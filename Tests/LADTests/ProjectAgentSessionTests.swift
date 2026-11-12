import AppKit
import Foundation
import XCTest
@testable import LAD

final class ProjectAgentSessionTests: XCTestCase {
    @MainActor
    func testUploadsAreImmutableTaskScopedAndRejectFilesystemPaths() async throws {
        let first = try session(), second = try session()
        defer { first.cancel(); second.cancel() }
        let original = Data("result = cq.Solid.makeBox(1, 2, 3)\n".utf8)
        let descriptor = try await first.uploadFile(data: original, name: "program.py")
        let identity = try XCTUnwrap(descriptor["fileID"] as? String)
        let downloaded = try await first.downloadFile(fileID: identity)
        XCTAssertEqual(downloaded.data, original)
        XCTAssertThrowsError(try second.download(fileID: identity))
        XCTAssertThrowsError(try first.download(fileID: "/etc/passwd"))
        XCTAssertThrowsError(try first.upload(data: original, name: "../program.py"))
        XCTAssertThrowsError(try first.upload(data: original, name: "bad\\program.py"))
        XCTAssertThrowsError(try first.upload(data: original, name: "bad\nprogram.py"))
        XCTAssertThrowsError(try first.upload(data: Data(), name: "empty.py"))
        do {
            _ = try await first.call(name: "lad_build", arguments: ["programID": "/etc/passwd"])
            XCTFail("An external tool must accept only known task file IDs.")
        } catch { XCTAssertFalse(error.localizedDescription.contains("Python runtime")) }
        XCTAssertEqual(try first.download(fileID: identity).data, original)
        let folder = first.workspaceURL
        first.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertThrowsError(try first.download(fileID: identity))
        do {
            _ = try await first.candidate(artifactID: "current")
            XCTFail("A canceled task must not provide a commit candidate.")
        } catch {}
    }

    @MainActor
    func testCurrentCandidateUsesItsExactProgramAndSeparateDownloadHandles() async throws {
        let native = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-Agent-Native-\(UUID().uuidString).brep")
        try Data("DBRep_DrawableShape\n".utf8).write(to: native)
        defer { try? FileManager.default.removeItem(at: native) }
        let model = ModelSpec(title: "Current", summary: "A validated design.", units: "mm", script: "result = cq.Solid.makeBox(1, 1, 1)\n")
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1], volume: 1,
            area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
            stepPath: native.deletingPathExtension().appendingPathExtension("step").path, brepPath: native.path)
        let task = try ProjectAgentSession(python: "/missing/python", threads: 1, current: model, currentPreview: preview)
        defer { task.cancel() }
        let result = try await task.call(name: "lad_inspect", arguments: [:])
        let values = try metadata(result)
        let programID = try XCTUnwrap(values["programID"] as? String)
        XCTAssertNil(values["programPath"])
        XCTAssertNotNil(UUID(uuidString: programID))
        XCTAssertEqual(try task.download(fileID: programID).data, Data(model.script.utf8))
        let metadataID = try XCTUnwrap(values["metadataPath"] as? String)
        let bytes = try task.download(fileID: metadataID).data
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(task.workspaceURL.path))
        let currentCandidate = try await task.candidate(artifactID: "current")
        XCTAssertEqual(currentCandidate.model, model)
        XCTAssertEqual(currentCandidate.preview.brepPath, native.path)
        do {
            _ = try await task.call(name: "lad_import", arguments: ["path": programID])
            XCTFail("Generated task files cannot be imported as original references.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("original external reference")) }
        task.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: native.path), "Committed native geometry belongs to its preview, not the task workspace.")
    }

    func testExternalCatalogAddsRoutingAndOpaqueFilesWithoutChangingNativeCatalog() throws {
        let native = try AgentToolCatalog.native()
        let external = try AgentToolCatalog.external()
        XCTAssertEqual(native.tools.map(\.name), external.tools.map(\.name))
        let nativeSchema = try XCTUnwrap(native["lad_build"]).inputSchema
        let schema = try XCTUnwrap(external["lad_build"]).inputSchema
        XCTAssertTrue((nativeSchema["required"] as? [String] ?? []).contains("programPath"))
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["taskID", "programID"])
        for tool in external.tools {
            XCTAssertTrue((tool.inputSchema["required"] as? [String] ?? []).contains("taskID"))
            XCTAssertEqual(Set(tool.descriptor.keys), ["name", "description", "inputSchema", "annotations"])
            if let export = tool.host.exportPath {
                XCTAssertNil((tool.inputSchema["properties"] as? [String: Any])?[export])
            }
        }
        XCTAssertEqual(Set(native.tools.filter { $0.host.exportPath != nil }.map(\.name)), ["lad_export_step", "lad_mesh_export_step"])
    }

    @MainActor
    func testExplicitCandidateKeepsItsOwnColorsWhenMatchingProgramsShareNativeGeometry() async throws {
        let native = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-Agent-Color-\(UUID().uuidString).brep")
        try Data("DBRep_DrawableShape\n".utf8).write(to: native)
        defer { try? FileManager.default.removeItem(at: native) }
        let model = ModelSpec(title: "Current", summary: "Validated geometry shared by candidates.", units: "mm",
                              script: "result = cq.Solid.makeBox(1, 1, 1)\n")
        let parts = [PartNode(id: "body", name: "Body", solidIndices: [0])]
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1], volume: 1,
            area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
            stepPath: native.deletingPathExtension().appendingPathExtension("step").path, parts: parts, brepPath: native.path)
        let task = try ProjectAgentSession(python: "/missing/python", threads: 1, current: model, currentPreview: preview)
        defer { task.cancel() }
        let program = try task.upload(data: Data(model.script.utf8), name: "same-program.py")
        let programID = try XCTUnwrap(program["fileID"] as? String)
        let first = try metadata(try await task.call(name: "lad_build", arguments: ["programID": programID, "title": "First"]))
        let second = try metadata(try await task.call(name: "lad_build", arguments: ["programID": programID, "title": "Second"]))
        let firstID = try XCTUnwrap(first["artifactID"] as? String)
        let secondID = try XCTUnwrap(second["artifactID"] as? String)
        let red = PartColor(red: 1, green: 0, blue: 0), blue = PartColor(red: 0, green: 0, blue: 1)
        let green = PartColor(red: 0, green: 1, blue: 0)
        for (id, color) in [(firstID, red), (secondID, blue), ("current", green)] {
            _ = try await task.call(name: "lad_set_part_colors", arguments: ["artifactID": id, "changes": [
                ["partID": "body", "color": ["red": color.red, "green": color.green, "blue": color.blue]]
            ]])
        }
        let firstCandidate = try await task.candidate(artifactID: firstID)
        let secondCandidate = try await task.candidate(artifactID: secondID)
        let currentCandidate = try await task.candidate(artifactID: "current")
        XCTAssertEqual(firstCandidate.colorChanges, [CADPartColorChange(partID: "body", color: red)])
        XCTAssertEqual(secondCandidate.colorChanges, [CADPartColorChange(partID: "body", color: blue)])
        XCTAssertEqual(currentCandidate.colorChanges, [CADPartColorChange(partID: "body", color: green)])
        XCTAssertEqual(firstCandidate.preview.brepPath, secondCandidate.preview.brepPath,
                       "The regression must cover distinct reviewed colors on reused native geometry.")
    }

    @MainActor
    func testEvictedCandidatePreviewRebuildsWhenCommitted() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the native external CAD task workflow.")
        }
        let task = try ProjectAgentSession(python: ProcessInfo.processInfo.environment["LAD_CAD_PYTHON"] ?? EngineService.defaultPython,
            threads: 2, current: nil, currentPreview: nil, versions: .empty)
        defer { task.cancel() }
        var artifactIDs = [String]()
        for size in 1...(CADAgentTools.retainedCandidatePreviews + 1) {
            let source = Data("result = cq.Solid.makeBox(\(size), 1, 1)\n".utf8)
            let uploaded = try await task.uploadFile(data: source, name: "box\(size).py")
            let fileID = try XCTUnwrap(uploaded["fileID"] as? String)
            let built = try metadata(try await task.call(name: "lad_build", arguments: ["programID": fileID, "title": "Box \(size)"]))
            artifactIDs.append(try XCTUnwrap(built["artifactID"] as? String))
        }
        let candidate = try await task.candidate(artifactID: artifactIDs[0])
        XCTAssertEqual(candidate.preview.volume, 1, accuracy: 1e-8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(candidate.preview.brepPath)))
    }

    @MainActor
    func testExternalNativeBuildCanCommitAndSurvivesTaskCleanup() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the native external CAD task workflow.")
        }
        let source = Data("result = cq.Solid.makeBox(2, 3, 4)\n".utf8)
        let historical = ProjectRevision(model: ModelSpec(title: "Historical box", summary: "Saved complete recipe.",
            units: "mm", script: String(decoding: source, as: UTF8.self)))
        let task = try ProjectAgentSession(python: ProcessInfo.processInfo.environment["LAD_CAD_PYTHON"] ?? EngineService.defaultPython,
            threads: 2, current: nil, currentPreview: nil,
            versions: ProjectVersionContext(revisions: [historical], selectedRevisionID: nil))
        defer { task.cancel() }
        let uploaded = try await task.uploadFile(data: source, name: "box.py")
        let fileID = try XCTUnwrap(uploaded["fileID"] as? String)
        let built = try metadata(try await task.call(name: "lad_build", arguments: ["programID": fileID, "title": "External box"]))
        let artifactID = try XCTUnwrap(built["artifactID"] as? String)
        let candidate = try await task.candidate(artifactID: artifactID)
        XCTAssertEqual(candidate.model.script, String(decoding: source, as: UTF8.self))
        XCTAssertEqual(candidate.preview.volume, 24, accuracy: 1e-8)
        let replay = try metadata(try await task.call(name: "lad_build", arguments: ["programID": fileID, "versionID": historical.id.uuidString]))
        let historicalArtifactID = try XCTUnwrap(replay["artifactID"] as? String)
        do {
            _ = try await task.candidate(artifactID: historicalArtifactID)
            XCTFail("A historical build must not be committable.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("without versionID"))
        }
        let export = try metadata(try await task.call(name: "lad_export_step", arguments: ["artifactID": artifactID]))
        let stepID = try XCTUnwrap(export["path"] as? String)
        let downloaded = try await task.downloadFile(fileID: stepID)
        let bytes = downloaded.data
        XCTAssertTrue(String(decoding: bytes.prefix(100), as: UTF8.self).contains("ISO-10303-21"))
        do {
            _ = try await task.call(name: "lad_import", arguments: ["path": stepID])
            XCTFail("A generated STEP export must not become a frozen imported input.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Generated CAD exports")) }
        let reuploaded = try await task.uploadFile(data: bytes, name: "renamed-reference.stp")
        do {
            _ = try await task.call(name: "lad_import", arguments: ["path": try XCTUnwrap(reuploaded["fileID"] as? String)])
            XCTFail("Renaming and reuploading generated geometry must not turn it into an original reference.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Generated CAD exports")) }
        let secondExport = try metadata(try await task.call(name: "lad_export_step", arguments: ["artifactID": artifactID]))
        XCTAssertNotEqual(secondExport["path"] as? String, stepID)
        let originalDownload = try await task.downloadFile(fileID: stepID)
        XCTAssertEqual(originalDownload.data, bytes)
        task.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(candidate.preview.brepPath)))
    }

    @MainActor
    private func session() throws -> ProjectAgentSession {
        try ProjectAgentSession(python: "/missing/python", threads: 1, current: nil, currentPreview: nil)
    }

    private func metadata(_ output: ProjectAgentToolResult) throws -> [String: Any] {
        output.result.metadata
    }
}
