import CryptoKit
import Foundation

/// Only these references belong in a Codex request. Complete design contents
/// remain in private local files for Codex to inspect.
struct CodexSourceReference: Codable, Sendable {
    var name: String
    var path: String
    var readPath: String
    var sha256: String
    var byteCount: Int
}

/// Complete image history is indexed locally, so a reference to an older log
/// image remains usable without replaying all historical media to the model.
struct CodexImageReference: Codable, Sendable {
    var attachmentID: UUID
    var messageID: UUID?
    var messageDate: Date?
    var isCurrent: Bool
    var file: CodexSourceReference
}

/// Native topology indices are meaningful only in this immutable origin recipe.
/// The JSON and required input bytes remain local references, never prompt text.
struct CodexSelectionFile: Codable, Sendable {
    var selection: ProjectSelectionContext
    var originRecipeStatus: String
    var originModel: CodexSourceReference?
    var originGeometryInputsManifestPath: String?
    var originMatchesCurrent: Bool
}

struct CodexSelectionHistoryReference: Codable, Sendable {
    var messageID: UUID
    var messageDate: Date
    var revisionID: UUID
    var selectionPath: String
}

struct CodexFileContext: Sendable {
    var currentModelPath: String?
    var sources: [CodexSourceReference]
    /// Bounded metadata for images attached to the current request.
    var images: [CodexSourceReference] = []
    /// Complete local index for current and historical image occurrences.
    var imageManifestPath: String? = nil
    /// Only images attached to this request become visual input items. Older
    /// images remain available as local references without replaying media.
    var currentImagePaths: [String] = []
    var partLayoutPath: String? = nil
    var inputAssetsPath: String? = nil
    var selectionPath: String? = nil
    var selectionPartCount = 0
    var selectionFeatureCount = 0
    var selectionOriginMatchesCurrent = false
    var selectionManifestPath: String? = nil

    static func prepare(current: ModelSpec?, history: [ChatMessage], attachments: [SourceAttachment], directory: URL,
                        partLayout: PartLayout? = nil, selection: ProjectSelectionContext? = nil,
                        selectionModel: ModelSpec? = nil, selectionModelsByRevision: [UUID: ModelSpec] = [:]) throws -> CodexFileContext {
        let manager = FileManager.default
        let context = directory.appendingPathComponent("context", isDirectory: true)
        try manager.createDirectory(at: context, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: context.path)

        func write(_ data: Data, to url: URL) throws {
            guard manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw LADError.message("Could not stage a local design reference for Codex.")
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        var modelPath: String?
        if var model = current {
            // Stage the complete CAD program as a file reference. Binary CAD
            // geometry stays with LAD's worker; programs use imported_model.
            model.sourceSTEP = nil
            model.inputAssets = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let url = context.appendingPathComponent("current-model.json")
            try write(encoder.encode(model), to: url)
            modelPath = url.path
        }

        var selected: [SourceAttachment] = []
        var seen = Set<String>(), bytes = 0
        let candidates = attachments + history.reversed().flatMap { ($0.attachments ?? []).reversed() }
        for source in candidates where !source.isImage {
            // Mark a path before applying the budget: skipping a newer version
            // must never resurrect an obsolete snapshot of that same source.
            guard seen.insert(source.path).inserted else { continue }
            let count = source.byteCount
            guard selected.count < SourceImport.maximumFiles,
                  count <= SourceImport.maximumTotalBytes - bytes else { continue }
            bytes += count
            selected.append(source)
        }

        var references: [CodexSourceReference] = []
        if !selected.isEmpty {
            let sources = context.appendingPathComponent("sources", isDirectory: true)
            try manager.createDirectory(at: sources, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sources.path)
            for (index, source) in selected.enumerated() {
                // User filenames are provenance only. Fixed numbered basenames
                // prevent traversal, collisions and control characters in paths.
                let ext = SourceImport.supportedExtensions.contains(source.fileExtension) ? source.fileExtension : "txt"
                let filename = String(format: "source-%03d.%@", index + 1, ext)
                let url = sources.appendingPathComponent(filename)
                let data = source.data
                try write(data, to: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let reference = CodexSourceReference(name: source.name, path: source.path, readPath: url.path, sha256: digest, byteCount: data.count)
                references.append(reference)
            }
        }

        let currentImages = attachments.filter(\.isImage)
        try SourceImport.validateAttachments(currentImages)
        let historicalImages = history.flatMap { message in
            (message.attachments ?? []).filter(\.isImage).map { (attachment: $0, message: message) }
        }
        var currentImageReferences: [CodexSourceReference] = []
        var imageManifestPath: String?
        if !currentImages.isEmpty || !historicalImages.isEmpty {
            let folder = context.appendingPathComponent("images", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var stored: [String: (path: String, data: Data)] = [:]
            var verified: [String: Data] = [:]
            var totalBytes = 0
            var manifest: [CodexImageReference] = []
            func stage(_ attachment: SourceAttachment, message: ChatMessage?) throws {
                try SourceImport.validateAttachments([attachment], verifiedPayloads: &verified)
                let data = attachment.data
                let path: String
                if let existing = stored[attachment.sha256] {
                    guard existing.data == data else { throw LADError.message("An image reference failed its integrity check.") }
                    path = existing.path
                } else {
                    guard data.count <= ProjectStore.maximumFileBytes - totalBytes else {
                        throw LADError.message("The image references exceed the design's 256 MB asset limit.")
                    }
                    totalBytes += data.count
                    let ext = attachment.fileExtension == "png" ? "png" : "jpg"
                    let url = folder.appendingPathComponent("image-\(attachment.sha256).\(ext)")
                    try write(data, to: url)
                    path = url.path
                    stored[attachment.sha256] = (path, data)
                }
                let reference = CodexSourceReference(name: attachment.name, path: attachment.path, readPath: path,
                                                     sha256: attachment.sha256, byteCount: data.count)
                manifest.append(CodexImageReference(attachmentID: attachment.id, messageID: message?.id,
                    messageDate: message?.date, isCurrent: message == nil, file: reference))
                if message == nil { currentImageReferences.append(reference) }
            }
            for attachment in currentImages { try stage(attachment, message: nil) }
            for item in historicalImages { try stage(item.attachment, message: item.message) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            guard data.count <= ProjectStore.maximumFileBytes else {
                throw LADError.message("The image reference index exceeds the design limit.")
            }
            let url = context.appendingPathComponent("images.json")
            try write(data, to: url)
            imageManifestPath = url.path
        }
        var layoutPath: String?
        if let partLayout {
            let url = context.appendingPathComponent("parts-layout.json")
            try write(JSONEncoder().encode(partLayout), to: url)
            layoutPath = url.path
        }
        var assetsPath: String?
        if let assets = current?.inputAssets, !assets.isEmpty {
            try ProjectStore.validateInputAssets(assets)
            let folder = context.appendingPathComponent("geometry-inputs", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var stored = [String: String]()
            var manifest = [[String: String]]()
            for (index, asset) in assets.enumerated() {
                let digest = SHA256.hash(data: asset.data).map { String(format: "%02x", $0) }.joined()
                let readPath: String
                if let existing = stored[digest] { readPath = existing }
                else {
                    let url = folder.appendingPathComponent(String(format: "input-%03d.%@", index + 1, asset.format))
                    try write(asset.data, to: url)
                    stored[digest] = url.path
                    readPath = url.path
                }
                manifest.append(["id": asset.id, "name": asset.name, "format": asset.format, "readPath": readPath,
                                 "sha256": digest, "byteCount": String(asset.data.count)])
            }
            let url = context.appendingPathComponent("geometry-inputs.json")
            try write(JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]), to: url)
            assetsPath = url.path
        }
        var files = CodexFileContext(currentModelPath: modelPath, sources: references, images: currentImageReferences,
                                     imageManifestPath: imageManifestPath, currentImagePaths: currentImageReferences.map(\.readPath),
                                     partLayoutPath: layoutPath, inputAssetsPath: assetsPath)
        if let selection, !selection.parts.isEmpty || !selection.features.isEmpty {
            let origin = selectionModel ?? selectionModelsByRevision[selection.revisionID]
            let staged = try stageSelection(selection, originModel: origin, current: current,
                                            directory: directory, folder: "context")
            files.selectionPath = staged.path
            files.selectionPartCount = selection.parts.count
            files.selectionFeatureCount = selection.features.count
            files.selectionOriginMatchesCurrent = staged.originMatchesCurrent
        }
        let requestSelectionRevisionID = selection?.revisionID
        var originFolders: [UUID: String] = [:]
        if let requestSelectionRevisionID, files.selectionPath != nil { originFolders[requestSelectionRevisionID] = "context" }
        var historical: [CodexSelectionHistoryReference] = []
        for message in history {
            guard let selection = message.selection, !selection.parts.isEmpty || !selection.features.isEmpty else { continue }
            let origin = selectionModelsByRevision[selection.revisionID]
                ?? (selection.revisionID == requestSelectionRevisionID ? selectionModel : nil)
            let originFolder = originFolders[selection.revisionID] ?? "context/selection-origins/\(selection.revisionID.uuidString)"
            originFolders[selection.revisionID] = originFolder
            let staged = try stageSelection(selection, originModel: origin, current: current,
                                            directory: directory, folder: "context/selections/\(message.id.uuidString)", originFolder: originFolder)
            historical.append(CodexSelectionHistoryReference(messageID: message.id, messageDate: message.date,
                revisionID: selection.revisionID, selectionPath: staged.path))
        }
        if !historical.isEmpty {
            let workspace = try CADAgentWorkspace(directory: directory)
            files.selectionManifestPath = try workspace.write(try selectionEncoder.encode(historical), path: "context/selections.json").path
        }
        return files
    }

    /// Used for both the initial request and unique same-turn steering folders.
    /// It never rebuilds geometry or changes the worker's current design inputs.
    static func stageSelection(_ selection: ProjectSelectionContext, originModel: ModelSpec?, current: ModelSpec?,
                               directory: URL, folder: String, originFolder: String? = nil) throws -> (path: String, originMatchesCurrent: Bool) {
        try selection.validate()
        let workspace = try CADAgentWorkspace(directory: directory)
        let encoder = selectionEncoder
        var modelReference: CodexSourceReference?
        var inputsPath: String?
        if var model = originModel {
            var inputs: [[String: String]] = []
            func stageInput(_ data: Data, name: String, format: String, id: String?, binding: String) throws {
                guard !data.isEmpty, data.count <= ProjectStore.maximumSTEPBytes else {
                    throw LADError.message("A selected design's required geometry input exceeds the storage limit.")
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let path = "context/selection-assets/\(digest).\(format)"
                // Content addressing shares exact original inputs across all
                // historical selections while keeping old references immutable.
                let url: URL
                if let existing = try? workspace.read(path, maximumBytes: ProjectStore.maximumSTEPBytes), existing == data {
                    url = try workspace.url(path)
                } else { url = try workspace.write(data, path: path) }
                var record = ["name": name, "format": format, "readPath": url.path,
                              "sha256": digest, "byteCount": String(data.count), "programBinding": binding]
                if let id { record["id"] = id }
                inputs.append(record)
            }
            if let source = model.sourceSTEP {
                try stageInput(source, name: model.sourceName ?? "source.step", format: "step", id: nil, binding: "imported_model")
            }
            if let assets = model.inputAssets {
                try ProjectStore.validateInputAssets(assets)
                for asset in assets {
                    try stageInput(asset.data, name: asset.name, format: asset.format, id: asset.id, binding: "imported_assets[assetID]")
                }
            }
            model.sourceSTEP = nil
            model.inputAssets = nil
            let bytes = try encoder.encode(model)
            let modelPath = (originFolder ?? folder) + "/selection-origin-model.json"
            let url: URL
            if let existing = try? workspace.read(modelPath, maximumBytes: ProjectStore.maximumFileBytes), existing == bytes {
                url = try workspace.url(modelPath)
            } else { url = try workspace.write(bytes, path: modelPath) }
            modelReference = CodexSourceReference(name: "selection-origin-model.json", path: url.path, readPath: url.path,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), byteCount: bytes.count)
            if !inputs.isEmpty {
                let path = (originFolder ?? folder) + "/selection-geometry-inputs.json"
                let data = try JSONSerialization.data(withJSONObject: inputs, options: [.sortedKeys, .withoutEscapingSlashes])
                if let existing = try? workspace.read(path, maximumBytes: ProjectStore.maximumFileBytes), existing == data {
                    inputsPath = try workspace.url(path).path
                } else { inputsPath = try workspace.write(data, path: path).path }
            }
        }
        let matches = originModel != nil && originModel == current
        let file = CodexSelectionFile(selection: selection, originRecipeStatus: originModel == nil ? "unavailable" : "available", originModel: modelReference,
                                      originGeometryInputsManifestPath: inputsPath, originMatchesCurrent: matches)
        let path = try workspace.write(try encoder.encode(file), path: folder + "/selection.json").path
        return (path, matches)
    }

    private static var selectionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
