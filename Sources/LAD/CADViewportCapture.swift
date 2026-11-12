import AppKit
import Metal
import SceneKit

/// An independent copy of a viewport's scene and highlight state, rendered
/// offscreen through the viewport's own passes. Native geometry buffers are
/// immutable and shared; mutable materials, cameras and lights are copied,
/// so a user's orbit or color change never affects the image and capturing
/// never changes the live view.
final class CADViewportCapture: @unchecked Sendable {
    let source: CADViewportSceneSource
    let frame: CADViewportFrame

    @MainActor
    init(view: CADSceneView, width: Int, height: Int) throws {
        guard let camera = view.pointOfView else {
            throw LADError.message("The design camera is unavailable for capture.")
        }
        source = try Self.isolatedCopy(of: view.scene, camera: camera)
        frame = view.makeFrame(width: width, height: height)
    }

    var width: Int { frame.width }
    var height: Int { frame.height }

    /// Renders on the calling thread and waits for the GPU. Cancellation of
    /// the calling task stops preparation before any frame is encoded.
    func image() throws -> CGImage {
        try Self.image(of: frame, source: source)
    }

    /// Renders a frame of any scene source offscreen through the viewport's
    /// passes, preparing a renderer of its own unless one is supplied.
    static func image(of frame: CADViewportFrame, source: CADViewportSceneSource,
                      renderer existing: SCNRenderer? = nil, passes existingPasses: CADViewportPasses? = nil) throws -> CGImage {
        try Task.checkCancellation()
        guard let device = existing?.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw LADError.message("Metal is unavailable, so LAD cannot render a design image.")
        }
        let renderer = existing ?? SCNRenderer(device: device, options: nil)
        renderer.scene = source.scene
        renderer.pointOfView = source.camera
        renderer.usesReverseZ = true
        renderer.autoenablesDefaultLighting = false
        guard renderer.prepare(source.scene, shouldAbortBlock: { Task.isCancelled }) else {
            try Task.checkCancellation()
            throw LADError.message("LAD could not prepare the design image.")
        }
        try Task.checkCancellation()
        let width = frame.width, height = frame.height
        let passes = try existingPasses ?? CADViewportPasses(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: CADViewportPasses.colorFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else {
            throw LADError.message("LAD could not allocate the design image.")
        }
        passes.encode(frame, source: source, renderer: renderer, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status != .completed {
            throw LADError.message("LAD could not render the design image.")
        }
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // The target stores BGRA bytes in sRGB, with opaque alpha.
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                           | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw LADError.message("LAD could not encode the design image.")
        }
        return image
    }

    func pngData() throws -> Data {
        let png = try CADAgentRenderer.encodePNG(try image())
        try Task.checkCancellation()
        return png
    }

    @MainActor
    private static func isolatedCopy(of source: SCNScene, camera sourceCamera: SCNNode) throws -> CADViewportSceneSource {
        let scene = SCNScene()
        scene.background.contents = source.background.contents
        scene.lightingEnvironment.contents = source.lightingEnvironment.contents
        scene.lightingEnvironment.intensity = source.lightingEnvironment.intensity
        let root = source.rootNode.clone()
        var copiedCamera: SCNNode?
        func isolate(_ original: SCNNode, _ copy: SCNNode) {
            if original === sourceCamera { copiedCamera = copy }
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
        guard let camera = copiedCamera, let copied = CADViewportSceneSource.adopt(scene: scene, camera: camera) else {
            throw LADError.message("The design camera is unavailable for capture.")
        }
        return copied
    }
}
