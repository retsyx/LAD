import Foundation
import XCTest
@testable import LAD

/// Opt-in tests need the local CAD runtime and permission to start macOS's
/// sandbox, so ordinary swift test remains independent of native dependencies.
final class EngineServiceTests: XCTestCase {
    @MainActor
    func testPreviewDefersSTEPThenExportsAndReusesExactSessionBytes() async throws {
        try requireRuntime()
        let spec = ModelSpec(title: "Deferred STEP assembly", summary: "Located exact solids, STEP created only for export.", units: "mm", script: """
        result = cq.Assembly(name='Case', metadata={'lad_id':'case'})
        result.add(cq.Solid.makeBox(7,8,2), name='Base', metadata={'lad_id':'base'})
        result.add(cq.Solid.makeCylinder(2,3), name='Post', loc=cq.Location((20,5,2)), metadata={'lad_id':'post'})
        """)
        let service = EngineService()
        let preview = try await service.buildPreview(spec, python: EngineService.defaultPython, threads: 4)
        XCTAssertEqual(preview.normals?.count, preview.vertices.count,
                       "The native worker must deliver exact surface normals with its preview.")
        let brep = URL(fileURLWithPath: try XCTUnwrap(preview.brepPath))
        defer { try? FileManager.default.removeItem(at: brep.deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.stepPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: brep.path))
        XCTAssertNotNil(preview.runtime)
        XCTAssertEqual(preview.parts?.first?.id, "case")
        let data = try await service.exportSTEP(preview, python: EngineService.defaultPython, threads: 4)
        XCTAssertTrue(String(decoding: data.prefix(128), as: UTF8.self).hasPrefix("ISO-10303-21;"))
        // A repeated export needs neither the native artifact nor a runtime.
        try FileManager.default.removeItem(at: brep)
        let cached = try await service.exportSTEP(preview, python: "/nonexistent/python", threads: 1)
        XCTAssertEqual(cached, data)
        let imported = try await EngineService().previewSTEP(data, parts: preview.parts,
                                                            python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: imported.stepPath).deletingLastPathComponent()) }
        XCTAssertEqual(imported.solids, preview.solids)
        XCTAssertEqual(imported.volume, preview.volume, accuracy: 0.00001)
        XCTAssertEqual(imported.parts, preview.parts)
        for (actual, expected) in zip(imported.bounds, preview.bounds) {
            XCTAssertEqual(actual, expected, accuracy: 0.00001)
        }
    }

    @MainActor
    func testExportRejectsUnregisteredNativeArtifactBeforeLaunchingPython() async throws {
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1], volume: 1,
                                  area: 1, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: "/unrelated/model.step", brepPath: "/unrelated/model.brep")
        do {
            _ = try await EngineService().exportSTEP(preview, python: "/nonexistent/python", threads: 1)
            XCTFail("An unregistered artifact must never be read or sent to Python")
        } catch EngineExportError.nativeArtifactUnavailable {
            // AppState can rebuild an evicted model instead of losing export.
        }
    }

    @MainActor
    func testActualNativePCBSTEPPreview() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_TEST_NATIVE_STEP"] else { throw XCTSkip("Set LAD_TEST_NATIVE_STEP to a native KiCad STEP export for the complete import check.") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let spec = ModelSpec(title: "Native PCB", summary: "Exact native KiCad assembly.", units: "mm", script: "result = imported_model", sourceSTEP: data, sourceName: "pcb.step")
        let mesh = try await EngineService().build(spec, python: EngineService.defaultPython, threads: 2)
        XCTAssertGreaterThan(mesh.solids, 1)
        XCTAssertGreaterThan(mesh.faces, 10)
        XCTAssertGreaterThan(mesh.volume, 0)
        XCTAssertEqual(mesh.triangleSolids?.count, mesh.triangles.count)
    }

    @MainActor
    func testNativeSTEPSourceSupportsLaterScriptRefinement() async throws {
        try requireRuntime()
        let original = try await EngineService().build(.bracket, python: EngineService.defaultPython, threads: 2)
        let data = try Data(contentsOf: URL(fileURLWithPath: original.stepPath))
        let spec = ModelSpec(title: "Refined native model", summary: "Original exact geometry translated by 100 mm.", units: "mm", script: "result = imported_model.translate((100, 0, 0))", sourceSTEP: data, sourceName: "source.step")
        let moved = try await EngineService().build(spec, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(moved.volume, original.volume, accuracy: 0.001)
        XCTAssertEqual(moved.bounds[0], original.bounds[0] + 100, accuracy: 0.0001)
        XCTAssertEqual(moved.solids, original.solids)
    }

    @MainActor
    func testSavedSTEPRegeneratesPreviewWithStablePartOwnershipAndExactBytes() async throws {
        try requireRuntime()
        let program = """
        shared = cq.Solid.makeBox(3, 4, 5)
        enclosure = cq.Assembly(name='Case', loc=cq.Location((10, 0, 0)), metadata={'lad_id':'case'})
        enclosure.add(shared, name='Base', metadata={'lad_id':'base'})
        enclosure.add(shared, name='Lid', loc=cq.Location((0, 0, 20)), metadata={'lad_id':'lid'})
        pcb = cq.Compound.makeCompound([cq.Solid.makeBox(7, 8, 1), cq.Solid.makeCylinder(2, 3).translate((2, 3, 1))])
        result = cq.Assembly(name='Product', loc=cq.Location((100, -40, 15), (0, 0, 1), 90))
        result.add(enclosure)
        result.add(pcb, name='PCB', loc=cq.Location((40, 0, 0)), metadata={'lad_id':'pcb'})
        """
        let spec = ModelSpec(title: "Saved assembly", summary: "Named parts with nested locations and multiple PCB solids.", units: "mm", script: program)
        let service = EngineService()
        let original = try await service.build(spec, python: EngineService.defaultPython, threads: 2)
        let step = try Data(contentsOf: URL(fileURLWithPath: original.stepPath))
        // No ModelSpec, Python program, source asset, or original build folder
        // is supplied to the regeneration path.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: original.stepPath).deletingLastPathComponent())
        let regenerated = try await service.previewSTEP(step, parts: original.parts, python: EngineService.defaultPython, threads: 4)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: regenerated.stepPath).deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: regenerated.stepPath)), step)
        XCTAssertEqual(regenerated.parts, original.parts)
        XCTAssertEqual(regenerated.solids, 4)
        XCTAssertEqual(regenerated.threads, 4)
        XCTAssertEqual(regenerated.volume, original.volume, accuracy: 0.0001)
        func bounds(_ mesh: PreviewMesh, owner: Int) -> [Double] {
            let vertices = zip(mesh.triangles, mesh.triangleSolids ?? []).filter { $0.1 == owner }
                .flatMap { triangle, _ in triangle.map { mesh.vertices[$0] } }
            return (0..<3).map { axis in vertices.map { $0[axis] }.min()! } +
                (0..<3).map { axis in vertices.map { $0[axis] }.max()! }
        }
        for owner in 0..<original.solids {
            for (actual, expected) in zip(bounds(regenerated, owner: owner), bounds(original, owner: owner)) {
                XCTAssertEqual(actual, expected, accuracy: 0.0001)
            }
        }
    }

    @MainActor
    func testPreviewRejectsInvalidSTEPBeforeLaunchingPython() async throws {
        do {
            _ = try await EngineService().previewSTEP(Data("invalid STEP".utf8), parts: nil, python: "/nonexistent/python", threads: 2)
            XCTFail("Invalid STEP data should be rejected before launching the CAD process")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("STEP design is invalid"))
        }
    }

    private func requireRuntime() throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to verify the installed native CAD runtime and macOS sandbox.")
        }
    }

    @MainActor
    func testSandboxedCadQueryAndDirectOpenCascadeAssembly() async throws {
        try requireRuntime()
        let program = """
        from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
        from OCP.gp import gp_Pnt
        body = (cq.Workplane('XY').ellipse(20, 12)
                .workplane(offset=8).ellipse(16, 10).loft()
                .faces('>Z').shell(-1.5))
        kernel_box = cq.Shape.cast(BRepPrimAPI_MakeBox(gp_Pnt(35, 0, 0), 5, 5, 5).Shape())
        result = cq.Assembly().add(body, name='lofted_shell').add(kernel_box, name='kernel_box')
        """
        let spec = ModelSpec(title: "Loft and OCP assembly", summary: "Two positioned solids built through CadQuery and the direct kernel API.", units: "mm", script: program)
        let mesh = try await EngineService().build(spec, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(mesh.solids, 2)
        XCTAssertGreaterThan(mesh.volume, 125)
        XCTAssertEqual(Set(mesh.triangleSolids ?? []), Set([0, 1]))
        let step = try String(contentsOfFile: mesh.stepPath, encoding: .utf8)
        XCTAssertTrue(step.hasPrefix("ISO-10303-21;"))
    }

    @MainActor
    func testScriptSandboxBlocksUnrelatedFilesAndProcessExecution() async throws {
        try requireRuntime()
        let canary = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-private-canary-\(UUID().uuidString).txt")
        try Data("private canary".utf8).write(to: canary)
        defer { try? FileManager.default.removeItem(at: canary) }
        // JSON quoting is also valid for this generated Python string literal.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let literal = String(decoding: try encoder.encode(canary.path), as: UTF8.self)
        let program = """
        import os, socket, subprocess
        try:
            open(\(literal)).read()
        except PermissionError:
            pass
        else:
            raise RuntimeError('unrelated file was readable')
        try:
            subprocess.run(['/bin/echo', 'should not run'], check=True)
        except (PermissionError, OSError):
            pass
        else:
            raise RuntimeError('external process was executable')
        sock = None
        try:
            sock = socket.socket()
            sock.connect(('127.0.0.1', 9))
        except PermissionError:
            pass
        except OSError as error:
            if error.errno not in (1, 13):
                raise RuntimeError('network was not sandbox denied: ' + str(error))
        else:
            raise RuntimeError('network was allowed')
        finally:
            if sock is not None:
                sock.close()
        assert not any(key in os.environ for key in ['OPENAI_API_KEY', 'CODEX_API_KEY', 'AWS_SECRET_ACCESS_KEY'])
        result = cq.Workplane('XY').box(10, 10, 10)
        """
        let spec = ModelSpec(title: "Isolated CAD program", summary: "Sandbox verification box.", units: "mm", script: program)
        let mesh = try await EngineService().build(spec, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(mesh.solids, 1)
        XCTAssertEqual(mesh.volume, 1_000, accuracy: 0.001)
    }
}
