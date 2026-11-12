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
        // Cancellation requests a save of the final audit outcome too; with the
        // grid change, it waits for the submission's write to finish.
        state.cancel()
        XCTAssertEqual(saves, 1)
        try await waitForSave(state)
        XCTAssertEqual(saves, 2, "Requests made during a write share one follow-up save")
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
        XCTAssertEqual(saves, 2, "The superseded audit timer must not save again")
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveStatus)
    }

    @MainActor
    func testChangesDuringASlowSaveShareOneFollowUpWithTheFinalState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest()
        try await waitForSave(state)
        let url = try XCTUnwrap(state.projectURL)
        let baseline = state.startedSaves
        var saves: Int { state.startedSaves - baseline }
        let holder = try await CoordinatedHolder(url)
        defer { holder.release() }

        state.showGrid = false
        XCTAssertEqual(saves, 1)
        for index in 0..<40 {
            state.showGrid.toggle()
            state.projectionMode = index.isMultiple(of: 2) ? .isometric : .perspective
            state.displayMode = index.isMultiple(of: 3) ? .shaded : .edges
            try await Task.sleep(for: .milliseconds(2))
        }
        state.showGrid = true
        state.projectionMode = .isometric
        state.displayMode = .translucent
        state.prompt = "The final draft"
        // The draft's debounced save request also arrives during the write.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(saves, 1, "Changes during a write must not start or queue more writes")
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertEqual(state.saveStatus, "Saving…")

        await holder.releaseAndWait()
        try await waitForSave(state)
        XCTAssertEqual(saves, 2, "One follow-up save writes everything changed during the slow write")
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.showGrid, true)
        XCTAssertEqual(saved.projectionMode, .isometric)
        XCTAssertEqual(saved.displayMode, .translucent)
        XCTAssertEqual(saved.draftPrompt, "The final draft")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(saves, 2)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveStatus)
    }

    @MainActor
    func testClosingFlushDuringASlowSaveWritesTheLatestStateWithoutAFollowUp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest()
        try await waitForSave(state)
        let url = try XCTUnwrap(state.projectURL)
        let baseline = state.startedSaves
        var saves: Int { state.startedSaves - baseline }
        let holder = try await CoordinatedHolder(url)
        defer { holder.release() }

        state.showGrid = false
        state.projectionMode = .isometric
        state.prompt = "Draft written by the closing flush"
        let closing = Task { await state.prepareToQuit() }
        try await Task.sleep(for: .milliseconds(50))
        await holder.releaseAndWait()
        await closing.value
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveStatus)
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.showGrid, false)
        XCTAssertEqual(saved.projectionMode, .isometric)
        XCTAssertEqual(saved.draftPrompt, "Draft written by the closing flush")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(saves, 1, "The flush supersedes the in-progress autosave's follow-up")
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    /// Another coordinated writer holds the package, so LAD's next save
    /// blocks inside its writer until this is released.
    private final class CoordinatedHolder: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var released = false
        private var holding: Task<Void, Never>?

        init(_ url: URL) async throws {
            let held = XCTestExpectation(description: "External coordinator holds the file")
            let semaphore = semaphore
            holding = Task.detached {
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var failure: NSError?
                coordinator.coordinate(writingItemAt: url, options: [], error: &failure) { _ in
                    held.fulfill()
                    _ = semaphore.wait(timeout: .now() + 10)
                }
            }
            guard await XCTWaiter().fulfillment(of: [held], timeout: 2) == .completed else {
                release()
                throw CocoaError(.fileWriteUnknown)
            }
        }

        func release() {
            lock.lock(); defer { lock.unlock() }
            guard !released else { return }
            released = true
            semaphore.signal()
        }

        func releaseAndWait() async {
            release()
            await holding?.value
        }
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
