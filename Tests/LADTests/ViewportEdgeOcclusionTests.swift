import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportEdgeOcclusionTests: XCTestCase {
    @MainActor
    func testNearSurfaceInteriorCurvesNeverBleedThroughAnOpaqueCover() throws {
        // Tiny interior clearances are ordinary in assemblies. A depth bias
        // that is constant in normalized coordinates can lift these curves
        // through the cover as the camera's clipping range changes.
        for orthographic in [false, true] {
            let exposed = try render(orthographic: orthographic, near: 0.01, scale: 2, cover: false)
            XCTAssertGreaterThan(magentaPixels(in: exposed), 500,
                "The hidden-curve fixture must contain substantial visible ink when the cover is removed.")
            for near in [0.01, 1.0] {
                for scale in [1, 2] {
                    let image = try render(orthographic: orthographic, near: near, scale: scale)
                    XCTAssertEqual(magentaPixels(in: image), 0,
                        "Interior curves 0.001–0.01 units below the cover must remain hidden (orthographic=\(orthographic), near=\(near), scale=\(scale)).")
                    if near == 0.01, scale == 2 {
                        try write(image, to: "/tmp/lad-covered-curves-\(orthographic ? "ortho" : "perspective").png")
                    }
                }
            }
        }
    }

    @MainActor
    func testCoplanarCurvesRemainContinuousAcrossClippingRangesAndBackingScales() throws {
        for orthographic in [false, true] {
            for near in [0.01, 1.0] {
                for scale in [1, 2] {
                    let image = try render(orthographic: orthographic, near: near, scale: scale, coplanar: true)
                    // The complete straight edge crosses the central half of
                    // the image. Measure each column so broken or absent ink
                    // cannot pass merely because some endpoints still draw.
                    let range = image.pixelsWide * 3 / 8..<image.pixelsWide * 5 / 8
                    let visible = range.filter { x in
                        (image.pixelsHigh / 2 - 4 * scale...image.pixelsHigh / 2 + 4 * scale).contains { y in
                            isMagenta(image.colorAt(x: x, y: y))
                        }
                    }.count
                    XCTAssertGreaterThanOrEqual(Double(visible) / Double(range.count), 0.99,
                        "A curve on its own opaque face must remain continuous (orthographic=\(orthographic), near=\(near), scale=\(scale)).")
                }
            }
        }
    }

    @MainActor
    func testSubpixelNearlyViewParallelSegmentsCannotProjectTheirCapsThroughACover() throws {
        // The endpoints are safely below the cover, but the projected segment
        // is shorter than a tenth of a pixel. Extrapolating its depth tangent
        // by a full screen-width cap advances it many units toward the camera.
        for orthographic in [false, true] {
            for scale in [1, 2] {
                let exposed = try render(orthographic: orthographic, near: 1, scale: scale,
                    cover: false, nearParallel: true)
                XCTAssertGreaterThan(magentaPixels(in: exposed), 0,
                    "The phase-shifted exposed subpixel segments must produce some ink across the raster samples.")
                let covered = try render(orthographic: orthographic, near: 1, scale: scale,
                    nearParallel: true)
                XCTAssertEqual(magentaPixels(in: covered), 0,
                    "The cap of an edge at least two units below the cover must remain occluded (orthographic=\(orthographic), scale=\(scale)).")
            }
        }
    }

    @MainActor
    private func render(orthographic: Bool, near: Double, scale: Int,
                        cover: Bool = true, coplanar: Bool = false,
                        nearParallel: Bool = false) throws -> NSBitmapImageRep {
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = orthographic
        camera.camera?.orthographicScale = 30
        camera.camera?.fieldOfView = 38
        camera.camera?.projectionDirection = .vertical
        camera.camera?.automaticallyAdjustsZRange = false
        camera.camera?.zNear = near
        camera.camera?.zFar = 1_000
        camera.camera?.wantsHDR = false
        camera.position = SCNVector3(0, 0, 100)
        scene.rootNode.addChildNode(camera)

        if cover {
            let plane = SCNPlane(width: 90, height: 70)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(srgbRed: 0.32, green: 0.67, blue: 0.80, alpha: 1)
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.categoryBitMask = 1
            scene.rootNode.addChildNode(node)
        }

        var segments = [[Double]]()
        if nearParallel {
            // Individual subpixel footprints may legitimately fall between
            // MSAA samples. Sweep small X/Y phases so the positive control
            // tests the collection rather than requiring every edge to hit a
            // sample. Every endpoint stays at least two units below the cover.
            for xPhase in 0..<16 {
                for yPhase in 0..<4 {
                    let x = (Double(xPhase) - 7.5) * 0.025
                    let y = (Double(yPhase) - 1.5) * 0.12
                    segments.append([x - 0.01, y, -2, x + 0.01, y, -4])
                }
            }
        } else if coplanar {
            segments = [[-22, 0, 0, 22, 0, 0]]
        } else {
            for (center, clearance) in [(-10.0, 0.001), (0.0, 0.003), (10.0, 0.01)] {
                let points = (0...128).map { index -> [Double] in
                    let angle = Double(index) * 2 * .pi / 128
                    return [center + 3 * cos(angle), 3 * sin(angle), -clearance]
                }
                segments += zip(points, points.dropFirst()).map { $0.0 + $0.1 }
            }
        }
        let geometry = CADStrokeGeometry.make(segments, color: .magenta, viewportHeight: 240,
            surfaces: Array(repeating: nearParallel ? CADStrokeSurface() : CADStrokeSurface(first: SIMD3(0, 0, 1)),
                count: segments.count))
        let edges = SCNNode(geometry: geometry)
        edges.categoryBitMask = 2
        edges.renderingOrder = 1
        scene.rootNode.addChildNode(edges)

        let palette = CADHighlightPalette(selected: .yellow, hover: .yellow, hoverHalo: .white, ink: .black, background: .black)
        return try ViewportPassTestRenderer.render(scene: scene, camera: camera, width: 320 * scale, height: 240 * scale,
            referenceHeight: 240, palette: palette).image
    }

    private func magentaPixels(in image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide where isMagenta(image.colorAt(x: x, y: y)) { count += 1 }
        }
        return count
    }

    private func isMagenta(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB) else { return false }
        return color.redComponent > color.greenComponent + 0.18 &&
            color.blueComponent > color.greenComponent + 0.18
    }

    private func write(_ image: NSBitmapImageRep, to path: String) throws {
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
