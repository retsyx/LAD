import Foundation
import XCTest
@testable import LAD

/// Opt-in tests need the local CAD runtime and permission to start macOS's
/// sandbox, so ordinary swift test remains independent of native dependencies.
final class EngineServiceTests: XCTestCase {
    @MainActor
    func testCandidateValidationSurvivesFinalMetadataAndProjectRoundtrip() async throws {
        try requireRuntime()
        let candidate = ModelSpec(title: "Candidate", summary: "Build-time description", units: "mm",
                                  script: "result = cq.Solid.makeBox(2,3,4)")
        let engine = EngineService()
        let built = try await engine.buildPreview(candidate, python: EngineService.defaultPython, threads: 2)
        let hash = try XCTUnwrap(built.validatedHash)
        var final = candidate
        final.title = "Final design title"
        final.summary = "A different final description after reviewing the validated candidate."
        let revision = ProjectRevision(model: final, validatedHash: hash)
        let project = LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id)
        let saved = try ProjectStore.decode(ProjectStore.encode(project)).revisions[0]
        let replay = try await engine.buildPreview(saved.model, python: EngineService.defaultPython, threads: 2,
                                                  validatedHash: saved.validatedHash)
        XCTAssertEqual(replay.validatedHash, hash,
                       "Changing only final presentation metadata must not invalidate the reviewed candidate.")
        XCTAssertEqual(replay.volume, built.volume)
        XCTAssertEqual(replay.bounds, built.bounds)
    }

    @MainActor
    func testPreviewDefersSTEPThenExportsAndReusesExactSessionBytes() async throws {
        try requireRuntime()
        let spec = ModelSpec(title: "Deferred STEP assembly", summary: "Located exact solids, retaining STEP only for export.", units: "mm", script: """
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
        let source = ResourcePaths.root.appendingPathComponent("Examples/lofted-shell.json")
        let spec = try JSONDecoder().decode(ModelSpec.self, from: Data(contentsOf: source))
        let mesh = try await EngineService().build(spec, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(mesh.solids, 2)
        XCTAssertGreaterThan(mesh.volume, 125)
        XCTAssertEqual(Set(mesh.triangleSolids ?? []), Set([0, 1]))
        let step = try String(contentsOfFile: mesh.stepPath, encoding: .utf8)
        XCTAssertTrue(step.hasPrefix("ISO-10303-21;"))
    }

    @MainActor
    func testPreviewRejectsSampledValidOffsetGeometryDuringGeneration() async throws {
        try requireRuntime()
        let program = """
        points = [cq.Vector(x*0.06, y*0.06, 0)
                  for x,y in [(404,330),(295,386),(201,418),(211,500)]]
        curve = cq.Edge.makeBezier(points)
        trace = cq.Wire.assembleEdges([curve, cq.Edge.makeLine(points[-1], points[0])])
        offsets = trace.offset2D(0.75, 'arc') + trace.offset2D(-0.75, 'arc')
        offsets.sort(key=lambda wire: cq.Face.makeFromWires(wire).Area(), reverse=True)
        result = cq.Solid.extrudeLinear(offsets[0], offsets[1:], cq.Vector(0,0,2))
        assert result.isValid()
        """
        let spec = ModelSpec(title: "Invalid curved ridge", summary: "Regression for sampled native validation.", units: "mm", script: program)
        do {
            _ = try await EngineService().buildPreview(spec, python: EngineService.defaultPython, threads: 2)
            XCTFail("The candidate must fail before a preview can be accepted or saved.")
        } catch {
            let diagnostic = error.localizedDescription
            XCTAssertTrue(diagnostic.contains("OpenCascade geometry validation failed"), diagnostic)
            XCTAssertTrue(diagnostic.contains("BRepCheck_UnorientableShape"), diagnostic)
            XCTAssertTrue(diagnostic.contains("Geometry scope: native_candidate"), diagnostic)
            XCTAssertTrue(diagnostic.contains("bounds (mm):"), diagnostic)
            XCTAssertFalse(diagnostic.contains("Geometry scope: step_readback"), diagnostic)
        }
    }

    @MainActor
    func testSTEPReadbackDiagnosticsPreserveTransferredGeometryAndValidAlternative() async throws {
        try requireRuntime()
        func slotProgram(radius: Int) -> String {
            """
            sphere = cq.Solid.makeSphere(50, angleDegrees1=-90, angleDegrees2=90).rotate((0,0,0),(1,0,0),-55)
            cutter = (cq.Workplane('XZ').center(0,-19.75).sketch().rect(15,8.5)
                      .vertices().fillet(\(radius)).finalize().extrude(200).val())
            result = sphere.cut(cutter).clean()
            assert result.isValid()
            """
        }
        let engine = EngineService()
        let rejected = ModelSpec(title: "Transferred rounded slot", summary: "Native geometry passes but STEP readback has invalid edges.",
                                 units: "mm", script: slotProgram(radius: 3))
        do {
            _ = try await engine.buildPreview(rejected, python: EngineService.defaultPython, threads: 2)
            XCTFail("An invalid STEP readback must fail before a preview is accepted.")
        } catch {
            let diagnostic = error.localizedDescription
            for required in ["Design failed STEP verification before acceptance", "Geometry scope: step_readback",
                             "BRepCheck_InvalidCurveOnSurface", "BRepCheck_InvalidSameParameterFlag", "bounds (mm):",
                             "edge tolerance:", "max curve-on-surface discrepancy:", " at [",
                             "STEP readback indices must not be used as selections in the original design."] {
                XCTAssertTrue(diagnostic.contains(required), diagnostic)
            }
            XCTAssertFalse(diagnostic.contains("Geometry scope: native_candidate"), diagnostic)
            let repair = EngineFailureDiagnostic.repairText(for: error)
            XCTAssertTrue(repair.contains("Geometry scope: step_readback"), repair)
            XCTAssertTrue(repair.contains("max curve-on-surface discrepancy:"), repair)
        }
        let accepted = ModelSpec(title: "Valid rounded slot", summary: "A one-millimeter corner radius survives STEP readback.",
                                 units: "mm", script: slotProgram(radius: 1))
        let preview = try await engine.buildPreview(accepted, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(preview.solids, 1)
        XCTAssertGreaterThan(preview.volume, 0)
        XCTAssertFalse(preview.triangles.isEmpty)
        XCTAssertNotNil(preview.validatedHash)
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
