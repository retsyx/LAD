import CryptoKit
import Foundation

/// The on-disk representation stores each exact file payload once, regardless
/// of how many messages or revisions refer to it. Generated geometry is rebuilt
/// from the saved CAD program and never belongs to the archive.
enum ProjectArchive {
    static let formatVersion = 4
    private static let maximumAssetCount = 32_768
    private static let maximumAssetBytes = ProjectStore.maximumFileBytes

    static func encode(_ project: LADProject) throws -> Data {
        var writer = AssetWriter()
        let messages = try project.messages.map { try ArchivedMessage($0, writer: &writer) }
        let revisions = try project.revisions.map { try ArchivedRevision($0, writer: &writer) }
        let taskAudits = try project.taskAudits?.map { try ArchivedTaskAudit($0, writer: &writer) }
        let queuedRequests = try project.queuedRequests?.map { try ArchivedQueuedRequest($0, writer: &writer) }
        let draftAttachments = try project.draftAttachments?.map { try ArchivedAttachment($0, writer: &writer) }
        let archive = Document(formatVersion: formatVersion, messages: messages,
                               revisions: revisions, selectedRevisionID: project.selectedRevisionID,
                               projectID: project.projectID, codexSettings: project.codexSettings,
                               projectName: project.projectName, showGrid: project.showGrid,
                               projectionMode: project.projectionMode, displayMode: project.displayMode,
                               partsPaneFraction: project.partsPaneFraction,
                               recentPartColors: project.recentPartColors, taskAudits: taskAudits,
                               queuedRequests: queuedRequests, draftPrompt: project.draftPrompt,
                               draftAttachments: draftAttachments, queuePaused: project.queuePaused, assets: writer.assets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= ProjectStore.maximumFileBytes else {
            throw invalid("File exceeds the 1,024 MB design limit.")
        }
        return data
    }

    static func decode(_ data: Data) throws -> LADProject {
        guard data.count <= ProjectStore.maximumFileBytes else {
            throw invalid("File exceeds the 1,024 MB design limit.")
        }
        let archive = try JSONDecoder().decode(Document.self, from: data)
        guard archive.formatVersion == formatVersion else {
            throw invalid("Unsupported format version \(archive.formatVersion).")
        }
        guard archive.messages.count <= 10_000, archive.revisions.count <= 1_000,
              (archive.queuedRequests?.count ?? 0) <= 10_000,
              (archive.draftAttachments?.count ?? 0) <= SourceImport.maximumAttachmentCount,
              archive.revisions.allSatisfy({ ($0.inputAssets?.count ?? 0) <= 256 }) else {
            throw invalid("Design contains too many revisions or messages.")
        }
        if let tasks = archive.taskAudits {
            guard tasks.count <= 10_000 else { throw invalid("Tool activity contains too many tasks.") }
            var events = 0
            for task in tasks {
                guard task.events.count <= 100_000 - events,
                      task.events.allSatisfy({ ($0.files?.count ?? 0) <= 64 }) else { throw invalid("Tool activity contains too many events or source snapshots.") }
                events += task.events.count
            }
        }
        var reader = try AssetReader(assets: archive.assets)
        let messages = try archive.messages.map { try $0.restored(reader: &reader) }
        let revisions = try archive.revisions.map { try $0.restored(reader: &reader) }
        let taskAudits = try archive.taskAudits?.map { try $0.restored(reader: &reader) }
        let queuedRequests = try archive.queuedRequests?.map { try $0.restored(reader: &reader) }
        let draftAttachments = try archive.draftAttachments?.map { try $0.restored(reader: &reader) }
        guard reader.usedAssets.count == archive.assets.count else {
            throw invalid("The design contains an unreferenced file asset.")
        }
        // The application uses its existing in-memory model. The disk format
        // version describes this archive, not the runtime snapshot structure.
        return LADProject(formatVersion: 1, messages: messages, revisions: revisions,
                          selectedRevisionID: archive.selectedRevisionID, projectID: archive.projectID,
                          codexSettings: archive.codexSettings, projectName: archive.projectName,
                          showGrid: archive.showGrid, projectionMode: archive.projectionMode,
                          displayMode: archive.displayMode, recentPartColors: archive.recentPartColors,
                          taskAudits: taskAudits, queuedRequests: queuedRequests,
                          draftPrompt: archive.draftPrompt, draftAttachments: draftAttachments,
                          queuePaused: archive.queuePaused, partsPaneFraction: archive.partsPaneFraction ?? 0.75)
    }

    private struct Document: Codable {
        var formatVersion: Int
        var messages: [ArchivedMessage]
        var revisions: [ArchivedRevision]
        var selectedRevisionID: UUID?
        var projectID: UUID?
        var codexSettings: CodexProjectSettings?
        var projectName: String?
        var showGrid: Bool?
        var projectionMode: ViewportProjectionMode?
        var displayMode: ViewportDisplayMode?
        var partsPaneFraction: Double?
        var recentPartColors: [PartColor]?
        var taskAudits: [ArchivedTaskAudit]?
        var queuedRequests: [ArchivedQueuedRequest]?
        var draftPrompt: String?
        var draftAttachments: [ArchivedAttachment]?
        var queuePaused: Bool?
        var assets: [String: Data]
    }

    private struct ArchivedTaskAudit: Codable {
        var id: UUID
        var userMessageID: UUID
        var startedAt: Date
        var finishedAt: Date?
        var model: String
        var reasoningEffort: String
        var status: String
        var events: [ArchivedActivityEvent]
        var additionalUserMessageIDs: [UUID]?

        init(_ task: ProjectTaskAudit, writer: inout AssetWriter) throws {
            id = task.id; userMessageID = task.userMessageID
            startedAt = task.startedAt; finishedAt = task.finishedAt
            model = task.model; reasoningEffort = task.reasoningEffort; status = task.status
            events = try task.events.map { try ArchivedActivityEvent($0, writer: &writer) }
            additionalUserMessageIDs = task.additionalUserMessageIDs
        }

        func restored(reader: inout AssetReader) throws -> ProjectTaskAudit {
            ProjectTaskAudit(id: id, userMessageID: userMessageID, startedAt: startedAt, finishedAt: finishedAt,
                             model: model, reasoningEffort: reasoningEffort, status: status,
                             events: try events.map { try $0.restored(reader: &reader) },
                             additionalUserMessageIDs: additionalUserMessageIDs)
        }
    }

    private struct ArchivedQueuedRequest: Codable {
        var id: UUID
        var content: String
        var date: Date
        var attachments: [ArchivedAttachment]?
        var codexSettings: CodexProjectSettings?
        var capturedSourcePaths: [String]?
        var selection: ProjectSelectionContext?

        init(_ request: ProjectQueuedRequest, writer: inout AssetWriter) throws {
            id = request.id; content = request.content; date = request.date
            attachments = try request.attachments?.map { try ArchivedAttachment($0, writer: &writer) }
            codexSettings = request.codexSettings
            capturedSourcePaths = request.capturedSourcePaths
            selection = request.selection
        }

        func restored(reader: inout AssetReader) throws -> ProjectQueuedRequest {
            ProjectQueuedRequest(id: id, content: content, date: date,
                attachments: try attachments?.map { try $0.restored(reader: &reader) }, codexSettings: codexSettings,
                capturedSourcePaths: capturedSourcePaths, selection: selection)
        }
    }

    private struct ArchivedActivityEvent: Codable {
        var id: String
        var date: Date
        var category: String
        var title: String
        var status: String
        var inputAsset: String?
        var outputAsset: String?
        var durationSeconds: Double?
        var files: [ArchivedActivityFile]?

        init(_ event: ProjectActivityEvent, writer: inout AssetWriter) throws {
            id = event.id; date = event.date; category = event.category
            title = event.title; status = event.status; durationSeconds = event.durationSeconds
            inputAsset = try event.input.map { try writer.store(Data($0.utf8), role: .activity) }
            outputAsset = try event.output.map { try writer.store(Data($0.utf8), role: .activity) }
            files = try event.files?.map { try ArchivedActivityFile($0, writer: &writer) }
        }

        private enum CodingKeys: String, CodingKey {
            case id, date, category, title, status, inputAsset, outputAsset, durationSeconds, files
        }

        init(from decoder: Decoder) throws {
            try rejectFields(["input", "output", "image", "imageData", "preview", "stepData", "brepData"], in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            date = try values.decode(Date.self, forKey: .date)
            category = try values.decode(String.self, forKey: .category)
            title = try values.decode(String.self, forKey: .title)
            status = try values.decode(String.self, forKey: .status)
            inputAsset = try values.decodeIfPresent(String.self, forKey: .inputAsset)
            outputAsset = try values.decodeIfPresent(String.self, forKey: .outputAsset)
            durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
            files = try values.decodeIfPresent([ArchivedActivityFile].self, forKey: .files)
        }

        func restored(reader: inout AssetReader) throws -> ProjectActivityEvent {
            ProjectActivityEvent(id: id, date: date, category: category, title: title, status: status,
                                 input: try inputAsset.map { try reader.text($0, role: .activity) },
                                 output: try outputAsset.map { try reader.text($0, role: .activity) },
                                 durationSeconds: durationSeconds,
                                 files: try files?.map { try $0.restored(reader: &reader) })
        }
    }

    private struct ArchivedActivityFile: Codable {
        var name: String
        var path: String
        var dataAsset: String

        init(_ file: ProjectActivityFile, writer: inout AssetWriter) throws {
            name = file.name; path = file.path
            dataAsset = try writer.store(file.data, role: .activityFile)
        }

        private enum CodingKeys: String, CodingKey { case name, path, dataAsset }

        init(from decoder: Decoder) throws {
            try rejectFields(["data", "content", "preview", "image", "topology"], in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            path = try values.decode(String.self, forKey: .path)
            dataAsset = try values.decode(String.self, forKey: .dataAsset)
        }

        func restored(reader: inout AssetReader) throws -> ProjectActivityFile {
            ProjectActivityFile(name: name, path: path, data: try reader.data(dataAsset, role: .activityFile))
        }
    }

    private struct ArchivedInputAsset: Codable {
        var id: String
        var name: String
        var format: String
        var dataAsset: String

        init(_ asset: CADInputAsset, writer: inout AssetWriter) throws {
            id = asset.id; name = asset.name; format = asset.format
            dataAsset = try writer.store(asset.data, role: .input)
        }

        private enum CodingKeys: String, CodingKey { case id, name, format, dataAsset }

        init(from decoder: Decoder) throws {
            try rejectFields(["data", "content", "preview", "topology"], in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            format = try values.decode(String.self, forKey: .format)
            dataAsset = try values.decode(String.self, forKey: .dataAsset)
        }

        func restored(reader: inout AssetReader) throws -> CADInputAsset {
            CADInputAsset(id: id, name: name, format: format, data: try reader.data(dataAsset, role: .input))
        }
    }

    private struct ArchivedMessage: Codable {
        var id: UUID
        var role: String
        var content: String
        var date: Date
        var attachments: [ArchivedAttachment]?
        var phase: String?
        var selection: ProjectSelectionContext?

        init(_ message: ChatMessage, writer: inout AssetWriter) throws {
            id = message.id
            role = message.role
            content = message.content
            date = message.date
            attachments = try message.attachments?.map { try ArchivedAttachment($0, writer: &writer) }
            phase = message.phase
            selection = message.selection
        }

        func restored(reader: inout AssetReader) throws -> ChatMessage {
            let sources = try attachments?.map { try $0.restored(reader: &reader) }
            return ChatMessage(id: id, role: role, content: content, date: date, attachments: sources, phase: phase, selection: selection)
        }
    }

    private struct ArchivedAttachment: Codable {
        var id: UUID
        var name: String
        var path: String
        var sha256: String
        var contentAsset: String
        var kind: String?

        init(_ attachment: SourceAttachment, writer: inout AssetWriter) throws {
            id = attachment.id
            name = attachment.name
            path = attachment.path
            sha256 = attachment.sha256
            kind = attachment.isImage ? "image" : nil
            contentAsset = try writer.store(attachment.data, role: attachment.isImage ? .image : .attachment)
            guard sha256 == contentAsset else {
                throw invalid("An attached source file failed its integrity check.")
            }
        }

        private enum CodingKeys: String, CodingKey { case id, name, path, sha256, contentAsset, kind }

        init(from decoder: Decoder) throws {
            try rejectFields(["content", "imageData"], in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            path = try values.decode(String.self, forKey: .path)
            sha256 = try values.decode(String.self, forKey: .sha256)
            contentAsset = try values.decode(String.self, forKey: .contentAsset)
            kind = try values.decodeIfPresent(String.self, forKey: .kind)
            guard kind == nil || kind == "image" else { throw invalid("An attachment has an unsupported payload kind.") }
        }

        func restored(reader: inout AssetReader) throws -> SourceAttachment {
            guard sha256 == contentAsset else {
                throw invalid("An attached source file has an inconsistent file reference.")
            }
            if kind == "image" {
                let data = try reader.data(contentAsset, role: .image)
                return SourceAttachment(id: id, name: name, path: path, content: "", sha256: sha256, imageData: data)
            }
            let content = try reader.text(contentAsset, role: .attachment)
            return SourceAttachment(id: id, name: name, path: path, content: content, sha256: sha256)
        }
    }

    private struct ArchivedModel: Codable {
        var title: String
        var summary: String
        var units: String
        var sourceName: String?
        var reorganizePartIDs: [String]?

        init(_ model: ModelSpec) {
            title = model.title
            summary = model.summary
            units = model.units
            sourceName = model.sourceName
            reorganizePartIDs = model.reorganizePartIDs
        }

        private enum CodingKeys: String, CodingKey {
            case title, summary, units, sourceName, reorganizePartIDs
        }

        init(from decoder: Decoder) throws {
            try rejectFields(["nodes", "result", "script", "sourceSTEP", "inputAssets"], in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decode(String.self, forKey: .title)
            summary = try values.decode(String.self, forKey: .summary)
            units = try values.decode(String.self, forKey: .units)
            sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName)
            reorganizePartIDs = try values.decodeIfPresent([String].self, forKey: .reorganizePartIDs)
        }
    }

    private struct ArchivedRevision: Codable {
        var id: UUID
        var model: ArchivedModel
        var date: Date
        var sourceSTEPAsset: String?
        var scriptAsset: String
        var inputAssets: [ArchivedInputAsset]?
        var parts: [PartNode]?
        var partLayout: PartLayout?
        var hiddenSolids: [Int]?
        var runtime: CADRuntime?
        var userMessageID: UUID?
        var responseMessageID: UUID?
        var partColors: [String: PartColor]?
        var name: String?
        var validatedHash: String?

        init(_ revision: ProjectRevision, writer: inout AssetWriter) throws {
            id = revision.id
            model = ArchivedModel(revision.model)
            date = revision.date
            sourceSTEPAsset = try revision.model.sourceSTEP.map { try writer.store($0, role: .step) }
            scriptAsset = try writer.store(Data(revision.model.script.utf8), role: .script)
            inputAssets = try revision.model.inputAssets?.map { try ArchivedInputAsset($0, writer: &writer) }
            if let semanticParts = revision.parts ?? revision.preview?.parts {
                parts = semanticParts
            } else if let preview = revision.preview {
                guard (0...4_096).contains(preview.solids) else {
                    throw invalid("The saved design contains too many solids.")
                }
                parts = (0..<preview.solids).map {
                    PartNode(id: "solid/\($0)", name: "Part \($0 + 1)", solidIndices: [$0])
                }
            }
            partLayout = revision.partLayout ?? parts.map { PartLayout(nodes: $0) }
            hiddenSolids = revision.hiddenSolids
            runtime = revision.runtime
            userMessageID = revision.userMessageID
            responseMessageID = revision.responseMessageID
            partColors = revision.partColors
            name = revision.name
            validatedHash = revision.validatedHash
        }

        private enum CodingKeys: String, CodingKey {
            case id, model, date, sourceSTEPAsset, scriptAsset, parts, partLayout, hiddenSolids, runtime
            case userMessageID, responseMessageID, partColors, name
            case inputAssets
            case validatedHash = "validated_hash"
        }

        init(from decoder: Decoder) throws {
            try rejectFields(["preview", "stepData", "stepAsset"], in: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            model = try values.decode(ArchivedModel.self, forKey: .model)
            date = try values.decode(Date.self, forKey: .date)
            sourceSTEPAsset = try values.decodeIfPresent(String.self, forKey: .sourceSTEPAsset)
            scriptAsset = try values.decode(String.self, forKey: .scriptAsset)
            inputAssets = try values.decodeIfPresent([ArchivedInputAsset].self, forKey: .inputAssets)
            parts = try values.decodeIfPresent([PartNode].self, forKey: .parts)
            partLayout = try values.decodeIfPresent(PartLayout.self, forKey: .partLayout)
            hiddenSolids = try values.decodeIfPresent([Int].self, forKey: .hiddenSolids)
            runtime = try values.decodeIfPresent(CADRuntime.self, forKey: .runtime)
            userMessageID = try values.decodeIfPresent(UUID.self, forKey: .userMessageID)
            responseMessageID = try values.decodeIfPresent(UUID.self, forKey: .responseMessageID)
            partColors = try values.decodeIfPresent([String: PartColor].self, forKey: .partColors)
            name = try values.decodeIfPresent(String.self, forKey: .name)
            validatedHash = try values.decodeIfPresent(String.self, forKey: .validatedHash)
        }

        func restored(reader: inout AssetReader) throws -> ProjectRevision {
            let restoredModel = ModelSpec(title: model.title, summary: model.summary, units: model.units,
                                          script: try reader.text(scriptAsset, role: .script),
                                          sourceSTEP: try sourceSTEPAsset.map { try reader.data($0, role: .step) },
                                          sourceName: model.sourceName, reorganizePartIDs: model.reorganizePartIDs,
                                          inputAssets: try inputAssets?.map { try $0.restored(reader: &reader) })
            var revision = ProjectRevision(id: id, model: restoredModel, date: date,
                                          preview: nil, stepData: nil, partLayout: partLayout,
                                          hiddenSolids: hiddenSolids)
            revision.parts = parts
            revision.runtime = runtime
            revision.userMessageID = userMessageID
            revision.responseMessageID = responseMessageID
            revision.partColors = partColors
            revision.name = name
            revision.validatedHash = validatedHash
            return revision
        }
    }

    private enum AssetRole: Equatable {
        case attachment, image, script, step, input, activity, activityFile

        var maximumBytes: Int {
            switch self {
            case .attachment: return SourceImport.maximumFileBytes
            case .image: return SourceImport.maximumImageFileBytes
            case .script: return 200_000
            case .step: return ProjectStore.maximumSTEPBytes
            case .input: return ProjectStore.maximumSTEPBytes
            case .activity: return ProjectStore.maximumActivityTextBytes
            case .activityFile: return ProjectActivityFile.maximumBytes
            }
        }
    }

    private struct AssetWriter {
        var assets: [String: Data] = [:]
        private var totalAssetBytes = 0

        mutating func store(_ bytes: Data, role: AssetRole) throws -> String {
            try validateSize(bytes.count, role: role)
            let key = digest(bytes)
            if let existing = assets[key] {
                guard existing == bytes else { throw invalid("File assets have conflicting integrity hashes.") }
            } else {
                guard assets.count < maximumAssetCount else { throw invalid("The design contains too many file assets.") }
                try addBytes(bytes.count, to: &totalAssetBytes, limit: maximumAssetBytes)
                assets[key] = bytes
            }
            return key
        }
    }

    private struct AssetReader {
        var assets: [String: Data]
        var usedAssets: Set<String> = []
        private var decodedText: [String: String] = [:]

        init(assets: [String: Data]) throws {
            guard assets.count <= maximumAssetCount else { throw invalid("The design contains too many file assets.") }
            var total = 0
            for (key, bytes) in assets {
                try addBytes(bytes.count, to: &total, limit: maximumAssetBytes)
                guard validKey(key), digest(bytes) == key else {
                    throw invalid("A saved file asset failed its integrity check.")
                }
            }
            self.assets = assets
        }

        mutating func data(_ key: String, role: AssetRole) throws -> Data {
            guard validKey(key), let bytes = assets[key] else {
                throw invalid("A saved file reference is invalid or missing.")
            }
            try validateSize(bytes.count, role: role)
            usedAssets.insert(key)
            return bytes
        }

        mutating func text(_ key: String, role: AssetRole) throws -> String {
            let bytes = try data(key, role: role)
            // Validate each reference's role, but decode shared text once.
            // Data and String then retain copy-on-write storage across history.
            if let cached = decodedText[key] { return cached }
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw invalid("A saved source file is not valid UTF-8 text.")
            }
            decodedText[key] = text
            return text
        }
    }

    private static func validateSize(_ count: Int, role: AssetRole) throws {
        guard (count > 0 || role == .activity || role == .activityFile), count <= role.maximumBytes else {
            throw invalid("A saved file asset is empty or exceeds its size limit.")
        }
    }

    private static func addBytes(_ count: Int, to total: inout Int, limit: Int) throws {
        guard count <= limit - total else { throw invalid("Saved file assets exceed the 1,024 MB design limit.") }
        total += count
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validKey(_ key: String) -> Bool {
        let bytes = key.utf8
        return bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private struct FieldKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func rejectFields(_ names: [String], in decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: FieldKey.self)
        guard !names.contains(where: { values.contains(FieldKey(stringValue: $0)) }) else {
            throw invalid("This design contains inline file or display data instead of asset references.")
        }
    }

    private static func invalid(_ reason: String) -> LADError { .message("Invalid LAD design. \(reason)") }
}
