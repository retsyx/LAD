import Foundation
import XCTest
@testable import LAD

final class CADStrokeSurfaceTests: XCTestCase {
    func testTriangleWindingAndReversedDuplicateSegmentsShareOnePlane() {
        let mesh = makeMesh(vertices: [[0, 0, 0], [2, 0, 0], [0, 3, 0]], triangles: [[0, 1, 2]], edges: [
            [0, 0, 0, 2, 0, 0], [2, 0, 0, 0, 0, 0], [0, 0, 0, 2, 0, 0], [0, 0, 0, 1, 1, 0]
        ])
        let surfaces = CADStrokeSurface.matching(mesh)
        XCTAssertEqual(surfaces.count, mesh.edges.count)
        for surface in surfaces.prefix(3) {
            XCTAssertEqual(surface.first, SIMD3(0, 0, 1))
            XCTAssertEqual(surface.second, .zero)
        }
        XCTAssertEqual(surfaces[3].first, .zero)
        var reversed = mesh
        reversed.triangles = [[0, 2, 1]]
        XCTAssertEqual(CADStrokeSurface.matching(reversed)[0].first, SIMD3(0, 0, -1))
    }

    func testDuplicatedFaceVerticesInLocatedWorldCoordinatesRetainTwoAdjacentPlanes() {
        let mesh = makeMesh(vertices: [
            [1000, 2000, 3000], [1002, 2000, 3000], [1000, 2003, 3000],
            [1002, 2000, 3000], [1000, 2000, 3000], [1000, 2000, 3004]
        ], triangles: [[0, 1, 2], [3, 4, 5]], edges: [[1000, 2000, 3000, 1002, 2000, 3000]])
        let surface = CADStrokeSurface.matching(mesh)[0]
        XCTAssertEqual(surface.first, SIMD3(0, 0, 1))
        XCTAssertEqual(surface.second, SIMD3(0, 1, 0))
    }

    func testCoplanarAndOppositeWindingDuplicatesDoNotDisplaceTheOtherAdjacentPlane() {
        let mesh = makeMesh(vertices: [[0, 0, 0], [2, 0, 0], [0, 3, 0], [0, 0, 4]],
            triangles: [[0, 1, 2], [2, 1, 0], [0, 1, 2], [1, 0, 3]], edges: [[0, 0, 0, 2, 0, 0]])
        let surface = CADStrokeSurface.matching(mesh)[0]
        XCTAssertEqual(surface.first, SIMD3(0, 0, 1))
        XCTAssertEqual(surface.second, SIMD3(0, 1, 0))
    }

    func testCoincidentSegmentsNeverBorrowAnotherSolidsPlanes() {
        var mesh = makeMesh(vertices: [[0, 0, 0], [2, 0, 0], [0, 3, 0], [0, 0, 4]],
            triangles: [[0, 1, 2], [1, 0, 3]], edges: [[0, 0, 0, 2, 0, 0], [2, 0, 0, 0, 0, 0]], solids: 2)
        mesh.edgeSolids = [0, 1]
        mesh.triangleSolids = [0, 1]
        let surfaces = CADStrokeSurface.matching(mesh)
        XCTAssertEqual(surfaces[0].first, SIMD3(0, 0, 1))
        XCTAssertEqual(surfaces[1].first, SIMD3(0, 1, 0))
        XCTAssertTrue(surfaces.allSatisfy { $0.second == .zero })
    }

    func testOwnershipRequiresBothCompleteMappingsOrNeither() {
        let original = makeMesh(vertices: [[0, 0, 0], [2, 0, 0], [0, 3, 0]],
            triangles: [[0, 1, 2]], edges: [[0, 0, 0, 2, 0, 0]])
        XCTAssertEqual(CADStrokeSurface.matching(original)[0].first, SIMD3(0, 0, 1))
        for (edges, triangles) in [([0], nil), (nil, [0]), ([], [0]), ([0], []), ([-1], [0]), ([0], [-1]), ([1], [1])] as [([Int]?, [Int]?)] {
            var mesh = original
            mesh.edgeSolids = edges; mesh.triangleSolids = triangles
            XCTAssertEqual(CADStrokeSurface.matching(mesh)[0].first, .zero)
        }
    }

    func testQuantizedCoordinatesMatchSmallRoundingNoiseWithoutMatchingDifferentSegments() {
        let mesh = makeMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2]], edges: [
            [-0.49e-7, 0, 0, 1 + 0.49e-7, 0, 0], [0.51e-7, 0, 0, 1, 0, 0]
        ])
        let surfaces = CADStrokeSurface.matching(mesh)
        XCTAssertEqual(surfaces[0].first, SIMD3(0, 0, 1))
        XCTAssertEqual(surfaces[1].first, .zero)
    }

    /// Packed arrays have fixed strides, so rows of the wrong width cannot
    /// occur; malformed values and indices still fall back to zero planes.
    func testMalformedCoordinatesTrianglesAndDegenerateGeometryHaveZeroFallbacks() {
        let mesh = makeMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [.nan, 1, 0]],
            triangles: [[-1, 1, 2], [0, 1, 99], [0, 0, 0], [0, 1, 3], [0, 1, 2]], edges: [
                [0, 0, 0, 1, 0, 0], [.infinity, 0, 0, 1, 0, 0],
                [0, 0, 0, 0, 0, 0], [Double.greatestFiniteMagnitude, 0, 0, 1, 0, 0], [.nan, 0, 0, 1, 0, 0]
            ])
        let surfaces = CADStrokeSurface.matching(mesh)
        XCTAssertEqual(surfaces.count, mesh.edges.count)
        XCTAssertEqual(surfaces[0].first, SIMD3(0, 0, 1))
        XCTAssertTrue(surfaces.dropFirst().allSatisfy { $0.first == .zero && $0.second == .zero })
        let collinear = makeMesh(vertices: [[0, 0, 0], [1, 0, 0], [2, 0, 0]],
            triangles: [[0, 1, 2]], edges: [[0, 0, 0, 1, 0, 0]])
        XCTAssertEqual(CADStrokeSurface.matching(collinear)[0].first, .zero)
    }

    func testLargeMeshMatchesOnlyRequestedSegmentsWithLinearTraversal() {
        let columns = 123, rows = 500
        var vertices: [[Double]] = [], triangles: [[Int]] = [], edges: [[Double]] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1))
        triangles.reserveCapacity(123_000); edges.reserveCapacity(55_000)
        for y in 0...rows { for x in 0...columns { vertices.append([Double(x), Double(y), 0]) } }
        for y in 0..<rows {
            for x in 0..<columns {
                let a = y * (columns + 1) + x, b = a + 1, d = a + columns + 1, c = d + 1
                triangles.append([a, b, c]); triangles.append([a, c, d])
                if edges.count < 55_000 { edges.append(vertices[a] + vertices[c]) }
            }
        }
        let mesh = makeMesh(vertices: vertices, triangles: triangles, edges: edges)
        let started = Date()
        let surfaces = CADStrokeSurface.matching(mesh)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Matching must avoid a segment-by-triangle search")
        XCTAssertEqual(surfaces.count, 55_000)
        XCTAssertTrue(surfaces.allSatisfy { $0.first == SIMD3(0, 0, 1) && $0.second == .zero })
    }

    private func makeMesh(vertices: [[Double]], triangles: [[Int]], edges: [[Double]], solids: Int = 1) -> PreviewMesh {
        PreviewMesh(vertices: vertices, triangles: triangles, edges: edges, bounds: [0, 0, 0, 2, 3, 4],
            volume: 0, area: 0, solids: solids, faces: 0, buildSeconds: 0, threads: 1, stepPath: "")
    }
}
