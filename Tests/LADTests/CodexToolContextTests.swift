import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class CodexToolContextTests: XCTestCase {
    private let input = Data("# FULL_SAVED_INPUT_MUST_STAY_LOCAL\nv 0 0 0\nv 2 0 0\nv 0 2 0\nf 1 2 3\n".utf8)

    func testGeometryBytesAreExcludedFromCurrentProgramJSONAndRemainInReferencedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var model = program(inputs: [asset("external-input")])
        let originalSTEP = Data("ISO-10303-21;\nORIGINAL_STEP_BYTES_MUST_STAY_LOCAL\nEND-ISO-10303-21;\n".utf8)
        model.sourceSTEP = originalSTEP
        model.sourceName = "native.step"
        let context = try CodexFileContext.prepare(current: model, history: [], attachments: [], directory: fixture.directory)
        let modelURL = URL(fileURLWithPath: try XCTUnwrap(context.currentModelPath))
        let stagedData = try Data(contentsOf: modelURL)
        let stagedModel = try JSONDecoder().decode(ModelSpec.self, from: stagedData)
        XCTAssertEqual(stagedModel.script, model.script, "The complete program is available only through its local reference.")
        XCTAssertNil(stagedModel.inputAssets)
        XCTAssertNil(stagedModel.sourceSTEP)
        let stagedText = String(decoding: stagedData, as: UTF8.self)
        for marker in ["FULL_SAVED_INPUT_MUST_STAY_LOCAL", input.base64EncodedString(),
                       "ORIGINAL_STEP_BYTES_MUST_STAY_LOCAL", originalSTEP.base64EncodedString()] {
            XCTAssertFalse(stagedText.contains(marker))
        }

        let references = try manifest(context)
        XCTAssertEqual(references.count, 1)
        let reference = try XCTUnwrap(references.first)
        XCTAssertEqual(reference["id"] as? String, "external-input")
        XCTAssertEqual(reference["name"] as? String, "external.obj")
        XCTAssertEqual(reference["format"] as? String, "obj")
        XCTAssertEqual(reference["sha256"] as? String, digest(input))
        XCTAssertEqual(try byteCount(reference), input.count)
        let inputURL = URL(fileURLWithPath: try XCTUnwrap(reference["readPath"] as? String))
        XCTAssertEqual(try Data(contentsOf: inputURL), input)
        XCTAssertEqual(inputURL.deletingLastPathComponent().standardizedFileURL,
                       fixture.directory.appendingPathComponent("context/geometry-inputs").standardizedFileURL)
        XCTAssertEqual(try permissions(inputURL), 0o600)
        XCTAssertEqual(try permissions(inputURL.deletingLastPathComponent()), 0o700)
        let manifestText = try String(contentsOfFile: XCTUnwrap(context.inputAssetsPath), encoding: .utf8)
        XCTAssertFalse(manifestText.contains("FULL_SAVED_INPUT_MUST_STAY_LOCAL"))
        XCTAssertFalse(manifestText.contains(input.base64EncodedString()))
    }

    @MainActor
    func testInitialCodexRequestIncludesOnlyManifestReferenceAndNoSavedGeometryOrProgramContents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let cli = try FakeCodex(responseJSON: "{\"status\":\"unsupported\",\"message\":\"Context inspection complete\",\"model\":null,\"assetIDs\":[]}", delay: 0.01)
        defer { cli.remove() }
        let model = program(inputs: [asset("external-input")])
        let result = try await CodexService().generate(prompt: "Refine the saved imported shape", current: model, history: [],
            executable: cli.executable.path, model: "", onProgress: { _ in })
        XCTAssertEqual(result, .response("Context inspection complete"))
        let request = try String(contentsOf: cli.inputURL, encoding: .utf8)
        XCTAssertTrue(request.contains("GEOMETRY INPUT MANIFEST FILE:"))
        XCTAssertTrue(request.contains("geometry-inputs.json"))
        XCTAssertTrue(request.contains("CURRENT MODEL FILE:"))
        XCTAssertFalse(request.contains("FULL_SAVED_INPUT_MUST_STAY_LOCAL"))
        XCTAssertFalse(request.contains(input.base64EncodedString()))
        XCTAssertFalse(request.contains("PRIVATE_PROGRAM_CONTENT_MUST_STAY_LOCAL"))
        XCTAssertFalse(request.contains(model.script))
    }

    func testIdenticalSavedBytesWithDifferentAssetIdentitiesAreStagedOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let changed = input + Data("# changed external shape\n".utf8)
        let assets = [asset("first"), asset("second"), CADInputAsset(id: "third", name: "changed.obj", format: "obj", data: changed)]
        let context = try CodexFileContext.prepare(current: program(inputs: assets), history: [], attachments: [], directory: fixture.directory)
        let references = try manifest(context)
        XCTAssertEqual(references.compactMap { $0["id"] as? String }, ["first", "second", "third"])
        let paths = try references.map { try XCTUnwrap($0["readPath"] as? String) }
        XCTAssertEqual(paths[0], paths[1])
        XCTAssertNotEqual(paths[0], paths[2])
        XCTAssertEqual(Set(paths).count, 2)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory.appendingPathComponent("context/geometry-inputs"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[0])), input)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[2])), changed)
    }

    func testUnsafeInputMetadataIsRejectedBeforeGeometryFilesCanEscapeTheWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let escapedName = "escaped-\(UUID()).obj"
        let escapedURL = fixture.directory.appendingPathComponent(escapedName)
        let invalid = [
            CADInputAsset(id: "external", name: "../" + escapedName, format: "obj", data: input),
            CADInputAsset(id: "external", name: "external.obj", format: "../obj", data: input),
            CADInputAsset(id: "external\0input", name: "external.obj", format: "obj", data: input),
            CADInputAsset(id: "external", name: "external\n.obj", format: "obj", data: input),
            CADInputAsset(id: "external", name: "frame.png", format: "png", data: input)
        ]
        for (index, asset) in invalid.enumerated() {
            let workspace = fixture.directory.appendingPathComponent("case-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            XCTAssertThrowsError(try CodexFileContext.prepare(current: program(inputs: [asset]), history: [], attachments: [], directory: workspace))
            XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("context/geometry-inputs").path))
        }
    }

    func testArchivedImportedInputsCanBeReferencedAfterTheOriginalTaskWorkspaceDisappears() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanUp(); second.cleanUp() }
        let model = program(inputs: [asset("external-input")])
        let context = try CodexFileContext.prepare(current: model, history: [], attachments: [], directory: first.directory)
        let oldPath = try XCTUnwrap(try manifest(context).first?["readPath"] as? String)
        let revision = ProjectRevision(model: model)
        let portable = try ProjectStore.encode(LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id))
        first.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))

        let reopened = try ProjectStore.decode(portable)
        let restoredModel = try XCTUnwrap(reopened.revisions.first?.model)
        let newContext = try CodexFileContext.prepare(current: restoredModel, history: reopened.messages, attachments: [], directory: second.directory)
        let reference = try XCTUnwrap(try manifest(newContext).first)
        let newPath = try XCTUnwrap(reference["readPath"] as? String)
        XCTAssertNotEqual(newPath, oldPath)
        XCTAssertEqual(reference["id"] as? String, "external-input")
        XCTAssertEqual(reference["sha256"] as? String, digest(input))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: newPath)), input)
        XCTAssertEqual(restoredModel.inputAssets, model.inputAssets)
    }

    private func program(inputs: [CADInputAsset]) -> ModelSpec {
        ModelSpec(title: "External geometry", summary: "A design based on portable imported inputs.", units: "mm",
                  script: "# PRIVATE_PROGRAM_CONTENT_MUST_STAY_LOCAL\nresult = imported_assets['external-input']\n", inputAssets: inputs)
    }

    private func asset(_ id: String) -> CADInputAsset { CADInputAsset(id: id, name: "external.obj", format: "obj", data: input) }

    private func manifest(_ context: CodexFileContext) throws -> [[String: Any]] {
        let path = try XCTUnwrap(context.inputAssetsPath)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
    }

    private func byteCount(_ record: [String: Any]) throws -> Int {
        if let count = record["byteCount"] as? Int { return count }
        return try XCTUnwrap((record["byteCount"] as? String).flatMap(Int.init))
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private struct Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-tool-context-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

}
