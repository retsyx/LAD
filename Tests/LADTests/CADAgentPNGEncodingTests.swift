import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class CADAgentPNGEncodingTests: XCTestCase {
    /// Direct CGImage encoding must keep the exact pixels, size and color
    /// space of the former TIFF/NSBitmapImageRep route, including alpha.
    func testSnapshotPNGMatchesTheTIFFRoutePixels() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for background in [NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1), NSColor.clear] {
            let image = snapshot(device: device, background: background, width: 321, height: 243)
            let encoded = try CADAgentRenderer.encodePNG(image)
            let legacy = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:]))
            XCTAssertEqual(Array(encoded.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            let direct = try XCTUnwrap(NSBitmapImageRep(data: encoded))
            let reference = try XCTUnwrap(NSBitmapImageRep(data: legacy))
            XCTAssertEqual(direct.pixelsWide, 321)
            XCTAssertEqual(direct.pixelsHigh, 243)
            XCTAssertEqual(direct.pixelsWide, reference.pixelsWide)
            XCTAssertEqual(direct.pixelsHigh, reference.pixelsHigh)
            XCTAssertEqual(direct.bitsPerPixel, reference.bitsPerPixel)
            XCTAssertEqual(direct.bitmapFormat, reference.bitmapFormat)
            XCTAssertEqual(direct.colorSpace, reference.colorSpace)
            XCTAssertEqual(pixels(direct), pixels(reference), "Background \(background)")
            XCTAssertGreaterThan(Set(pixels(direct)).count, 2, "The comparison must include rendered geometry.")
        }
    }

    private func snapshot(device: MTLDevice, background: NSColor, width: Int, height: Int) -> NSImage {
        let renderer = SCNRenderer(device: device, options: nil)
        let scene = SCNScene()
        scene.background.contents = background
        let box = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1))
        box.geometry?.firstMaterial?.diffuse.contents = NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        scene.rootNode.addChildNode(box)
        let translucent = SCNNode(geometry: SCNSphere(radius: 0.6))
        translucent.geometry?.firstMaterial?.diffuse.contents = NSColor(srgbRed: 0.1, green: 0.7, blue: 0.2, alpha: 0.5)
        translucent.position = SCNVector3(0.8, 0, 0)
        scene.rootNode.addChildNode(translucent)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(2, 2, 3)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
    }

    private func pixels(_ image: NSBitmapImageRep) -> [UInt8] {
        Array(UnsafeBufferPointer(start: image.bitmapData, count: image.bytesPerRow * image.pixelsHigh))
    }
}
