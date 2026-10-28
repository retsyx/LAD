import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportSilhouetteTests: XCTestCase {
    @MainActor
    func testNestedSelectedItemsRetainTheirIndividualProjectionOutlines() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 2.5
        camera.position = SCNVector3(0, 0, 6)
        scene.rootNode.addChildNode(camera)
        for (index, width) in [CGFloat(3), CGFloat(1.5)].enumerated() {
            let surface = SCNNode(geometry: SCNPlane(width: width, height: width))
            surface.geometry?.materials = [constantMaterial(.red)]
            surface.categoryBitMask = CADHighlightTechnique.silhouetteCategory
            surface.name = CADHighlightTechnique.silhouetteNodeName(index)
            scene.rootNode.addChildNode(surface)
        }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: 240,
            selected: NSColor(srgbRed: 0.96, green: 0.63, blue: 0.23, alpha: 1),
            hover: .green, hoverHalo: .darkGray, ink: .black, silhouetteCount: 2))
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 320, height: 240),
                                      antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        for distance in [0.75, 1.5] {
            for position in [SCNVector3(distance, 0, 0), SCNVector3(0, distance, 0),
                             SCNVector3(-distance, 0, 0), SCNVector3(0, -distance, 0)] {
                let point = renderer.projectPoint(position)
                XCTAssertTrue((-2...2).contains { dy in (-2...2).contains { dx in
                    isGold(bitmap, x: Int(point.x.rounded()) + dx,
                        y: bitmap.pixelsHigh - Int(point.y.rounded()) + dy)
                } }, "An overlapping selection must retain each item's outline instead of outlining only their union.")
            }
        }
        XCTAssertFalse(isGold(bitmap, x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2),
            "The silhouette overlay must not fill either selected projection.")
    }

    @MainActor
    func testSelectedCubeUsesOnlyItsProjectedOutlineThroughANearerSolid() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for orthographic in [false, true] {
            let scene = SCNScene()
            scene.background.contents = NSColor.black
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = orthographic
            camera.camera?.orthographicScale = 2.6
            camera.camera?.fieldOfView = 38
            camera.camera?.zNear = 0.1
            camera.camera?.zFar = 30
            camera.position = SCNVector3(4, 3, 6)
            camera.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(camera)

            let cube = SCNNode(geometry: SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0))
            cube.geometry?.materials = [constantMaterial(.red)]
            cube.categoryBitMask = CADHighlightTechnique.silhouetteCategory
            cube.name = CADHighlightTechnique.silhouetteNodeName(0)
            scene.rootNode.addChildNode(cube)

            let occluder = SCNNode(geometry: SCNPlane(width: 20, height: 20))
            occluder.geometry?.materials = [constantMaterial(NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1))]
            occluder.simdPosition = simd_normalize(camera.simdPosition) * 3
            occluder.look(at: camera.position)
            scene.rootNode.addChildNode(occluder)

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = camera
            renderer.technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: 288,
                selected: NSColor(srgbRed: 0.96, green: 0.63, blue: 0.23, alpha: 1),
                hover: .green, hoverHalo: .darkGray, ink: .black, silhouetteCount: 1))
            XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 384, height: 288),
                                          antialiasingMode: .multisampling4X)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let corners = [-1.0, 1.0].flatMap { x in [-1.0, 1.0].flatMap { y in [-1.0, 1.0].map { z in
                let point = renderer.projectPoint(SCNVector3(x, y, z))
                return SIMD2<Double>(Double(point.x), Double(bitmap.pixelsHigh) - Double(point.y))
            } } }
            let boundary = hull(corners)
            XCTAssertEqual(boundary.count, 6, "The oblique cube fixture must have a hexagonal projection.")
            var goldCount = 0, interiorCount = 0, covered = 0, sampleCount = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where isGold(bitmap, x: x, y: y) {
                    goldCount += 1
                    let distance = distanceToBoundary(SIMD2(Double(x) + 0.5, Double(y) + 0.5), polygon: boundary)
                    if distance > 7 { interiorCount += 1 }
                }
            }
            for (start, end) in zip(boundary, Array(boundary.dropFirst()) + [boundary[0]]) {
                let steps = Int(simd_length(end - start))
                for step in 0...steps {
                    let point = start + (end - start) * Double(step) / Double(steps)
                    sampleCount += 1
                    if (-3...3).contains(where: { dy in (-3...3).contains { dx in
                        isGold(bitmap, x: Int(point.x.rounded()) + dx, y: Int(point.y.rounded()) + dy)
                    } }) { covered += 1 }
                }
            }
            XCTAssertGreaterThan(goldCount, 400, "The outline must render behind the independent nearer plane.")
            XCTAssertEqual(interiorCount, 0, "A selected cube must not draw its internal projected edges or triangle seams.")
            XCTAssertGreaterThan(Double(covered) / Double(sampleCount), 0.97,
                "The outline must cover the complete projection boundary in both camera projections.")
        }
    }

    @MainActor
    func testProductionPartAndFaceHighlightsKeepOccludedOutlinesAndDepthTestTheirFill() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let preview = squares()
        let selectedFace = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)
        for wholePart in [false, true] {
            for occluded in [false, true] {
                view.update(mesh: preview, mode: .shaded, grid: false, command: nil,
                    selectedSolids: wholePart ? [0] : [], hiddenSolids: occluded ? [] : [1],
                    selectedFeatures: wholePart ? [] : [selectedFace])
                let deadline = ContinuousClock.now + .seconds(10)
                while view.isPreparingCaptureResources, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertFalse(view.isPreparingCaptureResources)
                let camera = try XCTUnwrap(view.pointOfView)
                camera.position = SCNVector3(0, 0, 6)
                camera.look(at: SCNVector3Zero)
                camera.camera?.usesOrthographicProjection = true
                camera.camera?.orthographicScale = 2.5
                let png = try await CADAgentRenderer.capturePNG(view: view)
                let image = try XCTUnwrap(NSBitmapImageRep(data: png))
                let middle = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                if occluded {
                    XCTAssertLessThan(middle.redComponent - middle.blueComponent, 0.1,
                        "The highlight fill must remain behind nearer geometry in the normal surface pass.")
                    var outlinePixels = 0
                    for y in 0..<image.pixelsHigh {
                        for x in 0..<image.pixelsWide where isGold(image, x: x, y: y) { outlinePixels += 1 }
                    }
                    XCTAssertGreaterThan(outlinePixels, 300,
                        "Both selected native faces and selected parts need their complete no-depth outline in captures.")
                } else {
                    XCTAssertGreaterThan(middle.redComponent - middle.blueComponent, 0.15,
                        "Visible selected native faces and parts must receive the highlight color in the normal pass.")
                }
            }
        }
    }

    @MainActor
    func testHoverProjectionSlotsFollowTargetModeExitAndGeometryReplacement() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        var preview = squares()
        preview.vertices = [[-2, -1, 0], [-0.25, -1, 0], [-0.25, 1, 0], [-2, 1, 0],
                            [0.25, -1, 0], [2, -1, 0], [2, 1, 0], [0.25, 1, 0]]
        preview.bounds = [-2, -1, 0, 2, 1, 0]
        preview.stepPath = "/tmp/viewport-silhouette-hover-targets"
        view.update(mesh: preview, mode: .shaded, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        try await ready(view)
        // Use the native top-view command so picking and rendering share the
        // same camera state throughout repeated target changes.
        let centers = [SCNVector3(-1.125, 0, 0), SCNVector3(1.125, 0, 0)]
        let boundaries = [SCNVector3(-1.125, 1, 0), SCNVector3(1.125, 1, 0)]
        var originalTechnique: SCNTechnique?
        for target in [0, 1, 0, 1] {
            let projected = view.projectPoint(centers[target])
            XCTAssertEqual(view.feature(at: NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))),
                CADFeatureID(kind: .face, solidIndex: target, localIndex: 0))
            view.mouseMoved(with: try event(.mouseMoved, at: NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))))
            try await ready(view)
            let image = try await bitmap(view)
            XCTAssertTrue(hasGold(image, around: boundaries[target], in: view, hover: true),
                "The permanent projection slot must follow the newly hovered face.")
            XCTAssertFalse(hasGold(image, around: boundaries[1 - target], in: view, hover: true),
                "The previous face must lose its hover outline when the active mask count stays unchanged.")
            if let originalTechnique { XCTAssertTrue(view.technique === originalTechnique) }
            else { originalTechnique = view.technique }
        }
        for mode in [ViewportDisplayMode.translucent, .edges, .shaded] {
            view.update(mesh: preview, mode: mode, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: .isometric)
            let image = try await bitmap(view)
            XCTAssertTrue(hasGold(image, around: boundaries[1], in: view, hover: true),
                "Changing display mode must retain the current face outline and its mask binding.")
        }
        view.mouseExited(with: try event(.mouseExited, at: NSPoint(x: -1, y: -1)))
        let cleared = try await bitmap(view)
        XCTAssertFalse(hasGold(cleared, around: boundaries[1], in: view, hover: true))
        let projected = view.projectPoint(centers[0])
        view.mouseMoved(with: try event(.mouseMoved, at: NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))))
        try await ready(view)
        preview.stepPath = "/tmp/viewport-silhouette-hover-replacement"
        view.update(mesh: preview, mode: .shaded, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        let replaced = try await bitmap(view)
        XCTAssertFalse(hasGold(replaced, around: boundaries[0], in: view, hover: true),
            "Replacing geometry must discard the previous model's hover mask.")
    }

    @MainActor
    func testSelectedPlanarFaceRetainsItsLineProjectionWhenViewedEdgeOn() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        view.update(mesh: squares(), mode: .shaded, grid: false, command: nil,
            selectedSolids: [], hiddenSolids: [1],
            selectedFeatures: [CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)])
        try await ready(view)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0, -6, 0)
        camera.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 2.5
        let image = try await bitmap(view)
        for x in [-0.8, 0, 0.8] {
            XCTAssertTrue(hasGold(image, around: SCNVector3(x, 0, 0), in: view),
                "An edge-on selected face still has a visible line projection.")
        }
    }

    @MainActor
    private func bitmap(_ view: CADSceneView) async throws -> NSBitmapImageRep {
        let png = try await CADAgentRenderer.capturePNG(view: view)
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    @MainActor
    private func ready(_ view: CADSceneView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingCaptureResources, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(view.isPreparingCaptureResources)
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        if type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    }

    @MainActor
    private func hasGold(_ image: NSBitmapImageRep, around position: SCNVector3, in view: CADSceneView,
                         hover: Bool = false) -> Bool {
        let projected = view.projectPoint(position)
        let x = Int((CGFloat(projected.x) * CGFloat(image.pixelsWide) / view.bounds.width).rounded())
        let y = image.pixelsHigh - Int((CGFloat(projected.y) * CGFloat(image.pixelsHigh) / view.bounds.height).rounded())
        guard let value = view.technique?.value(forKey: hover ? "cadHoverColor" : "cadSelectedColor") as? NSValue else { return false }
        let linear = value.scnVector4Value
        func gamma(_ component: CGFloat) -> CGFloat {
            component <= 0.0031308 ? 12.92 * component : 1.055 * pow(component, 1 / 2.4) - 0.055
        }
        let reference = [gamma(linear.x), gamma(linear.y), gamma(linear.z)]
        return (-3...3).contains { dy in (-3...3).contains { dx in
            let column = x + dx, row = y + dy
            guard column >= 0, row >= 0, column < image.pixelsWide, row < image.pixelsHigh,
                  let color = image.colorAt(x: column, y: row) else { return false }
            // colorAt labels the PNG's encoded RGB samples as calibrated RGB.
            // Compare the stored channels directly with the shader's sRGB
            // output; converting that label would apply another gamma curve.
            return max(abs(color.redComponent - reference[0]), abs(color.greenComponent - reference[1]),
                abs(color.blueComponent - reference[2])) < 0.04
        } }
    }

    private func constantMaterial(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        return material
    }

    private func isGold(_ image: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh,
              let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return color.redComponent > 0.7 && color.greenComponent > 0.4 && color.blueComponent < 0.5
    }

    private func hull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            let first = b - a, second = c - a
            return first.x * second.y - first.y * second.x
        }
        func chain(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
            var result = [SIMD2<Double>]()
            for point in points {
                while result.count >= 2, cross(result[result.count - 2], result[result.count - 1], point) <= 0 {
                    result.removeLast()
                }
                result.append(point)
            }
            return Array(result.dropLast())
        }
        return chain(sorted) + chain(Array(sorted.reversed()))
    }

    private func distanceToBoundary(_ point: SIMD2<Double>, polygon: [SIMD2<Double>]) -> Double {
        zip(polygon, Array(polygon.dropFirst()) + [polygon[0]]).map { start, end in
            let edge = end - start
            let phase = max(0, min(1, simd_dot(point - start, edge) / simd_length_squared(edge)))
            return simd_length(point - start - edge * phase)
        }.min()!
    }

    private func squares() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0],
                                            [-2, -2, 0.3], [2, -2, 0.3], [2, 2, 0.3], [-2, 2, 0.3]],
            triangles: [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]], edges: [],
            bounds: [-2, -2, 0, 2, 2, 0.3], volume: 1, area: 20, solids: 2, faces: 2,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-silhouette-squares",
            triangleSolids: [0, 0, 1, 1], edgeSolids: [])
        preview.topology = CADTopology(vertices: [], edges: [], faces: [
            CADFace(id: CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0), type: "PLANE", area: 4, center: [0, 0, 0], normal: [0, 0, 1]),
            CADFace(id: CADFeatureID(kind: .face, solidIndex: 1, localIndex: 0), type: "PLANE", area: 16, center: [0, 0, 0.3], normal: [0, 0, 1])
        ], parts: [])
        preview.triangleFaces = [0, 0, 1, 1]
        return preview
    }
}
