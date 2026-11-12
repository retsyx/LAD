import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class CameraClippingTests: XCTestCase {
    @MainActor
    func testDistantGeometryRendersInBothProjections() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this machine.")
        }

        for projection in ViewportProjectionMode.allCases {
            let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            view.update(mesh: nil, mode: .shaded, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: projection)
            let scene = try XCTUnwrap(view.scene)
            let cameraNode = try XCTUnwrap(view.pointOfView)
            let camera = try XCTUnwrap(cameraNode.camera)

            // This lies well beyond the former 5,000-unit far plane. Keep the
            // box visibly sized in each projection so subpixel size cannot
            // explain a missing result.
            let depth: Float = 1_000_000
            let halfHeight = camera.usesOrthographicProjection
                ? camera.orthographicScale
                : Double(depth) * tan(Double(camera.fieldOfView) * .pi / 360)
            let side = halfHeight * 0.8
            let box = SCNBox(width: side, height: side, length: side, chamferRadius: 0)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.white
            box.materials = [material]
            let probe = SCNNode(geometry: box)
            probe.simdPosition = cameraNode.simdWorldPosition + cameraNode.simdWorldFront * depth
            scene.rootNode.addChildNode(probe)

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = cameraNode
            let size = CGSize(width: 128, height: 128)
            let automaticRange = camera.automaticallyAdjustsZRange
            camera.automaticallyAdjustsZRange = false
            camera.zFar = 5_000
            let cutoff = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .none)
            camera.automaticallyAdjustsZRange = automaticRange
            // Auto-fitted planes are internal to rendering; SceneKit's separate
            // frustum query still uses the camera's explicit zNear/zFar values.
            let visible = renderer.snapshot(atTime: 1, with: size, antialiasingMode: .none)
            probe.isHidden = true
            let hidden = renderer.snapshot(atTime: 2, with: size, antialiasingMode: .none)
            XCTAssertLessThan(try changedPixelCount(cutoff, hidden), 20,
                              "The probe must lie beyond the old draw cutoff.")
            XCTAssertGreaterThan(try changedPixelCount(visible, hidden), 200,
                                 "Distant geometry produced no visible surface in \(projection.rawValue).")
        }
    }

    private func changedPixelCount(_ first: NSImage, _ second: NSImage) throws -> Int {
        let firstBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(first.tiffRepresentation)))
        let secondBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(second.tiffRepresentation)))
        XCTAssertEqual(firstBitmap.pixelsWide, secondBitmap.pixelsWide)
        XCTAssertEqual(firstBitmap.pixelsHigh, secondBitmap.pixelsHigh)
        var count = 0
        for y in 0..<firstBitmap.pixelsHigh {
            for x in 0..<firstBitmap.pixelsWide {
                let a = try XCTUnwrap(firstBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(secondBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let difference = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                if difference > 0.1 { count += 1 }
            }
        }
        return count
    }
}
