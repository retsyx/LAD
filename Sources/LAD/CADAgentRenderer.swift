import AppKit
import ImageIO
import Metal
import SceneKit
import UniformTypeIdentifiers

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
        let surface = CADSceneView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        surface.preparesRendererResources = false
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
                       selectedSolids: [], hiddenSolids: hiddenSolids, projection: projection, solidColors: solidColors,
                       solidTransforms: preview.assemblyPose?.solidTransforms ?? [:])
        try await waitForPreparation(surface)
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

    /// Encode the image's own CGImage. A TIFF round trip through
    /// NSBitmapImageRep produces the same pixels with two more full copies.
    nonisolated static func encodePNG(_ image: NSImage) throws -> Data {
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LADError.message("LAD could not encode the design image.")
        }
        return try encodePNG(pixels)
    }

    nonisolated static func encodePNG(_ pixels: CGImage) throws -> Data {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw LADError.message("LAD could not encode the design image.")
        }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LADError.message("LAD could not encode the design image.")
        }
        return encoded as Data
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw LADError.message("Design images must be between 1 and \(maximumDimension) pixels on each side.")
        }
    }

    private static func waitForPreparation(_ view: CADSceneView) async throws {
        guard try await view.waitForCaptureResources(until: .now + .seconds(30)) else {
            throw LADError.message("LAD could not prepare the design image. Try rendering it again.")
        }
    }

    private static func snapshotWithMetadata(of view: CADSceneView, width: Int, height: Int) async throws -> (png: Data, metadata: [String: Any]) {
        try Task.checkCancellation()
        let metadata = view.agentCaptureMetadata
        let capture = try CADViewportCapture(view: view, width: width, height: height)
        let writing = Task.detached(priority: .userInitiated) {
            try capture.pngData()
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
