import simd
import XCTest
@testable import LAD

final class ViewportPickingPerformanceTests: XCTestCase {
    func testVisibleVertexAvoidsTheExpensiveFaceHitEntirely() {
        var faceQueries = 0
        func face() -> CADFeatureID? { faceQueries += 1; return id(.face, 0) }
        let vertex = projected(.vertex, 0, x: 20, y: 20)
        let picked = ViewportFeaturePicking.pick(at: SIMD2(20, 20), vertices: [vertex], edges: [], face: face())
        XCTAssertEqual(picked, vertex.id)
        XCTAssertEqual(faceQueries, 0, "A visible native vertex must not pay for an unrelated face ray query.")
    }

    func testVisibleEdgeAvoidsTheFaceHitAfterAnOccludedVertex() {
        var faceQueries = 0
        func face() -> CADFeatureID? { faceQueries += 1; return id(.face, 0) }
        let vertex = projected(.vertex, 0, x: 5, y: 1)
        let edge = ViewportFeaturePicking.Edge(id: id(.edge, 0),
            start: projected(.edge, 0, x: 0, y: 0), end: projected(.edge, 0, x: 10, y: 0))
        let picked = ViewportFeaturePicking.pick(at: SIMD2(5, 1), vertices: [vertex], edges: [edge], face: face(),
            isVisible: { world, _ in world.y == 0 })
        XCTAssertEqual(picked, edge.id)
        XCTAssertEqual(faceQueries, 0)
    }

    func testFaceIsQueriedExactlyOnceOnlyAfterNearbyTopologyFailsOcclusion() {
        var faceQueries = 0, visibilityQueries = 0
        let expected = id(.face, 0)
        func face() -> CADFeatureID? { faceQueries += 1; return expected }
        let edge = ViewportFeaturePicking.Edge(id: id(.edge, 0),
            start: projected(.edge, 0, x: 0, y: 0), end: projected(.edge, 0, x: 10, y: 0))
        let picked = ViewportFeaturePicking.pick(at: SIMD2(5, 1),
            vertices: [projected(.vertex, 0, x: 5, y: 1)], edges: [edge], face: face(),
            isVisible: { _, _ in visibilityQueries += 1; return false })
        XCTAssertEqual(picked, expected)
        XCTAssertEqual(visibilityQueries, 2, "Both native feature candidates must be rejected before falling back.")
        XCTAssertEqual(faceQueries, 1)
    }

    private func id(_ kind: CADFeatureKind, _ index: Int) -> CADFeatureID {
        CADFeatureID(kind: kind, solidIndex: 0, localIndex: index)
    }

    private func projected(_ kind: CADFeatureKind, _ index: Int, x: Double, y: Double) -> ViewportFeaturePicking.Vertex {
        .init(id: id(kind, index), world: SIMD3(x, y, 0), screen: SIMD2(x, y), depth: 10)
    }
}
