import CryptoKit
import Foundation

/// Preparing and verifying these files can hash/read large original inputs.
/// Call both phases off the main actor; only their bounded metadata crosses it.
enum CADAgentVersionFiles {
    struct File: Sendable {
        let path: String
        let data: Data
    }

    struct Prepared: Sendable {
        let files: [File]
        let inputSizes: [String: Int]
        let payload: Data
    }

    static func metadata(_ version: ProjectVersionContext.Version) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var info: [String: Any] = ["versionID": version.id.uuidString, "versionNumber": version.number,
                                   "version": version.label, "isCurrent": version.isCurrent,
                                   "title": version.model.title, "summary": String(version.model.summary.prefix(400)),
                                   "date": formatter.string(from: version.date)]
        if let name = version.name { info["name"] = name }
        return info
    }

    static func prepare(_ version: ProjectVersionContext.Version, workspace: CADAgentWorkspace) throws -> Prepared {
        try Task.checkCancellation()
        let model = version.model
        guard !model.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.script.utf8.count <= 200_000, !model.script.contains("\0") else {
            throw LADError.message("The saved version does not contain a valid complete CAD program.")
        }
        try ProjectStore.validateInputAssets(model.inputAssets ?? [])
        let base = "context/versions/\(version.id.uuidString)"
        var files: [File] = []
        var inputSizes: [String: Int] = [:]
        func path(_ relative: String) throws -> String { try workspace.url(relative).path }
        func encoded<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            return try encoder.encode(value)
        }
        func object(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        }
        func input(_ data: Data, format: String, name: String, id: String? = nil) throws -> [String: Any] {
            try Task.checkCancellation()
            let digest = SHA256.hexDigest(data)
            let suffix = format == "stp" ? "step" : format
            let relative = "context/versions/inputs/\(digest).\(suffix)"
            if inputSizes[relative] == nil { files.append(File(path: relative, data: data)) }
            inputSizes[relative] = data.count
            var info: [String: Any] = ["path": try path(relative), "name": name, "format": format,
                                       "byteCount": data.count, "sha256": digest]
            if let id { info["assetID"] = id; info["programBinding"] = "imported_assets[assetID]" }
            else { info["programBinding"] = "imported_model" }
            return info
        }

        let programPath = try path("\(base)/program.py")
        let modelPath = try path("\(base)/model.json")
        let manifestPath = try path("\(base)/inputs.json")
        let metadataPath = try path("\(base)/metadata.json")
        var manifest: [String: Any] = ["versionID": version.id.uuidString, "programPath": programPath, "modelPath": modelPath]
        var info = metadata(version)
        info["programPath"] = programPath
        info["modelPath"] = modelPath
        info["inputsManifestPath"] = manifestPath
        info["metadataPath"] = metadataPath
        info["readOnly"] = true

        var sourceModel = model
        sourceModel.sourceSTEP = nil
        sourceModel.inputAssets = nil
        files.append(File(path: "\(base)/program.py", data: Data(model.script.utf8)))
        files.append(File(path: "\(base)/model.json", data: try encoded(sourceModel)))
        let assets = try (model.inputAssets ?? []).map { asset in
            try input(asset.data, format: asset.format, name: asset.name, id: asset.id)
        }
        info["inputAssets"] = assets
        manifest["inputAssets"] = assets
        if let source = model.sourceSTEP {
            let name = model.sourceName ?? "original.step"
            try ProjectStore.validateInputAssets([CADInputAsset(id: "original-source", name: name, format: "step", data: source)])
            let original = try input(source, format: "step", name: name)
            info["sourceSTEP"] = original
            manifest["sourceSTEP"] = original
        }
        if let runtime = version.runtime {
            info["runtime"] = try JSONSerialization.jsonObject(with: encoded(runtime))
        }
        if var layout = version.partLayout {
            layout.nodes = PartColorState.nodesWithCurrentColors(layout.nodes, stored: version.partColors ?? [:])
            info["partsLayoutPath"] = try path("\(base)/parts-layout.json")
            files.append(File(path: "\(base)/parts-layout.json", data: try encoded(layout)))
        }
        if let parts = version.parts {
            info["partsPath"] = try path("\(base)/parts.json")
            let currentParts = PartColorState.nodesWithCurrentColors(parts, stored: version.partColors ?? [:])
            files.append(File(path: "\(base)/parts.json", data: try encoded(currentParts)))
        }
        if version.hiddenSolids != nil || version.partColors != nil || version.jointPositions != nil {
            var display: [String: Any] = [:]
            if let hidden = version.hiddenSolids { display["hiddenSolids"] = hidden }
            if let colors = version.partColors { display["partColors"] = try JSONSerialization.jsonObject(with: encoded(colors)) }
            if let positions = version.jointPositions { display["jointPositions"] = positions; info["jointPositions"] = positions }
            info["partDisplayPath"] = try path("\(base)/part-display.json")
            files.append(File(path: "\(base)/part-display.json", data: try object(display)))
        }
        info["replay"] = "To inspect this exact saved construction, call lad_build with the returned programPath and versionID. That build uses this version's original imported_model and imported_assets bindings without changing the current design or its inputs."
        info["finalProgramGuidance"] = "For a final authored program, retain the current design's bindings or explicitly lad_import only required original external files from this manifest and adapt the complete program to their new asset IDs. Build the final candidate without versionID. Never import prior generated geometry, LAD STEP exports or preview caches."
        manifest["usage"] = info["replay"]
        files.append(File(path: "\(base)/inputs.json", data: try object(manifest)))
        files.append(File(path: "\(base)/metadata.json", data: try object(info)))
        return Prepared(files: files, inputSizes: inputSizes, payload: try object(info))
    }

    static func write(_ prepared: Prepared, workspace: CADAgentWorkspace) throws {
        for file in prepared.files {
            try Task.checkCancellation()
            // Agent workspace files are editable. Reuse an exact cached file,
            // but restore a modified file from the immutable task snapshot.
            if let existing = try? workspace.read(file.path, maximumBytes: file.data.count, allowEmpty: true), existing == file.data {
                continue
            }
            try workspace.write(file.data, path: file.path)
        }
    }
}
