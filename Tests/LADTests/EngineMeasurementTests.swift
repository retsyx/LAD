import Foundation
import XCTest
@testable import LAD

final class EngineMeasurementTests: XCTestCase {
    @MainActor
    func testExactMeasurementAndSelectedSTEPUseTheSameSessionTopology() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to verify exact native measurement and selected STEP export.")
        }
        let service = EngineService()
        let spec = ModelSpec(title: "Measurement assembly", summary: "A sphere and a separated block.", units: "mm", script: """
        result = cq.Assembly(name='Assembly', metadata={'lad_id':'assembly'})
        result.add(cq.Solid.makeSphere(2, angleDegrees1=-90, angleDegrees2=90), name='Sphere', metadata={'lad_id':'sphere'})
        result.add(cq.Solid.makeBox(1,1,1).translate((10,0,0)), name='Block', metadata={'lad_id':'block'})
        """)
        let preview = try await service.buildPreview(spec, python: EngineService.defaultPython, threads: 4)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: preview.stepPath).deletingLastPathComponent()) }
        let topology = try XCTUnwrap(preview.topology)
        try CADMeasurements.validateTopology(preview)
        let face = try XCTUnwrap(topology.faces.first { $0.id.solidIndex == 0 && $0.type == "SPHERE" })
        let vertex = try XCTUnwrap(topology.vertices.first { $0.id.solidIndex == 1 && $0.position == [10, 0, 0] })
        let report = try await service.measure(preview, features: [face.id, vertex.id], solids: [], python: EngineService.defaultPython, threads: 4)
        XCTAssertEqual(try XCTUnwrap(report.metrics.first { $0.id == "pair:distance" }?.values.first), 8, accuracy: 1e-9)
        XCTAssertEqual(report.closestPoints?.count, 2)
        let mixed = try await service.measure(preview, features: [vertex.id], solids: [0], python: EngineService.defaultPython, threads: 4)
        XCTAssertEqual(mixed.features, [vertex.id])
        XCTAssertEqual(mixed.solidIndices, [0])
        XCTAssertEqual(try XCTUnwrap(mixed.metrics.first { $0.id == "pair:distance" }?.values.first), 8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(mixed.metrics.first { $0.id == "parts:count" }?.values.first), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.stepPath), "Measurement must not create STEP")
        let selected = try await service.exportSTEP(preview, solidIndices: [1], python: EngineService.defaultPython, threads: 4)
        let exported = try await service.previewSTEP(selected, parts: nil, python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: exported.stepPath).deletingLastPathComponent()) }
        XCTAssertEqual(exported.solids, 1)
        XCTAssertEqual(exported.volume, 1, accuracy: 1e-9)
        for (actual, expected) in zip(exported.bounds, [10.0, 0, 0, 11, 1, 1]) { XCTAssertEqual(actual, expected, accuracy: 1e-6) }
        XCTAssertNotNil(exported.brepPath, "Imported STEP must retain the native topology used by its metadata")
        let importedFace = try XCTUnwrap(exported.topology?.faces.first)
        let local = try await service.measure(exported, features: [importedFace.id], solids: [], python: "/nonexistent/python", threads: 1)
        XCTAssertEqual(try XCTUnwrap(local.metrics.first { $0.id.hasSuffix(":area") }?.values.first), 1, accuracy: 1e-9)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(preview.brepPath))
        let cached = try await service.exportSTEP(preview, solidIndices: [1], python: "/nonexistent/python", threads: 1)
        XCTAssertEqual(cached, selected)
    }

    @MainActor
    func testInvalidSelectedExportFailsBeforeAnyNativeProcess() async throws {
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1], volume: 1,
                                  area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1, stepPath: "/unregistered/model.step")
        let selections: [Set<Int>] = [[], [-1], [1]]
        for selection in selections {
            do {
                _ = try await EngineService().exportSTEP(preview, solidIndices: selection, python: "/nonexistent/python", threads: 1)
                XCTFail("Invalid selections must be rejected before resolving a runtime or reading an artifact")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Select at least one available part to export.")
            }
        }
    }
}
