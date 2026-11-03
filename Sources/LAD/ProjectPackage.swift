import CryptoKit
import Darwin
import Foundation
import ImageIO
import zlib

/// Incremental directory storage. Only project.json publishes a save. Every
/// dependency is immutable except the two explicitly alternated index slots.
/// Calls are coordinated by the document writer; this lock also serializes
/// direct reads, tests and multiple writer instances within this process.
enum ProjectPackage {
    static let formatVersion = 5
    static let maximumRootBytes = 32_000_000
    static let maximumChunkBytes = 512_000
    static let maximumMetadataRecordBytes = 8_000_000
    static let maximumMetadataBytes = 256_000_000
    static let maximumChunkRecords = 128
    private static let lock = NSRecursiveLock()
    private static var sessions: [String: Session] = [:]

    struct Reference: Codable, Equatable {
        var path: String
        var sha256: String
    }

    private struct Session {
        var project: LADProject
        var snapshot: ProjectArchive.Snapshot
        var metadata: [String: Any]
        var root: [String: Any]
        var rootData: Data
        var files: Set<String>
        var verifiedAttachments: [String: Data]
    }

    static func rootData(from url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try requirePackage(url)
        return try readFile("project.json", in: url, limit: maximumRootBytes)
    }

    static func read(from url: URL) throws -> LADProject {
        lock.lock(); defer { lock.unlock() }
        return try load(url).project
    }

    /// beforePublication is a fault-injection point: throwing must leave the
    /// previously committed root and all its dependencies readable.
    static func write(_ project: LADProject, to url: URL, thumbnail: Data? = nil,
                      beforePublication: (() throws -> Void)? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        if !exists { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
        try requirePackage(url)
        let rootURL = url.appendingPathComponent("project.json")
        var previous: Session?
        if manager.fileExists(atPath: rootURL.path) {
            let data = try readFile("project.json", in: url, limit: maximumRootBytes)
            if let cached = sessions[key], cached.rootData == data { previous = cached }
            else { previous = try load(url) }
            guard previous?.project.projectID == project.projectID else {
                throw invalid("The destination belongs to a different design.")
            }
        } else if exists {
            guard try manager.contentsOfDirectory(atPath: url.path).isEmpty else {
                throw invalid("The destination is not an empty design package.")
            }
        }

        let portable = try normalized(project)
        var verified = previous?.verifiedAttachments ?? [:]
        let historyChanged = previous.map { !sameHistory(portable, $0.project) } ?? true
        guard portable.selectedRevisionID.map({ id in portable.revisions.contains { $0.id == id } }) ?? true else {
            throw invalid("The selected revision does not exist.")
        }
        if historyChanged { try ProjectStore.validate(portable, verifiedAttachmentPayloads: &verified) }
        else {
            var state = portable
            state.messages = []; state.revisions = []; state.taskAudits = nil; state.selectedRevisionID = nil
            try ProjectStore.validate(state, verifiedAttachmentPayloads: &verified)
        }
        let snapshot = try makeSnapshot(portable, previous: previous)
        let metadata = try object(snapshot.metadata)
        var root = metadata
        root.removeValue(forKey: "messages")
        root.removeValue(forKey: "revisions")
        root.removeValue(forKey: "taskAudits")
        root["formatVersion"] = formatVersion
        var files = Set<String>()
        var directories = Set<String>()

        func store(_ value: Any, directory: String, prefix: String) throws -> [String: Any] {
            let data = try json(value)
            let hash = digest(data)
            let path = "\(directory)/\(prefix)-\(hash).json"
            try writeImmutable(data, path: path, in: url, verified: previous?.files ?? [], directories: &directories)
            files.insert(path)
            return ["path": path, "sha256": hash]
        }
        func index(_ value: Any, directory: String, old: Any?) throws -> [String: Any] {
            let data = try json(value), hash = digest(data)
            let prior = old as? [String: Any]
            if prior?["sha256"] as? String == hash, let path = prior?["path"] as? String {
                try requireRegularFile(path, in: url)
                files.insert(path)
                return ["path": path, "sha256": hash]
            }
            let oldPath = prior?["path"] as? String
            let slot = oldPath == "\(directory)/index-1.json" ? 2 : 1
            let path = "\(directory)/index-\(slot).json"
            try writeAtomic(data, path: path, in: url, directories: &directories)
            files.insert(path)
            return ["path": path, "sha256": hash]
        }
        func chunks(_ values: [[String: Any]], directory: String, prefix: String) throws -> [[String: Any]] {
            var result = [[String: Any]](), pending = [[String: Any]](), count = 2
            for value in values {
                let bytes = try json(value).count + 1
                if !pending.isEmpty && (pending.count >= maximumChunkRecords || count + bytes > maximumChunkBytes) {
                    result.append(try store(pending, directory: directory, prefix: prefix))
                    pending = []; count = 2
                }
                pending.append(value); count += bytes
            }
            if !pending.isEmpty { result.append(try store(pending, directory: directory, prefix: prefix)) }
            return result
        }

        let reuseDependencies = previous.map {
            !historyChanged && portable.queuedRequests == $0.project.queuedRequests &&
                portable.draftAttachments == $0.project.draftAttachments
        } ?? false
        if reuseDependencies, let previous {
            for field in ["revisions", "conversation", "activity", "assets"] { root[field] = previous.root[field] }
            files = previous.files
        } else {
        var revisionEntries = [[String: Any]]()
        for archived in metadata["revisions"] as? [[String: Any]] ?? [] {
            guard let id = archived["id"] as? String, UUID(uuidString: id) != nil else { throw invalid("A revision identity is invalid.") }
            var recipe = archived, parts = [String: Any]()
            for field in ["parts", "partLayout", "hiddenSolids", "partColors"] {
                if let value = recipe.removeValue(forKey: field) { parts[field] = value }
            }
            let name = recipe.removeValue(forKey: "name")
            let directory = "revisions/\(id)"
            var entry: [String: Any] = ["id": id,
                "recipe": try store(recipe, directory: directory, prefix: "recipe"),
                "parts": try store(parts, directory: directory, prefix: "parts")]
            entry["name"] = name
            revisionEntries.append(entry)
        }
        root["revisions"] = try index(["entries": revisionEntries], directory: "revisions", old: previous?.root["revisions"])
        let messageChunks = try chunks(metadata["messages"] as? [[String: Any]] ?? [], directory: "conversation", prefix: "messages")
        root["conversation"] = try index(["chunks": messageChunks], directory: "conversation", old: previous?.root["conversation"])
        var taskEntries = [[String: Any]]()
        for archived in metadata["taskAudits"] as? [[String: Any]] ?? [] {
            guard let id = archived["id"] as? String, UUID(uuidString: id) != nil else { throw invalid("A task identity is invalid.") }
            var task = archived
            let events = task.removeValue(forKey: "events") as? [[String: Any]] ?? []
            let directory = "activity/\(id)"
            task["eventChunks"] = try chunks(events, directory: directory, prefix: "events")
            taskEntries.append(try store(task, directory: directory, prefix: "task"))
        }
        root["activity"] = try index(["tasks": taskEntries], directory: "activity", old: previous?.root["activity"])

        var assetEntries = [String: Any]()
        let previousAssets = previous?.root["assets"] as? [String: Any] ?? [:]
        for (hash, bytes) in snapshot.assets {
            let path = assetPath(hash)
            if let old = previousAssets[hash] as? [String: Any],
               old["byteCount"] as? Int == bytes.count, old["path"] as? String == path {
                try requireRegularFile(path, in: url)
                assetEntries[hash] = old
            } else {
                let stored = try compressedAsset(bytes)
                try writeImmutable(stored.bytes, path: path, in: url, verified: previous?.files ?? [], directories: &directories)
                assetEntries[hash] = ["path": path, "sha256": hash, "byteCount": bytes.count,
                                      "storedByteCount": stored.bytes.count, "codec": stored.codec]
            }
            files.insert(path)
        }
        root["assets"] = assetEntries
        }
        let thumbnailKey = try thumbnailIdentity(metadata)
        if let old = previous?.root["thumbnail"] as? [String: Any], let path = old["path"] as? String,
           !(root["assets"] as? [String: Any] ?? [:]).values.contains(where: { ($0 as? [String: Any])?["path"] as? String == path }) {
            files.remove(path)
        }
        if let thumbnail, validThumbnail(thumbnail) {
            let hash = digest(thumbnail), path = assetPath(hash)
            // Presentation images are optional: unavailable thumbnail storage
            // must not prevent publishing the authoritative design.
            if (try? writeImmutable(thumbnail, path: path, in: url, verified: previous?.files ?? [], directories: &directories)) != nil {
                files.insert(path)
                root["thumbnail"] = ["path": path, "sha256": hash, "byteCount": thumbnail.count]
                root["thumbnailIdentity"] = thumbnailKey
            }
        } else if previous?.root["thumbnailIdentity"] as? String == thumbnailKey,
                  let prior = previous?.root["thumbnail"] as? [String: Any], let path = prior["path"] as? String,
                  let hash = prior["sha256"] as? String,
                  let bytes = try? readFile(path, in: url, limit: 8_000_000), validThumbnail(bytes), digest(bytes) == hash {
            root["thumbnail"] = prior; root["thumbnailIdentity"] = thumbnailKey; files.insert(path)
        }
        // Do not create a new commit for a byte-identical authoritative state.
        var comparable = root, oldComparable = previous?.root ?? [:]
        comparable.removeValue(forKey: "commitID"); comparable.removeValue(forKey: "parentCommitID")
        oldComparable.removeValue(forKey: "commitID"); oldComparable.removeValue(forKey: "parentCommitID")
        if previous != nil, try json(comparable) == json(oldComparable) { return }
        root["commitID"] = UUID().uuidString
        root["parentCommitID"] = previous?.root["commitID"]
        let data = try json(root)
        guard data.count <= maximumRootBytes else { throw invalid("The design manifest exceeds its size limit.") }
        for directory in directories.sorted(by: { $0.count > $1.count }) { try synchronizeDirectory(url.appendingPathComponent(directory)) }
        try beforePublication?()
        try writeAtomic(data, path: "project.json", in: url, directories: &directories)
        try synchronizeDirectory(url)

        var committed = portable
        committed.fileOrigin = ProjectFileOrigin(url: url, data: data)
        let session = Session(project: committed, snapshot: snapshot, metadata: metadata, root: root,
                              rootData: data, files: files, verifiedAttachments: verified)
        remember(session, key: key)
        // Cleanup follows publication and cannot invalidate an unsuccessful save.
        // The inactive index slot is retained for the next alternating write.
        if let previous {
            for path in previous.files.subtracting(files) where !isIndexSlot(path) {
                if let target = try? safeURL(path, in: url) { try? manager.removeItem(at: target) }
            }
        }
    }

    /// Tests and one-time development conversion can discard process caches.
    static func clearSessionCache() {
        lock.lock(); defer { lock.unlock() }
        sessions.removeAll()
    }

    private static func load(_ url: URL) throws -> Session {
        try requirePackage(url)
        let data = try readFile("project.json", in: url, limit: maximumRootBytes)
        let root = try object(data)
        guard root["formatVersion"] as? Int == formatVersion,
              let commitID = root["commitID"] as? String, UUID(uuidString: commitID) != nil else {
            throw invalid("Unsupported design package format.")
        }
        var files = Set<String>()
        var metadataBytes = data.count
        func readReference(_ value: Any?, prefix: String) throws -> Data {
            guard let reference = value as? [String: Any], let path = reference["path"] as? String,
                  path.hasPrefix(prefix), let hash = reference["sha256"] as? String, validHash(hash) else {
                throw invalid("A design record reference is invalid.")
            }
            if isIndexSlot(path) {
                guard path == "\(prefix)1.json" || path == "\(prefix)2.json" else { throw invalid("An index slot is invalid.") }
            } else {
                guard path.hasSuffix("-\(hash).json") else { throw invalid("A record filename has an inconsistent hash.") }
            }
            let bytes = try readFile(path, in: url, limit: min(maximumMetadataRecordBytes, maximumMetadataBytes - metadataBytes))
            metadataBytes += bytes.count
            guard metadataBytes <= maximumMetadataBytes else { throw invalid("The design metadata exceeds its size limit.") }
            guard digest(bytes) == hash else { throw invalid("A saved design record failed its integrity check.") }
            files.insert(path)
            return bytes
        }
        func readChunks(_ value: Any?, prefix: String) throws -> [[String: Any]] {
            guard let refs = value as? [[String: Any]], refs.count <= 100_000 else { throw invalid("A design chunk list is invalid.") }
            var values = [[String: Any]]()
            for ref in refs {
                let data = try readReference(ref, prefix: prefix)
                guard let chunk = try jsonValue(data) as? [[String: Any]],
                      chunk.count <= maximumChunkRecords else { throw invalid("A design chunk is invalid.") }
                values.append(contentsOf: chunk)
                guard values.count <= 100_000 else { throw invalid("A design chunk collection is too large.") }
            }
            return values
        }
        var metadata = root
        metadata["formatVersion"] = ProjectArchive.formatVersion
        for field in ["commitID", "parentCommitID", "conversation", "activity", "thumbnail", "thumbnailIdentity"] { metadata.removeValue(forKey: field) }
        let revisionIndex = try object(readReference(root["revisions"], prefix: "revisions/index-"))
        guard let entries = revisionIndex["entries"] as? [[String: Any]], entries.count <= 1_000 else { throw invalid("The version index is invalid.") }
        var revisions = [[String: Any]]()
        for entry in entries {
            guard let id = entry["id"] as? String, UUID(uuidString: id) != nil else { throw invalid("A version identity is invalid.") }
            var revision = try object(readReference(entry["recipe"], prefix: "revisions/\(id)/recipe-"))
            guard revision["id"] as? String == id else { throw invalid("A version record has a mismatched identity.") }
            let parts = try object(readReference(entry["parts"], prefix: "revisions/\(id)/parts-"))
            guard Set(parts.keys).isSubset(of: ["parts", "partLayout", "hiddenSolids", "partColors"]) else { throw invalid("A parts record contains unsupported fields.") }
            revision.merge(parts) { _, value in value }
            revision["name"] = entry["name"]
            revisions.append(revision)
        }
        metadata["revisions"] = revisions
        let conversation = try object(readReference(root["conversation"], prefix: "conversation/index-"))
        metadata["messages"] = try readChunks(conversation["chunks"], prefix: "conversation/messages-")
        let activity = try object(readReference(root["activity"], prefix: "activity/index-"))
        guard let taskRefs = activity["tasks"] as? [[String: Any]], taskRefs.count <= 10_000 else { throw invalid("The activity index is invalid.") }
        var tasks = [[String: Any]](), eventCount = 0
        for reference in taskRefs {
            var task = try object(readReference(reference, prefix: "activity/"))
            guard let id = task["id"] as? String, UUID(uuidString: id) != nil,
                  (reference["path"] as? String)?.hasPrefix("activity/\(id)/task-") == true else { throw invalid("A task identity is invalid.") }
            let events = try readChunks(task.removeValue(forKey: "eventChunks"), prefix: "activity/\(id)/events-")
            eventCount += events.count
            guard eventCount <= 100_000 else { throw invalid("The activity history is too large.") }
            task["events"] = events
            tasks.append(task)
        }
        if !tasks.isEmpty { metadata["taskAudits"] = tasks }
        else { metadata.removeValue(forKey: "taskAudits") }
        guard let descriptors = root["assets"] as? [String: Any], descriptors.count <= 32_768 else { throw invalid("The asset catalog is invalid.") }
        var assets = [String: Data](), total = 0
        for (hash, value) in descriptors {
            guard validHash(hash), let descriptor = value as? [String: Any],
                  descriptor["sha256"] as? String == hash,
                  descriptor["path"] as? String == assetPath(hash),
                  let count = descriptor["byteCount"] as? Int, (0...ProjectStore.maximumFileBytes).contains(count),
                  let storedCount = descriptor["storedByteCount"] as? Int, (0...ProjectStore.maximumFileBytes).contains(storedCount),
                  let codec = descriptor["codec"] as? String else { throw invalid("A saved asset descriptor is invalid.") }
            guard count <= ProjectStore.maximumFileBytes - total else { throw invalid("Saved assets exceed the design size limit.") }
            total += count
            let path = assetPath(hash), stored = try readFile(path, in: url, limit: storedCount)
            guard stored.count == storedCount else { throw invalid("A saved asset has an inconsistent size.") }
            let bytes = try expandedAsset(stored, codec: codec, byteCount: count)
            guard digest(bytes) == hash else { throw invalid("A saved file asset failed its integrity check.") }
            assets[hash] = bytes; files.insert(path)
        }
        metadata["assets"] = [String: Any]()
        let snapshot = ProjectArchive.Snapshot(metadata: try json(metadata), assets: assets)
        var project = try ProjectArchive.restore(metadata: snapshot.metadata, assets: assets)
        var verified = [String: Data]()
        try ProjectStore.validate(project, verifiedAttachmentPayloads: &verified)
        project.fileOrigin = ProjectFileOrigin(url: url, data: data)
        if let thumbnail = root["thumbnail"] as? [String: Any],
           let hash = thumbnail["sha256"] as? String, validHash(hash),
           thumbnail["path"] as? String == assetPath(hash),
           let bytes = try? readFile(assetPath(hash), in: url, limit: 8_000_000),
           validThumbnail(bytes), digest(bytes) == hash {
            project.thumbnailData = bytes
            files.insert(assetPath(hash))
        }
        let session = Session(project: project, snapshot: snapshot, metadata: metadata, root: root,
                              rootData: data, files: files, verifiedAttachments: verified)
        remember(session, key: url.standardizedFileURL.resolvingSymlinksInPath().path)
        return session
    }

    private static func makeSnapshot(_ project: LADProject, previous: Session?) throws -> ProjectArchive.Snapshot {
        guard let previous else { return try ProjectArchive.split(project) }
        var changed = project
        let oldMessages = Dictionary(uniqueKeysWithValues: previous.project.messages.map { ($0.id, $0) })
        changed.messages = project.messages.filter { oldMessages[$0.id] != $0 }
        let oldRevisions = Dictionary(uniqueKeysWithValues: previous.project.revisions.map { ($0.id, $0) })
        changed.revisions = project.revisions.filter { revision in
            oldRevisions[revision.id].map { !sameRevision(revision, $0) } ?? true
        }
        let oldTasks = Dictionary(uniqueKeysWithValues: (previous.project.taskAudits ?? []).map { ($0.id, $0) })
        changed.taskAudits = project.taskAudits?.compactMap { task in
            guard oldTasks[task.id] != task else { return nil }
            var value = task
            let oldEvents = Dictionary(uniqueKeysWithValues: (oldTasks[task.id]?.events ?? []).map { ($0.id, $0) })
            value.events = task.events.filter { oldEvents[$0.id] != $0 }
            return value
        }
        let sameQueue = project.queuedRequests == previous.project.queuedRequests
        let sameDraftAttachments = project.draftAttachments == previous.project.draftAttachments
        if sameQueue { changed.queuedRequests = nil }
        if sameDraftAttachments { changed.draftAttachments = nil }
        changed.selectedRevisionID = nil
        let delta = try ProjectArchive.split(changed)
        var metadata = try object(delta.metadata)
        func mergeRecords(_ field: String, ids: [String]) -> [[String: Any]] {
            let old = previous.metadata[field] as? [[String: Any]] ?? []
            let new = metadata[field] as? [[String: Any]] ?? []
            let records = Dictionary((old + new).compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { _, new in new })
            return ids.compactMap { records[$0] }
        }
        metadata["messages"] = mergeRecords("messages", ids: project.messages.map { $0.id.uuidString })
        metadata["revisions"] = mergeRecords("revisions", ids: project.revisions.map { $0.id.uuidString })
        var mergedTasks = mergeRecords("taskAudits", ids: (project.taskAudits ?? []).map { $0.id.uuidString })
        let oldTaskRecords = Dictionary((previous.metadata["taskAudits"] as? [[String: Any]] ?? []).compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { _, new in new })
        let currentTasks = Dictionary(uniqueKeysWithValues: (project.taskAudits ?? []).map { ($0.id.uuidString, $0) })
        for index in mergedTasks.indices {
            guard let id = mergedTasks[index]["id"] as? String, let task = currentTasks[id] else { continue }
            let old = oldTaskRecords[id]?["events"] as? [[String: Any]] ?? []
            let new = mergedTasks[index]["events"] as? [[String: Any]] ?? []
            let events = Dictionary((old + new).compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { _, new in new })
            mergedTasks[index]["events"] = task.events.compactMap { events[$0.id] }
        }
        if project.taskAudits != nil { metadata["taskAudits"] = mergedTasks }
        if sameQueue { metadata["queuedRequests"] = previous.metadata["queuedRequests"] }
        if sameDraftAttachments { metadata["draftAttachments"] = previous.metadata["draftAttachments"] }
        metadata["selectedRevisionID"] = project.selectedRevisionID?.uuidString
        let candidates = previous.snapshot.assets.merging(delta.assets) { _, new in new }
        let required = assetReferences(metadata)
        let assets = candidates.filter { required.contains($0.key) }
        guard assets.count == required.count else { throw invalid("A saved asset reference is missing.") }
        return ProjectArchive.Snapshot(metadata: try json(metadata), assets: assets)
    }

    private static func normalized(_ project: LADProject) throws -> LADProject {
        var result = project
        for index in result.revisions.indices {
            if result.revisions[index].parts == nil, let preview = result.revisions[index].preview {
                guard (0...4_096).contains(preview.solids) else { throw invalid("The design contains an invalid solid count.") }
                result.revisions[index].parts = preview.parts ?? (0..<preview.solids).map {
                    PartNode(id: "solid/\($0)", name: "Part \($0 + 1)", solidIndices: [$0])
                }
            }
            result.revisions[index].preview = nil
            result.revisions[index].stepData = nil
        }
        for task in result.taskAudits?.indices ?? 0..<0 {
            for event in result.taskAudits![task].events.indices { result.taskAudits![task].events[event].imageData = nil }
        }
        return result
    }

    private static func sameHistory(_ lhs: LADProject, _ rhs: LADProject) -> Bool {
        lhs.messages == rhs.messages && lhs.taskAudits == rhs.taskAudits && lhs.revisions.count == rhs.revisions.count &&
            zip(lhs.revisions, rhs.revisions).allSatisfy(sameRevision)
    }

    private static func sameRevision(_ lhs: ProjectRevision, _ rhs: ProjectRevision) -> Bool {
        lhs.id == rhs.id && lhs.model == rhs.model && lhs.date == rhs.date && lhs.partLayout == rhs.partLayout &&
        lhs.hiddenSolids == rhs.hiddenSolids && lhs.parts == rhs.parts && lhs.runtime == rhs.runtime &&
        lhs.userMessageID == rhs.userMessageID && lhs.responseMessageID == rhs.responseMessageID &&
        lhs.partColors == rhs.partColors && lhs.name == rhs.name && lhs.validatedHash == rhs.validatedHash
    }

    private static func assetReferences(_ value: Any) -> Set<String> {
        let fields: Set<String> = ["scriptAsset", "sourceSTEPAsset", "dataAsset", "contentAsset", "inputAsset", "outputAsset"]
        var result = Set<String>()
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, value) in object {
                    if fields.contains(key), let hash = value as? String { result.insert(hash) }
                    else { visit(value) }
                }
            } else if let array = value as? [Any] { for value in array { visit(value) } }
        }
        visit(value)
        return result
    }

    private static func thumbnailIdentity(_ metadata: [String: Any]) throws -> String {
        let selected = metadata["selectedRevisionID"] as? String
        let revision = (metadata["revisions"] as? [[String: Any]] ?? []).first { $0["id"] as? String == selected }
        var identity = [String: Any]()
        for field in ["id", "scriptAsset", "sourceSTEPAsset", "inputAssets", "hiddenSolids", "partColors"] { identity[field] = revision?[field] }
        for field in ["displayMode", "projectionMode"] { identity[field] = metadata[field] }
        return digest(try json(identity))
    }

    private static func compressedAsset(_ data: Data) throws -> (bytes: Data, codec: String) {
        guard data.count >= 1_024,
              !data.starts(with: [137, 80, 78, 71]), !data.starts(with: [255, 216, 255]) else { return (data, "raw") }
        var capacity = compressBound(uLong(data.count))
        var result = Data(count: Int(capacity))
        let status = result.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &capacity,
                          source.bindMemory(to: Bytef.self).baseAddress!, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw invalid("A design asset could not be compressed.") }
        result.count = Int(capacity)
        return result.count + 32 < data.count ? (result, "zlib") : (data, "raw")
    }

    private static func expandedAsset(_ data: Data, codec: String, byteCount: Int) throws -> Data {
        if codec == "raw" {
            guard data.count == byteCount else { throw invalid("A saved asset has an inconsistent size.") }
            return data
        }
        guard codec == "zlib", byteCount > 0, !data.isEmpty else { throw invalid("A saved asset has an unsupported encoding.") }
        var count = uLongf(byteCount), sourceCount = uLong(data.count), output = Data(count: byteCount)
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                uncompress2(destination.bindMemory(to: Bytef.self).baseAddress!, &count,
                            source.bindMemory(to: Bytef.self).baseAddress!, &sourceCount)
            }
        }
        guard status == Z_OK, count == byteCount, sourceCount == data.count else { throw invalid("A compressed design asset is invalid.") }
        return output
    }

    private static func validThumbnail(_ data: Data) -> Bool {
        guard data.count <= 8_000_000, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4_096).contains(width), (1...4_096).contains(height) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func remember(_ session: Session, key: String) {
        if sessions[key] == nil, sessions.count >= 8 { sessions.removeValue(forKey: sessions.keys.sorted().first!) }
        sessions[key] = session
    }

    private static func requirePackage(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw invalid("Open a folder-based .lad design package.")
        }
    }

    private static func safeURL(_ path: String, in root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw invalid("A design package contains an invalid file path.")
        }
        var result = root
        for component in components {
            result.appendPathComponent(String(component))
            if let values = try? result.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw invalid("Design package contents cannot be symbolic links.")
            }
        }
        return result
    }

    private static func requireRegularFile(_ path: String, in root: URL) throws {
        let values = try safeURL(path, in: root).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalid("A required design file is unavailable.") }
    }

    private static func readFile(_ path: String, in root: URL, limit: Int) throws -> Data {
        try requireRegularFile(path, in: root)
        let target = try safeURL(path, in: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(max(0, limit)) else { throw invalid("A design file exceeds its size limit.") }
        let file = try FileHandle(forReadingFrom: target)
        defer { try? file.close() }
        var result = Data()
        while let chunk = try file.read(upToCount: min(1_048_576, limit + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= limit else { throw invalid("A design file exceeds its size limit.") }
        }
        return result
    }

    private static func writeImmutable(_ data: Data, path: String, in root: URL, verified: Set<String>, directories: inout Set<String>) throws {
        let target = try safeURL(path, in: root)
        if FileManager.default.fileExists(atPath: target.path) {
            try requireRegularFile(path, in: root)
            // An orphan from an interrupted save is not covered by the last
            // verified manifest. Verify its exact stored bytes before adopting it.
            if !verified.contains(path) {
                guard try readFile(path, in: root, limit: data.count) == data else {
                    throw invalid("An existing content-addressed file has conflicting bytes.")
                }
            }
            return
        }
        try writeAtomic(data, path: path, in: root, directories: &directories)
    }

    private static func writeAtomic(_ data: Data, path: String, in root: URL, directories: inout Set<String>) throws {
        let target = try safeURL(path, in: root)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try safeURL(path, in: root)
        try data.write(to: target, options: .atomic)
        let file = try FileHandle(forWritingTo: target)
        defer { try? file.close() }
        try file.synchronize()
        var ancestor = parent
        while ancestor.path.hasPrefix(root.path), ancestor.path != root.path {
            directories.insert(String(ancestor.path.dropFirst(root.path.count + 1)))
            ancestor.deleteLastPathComponent()
        }
        directories.insert("")
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func isIndexSlot(_ path: String) -> Bool { path.hasSuffix("/index-1.json") || path.hasSuffix("/index-2.json") }
    private static func assetPath(_ hash: String) -> String { "assets/sha256/\(hash.prefix(2))/\(hash)" }
    private static func validHash(_ hash: String) -> Bool { hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    /// JSONSerialization parses the integer token -0 as positive Int zero.
    /// Preserve Double's sign by giving that numeric token an explicit fraction;
    /// quoted strings and exponents remain byte-for-byte untouched.
    private static func jsonValue(_ data: Data) throws -> Any {
        guard data.range(of: Data("-0".utf8)) != nil else { return try JSONSerialization.jsonObject(with: data) }
        let bytes = [UInt8](data)
        var output = Data(capacity: data.count), quoted = false, escaped = false, index = 0
        let delimiters: Set<UInt8> = [9, 10, 13, 32, 44, 93, 125]
        let starts: Set<UInt8> = [9, 10, 13, 32, 44, 58, 91, 123]
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 {
                quoted = true; output.append(byte)
            } else if byte == 45, index + 1 < bytes.count, bytes[index + 1] == 48,
                      index == 0 || starts.contains(bytes[index - 1]),
                      index + 2 == bytes.count || delimiters.contains(bytes[index + 2]) {
                output.append(contentsOf: [45, 48, 46, 48])
                index += 2
                continue
            } else { output.append(byte) }
            index += 1
        }
        return try JSONSerialization.jsonObject(with: output)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try jsonValue(data) as? [String: Any] else { throw invalid("A design metadata record is invalid.") }
        return value
    }
    private static func invalid(_ reason: String) -> LADError { .message("Invalid LAD design. \(reason)") }
}
