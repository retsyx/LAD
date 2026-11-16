import XCTest
@testable import LAD

/// A design and its 3D printing version index the same parts' features
/// independently. Correspondence follows exact geometry, never indices.
final class CADFeatureCorrespondenceTests: XCTestCase {
    private let plate = CADPart(solidIndex: 0, area: 1_800, volume: 4_700, bounds: [-20, -10, -3, 20, 10, 3], centroid: [0, 0, 0])

    func testUnchangedFeaturesFollowTheirGeometryAndChangedOnesTheirReplacement() {
        // A counterbore floor that a sacrificial bridge closes, over a shorter bore.
        let design = CADTopology(
            vertices: [vertex(0, [3, 0, 0]), vertex(1, [1.6, 0, 0]), vertex(2, [1.6, 0, -3])],
            edges: [circle(0, z: 0, radius: 3), circle(1, z: 0, radius: 1.6), circle(2, z: -3, radius: 1.6),
                    line(3, from: [-20, -10, 3], to: [20, -10, 3])],
            faces: [plane(0, z: 3, area: 771.73, normal: 1), plane(1, z: 0, area: 20.23, normal: 1),
                    cylinder(2, z: -1.5, area: 30.16), plane(3, z: -3, area: 791.96, normal: -1)],
            parts: [plate])
        let printing = CADTopology(
            vertices: [vertex(0, [1.6, 0, -3]), vertex(1, [3, 0, 0]), vertex(2, [1.6, 0, -0.2])],
            edges: [line(0, from: [20, -10, 3], to: [-20, -10, 3]), circle(1, z: 0, radius: 3),
                    circle(2, z: -0.2, radius: 1.6), circle(3, z: -3, radius: 1.6)],
            faces: [plane(0, z: -3, area: 791.96, normal: -1), plane(1, z: 3, area: 771.73, normal: 1),
                    plane(2, z: 0, area: 28.27, normal: 1), cylinder(3, z: -1.6, area: 28.15),
                    plane(4, z: -0.2, area: 8.04, normal: -1)],
            parts: [plate])

        let selected = [id(.face, 1), id(.face, 0), id(.face, 2), id(.face, 3), id(.edge, 3), id(.edge, 0),
                        id(.edge, 1), id(.vertex, 0), id(.vertex, 1)]
        let mapped = CADFeatureCorrespondence.features(selected, from: design, to: printing)
        XCTAssertEqual(mapped, [id(.face, 2), id(.face, 1), id(.face, 3), id(.face, 0), id(.edge, 0), id(.edge, 1),
                                id(.edge, 2), id(.vertex, 1), id(.vertex, 2)],
                       "Selection order is kept; the closed floor, shorter bore and moved bore circle replace their originals")
        XCTAssertEqual(CADFeatureCorrespondence.features(mapped, from: printing, to: design), selected)
        XCTAssertEqual(CADFeatureCorrespondence.features([id(.face, 4)], from: printing, to: design), [],
                       "The bridge underside has no counterpart in the design")
        XCTAssertEqual(CADFeatureCorrespondence.features([id(.face, 1), id(.face, 7), id(.face, 1)], from: design, to: printing),
                       [id(.face, 2)])
    }

    func testChangedFeaturesWithoutOneUniqueNearbyReplacementHaveNoCounterpart() {
        let design = CADTopology(vertices: [], edges: [],
            faces: [plane(0, z: 0, area: 4, normal: 1), plane(1, z: 0, area: 4, normal: 1, x: 0.5),
                    plane(2, z: 1, area: 4, normal: 1, x: 8), plane(3, z: 2, area: 4, normal: 1, x: -8)],
            parts: [plate])
        let printing = CADTopology(vertices: [], edges: [],
            faces: [plane(0, z: 0, area: 4.1, normal: 1, x: 0.6),
                    plane(1, z: 1, area: 2, normal: 1, x: 7), plane(2, z: 1, area: 2, normal: 1, x: 9),
                    plane(3, z: 2, area: 4, normal: -1, x: -8), plane(4, z: 2, area: 4, normal: 1, x: 12)],
            parts: [plate])

        XCTAssertEqual(CADFeatureCorrespondence.features([id(.face, 1)], from: design, to: printing), [id(.face, 0)])
        XCTAssertEqual(CADFeatureCorrespondence.features([id(.face, 0)], from: design, to: printing), [],
                       "Another changed face is nearer to the only replacement")
        XCTAssertEqual(CADFeatureCorrespondence.features([id(.face, 2)], from: design, to: printing), [],
                       "A face split into two equal halves is ambiguous")
        XCTAssertEqual(CADFeatureCorrespondence.features([id(.face, 3)], from: design, to: printing), [],
                       "A face facing the other way is not the same face, and a distant face is not nearby")
    }

    private func id(_ kind: CADFeatureKind, _ index: Int) -> CADFeatureID {
        CADFeatureID(kind: kind, solidIndex: 0, localIndex: index)
    }

    private func vertex(_ index: Int, _ position: [Double]) -> CADVertex {
        CADVertex(id: id(.vertex, index), position: position)
    }

    private func circle(_ index: Int, z: Double, radius: Double) -> CADEdge {
        CADEdge(id: id(.edge, index), type: "CIRCLE", length: 2 * .pi * radius, polyline: [], radius: radius,
                diameter: 2 * radius, center: [0, 0, z], axis: [0, 0, 1], startPoint: [radius, 0, z], endPoint: [radius, 0, z],
                sweepDegrees: 360, closed: true)
    }

    private func line(_ index: Int, from start: [Double], to end: [Double]) -> CADEdge {
        CADEdge(id: id(.edge, index), type: "LINE", length: 40, polyline: [start, end], direction: [1, 0, 0],
                startPoint: start, endPoint: end, closed: false)
    }

    private func plane(_ index: Int, z: Double, area: Double, normal: Double, x: Double = 0) -> CADFace {
        CADFace(id: id(.face, index), type: "PLANE", area: area, center: [x, 0, z], normal: [0, 0, normal])
    }

    private func cylinder(_ index: Int, z: Double, area: Double) -> CADFace {
        CADFace(id: id(.face, index), type: "CYLINDER", area: area, center: [0, 0, z], axis: [0, 0, -1], radius: 1.6, diameter: 3.2)
    }
}
