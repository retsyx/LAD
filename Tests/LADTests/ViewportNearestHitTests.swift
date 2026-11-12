import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportNearestHitTests: XCTestCase {
    @MainActor
    func testLapelInteriorAlwaysPicksNearestFaceAcrossNodeOrderAndProjection() async throws {
        let coat = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)
        let lapel = CADFeatureID(kind: .face, solidIndex: 1, localIndex: 0)
        let orders = [[0, 1, 2], [1, 0, 2], [2, 0, 1], [2, 1, 0]]
        let visibility: [Set<Int>] = [[], [2], [1]]
        for projection in ViewportProjectionMode.allCases {
            let preview = panels()
            let view = try await preparedView(preview, projection: projection)
            let nodes = try (0..<3).map { index in
                try XCTUnwrap(view.scene.rootNode.childNode(withName: "solid:\(index)", recursively: true))
            }
            let parent = try XCTUnwrap(nodes[0].parent)
            for order in orders {
                nodes.forEach { $0.removeFromParentNode() }
                order.forEach { parent.addChildNode(nodes[$0]) }
                SCNTransaction.flush()
                for hidden in visibility {
                    let existingPart = hidden.contains(2) ? 0 : 2
                    view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                                selectedSolids: [existingPart], hiddenSolids: hidden, projection: projection)
                    SCNTransaction.flush()
                    let projected = view.projectPoint(SCNVector3(1.1, -0.15, 2.2))
                    let point = NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                    XCTAssertTrue(view.bounds.contains(point))
                    let expected = hidden.contains(1) ? coat : lapel
                    let picked = view.feature(at: point)
                    let context = "projection=\(projection.rawValue), order=\(order), hidden=\(hidden.sorted())"
                    XCTAssertEqual(picked, expected,
                        "The visible lapel must win even when coat geometry was submitted first; hidden owners must still be filtered. \(context)")
                    var featureSelections = [[CADFeatureID]]()
                    view.onFeatureSelectionChanged = { featureSelections.append($0) }
                    view.mouseDown(with: try click(at: point))
                    XCTAssertEqual(featureSelections, [[expected]], "Native clicks must select the same nearest face. \(context)")
                    XCTAssertEqual(view.agentCaptureMetadata["selectedSolidIndices"] as? [Int], [existingPart],
                                   "Selecting a face must preserve a distinct selected part. \(context)")

                    var partSelections = [Set<Int>]()
                    view.onSelectionChanged = { partSelections.append($0) }
                    view.mouseDown(with: try click(at: point, modifiers: .option))
                    XCTAssertEqual(partSelections, [[existingPart, expected.solidIndex]],
                                   "Option-click must select the nearest visible owner. \(context)")
                    XCTAssertEqual(featureSelections, [[expected]],
                                   "Selecting a whole part must preserve the previous feature selection. \(context)")
                    view.mouseDown(with: try click(at: point, modifiers: .option))
                    XCTAssertEqual(partSelections, [[existingPart, expected.solidIndex], [existingPart]],
                                   "A second Option-click must deselect the owner. \(context)")
                    XCTAssertEqual(featureSelections, [[expected]],
                                   "Deselecting a whole part must preserve the previous feature selection. \(context)")
                }
            }
        }
    }

    /// A local native preview and geometric probes can reproduce a reported
    /// design without storing that design or its generated geometry in tests.
    @MainActor
    func testPreparedPreviewFeatureProbes() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_VIEWPORT_PICKING_PROBES"] else {
            throw XCTSkip("Set LAD_VIEWPORT_PICKING_PROBES to a local preview/probe manifest.")
        }
        struct Probe: Decodable { var worldPoint: [Double]; var featureID: CADFeatureID }
        struct Manifest: Decodable { var preview: String; var points: [Probe] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let preview = try PreviewMesh.loadResult(at: URL(fileURLWithPath: manifest.preview))
        XCTAssertFalse(manifest.points.isEmpty)
        for projection in ViewportProjectionMode.allCases {
            // Face probes need enough screen space to lie outside the
            // generous vertex/edge targets on small decorative parts.
            let view = try await preparedView(preview, projection: projection,
                                              size: NSSize(width: 900, height: 1200))
            var clicked: [CADFeatureID] = []
            view.onFeatureSelectionChanged = { clicked = $0 }
            var expected: [CADFeatureID] = []
            for probe in manifest.points {
                guard probe.worldPoint.count == 3 else { throw LADError.message("A picking probe requires three coordinates.") }
                let world = probe.worldPoint
                let projected = view.projectPoint(SCNVector3(world[0], world[1], world[2]))
                let point = NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                XCTAssertTrue(view.bounds.contains(point))
                XCTAssertEqual(view.feature(at: point), probe.featureID, projection.rawValue)
                view.mouseDown(with: try click(at: point))
                expected.append(probe.featureID)
                XCTAssertEqual(clicked, expected, projection.rawValue)
            }
        }
    }

    private func click(at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func preparedView(_ preview: PreviewMesh, projection: ViewportProjectionMode,
                              size: NSSize = NSSize(width: 640, height: 480)) async throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(origin: .zero, size: size))
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.front),
                    selectedSolids: [], hiddenSolids: [], projection: projection)
        view.layout()
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        SCNTransaction.flush()
        return view
    }

    private func panels() -> PreviewMesh {
        // The coat lies behind a small inset lapel, matching the real design's
        // front (-Y) direction. A separate off-axis part exercises the branch
        // that must query all intersections when an unrelated part is hidden.
        let quads: [[[Double]]] = [
            [[-12,0,-10],[12,0,-10],[12,0,10],[-12,0,10]],
            [[-4,-0.15,-6],[4,-0.15,-6],[4,-0.15,6],[-4,-0.15,6]],
            [[28,0,-2],[32,0,-2],[32,0,2],[28,0,2]]
        ]
        var triangles = [[Int]](), edges = [[Double]](), triangleSolids = [Int](), edgeSolids = [Int]()
        var faces = [CADFace](), parts = [CADPart]()
        for (solid, quad) in quads.enumerated() {
            let base = solid * 4
            triangles += [[base, base + 1, base + 2], [base, base + 2, base + 3]]
            triangleSolids += [solid, solid]
            for index in 0..<4 {
                edges.append(quad[index] + quad[(index + 1) % 4])
                edgeSolids.append(solid)
            }
            let center = zip(quad[0], quad[2]).map { ($0 + $1) / 2 }
            faces.append(CADFace(id: CADFeatureID(kind: .face, solidIndex: solid, localIndex: 0), type: "PLANE",
                                 area: 1, center: center, normal: [0,-1,0]))
            parts.append(CADPart(solidIndex: solid, area: 1, volume: 1,
                                 bounds: [quad[0][0],quad[0][1],quad[0][2],quad[2][0],quad[2][1],quad[2][2]], centroid: center))
        }
        return PreviewMesh(vertices: quads.flatMap { $0 }, triangles: triangles, edges: edges,
            bounds: [-12,-0.15,-10,32,0,10], volume: 3, area: 3, solids: 3, faces: 3, buildSeconds: 0, threads: 1,
            stepPath: "/tmp/nearest-lapel-preview", triangleSolids: triangleSolids, edgeSolids: edgeSolids,
            topology: CADTopology(vertices: [], edges: [], faces: faces, parts: parts), triangleFaces: [0,0,1,1,2,2])
    }
}
