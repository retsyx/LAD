import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

/// Opt-in measurement of the GPU memory the viewport passes allocate for one
/// frame. It reports figures without machine-specific thresholds.
final class ViewportPassMemoryProfileTests: XCTestCase {
    @MainActor
    func testProfileViewportPassTargetMemory() throws {
        guard ProcessInfo.processInfo.environment["LAD_GPU_MEMORY_PROFILE"] == "1" else {
            throw XCTSkip("Set LAD_GPU_MEMORY_PROFILE=1 to measure viewport render targets.")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let width = 2_560, height = 1_600
        // One mode per process, so the other mode's freed targets cannot
        // distort the measurement.
        let modes = ProcessInfo.processInfo.environment["LAD_GPU_MEMORY_TRANSLUCENT"].map { [$0 == "1"] } ?? [false, true]
        for translucent in modes {
            // No highlight, a hovered edge, and a selection covering the frame.
            let areas: [(String, CADSilhouetteBatching.Rect?)] = [
                ("none", nil), ("hover", .init(low: SIMD2(-0.1, -0.1), high: SIMD2(0.1, 0.1))), ("full", .full)
            ]
            for (highlight, bounds) in areas {
                let scene = SCNScene()
                scene.background.contents = CADSceneView.sceneBackgroundColor
                let box = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
                scene.rootNode.addChildNode(box)
                let camera = SCNNode()
                camera.camera = SCNCamera()
                camera.position = SCNVector3(2, 2, 3)
                camera.look(at: SCNVector3Zero)
                scene.rootNode.addChildNode(camera)
                let source = CADViewportSceneSource.install(in: scene, camera: camera)
                var frame = CADViewportFrame(width: width, height: height, referenceHeight: Double(height) / 2,
                                             translucent: translucent, palette: CADSceneView.highlightPalette)
                if let bounds {
                    frame.seeds = [try ViewportPassTestRenderer.seeds([[-0.1, -0.1, 0.5, 0.1, -0.1, 0.5]], channel: .hoveredEdge)]
                    frame.highlightBounds = bounds
                }
                let target = try XCTUnwrap(device.makeTexture(descriptor: {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: CADViewportPasses.colorFormat,
                        width: width, height: height, mipmapped: false)
                    descriptor.usage = .renderTarget
                    descriptor.storageMode = .private
                    return descriptor
                }()))
                let renderer = SCNRenderer(device: device, options: nil)
                XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
                let queue = try XCTUnwrap(device.makeCommandQueue())
                let before = device.currentAllocatedSize
                let passes = try CADViewportPasses(device: device)
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                passes.encode(frame, source: source, renderer: renderer, into: target, commandBuffer: commandBuffer)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                let allocated = Double(device.currentAllocatedSize) - Double(before)
                print("LAD_GPU_MEMORY translucent=\(translucent) highlight=\(highlight) allocatedMB=\(String(format: "%.1f", allocated / 1_000_000))")
                withExtendedLifetime((passes, renderer)) {}
            }
        }
    }
}
