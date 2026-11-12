import CryptoKit
import Foundation

/// The on-disk representation stores each exact file payload once, regardless
/// of how many messages or revisions refer to it. Generated geometry is rebuilt
/// from the saved CAD program and never belongs to the archive. Design packages
/// store these same typed records in their sections.
enum ProjectArchive {
    static let formatVersion = 4
    private static let maximumAssetBytes = ProjectStore.maximumFileBytes

    struct Snapshot {
        var metadata: Data
        var assets: [String: Data]
    }

    /// Separate metadata from exact asset bytes without ever base64-encoding them.
    static func split(_ project: LADProject) throws -> Snapshot {
        var archive = try document(project)
        let assets = archive.assets
        archive.assets = [:]
        return Snapshot(metadata: try encoder().encode(archive), assets: assets)
    }

    static func encode(_ project: LADProject) throws -> Data {
        let data = try encoder().encode(document(project))
        guard data.count <= ProjectStore.maximumFileBytes else {
            throw invalid("File exceeds the 1,024 MB design limit.")
        }
        return data
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func document(_ project: LADProject) throws -> Document {
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
        return archive
    }

    static func decode(_ data: Data) throws -> LADProject {
        guard data.count <= ProjectStore.maximumFileBytes else {
            throw invalid("File exceeds the 1,024 MB design limit.")
        }
        return try restore(JSONDecoder().decode(Document.self, from: data))
    }

    /// Restores the application model with the archive's history limits, asset
    /// roles and reference checks. Package readers have already verified each
    /// asset's bytes against its hash.
    static func restore(_ archive: Document, verifiedAssets: Bool = false) throws -> LADProject {
        guard archive.formatVersion == formatVersion else {
            throw invalid("Unsupported format version \(archive.formatVersion).")
        }
        guard archive.messages.count <= 10_000, archive.revisions.count <= 1_000,
              (archive.queuedRequests?.count ?? 0) <= 10_000,
              (archive.draftAttachments?.count ?? 0) <= SourceImport.maximumAttachmentCount,
              archive.revisions.allSatisfy({ ($0.recipe.inputAssets?.count ?? 0) <= 256 }) else {
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
        var reader = try AssetReader(assets: archive.assets, verified: verifiedAssets)
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

    struct Document: Codable {
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

    /// A task's provenance and outcome, without its events.
    struct ArchivedTask: Codable, Equatable {
        var id: UUID
        var userMessageID: UUID?
        var startedAt: Date
        var finishedAt: Date?
        var agent: String?
        var model: String?
        var reasoningEffort: String?
        var status: String
        var additionalUserMessageIDs: [UUID]?
        var externalClient: ProjectExternalAgentIdentity?
        var requestAsset: String?
        var committedRevisionID: UUID?
        var commitKey: String?
        var commitArtifactID: String?

        /// An unchanged request keeps its stored asset without hashing it again.
        init(_ task: ProjectTaskAudit, reusing old: (task: ProjectTaskAudit, record: ArchivedTask)? = nil,
             writer: inout AssetWriter) throws {
            id = task.id; userMessageID = task.userMessageID
            startedAt = task.startedAt; finishedAt = task.finishedAt
            agent = task.agent; model = task.model; reasoningEffort = task.reasoningEffort; status = task.status
            additionalUserMessageIDs = task.additionalUserMessageIDs
            externalClient = task.externalClient
            if let old, old.task.request == task.request { requestAsset = old.record.requestAsset }
            else { requestAsset = try task.request.map { try writer.store(Data($0.utf8), role: .activity) } }
            committedRevisionID = task.committedRevisionID; commitKey = task.commitKey; commitArtifactID = task.commitArtifactID
        }

        var assetKeys: [String] { requestAsset.map { [$0] } ?? [] }
    }

    /// A task and its events, coded as one object.
    struct ArchivedTaskAudit: Codable {
        var task: ArchivedTask
        var events: [ArchivedActivityEvent]

        init(task: ArchivedTask, events: [ArchivedActivityEvent]) {
            self.task = task
            self.events = events
        }

        init(_ task: ProjectTaskAudit, writer: inout AssetWriter) throws {
            self.task = try ArchivedTask(task, writer: &writer)
            events = try task.events.map { try ArchivedActivityEvent($0, writer: &writer) }
        }

        private enum CodingKeys: String, CodingKey { case events }

        init(from decoder: Decoder) throws {
            task = try ArchivedTask(from: decoder)
            events = try decoder.container(keyedBy: CodingKeys.self).decode([ArchivedActivityEvent].self, forKey: .events)
        }

        func encode(to encoder: Encoder) throws {
            try task.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(events, forKey: .events)
        }

        func restored(reader: inout AssetReader) throws -> ProjectTaskAudit {
            ProjectTaskAudit(id: task.id, userMessageID: task.userMessageID, startedAt: task.startedAt, finishedAt: task.finishedAt,
                             agent: task.agent, model: task.model, reasoningEffort: task.reasoningEffort, status: task.status,
                             events: try events.map { try $0.restored(reader: &reader) },
                             additionalUserMessageIDs: task.additionalUserMessageIDs,
                             externalClient: task.externalClient,
                             request: try task.requestAsset.map { try reader.text($0, role: .activity) },
                             committedRevisionID: task.committedRevisionID, commitKey: task.commitKey,
                             commitArtifactID: task.commitArtifactID)
        }
    }

    struct ArchivedQueuedRequest: Codable, Equatable {
        var id: UUID
        var content: String
        var date: Date
        var attachments: [ArchivedAttachment]?
        var codexSettings: CodexProjectSettings?
        var capturedSourcePaths: [String]?
        var selection: ProjectSelectionContext?

        /// Unchanged attachments keep their stored assets without hashing them again.
        init(_ request: ProjectQueuedRequest, reusing old: (request: ProjectQueuedRequest, record: ArchivedQueuedRequest)? = nil,
             writer: inout AssetWriter) throws {
            id = request.id; content = request.content; date = request.date
            if let old, old.request.attachments == request.attachments { attachments = old.record.attachments }
            else { attachments = try request.attachments?.map { try ArchivedAttachment($0, writer: &writer) } }
            codexSettings = request.codexSettings
            capturedSourcePaths = request.capturedSourcePaths
            selection = request.selection
        }

        var assetKeys: [String] { attachments?.map(\.contentAsset) ?? [] }

        func restored(reader: inout AssetReader) throws -> ProjectQueuedRequest {
            ProjectQueuedRequest(id: id, content: content, date: date,
                attachments: try attachments?.map { try $0.restored(reader: &reader) }, codexSettings: codexSettings,
                capturedSourcePaths: capturedSourcePaths, selection: selection)
        }
    }

    struct ArchivedActivityEvent: Codable, Equatable {
        var id: String
        var date: Date
        var category: String
        var title: String
        var status: String
        var inputAsset: String?
        var outputAsset: String?
        var imageAsset: String?
        var durationSeconds: Double?
        var files: [ArchivedActivityFile]?

        /// Unchanged payloads keep their stored assets without hashing them again.
        init(_ event: ProjectActivityEvent, reusing old: (event: ProjectActivityEvent, record: ArchivedActivityEvent)? = nil,
             writer: inout AssetWriter) throws {
            id = event.id; date = event.date; category = event.category
            title = event.title; status = event.status; durationSeconds = event.durationSeconds
            if let old, old.event.input == event.input { inputAsset = old.record.inputAsset }
            else { inputAsset = try event.input.map { try writer.store(Data($0.utf8), role: .activity) } }
            if let old, old.event.output == event.output { outputAsset = old.record.outputAsset }
            else { outputAsset = try event.output.map { try writer.store(Data($0.utf8), role: .activity) } }
            if let old, old.event.imageData == event.imageData { imageAsset = old.record.imageAsset }
            else { imageAsset = try event.imageData.map { try writer.store($0, role: .activityImage) } }
            if let old, old.event.files == event.files { files = old.record.files }
            else { files = try event.files?.map { try ArchivedActivityFile($0, writer: &writer) } }
        }

        var assetKeys: [String] {
            [inputAsset, outputAsset, imageAsset].compactMap { $0 } + (files?.map(\.dataAsset) ?? [])
        }

        private enum CodingKeys: String, CodingKey {
            case id, date, category, title, status, inputAsset, outputAsset, imageAsset, durationSeconds, files
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
            imageAsset = try values.decodeIfPresent(String.self, forKey: .imageAsset)
            durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
            files = try values.decodeIfPresent([ArchivedActivityFile].self, forKey: .files)
        }

        func restored(reader: inout AssetReader) throws -> ProjectActivityEvent {
            ProjectActivityEvent(id: id, date: date, category: category, title: title, status: status,
                                 input: try inputAsset.map { try reader.text($0, role: .activity) },
                                 output: try outputAsset.map { try reader.text($0, role: .activity) },
                                 durationSeconds: durationSeconds,
                                 files: try files?.map { try $0.restored(reader: &reader) },
                                 imageData: try imageAsset.map { try reader.data($0, role: .activityImage) })
        }
    }

    struct ArchivedActivityFile: Codable, Equatable {
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

    struct ArchivedInputAsset: Codable, Equatable {
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

    struct ArchivedMessage: Codable, Equatable {
        var id: UUID
        var role: String
        var content: String
        var date: Date
        var attachments: [ArchivedAttachment]?
        var phase: String?
        var selection: ProjectSelectionContext?

        /// Unchanged attachments keep their stored assets without hashing them again.
        init(_ message: ChatMessage, reusing old: (message: ChatMessage, record: ArchivedMessage)? = nil,
             writer: inout AssetWriter) throws {
            id = message.id
            role = message.role
            content = message.content
            date = message.date
            if let old, old.message.attachments == message.attachments { attachments = old.record.attachments }
            else { attachments = try message.attachments?.map { try ArchivedAttachment($0, writer: &writer) } }
            phase = message.phase
            selection = message.selection
        }

        var assetKeys: [String] { attachments?.map(\.contentAsset) ?? [] }

        func restored(reader: inout AssetReader) throws -> ChatMessage {
            let sources = try attachments?.map { try $0.restored(reader: &reader) }
            return ChatMessage(id: id, role: role, content: content, date: date, attachments: sources, phase: phase, selection: selection)
        }
    }

    struct ArchivedAttachment: Codable, Equatable {
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

    struct ArchivedModel: Codable, Equatable {
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

    /// A revision's modeling instructions and provenance.
    struct ArchivedRecipe: Codable, Equatable {
        var id: UUID
        var model: ArchivedModel
        var date: Date
        var sourceSTEPAsset: String?
        var scriptAsset: String
        var inputAssets: [ArchivedInputAsset]?
        var runtime: CADRuntime?
        var userMessageID: UUID?
        var responseMessageID: UUID?
        var validatedHash: String?

        init(_ revision: ProjectRevision, writer: inout AssetWriter) throws {
            id = revision.id
            model = ArchivedModel(revision.model)
            date = revision.date
            sourceSTEPAsset = try revision.model.sourceSTEP.map { try writer.store($0, role: .step) }
            scriptAsset = try writer.store(Data(revision.model.script.utf8), role: .script)
            inputAssets = try revision.model.inputAssets?.map { try ArchivedInputAsset($0, writer: &writer) }
            runtime = revision.runtime
            userMessageID = revision.userMessageID
            responseMessageID = revision.responseMessageID
            validatedHash = revision.validatedHash
        }

        var assetKeys: [String] {
            [scriptAsset] + (sourceSTEPAsset.map { [$0] } ?? []) + (inputAssets?.map(\.dataAsset) ?? [])
        }

        private enum CodingKeys: String, CodingKey {
            case id, model, date, sourceSTEPAsset, scriptAsset, inputAssets, runtime, userMessageID, responseMessageID
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
            runtime = try values.decodeIfPresent(CADRuntime.self, forKey: .runtime)
            userMessageID = try values.decodeIfPresent(UUID.self, forKey: .userMessageID)
            responseMessageID = try values.decodeIfPresent(UUID.self, forKey: .responseMessageID)
            validatedHash = try values.decodeIfPresent(String.self, forKey: .validatedHash)
        }
    }

    /// A revision's part organization, visibility, colors and assembly pose.
    struct ArchivedParts: Codable, Equatable {
        var parts: [PartNode]?
        var partLayout: PartLayout?
        var hiddenSolids: [Int]?
        var partColors: [String: PartColor]?
        var jointPositions: [String: Double]?

        init(_ revision: ProjectRevision) throws {
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
            partColors = revision.partColors
            jointPositions = revision.jointPositions
        }
    }

    /// A revision's recipe, parts and optional name, coded as one object.
    struct ArchivedRevision: Codable {
        var recipe: ArchivedRecipe
        var parts: ArchivedParts
        var name: String?

        init(recipe: ArchivedRecipe, parts: ArchivedParts, name: String?) {
            self.recipe = recipe
            self.parts = parts
            self.name = name
        }

        init(_ revision: ProjectRevision, writer: inout AssetWriter) throws {
            recipe = try ArchivedRecipe(revision, writer: &writer)
            parts = try ArchivedParts(revision)
            name = revision.name
        }

        private enum CodingKeys: String, CodingKey { case name }

        init(from decoder: Decoder) throws {
            recipe = try ArchivedRecipe(from: decoder)
            parts = try ArchivedParts(from: decoder)
            name = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .name)
        }

        func encode(to encoder: Encoder) throws {
            try recipe.encode(to: encoder)
            try parts.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(name, forKey: .name)
        }

        func restored(reader: inout AssetReader) throws -> ProjectRevision {
            let model = recipe.model
            let restoredModel = ModelSpec(title: model.title, summary: model.summary, units: model.units,
                                          script: try reader.text(recipe.scriptAsset, role: .script),
                                          sourceSTEP: try recipe.sourceSTEPAsset.map { try reader.data($0, role: .step) },
                                          sourceName: model.sourceName, reorganizePartIDs: model.reorganizePartIDs,
                                          inputAssets: try recipe.inputAssets?.map { try $0.restored(reader: &reader) })
            var revision = ProjectRevision(id: recipe.id, model: restoredModel, date: recipe.date,
                                          preview: nil, partLayout: parts.partLayout,
                                          hiddenSolids: parts.hiddenSolids)
            revision.parts = parts.parts
            revision.runtime = recipe.runtime
            revision.userMessageID = recipe.userMessageID
            revision.responseMessageID = recipe.responseMessageID
            revision.partColors = parts.partColors
            revision.name = name
            revision.validatedHash = recipe.validatedHash
            revision.jointPositions = parts.jointPositions
            return revision
        }
    }

    enum AssetRole: Equatable {
        case attachment, image, script, step, input, activity, activityFile, activityImage

        var maximumBytes: Int {
            switch self {
            case .attachment: return SourceImport.maximumFileBytes
            case .image: return SourceImport.maximumImageFileBytes
            case .script: return 200_000
            case .step: return ProjectStore.maximumSTEPBytes
            case .input: return ProjectStore.maximumSTEPBytes
            case .activity: return ProjectStore.maximumActivityTextBytes
            case .activityFile: return ProjectActivityFile.maximumBytes
            case .activityImage: return ProjectActivityEvent.maximumImageBytes
            }
        }
    }

    struct AssetWriter {
        var assets: [String: Data] = [:]
        private var totalAssetBytes = 0

        mutating func store(_ bytes: Data, role: AssetRole) throws -> String {
            try validateSize(bytes.count, role: role)
            let key = SHA256.hexDigest(bytes)
            if let existing = assets[key] {
                guard existing == bytes else { throw invalid("File assets have conflicting integrity hashes.") }
            } else {
                try addBytes(bytes.count, to: &totalAssetBytes, limit: maximumAssetBytes)
                assets[key] = bytes
            }
            return key
        }
    }

    struct AssetReader {
        var assets: [String: Data]
        var usedAssets: Set<String> = []
        private var decodedText: [String: String] = [:]

        init(assets: [String: Data], verified: Bool = false) throws {
            var total = 0
            for (key, bytes) in assets {
                try addBytes(bytes.count, to: &total, limit: maximumAssetBytes)
                guard validKey(key), verified || SHA256.hexDigest(bytes) == key else {
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
