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
    func testThousandSelectedPartsUseOneBatchAndKeepTechniqueWhenSelectionShrinks() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 625), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let preview = tiledParts(count: 1_000)
        view.update(mesh: preview, mode: .wireframe, grid: false, command: ViewportCommand(.top),
                    selectedSolids: Set(0..<1_000), hiddenSolids: [], projection: .isometric)
        let deadline = ContinuousClock.now + .seconds(30)
        while view.isPreparingCaptureResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isPreparingCaptureResources)
        let technique = try XCTUnwrap(view.technique)
        let sequence = try XCTUnwrap(technique.dictionaryRepresentation["sequence"] as? [String])
        let capacity = sequence.filter { $0.hasPrefix("cadContour") }.count
        let activeBatches = (0..<capacity).filter { index in
            let rect = (technique.value(forKey: "cadSilhouetteBounds\(index)") as? NSValue)?.scnVector4Value
            return rect.map { $0.z > $0.x && $0.w > $0.y } ?? false
        }.count
        XCTAssertEqual(activeBatches, 1,
            "Selecting a disjoint thousand-part assembly must not add a thousand full-screen passes.")
        XCTAssertLessThanOrEqual(capacity, 2, "The initial isometric pose may leave one reusable empty bucket after the top-view command.")
        for _ in 0..<4 {
            view.refreshSilhouetteBatches()
            XCTAssertTrue(view.technique === technique,
                "SceneKit copies assigned techniques; bounds updates must reuse and mutate the installed copy.")
        }
        let start = ContinuousClock.now
        let png = try await CADAgentRenderer.capturePNG(view: view)
        XCTAssertTrue(view.technique === technique, "Independent output dimensions must not replace live attachments.")
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        for solid in [0, 19, 39, 480, 999] {
            let x = Double(solid % 40), y = Double(solid / 40)
            XCTAssertTrue(pixels(image, at: SCNVector3(x + 0.3, y, 0), in: view, radius: 2).contains(where: isGold),
                "The grouped mask must draw the complete outline of part \(solid), including batch children.")
            XCTAssertFalse(pixels(image, at: SCNVector3(x + 0.3, y + 0.3, 0), in: view, radius: 0).contains(where: isGold),
                "A silhouette must not fill the part's projected interior.")
        }
        print("LAD selected-part profile: 1000 parts, \(activeBatches) active contour batches / \(capacity) retained, capture \(ContinuousClock.now - start)")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: Set(0..<100), hiddenSolids: [], projection: .isometric)
        XCTAssertTrue(view.technique === technique, "Selection count changes inside retained batch capacity must reuse the technique.")
        let ordinaryPNG = try await CADAgentRenderer.capturePNG(view: view)
        let ordinary = try XCTUnwrap(NSBitmapImageRep(data: ordinaryPNG))
        XCTAssertTrue(pixels(ordinary, at: SCNVector3(39.3, 24, 0), in: view, radius: 2).contains {
            max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.12
        }, "An unselected part's ordinary edge ink must survive the shared mask and compositor.")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        XCTAssertTrue(view.technique === technique)
        let bounds = try XCTUnwrap(technique.value(forKey: "cadSilhouetteBounds0") as? NSValue).scnVector4Value
        XCTAssertEqual(bounds.x, 0); XCTAssertEqual(bounds.y, 0); XCTAssertEqual(bounds.z, 0); XCTAssertEqual(bounds.w, 0)
    }

    @MainActor
    func testLargeOverlappingSelectionReleasesDormantPasses() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
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
        func passCount() -> Int {
            (view.technique?.dictionaryRepresentation["sequence"] as? [String] ?? []).filter { $0.hasPrefix("cadContour") }.count
        }
        XCTAssertEqual(passCount(), 32)
        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [], projection: .isometric)
        XCTAssertEqual(passCount(), 1, "A previous large overlap must not leave its pass count attached to ordinary navigation.")
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
                    "Batching and bounded clears must retain every independent outline without stale rectangular ink. scale=\(scale), orthographic=\(orthographic)")
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
        var nodes: [SCNNode] = [], rectangles: [CADSilhouetteBatching.Rect?] = []
        for (index, definition) in definitions.enumerated() {
            let (x, y, width, height) = definition
            let node = SCNNode(geometry: SCNPlane(width: width, height: height))
            let material = SCNMaterial()
            material.lightingModel = .constant; material.diffuse.contents = index == 1 ? NSColor.green : NSColor.red
            material.isDoubleSided = true
            node.geometry?.materials = [material]
            node.position = SCNVector3(x, y, 0)
            node.categoryBitMask = CADHighlightTechnique.silhouetteCategory
            rectangles.append(CADSilhouetteBatching.project(bounds: [-width / 2, -height / 2, 0, width / 2, height / 2, 0],
                transform: node.simdTransform, projection: projection, pixels: size))
            nodes.append(node)
        }
        let batches = batched ? CADSilhouetteBatching.make(rectangles) : nodes.indices.map {
            CADSilhouetteBatching.Batch(items: [$0], rect: .full)
        }
        for (index, batch) in batches.enumerated() {
            let root = SCNNode()
            root.name = CADHighlightTechnique.silhouetteNodeName(index)
            root.categoryBitMask = CADHighlightTechnique.silhouetteCategory
            for item in batch.items { root.addChildNode(nodes[item]) }
            scene.rootNode.addChildNode(root)
        }
        let technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: 240,
            selected: NSColor(srgbRed: 0.96, green: 0.63, blue: 0.23, alpha: 1),
            hover: NSColor(srgbRed: 1, green: 0.9, blue: 0.5, alpha: 1), hoverHalo: .gray, ink: .black,
            silhouetteCount: batches.count))
        CADHighlightTechnique.setSilhouetteBounds(batches.map { $0.rect.vector }, on: technique)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene; renderer.pointOfView = camera; renderer.technique = technique
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        // Render twice through the same attachments. Fractional, moving bounds
        // must not reuse stale MSAA samples from the preceding larger masks.
        _ = renderer.snapshot(atTime: 0, with: CGSize(width: size.x, height: size.y), antialiasingMode: .multisampling4X)
        nodes[1].position.x += 0.137; nodes[1].position.y -= 0.073
        nodes[1].scale = SCNVector3(0.65, 0.65, 1)
        if batched {
            let moved = definitions.enumerated().map { index, definition -> CADSilhouetteBatching.Rect in
                let (_, _, width, height) = definition
                return CADSilhouetteBatching.project(bounds: [-width / 2, -height / 2, 0, width / 2, height / 2, 0],
                    transform: nodes[index].simdWorldTransform, projection: projection, pixels: size) ?? .full
            }
            CADHighlightTechnique.setSilhouetteBounds(batches.map { batch in
                batch.items.dropFirst().reduce(moved[batch.items[0]]) { $0.union(moved[$1]) }.vector
            }, on: try XCTUnwrap(renderer.technique))
        }
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: size.x, height: size.y), antialiasingMode: .multisampling4X)
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
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
