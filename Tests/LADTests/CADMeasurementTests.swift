import Foundation
import XCTest
@testable import LAD

final class CADMeasurementTests: XCTestCase {
    @MainActor
    func testVertexPairIsExactAndImmediateWithoutNativeArtifactOrRuntime() async throws {
        let mesh = preview()
        let report = try await EngineService().measure(mesh, features: [id(.vertex, 0), id(.vertex, 2)], solids: [],
                                                       python: "/nonexistent/python", threads: 1)
        XCTAssertEqual(try values(report, "pair:distance"), [5])
        XCTAssertEqual(try values(report, "pair:delta"), [3, 4, 0])
        XCTAssertEqual(report.closestPoints, [[0, 0, 0], [3, 4, 0]])
        XCTAssertEqual(report.metrics.first?.label, "Vertex 1 · Coordinates X, Y, Z")
    }

    func testThreeOrderedVerticesReportTheMiddleAngleAndTriangleGeometry() throws {
        let report = try CADMeasurements.report(preview(), features: [id(.vertex, 0), id(.vertex, 1), id(.vertex, 2)], solids: [])
        XCTAssertEqual(try values(report, "triangle:angle").first!, 90, accuracy: 1e-9)
        XCTAssertEqual(try values(report, "triangle:area"), [6])
        XCTAssertEqual(try values(report, "triangle:perimeter"), [12])
        XCTAssertEqual(try values(report, "triangle:sides"), [3, 4, 5])
        let collinear = [CADVertex(id: id(.vertex, 0), position: [0, 0, 0]),
                         CADVertex(id: id(.vertex, 1), position: [1, 0, 0]),
                         CADVertex(id: id(.vertex, 2), position: [2, 0, 0])]
        var mesh = preview()
        mesh.topology?.vertices = collinear
        let flat = try CADMeasurements.report(mesh, features: collinear.map(\.id), solids: [])
        XCTAssertEqual(try values(flat, "triangle:area"), [0])
        XCTAssertEqual(try values(flat, "triangle:angle").first!, 180, accuracy: 1e-9)
    }

    func testAnalyticEdgesAndFacesExposePropertiesAndAccurateTotals() throws {
        let circle = try CADMeasurements.report(preview(), features: [id(.edge, 0)], solids: [])
        XCTAssertEqual(try values(circle, "edge:0:0:radius"), [2])
        XCTAssertEqual(try values(circle, "edge:0:0:diameter"), [4])
        XCTAssertEqual(try values(circle, "edge:0:0:sweep"), [360])
        let edges = try CADMeasurements.report(preview(), features: [id(.edge, 1), id(.edge, 2)], solids: [])
        XCTAssertEqual(try values(edges, "edges:totalLength"), [7])
        let faces = try CADMeasurements.report(preview(), features: [id(.face, 0), id(.face, 1)], solids: [])
        XCTAssertEqual(try values(faces, "faces:totalArea").first!, 12 + 8 * .pi, accuracy: 1e-9)
        XCTAssertEqual(try values(faces, "faces:totalPerimeter"), [34])
        XCTAssertEqual(try values(faces, "face:0:1:diameter"), [4])
        XCTAssertFalse(faces.metrics.contains { $0.id == "face:0:1:normal" }, "A curved face must not claim a constant plane normal")
    }

    func testSelectedPartTotalsUseOriginalCoordinatesAndVolumeWeightedCentroid() throws {
        var mesh = preview()
        mesh.solids = 2
        mesh.topology?.parts.append(CADPart(solidIndex: 1, area: 6, volume: 1, bounds: [10, 0, 0, 11, 1, 1], centroid: [10.5, 0.5, 0.5]))
        let report = try CADMeasurements.report(mesh, features: [], solids: [0, 1])
        XCTAssertEqual(try values(report, "parts:count"), [2])
        XCTAssertEqual(try values(report, "parts:volume"), [61])
        XCTAssertEqual(try values(report, "parts:area"), [100])
        XCTAssertEqual(try values(report, "parts:size"), [11, 4, 5])
        let centroid = try values(report, "parts:centroid")
        XCTAssertEqual(centroid[0], (1.5 * 60 + 10.5) / 61, accuracy: 1e-9)
        XCTAssertEqual(centroid[1], (2 * 60 + 0.5) / 61, accuracy: 1e-9)
        XCTAssertEqual(centroid[2], (2.5 * 60 + 0.5) / 61, accuracy: 1e-9)
    }

    func testInvalidTopologyReferencesAndZeroVolumeNeverProduceMeasurements() throws {
        XCTAssertThrowsError(try CADMeasurements.report(preview(), features: [id(.face, 99)], solids: []))
        XCTAssertThrowsError(try CADMeasurements.report(preview(), features: [], solids: [1]))
        XCTAssertThrowsError(try CADMeasurements.report(preview(), features: [], solids: []))
        var mesh = preview()
        mesh.topology?.parts[0].volume = 0
        XCTAssertThrowsError(try CADMeasurements.report(mesh, features: [], solids: [0]))
    }

    func testTopologyValidationChecksRenderMappingsAndNativeOwnership() throws {
        let original = preview()
        try CADMeasurements.validateTopology(original)
        var invalid = original
        invalid.triangleFaces = [100]
        XCTAssertThrowsError(try CADMeasurements.validateTopology(invalid))
        invalid = original
        invalid.edgeFeatures = []
        XCTAssertThrowsError(try CADMeasurements.validateTopology(invalid))
        invalid = original
        invalid.topology?.edges[0].id.localIndex = 9
        XCTAssertThrowsError(try CADMeasurements.validateTopology(invalid))
        invalid = original
        invalid.topology?.vertices[0].position = [.nan, 0, 0]
        XCTAssertThrowsError(try CADMeasurements.validateTopology(invalid))
    }

    func testTopologyAndMeasurementsAreNeverEmbeddedInProjectArchives() throws {
        let revision = ProjectRevision(model: .bracket, preview: preview())
        let project = LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id, projectID: UUID())
        let compressed = try ProjectStore.encode(project)
        let manifest = String(decoding: try ProjectZIP.decode(compressed), as: UTF8.self)
        for forbidden in ["topology", "triangleFaces", "edgeFeatures", "polyline", "brepPath", "closestPoints"] {
            XCTAssertFalse(manifest.contains("\"\(forbidden)\""), forbidden)
        }
        XCTAssertNil(try ProjectStore.decode(compressed).revisions[0].preview)
    }

    func testMeshedCurvesCanExceedOldPerEdgeSamplingLimitWithinTotalBudget() throws {
        var mesh = preview()
        mesh.topology?.edges[0].polyline = (0...512).map { index in
            let angle = Double(index) * 2 * .pi / 512
            return [2 * cos(angle), 2 * sin(angle), 0]
        }
        XCTAssertNoThrow(try CADMeasurements.validateTopology(mesh))

        // The same global bound applies to all edge polygons together.
        mesh.topology?.edges[0].polyline = Array(repeating: [1, 0, 0], count: 125_001)
        mesh.topology?.edges[1].polyline = Array(repeating: [1, 0, 0], count: 125_001)
        mesh.topology?.edges[2].polyline = []
        XCTAssertNoThrow(try CADMeasurements.validateTopology(mesh))
        mesh.topology?.edges[2].polyline = [[0, 0, 0], [0, 1, 0]]
        XCTAssertThrowsError(try CADMeasurements.validateTopology(mesh))
    }

    func testMeasurementFormattingKeepsAreaVolumeAnglesAndVectorsDistinct() {
        XCTAssertEqual(CADMeasurementMetric(id: "area", label: "Area", values: [12.5], unit: .area).formattedValue, "12.5 mm²")
        XCTAssertEqual(CADMeasurementMetric(id: "volume", label: "Volume", values: [6], unit: .volume).formattedValue, "6 mm³")
        XCTAssertEqual(CADMeasurementMetric(id: "angle", label: "Angle", values: [90], unit: .angle).formattedValue, "90°")
        XCTAssertEqual(CADMeasurementMetric(id: "vector", label: "Point", values: [-0.00000001, 3, 4], unit: .length).formattedValue, "0, 3, 4 mm")
    }

    private func id(_ kind: CADFeatureKind, _ index: Int) -> CADFeatureID { CADFeatureID(kind: kind, solidIndex: 0, localIndex: index) }

    private func values(_ report: CADMeasurementReport, _ key: String) throws -> [Double] {
        try XCTUnwrap(report.metrics.first { $0.id == key }, key).values
    }

    private func preview() -> PreviewMesh {
        let topology = CADTopology(
            vertices: [CADVertex(id: id(.vertex, 0), position: [0, 0, 0]),
                       CADVertex(id: id(.vertex, 1), position: [3, 0, 0]),
                       CADVertex(id: id(.vertex, 2), position: [3, 4, 0])],
            edges: [CADEdge(id: id(.edge, 0), type: "CIRCLE", length: 4 * .pi, polyline: [[2, 0, 0], [-2, 0, 0]],
                            radius: 2, diameter: 4, center: [0, 0, 0], axis: [0, 0, 1], sweepDegrees: 360, closed: true),
                    CADEdge(id: id(.edge, 1), type: "LINE", length: 3, polyline: [[0, 0, 0], [3, 0, 0]], direction: [1, 0, 0], startPoint: [0, 0, 0], endPoint: [3, 0, 0]),
                    CADEdge(id: id(.edge, 2), type: "LINE", length: 4, polyline: [[3, 0, 0], [3, 4, 0]], direction: [0, 1, 0])],
            faces: [CADFace(id: id(.face, 0), type: "PLANE", area: 12, center: [1.5, 2, 0], normal: [0, 0, 1], perimeter: 14),
                    CADFace(id: id(.face, 1), type: "CYLINDER", area: 8 * .pi, center: [3, 3, 2], axis: [0, 0, 1], radius: 2, perimeter: 20, diameter: 4)],
            parts: [CADPart(solidIndex: 0, area: 94, volume: 60, bounds: [0, 0, 0, 3, 4, 5], centroid: [1.5, 2, 2.5])])
        return PreviewMesh(vertices: [[0, 0, 0], [3, 0, 0], [3, 4, 0]], triangles: [[0, 1, 2]], edges: [[0, 0, 0, 3, 0, 0]],
                           bounds: [-2, -2, 0, 5, 5, 5], volume: 60, area: 94, solids: 1, faces: 2,
                           buildSeconds: 0, threads: 1, stepPath: "/session/model.step", triangleSolids: [0], edgeSolids: [0],
                           topology: topology, triangleFaces: [0], edgeFeatures: [1])
    }
}
