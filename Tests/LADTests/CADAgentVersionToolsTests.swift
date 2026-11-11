import Foundation
import XCTest
@testable import LAD

final class CADAgentVersionToolsTests: XCTestCase {
    @MainActor
    func testVersionListingIsPaginatedMetadataOnlyWithoutStartingCADOrStagingFiles() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let revisions = (1...105).map { index in
            ProjectRevision(model: model("Design \(index)", script: "private_program_\(index)"),
                            name: index == 3 ? "Rounded" : nil)
        }
        let tools = try makeTools(root, versions: ProjectVersionContext(revisions: revisions, selectedRevisionID: revisions[2].id))
        let first = try content(try await tools.handle(name: "lad_versions", arguments: [:]))
        let items = try XCTUnwrap(first["items"] as? [[String: Any]])
        XCTAssertEqual(first["total"] as? Int, 105)
        XCTAssertEqual(items.count, 50)
        XCTAssertEqual(first["hasMore"] as? Bool, true)
        XCTAssertEqual(items[2]["version"] as? String, "v3")
        XCTAssertEqual(items[2]["name"] as? String, "Rounded")
        XCTAssertEqual(items[2]["versionID"] as? String, revisions[2].id.uuidString)
        XCTAssertEqual(items[2]["isCurrent"] as? Bool, true)
        XCTAssertNotNil(items[2]["date"] as? String)
        let second = try content(try await tools.handle(name: "lad_versions", arguments: ["offset": 100, "limit": 100]))
        XCTAssertEqual((second["items"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(second["hasMore"] as? Bool, false)
        XCTAssertFalse(String(describing: first).contains("private_program"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        for arguments: [String: Any] in [["offset": -1], ["offset": true], ["limit": 0], ["limit": 101], ["unexpected": 1]] {
            await assertFailure(tools, "lad_versions", arguments)
        }
        let empty = try makeTools(root)
        let emptyList = try content(try await empty.handle(name: "lad_versions", arguments: [:]))
        XCTAssertEqual(emptyList["total"] as? Int, 0)
    }

    @MainActor
    func testLookupUsesStableIDsAndExactNamesAndReturnsAmbiguousCandidatesWithoutGuessing() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ProjectRevision(model: model("First"), name: "Rounded")
        let second = ProjectRevision(model: model("Second"), name: "Rounded")
        let third = ProjectRevision(model: model("Third"), name: "Named third")
        let fourth = ProjectRevision(model: model("Fourth"), name: "v3")
        let fifth = ProjectRevision(model: model("Fifth"), name: first.id.uuidString)
        let tools = try makeTools(root, versions: ProjectVersionContext(revisions: [first, second, third, fourth, fifth], selectedRevisionID: third.id))
        for reference in ["Rounded", "v3"] {
            let result = try content(try await tools.handle(name: "lad_version", arguments: ["reference": reference]))
            XCTAssertEqual(result["status"] as? String, "ambiguous")
            XCTAssertEqual((result["candidates"] as? [[String: Any]])?.count, 2)
            XCTAssertNil(result["programPath"])
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let explicit = try content(try await tools.handle(name: "lad_version", arguments: ["reference": first.id.uuidString.lowercased()]))
        XCTAssertEqual(explicit["versionID"] as? String, first.id.uuidString, "Stable UUID takes precedence over a colliding custom name")
        let named = try content(try await tools.handle(name: "lad_version", arguments: ["reference": "  Named third  "]))
        XCTAssertEqual(named["versionID"] as? String, third.id.uuidString)
        XCTAssertEqual(named["isCurrent"] as? Bool, true)
        let ordinal = try content(try await tools.handle(name: "lad_version", arguments: ["reference": "v2"]))
        XCTAssertEqual(ordinal["versionID"] as? String, second.id.uuidString)
        for reference in ["rounded", "v0", "v99", "v03", "", "   ", UUID().uuidString] {
            await assertFailure(tools, "lad_version", ["reference": reference])
        }
        await assertFailure(tools, "lad_version", ["reference": 3])
        await assertFailure(tools, "lad_version", ["reference": "v1", "unexpected": true])
    }

    @MainActor
    func testLookupStagesCompleteImmutableRecipesAndOnlyRequiredOriginalInputs() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = step("historical original")
        let asset = CADInputAsset(id: "shared", name: "reference.stp", format: "stp", data: source)
        let program = "# complete historical program\n" + String(repeating: "# source must remain a file reference\n", count: 300) + "result = imported_assets['shared']\n"
        let part = PartNode(id: "part", name: "Original part", solidIndices: [0])
        let preview = PreviewMesh(vertices: [[987654, 0, 0]], triangles: [], edges: [], bounds: [0,0,0,1,1,1],
                                  volume: 1, area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: "/private/derived-preview.step", parts: [part], brepPath: "/private/derived-cache.brep")
        var revision = ProjectRevision(model: model("Historical", script: program, source: source, assets: [asset]),
                                       preview: preview, stepData: Data("never stage generated STEP".utf8),
                                       partLayout: PartLayout(nodes: [part]), hiddenSolids: [0],
                                       runtime: CADRuntime(python: "3.12", cadquery: "2.6", ocp: "7.8"), name: "Before")
        revision.jointPositions = ["hinge": 42]
        let context = ProjectVersionContext(revisions: [revision], selectedRevisionID: revision.id)
        revision.name = "After"
        revision.model.script = "mutated later"
        revision.model.inputAssets?[0].data = step("mutated later")
        let currentAsset = CADInputAsset(id: "shared", name: "current.step", format: "step", data: step("current original"))
        let current = model("Current", source: step("current source"), assets: [currentAsset])
        let tools = try makeTools(root, current: current, versions: context)
        let output = try content(try await tools.handle(name: "lad_version", arguments: ["reference": "v1"]))
        XCTAssertEqual(output["name"] as? String, "Before")
        XCTAssertEqual(output["jointPositions"] as? [String: Double], ["hinge": 42])
        XCTAssertEqual(try read(output, "programPath"), Data(program.utf8))
        let saved = try JSONDecoder().decode(ModelSpec.self, from: read(output, "modelPath"))
        XCTAssertEqual(saved.script, program)
        XCTAssertNil(saved.sourceSTEP)
        XCTAssertNil(saved.inputAssets)
        let manifest = try object(read(output, "inputsManifestPath"))
        let stagedAsset = try XCTUnwrap((manifest["inputAssets"] as? [[String: Any]])?.first)
        let stagedSource = try XCTUnwrap(manifest["sourceSTEP"] as? [String: Any])
        XCTAssertEqual(stagedAsset["assetID"] as? String, "shared")
        XCTAssertEqual(stagedAsset["path"] as? String, stagedSource["path"] as? String, "Identical external bytes are staged once")
        XCTAssertEqual(try read(stagedAsset, "path"), source)
        XCTAssertEqual(stagedSource["programBinding"] as? String, "imported_model")
        XCTAssertEqual(try tools.resolveAssets(ids: ["shared"]), [currentAsset], "Historical IDs never overwrite the current registry")
        XCTAssertEqual((output["runtime"] as? [String: Any])?["cadquery"] as? String, "2.6")
        XCTAssertNotNil(output["partsLayoutPath"] as? String)
        XCTAssertNotNil(output["partsPath"] as? String)
        let outputText = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
        for forbidden in ["source must remain", "987654", "derived-preview", "derived-cache", "never stage", source.base64EncodedString()] {
            XCTAssertFalse(outputText.contains(forbidden))
        }
        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { !$0.hasSuffix("/") }
        XCTAssertFalse(allFiles.contains { $0.contains("brep") || $0.contains("preview") })
        let permissions = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(output["programPath"] as? String))[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    @MainActor
    func testRepeatedLookupReusesPathsAndRestoresModifiedFilesFromTheTaskSnapshot() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = CADInputAsset(id: "input", name: "original.obj", format: "obj", data: Data("original external mesh bytes".utf8))
        let first = ProjectRevision(model: model("First", assets: [asset]))
        let second = ProjectRevision(model: model("Second", assets: [asset]))
        let tools = try makeTools(root, versions: ProjectVersionContext(revisions: [first, second], selectedRevisionID: second.id))
        let original = try content(try await tools.handle(name: "lad_version", arguments: ["reference": "v1"]))
        let originalAsset = try XCTUnwrap((original["inputAssets"] as? [[String: Any]])?.first)
        let originalManifest = try read(original, "inputsManifestPath")
        for path in [try XCTUnwrap(original["programPath"] as? String), try XCTUnwrap(original["inputsManifestPath"] as? String), try XCTUnwrap(originalAsset["path"] as? String)] {
            try Data("agent modified this file".utf8).write(to: URL(fileURLWithPath: path))
        }
        let repeated = try content(try await tools.handle(name: "lad_version", arguments: ["reference": first.id.uuidString]))
        XCTAssertEqual(repeated["programPath"] as? String, original["programPath"] as? String)
        XCTAssertEqual(try read(repeated, "programPath"), Data(first.model.script.utf8))
        XCTAssertEqual(try read(repeated, "inputsManifestPath"), originalManifest)
        XCTAssertEqual(try read(originalAsset, "path"), asset.data)
        let other = try content(try await tools.handle(name: "lad_version", arguments: ["reference": "v2"]))
        let otherAsset = try XCTUnwrap((other["inputAssets"] as? [[String: Any]])?.first)
        XCTAssertEqual(otherAsset["path"] as? String, originalAsset["path"] as? String)
        let inputFolder = root.appendingPathComponent("context/versions/inputs")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inputFolder.path).count, 1)
    }

    @MainActor
    func testHistoryStagingCannotFollowWorkspaceDirectoryLinksAndBuildContextsDoNotFallBack() async throws {
        let root = try temporary(), outside = try temporary()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let historical = CADInputAsset(id: "old", name: "old.obj", format: "obj", data: Data("old".utf8))
        let currentAsset = CADInputAsset(id: "current", name: "current.obj", format: "obj", data: Data("current".utf8))
        let revision = ProjectRevision(model: model("Old", assets: [historical]))
        let tools = try makeTools(root, current: model("Current", assets: [currentAsset]),
                                  versions: ProjectVersionContext(revisions: [revision], selectedRevisionID: nil))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("context"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("context/versions"), withDestinationURL: outside)
        await assertFailure(tools, "lad_version", ["reference": "v1"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try Data("result=cq.Solid.makeBox(1,1,1)".utf8).write(to: root.appendingPathComponent("program.py"))
        await assertFailure(tools, "lad_build", ["programPath": "program.py", "versionID": revision.id.uuidString, "assetIDs": ["current"]])
        await assertFailure(tools, "lad_build", ["programPath": "program.py", "versionID": "v1"])
        XCTAssertThrowsError(try tools.resolveAssets(ids: ["old"]))
        XCTAssertEqual(try tools.resolveAssets(ids: ["current"]), [currentAsset])
        tools.cancel()
        do {
            _ = try await tools.handle(name: "lad_versions", arguments: [:])
            XCTFail("Cancelled history access must stop")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    @MainActor
    func testNativeHistoricalBuildUsesItsOwnOriginalSTEPAndConflictingAssetIDsWithoutChangingCurrent() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for exact historical native replay.")
        }
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineService()
        func source(_ length: Int) async throws -> Data {
            let shape = model("External fixture", script: "result = cq.Solid.makeBox(\(length),\(length),\(length))")
            let preview = try await engine.buildPreview(shape, python: EngineService.defaultPython, threads: 2)
            return try await engine.exportSTEP(preview, python: EngineService.defaultPython, threads: 2)
        }
        let oldBytes = try await source(2), currentBytes = try await source(5)
        let oldAsset = CADInputAsset(id: "shared", name: "old.step", format: "step", data: oldBytes)
        let currentAsset = CADInputAsset(id: "shared", name: "current.step", format: "step", data: currentBytes)
        let program = """
        result = cq.Assembly(name='Fixture')
        result.add(imported_model, name='Original', metadata={'lad_id':'original'})
        result.add(imported_assets['shared'], name='Reference', loc=cq.Location(cq.Vector(20,0,0)), metadata={'lad_id':'reference'})
        """
        let historical = ProjectRevision(model: model("Historical", script: program, source: oldBytes, assets: [oldAsset]))
        let current = model("Current", script: program, source: currentBytes, assets: [currentAsset])
        let tools = try CADAgentTools(directory: root, python: EngineService.defaultPython, threads: 2, current: current,
                                      currentPreview: nil, engine: engine,
                                      versions: ProjectVersionContext(revisions: [historical], selectedRevisionID: nil))
        let lookedUp = try content(try await tools.handle(name: "lad_version", arguments: ["reference": "v1"]))
        let programPath = try XCTUnwrap(lookedUp["programPath"] as? String)
        let oldBuild = try content(try await tools.handle(name: "lad_build", arguments: ["programPath": programPath, "versionID": historical.id.uuidString]))
        XCTAssertEqual(oldBuild["versionID"] as? String, historical.id.uuidString)
        XCTAssertEqual(try XCTUnwrap(oldBuild["volume"] as? Double), 16, accuracy: 1e-7)
        XCTAssertEqual(oldBuild["solids"] as? Int, 2)
        XCTAssertEqual(try tools.resolveAssets(ids: ["shared"]), [currentAsset])
        let currentBuild = try content(try await tools.handle(name: "lad_build", arguments: ["programPath": programPath]))
        XCTAssertNil(currentBuild["versionID"])
        XCTAssertEqual(try XCTUnwrap(currentBuild["volume"] as? Double), 250, accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(tools.validatedPreview(for: historical.model)?.volume), 16, accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(tools.validatedPreview(for: current)?.volume), 250, accuracy: 1e-7)
    }

    private func model(_ title: String, script: String = "result = cq.Solid.makeBox(1,1,1)", source: Data? = nil, assets: [CADInputAsset]? = nil) -> ModelSpec {
        ModelSpec(title: title, summary: "A saved design.", units: "mm", script: script,
                  sourceSTEP: source, sourceName: source == nil ? nil : "original.step", inputAssets: assets)
    }

    @MainActor
    private func makeTools(_ root: URL, current: ModelSpec? = nil, versions: ProjectVersionContext = .empty) throws -> CADAgentTools {
        try CADAgentTools(directory: root, python: "/missing/python", threads: 1, current: current,
                          currentPreview: nil, engine: EngineService(), versions: versions)
    }

    @MainActor
    private func assertFailure(_ tools: CADAgentTools, _ name: String, _ arguments: [String: Any], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await tools.handle(name: name, arguments: arguments)
            XCTFail("Invalid history access must fail", file: file, line: line)
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("Python runtime not found"), "Arguments must fail before starting CAD", file: file, line: line)
        }
    }

    private func content(_ result: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try object(Data(try XCTUnwrap(content.first?["text"] as? String).utf8))
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func read(_ object: [String: Any], _ key: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(object[key] as? String)))
    }
    private func step(_ marker: String) -> Data {
        Data("ISO-10303-21;\nHEADER; /* \(marker) */ ENDSEC;\nDATA; ENDSEC;\nEND-ISO-10303-21;".utf8)
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-version-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
