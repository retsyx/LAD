import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportSectionPickingTests: XCTestCase {
    private let top = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 1)
    private let frontEdge = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)
    private let frontCorner = CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: 0)

    @MainActor
    func testSectionPicksRetainedNativeFeaturesAndClipsAnEdgeAtThePlane() async throws {
        let view = try makeView()
        let mesh = preview()
        view.update(mesh: mesh, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        try await ready(view)

        let keptFace = point(at: SCNVector3(-4, 0, 4), in: view)
        let removedFace = point(at: SCNVector3(4, 0, 4), in: view)
        let keptEdge = point(at: SCNVector3(-3, -5, 4), in: view)
        let removedEdge = point(at: SCNVector3(3, -5, 4), in: view)
        let removedCorner = point(at: SCNVector3(8, -5, 4), in: view)
        XCTAssertEqual(view.feature(at: keptFace), top)
        XCTAssertEqual(view.feature(at: removedFace), top)
        XCTAssertEqual(view.feature(at: keptEdge), frontEdge)
        XCTAssertEqual(view.feature(at: removedEdge), frontEdge)
        XCTAssertEqual(view.feature(at: removedCorner), frontCorner)

        view.update(mesh: mesh, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric, sectionEnabled: true)
        try await ready(view)
        XCTAssertEqual(view.feature(at: keptFace), top)
        XCTAssertEqual(view.feature(at: keptEdge), frontEdge,
                       "An edge crossing the plane retains its native identity on the visible segment.")
        XCTAssertNil(view.feature(at: removedFace))
        XCTAssertNil(view.feature(at: removedEdge))
        XCTAssertNil(view.feature(at: removedCorner))
    }

    @MainActor
    func testSectionCapOccludesInteriorFacesWithoutBecomingASelectableFeature() async throws {
        let view = try makeView()
        let mesh = preview(withInterior: true)
        view.update(mesh: mesh, mode: .edges, grid: false, command: ViewportCommand(.right),
                    selectedSolids: [], hiddenSolids: [], projection: .isometric, sectionEnabled: true)
        try await ready(view)

        let cap = point(at: SCNVector3Zero, in: view)
        XCTAssertFalse(view.hitTest(cap, options: [.categoryBitMask: CADViewportCategory.sectionCaps]).isEmpty)
        XCTAssertNil(view.feature(at: cap), "The visible synthetic cap must not pick a native face behind it.")

        view.update(mesh: mesh, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [0], projection: .isometric, sectionEnabled: true)
        try await ready(view)
        XCTAssertEqual(view.feature(at: cap), CADFeatureID(kind: .face, solidIndex: 1, localIndex: 3),
                       "Hiding the outer solid removes its cap and reveals the actual inner face.")
    }

    @MainActor
    func testSectionIsLocalToEachViewAndKeepsItsPlaneWhileTheCameraTurns() async throws {
        let first = try makeView()
        let second = try makeView()
        let mesh = preview()

        first.update(mesh: mesh, mode: .edges, grid: false, command: ViewportCommand(.right),
                     selectedSolids: [], hiddenSolids: [], sectionEnabled: true)
        second.update(mesh: mesh, mode: .edges, grid: false, command: ViewportCommand(.left),
                      selectedSolids: [], hiddenSolids: [])
        let plane = try XCTUnwrap(first.sectionPlane)
        XCTAssertNil(second.sectionPlane)

        first.update(mesh: mesh, mode: .edges, grid: false, command: ViewportCommand(.left),
                     selectedSolids: [], hiddenSolids: [], sectionEnabled: true)
        XCTAssertEqual(first.sectionPlane, plane)
        second.update(mesh: mesh, mode: .edges, grid: false, command: nil,
                      selectedSolids: [], hiddenSolids: [], sectionEnabled: true)
        let secondPlane = try XCTUnwrap(second.sectionPlane)
        XCTAssertEqual(secondPlane.normal.x, -plane.normal.x)

        first.update(mesh: mesh, mode: .edges, grid: false, command: nil,
                     selectedSolids: [], hiddenSolids: [])
        XCTAssertNil(first.sectionPlane)
        XCTAssertEqual(second.sectionPlane, secondPlane)
        first.update(mesh: mesh, mode: .edges, grid: false, command: nil,
                     selectedSolids: [], hiddenSolids: [], sectionEnabled: true)
        XCTAssertEqual(first.sectionPlane, plane, "Turning the cut off and on preserves its setting in this view.")
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.preparesRendererResources = false
        return view
    }

    @MainActor
    private func ready(_ view: CADSceneView) async throws {
        let ready = try await view.waitForCaptureResources(until: .now + .seconds(10))
        XCTAssertTrue(ready)
        SCNTransaction.flush()
    }

    @MainActor
    private func point(at world: SCNVector3, in view: CADSceneView) -> NSPoint {
        let projected = view.projectPoint(world)
        return NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
    }

    private func preview(withInterior: Bool = false) -> PreviewMesh {
        let outer: [Double] = [-8, -5, -4, 8, 5, 4]
        let boxes: [[Double]] = withInterior ? [outer, [-6, -2, -2, -2, 2, 2]] : [outer]
        let corners = [[0, 1, 2], [3, 1, 2], [3, 4, 2], [0, 4, 2],
                       [0, 1, 5], [3, 1, 5], [3, 4, 5], [0, 4, 5]]
        let indices = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                       [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        let axes = [2, 2, 1, 0, 1, 0]
        let signs = [-1.0, 1, -1, 1, 1, -1]
        var vertices = [[Double]](), triangles = [[Int]](), owners = [Int]()
        var faces = [CADFace](), parts = [CADPart]()
        for (solid, bounds) in boxes.enumerated() {
            let first = vertices.count
            vertices += corners.map { $0.map { bounds[$0] } }
            triangles += indices.map { $0.map { first + $0 } }
            owners += Array(repeating: solid, count: indices.count)
            let center = (0..<3).map { (bounds[$0] + bounds[$0 + 3]) / 2 }
            let dimensions = (0..<3).map { bounds[$0 + 3] - bounds[$0] }
            var area = 0.0
            for (index, axis) in axes.enumerated() {
                var normal = [0.0, 0, 0], faceCenter = center
                normal[axis] = signs[index]
                faceCenter[axis] = signs[index] < 0 ? bounds[axis] : bounds[axis + 3]
                let faceArea = dimensions[(axis + 1) % 3] * dimensions[(axis + 2) % 3]
                area += faceArea
                let id = CADFeatureID(kind: .face, solidIndex: solid, localIndex: index)
                faces.append(CADFace(id: id, type: "PLANE", area: faceArea, center: faceCenter, normal: normal))
            }
            parts.append(CADPart(solidIndex: solid, area: area, volume: dimensions.reduce(1, *),
                                 bounds: bounds, centroid: center))
        }
        let edge = [[-8.0, -5, 4], [8, -5, 4]]
        var mesh = PreviewMesh(vertices: vertices, triangles: triangles, edges: [edge.flatMap { $0 }], bounds: outer,
                               volume: parts.map(\.volume).reduce(0, +), area: parts.map(\.area).reduce(0, +),
                               solids: boxes.count, faces: faces.count, buildSeconds: 0, threads: 1,
                               stepPath: "/tmp/viewport-section-picking", triangleSolids: owners, edgeSolids: [0])
        mesh.topology = CADTopology(vertices: [CADVertex(id: frontCorner, position: edge[1])],
                                    edges: [CADEdge(id: frontEdge, type: "LINE", length: 16, polyline: edge)],
                                    faces: faces, parts: parts)
        mesh.triangleFaces = triangles.indices.map { $0 / 2 }
        mesh.edgeFeatures = [0]
        return mesh
    }
}
