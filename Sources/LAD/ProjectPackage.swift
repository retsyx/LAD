import CryptoKit
import Darwin
import Foundation
import ImageIO
import zlib

/// Incremental directory storage. Only project.json publishes a save. Every
/// dependency is immutable except the two explicitly alternated index slots.
/// Calls are coordinated by the document writer. In-process package locks also
/// protect direct readers and multiple writers without blocking other designs.
enum ProjectPackage {
    /// Version 7 encodes every section as typed records through one sorted-key
    /// JSONEncoder. Versions 5 and 6 contain the same records written by
    /// JSONSerialization; version 5 also inlines its asset catalog in
    /// project.json. Both open with their full history, and their next save
    /// rewrites every record and index in the current encoding.
    static let formatVersion = 7
    private static let readableFormatVersions = 5...formatVersion
    private static let inlineCatalogFormatVersion = 5
    static let maximumRootBytes = 32_000_000
    static let maximumChunkBytes = 512_000
    static let maximumMetadataRecordBytes = 8_000_000
    static let maximumMetadataBytes = 256_000_000
    static let maximumChunkRecords = 128
    /// Parsed sessions serve the open designs' next incremental writes. Closed
    /// designs release theirs; the least recently used entry goes first.
    static let maximumCachedSessions = 8
    private static let cacheLock = NSLock()
    private static var sessions: [String: Session] = [:]
    private static var sessionOrder: [String] = []
    private static var packageLocks: [String: PackageLock] = [:]

    private final class PackageLock {
        let lock = NSRecursiveLock()
        // Counts both owners and waiters. Access only while holding cacheLock.
        var users = 0
    }

    private static func acquirePackage(_ url: URL) -> (key: String, entry: PackageLock) {
        // The coordinated document writer also owns initial creation and moves.
        // Existing case, symlink and standardized-path aliases resolve together.
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        cacheLock.lock()
        let entry = packageLocks[key] ?? PackageLock()
        entry.users += 1
        packageLocks[key] = entry
        cacheLock.unlock()
        // Never hold the shared cache lock while waiting or doing file work.
        entry.lock.lock()
        return (key, entry)
    }

    private static func releasePackage(_ lease: (key: String, entry: PackageLock)) {
        lease.entry.lock.unlock()
        cacheLock.lock()
        lease.entry.users -= 1
        if lease.entry.users == 0 { packageLocks.removeValue(forKey: lease.key) }
        cacheLock.unlock()
    }

    /// Session keys resolve the parent folder, so a package that was just moved
    /// or removed still maps to the key it was cached under.
    private static func sessionKey(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent).path
    }

    private static func cachedSession(_ key: String) -> Session? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let session = sessions[key] else { return nil }
        sessionOrder.removeAll { $0 == key }
        sessionOrder.append(key)
        return session
    }

    struct Reference: Codable, Equatable {
        var path: String
        var sha256: String
    }

    struct WriteMetrics {
        /// The previous commit had to be parsed from disk rather than reused
        /// from this process's session cache.
        var reloadedPrevious = false
        var historySnapshots = 0
        var rootEncodings = 0
        var thumbnailValidations = 0
        var encodedHistoryRecords = 0
        var encodedChunks = 0
        var encodedSectionIndexes = 0
        var encodedRevisionRecipes = 0
        var encodedRevisionParts = 0
        var encodedTaskRecords = 0
        var compressedAssets = 0
        var encodedCatalogBuckets = 0
        var phaseSeconds: [String: TimeInterval] = [:]
    }

    // MARK: - Section records

    /// project.json: identity, per-design state, the draft and queue, and the
    /// committed section references.
    private struct Manifest: Codable, Equatable {
        var formatVersion: Int
        var commitID: UUID?
        var parentCommitID: UUID?
        var projectID: UUID?
        var selectedRevisionID: UUID?
        var codexSettings: CodexProjectSettings?
        var projectName: String?
        var showGrid: Bool?
        var projectionMode: ViewportProjectionMode?
        var displayMode: ViewportDisplayMode?
        var partsPaneFraction: Double?
        var recentPartColors: [PartColor]?
        var queuedRequests: [ProjectArchive.ArchivedQueuedRequest]?
        var draftPrompt: String?
        var draftAttachments: [ProjectArchive.ArchivedAttachment]?
        var queuePaused: Bool?
        var revisions: Reference
        var conversation: Reference
        var activity: Reference
        var catalog: Reference?
        /// Version 5 lists its asset descriptors here instead of a catalog section.
        var assets: [String: AssetDescriptor]?
        var thumbnail: Thumbnail?
        var thumbnailIdentity: String?

        var uncommitted: Manifest {
            var manifest = self
            manifest.commitID = nil
            manifest.parentCommitID = nil
            return manifest
        }
    }

    private struct Thumbnail: Codable, Equatable {
        var path: String
        var sha256: String
        var byteCount: Int
    }

    private struct AssetDescriptor: Codable, Equatable {
        var path: String
        var sha256: String
        var byteCount: Int
        var storedByteCount: Int
        var codec: String
    }

    private struct RevisionEntry: Codable {
        var id: UUID
        var name: String?
        var recipe: Reference
        var parts: Reference
    }

    private struct RevisionIndex: Codable { var entries: [RevisionEntry] }
    private struct ConversationIndex: Codable { var chunks: [Reference] }
    private struct ActivityIndex: Codable { var tasks: [Reference] }
    private struct CatalogIndex: Codable { var buckets: [String: Reference] }

    /// A task header and the chunks holding its events, coded as one object.
    private struct TaskRecord: Codable {
        var task: ProjectArchive.ArchivedTask
        var eventChunks: [Reference]

        init(task: ProjectArchive.ArchivedTask, eventChunks: [Reference]) {
            self.task = task
            self.eventChunks = eventChunks
        }

        private enum CodingKeys: String, CodingKey { case eventChunks }

        init(from decoder: Decoder) throws {
            task = try ProjectArchive.ArchivedTask(from: decoder)
            eventChunks = try decoder.container(keyedBy: CodingKeys.self).decode([Reference].self, forKey: .eventChunks)
        }

        func encode(to encoder: Encoder) throws {
            try task.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(eventChunks, forKey: .eventChunks)
        }
    }

    /// A parts file contains only part organization.
    private struct PartsRecord: Decodable {
        var parts: ProjectArchive.ArchivedParts

        private struct Field: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let fields: Set = ["parts", "partLayout", "hiddenSolids", "partColors", "jointPositions"]
            guard try decoder.container(keyedBy: Field.self).allKeys.allSatisfy({ fields.contains($0.stringValue) }) else {
                throw invalid("A parts record contains unsupported fields.")
            }
            parts = try ProjectArchive.ArchivedParts(from: decoder)
        }
    }

    /// The selected revision's replay inputs and presentation that a saved
    /// thumbnail depicts.
    private struct ThumbnailIdentity: Encodable {
        var id: UUID?
        var scriptAsset: String?
        var sourceSTEPAsset: String?
        var inputAssets: [ProjectArchive.ArchivedInputAsset]?
        var hiddenSolids: [Int]?
        var partColors: [String: PartColor]?
        var jointPositions: [String: Double]?
        var displayMode: ViewportDisplayMode?
        var projectionMode: ViewportProjectionMode?

        init(_ revision: RevisionRecords?, displayMode: ViewportDisplayMode?, projectionMode: ViewportProjectionMode?) {
            id = revision?.recipe.id
            scriptAsset = revision?.recipe.scriptAsset
            sourceSTEPAsset = revision?.recipe.sourceSTEPAsset
            inputAssets = revision?.recipe.inputAssets
            hiddenSolids = revision?.parts.hiddenSolids
            partColors = revision?.parts.partColors
            jointPositions = revision?.parts.jointPositions
            self.displayMode = displayMode
            self.projectionMode = projectionMode
        }

        var digest: String {
            get throws { SHA256.hexDigest(try ProjectPackage.encode(self)) }
        }

        /// Versions 5 and 6 hashed the same fields as JSONSerialization output.
        var legacyDigest: String {
            get throws {
                var object = [String: Any]()
                object["id"] = id?.uuidString
                object["scriptAsset"] = scriptAsset
                object["sourceSTEPAsset"] = sourceSTEPAsset
                object["inputAssets"] = inputAssets?.map { ["id": $0.id, "name": $0.name, "format": $0.format, "dataAsset": $0.dataAsset] }
                object["hiddenSolids"] = hiddenSolids
                object["partColors"] = partColors?.mapValues { ["red": $0.red, "green": $0.green, "blue": $0.blue] }
                object["jointPositions"] = jointPositions
                object["displayMode"] = displayMode?.rawValue
                object["projectionMode"] = projectionMode?.rawValue
                return SHA256.hexDigest(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            }
        }
    }

    // MARK: - Cached sections

    private struct Chunk {
        var reference: Reference
        var recordIDs: [String]
    }

    /// A history record with its canonical bytes, which rebuild changed chunks.
    private struct Encoded<Record> {
        var record: Record
        var bytes: Data
    }

    private struct RevisionRecords {
        var recipe: ProjectArchive.ArchivedRecipe
        var recipeFile: Reference?
        var parts: ProjectArchive.ArchivedParts
        var partsFile: Reference?
    }

    private struct TaskRecords {
        var task: ProjectArchive.ArchivedTask
        var file: Reference?
        var events: [String: Encoded<ProjectArchive.ArchivedActivityEvent>]
        var chunks: [Chunk]
    }

    /// Typed records of the committed sections and the files holding them.
    /// Derived once when opening, then updated only for changed records; this
    /// cache never becomes an additional on-disk dependency.
    private struct Sections {
        var revisions = [UUID: RevisionRecords]()
        var messages = [UUID: Encoded<ProjectArchive.ArchivedMessage>]()
        var conversation = [Chunk]()
        var tasks = [UUID: TaskRecords]()
        /// Asset descriptors by hash, and the catalog file holding each
        /// two-character hash prefix. A save rewrites only changed prefixes.
        var catalog = [String: AssetDescriptor]()
        var catalogBuckets = [String: Reference]()

        /// Keeps the records but none of their files, so a save rewrites them.
        mutating func forgetFiles() {
            for id in revisions.keys {
                revisions[id]?.recipeFile = nil
                revisions[id]?.partsFile = nil
            }
            conversation = []
            for id in tasks.keys {
                tasks[id]?.file = nil
                tasks[id]?.chunks = []
            }
            catalogBuckets = [:]
        }

        /// Every payload the sections refer to.
        var assetKeys: Set<String> {
            var keys = Set<String>()
            for revision in revisions.values { keys.formUnion(revision.recipe.assetKeys) }
            for message in messages.values { keys.formUnion(message.record.assetKeys) }
            for task in tasks.values {
                keys.formUnion(task.task.assetKeys)
                for event in task.events.values { keys.formUnion(event.record.assetKeys) }
            }
            return keys
        }
    }

    private struct Session {
        var project: LADProject
        var manifest: Manifest
        var rootData: Data
        var assets: [String: Data]
        var files: Set<String>
        var verifiedAttachments: [String: Data]
        var sections: Sections
        /// The current-encoding identity of the retained thumbnail.
        var thumbnailIdentity: String?
    }

    static func rootData(from url: URL) throws -> Data {
        let lease = acquirePackage(url); defer { releasePackage(lease) }
        try requirePackage(url)
        return try readFile("project.json", in: url, limit: maximumRootBytes)
    }

    /// Opening a design caches its parsed session for the next autosave.
    /// Comparisons with other files pass `caching: false`.
    static func read(from url: URL, caching: Bool = true) throws -> LADProject {
        let lease = acquirePackage(url); defer { releasePackage(lease) }
        return try load(url, caching: caching).project
    }

    /// The identity recorded in the authoritative manifest, without loading
    /// or caching the design's history.
    static func projectID(at url: URL) throws -> UUID? {
        struct Identity: Decodable {
            var formatVersion: Int
            var projectID: UUID?
        }
        let identity = try decode(Identity.self, from: rootData(from: url))
        guard readableFormatVersions.contains(identity.formatVersion) else {
            throw invalid("Unsupported design package format.")
        }
        return identity.projectID
    }

    /// Renames a package without replacing an existing file, keeping its
    /// validated session under the new path.
    static func rename(_ source: URL, to destination: URL) throws {
        let lease = acquirePackage(source); defer { releasePackage(lease) }
        let sourceKey = sessionKey(source)
        // RENAME_EXCL changes filename case on APFS and makes the move itself
        // refuse a newly appeared file.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
        let destinationKey = sessionKey(destination)
        cacheLock.lock()
        let moved = sessions.removeValue(forKey: sourceKey)
        sessionOrder.removeAll { $0 == sourceKey }
        cacheLock.unlock()
        guard var session = moved else { return }
        session.project.fileOrigin = ProjectFileOrigin(url: destination, data: session.rootData)
        remember(session, key: destinationKey)
    }

    /// Releases a design's parsed history once no open window or writer needs
    /// it. A later write reloads the package from disk.
    static func discardSession(at url: URL) {
        let key = sessionKey(url)
        cacheLock.lock()
        let discarded = sessions.removeValue(forKey: key)
        sessionOrder.removeAll { $0 == key }
        cacheLock.unlock()
        withExtendedLifetime(discarded) {}
    }

    // MARK: - Writing

    /// beforePublication is a fault-injection point: throwing must leave the
    /// previously committed root and all its dependencies readable.
    @discardableResult
    static func write(_ project: LADProject, to url: URL, thumbnail: Data? = nil,
                      beforePublication: (() throws -> Void)? = nil,
                      didFinish: ((WriteMetrics) -> Void)? = nil) throws -> Data {
        let lease = acquirePackage(url); defer { releasePackage(lease) }
        let save = Save(url: url)
        defer { didFinish?(save.metrics) }
        let key = sessionKey(url)
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        if !exists { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
        try requirePackage(url)
        var previous: Session?
        if manager.fileExists(atPath: url.appendingPathComponent("project.json").path) {
            let data = try readFile("project.json", in: url, limit: maximumRootBytes)
            if let cached = cachedSession(key), cached.rootData == data { previous = cached }
            else { previous = try load(url, caching: false); save.metrics.reloadedPrevious = true }
            guard previous?.project.projectID == project.projectID else {
                throw invalid("The destination belongs to a different design.")
            }
        } else if exists {
            guard try manager.contentsOfDirectory(atPath: url.path).isEmpty else {
                throw invalid("The destination is not an empty design package.")
            }
        }
        save.endPhase("previous")

        let portable = try normalized(project)
        var verified = previous?.verifiedAttachments ?? [:]
        let historyChanged = previous.map { !sameHistory(portable, $0.project) } ?? true
        guard portable.selectedRevisionID.map({ id in portable.revisions.contains { $0.id == id } }) ?? true else {
            throw invalid("The selected revision does not exist.")
        }
        if historyChanged { try ProjectStore.validate(portable, verifiedAttachmentPayloads: &verified, validatedPrevious: previous?.project) }
        else {
            try ProjectStore.validate(inlineProject(portable), verifiedAttachmentPayloads: &verified,
                                      validatedPrevious: previous.map { inlineProject($0.project) })
        }
        save.endPhase("validation")

        save.prepare(previous: previous)
        let queue = try save.queue(portable.queuedRequests)
        let draftAttachments = try save.draftAttachments(portable.draftAttachments)
        let revisions: Reference, conversation: Reference, activity: Reference, catalog: Reference
        let assets: [String: Data]
        if let previous, save.current, !historyChanged,
           sameQueuedAttachments(portable.queuedRequests, previous.project.queuedRequests),
           portable.draftAttachments == previous.project.draftAttachments, let previousCatalog = previous.manifest.catalog {
            // Unchanged history and attachments keep every section and payload.
            save.sections = previous.sections
            save.files = previous.files
            revisions = previous.manifest.revisions
            conversation = previous.manifest.conversation
            activity = previous.manifest.activity
            catalog = previousCatalog
            assets = previous.assets
        } else {
            save.metrics.historySnapshots += 1
            revisions = try save.revisions(portable.revisions)
            conversation = try save.conversation(portable.messages)
            activity = try save.activity(portable.taskAudits)
            assets = try save.assets(queue: queue, draftAttachments: draftAttachments)
            catalog = try save.catalog(assets)
        }
        save.endPhase("sections")

        let identity = try ThumbnailIdentity(portable.selectedRevisionID.flatMap { save.sections.revisions[$0] },
                                             displayMode: portable.displayMode, projectionMode: portable.projectionMode).digest
        let savedThumbnail = save.thumbnail(thumbnail, identity: identity)
        save.endPhase("thumbnail")

        var manifest = Manifest(formatVersion: formatVersion, projectID: portable.projectID,
                                selectedRevisionID: portable.selectedRevisionID, codexSettings: portable.codexSettings,
                                projectName: portable.projectName, showGrid: portable.showGrid,
                                projectionMode: portable.projectionMode, displayMode: portable.displayMode,
                                partsPaneFraction: portable.partsPaneFraction, recentPartColors: portable.recentPartColors,
                                queuedRequests: queue, draftPrompt: portable.draftPrompt, draftAttachments: draftAttachments,
                                queuePaused: portable.queuePaused, revisions: revisions, conversation: conversation,
                                activity: activity, catalog: catalog, thumbnail: savedThumbnail?.reference,
                                thumbnailIdentity: savedThumbnail == nil ? nil : identity)
        // Do not create a new commit for an identical authoritative state.
        // The catalog section's reference covers every asset descriptor.
        if let previous, manifest == previous.manifest.uncommitted {
            save.endPhase("manifest")
            return previous.rootData
        }
        manifest.commitID = UUID()
        manifest.parentCommitID = previous?.manifest.commitID
        save.metrics.rootEncodings += 1
        let data = try encode(manifest)
        guard data.count <= maximumRootBytes else { throw invalid("The design manifest exceeds its size limit.") }
        save.endPhase("manifest")
        for directory in save.directories.sorted(by: { $0.count > $1.count }) {
            try synchronizeDirectory(url.appendingPathComponent(directory))
        }
        try beforePublication?()
        try writeAtomic(data, path: "project.json", in: url, directories: &save.directories)
        try synchronizeDirectory(url)

        var committed = portable
        committed.fileOrigin = ProjectFileOrigin(url: url, data: data)
        committed.thumbnailData = savedThumbnail?.bytes
        remember(Session(project: committed, manifest: manifest, rootData: data, assets: assets, files: save.files,
                         verifiedAttachments: verified, sections: save.sections,
                         thumbnailIdentity: savedThumbnail == nil ? nil : identity), key: key)
        // Cleanup follows publication and cannot invalidate an unsuccessful save.
        // The inactive index slot is retained for the next alternating write.
        if let previous {
            for path in previous.files.subtracting(save.files) where !isIndexSlot(path) {
                if let target = try? safeURL(path, in: url) { try? manager.removeItem(at: target) }
            }
        }
        save.endPhase("publication")
        return data
    }

    /// One save: the new sections, the payloads they store, and the files
    /// written or kept for them.
    private final class Save {
        let url: URL
        private(set) var previous: Session?
        /// Whether the previous commit's files use the current encoding.
        private(set) var current = false
        /// The previous sections, whose unchanged records and files are reused.
        private(set) var old = Sections()
        var sections = Sections()
        var writer = ProjectArchive.AssetWriter()
        var files = Set<String>()
        var directories = Set<String>()
        var metrics = WriteMetrics()
        private var phaseStart = ProcessInfo.processInfo.systemUptime

        init(url: URL) { self.url = url }

        /// Records of an earlier format version are reused, but their files are
        /// rewritten in the current encoding.
        func prepare(previous: Session?) {
            self.previous = previous
            current = previous?.manifest.formatVersion == formatVersion
            old = previous?.sections ?? Sections()
            if !current { old.forgetFiles() }
        }

        func endPhase(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            metrics.phaseSeconds[name] = now - phaseStart
            phaseStart = now
        }

        private var verified: Set<String> { previous?.files ?? [] }

        func keep(_ reference: Reference) -> Reference {
            files.insert(reference.path)
            return reference
        }

        private func keepFiles(prefix: String) {
            files.formUnion((previous?.files ?? []).filter { $0.hasPrefix(prefix) })
        }

        func store(_ data: Data, directory: String, prefix: String) throws -> Reference {
            let hash = SHA256.hexDigest(data)
            let path = "\(directory)/\(prefix)-\(hash).json"
            try writeImmutable(data, path: path, in: url, verified: verified, directories: &directories)
            files.insert(path)
            return Reference(path: path, sha256: hash)
        }

        /// Writes the inactive index slot unless the committed one holds these bytes.
        func index<Value: Encodable>(_ value: Value, directory: String, old: Reference?) throws -> Reference {
            metrics.encodedSectionIndexes += 1
            let data = try encode(value), hash = SHA256.hexDigest(data)
            if let old, old.sha256 == hash {
                try requireRegularFile(old.path, in: url)
                return keep(old)
            }
            let slot = old?.path == "\(directory)/index-1.json" ? 2 : 1
            let path = "\(directory)/index-\(slot).json"
            try writeAtomic(data, path: path, in: url, directories: &directories)
            files.insert(path)
            return Reference(path: path, sha256: hash)
        }

        /// Greedy chunks of encoded records. A chunk with the same records, none
        /// of them changed, keeps its file.
        func chunks(_ records: [(id: String, bytes: Data)], changed: Set<String>, directory: String, prefix: String,
                    old: [Chunk]) throws -> [Chunk] {
            let prior = Dictionary(old.compactMap { chunk in chunk.recordIDs.first.map { ($0, chunk) } },
                                   uniquingKeysWith: { first, _ in first })
            var result = [Chunk](), pending = [(id: String, bytes: Data)](), count = 2
            func flush() throws {
                guard let first = pending.first else { return }
                let ids = pending.map(\.id)
                let reference: Reference
                if let cached = prior[first.id], cached.recordIDs == ids, !ids.contains(where: changed.contains) {
                    reference = keep(cached.reference)
                } else {
                    var data = Data([91])
                    for (offset, record) in pending.enumerated() {
                        if offset > 0 { data.append(44) }
                        data.append(record.bytes)
                    }
                    data.append(93)
                    metrics.encodedChunks += 1
                    reference = try store(data, directory: directory, prefix: prefix)
                }
                result.append(Chunk(reference: reference, recordIDs: ids))
                pending = []; count = 2
            }
            for record in records {
                let bytes = record.bytes.count + 1
                if !pending.isEmpty && (pending.count >= maximumChunkRecords || count + bytes > maximumChunkBytes) {
                    try flush()
                }
                pending.append(record); count += bytes
            }
            try flush()
            return result
        }

        func queue(_ requests: [ProjectQueuedRequest]?) throws -> [ProjectArchive.ArchivedQueuedRequest]? {
            let oldRequests = Dictionary((previous?.project.queuedRequests ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let oldRecords = Dictionary((previous?.manifest.queuedRequests ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return try requests?.map { request in
                let old = oldRequests[request.id].flatMap { old in oldRecords[request.id].map { (old, $0) } }
                return try ProjectArchive.ArchivedQueuedRequest(request, reusing: old, writer: &writer)
            }
        }

        func draftAttachments(_ attachments: [SourceAttachment]?) throws -> [ProjectArchive.ArchivedAttachment]? {
            if let previous, attachments == previous.project.draftAttachments { return previous.manifest.draftAttachments }
            return try attachments?.map { try ProjectArchive.ArchivedAttachment($0, writer: &writer) }
        }

        func revisions(_ revisions: [ProjectRevision]) throws -> Reference {
            if let previous, current, sameRevisions(revisions, previous.project.revisions) {
                sections.revisions = old.revisions
                keepFiles(prefix: "revisions/")
                return previous.manifest.revisions
            }
            let oldRevisions = Dictionary((previous?.project.revisions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var entries = [RevisionEntry]()
            for revision in revisions {
                let oldRevision = oldRevisions[revision.id], cached = old.revisions[revision.id]
                let directory = "revisions/\(revision.id.uuidString)"
                let cachedRecipe = oldRevision.flatMap { sameRecipe(revision, $0) ? cached : nil }
                let cachedParts = oldRevision.flatMap { sameParts(revision, $0) ? cached : nil }
                let recipe = try cachedRecipe?.recipe ?? ProjectArchive.ArchivedRecipe(revision, writer: &writer)
                let recipeFile: Reference
                if let file = cachedRecipe?.recipeFile { recipeFile = keep(file) }
                else {
                    metrics.encodedRevisionRecipes += 1
                    recipeFile = try store(encode(recipe), directory: directory, prefix: "recipe")
                }
                let parts = try cachedParts?.parts ?? ProjectArchive.ArchivedParts(revision)
                let partsFile: Reference
                if let file = cachedParts?.partsFile { partsFile = keep(file) }
                else {
                    metrics.encodedRevisionParts += 1
                    partsFile = try store(encode(parts), directory: directory, prefix: "parts")
                }
                if !(oldRevision.map { sameRevision(revision, $0) } ?? false) { metrics.encodedHistoryRecords += 1 }
                sections.revisions[revision.id] = RevisionRecords(recipe: recipe, recipeFile: recipeFile, parts: parts, partsFile: partsFile)
                entries.append(RevisionEntry(id: revision.id, name: revision.name, recipe: recipeFile, parts: partsFile))
            }
            return try index(RevisionIndex(entries: entries), directory: "revisions", old: previous?.manifest.revisions)
        }

        func conversation(_ messages: [ChatMessage]) throws -> Reference {
            if let previous, current, messages == previous.project.messages {
                sections.messages = old.messages
                sections.conversation = old.conversation
                keepFiles(prefix: "conversation/")
                return previous.manifest.conversation
            }
            let oldMessages = Dictionary((previous?.project.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var records = [(id: String, bytes: Data)](), changed = Set<String>()
            for message in messages {
                let oldMessage = oldMessages[message.id], cached = old.messages[message.id]
                let encoded: Encoded<ProjectArchive.ArchivedMessage>
                if let cached, oldMessage == message { encoded = cached }
                else {
                    let reused = oldMessage.flatMap { old in cached.map { (old, $0.record) } }
                    let record = try ProjectArchive.ArchivedMessage(message, reusing: reused, writer: &writer)
                    encoded = Encoded(record: record, bytes: try encode(record))
                    changed.insert(message.id.uuidString)
                    metrics.encodedHistoryRecords += 1
                }
                sections.messages[message.id] = encoded
                records.append((message.id.uuidString, encoded.bytes))
            }
            sections.conversation = try chunks(records, changed: changed, directory: "conversation", prefix: "messages",
                                               old: old.conversation)
            return try index(ConversationIndex(chunks: sections.conversation.map(\.reference)), directory: "conversation",
                             old: previous?.manifest.conversation)
        }

        func activity(_ tasks: [ProjectTaskAudit]?) throws -> Reference {
            if let previous, current, tasks == previous.project.taskAudits {
                sections.tasks = old.tasks
                keepFiles(prefix: "activity/")
                return previous.manifest.activity
            }
            let oldTasks = Dictionary((previous?.project.taskAudits ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var references = [Reference]()
            for task in tasks ?? [] {
                let oldTask = oldTasks[task.id], cached = old.tasks[task.id]
                if let cached, let file = cached.file, oldTask == task {
                    sections.tasks[task.id] = cached
                    references.append(keep(file))
                    for chunk in cached.chunks { _ = keep(chunk.reference) }
                    continue
                }
                let oldEvents = Dictionary((oldTask?.events ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var events = [String: Encoded<ProjectArchive.ArchivedActivityEvent>]()
                var records = [(id: String, bytes: Data)](), changed = Set<String>()
                for event in task.events {
                    let oldEvent = oldEvents[event.id], cachedEvent = cached?.events[event.id]
                    let encoded: Encoded<ProjectArchive.ArchivedActivityEvent>
                    if let cachedEvent, oldEvent == event { encoded = cachedEvent }
                    else {
                        let reused = oldEvent.flatMap { old in cachedEvent.map { (old, $0.record) } }
                        let record = try ProjectArchive.ArchivedActivityEvent(event, reusing: reused, writer: &writer)
                        encoded = Encoded(record: record, bytes: try encode(record))
                        changed.insert(event.id)
                        metrics.encodedHistoryRecords += 1
                    }
                    events[event.id] = encoded
                    records.append((event.id, encoded.bytes))
                }
                let directory = "activity/\(task.id.uuidString)"
                let eventChunks = try chunks(records, changed: changed, directory: directory, prefix: "events",
                                             old: cached?.chunks ?? [])
                let reused = oldTask.flatMap { old in cached.map { (old, $0.task) } }
                let header = try ProjectArchive.ArchivedTask(task, reusing: reused, writer: &writer)
                metrics.encodedTaskRecords += 1
                let file = try store(encode(TaskRecord(task: header, eventChunks: eventChunks.map(\.reference))),
                                     directory: directory, prefix: "task")
                sections.tasks[task.id] = TaskRecords(task: header, file: file, events: events, chunks: eventChunks)
                references.append(file)
            }
            return try index(ActivityIndex(tasks: references), directory: "activity", old: previous?.manifest.activity)
        }

        /// The exact payloads the new sections and inline state refer to, from
        /// the previous commit or newly stored bytes.
        func assets(queue: [ProjectArchive.ArchivedQueuedRequest]?,
                    draftAttachments: [ProjectArchive.ArchivedAttachment]?) throws -> [String: Data] {
            var required = sections.assetKeys
            for request in queue ?? [] { required.formUnion(request.assetKeys) }
            for attachment in draftAttachments ?? [] { required.insert(attachment.contentAsset) }
            var assets = [String: Data](), total = 0
            for key in required {
                guard let bytes = writer.assets[key] ?? previous?.assets[key] else {
                    throw invalid("A saved asset reference is missing.")
                }
                guard bytes.count <= ProjectStore.maximumFileBytes - total else {
                    throw invalid("Saved assets exceed the design size limit.")
                }
                total += bytes.count
                assets[key] = bytes
            }
            return assets
        }

        func catalog(_ assets: [String: Data]) throws -> Reference {
            var descriptors = [String: AssetDescriptor](), changedBuckets = Set<String>()
            for (hash, bytes) in assets {
                let path = assetPath(hash)
                if let descriptor = old.catalog[hash], descriptor.byteCount == bytes.count, descriptor.path == path {
                    // These exact bytes already belong to the verified committed
                    // session. A transcript append need not stat every CAD input.
                    descriptors[hash] = descriptor
                } else {
                    let stored = try compressedAsset(bytes)
                    metrics.compressedAssets += 1
                    try writeImmutable(stored.bytes, path: path, in: url, verified: verified, directories: &directories)
                    descriptors[hash] = AssetDescriptor(path: path, sha256: hash, byteCount: bytes.count,
                                                        storedByteCount: stored.bytes.count, codec: stored.codec)
                    changedBuckets.insert(String(hash.prefix(2)))
                }
                files.insert(path)
            }
            for hash in old.catalog.keys where descriptors[hash] == nil { changedBuckets.insert(String(hash.prefix(2))) }
            var buckets = [String: Reference]()
            for (bucket, members) in Dictionary(grouping: descriptors, by: { String($0.key.prefix(2)) }) {
                if !changedBuckets.contains(bucket), let reference = old.catalogBuckets[bucket] {
                    buckets[bucket] = keep(reference)
                } else {
                    metrics.encodedCatalogBuckets += 1
                    let entries = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })
                    buckets[bucket] = try store(encode(entries), directory: "catalog", prefix: "assets-\(bucket)")
                }
            }
            sections.catalog = descriptors
            sections.catalogBuckets = buckets
            if buckets == old.catalogBuckets, let reference = previous?.manifest.catalog { return keep(reference) }
            return try index(CatalogIndex(buckets: buckets), directory: "catalog", old: previous?.manifest.catalog)
        }

        /// Presentation images are optional: unavailable thumbnail storage must
        /// not prevent saving the authoritative design.
        func thumbnail(_ thumbnail: Data?, identity: String) -> (reference: Thumbnail, bytes: Data)? {
            if let old = previous?.manifest.thumbnail, sections.catalog[old.sha256] == nil { files.remove(old.path) }
            func retain(_ bytes: Data, _ reference: Thumbnail) -> (reference: Thumbnail, bytes: Data)? {
                if (try? requireRegularFile(reference.path, in: url)) == nil {
                    guard (try? writeImmutable(bytes, path: reference.path, in: url, verified: verified,
                                               directories: &directories)) != nil else { return nil }
                }
                files.insert(reference.path)
                return (reference, bytes)
            }
            if let thumbnail {
                if thumbnail == previous?.project.thumbnailData, let reference = previous?.manifest.thumbnail {
                    if let retained = retain(thumbnail, reference) { return retained }
                } else {
                    metrics.thumbnailValidations += 1
                    if validThumbnail(thumbnail) {
                        let hash = SHA256.hexDigest(thumbnail)
                        if let retained = retain(thumbnail, Thumbnail(path: assetPath(hash), sha256: hash, byteCount: thumbnail.count)) {
                            return retained
                        }
                    }
                }
            }
            if previous?.thumbnailIdentity == identity, let reference = previous?.manifest.thumbnail,
               let bytes = previous?.project.thumbnailData {
                return retain(bytes, reference)
            }
            return nil
        }
    }

    /// Tests and one-time development conversion can discard process caches.
    static func clearSessionCache() {
        cacheLock.lock()
        let discarded = sessions
        sessions = [:]
        sessionOrder = []
        cacheLock.unlock()
        // Releasing a large parsed history is not shared-cache bookkeeping.
        withExtendedLifetime(discarded) {}
    }

    // MARK: - Reading

    /// Reads committed section files, checking their names, hashes and sizes
    /// against the aggregate metadata limit.
    private struct SectionReader {
        let url: URL
        var metadataBytes: Int
        var files = Set<String>()

        mutating func data(_ reference: Reference, prefix: String) throws -> Data {
            let path = reference.path, hash = reference.sha256
            guard path.hasPrefix(prefix), validHash(hash) else { throw invalid("A design record reference is invalid.") }
            if isIndexSlot(path) {
                guard path == "\(prefix)1.json" || path == "\(prefix)2.json" else { throw invalid("An index slot is invalid.") }
            } else {
                guard path.hasSuffix("-\(hash).json") else { throw invalid("A record filename has an inconsistent hash.") }
            }
            let bytes = try readFile(path, in: url, limit: min(maximumMetadataRecordBytes, maximumMetadataBytes - metadataBytes))
            metadataBytes += bytes.count
            guard metadataBytes <= maximumMetadataBytes else { throw invalid("The design metadata exceeds its size limit.") }
            guard SHA256.hexDigest(bytes) == hash else { throw invalid("A saved design record failed its integrity check.") }
            files.insert(path)
            return bytes
        }

        mutating func record<Record: Decodable>(_ type: Record.Type, _ reference: Reference, prefix: String) throws -> Record {
            try decode(type, from: data(reference, prefix: prefix))
        }

        mutating func chunks<Record: Decodable>(_ type: Record.Type, _ references: [Reference], prefix: String,
                                                id: (Record) -> String) throws -> (records: [Record], chunks: [Chunk]) {
            guard references.count <= 100_000 else { throw invalid("A design chunk list is invalid.") }
            var records = [Record](), chunks = [Chunk]()
            for reference in references {
                let chunk = try record([Record].self, reference, prefix: prefix)
                guard chunk.count <= maximumChunkRecords else { throw invalid("A design chunk is invalid.") }
                records.append(contentsOf: chunk)
                chunks.append(Chunk(reference: reference, recordIDs: chunk.map(id)))
                guard records.count <= 100_000 else { throw invalid("A design chunk collection is too large.") }
            }
            return (records, chunks)
        }
    }

    private static func load(_ url: URL, caching: Bool) throws -> Session {
        try requirePackage(url)
        let data = try readFile("project.json", in: url, limit: maximumRootBytes)
        let manifest = try decode(Manifest.self, from: data)
        guard readableFormatVersions.contains(manifest.formatVersion), manifest.commitID != nil else {
            throw invalid("Unsupported design package format.")
        }
        var reader = SectionReader(url: url, metadataBytes: data.count)
        var sections = Sections()

        let revisionIndex = try reader.record(RevisionIndex.self, manifest.revisions, prefix: "revisions/index-")
        guard revisionIndex.entries.count <= 1_000 else { throw invalid("The version index is invalid.") }
        var revisions = [ProjectArchive.ArchivedRevision]()
        for entry in revisionIndex.entries {
            let directory = "revisions/\(entry.id.uuidString)"
            let recipe = try reader.record(ProjectArchive.ArchivedRecipe.self, entry.recipe, prefix: "\(directory)/recipe-")
            guard recipe.id == entry.id else { throw invalid("A version record has a mismatched identity.") }
            let parts = try reader.record(PartsRecord.self, entry.parts, prefix: "\(directory)/parts-").parts
            revisions.append(ProjectArchive.ArchivedRevision(recipe: recipe, parts: parts, name: entry.name))
            sections.revisions[entry.id] = RevisionRecords(recipe: recipe, recipeFile: entry.recipe, parts: parts, partsFile: entry.parts)
        }

        let conversation = try reader.record(ConversationIndex.self, manifest.conversation, prefix: "conversation/index-")
        let messages = try reader.chunks(ProjectArchive.ArchivedMessage.self, conversation.chunks,
                                         prefix: "conversation/messages-", id: \.id.uuidString)
        sections.conversation = messages.chunks

        let activity = try reader.record(ActivityIndex.self, manifest.activity, prefix: "activity/index-")
        guard activity.tasks.count <= 10_000 else { throw invalid("The activity index is invalid.") }
        var tasks = [ProjectArchive.ArchivedTaskAudit](), eventCount = 0
        for reference in activity.tasks {
            let task = try reader.record(TaskRecord.self, reference, prefix: "activity/")
            let directory = "activity/\(task.task.id.uuidString)"
            guard reference.path.hasPrefix("\(directory)/task-") else { throw invalid("A task identity is invalid.") }
            let events = try reader.chunks(ProjectArchive.ArchivedActivityEvent.self, task.eventChunks,
                                           prefix: "\(directory)/events-", id: \.id)
            eventCount += events.records.count
            guard eventCount <= 100_000 else { throw invalid("The activity history is too large.") }
            tasks.append(ProjectArchive.ArchivedTaskAudit(task: task.task, events: events.records))
            sections.tasks[task.task.id] = TaskRecords(task: task.task, file: reference, events: [:], chunks: events.chunks)
        }

        let descriptors: [String: AssetDescriptor]
        if manifest.formatVersion == inlineCatalogFormatVersion {
            guard manifest.catalog == nil, let inline = manifest.assets else { throw invalid("The asset catalog is invalid.") }
            descriptors = inline
        } else {
            guard manifest.assets == nil, let catalog = manifest.catalog else { throw invalid("The asset catalog is invalid.") }
            let index = try reader.record(CatalogIndex.self, catalog, prefix: "catalog/index-")
            guard index.buckets.count <= 256 else { throw invalid("The asset catalog is invalid.") }
            var merged = [String: AssetDescriptor]()
            for (bucket, reference) in index.buckets {
                guard bucket.utf8.count == 2, bucket.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw invalid("The asset catalog is invalid.")
                }
                for (hash, descriptor) in try reader.record([String: AssetDescriptor].self, reference, prefix: "catalog/assets-\(bucket)-") {
                    guard hash.hasPrefix(bucket), merged[hash] == nil else { throw invalid("The asset catalog is invalid.") }
                    merged[hash] = descriptor
                }
                sections.catalogBuckets[bucket] = reference
            }
            descriptors = merged
        }
        var assets = [String: Data](), total = 0
        for (hash, descriptor) in descriptors {
            guard validHash(hash), descriptor.sha256 == hash, descriptor.path == assetPath(hash),
                  (0...ProjectStore.maximumFileBytes).contains(descriptor.byteCount),
                  (0...ProjectStore.maximumFileBytes).contains(descriptor.storedByteCount) else {
                throw invalid("A saved asset descriptor is invalid.")
            }
            guard descriptor.byteCount <= ProjectStore.maximumFileBytes - total else { throw invalid("Saved assets exceed the design size limit.") }
            total += descriptor.byteCount
            let stored = try readFile(descriptor.path, in: url, limit: descriptor.storedByteCount)
            guard stored.count == descriptor.storedByteCount else { throw invalid("A saved asset has an inconsistent size.") }
            let bytes = try expandedAsset(stored, codec: descriptor.codec, byteCount: descriptor.byteCount)
            guard SHA256.hexDigest(bytes) == hash else { throw invalid("A saved file asset failed its integrity check.") }
            assets[hash] = bytes
            reader.files.insert(descriptor.path)
        }
        sections.catalog = descriptors

        let document = ProjectArchive.Document(
            formatVersion: ProjectArchive.formatVersion, messages: messages.records, revisions: revisions,
            selectedRevisionID: manifest.selectedRevisionID, projectID: manifest.projectID, codexSettings: manifest.codexSettings,
            projectName: manifest.projectName, showGrid: manifest.showGrid, projectionMode: manifest.projectionMode,
            displayMode: manifest.displayMode, partsPaneFraction: manifest.partsPaneFraction,
            recentPartColors: manifest.recentPartColors, taskAudits: tasks.isEmpty ? nil : tasks,
            queuedRequests: manifest.queuedRequests, draftPrompt: manifest.draftPrompt,
            draftAttachments: manifest.draftAttachments, queuePaused: manifest.queuePaused, assets: assets)
        var project = try ProjectArchive.restore(document, verifiedAssets: true)
        var verified = [String: Data]()
        try ProjectStore.validate(project, verifiedAttachmentPayloads: &verified)
        project.fileOrigin = ProjectFileOrigin(url: url, data: data)
        // Canonical record bytes rebuild a chunk once one of its records changes.
        for message in messages.records { sections.messages[message.id] = Encoded(record: message, bytes: try encode(message)) }
        for task in tasks {
            for event in task.events {
                sections.tasks[task.task.id]?.events[event.id] = Encoded(record: event, bytes: try encode(event))
            }
        }

        var thumbnailIdentity: String?
        if let thumbnail = manifest.thumbnail, validHash(thumbnail.sha256), thumbnail.path == assetPath(thumbnail.sha256) {
            let identity = ThumbnailIdentity(manifest.selectedRevisionID.flatMap { sections.revisions[$0] },
                                             displayMode: manifest.displayMode, projectionMode: manifest.projectionMode)
            let stored = try? (manifest.formatVersion == formatVersion ? identity.digest : identity.legacyDigest)
            if stored != nil, manifest.thumbnailIdentity == stored,
               let bytes = try? readFile(thumbnail.path, in: url, limit: 8_000_000),
               validThumbnail(bytes), SHA256.hexDigest(bytes) == thumbnail.sha256 {
                project.thumbnailData = bytes
                reader.files.insert(thumbnail.path)
                thumbnailIdentity = try identity.digest
            }
        }
        let session = Session(project: project, manifest: manifest, rootData: data, assets: assets, files: reader.files,
                              verifiedAttachments: verified, sections: sections, thumbnailIdentity: thumbnailIdentity)
        if caching { remember(session, key: sessionKey(url)) }
        return session
    }

    // MARK: - Comparison

    private static func inlineProject(_ project: LADProject) -> LADProject {
        var state = project
        state.messages = []; state.revisions = []; state.taskAudits = nil; state.selectedRevisionID = nil
        return state
    }

    private static func sameQueuedAttachments(_ lhs: [ProjectQueuedRequest]?, _ rhs: [ProjectQueuedRequest]?) -> Bool {
        if lhs == rhs { return true }
        let old = Dictionary(uniqueKeysWithValues: (rhs ?? []).compactMap { request in
            request.attachments?.isEmpty == false ? (request.id, request.attachments!) : nil
        })
        let current = (lhs ?? []).filter { $0.attachments?.isEmpty == false }
        return old.count == current.count && current.allSatisfy { old[$0.id] == $0.attachments }
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
            if result.revisions[index].preview != nil { result.revisions[index].preview = nil }
        }
        return result
    }

    private static func sameRevisions(_ lhs: [ProjectRevision], _ rhs: [ProjectRevision]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(sameRevision)
    }

    private static func sameRecipe(_ lhs: ProjectRevision, _ rhs: ProjectRevision) -> Bool {
        lhs.id == rhs.id && lhs.model == rhs.model && lhs.date == rhs.date && lhs.runtime == rhs.runtime &&
        lhs.userMessageID == rhs.userMessageID && lhs.responseMessageID == rhs.responseMessageID && lhs.validatedHash == rhs.validatedHash
    }

    private static func sameParts(_ lhs: ProjectRevision, _ rhs: ProjectRevision) -> Bool {
        lhs.partLayout == rhs.partLayout && lhs.hiddenSolids == rhs.hiddenSolids && lhs.parts == rhs.parts && lhs.partColors == rhs.partColors && lhs.jointPositions == rhs.jointPositions
    }

    private static func sameHistory(_ lhs: LADProject, _ rhs: LADProject) -> Bool {
        lhs.messages == rhs.messages && lhs.taskAudits == rhs.taskAudits && lhs.revisions.count == rhs.revisions.count &&
            zip(lhs.revisions, rhs.revisions).allSatisfy(sameRevision)
    }

    static func sameRevision(_ lhs: ProjectRevision, _ rhs: ProjectRevision) -> Bool {
        lhs.id == rhs.id && lhs.model == rhs.model && lhs.date == rhs.date && lhs.partLayout == rhs.partLayout &&
        lhs.hiddenSolids == rhs.hiddenSolids && lhs.parts == rhs.parts && lhs.runtime == rhs.runtime &&
        lhs.userMessageID == rhs.userMessageID && lhs.responseMessageID == rhs.responseMessageID &&
        lhs.partColors == rhs.partColors && lhs.jointPositions == rhs.jointPositions && lhs.name == rhs.name && lhs.validatedHash == rhs.validatedHash
    }

    // MARK: - Files

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
        var evicted = [Session]()
        cacheLock.lock()
        let replaced = sessions.updateValue(session, forKey: key)
        sessionOrder.removeAll { $0 == key }
        sessionOrder.append(key)
        while sessionOrder.count > maximumCachedSessions {
            if let oldest = sessions.removeValue(forKey: sessionOrder.removeFirst()) { evicted.append(oldest) }
        }
        cacheLock.unlock()
        // Releasing a large parsed history is not shared-cache bookkeeping.
        withExtendedLifetime((evicted, replaced)) {}
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

    /// The one encoder for every package file. Sorted keys make each record's
    /// bytes, and therefore its content hash, a function of its value.
    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch is DecodingError { throw invalid("A design metadata record is invalid.") }
    }

    private static func invalid(_ reason: String) -> LADError { .message("Invalid LAD design. \(reason)") }
}
