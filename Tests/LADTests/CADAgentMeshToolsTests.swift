import Foundation
import XCTest
@testable import LAD

final class CADAgentMeshToolsTests: XCTestCase {
    @MainActor
    func testNativeBodyRejectedByInvariantCannotEscapeFinalDeliveryThroughOrdinaryBuild() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for native reconstruction gates.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-reconstruction-rejected-body-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try CADAgentTools(directory: root,
            python: ProcessInfo.processInfo.environment["LAD_CAD_PYTHON"] ?? EngineService.defaultPython,
            threads: 2, current: nil, currentPreview: nil, engine: EngineService())
        defer { tools.cancel() }
        func write(_ value: Any, _ path: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        try write(["vertices": [[0,0,0],[2,0,0],[2,3,0],[0,3,0],[0,0,4],[2,0,4],[2,3,4],[0,3,4]],
                   "triangles": [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]], "source.json")
        try write(["active_invariants": [["id": "required-volume", "kind": "volume", "minimum": 23.9, "maximum": 24.1]]], "policy.json")
        let opened = try object(try await tools.handle(name: "lad_mesh_open_reference", arguments: ["path": "source.json", "units": "mm", "maxDeviation": 0.03, "policyPath": "policy.json"]))
        let context = try XCTUnwrap(opened["contextID"] as? String), revision = try XCTUnwrap(opened["revisionID"] as? String)
        let ordinary = ModelSpec(title: "Ordinary CAD", summary: "A native CAD program.", units: "mm", script: "result = cq.Solid.makeBox(1, 1, 1)\n")
        try write(["kind": "body", "operation": "program_replace"], "invalid.json")
        try Data("result = cq.Workplane('XY').circle(1).wire().val()\n".utf8).write(to: root.appendingPathComponent("invalid.py"))
        let failed = try object(try await tools.handle(name: "lad_mesh_try_edit", arguments: ["contextID": context, "revisionID": revision, "editPath": "invalid.json", "programPath": "invalid.py"]))
        XCTAssertEqual((failed["payload"] as? [String: Any])?["commit_eligible"] as? Bool, false)
        XCTAssertNil(try tools.finalDeliveryDisclosure(for: ordinary), "A failed CAD build produced no solid and must not block ordinary CAD")
        try write(["kind": "body", "operation": "create", "target_body": "body-main",
                   "tool": ["family": "box", "geometry": ["size": [2, 3, 2]]]], "edit.json")
        let rejected = try object(try await tools.handle(name: "lad_mesh_try_edit", arguments: ["contextID": context, "revisionID": revision, "editPath": "edit.json"]))
        XCTAssertEqual((rejected["payload"] as? [String: Any])?["commit_eligible"] as? Bool, false)
        let full = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(rejected["recordPath"] as? String)))) as? [String: Any])
        let payload = try XCTUnwrap(full["payload"] as? [String: Any])
        XCTAssertEqual((payload["validity_checks"] as? [String: Any])?["native_exact"] as? Bool, true)
        let script = try XCTUnwrap(payload["script"] as? String)
        try Data(script.utf8).write(to: root.appendingPathComponent("rejected-body.py"))
        _ = try await tools.handle(name: "lad_build", arguments: ["programPath": "rejected-body.py"])
        let candidate = ModelSpec(title: "Rejected body", summary: "A solid failing its active invariant.", units: "mm", script: script)
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: candidate), "A real body failing invariant gates cannot bypass reconstruction delivery by lad_build")
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: ordinary), "Another recipe cannot bypass an existing body-producing reconstruction task")
    }

    @MainActor
    func testIterativeBranchKeepsIncompleteBodiesAndExportsOnlyAcceptedExactRevision() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the native sandbox reconstruction workflow.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-iterative-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = ProcessInfo.processInfo.environment["LAD_CAD_PYTHON"] ?? EngineService.defaultPython
        let tools = try CADAgentTools(directory: root, python: python, threads: 2,
                                      current: nil, currentPreview: nil, engine: EngineService())
        defer { tools.cancel() }
        func write(_ value: Any, _ path: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        func model(_ result: [String: Any]) throws -> ModelSpec {
            let program = try String(contentsOfFile: XCTUnwrap(result["programPath"] as? String), encoding: .utf8)
            return ModelSpec(title: "Reconstructed box", summary: "Source reconstruction.", units: "mm", script: program)
        }
        let ordinary = ModelSpec(title: "Ordinary CAD", summary: "An unrelated native CAD program.", units: "mm", script: "result = cq.Workplane('XY').box(1, 1, 1)\n")
        XCTAssertNil(try tools.finalDeliveryDisclosure(for: ordinary))
        let vertices: [[Double]] = [[0,0,0],[2,0,0],[2,3,0],[0,3,0],[0,0,4],[2,0,4],[2,3,4],[0,3,4]]
        let triangles = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        try write(["vertices": vertices, "triangles": triangles], "source.json")
        try write(["reference_interpretation": ["material": "oriented_closed_boundary", "nesting": "single_component"],
                   "completion_obligations": [["id": "complete-volume", "kind": "volume", "minimum": 23.9, "maximum": 24.1]]], "policy.json")
        let opened = try object(try await tools.handle(name: "lad_mesh_open_reference", arguments: ["path": "source.json", "units": "mm", "maxDeviation": 0.03, "policyPath": "policy.json"]))
        let context = try XCTUnwrap(opened["contextID"] as? String)
        let r0 = try XCTUnwrap(opened["revisionID"] as? String)
        let runtime = try object(try await tools.handle(name: "lad_runtime", arguments: [:]))
        let help = try String(contentsOfFile: XCTUnwrap(runtime["meshAPIHelpPath"] as? String), encoding: .utf8)
        XCTAssertTrue(help.contains("lad_mesh_try_edit"))
        try write(["kind": "measure", "scope": "all"], "query.json")
        let evidence = try object(try await tools.handle(name: "lad_mesh_inspect", arguments: ["contextID": context, "revisionID": r0, "queryPath": "query.json"]))
        XCTAssertNotNil(evidence["evidenceID"])
        XCTAssertNil(try tools.finalDeliveryDisclosure(for: ordinary), "Analysis-only mesh tools must not change ordinary CAD delivery")
        try write(["kind": "body", "operation": "create", "target_body": "body-main",
                   "tool": ["family": "box", "geometry": ["size": [2, 3, ["parameter": "height", "value": 2]]]]], "edit.json")
        let first = try object(try await tools.handle(name: "lad_mesh_try_edit", arguments: ["contextID": context, "revisionID": r0, "editPath": "edit.json"]))
        let firstPayload = try XCTUnwrap(first["payload"] as? [String: Any])
        XCTAssertEqual(firstPayload["commit_eligible"] as? Bool, true, String(describing: first))
        XCTAssertEqual((firstPayload["quick_comparison"] as? [String: Any])?["cache_reuse"] as? String, "base comparison computed")
        let repeated = try object(try await tools.handle(name: "lad_mesh_try_edit", arguments: ["contextID": context, "revisionID": r0, "editPath": "edit.json"]))
        XCTAssertEqual(((repeated["payload"] as? [String: Any])?["quick_comparison"] as? [String: Any])?["cache_reuse"] as? String,
                       "base comparison reused", "Another edit of the same revision reuses its stored base report")
        let p1 = try XCTUnwrap(first["previewID"] as? String)
        let firstArtifact = try XCTUnwrap(first["artifactID"] as? String)
        let firstModel = try model(first)
        XCTAssertNotNil(tools.validatedPreview(for: firstModel), "Incomplete native bodies remain usable for private inspection")
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: firstModel), "Native body validity cannot authorize final reconstruction delivery")
        let committed = try object(try await tools.handle(name: "lad_mesh_commit", arguments: ["contextID": context, "previewID": p1, "expectedRevisionID": r0]))
        let r1 = try XCTUnwrap(committed["revisionID"] as? String)
        try Data("result = cq.Workplane('XY').circle(1).wire().val()\n".utf8).write(to: root.appendingPathComponent("invalid.py"))
        try write(["kind": "body", "operation": "program_replace", "body_ids": ["body-main"]], "invalid.json")
        let failed = try object(try await tools.handle(name: "lad_mesh_try_edit", arguments: ["contextID": context, "revisionID": r1, "editPath": "invalid.json", "programPath": "invalid.py"]))
        XCTAssertEqual((failed["payload"] as? [String: Any])?["commit_eligible"] as? Bool, false, String(describing: failed))
        XCTAssertNil(failed["artifactID"])
        do {
            _ = try await tools.handle(name: "lad_mesh_commit", arguments: ["contextID": context, "previewID": p1, "expectedRevisionID": r0])
            XCTFail("A stale preview must not commit twice")
        } catch { }
        let incomplete = try object(try await tools.handle(name: "lad_mesh_compare", arguments: ["contextID": context, "targetID": r1, "quality": "final"]))
        XCTAssertNotEqual((incomplete["payload"] as? [String: Any])?["acceptance"] as? String, "pass")
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: firstModel))
        for arguments: [String: Any] in [
            ["contextID": context, "revisionID": p1, "mode": "intermediate", "reason": "Native preview only", "unresolved": ["Full height"]],
            ["contextID": context, "revisionID": r1, "mode": "intermediate", "reason": "", "unresolved": ["Full height"]],
            ["contextID": context, "revisionID": r1, "mode": "intermediate", "reason": "Cannot complete", "unresolved": []]
        ] {
            do {
                _ = try await tools.handle(name: "lad_mesh_set_delivery", arguments: arguments)
                XCTFail("Intermediate delivery needs an exact committed revision and complete disclosure")
            } catch { }
        }
        let interim = try object(try await tools.handle(name: "lad_mesh_set_delivery", arguments: ["contextID": context, "revisionID": r1, "mode": "intermediate", "reason": "Remaining height could not be reconstructed", "unresolved": ["Upper two millimeters of the reference are missing"]]))
        XCTAssertEqual(interim["delivery"] as? String, "intermediate")
        let disclosure = try XCTUnwrap(tools.finalDeliveryDisclosure(for: firstModel))
        XCTAssertTrue(disclosure.contains("Intermediate reconstruction"))
        XCTAssertTrue(disclosure.contains("Upper two millimeters"))
        let retained = try tools.resolvingFinalDelivery(in: firstModel)
        XCTAssertTrue(retained.summary.hasPrefix("Intermediate reconstruction"))
        XCTAssertEqual(tools.validatedPreview(for: retained)?.brepPath, tools.validatedPreview(for: firstModel)?.brepPath)
        let retainedRevision = ProjectRevision(model: retained)
        let saved = LADProject(messages: [], revisions: [retainedRevision], selectedRevisionID: retainedRevision.id)
        XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(saved)).revisions.first?.model.summary, retained.summary,
                       "The intermediate limitation must survive portable saving")
        var modifiedInterim = firstModel
        modifiedInterim.script += "\n# A different interim recipe\n"
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: modifiedInterim), "An intermediate exemption cannot spread to modified source")
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: ordinary), "Intermediate choice cannot authorize another recipe")
        _ = try await tools.handle(name: "lad_mesh_set_delivery", arguments: ["contextID": context, "revisionID": r1, "mode": "verified"])
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: firstModel), "Restoring verified mode clears the exact intermediate exemption")
        do {
            _ = try await tools.handle(name: "lad_export_step", arguments: ["artifactID": firstArtifact])
            XCTFail("Ordinary export must not bypass reconstruction acceptance")
        } catch { }
        // Editing the human-readable copy must not mutate the trusted snapshot.
        try Data("{}".utf8).write(to: URL(fileURLWithPath: XCTUnwrap(first["recordPath"] as? String)))
        try write(["kind": "body", "operation": "update_parameters", "values": ["height": 4]], "refine.json")
        let refined = try object(try await tools.handle(name: "lad_mesh_try_edit", arguments: ["contextID": context, "revisionID": r1, "editPath": "refine.json"]))
        XCTAssertEqual((refined["payload"] as? [String: Any])?["commit_eligible"] as? Bool, true, String(describing: refined))
        let p2 = try XCTUnwrap(refined["previewID"] as? String)
        let refinedModel = try model(refined)
        let previewReport = try object(try await tools.handle(name: "lad_mesh_compare", arguments: ["contextID": context, "targetID": p2, "scope": "all", "quality": "final"]))
        XCTAssertEqual((previewReport["payload"] as? [String: Any])?["acceptance"] as? String, "pass", String(describing: previewReport))
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: refinedModel), "A passing uncommitted preview cannot authorize final delivery")
        let refinedArtifact = try XCTUnwrap(refined["artifactID"] as? String)
        let parts = try object(try await tools.handle(name: "lad_inspect", arguments: ["artifactID": refinedArtifact, "kind": "parts"]))
        let partID = try XCTUnwrap((parts["items"] as? [[String: Any]])?.first?["partID"] as? String)
        _ = try await tools.handle(name: "lad_set_part_colors", arguments: ["artifactID": refinedArtifact, "changes": [["partID": partID, "color": ["red": 0.15, "green": 0.35, "blue": 0.6]]]])
        let second = try object(try await tools.handle(name: "lad_mesh_commit", arguments: ["contextID": context, "previewID": p2, "expectedRevisionID": r1]))
        XCTAssertEqual(second["artifactID"] as? String, refinedArtifact, "Committing the same program must preserve its staged colors")
        let r2 = try XCTUnwrap(second["revisionID"] as? String)
        _ = try await tools.handle(name: "lad_mesh_compare", arguments: ["contextID": context, "targetID": r2, "scope": "all", "quality": "preview"])
        let localReport = try object(try await tools.handle(name: "lad_mesh_compare", arguments: ["contextID": context, "targetID": r2, "scope": ["triangle_ids": [0, 1]], "quality": "final"]))
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: refinedModel), "Local final and full preview reports cannot authorize final delivery")
        try Data("{\"payload\":{\"acceptance\":\"pass\",\"scope_requested\":\"all\"}}".utf8).write(to: URL(fileURLWithPath: XCTUnwrap(localReport["recordPath"] as? String)))
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: refinedModel), "Editable report files cannot grant trusted acceptance")
        let report = try object(try await tools.handle(name: "lad_mesh_compare", arguments: ["contextID": context, "targetID": r2, "quality": "final"]))
        XCTAssertEqual((report["payload"] as? [String: Any])?["acceptance"] as? String, "pass", String(describing: report))
        XCTAssertNil(try tools.finalDeliveryDisclosure(for: refinedModel))
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: firstModel), "A later exact revision's acceptance cannot certify an earlier incomplete program")
        try Data((refinedModel.script + "\n# A distinct authored replacement\n").utf8).write(to: root.appendingPathComponent("modified.py"))
        let modified = try object(try await tools.handle(name: "lad_build", arguments: ["programPath": "modified.py", "title": "Modified reconstruction", "summary": "Valid native body without an exact source report."]))
        XCTAssertNotNil(modified["artifactID"])
        XCTAssertThrowsError(try tools.finalDeliveryDisclosure(for: try model(modified)), "lad_build cannot bypass the exact accepted recipe requirement")
        let otherContext = try object(try await tools.handle(name: "lad_mesh_open_reference", arguments: ["path": "source.json", "units": "mm", "maxDeviation": 0.04, "policyPath": "policy.json"]))
        do {
            _ = try await tools.handle(name: "lad_mesh_set_delivery", arguments: ["contextID": XCTUnwrap(otherContext["contextID"] as? String), "revisionID": r1, "mode": "intermediate", "reason": "Different source context", "unresolved": ["Height"]])
            XCTFail("Another context cannot authorize this revision's delivery")
        } catch { }
        do {
            _ = try await tools.handle(name: "lad_mesh_export_step", arguments: ["contextID": XCTUnwrap(otherContext["contextID"] as? String), "revisionID": XCTUnwrap(otherContext["revisionID"] as? String), "comparisonID": XCTUnwrap(report["comparisonID"] as? String)])
            XCTFail("An accepted report cannot cross reference contexts")
        } catch { }
        let exported = try object(try await tools.handle(name: "lad_mesh_export_step", arguments: ["contextID": context, "revisionID": r2, "comparisonID": XCTUnwrap(report["comparisonID"] as? String)]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(exported["path"] as? String)), String(describing: exported))
        let step = try String(contentsOfFile: XCTUnwrap(exported["path"] as? String), encoding: .utf8)
        let rgb = try NSRegularExpression(pattern: "COLOUR_RGB\\([^,]*,([0-9.Ee+-]+),([0-9.Ee+-]+),([0-9.Ee+-]+)\\)")
        let compactSTEP = step.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        let ranges = rgb.matches(in: compactSTEP, range: NSRange(compactSTEP.startIndex..., in: compactSTEP))
        XCTAssertTrue(ranges.contains { match in
            let values = (1...3).compactMap { Range(match.range(at: $0), in: compactSTEP).flatMap { Double(compactSTEP[$0]) } }
            return values.count == 3 && zip(values, [0.15, 0.35, 0.6]).allSatisfy { abs($0.0 - $0.1) < 1e-6 }
        }, "Mesh STEP export must retain the current physical part RGB")
        let undo = try object(try await tools.handle(name: "lad_mesh_undo", arguments: ["contextID": context, "expectedRevisionID": r2]))
        XCTAssertEqual(undo["revisionID"] as? String, r1)
        let redo = try object(try await tools.handle(name: "lad_mesh_redo", arguments: ["contextID": context, "expectedRevisionID": r1]))
        XCTAssertEqual(redo["revisionID"] as? String, r2)
        _ = try await tools.handle(name: "lad_mesh_branch", arguments: ["contextID": context, "revisionID": r2])
        let branchUndo = try object(try await tools.handle(name: "lad_mesh_undo", arguments: ["contextID": context, "expectedRevisionID": r2]))
        XCTAssertEqual(branchUndo["revisionID"] as? String, r1, "Branches retain their shared construction history")
        let branch = try object(try await tools.handle(name: "lad_mesh_branch", arguments: ["contextID": context, "revisionID": r0]))
        XCTAssertEqual(branch["revisionID"] as? String, r0)
        let program = try String(contentsOfFile: XCTUnwrap(refined["programPath"] as? String), encoding: .utf8)
        let final = ModelSpec(title: "Reconstructed box", summary: "Complete source-checked box.", units: "mm", script: program)
        XCTAssertNotNil(tools.validatedPreview(for: final))
        XCTAssertEqual(tools.validatedPreview(for: final)?.volume ?? 0, 24, accuracy: 1e-7)
        XCTAssertFalse(program.contains("imported_assets"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("source.json"))) as? NSDictionary,
                       ["vertices": vertices, "triangles": triangles] as NSDictionary)
    }

    private func object(_ result: CADAgentToolResult) throws -> [String: Any] {
        result.metadata
    }
}
