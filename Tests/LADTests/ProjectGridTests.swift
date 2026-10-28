import Foundation
import XCTest
@testable import LAD

final class ProjectGridTests: XCTestCase {
    @MainActor
    func testInitialGridChangesDoNotSaveAPlaceholderOrLeakBetweenStates() {
        let first = AppState(), second = AppState()
        XCTAssertTrue(first.showGrid)
        XCTAssertTrue(second.showGrid)
        first.showGrid = false
        XCTAssertFalse(first.showGrid)
        XCTAssertTrue(second.showGrid)
        XCTAssertNil(first.projectURL)
        XCTAssertNil(first.saveStatus)
        XCTAssertNil(second.projectURL)
        XCTAssertNil(second.saveStatus)
    }

    func testGridVisibilityRoundtripsWithCompleteZIPProject() throws {
        for visible in [false, true] {
            var original = project()
            original.showGrid = visible
            let encoded = try ProjectStore.encode(original)
            XCTAssertEqual(encoded.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(encoded)) as? [String: Any])
            XCTAssertEqual(manifest["showGrid"] as? Bool, visible)
            let restored = try ProjectStore.decode(encoded)
            XCTAssertEqual(restored.showGrid, visible)
            XCTAssertEqual(restored.projectID, original.projectID)
            XCTAssertEqual(restored.projectName, original.projectName)
            XCTAssertEqual(restored.codexSettings, original.codexSettings)
            XCTAssertEqual(restored.messages, original.messages)
            XCTAssertEqual(restored.selectedRevisionID, original.selectedRevisionID)
            XCTAssertEqual(restored.revisions.map(\.id), original.revisions.map(\.id))
            XCTAssertEqual(restored.revisions.map(\.model), original.revisions.map(\.model))
        }
    }

    func testMissingGridPreferenceRemainsUnsetForOlderProjects() throws {
        let original = project()
        let encoded = try ProjectStore.encode(original)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(encoded)) as? [String: Any])
        XCTAssertNil(manifest["showGrid"])
        var other = project()
        other.showGrid = false
        XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(other)).showGrid, false)
        XCTAssertNil(try ProjectStore.decode(encoded).showGrid,
                     "A file without a preference must not inherit another project's grid choice")
    }

    func testAutosaveRestoreAndCopyKeepEachProjectsGridChoice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-grid-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("LAD", isDirectory: true))
        var first = project(), second = project()
        first.projectName = "First grid project"
        second.projectName = "Second grid project"
        first.showGrid = false
        second.showGrid = true
        let firstID = try XCTUnwrap(first.projectID), secondID = try XCTUnwrap(second.projectID)
        let firstURL = try await store.write(project: first, projectID: firstID, title: "First", sequence: 1)
        let secondURL = try await store.write(project: second, projectID: secondID, title: "Second", sequence: 1)
        let restoredFirst = try await store.restoreRecent(preferredURL: firstURL, projectID: firstID)
        let restoredSecond = try await store.restoreRecent(preferredURL: secondURL, projectID: secondID)
        XCTAssertEqual(restoredFirst?.project.showGrid, false)
        XCTAssertEqual(restoredSecond?.project.showGrid, true)
        let copy = directory.appendingPathComponent("Copy.lad")
        try await store.writeCopy(first, to: copy)
        XCTAssertEqual(try ProjectStore.read(from: copy).showGrid, false)
        XCTAssertEqual(try ProjectStore.read(from: secondURL).showGrid, true)
    }

    func testNonBooleanGridPreferencesAreRejected() throws {
        let encoded = try ProjectStore.encode(project())
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(encoded)) as? [String: Any])
        let invalidValues: [Any] = ["false", 1, [true]]
        for invalid in invalidValues {
            var changed = manifest
            changed["showGrid"] = invalid
            let malformed = try ProjectZIP.encode(JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try ProjectStore.decode(malformed))
        }
    }

    private func project() -> LADProject {
        let first = ProjectRevision(model: .bracket)
        var wider = ModelSpec.bracket
        wider.title = "Wider bracket"
        wider.script = wider.script.replacingOccurrences(of: "box(80, 50, 6", with: "box(100, 50, 6")
        let last = ProjectRevision(model: wider)
        return LADProject(messages: [ChatMessage(role: "user", content: "Create a bracket"),
                                     ChatMessage(role: "assistant", content: "Model ready.", phase: "final_answer")],
                          revisions: [first, last], selectedRevisionID: first.id, projectID: UUID(),
                          codexSettings: CodexProjectSettings(model: "design-model", reasoningEffort: "ultra"),
                          projectName: "Workshop bracket")
    }
}
