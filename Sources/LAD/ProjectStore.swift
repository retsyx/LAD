import Foundation

/// Portable project serialization. All methods are nonisolated so callers can
/// read, validate and encode large geometry snapshots on a background task.
enum ProjectStore {
    static let maximumFileBytes = 256_000_000
    static let maximumSTEPBytes = 128_000_000
    private static let coordinateLimit = 1_000_000.0

    static func encode(_ project: LADProject) throws -> Data {
        try validate(project)
        let data = try ProjectZIP.encode(ProjectArchive.encode(project))
        guard data.count <= maximumFileBytes else { throw invalid("File exceeds the 256 MB design limit.") }
        return data
    }

    static func decode(_ data: Data) throws -> LADProject {
        guard data.count <= maximumFileBytes else { throw invalid("File exceeds the 256 MB design limit.") }
        let payload = ProjectZIP.isZIP(data) ? try ProjectZIP.decode(data) : data
        let project = try ProjectArchive.decode(payload)
        try validate(project)
        return project
    }

    static func read(from url: URL) throws -> LADProject {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(maximumFileBytes) {
            throw invalid("File exceeds the 256 MB design limit.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        // Bound actual reads as well as the file-size preflight, including if a
        // file grows between the two operations.
        while let chunk = try file.read(upToCount: min(1_048_576, maximumFileBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumFileBytes else { throw invalid("File exceeds the 256 MB design limit.") }
        }
        return try decode(data)
    }

    static func write(_ project: LADProject, to url: URL) throws {
        try encode(project).write(to: url, options: .atomic)
    }

    static func validate(_ project: LADProject) throws {
        var verifiedAttachmentPayloads: [String: Data] = [:]
        guard project.formatVersion == 1 else { throw invalid("Unsupported format version \(project.formatVersion).") }
        if let name = project.projectName {
            do { try ProjectNaming.validateSavedName(name) }
            catch { throw invalid("The saved design name is invalid. \(error.localizedDescription)") }
        }
        if let settings = project.codexSettings { try validateCodexSettings(settings) }
        if let draft = project.draftPrompt, draft.utf8.count > 1_000_000 {
            throw invalid("The saved draft exceeds the request size limit.")
        }
        if let attachments = project.draftAttachments { try validateAttachments(attachments, verifiedPayloads: &verifiedAttachmentPayloads) }
        if let queue = project.queuedRequests {
            guard queue.count <= 10_000, Set(queue.map(\.id)).count == queue.count else {
                throw invalid("The request queue contains too many items or duplicate IDs.")
            }
            for request in queue {
                guard request.content.utf8.count <= 1_000_000,
                      !request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.attachments?.isEmpty == false,
                      request.date.timeIntervalSinceReferenceDate.isFinite else {
                    throw invalid("A queued request is empty, oversized, or invalid.")
                }
                if let attachments = request.attachments { try validateAttachments(attachments, verifiedPayloads: &verifiedAttachmentPayloads) }
                if let settings = request.codexSettings { try validateCodexSettings(settings) }
                if let selection = request.selection { try selection.validate() }
                if let captured = request.capturedSourcePaths {
                    let referenced = Set(SourceImport.referencedURLs(in: request.content).map { $0.standardizedFileURL.path })
                    guard captured.count <= 10_000, Set(captured).count == captured.count,
                          captured.isEmpty || request.attachments?.isEmpty == false,
                          captured.allSatisfy({ $0.utf8.count <= 16_384 && referenced.contains($0) }) else {
                        throw invalid("A queued request contains invalid captured source references.")
                    }
                }
            }
        }
        if let colors = project.recentPartColors {
            guard colors.count <= PartColor.maximumRecentCount,
                  colors.allSatisfy(\.isValid), Set(colors).count == colors.count else {
                throw invalid("The saved recent part colors are invalid.")
            }
        }
        guard project.revisions.count <= 1_000, project.messages.count <= 10_000 else {
            throw invalid("Design contains too many revisions or messages.")
        }
        guard Set(project.revisions.map(\.id)).count == project.revisions.count,
              Set(project.messages.map(\.id)).count == project.messages.count else {
            throw invalid("Revision and message IDs must be unique.")
        }
        if let selected = project.selectedRevisionID, !project.revisions.contains(where: { $0.id == selected }) {
            throw invalid("The selected revision does not exist.")
        }
        for message in project.messages {
            guard ["user", "assistant", "system"].contains(message.role),
                  message.content.utf8.count <= 1_000_000, message.date.timeIntervalSinceReferenceDate.isFinite else {
                throw invalid("Chat history contains an invalid message.")
            }
            if let attachments = message.attachments { try validateAttachments(attachments, verifiedPayloads: &verifiedAttachmentPayloads) }
            if let selection = message.selection {
                guard message.role == "user" else { throw invalid("Only user requests may contain selection references.") }
                try selection.validate()
            }
            if let phase = message.phase {
                guard message.role == "assistant", ["commentary", "response", "final_answer"].contains(phase) else {
                    throw invalid("Chat history contains an invalid assistant message phase.")
                }
            }
        }
        if let taskAudits = project.taskAudits { try validateTaskAudits(taskAudits, messages: project.messages) }
        let messageIndices = Dictionary(uniqueKeysWithValues: project.messages.enumerated().map { ($0.element.id, $0.offset) })
        for revision in project.revisions {
            guard revision.date.timeIntervalSinceReferenceDate.isFinite else { throw invalid("A revision date is invalid.") }
            if let name = revision.name {
                do { try ProjectRevisionNaming.validateSavedName(name) }
                catch { throw invalid("A saved version name is invalid. \(error.localizedDescription)") }
            }
            if revision.userMessageID != nil || revision.responseMessageID != nil {
                guard let userID = revision.userMessageID, let responseID = revision.responseMessageID,
                      let userIndex = messageIndices[userID], let responseIndex = messageIndices[responseID],
                      userIndex < responseIndex, project.messages[userIndex].role == "user",
                      project.messages[responseIndex].role == "assistant",
                      project.messages[responseIndex].phase != "commentary",
                      project.messages[responseIndex].phase != "response" else {
                    throw invalid("A saved design contains invalid conversation references.")
                }
            }
            if let runtime = revision.runtime {
                guard [runtime.python, runtime.cadquery, runtime.ocp].allSatisfy({
                    !$0.isEmpty && $0.utf8.count <= 256 &&
                    $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                }) else { throw invalid("The saved CAD runtime metadata is invalid.") }
            }
            try validateModel(revision.model)
            if let preview = revision.preview { try validatePreview(preview) }
            if let step = revision.stepData { try validateSTEP(step) }
            let parts = revision.parts ?? revision.preview?.parts
            let indices = parts?.flatMap(\.allSolidIndices) ?? []
            guard indices.allSatisfy({ (0..<4_096).contains($0) }) else { throw invalid("The saved parts contain invalid solid indices.") }
            let solidCount = revision.preview?.solids ?? indices.max().map { $0 + 1 } ?? 0
            if let parts { try validatePartHierarchy(parts, solidCount: solidCount) }
            if let layout = revision.partLayout {
                try validatePartHierarchy(layout.nodes, solidCount: solidCount)
                let folderIDs = Set(layout.nodes.flatMap(\.flattened).filter(\.isGroup).map(\.id))
                guard layout.movedNodeIDs.count <= 8_192, layout.userFolderIDs.count <= 8_192, layout.renamedNodes.count <= 8_192,
                      layout.collapsedNodeIDs.count <= 8_192,
                      Set(layout.collapsedNodeIDs).count == layout.collapsedNodeIDs.count,
                      layout.collapsedNodeIDs.allSatisfy({ folderIDs.contains($0) }),
                      layout.movedNodeIDs.allSatisfy(validPartID), layout.userFolderIDs.allSatisfy(validPartID),
                      layout.renamedNodes.allSatisfy({ validPartID($0.key) && validPartName($0.value) }) else {
                    throw invalid("The saved parts layout contains invalid edit metadata.")
                }
            }
            if let hidden = revision.hiddenSolids {
                guard hidden.count <= solidCount, Set(hidden).count == hidden.count,
                      hidden.allSatisfy({ $0 >= 0 && $0 < solidCount }) else {
                    throw invalid("The saved part visibility is invalid.")
                }
            }
            if let colors = revision.partColors {
                let colorNodes = revision.partLayout?.nodes ?? parts ?? (0..<solidCount).map {
                    PartNode(id: "solid/\($0)", name: "Part \($0 + 1)", solidIndices: [$0])
                }
                // An assembly node may own geometry in addition to children.
                // Colors address each node's own solids, never an empty folder.
                let physicalIDs = Set(colorNodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map(\.id))
                guard colors.count <= 4_096, colors.allSatisfy({ physicalIDs.contains($0.key) && $0.value.isValid }) else {
                    throw invalid("The saved part colors are invalid or refer to missing parts.")
                }
            }
        }
    }

    private static func validateCodexSettings(_ settings: CodexProjectSettings) throws {
        func validModel(_ value: String) -> Bool {
            value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard validModel(settings.model), CodexReasoningEffort(rawValue: settings.reasoningEffort) != nil,
              settings.reasoningByModel.count <= 256,
              settings.reasoningByModel.allSatisfy({ validModel($0.key) && CodexReasoningEffort(rawValue: $0.value) != nil }) else {
            throw invalid("The saved Codex model or reasoning selection is invalid.")
        }
    }

    private static func validateAttachments(_ attachments: [SourceAttachment], verifiedPayloads: inout [String: Data]) throws {
        do { try SourceImport.validateAttachments(attachments, verifiedPayloads: &verifiedPayloads) }
        catch { throw invalid(error.localizedDescription) }
    }

    static func validatePreview(_ mesh: PreviewMesh) throws {
        guard (1...1_000_000).contains(mesh.vertices.count),
              (1...1_000_000).contains(mesh.triangles.count), mesh.edges.count <= 250_000,
              mesh.bounds.count == 6, mesh.bounds.allSatisfy(validCoordinate),
              (0..<3).allSatisfy({ mesh.bounds[$0] <= mesh.bounds[$0 + 3] }),
              (0..<3).contains(where: { mesh.bounds[$0] < mesh.bounds[$0 + 3] }),
              mesh.volume.isFinite, mesh.volume > 0, mesh.area.isFinite, mesh.area > 0,
              (1...4_096).contains(mesh.solids), (1...20_000).contains(mesh.faces),
              mesh.buildSeconds.isFinite, mesh.buildSeconds >= 0, (1...256).contains(mesh.threads),
              mesh.stepPath.utf8.count <= 16_384 else { throw invalid("Embedded preview metadata is invalid.") }
        let span = (0..<3).map { mesh.bounds[$0 + 3] - mesh.bounds[$0] }.max() ?? 0
        let tolerance = max(0.0001, span * 0.000001)
        func inBounds(_ point: ArraySlice<Double>) -> Bool {
            guard point.count == 3 else { return false }
            return point.enumerated().allSatisfy { axis, value in
                validCoordinate(value) && value >= mesh.bounds[axis] - tolerance && value <= mesh.bounds[axis + 3] + tolerance
            }
        }
        guard mesh.vertices.allSatisfy({ $0.count == 3 && inBounds($0[...]) }),
              mesh.triangles.allSatisfy({ triangle in
                  triangle.count == 3 && triangle.allSatisfy { $0 >= 0 && $0 < mesh.vertices.count }
              }),
              mesh.edges.allSatisfy({ edge in
                  edge.count == 6 && inBounds(edge.prefix(3)) && inBounds(edge.suffix(3))
              }) else { throw invalid("Embedded preview contains invalid vertices, triangles or edges.") }
        if mesh.normals != nil, !mesh.hasValidNormals {
            throw invalid("Preview surface normals are invalid.")
        }
        if let mapping = mesh.triangleSolids {
            guard mapping.count == mesh.triangles.count,
                  mapping.allSatisfy({ $0 >= 0 && $0 < mesh.solids }),
                  Set(mapping) == Set(0..<mesh.solids) else {
                throw invalid("Embedded preview solid selection data is invalid.")
            }
        }
        if let mapping = mesh.edgeSolids {
            guard mapping.count == mesh.edges.count, mapping.allSatisfy({ $0 >= 0 && $0 < mesh.solids }) else {
                throw invalid("Embedded preview edge ownership is invalid.")
            }
        }
        if let parts = mesh.parts { try validatePartHierarchy(parts, solidCount: mesh.solids) }
    }

    static func validatePartHierarchy(_ nodes: [PartNode], solidCount: Int) throws {
        guard nodes.count <= 8_192, (0...4_096).contains(solidCount) else { throw invalid("The parts hierarchy is too large.") }
        var pending = nodes.map { ($0, 0) }, identifiers = Set<String>(), owners = Set<Int>(), count = 0
        while let (node, depth) = pending.popLast() {
            count += 1
            guard count <= 8_192, depth <= 32, validPartID(node.id), validPartName(node.name), node.isGroup || !node.solidIndices.isEmpty,
                  identifiers.insert(node.id).inserted else { throw invalid("The parts hierarchy contains invalid or duplicate items.") }
            for solid in node.solidIndices {
                guard solid >= 0, solid < solidCount, owners.insert(solid).inserted else {
                    throw invalid("Each solid must belong to exactly one item in the parts hierarchy.")
                }
            }
            if let children = node.children {
                guard count + pending.count + children.count <= 8_192 else { throw invalid("The parts hierarchy is too large.") }
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        guard owners == Set(0..<solidCount) else { throw invalid("The parts hierarchy must include every solid.") }
    }

    private static func validPartID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 1_024 && id.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func validPartName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 160 &&
            name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func validateSTEP(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumSTEPBytes,
              let header = String(data: data.prefix(512), encoding: .utf8),
              header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ISO-10303-21;"),
              let footer = String(data: data.suffix(512), encoding: .utf8),
              footer.contains("END-ISO-10303-21;") else {
            throw invalid("Embedded STEP asset is invalid or exceeds 128 MB.")
        }
    }

    private static func validateModel(_ model: ModelSpec) throws {
        if let ids = model.reorganizePartIDs {
            guard ids.count <= 8_192, ids.allSatisfy(validPartID) else { throw invalid("The design contains invalid parts layout changes.") }
        }
        guard !model.title.isEmpty, model.title.count <= 160,
              !model.summary.isEmpty, model.summary.count <= 6_000,
              model.units == "mm" else {
            throw invalid("A design contains invalid title, summary or units.")
        }
        if let source = model.sourceSTEP { try validateSTEP(source) }
        if let assets = model.inputAssets { try validateInputAssets(assets) }
        if let name = model.sourceName {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 256, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"),
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw invalid("A design source name must be a filename of at most 256 UTF-8 bytes, without a directory path or control characters.")
            }
        }
        guard !model.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.script.utf8.count <= 200_000, !model.script.contains("\0") else {
            throw invalid("A CadQuery design must contain a nonempty program of at most 200,000 UTF-8 bytes without null characters.")
        }
    }

    /// Imported backend geometry is portable recipe input. Native validation
    /// remains the worker's job; this boundary checks names, kinds and storage.
    static func validateInputAssets(_ assets: [CADInputAsset]) throws {
        guard assets.count <= 256, Set(assets.map(\.id)).count == assets.count else {
            throw invalid("The design contains too many imported inputs or duplicate input IDs.")
        }
        var total = 0
        for asset in assets {
            guard validPartID(asset.id), CADInputAsset.supportedFormats.contains(asset.format),
                  !asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  asset.name.utf8.count <= 256, asset.name != ".", asset.name != "..",
                  !asset.name.contains("/"), !asset.name.contains("\\"),
                  asset.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !asset.data.isEmpty, asset.data.count <= maximumSTEPBytes,
                  asset.data.count <= maximumFileBytes - total else {
                throw invalid("An imported design input has an invalid ID, filename, format, or size.")
            }
            total += asset.data.count
            if asset.format == "step" || asset.format == "stp" { try validateSTEP(asset.data) }
        }
    }

    static func validateTaskAudits(_ audits: [ProjectTaskAudit], messages: [ChatMessage]) throws {
        let statuses: Set<String> = ["running", "completed", "failed", "canceled", "interrupted"]
        let categories: Set<String> = ["tool", "command", "file_change", "web_search", "plan", "lifecycle", "validation", "diagnostic", "steering"]
        let userIDs = Set(messages.filter { $0.role == "user" }.map(\.id))
        guard audits.count <= 10_000, Set(audits.map(\.id)).count == audits.count else {
            throw invalid("Tool activity contains too many tasks or duplicate task IDs.")
        }
        var totalEvents = 0
        for task in audits {
            guard userIDs.contains(task.userMessageID), statuses.contains(task.status),
                  task.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  task.finishedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= task.startedAt }) ?? true,
                  [task.model, task.reasoningEffort].allSatisfy({ $0.utf8.count <= 256 && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }),
                  task.events.count <= 100_000 - totalEvents,
                  Set(task.events.map(\.id)).count == task.events.count else {
                throw invalid("The saved tool task metadata is invalid.")
            }
            totalEvents += task.events.count
            if let additional = task.additionalUserMessageIDs {
                guard additional.count <= 10_000, Set(additional).count == additional.count,
                      !additional.contains(task.userMessageID), additional.allSatisfy(userIDs.contains) else {
                    throw invalid("A saved tool task has invalid supplemental message references.")
                }
            }
            for event in task.events {
                guard validPartID(event.id), categories.contains(event.category), statuses.contains(event.status),
                      !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      event.title.utf8.count <= 16_384, !event.title.contains("\0"),
                      event.date.timeIntervalSinceReferenceDate.isFinite,
                      event.durationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
                      event.input.map({ $0.utf8.count <= maximumFileBytes }) ?? true,
                      event.output.map({ $0.utf8.count <= maximumFileBytes }) ?? true else {
                    throw invalid("A saved tool activity event is invalid.")
                }
                if let files = event.files {
                    guard files.count <= 64, Set(files.map(\.path)).count == files.count else {
                        throw invalid("A tool activity event contains too many source snapshots or duplicate paths.")
                    }
                    for file in files { try validateActivityFile(file) }
                }
            }
        }
    }

    static func validateActivityFile(_ file: ProjectActivityFile) throws {
        guard !file.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              file.name.utf8.count <= 256, file.name != ".", file.name != "..",
              !file.name.contains("/"), !file.name.contains("\\"),
              file.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !file.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              file.path.utf8.count <= 4_096,
              file.path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              ProjectActivityFile.supportedExtensions.contains((file.name as NSString).pathExtension.lowercased()),
              file.data.count <= ProjectActivityFile.maximumBytes,
              let text = String(data: file.data, encoding: .utf8), !text.contains("\0") else {
            throw invalid("A tool source snapshot must be a supported UTF-8 source or dependency text file of at most 2 MB.")
        }
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.hasPrefix("ISO-10303-21;"), !prefix.hasPrefix("DBRep_DrawableShape"),
              !prefix.hasPrefix("CASCADE Topology") else {
            throw invalid("Generated geometry cannot be stored as a tool source snapshot.")
        }
        if let json = try? JSONSerialization.jsonObject(with: file.data) as? [String: Any],
           json["vertices"] != nil, json["triangles"] != nil,
           json["stepPath"] != nil || json["topology"] != nil || json["triangleSolids"] != nil {
            throw invalid("Derived display data cannot be stored as a tool source snapshot.")
        }
    }

    private static func validCoordinate(_ value: Double) -> Bool { value.isFinite && abs(value) <= coordinateLimit }
    private static func invalid(_ reason: String) -> LADError { .message("Invalid LAD design. \(reason)") }
}
