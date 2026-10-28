import AppKit
import Metal
import SceneKit

/// Agent images use the same prepared geometry, camera convention, materials
/// and lights as LAD's viewer, without capturing the desktop or moving its view.
@MainActor
enum CADAgentRenderer {
    static let maximumDimension = 2_048

    static func render(preview: PreviewMesh, to url: URL, view: String = "isometric",
                       projection: ViewportProjectionMode = .isometric,
                       display: ViewportDisplayMode = .edges, hiddenSolids: Set<Int> = [],
                       solidColors: [Int: PartColor] = [:], width: Int = 1_024, height: Int = 768,
                       camera: CADAgentCamera = .init()) async throws -> URL {
        let data = try await renderPNG(preview: preview, view: view, projection: projection, display: display,
                                       hiddenSolids: hiddenSolids, solidColors: solidColors, width: width, height: height,
                                       camera: camera)
        return try await write(data, to: url)
    }

    static func renderPNG(preview: PreviewMesh, view: String = "isometric",
                          projection: ViewportProjectionMode = .isometric,
                          display: ViewportDisplayMode = .edges, hiddenSolids: Set<Int> = [],
                          solidColors: [Int: PartColor] = [:], width: Int = 1_024, height: Int = 768,
                          camera: CADAgentCamera = .init()) async throws -> Data {
        let captured = try await renderWithMetadata(preview: preview, view: view, projection: projection, display: display,
            hiddenSolids: hiddenSolids, solidColors: solidColors, width: width, height: height, camera: camera)
        return captured.png
    }

    /// The returned pose and projection describe the actual detached camera
    /// captured with these pixels, rather than the optional requested controls.
    static func renderWithMetadata(preview: PreviewMesh, view: String = "isometric",
                                   projection: ViewportProjectionMode = .isometric,
                                   display: ViewportDisplayMode = .edges, hiddenSolids: Set<Int> = [],
                                   solidColors: [Int: PartColor] = [:], width: Int = 1_024, height: Int = 768,
                                   camera: CADAgentCamera = .init()) async throws -> (png: Data, metadata: [String: Any]) {
        try validateDimensions(width: width, height: height)
        try camera.validate()
        guard ["isometric", "front", "back", "left", "right", "top", "bottom"].contains(view) else {
            throw LADError.message("Choose isometric, front, back, left, right, top, or bottom for the design image.")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw LADError.message("Metal is unavailable, so LAD cannot render a design image.")
        }
        let surface = CADSceneView(frame: NSRect(x: 0, y: 0, width: width, height: height), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        var fittingPreview = preview
        // An isolated component should fill its image rather than remaining
        // tiny inside the complete assembly's bounds. CAD coordinates stay put.
        if !hiddenSolids.isEmpty, let parts = preview.topology?.parts {
            let visible = parts.filter { !hiddenSolids.contains($0.solidIndex) && $0.bounds.count == 6 }
            if !visible.isEmpty {
                fittingPreview.bounds = (0..<3).map { axis in visible.map { $0.bounds[axis] }.min()! }
                    + (0..<3).map { axis in visible.map { $0.bounds[axis + 3] }.max()! }
            }
        }
        surface.update(mesh: fittingPreview, mode: display, grid: false, command: nil,
                       selectedSolids: [], hiddenSolids: hiddenSolids, projection: projection, solidColors: solidColors)
        guard surface.hasRenderableGeometry else { throw LADError.message("The design has no renderable geometry.") }
        try surface.configureAgentView(named: view, camera: camera)
        surface.layout()
        try await waitForPreparation(surface)
        return try await snapshotWithMetadata(of: surface, width: width, height: height)
    }

    static func capture(view: CADSceneView, to url: URL) async throws -> URL {
        let data = try await capturePNG(view: view)
        return try await write(data, to: url)
    }

    static func capturePNG(view: CADSceneView) async throws -> Data {
        let captured = try await captureWithMetadata(view: view)
        return captured.png
    }

    /// Camera/visibility facts are captured in the same main-actor operation
    /// as the scene clone, before background rendering can overlap user input.
    static func captureWithMetadata(view: CADSceneView) async throws -> (png: Data, metadata: [String: Any]) {
        guard view.bounds.width.isFinite, view.bounds.height.isFinite,
              view.bounds.width >= 1, view.bounds.height >= 1 else {
            throw LADError.message("The design viewport is not ready for capture.")
        }
        try await waitForPreparation(view)
        let scale = view.window?.backingScaleFactor ?? 1
        let requestedWidth = view.bounds.width * scale
        let requestedHeight = view.bounds.height * scale
        let factor = min(1, CGFloat(maximumDimension) / max(requestedWidth, requestedHeight))
        let width = max(1, Int((requestedWidth * factor).rounded()))
        let height = max(1, Int((requestedHeight * factor).rounded()))
        return try await snapshotWithMetadata(of: view, width: width, height: height)
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw LADError.message("Design images must be between 1 and \(maximumDimension) pixels on each side.")
        }
    }

    private static func waitForPreparation(_ view: CADSceneView) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while view.isPreparingCaptureResources {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw LADError.message("LAD could not prepare the design image. Try rendering it again.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }

    private static func snapshotWithMetadata(of view: CADSceneView, width: Int, height: Int) async throws -> (png: Data, metadata: [String: Any]) {
        guard let sourceScene = view.scene, let sourceCamera = view.pointOfView else {
            throw LADError.message("The design viewport has no renderable scene.")
        }
        try Task.checkCancellation()
        let metadata = view.agentCaptureMetadata
        let snapshot = try CADAgentSceneSnapshot(scene: sourceScene, camera: sourceCamera,
            technique: view.technique, width: width, height: height)
        let writing = Task.detached(priority: .userInitiated) {
            try snapshot.pngData()
        }
        let png = try await withTaskCancellationHandler {
            try await writing.value
        } onCancel: { writing.cancel() }
        return (png, metadata)
    }

    private static func write(_ data: Data, to url: URL) async throws -> URL {
        let writing = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
            return url
        }
        return try await withTaskCancellationHandler { try await writing.value } onCancel: { writing.cancel() }
    }
}

/// Own a detached scene graph before handing it to the rendering queue. Native
/// geometry buffers are immutable and shared; mutable material/camera/light
/// objects are copied so a user's orbit or color change cannot affect the image.
private final class CADAgentSceneSnapshot: @unchecked Sendable {
    let scene: SCNScene
    let camera: SCNNode
    let technique: SCNTechnique?
    let width: Int
    let height: Int

    @MainActor
    init(scene source: SCNScene, camera sourceCamera: SCNNode, technique: SCNTechnique?, width: Int, height: Int) throws {
        let scene = SCNScene()
        scene.background.contents = source.background.contents
        scene.lightingEnvironment.contents = source.lightingEnvironment.contents
        scene.lightingEnvironment.intensity = source.lightingEnvironment.intensity
        let root = source.rootNode.clone()
        var copiedCamera: SCNNode?
        func isolate(_ original: SCNNode, _ copy: SCNNode) {
            if original === sourceCamera { copiedCamera = copy }
            if original.name == CADHighlightTechnique.completionNodeName {
                // Independent captures must not acknowledge a live viewport.
                copy.rendererDelegate = nil
            }
            if let geometry = original.geometry?.copy() as? SCNGeometry {
                if let originalGeometry = original.geometry {
                    CADStrokeGeometry.copyParameters(from: originalGeometry, to: geometry)
                }
                geometry.materials = original.geometry?.materials.map { ($0.copy() as? SCNMaterial) ?? $0 } ?? []
                copy.geometry = geometry
            }
            copy.camera = original.camera?.copy() as? SCNCamera
            copy.light = original.light?.copy() as? SCNLight
            for (originalChild, copiedChild) in zip(original.childNodes, copy.childNodes) {
                isolate(originalChild, copiedChild)
            }
        }
        isolate(source.rootNode, root)
        scene.rootNode.addChildNode(root)
        guard let camera = copiedCamera else {
            throw LADError.message("The design camera is unavailable for capture.")
        }
        self.scene = scene
        self.camera = camera
        self.technique = technique.flatMap { CADHighlightTechnique.copy($0) }
        self.width = width
        self.height = height
    }

    func pngData() throws -> Data {
        try Task.checkCancellation()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LADError.message("Metal is unavailable, so LAD cannot render a design image.")
        }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.usesReverseZ = true
        renderer.technique = technique
        renderer.autoenablesDefaultLighting = false
        guard renderer.prepare(scene, shouldAbortBlock: { Task.isCancelled }) else {
            try Task.checkCancellation()
            throw LADError.message("LAD could not prepare the design image.")
        }
        try Task.checkCancellation()
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw LADError.message("LAD could not encode the design image.")
        }
        try Task.checkCancellation()
        return png
    }
}
