import Foundation
import XCTest
@testable import LAD

final class CodexFinalMetadataTests: XCTestCase {
    @MainActor
    func testGeometryReuseRejectsEmptyAndOversizedFinalTitles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for title in ["", String(repeating: "T", count: 161)] {
            var candidate = fixture.current
            candidate.title = title
            try await assertRejected(candidate, fixture: fixture, context: "Final title length \(title.count)")
        }
    }

    @MainActor
    func testGeometryReuseRejectsEmptyAndOversizedFinalSummaries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for summary in ["", String(repeating: "S", count: 6_001)] {
            var candidate = fixture.current
            candidate.summary = summary
            try await assertRejected(candidate, fixture: fixture, context: "Final summary length \(summary.count)")
        }
    }

    @MainActor
    func testFinalProgramWithNullCharacterIsRejectedBeforeReturningReady() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var candidate = fixture.current
        candidate.script += "\0"
        // This changes construction, so the same final validation must also
        // run when there is no matching preview to reuse.
        try await assertRejected(candidate, fixture: fixture, context: "Program with a null character")
    }

    @MainActor
    func testValidFinalMetadataReusesCurrentGeometryAndCanBeSaved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var candidate = fixture.current
        candidate.title = String(repeating: "T", count: 160)
        candidate.summary = String(repeating: "S", count: 6_000)
        let codex = try FakeCodex(responseJSON: readyResponse(candidate), delay: 0.01)
        defer { codex.remove() }
        let service = CodexService()

        let result = try await service.generate(prompt: "Update the design's title and description", current: fixture.current,
            history: [], executable: codex.executable.path, model: "", onProgress: { _ in }, currentPreview: fixture.preview)

        guard case .ready(let accepted) = result else { return XCTFail("Valid metadata must produce a ready design.") }
        XCTAssertEqual(accepted, candidate)
        let reused = try XCTUnwrap(service.validatedPreview(for: accepted), "Metadata edits must retain validated geometry reuse.")
        XCTAssertEqual(reused.brepPath, fixture.preview.brepPath)
        XCTAssertEqual(reused.stepPath, fixture.preview.stepPath)
        let revision = ProjectRevision(model: accepted)
        let project = LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id)
        let restored = try ProjectStore.decode(ProjectStore.encode(project))
        XCTAssertEqual(restored.revisions.first?.model, accepted, "An accepted final design must survive portable saving.")
        try codex.assertJobWasCleanedUp()
    }

    @MainActor
    private func assertRejected(_ candidate: ModelSpec, fixture: Fixture, context: String,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let codex = try FakeCodex(responseJSON: readyResponse(candidate), delay: 0.01)
        defer { codex.remove() }
        let service = CodexService()
        do {
            _ = try await service.generate(prompt: "Update the design metadata", current: fixture.current, history: [],
                executable: codex.executable.path, model: "", onProgress: { _ in }, currentPreview: fixture.preview)
            XCTFail("\(context) must be rejected before a ready design is returned.", file: file, line: line)
        } catch let error as CodexError {
            guard case .invalidModel = error else {
                return XCTFail("Expected invalid final design metadata, received \(error).", file: file, line: line)
            }
        }
        XCTAssertNil(service.validatedPreview(for: candidate), "Rejected final metadata must not expose a reusable candidate.",
                     file: file, line: line)
        try codex.assertJobWasCleanedUp(file: file, line: line)
    }

    private func readyResponse(_ candidate: ModelSpec) throws -> String {
        let object: [String: Any] = ["status": "ready", "message": "Updated the design metadata.", "assetIDs": [],
            "model": try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private struct Fixture {
        let directory: URL
        let current = ModelSpec(title: "Box", summary: "A single solid box.", units: "mm",
                                script: "result = cq.Workplane('XY').box(1, 1, 1)\n")
        let preview: PreviewMesh

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-final-metadata-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let native = directory.appendingPathComponent("model.brep")
            // Reuse needs a retained artifact path; these tests never invoke
            // a CAD build or read geometry from this synthetic session file.
            try Data("DBRep_DrawableShape\n".utf8).write(to: native)
            preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                volume: 1, area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                stepPath: directory.appendingPathComponent("model.step").path, brepPath: native.path)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
