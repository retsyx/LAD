import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportVertexVisibilityTests: XCTestCase {
    @MainActor
    func testVisibleVertexKeepsItsCompleteSmallerCircleOnAnObliqueSurface() throws {
        for orthographic in [false, true] {
            for zoomedOut in [false, true] {
                for scale in [1, 2] {
                    for hover in [false, true] {
                        let shot = try render(orthographic: orthographic, zoomedOut: zoomedOut,
                                              scale: scale, hover: hover)
                        let mark = try footprint(shot.image, hover: hover)
                        let diameter = Double(hover ? CADVertexGeometry.hoverDiameter : CADVertexGeometry.selectedDiameter)
                        let expected = diameter * Double(scale)
                        let context = "orthographic=\(orthographic), far=\(zoomedOut), scale=\(scale), hover=\(hover)"
                        XCTAssertEqual(Double(mark.width), expected, accuracy: 2, context)
                        XCTAssertEqual(Double(mark.height), expected, accuracy: 2, context)
                        XCTAssertEqual(Double(mark.width), Double(mark.height), accuracy: 1, context)
                        XCTAssertGreaterThan(Double(mark.count), expected * expected * 0.60,
                            "The full disc must survive its own sloped face, rather than rendering as a half-disc: \(context)")
                        XCTAssertLessThan(Double(mark.count), Double(mark.width * mark.height) * 0.93,
                            "The smaller marker must retain a round footprint: \(context)")
                        if scale == 2, !zoomedOut {
                            let projection = orthographic ? "ortho" : "perspective"
                            let style = hover ? "hover" : "selected"
                            try shot.png.write(to: URL(fileURLWithPath: "/tmp/lad-vertex-visible-\(projection)-\(style).png"))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testASeparateNearerFaceDoesNotOccludeTheVertexOverlay() throws {
        for orthographic in [false, true] {
            for hover in [false, true] {
                for distance in [0.01, 0.5] {
                    let shot = try render(orthographic: orthographic, scale: 2, hover: hover,
                                          independentOccluderDistance: distance)
                    let mark = try footprint(shot.image, hover: hover)
                    let diameter = Double(hover ? CADVertexGeometry.hoverDiameter : CADVertexGeometry.selectedDiameter) * 2
                    XCTAssertGreaterThan(Double(mark.count), diameter * diameter * 0.60,
                        "The complete vertex overlay must remain visible behind a nearer face (distance \(distance)).")
                    XCTAssertEqual(Double(mark.width), diameter, accuracy: 2)
                    XCTAssertEqual(Double(mark.height), diameter, accuracy: 2)
                }
            }
        }
    }

    private struct Shot {
        let image: NSBitmapImageRep
        let png: Data
    }

    @MainActor
    private func render(orthographic: Bool, zoomedOut: Bool = false, scale: Int,
                        hover: Bool, independentOccluderDistance: Double? = nil) throws -> Shot {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = orthographic
        camera.camera?.orthographicScale = zoomedOut ? 4 : 2
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 100
        camera.camera?.wantsHDR = false
        camera.position = SCNVector3(0, 0, zoomedOut ? 10 : 6)
        scene.rootNode.addChildNode(camera)

        let surface = SCNNode(geometry: SCNPlane(width: 8, height: 8))
        let surfaceMaterial = SCNMaterial()
        surfaceMaterial.lightingModel = .constant
        surfaceMaterial.diffuse.contents = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        surfaceMaterial.isDoubleSided = true
        surface.geometry?.materials = [surfaceMaterial]
        // A view-facing billboard at this point would be cut in half by this
        // slope. A visible center seed must instead expand to a complete dot.
        surface.eulerAngles = SCNVector3(0, 0.85, 0)
        surface.categoryBitMask = 1
        scene.rootNode.addChildNode(surface)

        let geometry = CADVertexSeedGeometry.make([0, 0, 0])
        geometry.firstMaterial?.diffuse.contents = hover ? NSColor.red : NSColor.blue
        let seed = SCNNode(geometry: geometry)
        seed.categoryBitMask = CADHighlightTechnique.seedCategory
        scene.rootNode.addChildNode(seed)
        if let distance = independentOccluderDistance {
            let occluder = SCNNode(geometry: SCNPlane(width: 8, height: 8))
            occluder.geometry?.materials = [surfaceMaterial]
            occluder.position = SCNVector3(0, 0, distance)
            occluder.categoryBitMask = 1
            scene.rootNode.addChildNode(occluder)
        }

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        renderer.technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: 192,
            selected: NSColor(srgbRed: 0.96, green: 0.63, blue: 0.23, alpha: 1),
            hover: NSColor(srgbRed: 0.35, green: 0.83, blue: 0.72, alpha: 1),
            hoverHalo: NSColor(srgbRed: 0.14, green: 0.22, blue: 0.28, alpha: 1),
            ink: NSColor(srgbRed: 0.025, green: 0.035, blue: 0.045, alpha: 1)))
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 256 * scale, height: 192 * scale),
                                      antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return Shot(image: bitmap, png: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }

    private func footprint(_ image: NSBitmapImageRep, hover: Bool) throws -> (width: Int, height: Int, count: Int) {
        var minX = image.pixelsWide, minY = image.pixelsHigh, maxX = -1, maxY = -1, count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let isCore = hover
                    ? color.greenComponent > 0.65 && color.blueComponent > 0.5 && color.redComponent < 0.65
                    : color.redComponent > 0.7 && color.greenComponent > 0.4 && color.blueComponent < 0.5
                if isCore {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    count += 1
                }
            }
        }
        return (max(0, maxX - minX + 1), max(0, maxY - minY + 1), count)
    }
}
