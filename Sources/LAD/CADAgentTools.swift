import AppKit
import CryptoKit
import CoreFoundation
import Darwin
import Foundation

/// LAD-owned operations available to the agent for one writable task workspace.
/// Builds remain speculative until the final program is committed by AppState.
@MainActor
final class CADAgentTools {
    private struct Artifact {
        var id: String
        var model: ModelSpec
        var preview: PreviewMesh?
        var programURL: URL
        var metadataURL: URL
        var versionID: UUID? = nil
        var parts: [PartNode] = []
        var partLayout: PartLayout? = nil
        var partColors: [String: PartColor] = [:]
        var colorChanges: [CADPartColorChange] = []
    }
    private let workspace: CADAgentWorkspace
    private let python: String
    private let threads: Int
    private let engine: EngineService
    private let permissionController: AgentPermissionController
    private let current: ModelSpec?
    private let versions: ProjectVersionContext
    private weak var viewport: CADSceneView?
    private weak var permissionWindow: NSWindow?
    private var permissionWindowWasBound: Bool
    private let hasPermissionViewport: Bool
    private let hiddenSolids: Set<Int>
    private let partLayout: PartLayout?
    private let initialPartColors: [String: PartColor]
    /// A per-call handoff of the exact PNG already returned by an image tool.
    /// It is consumed by the trusted bridge, never added to the tool JSON.
    private var renderedImageData: Data?
    private var artifacts: [String: Artifact] = [:]
    private var artifactOrder: [String] = []
    private var inputs: [String: CADInputAsset] = [:]
    private var versionInputSizes: [String: Int] = [:]
    private var versionTasks: [UUID: Task<CADAgentVersionFiles.Prepared, Error>] = [:]
    private var runtime: CADRuntime?
    private var permissionRequest: (id: UUID, task: Task<AgentPermissionDecision, Error>)?
    private var cancelled = false

    init(directory: URL, python: String, threads: Int, current: ModelSpec?, currentPreview: PreviewMesh?,
         engine: EngineService, viewport: CADSceneView? = nil, hiddenSolids: Set<Int> = [],
         solidColors: [Int: PartColor] = [:],
         referenceAssets: [CADInputAsset] = [], versions: ProjectVersionContext = .empty,
         partLayout: PartLayout? = nil, partColors: [String: PartColor] = [:],
         permissionController: AgentPermissionController? = nil) throws {
        workspace = try CADAgentWorkspace(directory: directory)
        self.python = python
        self.threads = threads
        self.current = current
        self.versions = versions
        self.engine = engine
        self.permissionController = permissionController ?? .shared
        self.viewport = viewport
        permissionWindow = viewport?.window
        permissionWindowWasBound = viewport?.window != nil
        hasPermissionViewport = viewport != nil
        self.hiddenSolids = hiddenSolids
        self.partLayout = partLayout
        let currentParts = partLayout?.nodes ?? Self.parts(in: currentPreview)
        if !currentParts.isEmpty {
            let count = currentPreview?.solids ?? (currentParts.flatMap(\.flattened).flatMap(\.solidIndices).max().map { $0 + 1 } ?? 0)
            try ProjectStore.validatePartHierarchy(currentParts, solidCount: count)
        }
        let physicalIDs = Self.physicalIDs(in: currentParts)
        guard partColors.count <= 4096, partColors.allSatisfy({ physicalIDs.contains($0.key) && $0.value.isValid }),
              solidColors.allSatisfy({ $0.key >= 0 && $0.key < (currentPreview?.solids ?? Int.max) && $0.value.isValid }) else {
            throw LADError.message("The current design has invalid part colors.")
        }
        var currentColors = Self.completePartColors(in: currentParts, colors: partColors)
        for node in currentParts.flatMap(\.flattened) where partColors[node.id] == nil && !node.solidIndices.isEmpty {
            let legacy = node.solidIndices.compactMap { solidColors[$0] }
            if legacy.count == node.solidIndices.count, let color = legacy.first, legacy.allSatisfy({ $0 == color }) {
                currentColors[node.id] = color
            }
        }
        self.initialPartColors = currentColors
        runtime = currentPreview?.runtime
        for asset in current?.inputAssets ?? [] {
            guard inputs[asset.id] == nil else { throw LADError.message("Imported geometry has duplicate asset identities.") }
            inputs[asset.id] = asset
        }
        // A queued selection may refer to an earlier revision's original
        // external inputs. Keep these available for exact origin replay without
        // changing the current design or substituting its imported_model.
        try registerReferenceAssets(referenceAssets)
        if let current {
            artifacts["current"] = Artifact(id: "current", model: current, preview: currentPreview,
                programURL: workspace.root.appendingPathComponent("context/current-model.json"),
                metadataURL: workspace.root.appendingPathComponent("artifacts/current/metadata.json"),
                parts: currentParts, partLayout: partLayout, partColors: currentColors)
        }
    }

    func registerReferenceAssets(_ assets: [CADInputAsset]) throws {
        guard assets.count <= 256 else { throw LADError.message("The selection has too many reference inputs.") }
        var merged = inputs
        for asset in assets {
            if let existing = merged[asset.id] {
                guard existing.format == asset.format, existing.data == asset.data else {
                    throw LADError.message("Selection reference inputs have conflicting geometry identities.")
                }
            } else { merged[asset.id] = asset }
        }
        guard merged.count <= 8_192 else { throw LADError.message("The selection has too many reference inputs.") }
        var bytes = 0
        for asset in merged.values {
            guard asset.data.count <= ProjectStore.maximumFileBytes - bytes else {
                throw LADError.message("The selection's reference inputs exceed the design's 256 MB storage limit.")
            }
            bytes += asset.data.count
        }
        inputs = merged
    }

    func resolveAssets(ids: [String]) throws -> [CADInputAsset] {
        try resolveAssets(ids: ids, available: inputs)
    }

    private func resolveAssets(ids: [String], available: [String: CADInputAsset]) throws -> [CADInputAsset] {
        guard ids.count <= 256, Set(ids).count == ids.count else {
            throw LADError.message("Choose at most 256 distinct imported geometry inputs.")
        }
        let assets = try ids.map { id in
            guard let asset = available[id] else { throw LADError.message("Imported geometry input ‘\(id)’ is unavailable in this build's input context.") }
            return asset
        }
        var total = 0
        for asset in assets {
            guard asset.data.count <= ProjectStore.maximumFileBytes - total else {
                throw LADError.message("Imported geometry inputs exceed the design's 256 MB storage limit.")
            }
            total += asset.data.count
        }
        return assets
    }

    func validatedPreview(for model: ModelSpec) -> PreviewMesh? {
        for id in Array(artifactOrder.reversed()) + ["current"] {
            guard let artifact = artifacts[id], constructionMatches(artifact.model, model),
                  let preview = artifact.preview,
                  preview.brepPath.map({ FileManager.default.fileExists(atPath: $0) }) == true else { continue }
            return preview
        }
        return nil
    }

    /// Only the chosen construction's speculative color patch crosses the
    /// successful task boundary. Other candidates and history remain isolated.
    func partColorChanges(for model: ModelSpec?) -> [CADPartColorChange] {
        guard !cancelled else { return [] }
        guard let model else { return artifacts["current"]?.colorChanges ?? [] }
        for id in Array(artifactOrder.reversed()) + ["current"] {
            guard let artifact = artifacts[id], constructionMatches(artifact.model, model) else { continue }
            guard artifact.versionID != nil else { return artifact.colorChanges }
            // Choosing a historical construction must also restore the exact
            // current colors that were reviewed.
            var changes: [String: CADPartColorChange] = [:]
            for id in Self.physicalIDs(in: artifact.parts) where artifact.partColors[id] != initialPartColors[id] {
                changes[id] = CADPartColorChange(partID: id, color: artifact.partColors[id])
            }
            for change in artifact.colorChanges { changes[change.partID] = change }
            return changes.values.sorted { $0.partID < $1.partID }
        }
        return []
    }

    func cancel() {
        cancelled = true
        renderedImageData = nil
        versionTasks.values.forEach { $0.cancel() }
        permissionRequest?.task.cancel()
        engine.cancel()
    }

    func consumeRenderedImage() -> Data? {
        defer { renderedImageData = nil }
        return renderedImageData
    }

    func handle(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        renderedImageData = nil
        try checkCancellation()
        switch name {
        case "lad_runtime":
            try allowed(arguments, [])
            if runtime == nil { runtime = try await engine.runtimeInfo(python: python, threads: threads) }
            return try result(["pythonExecutable": python, "runtime": try json(runtime!), "threads": threads,
                               "workspace": workspace.root.path,
                               "programInterface": "Full installed CadQuery and OCP Python APIs; assign result. cq, math, np and imported_assets are preloaded. imported_model is available when the current design has an original STEP input.",
                               "capabilities": ["sketches", "lofts", "sweeps", "splines", "surfaces", "shells", "offsets", "booleans", "assemblies", "direct OCP", "exact measurements", "PNG rendering", "STEP export"],
                               "externalTools": "External tools are user-managed. Before each new optional download or dependency installation, call lad_request_permission with the proposed operation and reason, even after a previous always-allow/always-deny result; Settings can change at any time. Proceed only when the current result has allowed true. That tool returns a decision only; you execute any approved operation in an isolated environment inside this task workspace, using LAD's Python as the base for a helper environment if needed. Never change LAD's shared runtime, global settings, original sources or files outside the task workspace. Final authored geometry must replay using only LAD's bundled CAD dependencies and registered reference inputs. lad_import is only for pre-existing external/reference inputs and faithful format conversions of user-provided inputs; never export/import or reimport geometry generated as part of this design by LAD or external tools.",
                               "apiHelp": "The selected runtime is ready to use. Inspect Python help(cq.Workplane.loft), help(cq.Solid), or installed OCP classes with workspace commands; no CAD environment bootstrap is needed.",
                               "inputAssets": inputs.values.sorted { $0.id < $1.id }.map { ["assetID": $0.id, "name": $0.name, "format": $0.format] }])
        case "lad_request_permission":
            try allowed(arguments, ["operation", "reason"])
            let operation = try permissionText("operation", arguments, maximum: 200)
            let reason = try permissionText("reason", arguments, maximum: 2_000)
            guard permissionRequest == nil else { throw LADError.message("A permission request is already pending for this task.") }
            let controller = permissionController
            let owner: NSWindow?
            if hasPermissionViewport {
                if !permissionWindowWasBound, let window = viewport?.window {
                    permissionWindow = window
                    permissionWindowWasBound = true
                }
                guard let window = permissionWindow, viewport?.window === window else { throw CancellationError() }
                owner = window
            } else { owner = nil }
            let id = UUID()
            let request = Task { try await controller.request(operation: operation, reason: reason, window: owner) }
            permissionRequest = (id, request)
            defer { if permissionRequest?.id == id { permissionRequest = nil } }
            let decision = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            try checkCancellation()
            return try result(["allowed": decision.allowed, "source": decision.source.rawValue,
                               "rememberedPolicy": decision.rememberedPolicy.map { $0.rawValue as Any } ?? NSNull(),
                               "scope": "task_workspace", "workspace": workspace.root.path,
                               "executionPerformed": false,
                               "nextStep": decision.allowed
                                   ? "Permission granted for this proposed operation inside this task workspace. Execute it yourself; LAD has not run anything. Use an isolated local environment for optional installs, keep final CAD replay dependent only on LAD's bundled dependencies, and query permission again for each new operation."
                                   : "Permission denied. Do not perform the proposed operation or rephrase/retry it without new user direction. Continue with existing or bundled capabilities, or explain the limitation."])
        case "lad_versions":
            try allowed(arguments, ["offset", "limit"])
            let offset = try integer("offset", arguments, fallback: 0, range: 0...1_000_000)
            let limit = try integer("limit", arguments, fallback: 50, range: 1...100)
            let page = Array(versions.versions.dropFirst(offset).prefix(limit))
            return try result(["offset": offset, "total": versions.versions.count,
                               "items": page.map(CADAgentVersionFiles.metadata),
                               "hasMore": offset + page.count < versions.versions.count])
        case "lad_version":
            try allowed(arguments, ["reference"])
            let reference = try string("reference", arguments, required: true)!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reference.isEmpty else { throw LADError.message("Choose a saved version by its versionID, vN label or exact custom name.") }
            let matches = versions.matches(reference: reference)
            guard !matches.isEmpty else { throw LADError.message("The saved version ‘\(reference)’ is unavailable. Use lad_versions to list this task's saved versions.") }
            guard matches.count == 1 else {
                return try result(["status": "ambiguous", "reference": reference,
                                   "candidates": matches.map(CADAgentVersionFiles.metadata),
                                   "nextStep": "Choose a candidate's stable versionID; no version was opened or rebuilt."])
            }
            return try await stageVersion(matches[0])
        case "lad_build":
            try allowed(arguments, ["programPath", "title", "summary", "assetIDs", "versionID"])
            let version = try string("versionID", arguments).map { try versions.version(id: $0) }
            let origin = version?.model ?? current
            let path = try string("programPath", arguments, required: true)!
            let bytes = try workspace.read(path, maximumBytes: 200_000)
            guard let script = String(data: bytes, encoding: .utf8), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LADError.message("The CAD program must be nonempty UTF-8 Python text.")
            }
            let ids = try strings("assetIDs", arguments) ?? (origin?.inputAssets ?? []).map(\.id)
            let selected: [CADInputAsset]
            if let version {
                let assets = version.model.inputAssets ?? []
                try ProjectStore.validateInputAssets(assets)
                selected = try resolveAssets(ids: ids, available: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }))
            } else { selected = try resolveAssets(ids: ids) }
            let model = ModelSpec(title: try boundedText("title", arguments, fallback: version?.model.title ?? "Untitled design", maximum: 160),
                                  summary: try boundedText("summary", arguments, fallback: version?.model.summary ?? "CAD program built and validated by LAD.", maximum: 6_000),
                                  units: "mm", script: script, sourceSTEP: origin?.sourceSTEP,
                                  sourceName: origin?.sourceName, inputAssets: selected.isEmpty ? nil : selected)
            let artifact = try await build(model, versionID: version?.id)
            return try result(summary(artifact))
        case "lad_import":
            try allowed(arguments, ["path", "name", "producerPaths"])
            let path = try string("path", arguments, required: true)!
            let producerPaths = try (strings("producerPaths", arguments) ?? []).map { try workspace.url($0).path }
            let url = try workspace.url(path)
            let format = url.pathExtension.lowercased() == "stp" ? "step" : url.pathExtension.lowercased()
            guard CADInputAsset.supportedFormats.contains(format) else {
                throw LADError.message("Import STEP, BREP, STL or OBJ geometry from the task workspace.")
            }
            let data = try workspace.read(path, maximumBytes: ProjectStore.maximumSTEPBytes)
            let id = "asset-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let asset = CADInputAsset(id: id, name: try boundedText("name", arguments, fallback: url.lastPathComponent, maximum: 255), format: format, data: data)
            let model = ModelSpec(title: "Imported geometry", summary: "Validated \(format.uppercased()) input geometry.", units: "mm",
                                  script: "result = imported_assets[\(String(data: try JSONEncoder().encode(id), encoding: .utf8)!)]\n",
                                  inputAssets: [asset])
            let artifact = try await build(model)
            inputs[id] = asset
            var info = summary(artifact)
            info["assetID"] = id
            info["name"] = asset.name
            info["format"] = format
            info["byteCount"] = data.count
            info["fidelity"] = ["stl", "obj"].contains(format)
                ? "Closed mesh converted to faceted BREP solids. Facets are retained; this is not a smooth-surface reconstruction. STEP export preserves the faceted solid."
                : "Native exact boundary representation retained."
            info["programBinding"] = "imported_assets[assetID]"
            info["producerPaths"] = producerPaths
            info["provenance"] = producerPaths.isEmpty
                ? "No producer files were specified. Optional producerPaths can retain source-conversion code and dependency descriptions for a pre-existing reference input in the task audit."
                : "Producer file references supplied for the saved task audit."
            return try result(info)
        case "lad_get_part_colors":
            try allowed(arguments, ["artifactID", "offset", "limit"])
            let artifact = try colorArtifact(arguments)
            let offset = try integer("offset", arguments, fallback: 0, range: 0...1_000_000)
            let limit = try integer("limit", arguments, fallback: 100, range: 1...500)
            return try result(colorPage(artifact, offset: offset, limit: limit))
        case "lad_set_part_colors":
            try allowed(arguments, ["artifactID", "changes"])
            var artifact = try colorArtifact(arguments)
            let changes = try colorChanges(arguments)
            let normalized = try PartColorState.normalized(changes: changes, in: artifact.parts)
            let updated = try PartColorState.applyingPhysical(changes: normalized, to: artifact.partColors, in: artifact.parts)
            var staged = Dictionary(uniqueKeysWithValues: artifact.colorChanges.map { ($0.partID, $0) })
            for change in normalized { staged[change.partID] = change }
            artifact.partColors = Self.completePartColors(in: artifact.parts, colors: updated)
            artifact.colorChanges = staged.values.sorted { $0.partID < $1.partID }
            artifacts[artifact.id] = artifact
            var info = try colorPage(artifact, offset: 0, limit: 100)
            info["staged"] = true
            info["changedPartCount"] = normalized.count
            info["nextStep"] = "Colors are staged for this artifact only. Use lad_render to review them when needed. A successful final response applies only the current design's patch or the final replacement program's matching artifact patch."
            return try result(info)
        case "lad_inspect":
            try allowed(arguments, ["artifactID", "kind", "solidIndices", "offset", "limit"])
            let artifact = try await artifact(arguments)
            guard let preview = artifact.preview else { throw LADError.message("The design preview is unavailable.") }
            let kind = try string("kind", arguments) ?? "summary"
            if kind == "summary" { return try result(summary(artifact)) }
            guard let topology = preview.topology else { throw LADError.message("The design has no native topology metadata.") }
            let solids = try indices(arguments, preview: preview, optional: true)
            let offset = try integer("offset", arguments, fallback: 0, range: 0...1_000_000)
            let limit = try integer("limit", arguments, fallback: 100, range: 1...500)
            let items: [[String: Any]]
            switch kind {
            case "parts":
                let nodes = artifact.parts.flatMap(\.flattened)
                items = try topology.parts.filter { solids?.contains($0.solidIndex) ?? true }.map { part in
                    var item = try json(part)
                    if let owner = nodes.first(where: { $0.solidIndices.contains(part.solidIndex) }) {
                        item["partID"] = owner.id; item["name"] = owner.name
                        item.merge(try colorInfo(owner, in: artifact)) { _, color in color }
                    }
                    return item
                }
            case "vertices": items = try topology.vertices.filter { solids?.contains($0.id.solidIndex) ?? true }.map(json)
            case "edges": items = try topology.edges.filter { solids?.contains($0.id.solidIndex) ?? true }.map {
                var item = try json($0); item.removeValue(forKey: "polyline"); return item
            }
            case "faces": items = try topology.faces.filter { solids?.contains($0.id.solidIndex) ?? true }.map(json)
            default: throw LADError.message("Inspect summary, parts, vertices, edges or faces.")
            }
            let page = Array(items.dropFirst(offset).prefix(limit))
            return try result(["artifactID": artifact.id, "kind": kind, "offset": offset,
                               "total": items.count, "items": page, "hasMore": offset + page.count < items.count])
        case "lad_measure":
            try allowed(arguments, ["artifactID", "features", "solidIndices"])
            let artifact = try await artifact(arguments)
            let preview = artifact.preview!
            let raw = arguments["features"] ?? []
            let features = try JSONDecoder().decode([CADFeatureID].self, from: JSONSerialization.data(withJSONObject: raw))
            guard features.count <= 256 else { throw LADError.message("Measure at most 256 features at once.") }
            let report = try await engine.measure(preview, features: features, solids: try indices(arguments, preview: preview, optional: true, allowEmpty: true) ?? [],
                                                  python: python, threads: threads)
            return try result(json(report))
        case "lad_validate":
            try allowed(arguments, ["artifactID"])
            let artifact = try await artifact(arguments)
            var info = summary(artifact)
            info["valid"] = true
            info["checks"] = ["Exact OpenCascade curve-on-surface validity", "closed oriented final solids", "positive finite part volumes and surface area", "STEP roundtrip preserves closed solids and per-part geometry", "finite dimensions", "native topology ownership", "preview integrity"]
            return try result(info)
        case "lad_render":
            try allowed(arguments, ["artifactID", "view", "projection", "display", "width", "height", "solidIndices",
                                    "yawDegrees", "elevationDegrees", "rollDegrees", "cameraPosition", "cameraTarget", "zoom"])
            let view = try string("view", arguments) ?? "isometric"
            guard ["isometric", "front", "back", "top", "bottom", "left", "right"].contains(view),
                  let projection = ViewportProjectionMode(rawValue: try string("projection", arguments) ?? "isometric"),
                  let display = ViewportDisplayMode(rawValue: try string("display", arguments) ?? "edges") else {
                throw LADError.message("Choose a standard camera view, perspective/isometric projection, and a supported rendering mode.")
            }
            let width = try integer("width", arguments, fallback: 1024, range: 256...2048)
            let height = try integer("height", arguments, fallback: 768, range: 256...2048)
            let camera = try renderCamera(arguments)
            let artifact = try await artifact(arguments)
            let preview = artifact.preview!
            let selected = try indices(arguments, preview: preview, optional: true)
            let hidden = selected.map { Set(0..<preview.solids).subtracting($0) } ?? []
            let captured = try await CADAgentRenderer.renderWithMetadata(preview: preview, view: view, projection: projection,
                display: display, hiddenSolids: hidden, solidColors: renderColors(for: artifact), width: width, height: height, camera: camera)
            try checkCancellation()
            let url = try workspace.write(captured.png, path: "renders/\(UUID().uuidString).png")
            var metadata = captured.metadata
            metadata.merge(["artifactID": artifact.id, "view": view, "projection": projection.rawValue,
                            "display": display.rawValue, "width": width, "height": height,
                            "zoom": camera.zoom, "customCamera": camera.isCustom,
                            "source": "LAD offscreen renderer"]) { _, supplied in supplied }
            metadata["cameraParameters"] = arguments.filter {
                ["yawDegrees", "elevationDegrees", "rollDegrees", "cameraPosition", "cameraTarget", "zoom"].contains($0.key)
            }
            return try imageResult(url, metadata: metadata)
        case "lad_screenshot":
            try allowed(arguments, [])
            if let viewport {
                let captured = try await CADAgentRenderer.captureWithMetadata(view: viewport)
                try checkCancellation()
                let url = try workspace.write(captured.png, path: "renders/\(UUID().uuidString).png")
                var metadata = captured.metadata
                metadata["source"] = "Current LAD viewport"
                metadata["artifactID"] = "current"
                return try imageResult(url, metadata: metadata)
            }
            let artifact = try await artifact([:])
            let png = try await CADAgentRenderer.renderPNG(preview: artifact.preview!, hiddenSolids: hiddenSolids, solidColors: renderColors(for: artifact))
            try checkCancellation()
            let url = try workspace.write(png, path: "renders/\(UUID().uuidString).png")
            return try imageResult(url, metadata: ["source": "LAD offscreen fallback; no live viewport is attached", "artifactID": artifact.id])
        case "lad_export_step":
            try allowed(arguments, ["artifactID", "path", "solidIndices"])
            let requestedID = try string("artifactID", arguments) ?? "current"
            let previous = artifacts[requestedID]
            let artifact = try await artifact(arguments)
            let preview = artifact.preview!
            var indices = try indices(arguments, preview: preview, optional: true)
            if let requested = indices, let previous, previous.preview == nil, !previous.parts.isEmpty {
                indices = try Self.remappedExportIndices(requested, from: previous.parts, to: artifact.parts)
            }
            let data = try await engine.exportSTEP(preview, solidIndices: indices, solidColors: renderColors(for: artifact),
                                                   python: python, threads: threads)
            try checkCancellation()
            let relative = try string("path", arguments) ?? "exports/\(artifact.id).step"
            let url = try workspace.write(data, path: relative)
            return try result(["artifactID": artifact.id, "path": url.path, "byteCount": data.count,
                               "solidIndices": (indices ?? Set(0..<preview.solids)).sorted()])
        default: throw LADError.message("Unknown LAD tool ‘\(name)’.")
        }
    }

    private func stageVersion(_ version: ProjectVersionContext.Version) async throws -> [String: Any] {
        let workspace = self.workspace
        let prepared = try await versionWork { try CADAgentVersionFiles.prepare(version, workspace: workspace) }
        try checkCancellation()
        var sizes = versionInputSizes
        for (path, count) in prepared.inputSizes { sizes[path] = count }
        var total = 0
        for count in sizes.values {
            guard count <= ProjectStore.maximumFileBytes - total else {
                throw LADError.message("Saved version inputs exceed the design's 256 MB storage limit.")
            }
            total += count
        }
        versionInputSizes = sizes
        _ = try await versionWork {
            try CADAgentVersionFiles.write(prepared, workspace: workspace)
            return prepared
        }
        try checkCancellation()
        guard let object = try JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any] else {
            throw LADError.message("The saved version metadata is unavailable.")
        }
        return try result(object)
    }

    private func versionWork(_ operation: @escaping @Sendable () throws -> CADAgentVersionFiles.Prepared) async throws -> CADAgentVersionFiles.Prepared {
        let id = UUID()
        let task = Task.detached(priority: .userInitiated, operation: operation)
        versionTasks[id] = task
        defer { versionTasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func build(_ model: ModelSpec, id: String? = nil, versionID: UUID? = nil) async throws -> Artifact {
        let id = id ?? UUID().uuidString
        let preview: PreviewMesh
        if let cached = validatedPreview(for: model) { preview = cached }
        else { preview = try await engine.buildPreview(model, python: python, threads: threads) }
        try checkCancellation()
        runtime = preview.runtime
        let programURL = try workspace.write(Data(model.script.utf8), path: "artifacts/\(id)/program.py")
        let metadataURL = workspace.root.appendingPathComponent("artifacts/\(id)/metadata.json")
        let defaults = Self.parts(in: preview)
        let previous = artifacts[id]
        let version = versionID.flatMap { identity in versions.versions.first { $0.id == identity } }
        let layout = previous?.partLayout ?? version?.partLayout ?? (versionID == nil ? partLayout : nil)
            ?? previous.flatMap { $0.parts.isEmpty ? nil : PartLayout(nodes: $0.parts) }
        let resolvedLayout = layout.map {
            $0.remappingGenericParts(to: defaults).reconciled(with: defaults,
                allowingPlacementChanges: Set(model.reorganizePartIDs ?? []))
        } ?? PartLayout(nodes: defaults)
        let nodes = resolvedLayout.nodes
        let inherited = previous?.partColors ?? (versionID != nil ? version?.partColors ?? [:]
            : artifacts["current"]?.partColors ?? initialPartColors)
        let physicalIDs = Self.physicalIDs(in: nodes)
        let patch = previous?.colorChanges ?? (versionID == nil ? artifacts["current"]?.colorChanges ?? [] : [])
        let artifact = Artifact(id: id, model: model, preview: preview, programURL: programURL, metadataURL: metadataURL,
            versionID: versionID, parts: nodes, partLayout: resolvedLayout,
            partColors: Self.completePartColors(in: nodes, colors: inherited),
            colorChanges: patch.filter { physicalIDs.contains($0.partID) })
        _ = try workspace.write(JSONSerialization.data(withJSONObject: summary(artifact), options: [.sortedKeys, .prettyPrinted]), path: "artifacts/\(id)/metadata.json")
        artifacts[id] = artifact
        if !artifactOrder.contains(id) { artifactOrder.append(id) }
        // Retain recipes for replay while bounding heavyweight display caches.
        for old in artifactOrder.dropLast(16) where old != "current" { artifacts[old]?.preview = nil }
        return artifact
    }

    private static func parts(in preview: PreviewMesh?) -> [PartNode] {
        guard let preview else { return [] }
        return preview.parts ?? (0..<preview.solids).map {
            PartNode(id: "solid/\($0)", name: "Part \($0 + 1)", solidIndices: [$0])
        }
    }

    private static func physicalIDs(in nodes: [PartNode]) -> Set<String> {
        Set(nodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map(\.id))
    }

    /// Color lookup can expose saved ownership before a cold replay. Keep an
    /// export subset attached to those physical identities if native order changes.
    private static func remappedExportIndices(_ requested: Set<Int>, from previous: [PartNode],
                                             to current: [PartNode]) throws -> Set<Int> {
        let owners = Dictionary(uniqueKeysWithValues: current.flatMap(\.flattened).filter {
            !$0.solidIndices.isEmpty
        }.map { ($0.id, $0.solidIndices) })
        var result = Set<Int>()
        for part in previous.flatMap(\.flattened) where !Set(part.solidIndices).isDisjoint(with: requested) {
            guard let indices = owners[part.id], indices.count == part.solidIndices.count else {
                throw LADError.message("Part ownership changed while rebuilding this artifact. Inspect its current parts before exporting a subset.")
            }
            for (old, new) in zip(part.solidIndices, indices) where requested.contains(old) { result.insert(new) }
        }
        guard result.count == requested.count else {
            throw LADError.message("The selected export parts are no longer available. Inspect the artifact's current parts.")
        }
        return result
    }

    private func colorArtifact(_ arguments: [String: Any]) throws -> Artifact {
        let id = try string("artifactID", arguments) ?? "current"
        guard let artifact = artifacts[id] else {
            throw LADError.message(id == "current" ? "There is no current design with parts to color."
                : "The requested CAD artifact is unavailable in this task.")
        }
        return artifact
    }

    private func colorChanges(_ arguments: [String: Any]) throws -> [CADPartColorChange] {
        guard let values = arguments["changes"] as? [[String: Any]], !values.isEmpty, values.count <= 256 else {
            throw LADError.message("Provide between 1 and 256 part color assignments.")
        }
        return try values.map { value in
            try allowed(value, ["partID", "color"])
            let id = try string("partID", value, required: true)!
            guard let raw = value["color"] else { throw LADError.message("Each part color assignment requires color, or null to use the neutral default finish.") }
            if raw is NSNull { return CADPartColorChange(partID: id, color: nil) }
            guard let components = raw as? [String: Any], Set(components.keys) == ["red", "green", "blue"] else {
                throw LADError.message("Part colors require red, green and blue sRGB components between 0 and 1.")
            }
            func component(_ name: String) throws -> Double {
                guard let number = components[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else {
                    throw LADError.message("Part color components must be finite sRGB numbers between 0 and 1.")
                }
                return number.doubleValue
            }
            return CADPartColorChange(partID: id, color: PartColor(red: try component("red"),
                green: try component("green"), blue: try component("blue")))
        }
    }

    private static func completePartColors(in nodes: [PartNode], colors: [String: PartColor]) -> [String: PartColor] {
        Dictionary(uniqueKeysWithValues: nodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map { node in
            (node.id, colors[node.id] ?? node.color ?? PartColorState.defaultFinish)
        })
    }

    private func colorInfo(_ node: PartNode, in artifact: Artifact) throws -> [String: Any] {
        ["color": try json(artifact.partColors[node.id] ?? PartColorState.defaultFinish)]
    }

    private func colorPage(_ artifact: Artifact, offset: Int, limit: Int) throws -> [String: Any] {
        var nodes: [(PartNode, String?)] = []
        func append(_ children: [PartNode], parent: String?) {
            for node in children { nodes.append((node, parent)); append(node.children ?? [], parent: node.id) }
        }
        append(artifact.parts, parent: nil)
        let page = try nodes.dropFirst(offset).prefix(limit).map { node, parent -> [String: Any] in
            var item: [String: Any] = ["partID": node.id, "name": node.name, "isGroup": node.isGroup,
                                      "solidIndices": node.solidIndices]
            if let parent { item["parentID"] = parent }
            if !node.solidIndices.isEmpty { item.merge(try colorInfo(node, in: artifact)) { _, color in color } }
            return item
        }
        return ["artifactID": artifact.id, "offset": offset, "total": nodes.count, "items": page,
                "hasMore": offset + page.count < nodes.count, "staged": !artifact.colorChanges.isEmpty]
    }

    private func renderColors(for artifact: Artifact) -> [Int: PartColor] {
        PartColorState.solidColors(in: artifact.parts, overrides: artifact.partColors)
    }

    private func artifact(_ arguments: [String: Any]) async throws -> Artifact {
        let id = try string("artifactID", arguments) ?? "current"
        if let artifact = artifacts[id] {
            return artifact.preview == nil ? try await build(artifact.model, id: id, versionID: artifact.versionID) : artifact
        }
        if id == "current", let current { return try await build(current, id: "current") }
        throw LADError.message(id == "current" ? "There is no current design. Build a CAD program first." : "The requested CAD artifact is unavailable in this task.")
    }

    private func summary(_ artifact: Artifact) -> [String: Any] {
        let preview = artifact.preview!
        var result: [String: Any] = ["artifactID": artifact.id, "units": "mm", "programPath": artifact.programURL.path,
                                    "metadataPath": artifact.metadataURL.path, "solids": preview.solids, "faces": preview.faces,
                                    "bounds": preview.bounds, "size": preview.size, "volume": preview.volume, "surfaceArea": preview.area,
                                    "buildSeconds": preview.buildSeconds, "threads": preview.threads,
                                    "assetIDs": (artifact.model.inputAssets ?? []).map(\.id),
                                    "topologyCounts": ["vertices": preview.topology?.vertices.count ?? 0,
                                                       "edges": preview.topology?.edges.count ?? 0, "faces": preview.topology?.faces.count ?? 0]]
        if let runtime = preview.runtime, let info = try? json(runtime) { result["runtime"] = info }
        if let versionID = artifact.versionID { result["versionID"] = versionID.uuidString }
        return result
    }

    private func constructionMatches(_ first: ModelSpec, _ second: ModelSpec) -> Bool {
        guard first.units == second.units, first.script == second.script, first.sourceSTEP == second.sourceSTEP else { return false }
        // Programs have the full Python API and may iterate imported_assets.
        // Its insertion order is therefore part of the construction contract.
        let a = first.inputAssets ?? []
        let b = second.inputAssets ?? []
        return a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.format == $1.format && $0.data == $1.data }
    }

    private func imageResult(_ url: URL, metadata: [String: Any]) throws -> [String: Any] {
        // Verify the renderer wrote a regular workspace file before the MCP
        // adapter reads it. The image itself remains a session-only artifact.
        let bytes = try workspace.read(url.path, maximumBytes: 32 * 1024 * 1024)
        var info = metadata
        info["path"] = url.path
        info["byteCount"] = bytes.count
        info["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var value = try result(info)
        var content = value["content"] as! [[String: Any]]
        content.append(["type": "image_path", "path": url.path, "mimeType": "image/png"])
        value["content"] = content
        renderedImageData = bytes
        return value
    }

    private func result(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func allowed(_ values: [String: Any], _ keys: Set<String>) throws {
        guard Set(values.keys).isSubset(of: keys) else { throw LADError.message("The LAD tool request contains unsupported arguments.") }
    }
    private func string(_ key: String, _ values: [String: Any], required: Bool = false) throws -> String? {
        guard let value = values[key] else {
            if required { throw LADError.message("The LAD tool requires ‘\(key)’.") }
            return nil
        }
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 8_192,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LADError.message("The LAD tool argument ‘\(key)’ must be nonempty text.")
        }
        return value
    }
    private func strings(_ key: String, _ values: [String: Any]) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard let list = value as? [String], list.count <= 256,
              list.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }) else {
            throw LADError.message("The LAD tool argument ‘\(key)’ must be an array of identities.")
        }
        return list
    }
    private func boundedText(_ key: String, _ values: [String: Any], fallback: String, maximum: Int) throws -> String {
        guard let value = (values[key] ?? fallback) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum, !value.contains("\0") else {
            throw LADError.message("‘\(key)’ must be nonempty text of at most \(maximum) characters.")
        }
        return value
    }
    private func permissionText(_ key: String, _ values: [String: Any], maximum: Int) throws -> String {
        let value = try string(key, values, required: true)!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= maximum else {
            throw LADError.message("‘\(key)’ must be nonempty text of at most \(maximum) characters.")
        }
        return value
    }
    private func integer(_ key: String, _ values: [String: Any], fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[key] else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), range.contains(number.intValue) else {
            throw LADError.message("The LAD tool argument ‘\(key)’ is outside its supported range.")
        }
        return number.intValue
    }

    private func renderCamera(_ values: [String: Any]) throws -> CADAgentCamera {
        func number(_ raw: Any, key: String) throws -> Double {
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
                throw LADError.message("The camera argument ‘\(key)’ must be a finite number.")
            }
            return value.doubleValue
        }
        func scalar(_ key: String) throws -> Double? {
            try values[key].map { try number($0, key: key) }
        }
        func point(_ key: String) throws -> [Double]? {
            guard let raw = values[key] else { return nil }
            guard let list = raw as? [Any], list.count == 3 else {
                throw LADError.message("The camera argument ‘\(key)’ must contain three millimetre coordinates.")
            }
            return try list.map { try number($0, key: key) }
        }
        var camera = CADAgentCamera()
        camera.yawDegrees = try scalar("yawDegrees")
        camera.elevationDegrees = try scalar("elevationDegrees")
        camera.rollDegrees = try scalar("rollDegrees") ?? 0
        camera.position = try point("cameraPosition")
        camera.target = try point("cameraTarget")
        camera.zoom = try scalar("zoom") ?? 1
        try camera.validate()
        return camera
    }
    private func indices(_ values: [String: Any], preview: PreviewMesh, optional: Bool, allowEmpty: Bool = false) throws -> Set<Int>? {
        guard let raw = values["solidIndices"] else { return optional ? nil : [] }
        guard let numbers = raw as? [NSNumber], (allowEmpty || !numbers.isEmpty), numbers.count <= preview.solids else {
            throw LADError.message("Choose at least one available solid index.")
        }
        var indices = Set<Int>()
        for number in numbers {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue),
                  (0..<preview.solids).contains(number.intValue), indices.insert(number.intValue).inserted else {
                throw LADError.message("The selected parts contain invalid or duplicate solid indices.")
            }
        }
        return indices
    }
}

/// Descriptor-relative I/O keeps the native host inside this task's workspace,
/// even if an agent replaces a parent directory while a tool is reading/writing.
struct CADAgentWorkspace: Sendable {
    let root: URL
    private let suppliedRoot: URL
    init(directory: URL) throws {
        suppliedRoot = directory.standardizedFileURL
        root = try EngineArtifact.canonicalDirectory(directory)
    }

    func url(_ path: String) throws -> URL {
        guard !path.isEmpty, path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LADError.message("Use a valid file path inside the task workspace.")
        }
        var url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        if url.path.hasPrefix(suppliedRoot.path + "/") {
            url = root.appendingPathComponent(String(url.path.dropFirst(suppliedRoot.path.count + 1)))
        }
        guard url.path.hasPrefix(root.path + "/"), url.path != root.path,
              !url.lastPathComponent.isEmpty else { throw LADError.message("Use a file path inside the task workspace.") }
        return url
    }

    func read(_ path: String, maximumBytes: Int, allowEmpty: Bool = false) throws -> Data {
        let url = try url(path)
        let parent = try parentDescriptor(url, create: false)
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LADError.message("The workspace file is missing or is a symbolic link.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size >= (allowEmpty ? 0 : 1), info.st_size <= maximumBytes else {
            throw LADError.message("Use a bounded regular workspace file without symbolic or hard links.")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1_048_576, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw LADError.message("The workspace file exceeds its size limit.") }
        }
        return data
    }

    @discardableResult
    func write(_ data: Data, path: String) throws -> URL {
        let url = try url(path)
        let parent = try parentDescriptor(url, create: true)
        defer { Darwin.close(parent) }
        let temporary = ".lad-\(UUID().uuidString)"
        let descriptor = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw LADError.message("Could not create a private workspace output.") }
        defer { Darwin.unlinkat(parent, temporary, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard Darwin.renameat(parent, temporary, parent, url.lastPathComponent) == 0 else {
            throw LADError.message("Could not finish writing the workspace output.")
        }
        return url
    }

    func prepareOutput(_ path: String) throws -> URL {
        let url = try url(path)
        let parent = try parentDescriptor(url, create: true)
        Darwin.close(parent)
        return url
    }

    private func parentDescriptor(_ url: URL, create: Bool) throws -> Int32 {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        let components = relative.split(separator: "/").dropLast().map(String.init)
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LADError.message("The task workspace is unavailable.") }
        for component in components {
            if create { _ = Darwin.mkdirat(descriptor, component, mode_t(0o700)) }
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw LADError.message("Workspace output directories must not contain symbolic links.") }
            descriptor = next
        }
        return descriptor
    }
}
