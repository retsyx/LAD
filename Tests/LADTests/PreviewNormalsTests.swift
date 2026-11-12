import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class PreviewNormalsTests: XCTestCase {
    func testWorkerNormalPayloadDecodesAndValidates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-normals-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = curvedPreview()
        let decoded = try PreviewMesh.loadResult(at: original.writeWorkerResult(to: folder))
        XCTAssertEqual(decoded.vertexNormals, original.vertexNormals)
        XCTAssertEqual(decoded.positions, original.positions)
        XCTAssertEqual(decoded.triangleIndices, original.triangleIndices)
        XCTAssertTrue(decoded.hasValidNormals)
        XCTAssertNoThrow(try ProjectStore.validatePreview(decoded))

        let truncated = try PreviewMesh.loadResult(at: original.writeWorkerResult(to: folder, sections: ["normals": [0, 0, 1]]))
        XCTAssertThrowsError(try ProjectStore.validatePreview(truncated), "A partial normal buffer must not reach the GPU.")
    }

    func testRejectsMalformedAndNonUnitNormalBuffers() {
        let invalid: [[[Double]]] = [
            [], [[0, 0, 1]],
            Array(repeating: [0, 1], count: 6),
            Array(repeating: [0, 0, 0], count: 6),
            Array(repeating: [0, 0, 2], count: 6),
            Array(repeating: [0, .nan, 1], count: 6),
            Array(repeating: [0, .infinity, 1], count: 6),
            Array(repeating: [1e300, 0, 0], count: 6)
        ]
        for normals in invalid {
            var preview = curvedPreview()
            preview.normals = normals
            XCTAssertFalse(preview.hasValidNormals)
            XCTAssertThrowsError(try ProjectStore.validatePreview(preview))
        }
    }

    func testNormalsRemainDisposableAcrossProjectArchiveRoundtrip() throws {
        let preview = curvedPreview()
        let revision = ProjectRevision(model: .bracket, preview: preview)
        let project = LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id)
        let bytes = try ProjectStore.encode(project)
        let restored = try ProjectStore.decode(bytes)
        XCTAssertNil(restored.revisions[0].preview, "Exact lighting normals are derived session data, like the rest of the preview.")
        XCTAssertEqual(project.revisions[0].preview?.normals, preview.normals)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
        let revisions = try XCTUnwrap(manifest["revisions"] as? [[String: Any]])
        XCTAssertNil(revisions[0]["normals"])
        XCTAssertNil(revisions[0]["preview"])
    }

    @MainActor
    func testExactNormalsReachSolidsAndFaceHighlightsAcrossDisplayChanges() async throws {
        let view = try makeView()
        let preview = curvedPreview()
        let expected = try XCTUnwrap(preview.normals)
        let face = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        try await waitForPreparation(view)
        let solid = try node("solid:0", in: view)
        let highlight = try node("feature:face:0:0", in: view)
        let geometry = try XCTUnwrap(solid.geometry)
        let source = try XCTUnwrap(geometry.sources(for: .normal).first)
        try assertNormals(source, equal: expected)
        XCTAssertTrue(highlight.geometry?.sources(for: .normal).first === source,
                      "Face hover and selection must use the same surface normals as their owning solid.")

        for mode in ViewportDisplayMode.allCases {
            for projection in ViewportProjectionMode.allCases {
                view.update(mesh: preview, mode: mode, grid: false, command: nil,
                            selectedSolids: [0], hiddenSolids: [], projection: projection, selectedFeatures: [face])
                try await waitForPreparation(view)
                XCTAssertTrue(solid.geometry === geometry)
                XCTAssertTrue(solid.geometry?.sources(for: .normal).first === source)
                try assertNormals(try XCTUnwrap(highlight.geometry?.sources(for: .normal).first), equal: expected)
            }
        }
    }

    @MainActor
    func testRenderingBoundaryRejectsMalformedSuppliedNormals() throws {
        let view = try makeView()
        var preview = curvedPreview()
        preview.normals = [[0, 0, 1]]
        view.update(mesh: preview, mode: .shaded, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertFalse(view.hasRenderableGeometry, "Malformed supplied normals must not silently fall back to approximate shading.")
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = NSApplication.shared
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
    }

    @MainActor
    private func waitForPreparation(_ view: CADSceneView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingCaptureResources, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(view.isPreparingCaptureResources)
    }

    @MainActor
    private func node(_ name: String, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene?.rootNode.childNode(withName: name, recursively: true))
    }

    private func assertNormals(_ source: SCNGeometrySource, equal expected: [[Double]],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(source.usesFloatComponents, file: file, line: line)
        XCTAssertEqual(source.componentsPerVector, 3, file: file, line: line)
        XCTAssertEqual(source.vectorCount, expected.count, file: file, line: line)
        XCTAssertTrue([4, 8].contains(source.bytesPerComponent), file: file, line: line)
        guard [4, 8].contains(source.bytesPerComponent) else { return }
        source.data.withUnsafeBytes { bytes in
            for (index, normal) in expected.enumerated() {
                for axis in 0..<3 {
                    let offset = source.dataOffset + index * source.dataStride + axis * source.bytesPerComponent
                    let actual = source.bytesPerComponent == 4
                        ? Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
                        : bytes.loadUnaligned(fromByteOffset: offset, as: Double.self)
                    XCTAssertEqual(actual, normal[axis], accuracy: 1e-6, file: file, line: line)
                }
            }
        }
    }

    private func curvedPreview() -> PreviewMesh {
        let angles = [0.0, Double.pi / 4, Double.pi / 2]
        let normals = angles.map { [cos($0), sin($0), 0] }
        let vertices = [-1.0, 1.0].flatMap { z in angles.map { [cos($0), sin($0), z] } }
        let face = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)
        var preview = PreviewMesh(vertices: vertices, triangles: [[0, 1, 4], [0, 4, 3], [1, 2, 5], [1, 5, 4]],
                                  edges: [], bounds: [0, 0, -1, 1, 1, 1], volume: 1, area: .pi,
                                  solids: 1, faces: 1, buildSeconds: 0.01, threads: 1,
                                  stepPath: "/tmp/preview-exact-normals.step", triangleSolids: [0, 0, 0, 0], edgeSolids: [])
        preview.normals = normals + normals
        preview.triangleFaces = [0, 0, 0, 0]
        preview.topology = CADTopology(vertices: [], edges: [], faces: [
            CADFace(id: face, type: "CYLINDER", area: .pi, center: [0.5, 0.5, 0], axis: [0, 0, 1], radius: 1)
        ], parts: [CADPart(solidIndex: 0, area: .pi, volume: 1, bounds: preview.bounds, centroid: [0.5, 0.5, 0])])
        return preview
    }
}
