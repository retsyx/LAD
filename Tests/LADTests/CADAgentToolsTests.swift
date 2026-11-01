import AppKit
import Foundation
import XCTest
@testable import LAD

final class CADAgentToolsTests: XCTestCase {
    func testWorkspaceRejectsTraversalLinksAndKeepsAtomicWritesInsideItsRoot() throws {
        let root = temporary(), outside = temporary()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let workspace = try CADAgentWorkspace(directory: root)
        let original = outside.appendingPathComponent("original.txt")
        try Data("unchanged".utf8).write(to: original)
        XCTAssertThrowsError(try workspace.url("../escape.txt"))
        XCTAssertThrowsError(try workspace.read(original.path, maximumBytes: 100))
        XCTAssertThrowsError(try workspace.url("bad\0path"))
        let symlink = root.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        XCTAssertThrowsError(try workspace.read("symlink.txt", maximumBytes: 100))
        let hardlink = root.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: original, to: hardlink)
        XCTAssertThrowsError(try workspace.read("hardlink.txt", maximumBytes: 100))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertThrowsError(try workspace.write(Data("unsafe".utf8), path: "linked/changed.txt"))
        // Atomic output replaces a workspace link itself; it never follows the
        // link into the external source and changes its bytes.
        _ = try workspace.write(Data("workspace output".utf8), path: "symlink.txt")
        XCTAssertEqual(try Data(contentsOf: original), Data("unchanged".utf8))
        XCTAssertEqual(try workspace.read("symlink.txt", maximumBytes: 100), Data("workspace output".utf8))
        let nested = try workspace.write(Data("nested".utf8), path: "artifacts/a/metadata.txt")
        XCTAssertTrue(nested.path.hasPrefix(workspace.root.path + "/"))
        XCTAssertEqual(try workspace.read(nested.path, maximumBytes: 100), Data("nested".utf8))
        _ = try workspace.write(Data(), path: "requirements.txt")
        XCTAssertThrowsError(try workspace.read("requirements.txt", maximumBytes: 100))
        XCTAssertEqual(try workspace.read("requirements.txt", maximumBytes: 100, allowEmpty: true), Data())
    }

    @MainActor
    func testToolArgumentsFailBeforeRuntimeAndFinalReuseRequiresMatchingConstruction() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("model.brep")
        try Data("DBRep_DrawableShape\n".utf8).write(to: native)
        let first = CADInputAsset(id: "input", name: "input.obj", format: "obj", data: Data("source".utf8))
        let model = ModelSpec(title: "Current", summary: "Current shape", units: "mm", script: "result=imported_assets['input']", inputAssets: [first])
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1], volume: 1,
                                  area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: root.appendingPathComponent("model.step").path, brepPath: native.path)
        let tools = try CADAgentTools(directory: root, python: "/missing/python", threads: 1, current: model,
                                      currentPreview: preview, engine: EngineService())
        let summary = try content(try await tools.handle(name: "lad_inspect", arguments: [:]))
        XCTAssertEqual(summary["artifactID"] as? String, "current")
        XCTAssertEqual(summary["solids"] as? Int, 1)
        XCTAssertEqual(try tools.resolveAssets(ids: ["input"]), [first])
        XCTAssertThrowsError(try tools.resolveAssets(ids: ["missing"]))
        XCTAssertThrowsError(try tools.resolveAssets(ids: ["input", "input"]))
        var renamed = model; renamed.title = "Renamed"; renamed.summary = "New prose"
        XCTAssertNotNil(tools.validatedPreview(for: renamed), "Metadata edits need no extra CAD build")
        renamed.script = "result=cq.Solid.makeBox(2,2,2)"
        XCTAssertNil(tools.validatedPreview(for: renamed))
        for (name, args) in [("unknown", [:]), ("lad_build", ["programPath": "/outside/file.py"]),
                             ("lad_runtime", ["unexpected": true]), ("lad_render", ["width": true]) ] as [(String,[String:Any])] {
            do { _ = try await tools.handle(name: name, arguments: args); XCTFail("Invalid tool call must fail") }
            catch { XCTAssertFalse(error.localizedDescription.contains("Python runtime not found")) }
        }
        tools.cancel()
        do { _ = try await tools.handle(name: "lad_inspect", arguments: [:]); XCTFail("Stopped tools must not run") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    @MainActor
    func testPreviewReusePreservesTheInsertionOrderAvailableToPythonPrograms() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("model.brep")
        try Data("DBRep_DrawableShape\n".utf8).write(to: native)
        let first = CADInputAsset(id: "first", name: "one.obj", format: "obj", data: Data("first input".utf8))
        let second = CADInputAsset(id: "second", name: "two.obj", format: "obj", data: Data("second input".utf8))
        let model = ModelSpec(title: "First input", summary: "Iterates complete Python input dictionary.", units: "mm",
                              script: "result = next(iter(imported_assets.values()))", inputAssets: [first, second])
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1], volume: 1,
                                  area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: root.appendingPathComponent("model.step").path, brepPath: native.path)
        let tools = try CADAgentTools(directory: root, python: "/missing/python", threads: 1, current: model,
                                      currentPreview: preview, engine: EngineService())
        XCTAssertNotNil(tools.validatedPreview(for: model))
        var reordered = model
        reordered.inputAssets = [second, first]
        XCTAssertNil(tools.validatedPreview(for: reordered), "The same program can select a different shape after dictionary insertion order changes.")
        var renamed = model
        renamed.title = "Metadata change"
        renamed.inputAssets?[0].name = "renamed source.obj"
        XCTAssertNotNil(tools.validatedPreview(for: renamed), "Provenance names and prose do not affect the injected geometry.")
    }

    @MainActor
    func testNativeAgentBuildInspectMeasureRenderExportAndPortableExternalImport() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to exercise the complete native agent CAD tool interface.")
        }
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let program = """
        loft = cq.Workplane('XY').circle(2).workplane(offset=5).circle(3).loft()
        result = cq.Assembly(name='Test', metadata={'lad_id':'test'})
        result.add(loft, name='Loft', metadata={'lad_id':'loft'})
        result.add(cq.Solid.makeBox(1,1,1).translate((10,0,0)), name='Block', metadata={'lad_id':'block'})
        """
        try Data(program.utf8).write(to: root.appendingPathComponent("program.py"))
        let engine = EngineService()
        let tools = try CADAgentTools(directory: root, python: EngineService.defaultPython, threads: 4,
                                      current: nil, currentPreview: nil, engine: engine)
        let runtime = try content(try await tools.handle(name: "lad_runtime", arguments: [:]))
        XCTAssertEqual(runtime["pythonExecutable"] as? String, EngineService.defaultPython)
        XCTAssertNotNil((runtime["runtime"] as? [String: Any])?["cadquery"])
        let built = try content(try await tools.handle(name: "lad_build", arguments: ["programPath": "program.py", "title": "Loft and block"]))
        let id = try XCTUnwrap(built["artifactID"] as? String)
        XCTAssertEqual(built["solids"] as? Int, 2)
        let retained = try XCTUnwrap(tools.validatedPreview(for: ModelSpec(title: "Final title", summary: "Final text", units: "mm", script: program)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.stepPath), "Speculative tools must defer STEP")
        let inspected = try content(try await tools.handle(name: "lad_inspect", arguments: ["artifactID": id, "kind": "vertices", "solidIndices": [1], "limit": 2]))
        let vertices = try XCTUnwrap(inspected["items"] as? [[String: Any]])
        XCTAssertEqual(vertices.count, 2)
        XCTAssertTrue(try XCTUnwrap(inspected["hasMore"] as? Bool))
        let features = vertices.compactMap { $0["id"] as? [String: Any] }
        let report = try content(try await tools.handle(name: "lad_measure", arguments: ["artifactID": id, "features": features, "solidIndices": []]))
        XCTAssertTrue(try XCTUnwrap(report["metrics"] as? [[String: Any]]).contains { $0["id"] as? String == "pair:distance" })
        let valid = try content(try await tools.handle(name: "lad_validate", arguments: ["artifactID": id]))
        XCTAssertEqual(valid["valid"] as? Bool, true)
        let image = try await tools.handle(name: "lad_render", arguments: ["artifactID": id, "view": "front", "width": 400, "height": 300])
        let imageContent = try XCTUnwrap(image["content"] as? [[String: Any]])
        let imageMetadata = try content(image)
        let imagePath = try XCTUnwrap(imageContent.first { $0["type"] as? String == "image_path" }?["path"] as? String)
        let png = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        XCTAssertEqual(imageMetadata["byteCount"] as? Int, png.count)
        XCTAssertEqual((imageMetadata["sha256"] as? String)?.count, 64)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 400); XCTAssertEqual(bitmap.pixelsHigh, 300)
        let exported = try content(try await tools.handle(name: "lad_export_step", arguments: ["artifactID": id, "solidIndices": [1], "path": "exports/block.step"]))
        let exportedPath = try XCTUnwrap(exported["path"] as? String)
        XCTAssertTrue(exportedPath.hasPrefix(try EngineArtifact.canonicalDirectory(root).path + "/"))
        let imported = try content(try await tools.handle(name: "lad_import", arguments: ["path": exportedPath]))
        let assetID = try XCTUnwrap(imported["assetID"] as? String)
        XCTAssertEqual(imported["solids"] as? Int, 1)
        let assets = try tools.resolveAssets(ids: [assetID])
        XCTAssertEqual(assets.count, 1)
        let replay = ModelSpec(title: "Portable block", summary: "Replay external input", units: "mm",
                               script: "result = imported_assets['\(assetID)']", inputAssets: assets)
        let rebuilt = try await engine.buildPreview(replay, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(rebuilt.solids, 1); XCTAssertEqual(rebuilt.volume, 1, accuracy: 1e-9)
        XCTAssertEqual(rebuilt.bounds[0], 10, accuracy: 1e-6)
        let duplicate = try content(try await tools.handle(name: "lad_import", arguments: ["path": exportedPath]))
        XCTAssertEqual(duplicate["assetID"] as? String, assetID, "An identical external file gets one content identity")
        let unknown = root.appendingPathComponent("empty.obj")
        try Data("v 0 0 0\n".utf8).write(to: unknown)
        do { _ = try await tools.handle(name: "lad_import", arguments: ["path": unknown.path]); XCTFail("An empty external mesh must not become a design") }
        catch { XCTAssertTrue(error.localizedDescription.contains("closed mesh")) }
    }

    @MainActor
    func testAgentImportsSTLAndReplaysWithoutOriginalFile() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to exercise native STL import.")
        }
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        // A pre-existing closed tetrahedron, independent of any LAD-generated geometry.
        let triangles = [
            [[0, 0, 0], [0, 3, 0], [2, 0, 0]],
            [[0, 0, 0], [2, 0, 0], [0, 0, 4]],
            [[2, 0, 0], [0, 3, 0], [0, 0, 4]],
            [[0, 3, 0], [0, 0, 0], [0, 0, 4]]
        ]
        let text = "solid reference\n" + triangles.map { triangle in
            "facet normal 0 0 0\nouter loop\n" + triangle.map {
                "vertex \($0[0]) \($0[1]) \($0[2])\n"
            }.joined() + "endloop\nendfacet\n"
        }.joined() + "endsolid reference\n"
        let bytes = Data(text.utf8)
        let path = root.appendingPathComponent("reference.STL")
        try bytes.write(to: path)
        let engine = EngineService()
        let tools = try CADAgentTools(directory: root, python: EngineService.defaultPython, threads: 2,
                                      current: nil, currentPreview: nil, engine: engine)
        let imported = try content(try await tools.handle(name: "lad_import", arguments: ["path": path.path]))
        let id = try XCTUnwrap(imported["assetID"] as? String)
        XCTAssertEqual(imported["format"] as? String, "stl")
        XCTAssertEqual(imported["solids"] as? Int, 1)
        XCTAssertTrue((imported["fidelity"] as? String)?.contains("faceted") == true)
        let assets = try tools.resolveAssets(ids: [id])
        XCTAssertEqual(assets.first?.data, bytes)
        try FileManager.default.removeItem(at: path)
        let model = ModelSpec(title: "STL reference", summary: "Portable mesh input", units: "mm",
                              script: "result = imported_assets['\(id)']", inputAssets: assets)
        let preview = try await engine.buildPreview(model, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(preview.solids, 1)
        XCTAssertEqual(preview.volume, 4, accuracy: 1e-7)
    }

    private func content(_ result: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-agent-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
