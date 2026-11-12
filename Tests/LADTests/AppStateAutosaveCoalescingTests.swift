import Foundation
import XCTest
@testable import LAD

final class AppStateAutosaveCoalescingTests: XCTestCase {
    @MainActor
    func testImmediateSaveConsumesPendingDraftAndDividerSave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest()
        try await waitForSave(state)
        let url = try XCTUnwrap(state.projectURL)

        let baseline = state.startedSaves
        var saves: Int { state.startedSaves - baseline }

        state.prompt = "Keep this pending draft"
        state.setPartsPaneFraction(0.61)
        state.showGrid = false
        try await waitForSave(state)
        XCTAssertEqual(saves, 1)
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.draftPrompt, state.prompt)
        XCTAssertEqual(saved.partsPaneFraction, 0.61)
        XCTAssertEqual(saved.showGrid, false)

        // Saving… is published after snapshot creation and before the actor
        // write, so no later event proves neither is requested by the old timer.
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(saves, 1, "The superseded draft timer must not save again")
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveStatus)

        // Consuming an old timer must not suppress a later, independent edit.
        state.prompt = "A later draft still autosaves"
        try await waitForSave(state)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(try ProjectStore.read(from: url).draftPrompt, state.prompt)
    }

    @MainActor
    func testImmediateSaveConsumesPendingAuditSaveWithoutLosingLatestEvent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProject()
        state.prompt = "Synthetic request for autosave bookkeeping"
        let baseline = state.startedSaves
        var saves: Int { state.startedSaves - baseline }

        state.submit()
        state.recordTaskEvent(ProjectActivityEvent(id: "command", category: "command", title: "Inspect design",
            status: "running", input: "inspect.py", output: "Partial output"))
        state.recordTaskEvent(ProjectActivityEvent(id: "command", category: "command", title: "Inspect design",
            status: "completed", output: "Complete output", durationSeconds: 0.25))
        state.prompt = "Keep this follow-up draft"
        state.showGrid = false
        // Cancel before yielding, preventing any Codex or CAD process launch.
        // Cancellation immediately saves the final audit outcome too.
        state.cancel()
        XCTAssertEqual(saves, 3)
        try await waitForSave(state)
        let url = try XCTUnwrap(state.projectURL)
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.taskAudits, state.taskAudits)
        XCTAssertEqual(saved.taskAudits?.first?.status, "canceled")
        XCTAssertEqual(saved.taskAudits?.first?.events.first?.status, "completed")
        XCTAssertEqual(saved.taskAudits?.first?.events.first?.input, "inspect.py")
        XCTAssertEqual(saved.taskAudits?.first?.events.first?.output, "Complete output")
        XCTAssertEqual(saved.draftPrompt, state.prompt)
        XCTAssertEqual(saved.showGrid, false)

        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(saves, 3, "The superseded audit timer must not save again")
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveStatus)
    }

    @MainActor
    private func waitForSave(_ state: AppState) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while state.hasUnsavedChanges || state.saveStatus != nil {
            if let conflict = state.saveConflict { throw conflict }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Autosave did not complete: \(state.saveStatus ?? "pending")")
                throw CocoaError(.fileWriteUnknown)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let state: AppState

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-autosave-coalescing-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        }

        func cleanUp() {
            state.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
