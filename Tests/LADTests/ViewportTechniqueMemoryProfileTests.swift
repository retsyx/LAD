import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

/// Opt-in measurement of the GPU memory the highlight technique allocates for
/// one frame. It reports figures without machine-specific thresholds.
final class ViewportTechniqueMemoryProfileTests: XCTestCase {
    @MainActor
    func testProfileHighlightTechniqueTargetMemory() throws {
        guard ProcessInfo.processInfo.environment["LAD_GPU_MEMORY_PROFILE"] == "1" else {
            throw XCTSkip("Set LAD_GPU_MEMORY_PROFILE=1 to measure highlight technique render targets.")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = CGSize(width: 2_560, height: 1_600)
        // One mode per process, so the other mode's freed targets cannot
        // distort the measurement.
        let modes = ProcessInfo.processInfo.environment["LAD_GPU_MEMORY_TRANSLUCENT"].map { [$0 == "1"] } ?? [false, true]
        for translucent in modes {
            let before = device.currentAllocatedSize
            let renderer = SCNRenderer(device: device, options: nil)
            let scene = SCNScene()
            scene.background.contents = CADSceneView.sceneBackgroundColor
            let box = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
            box.categoryBitMask = 1
            scene.rootNode.addChildNode(box)
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.position = SCNVector3(2, 2, 3)
            camera.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(camera)
            renderer.scene = scene
            renderer.pointOfView = camera
            renderer.technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: size.height, selected: .yellow,
                hover: .orange, hoverHalo: .white, ink: .black, translucentFaces: translucent))
            _ = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            let allocated = Double(device.currentAllocatedSize) - Double(before)
            print("LAD_GPU_MEMORY translucent=\(translucent) allocatedMB=\(String(format: "%.1f", allocated / 1_000_000))")
            withExtendedLifetime(renderer) {}
        }
    }
}
