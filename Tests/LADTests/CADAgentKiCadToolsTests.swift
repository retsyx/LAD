import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class CADAgentKiCadToolsTests: XCTestCase {
    @MainActor
    func testExplicitConversionReturnsWorkspaceReferenceAndCoverageWithoutBuildingOrImporting() async throws {
        let workspace = try temporaryDirectory(), sources = try temporaryDirectory(), binaries = try temporaryDirectory()
        let models = sources.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: false)
        try Data("ISO-10303-21;\nEND-ISO-10303-21;\n".utf8).write(to: models.appendingPathComponent("part.step"))
        let original = Data("""
        (kicad_pcb (version 20260206) (general (thickness 1.6))
          (footprint "Reference" (property "Reference" "U1") (model "${KIPRJMOD}/models/part.step")))
        """.utf8)
        let board = sources.appendingPathComponent("source board.kicad_pcb")
        try original.write(to: board)
        let project = board.deletingPathExtension().appendingPathExtension("kicad_pro")
        let originalProject = Data("{\"text_variables\":{\"REV\":\"A\"}}".utf8)
        try originalProject.write(to: project)
        let service = KiCadService(executable: try executable(in: binaries), recoverMissingModels: false)
        // Missing CAD Python proves that converting a reference is independent
        // of constructing, validating or importing it as the current design.
        let tools = try CADAgentTools(directory: workspace, python: "/missing/python", threads: 1,
                                      current: nil, currentPreview: nil, engine: EngineService(), kicad: service)
        let response = try content(try await tools.handle(name: "lad_convert_kicad", arguments: [
            "boardPath": board.path, "path": "references/pcb.step"
        ]))
        let output = try XCTUnwrap(response["path"] as? String)
        let canonicalWorkspace = try EngineArtifact.canonicalDirectory(workspace)
        let expectedOutput = canonicalWorkspace.appendingPathComponent("references/pcb.step").path
        XCTAssertEqual(output, expectedOutput, "Output \(output) must be the requested file inside \(canonicalWorkspace.path)")
        XCTAssertTrue(output.hasPrefix(canonicalWorkspace.path + "/"), "Output \(output) escaped \(canonicalWorkspace.path)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), step)
        XCTAssertEqual(response["format"] as? String, "step")
        XCTAssertEqual(response["sourceBoardPath"] as? String, board.resolvingSymlinksInPath().path)
        XCTAssertEqual(response["sourceSHA256"] as? String, digest(original))
        XCTAssertEqual(response["sha256"] as? String, digest(step))
        XCTAssertEqual(response["byteCount"] as? Int, step.count)
        XCTAssertEqual(response["boardThickness"] as? Double, 1.6)
        XCTAssertEqual(response["modeledComponents"] as? Int, 1)
        XCTAssertEqual(response["referencedComponents"] as? Int, 1)
        XCTAssertEqual(response["coverageComplete"] as? Bool, true)
        XCTAssertEqual(response["missingModels"] as? [String], [])
        XCTAssertNil(response["artifactID"])
        XCTAssertNil(response["assetID"])
        XCTAssertEqual(try tools.resolveAssets(ids: []), [])
        XCTAssertNil(tools.validatedPreview(for: .bracket))
        do {
            _ = try await tools.handle(name: "lad_inspect", arguments: [:])
            XCTFail("A converter must not create an implicit current design")
        } catch { XCTAssertTrue(error.localizedDescription.contains("There is no current design")) }
        XCTAssertEqual(try Data(contentsOf: board), original)
        XCTAssertEqual(try Data(contentsOf: project), originalProject)
        XCTAssertEqual(try Data(contentsOf: models.appendingPathComponent("part.step")), Data("ISO-10303-21;\nEND-ISO-10303-21;\n".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sources.path).sorted(), ["models", "source board.kicad_pcb", "source board.kicad_pro"])
    }

    @MainActor
    func testWorkspaceSourceConversionDisclosesMissingReferenceGeometry() async throws {
        let workspace = try temporaryDirectory(), binaries = try temporaryDirectory()
        let board = workspace.appendingPathComponent("board.kicad_pcb")
        try Data("""
        (kicad_pcb (version 20260206) (general (thickness 1.2))
          (footprint "Missing" (property "Reference" "J1") (model "${KIPRJMOD}/missing.step")))
        """.utf8).write(to: board)
        let tools = try CADAgentTools(directory: workspace, python: "/missing/python", threads: 1,
                                      current: nil, currentPreview: nil, engine: EngineService(),
                                      kicad: KiCadService(executable: executable(in: binaries), recoverMissingModels: false))
        let response = try content(try await tools.handle(name: "lad_convert_kicad", arguments: ["boardPath": "board.kicad_pcb"]))
        XCTAssertEqual(response["coverageComplete"] as? Bool, false)
        XCTAssertEqual(response["modeledComponents"] as? Int, 0)
        XCTAssertEqual(response["missingModels"] as? [String], ["J1: ${KIPRJMOD}/missing.step"])
        XCTAssertTrue(try XCTUnwrap(response["diagnostics"] as? String).contains("omitted from STEP"))
        XCTAssertTrue(try XCTUnwrap(response["nextStep"] as? String).contains("explicitly call lad_import"))
        XCTAssertNil(response["assetID"])
    }

    @MainActor
    func testConverterWritesStayConfinedAndWorkspaceSourceLinksAreRejected() async throws {
        let workspace = try temporaryDirectory(), sources = try temporaryDirectory(), binaries = try temporaryDirectory()
        let board = sources.appendingPathComponent("board.kicad_pcb")
        let original = Data("(kicad_pcb (version 20260206) (general (thickness 1.6)))".utf8)
        try original.write(to: board)
        let tools = try CADAgentTools(directory: workspace, python: "/missing/python", threads: 1,
                                      current: nil, currentPreview: nil, engine: EngineService(),
                                      kicad: KiCadService(executable: executable(in: binaries), recoverMissingModels: false))
        let outside = sources.appendingPathComponent("outside.step")
        do {
            _ = try await tools.handle(name: "lad_convert_kicad", arguments: ["boardPath": board.path, "path": outside.path])
            XCTFail("Conversion output must stay in the task workspace")
        } catch { XCTAssertTrue(error.localizedDescription.contains("task workspace")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("linked.kicad_pcb"), withDestinationURL: board)
        do {
            _ = try await tools.handle(name: "lad_convert_kicad", arguments: ["boardPath": "linked.kicad_pcb"])
            XCTFail("Workspace input references must not follow links")
        } catch { XCTAssertTrue(error.localizedDescription.contains("symbolic link")) }
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("linked"), withDestinationURL: sources)
        do {
            _ = try await tools.handle(name: "lad_convert_kicad", arguments: ["boardPath": board.path, "path": "linked/outside.step"])
            XCTFail("Conversion output must not follow a replaced parent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("symbolic links")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try Data(contentsOf: board), original)
    }

    @MainActor
    func testTaskCancellationStopsTheKiCadConverter() async throws {
        let workspace = try temporaryDirectory(), sources = try temporaryDirectory(), binaries = try temporaryDirectory()
        let board = sources.appendingPathComponent("board.kicad_pcb")
        try Data("(kicad_pcb (version 20260206) (general (thickness 1.6)))".utf8).write(to: board)
        let tools = try CADAgentTools(directory: workspace, python: "/missing/python", threads: 1,
                                      current: nil, currentPreview: nil, engine: EngineService(),
                                      kicad: KiCadService(executable: executable(in: binaries, body: "while :; do /bin/sleep 1; done"), recoverMissingModels: false))
        let task = Task { try await tools.handle(name: "lad_convert_kicad", arguments: ["boardPath": board.path]) }
        try await Task.sleep(for: .milliseconds(150))
        let start = Date()
        tools.cancel()
        do { _ = try await task.value; XCTFail("A stopped task must not finish a conversion") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty)
    }

    @MainActor
    func testInstalledKiCadToolConversionExplicitImportAndPortableReferenceReplay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LAD_RUN_ENGINE_TESTS"] == "1", let path = environment["LAD_KICAD_TEST_BOARD"] else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 and LAD_KICAD_TEST_BOARD to verify explicit KiCad conversion, import and native replay.")
        }
        let workspace = try temporaryDirectory()
        let canonicalWorkspace = try EngineArtifact.canonicalDirectory(workspace)
        let source = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: source)
        let cache = environment["LAD_KICAD_MODEL_CACHE"].map { URL(fileURLWithPath: $0) }
        let engine = EngineService()
        let tools = try CADAgentTools(directory: workspace, python: EngineService.defaultPython, threads: 4,
                                      current: nil, currentPreview: nil, engine: engine,
                                      kicad: KiCadService(modelCache: cache))
        let converted = try content(try await tools.handle(name: "lad_convert_kicad", arguments: ["boardPath": source.path]))
        let stepPath = try XCTUnwrap(converted["path"] as? String)
        XCTAssertTrue(stepPath.hasPrefix(canonicalWorkspace.path + "/"), "Converted STEP \(stepPath) must remain inside \(canonicalWorkspace.path)")
        XCTAssertNil(converted["artifactID"])
        XCTAssertNil(converted["assetID"])
        XCTAssertEqual(converted["sourceSHA256"] as? String, digest(original))
        let missing = try XCTUnwrap(converted["missingModels"] as? [String])
        XCTAssertEqual(converted["coverageComplete"] as? Bool, missing.isEmpty)
        XCTAssertEqual(try XCTUnwrap(converted["referencedComponents"] as? Int),
                       try XCTUnwrap(converted["modeledComponents"] as? Int) + missing.count)
        let nativeBytes = try Data(contentsOf: URL(fileURLWithPath: stepPath))
        let expectedAssetID = "asset-" + digest(nativeBytes)
        XCTAssertThrowsError(try tools.resolveAssets(ids: [expectedAssetID]), "Conversion must not register a recipe input automatically")
        do {
            _ = try await tools.handle(name: "lad_inspect", arguments: [:])
            XCTFail("Conversion must not replace an empty current design")
        } catch { XCTAssertTrue(error.localizedDescription.contains("There is no current design")) }

        // The agent explicitly imports the user-supplied PCB reference only
        // after choosing conversion. This is not authored project geometry.
        let imported = try content(try await tools.handle(name: "lad_import", arguments: ["path": stepPath, "name": "Supplied PCB reference"]))
        let assetID = try XCTUnwrap(imported["assetID"] as? String)
        XCTAssertEqual(assetID, expectedAssetID)
        let importedVolume = try XCTUnwrap(imported["volume"] as? Double)
        XCTAssertGreaterThan(importedVolume, 0)
        XCTAssertGreaterThan(try XCTUnwrap(imported["solids"] as? Int), 0)
        let assets = try tools.resolveAssets(ids: [assetID])
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?.data, nativeBytes)
        // Replay must use the retained input bytes rather than the temporary
        // converter path, just as it will after a saved design is reopened.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: stepPath))
        let literal = String(decoding: try JSONEncoder().encode(assetID), as: UTF8.self)
        let program = """
        reference = imported_assets[\(literal)]
        result = cq.Assembly(reference, name='PCB reference', metadata={'lad_id':'pcb-reference'})
        """
        let programURL = canonicalWorkspace.appendingPathComponent("pcb-reference.py")
        try Data(program.utf8).write(to: programURL)
        let replayed = try content(try await tools.handle(name: "lad_build", arguments: [
            "programPath": programURL.path, "assetIDs": [assetID], "title": "Supplied PCB reference"
        ]))
        let replayID = try XCTUnwrap(replayed["artifactID"] as? String)
        XCTAssertEqual(try XCTUnwrap(replayed["volume"] as? Double), importedVolume, accuracy: max(1e-6, importedVolume * 1e-9))
        let validation = try content(try await tools.handle(name: "lad_validate", arguments: ["artifactID": replayID]))
        XCTAssertEqual(validation["valid"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(validation["volume"] as? Double), 0)
        XCTAssertEqual(try Data(contentsOf: source), original, "The complete tool workflow must leave the original board unchanged")
    }

    private var step: Data { Data("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;\n".utf8) }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-agent-kicad-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func executable(in directory: URL, body: String = "") throws -> URL {
        let executable = directory.appendingPathComponent("fake kicad-cli")
        let script = """
        #!/bin/sh
        output=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '--output' ]; then shift; output="$1"; fi
            shift
        done
        \(body)
        printf 'ISO-10303-21;\\nHEADER;\\nENDSEC;\\nDATA;\\nENDSEC;\\nEND-ISO-10303-21;\\n' > "$output"
        printf 'Reference PCB conversion completed\\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
    private func content(_ response: [String: Any]) throws -> [String: Any] {
        let blocks = try XCTUnwrap(response["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
