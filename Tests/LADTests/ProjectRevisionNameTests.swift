import Foundation
import XCTest
@testable import LAD

final class ProjectRevisionNameTests: XCTestCase {
    @MainActor
    func testDefaultNamesUseHistoryPositionAndResetWithoutRenumberingOtherVersions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.newProjectWithSubmittedRequest()
        state.revisions = (0..<4).map { _ in ProjectRevision(model: .bracket) }
        let ids = state.revisions.map(\.id)
        XCTAssertEqual(ids.map { state.revisionName(for: $0) }, ["v1", "v2", "v3", "v4"])
        try state.renameRevision(id: ids[1], to: "  Initial design – 初版 🔧  ")
        XCTAssertEqual(state.revisions[1].name, "Initial design – 初版 🔧")
        XCTAssertEqual(ids.map { state.revisionName(for: $0) }, ["v1", "Initial design – 初版 🔧", "v3", "v4"])
        try state.renameRevision(id: ids[3], to: "Rounded edges / 2:1")
        try state.renameRevision(id: ids[1], to: "   ")
        XCTAssertNil(state.revisions[1].name)
        XCTAssertEqual(ids.map { state.revisionName(for: $0) }, ["v1", "v2", "v3", "Rounded edges / 2:1"])
        XCTAssertEqual(state.revisionName(for: UUID()), "")
        await state.prepareToQuit()
    }

    @MainActor
    func testRenamingUnselectedVersionPreservesActiveGeometryHistoryAndTitleThenAutosaves() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.newProjectWithSubmittedRequest("Build an enclosure")
        let preview = preview()
        var firstModel = ModelSpec.bracket
        firstModel.title = "First enclosure"
        var latestModel = ModelSpec.bracket
        latestModel.title = "Latest enclosure"
        let user = try XCTUnwrap(state.messages.first)
        let response = ChatMessage(role: "assistant", content: "The enclosure is ready.", phase: "final_answer")
        let first = ProjectRevision(model: firstModel, date: Date(timeIntervalSinceReferenceDate: 1), preview: preview)
        let latest = ProjectRevision(model: latestModel, date: Date(timeIntervalSinceReferenceDate: 2), preview: preview,
                                     userMessageID: user.id, responseMessageID: response.id)
        state.messages = [user, response]
        state.revisions = [first, latest]
        state.selectedRevisionID = latest.id
        XCTAssertTrue(state.loadStoredRevision())
        XCTAssertTrue(state.canExport)
        let title = state.title
        let activity = state.activity
        let geometryPath = state.mesh?.stepPath
        let documentID = state.projectDocumentID
        try state.renameRevision(id: first.id, to: "Initial design")
        XCTAssertEqual(state.selectedRevisionID, latest.id)
        XCTAssertEqual(state.current, latestModel)
        XCTAssertEqual(state.mesh?.stepPath, geometryPath)
        XCTAssertEqual(state.mesh?.vertices, preview.vertices)
        XCTAssertTrue(state.canExport, "Renaming must not invalidate the prepared native geometry.")
        XCTAssertFalse(state.isWorking, "Renaming must not begin a CAD rebuild.")
        XCTAssertEqual(state.activity, activity)
        XCTAssertEqual(state.title, title)
        XCTAssertNil(state.projectName)
        XCTAssertEqual(state.projectDocumentID, documentID)
        XCTAssertEqual(state.messages, [user, response])
        XCTAssertEqual(state.revisions.map(\.id), [first.id, latest.id])
        XCTAssertEqual(state.revisions.map(\.model), [firstModel, latestModel])
        XCTAssertEqual(state.revisions.map(\.date), [first.date, latest.date])
        XCTAssertEqual(state.revisions[1].userMessageID, user.id)
        XCTAssertEqual(state.revisions[1].responseMessageID, response.id)
        XCTAssertNil(state.revisions[1].name)
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.revisions.map(\.name), ["Initial design", nil])
        XCTAssertEqual(saved.selectedRevisionID, latest.id)
        XCTAssertEqual(saved.revisions.map(\.model), [firstModel, latestModel])
        XCTAssertEqual(saved.messages, [user, response])
    }

    func testZIPRoundtripPreservesNamesAndOmitsDefaultLabels() throws {
        let project = fixture()
        let bytes = try ProjectStore.encode(project)
        XCTAssertEqual(bytes.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        let restored = try ProjectStore.decode(bytes)
        XCTAssertEqual(restored.revisions.map(\.name), [nil, "Initial design", "Rounded edges – 半径 2 mm"])
        XCTAssertEqual(restored.revisions.map(\.id), project.revisions.map(\.id))
        XCTAssertEqual(restored.selectedRevisionID, project.selectedRevisionID)
        XCTAssertEqual(restored.projectName, project.projectName)
        XCTAssertEqual(restored.revisions.map(\.model), project.revisions.map(\.model))
        let manifest = try manifest(bytes)
        XCTAssertEqual(manifest["formatVersion"] as? Int, 4)
        let revisions = try XCTUnwrap(manifest["revisions"] as? [[String: Any]])
        XCTAssertNil(revisions[0]["name"])
        XCTAssertEqual(revisions[1]["name"] as? String, "Initial design")
        XCTAssertEqual(revisions[2]["name"] as? String, "Rounded edges – 半径 2 mm")
        XCTAssertTrue(revisions.allSatisfy { $0["preview"] == nil && $0["stepData"] == nil })
    }

    @MainActor
    func testInvalidNameOrMissingVersionLeavesExistingNamesAndSelectionUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.newProjectWithSubmittedRequest()
        let first = ProjectRevision(model: .bracket, name: "Initial design")
        let last = ProjectRevision(model: .bracket)
        state.revisions = [first, last]
        state.selectedRevisionID = last.id
        for invalid in ["Line\nbreak", "Line\rbreak", "Tab\tname", "Null\0name", "Separator\u{2028}name", String(repeating: "a", count: 513), String(repeating: "🔧", count: 129)] {
            XCTAssertThrowsError(try state.renameRevision(id: first.id, to: invalid), invalid)
            XCTAssertEqual(state.revisions[0].name, "Initial design")
            XCTAssertEqual(state.selectedRevisionID, last.id)
        }
        XCTAssertThrowsError(try state.renameRevision(id: UUID(), to: "Missing"))
        XCTAssertEqual(state.revisions.map(\.name), ["Initial design", nil])
        try state.renameRevision(id: first.id, to: String(repeating: "🔧", count: 128))
        XCTAssertEqual(state.revisions[0].name?.utf8.count, ProjectRevisionNaming.maximumNameBytes)
        await state.prepareToQuit()
    }

    func testArchiveRejectsInvalidNamesOnBothSaveAndLoad() throws {
        let project = fixture()
        for invalid in ["", "   ", " name", "name ", "Line\nbreak", "Null\0name", String(repeating: "a", count: 513)] {
            var changed = project
            changed.revisions[0].name = invalid
            XCTAssertThrowsError(try ProjectStore.encode(changed), invalid)
            var json = try manifest(ProjectStore.encode(project))
            var revisions = try XCTUnwrap(json["revisions"] as? [[String: Any]])
            revisions[0]["name"] = invalid
            json["revisions"] = revisions
            let bytes = try ProjectZIP.encode(JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try ProjectStore.decode(bytes), invalid)
        }
    }

    func testSaveNewKeepsLatestCustomVersionNameWithoutChangingOriginalHistory() throws {
        var original = fixture()
        original.selectedRevisionID = original.revisions[0].id
        let latest = try XCTUnwrap(original.revisions.last)
        let copy = try SaveNewProject.snapshot(from: original)
        XCTAssertEqual(copy.revisions.map(\.id), [latest.id])
        XCTAssertEqual(copy.revisions.map(\.name), [latest.name])
        XCTAssertEqual(copy.selectedRevisionID, latest.id)
        XCTAssertNotEqual(copy.projectID, original.projectID)
        let restored = try ProjectStore.decode(ProjectStore.encode(copy))
        XCTAssertEqual(restored.revisions[0].name, "Rounded edges – 半径 2 mm")
        XCTAssertEqual(restored.revisions[0].model, latest.model)
        XCTAssertEqual(original.revisions.count, 3)
        XCTAssertEqual(original.selectedRevisionID, original.revisions[0].id)
        XCTAssertEqual(original.revisions.map(\.name), [nil, "Initial design", "Rounded edges – 半径 2 mm"])
    }

    private func fixture() -> LADProject {
        let revisions = [ProjectRevision(model: .bracket),
                         ProjectRevision(model: .bracket, name: "Initial design"),
                         ProjectRevision(model: .bracket, name: "Rounded edges – 半径 2 mm")]
        return LADProject(messages: [], revisions: revisions, selectedRevisionID: revisions[1].id,
                          projectID: UUID(), projectName: "Workshop enclosure")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-version-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func preview() -> PreviewMesh {
        PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2]], edges: [],
                    bounds: [0, 0, 0, 1, 1, 1], volume: 1, area: 3, solids: 1, faces: 1,
                    buildSeconds: 0.01, threads: 1, stepPath: "/private/tmp/revision-name-preview.step",
                    brepPath: "/private/tmp/revision-name-preview.brep")
    }

    private func manifest(_ bytes: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
    }
}
