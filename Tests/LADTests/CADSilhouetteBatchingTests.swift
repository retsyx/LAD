import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class CADSilhouetteBatchingTests: XCTestCase {
    func testThousandDisjointMasksShareOnePassButNestedMasksKeepIndependentOutlines() {
        let rectangles = (0..<1_000).map { index -> CADSilhouetteBatching.Rect? in
            let x = Double(index % 40) * 0.05 - 1, y = Double(index / 40) * 0.08 - 1
            return .init(low: SIMD2(x, y), high: SIMD2(x + 0.03, y + 0.05))
        }
        let batches = CADSilhouetteBatching.make(rectangles)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(Set(batches[0].items), Set(rectangles.indices))

        let nested = (0..<32).map { index -> CADSilhouetteBatching.Rect? in
            let extent = 1 - Double(index) / 40
            return .init(low: SIMD2(repeating: -extent), high: SIMD2(repeating: extent))
        }
        XCTAssertEqual(CADSilhouetteBatching.make(nested).count, nested.count)
        XCTAssertTrue(CADSilhouetteBatching.make([nil, nil]).isEmpty)
    }

    func testPaddedBoundsAreConservativeForClippingAndEyePlaneCrossing() throws {
        let projection = AssemblyGrabProjection(worldToClip: [1, 0, 0, 0, 0, 1, 0, 0,
                                                               0, 0, 0, 0, 0, 0, -1, 0],
                                                 viewportSize: [400, 200])
        let pixels = SIMD2<Double>(400, 200)
        let bounds = try XCTUnwrap(CADSilhouetteBatching.project(bounds: [-0.5, -0.5, -2, 0.5, 0.5, -1],
            transform: matrix_identity_float4x4, projection: projection, pixels: pixels))
        XCTAssertLessThanOrEqual(bounds.low.x, -0.51)
        XCTAssertGreaterThanOrEqual(bounds.low.x, -0.515)
        XCTAssertGreaterThanOrEqual(bounds.high.y, 0.52)
        XCTAssertLessThanOrEqual(bounds.high.y, 0.53)
        XCTAssertEqual(CADSilhouetteBatching.project(bounds: [-1, -1, -1, 1, 1, 1],
            transform: matrix_identity_float4x4, projection: projection, pixels: pixels), .full)
        XCTAssertNil(CADSilhouetteBatching.project(bounds: [-1, -1, 1, 1, 1, 2],
            transform: matrix_identity_float4x4, projection: projection, pixels: pixels))
        XCTAssertNil(CADSilhouetteBatching.project(bounds: [10, 10, -2, 11, 11, -1],
            transform: matrix_identity_float4x4, projection: projection, pixels: pixels))
    }

    @MainActor
    func testThousandSelectedPartsShareOneBatchAndDeselectionDropsHighlightPasses() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 625))
        let preview = tiledParts(count: 1_000)
        view.update(mesh: preview, mode: .wireframe, grid: false, command: ViewportCommand(.top),
                    selectedSolids: Set(0..<1_000), hiddenSolids: [], projection: .isometric)
        let deadline = ContinuousClock.now + .seconds(30)
        while view.isPreparingCaptureResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isPreparingCaptureResources)
        // At Retina output the tiles' padded projections are disjoint. At 1×,
        // padding makes neighbors touch, which only alternates batches.
        let frame = view.makeFrame(width: 2_000, height: 1_250)
        XCTAssertEqual(frame.batches.count, 1,
            "Selecting a disjoint thousand-part assembly must not add a thousand mask passes.")
        XCTAssertEqual(frame.batches.first?.masks.count, 1_000)
        XCTAssertLessThanOrEqual(view.makeFrame(width: 1_000, height: 625).batches.count, 4)
        let start = ContinuousClock.now
        let png = try await CADAgentRenderer.capturePNG(view: view)
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        for solid in [0, 19, 39, 480, 999] {
            let x = Double(solid % 40), y = Double(solid / 40)
            XCTAssertTrue(pixels(image, at: SCNVector3(x + 0.3, y, 0), in: view, radius: 2).contains(where: isGold),
                "The grouped mask must draw the complete outline of part \(solid).")
            XCTAssertFalse(pixels(image, at: SCNVector3(x + 0.3, y + 0.3, 0), in: view, radius: 0).contains(where: isGold),
                "A silhouette must not fill the part's projected interior.")
        }
        print("LAD selected-part profile: 1000 parts, \(frame.batches.count) contour batch, capture \(ContinuousClock.now - start)")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: Set(0..<100), hiddenSolids: [], projection: .isometric)
        let ordinaryPNG = try await CADAgentRenderer.capturePNG(view: view)
        let ordinary = try XCTUnwrap(NSBitmapImageRep(data: ordinaryPNG))
        XCTAssertTrue(pixels(ordinary, at: SCNVector3(39.3, 24, 0), in: view, radius: 2).contains {
            max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.12
        }, "An unselected part's ordinary edge ink must survive the shared mask and compositor.")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        let cleared = view.makeFrame(width: 1_000, height: 625)
        XCTAssertFalse(cleared.hasHighlights, "Without highlights a frame is only its scene pass.")
        XCTAssertNil(cleared.highlightBounds)
    }

    @MainActor
    func testOverlappingSelectionUsesOnePassPerOverlapOnlyWhileSelected() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        var preview = tiledParts(count: 32)
        for index in preview.vertices.indices { preview.vertices[index][0] -= Double(index / 4) }
        for index in preview.edges.indices {
            preview.edges[index][0] -= Double(index / 4); preview.edges[index][3] -= Double(index / 4)
        }
        preview.bounds = [0, 0, 0, 0.6, 0.6, 0]
        view.update(mesh: preview, mode: .wireframe, grid: false, command: ViewportCommand(.top),
                    selectedSolids: Set(0..<32), hiddenSolids: [], projection: .isometric)
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingCaptureResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(view.makeFrame(width: 320, height: 240).batches.count, 32)
        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [], projection: .isometric)
        XCTAssertEqual(view.makeFrame(width: 320, height: 240).batches.count, 1,
                       "A previous large overlap must not leave its passes attached to ordinary navigation.")
    }

    @MainActor
    func testBoundedBatchPixelsMatchIndependentMasksWithNestedAndDisjointGeometry() throws {
        for scale in [1, 2] {
            for orthographic in [false, true] {
                let expected = try renderMasks(batched: false, scale: scale, orthographic: orthographic)
                let actual = try renderMasks(batched: true, scale: scale, orthographic: orthographic)
                var different = 0, gold = 0
                for y in 0..<expected.pixelsHigh {
                    for x in 0..<expected.pixelsWide {
                        let lhs = try XCTUnwrap(expected.colorAt(x: x, y: y)), rhs = try XCTUnwrap(actual.colorAt(x: x, y: y))
                        if max(abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
                               abs(lhs.blueComponent - rhs.blueComponent)) > 0.025 { different += 1 }
                        if isGold(rhs) { gold += 1 }
                    }
                }
                XCTAssertGreaterThan(gold, 200)
                XCTAssertLessThan(different, 8,
                    "Batching and bounded mask regions must retain every independent outline without stale rectangular ink. scale=\(scale), orthographic=\(orthographic)")
            }
        }
    }

    @MainActor
    private func renderMasks(batched: Bool, scale: Int, orthographic: Bool) throws -> NSBitmapImageRep {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = SCNScene()
        scene.background.contents = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = orthographic
        camera.camera?.projectionDirection = .vertical
        camera.camera?.orthographicScale = 2.5
        camera.camera?.fieldOfView = 45
        camera.position = SCNVector3(0, 0, 6)
        camera.eulerAngles.z = 0.17
        scene.rootNode.addChildNode(camera)
        let size = SIMD2<Double>(320 * Double(scale), 240 * Double(scale))
        let vertical = orthographic ? 2.5 : tan(45.0 * .pi / 360)
        let horizontal = vertical * size.x / size.y
        let c = cos(0.17), s = sin(0.17)
        let projection = AssemblyGrabProjection(worldToClip: [c / horizontal, s / horizontal, 0, 0,
            -s / vertical, c / vertical, 0, 0, 0, 0, 0, 0,
            0, 0, orthographic ? 0 : -1, orthographic ? 1 : 6], viewportSize: [size.x, size.y])
        let definitions: [(Double, Double, Double, Double)] = [
            (-0.9, 0.1, 2.0, 1.7), (-0.73, 0.19, 0.47, 0.66),
            (1.5, 1.2, 0.67, 0.45), (1.2, -1.1, 0.8, 0.63), (-2.4, -1.3, 0.4, 0.5)
        ]
        func rectangle(_ width: Double, _ height: Double) -> [[SIMD3<Float>]] {
            let w = Float(width / 2), h = Float(height / 2)
            return [[SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0)], [SIMD3(-w, -h, 0), SIMD3(w, h, 0), SIMD3(-w, h, 0)]]
        }
        func layout(moved: Bool) throws -> [CADViewportFrame.Batch] {
            var masks: [CADViewportFrame.Mask] = [], rectangles: [CADSilhouetteBatching.Rect?] = []
            for (index, definition) in definitions.enumerated() {
                let (x, y, width, height) = definition
                var transform = matrix_identity_float4x4
                transform.columns.3 = SIMD4(Float(x), Float(y), 0, 1)
                if moved && index == 1 {
                    transform.columns.3.x += 0.137; transform.columns.3.y -= 0.073
                    transform.columns.0.x = 0.65; transform.columns.1.y = 0.65
                }
                masks.append(try ViewportPassTestRenderer.mask(triangles: rectangle(width, height), selected: index != 1,
                                                               model: transform))
                rectangles.append(CADSilhouetteBatching.project(bounds: [-width / 2, -height / 2, 0, width / 2, height / 2, 0],
                    transform: transform, projection: projection, pixels: size))
            }
            let batches = batched ? CADSilhouetteBatching.make(rectangles) : masks.indices.map {
                CADSilhouetteBatching.Batch(items: [$0], rect: .full)
            }
            return batches.map { CADViewportFrame.Batch(rect: $0.rect, masks: $0.items.map { masks[$0] }) }
        }
        let palette = CADHighlightPalette(selected: NSColor(srgbRed: 0.96, green: 0.63, blue: 0.23, alpha: 1),
            hover: NSColor(srgbRed: 1, green: 0.9, blue: 0.5, alpha: 1), hoverHalo: .gray, ink: .black,
            background: try XCTUnwrap(scene.background.contents as? NSColor))
        // Render twice through the same targets. Moving, scaled bounds must not
        // reuse stale samples from the preceding larger masks.
        let passes = try CADViewportPasses(device: device)
        _ = try ViewportPassTestRenderer.render(scene: scene, camera: camera, width: Int(size.x), height: Int(size.y),
            referenceHeight: 240, palette: palette, batches: try layout(moved: false), passes: passes)
        let shot = try ViewportPassTestRenderer.render(scene: scene, camera: camera, width: Int(size.x), height: Int(size.y),
            referenceHeight: 240, palette: palette, batches: try layout(moved: true), passes: passes)
        return shot.image
    }

    @MainActor
    private func pixels(_ image: NSBitmapImageRep, at point: SCNVector3, in view: CADSceneView, radius: Int) -> [NSColor] {
        let position = view.projectPoint(point)
        let x = Int((Double(position.x) * Double(image.pixelsWide) / view.bounds.width).rounded())
        let y = image.pixelsHigh - Int((Double(position.y) * Double(image.pixelsHigh) / view.bounds.height).rounded())
        return (-radius...radius).flatMap { dy in (-radius...radius).compactMap { dx in
            let column = x + dx, row = y + dy
            guard column >= 0, row >= 0, column < image.pixelsWide, row < image.pixelsHigh else { return nil }
            return image.colorAt(x: column, y: row)
        } }
    }

    private func isGold(_ color: NSColor) -> Bool {
        color.redComponent > 0.7 && color.greenComponent > 0.4 && color.blueComponent < 0.5
    }

    private func tiledParts(count: Int) -> PreviewMesh {
        var vertices: [[Double]] = [], triangles: [[Int]] = [], edges: [[Double]] = []
        var triangleSolids: [Int] = [], edgeSolids: [Int] = []
        for solid in 0..<count {
            let x = Double(solid % 40), y = Double(solid / 40), first = vertices.count
            let points = [[x, y, 0], [x + 0.6, y, 0], [x + 0.6, y + 0.6, 0], [x, y + 0.6, 0]]
            vertices += points
            triangles += [[first, first + 1, first + 2], [first, first + 2, first + 3]]
            triangleSolids += [solid, solid]
            for index in 0..<4 { edges.append(points[index] + points[(index + 1) % 4]); edgeSolids.append(solid) }
        }
        return PreviewMesh(vertices: vertices, triangles: triangles, edges: edges,
            bounds: [0, 0, 0, 40, 25, 0], volume: 1, area: Double(count), solids: count, faces: count,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/silhouette-thousand-parts",
            triangleSolids: triangleSolids, edgeSolids: edgeSolids)
    }
}
