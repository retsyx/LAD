import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

/// Renders hand-built scenes through the viewport's own passes, with explicit
/// unoccluded highlight seeds and outline masks.
@MainActor
struct ViewportPassShot {
    let image: NSBitmapImageRep
    let renderer: SCNRenderer
    let frame: CADViewportFrame

    /// Pixel color at a world point projected by the renderer that drew it.
    func color(at point: SCNVector3) throws -> NSColor {
        let projected = renderer.projectPoint(point)
        let x = min(image.pixelsWide - 1, max(0, Int(projected.x.rounded(.down))))
        let y = min(image.pixelsHigh - 1, max(0, image.pixelsHigh - 1 - Int(projected.y.rounded(.down))))
        return try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
}

@MainActor
enum ViewportPassTestRenderer {
    static let device = MTLCreateSystemDefaultDevice()

    /// Installs the translucent pass cameras and frame probe once per scene.
    static func source(scene: SCNScene, camera: SCNNode) -> CADViewportSceneSource {
        CADViewportSceneSource.adopt(scene: scene, camera: camera) ?? CADViewportSceneSource.install(in: scene, camera: camera)
    }

    static func seeds(_ segments: [[Double]], channel: CADViewportFrame.SeedChannel,
                      model: simd_float4x4 = matrix_identity_float4x4) throws -> CADViewportFrame.Seeds {
        let device = try XCTUnwrap(device)
        let points = segments.flatMap { s in
            [SIMD3<Float>(Float(s[0]), Float(s[1]), Float(s[2])), SIMD3<Float>(Float(s[3]), Float(s[4]), Float(s[5]))]
        }
        return .init(buffer: try XCTUnwrap(CADHighlightBuffers.Seeds(device: device, points: points, primitive: .line)),
                     channel: channel, model: model)
    }

    static func point(_ position: SIMD3<Float>, channel: CADViewportFrame.SeedChannel,
                      model: simd_float4x4 = matrix_identity_float4x4) throws -> CADViewportFrame.Seeds {
        let device = try XCTUnwrap(device)
        return .init(buffer: try XCTUnwrap(CADHighlightBuffers.Seeds(device: device, points: [position], primitive: .point)),
                     channel: channel, model: model)
    }

    /// A filled projection of triangles given as world-space corner lists.
    static func mask(triangles: [[SIMD3<Float>]], selected: Bool, lines: Bool = false,
                     model: simd_float4x4 = matrix_identity_float4x4) throws -> CADViewportFrame.Mask {
        let device = try XCTUnwrap(device)
        let corners = triangles.flatMap { $0 }
        let packed = corners.flatMap { [$0.x, $0.y, $0.z] }
        let positions = try XCTUnwrap(device.makeBuffer(bytes: packed, length: packed.count * 4, options: .storageModeShared))
        let indices = (0..<Int32(corners.count)).map { $0 }
        let buffer = try XCTUnwrap(CADHighlightBuffers.Mask(device: device, positions: positions,
            triangleIndices: indices.withUnsafeBufferPointer { Data(buffer: $0) }, includeLines: lines))
        return .init(buffer: buffer, selected: selected, model: model)
    }

    static func render(scene: SCNScene, camera: SCNNode, width: Int, height: Int, referenceHeight: Double? = nil,
                       translucent: Bool = false, palette: CADHighlightPalette = CADSceneView.highlightPalette,
                       seeds: [CADViewportFrame.Seeds] = [], batches: [CADViewportFrame.Batch] = [],
                       verticesEnabled: Bool? = nil, passes: CADViewportPasses? = nil) throws -> ViewportPassShot {
        let device = try XCTUnwrap(device)
        let source = source(scene: scene, camera: camera)
        var frame = CADViewportFrame(width: width, height: height, referenceHeight: referenceHeight ?? Double(height),
                                     translucent: translucent, palette: palette, seeds: seeds, batches: batches)
        frame.verticesEnabled = verticesEnabled ?? seeds.contains { $0.channel == .selectedVertex || $0.channel == .hoveredVertex }
        if frame.hasHighlights { frame.highlightBounds = .full }
        let renderer = SCNRenderer(device: device, options: nil)
        let image = try CADViewportCapture.image(of: frame, source: source, renderer: renderer, passes: passes)
        return ViewportPassShot(image: NSBitmapImageRep(cgImage: image), renderer: renderer, frame: frame)
    }

    /// The current state of a viewport, rendered offscreen at an output size.
    static func capture(_ view: CADSceneView, width: Int, height: Int) throws -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: try CADViewportCapture(view: view, width: width, height: height).image())
    }
}
