import Foundation
import XCTest
@testable import LAD

final class AppStateActivityTests: XCTestCase {
    @MainActor
    func testSubmissionCapturesSelectionAndUpsertsCompleteEventsWithoutChangingTheirStart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.selectCodexModel("audit-model")
        state.selectCodexReasoningEffort("high")
        state.prompt = "Create a synthetic design"
        state.submit()
        let task = try XCTUnwrap(state.taskAudits.first)
        XCTAssertEqual(task.userMessageID, state.messages.last?.id)
        XCTAssertEqual(task.model, "audit-model")
        XCTAssertEqual(task.reasoningEffort, "high")
        XCTAssertEqual(task.status, "running")

        let began = Date(timeIntervalSinceReferenceDate: 100)
        let file = ProjectActivityFile(name: "candidate.py", path: "/workspace/candidate.py", data: Data("result = cq.Workplane('XY').box(1,2,3)".utf8))
        state.recordTaskEvent(ProjectActivityEvent(id: "command-1", date: began, category: "command", title: "Build candidate",
                                                  status: "running", input: "python candidate.py", output: "partial", files: [file]))
        let fullOutput = String(repeating: "complete output line\n", count: 1_000)
        state.recordTaskEvent(ProjectActivityEvent(id: "command-1", date: began.addingTimeInterval(2), category: "command", title: "Build candidate",
                                                  status: "completed", output: fullOutput, durationSeconds: 1.75))
        let updated = try XCTUnwrap(state.taskAudits.first?.events.first)
        XCTAssertEqual(state.taskAudits.first?.events.count, 1)
        XCTAssertEqual(updated.date, began)
        XCTAssertEqual(updated.input, "python candidate.py")
        XCTAssertEqual(updated.output, fullOutput)
        XCTAssertEqual(updated.files, [file])
        XCTAssertEqual(updated.status, "completed")
        XCTAssertEqual(updated.durationSeconds, 1.75)

        // Cancel synchronously before yielding the main actor: this exercises
        // real submission bookkeeping without launching Codex or CAD workers.
        state.cancel()
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.taskAudits, state.taskAudits)
        XCTAssertNil(state.saveStatus)
    }

    @MainActor
    func testCancellationClosesPendingEventsAndRejectsLateToolCallbacks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = "Create a synthetic design"
        state.submit()
        state.recordTaskEvent(event("building", status: "running"))
        state.recordTaskEvent(event("finished", status: "completed"))
        state.stopGeneration()
        let task = try XCTUnwrap(state.taskAudits.first)
        XCTAssertEqual(task.status, "canceled")
        XCTAssertNotNil(task.finishedAt)
        XCTAssertEqual(task.events.map(\.status), ["canceled", "completed"])
        XCTAssertFalse(state.isWorking)
        XCTAssertTrue(state.messages.last?.content.contains("Generation canceled") == true)
        state.recordTaskEvent(event("late", status: "completed"))
        XCTAssertEqual(state.taskAudits, [task])
        await state.prepareToQuit()
        XCTAssertEqual(try ProjectStore.read(from: XCTUnwrap(state.projectURL)).taskAudits, [task])
    }

    @MainActor
    func testFinishedTaskActivitySurvivesSavingAndReopeningWithoutCreatingActiveCallbacks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let user = ChatMessage(role: "user", content: "Inspect an external design")
        let task = ProjectTaskAudit(userMessageID: user.id,
                                    startedAt: Date(timeIntervalSinceReferenceDate: 100),
                                    finishedAt: Date(timeIntervalSinceReferenceDate: 102),
                                    model: "audit-model", reasoningEffort: "high", status: "completed",
                                    events: [event("finished", status: "completed")])
        let project = LADProject(messages: [user], revisions: [], selectedRevisionID: nil,
                                 projectID: UUID(), taskAudits: [task])
        let source = fixture.directory.appendingPathComponent("Completed activity.lad")
        try ProjectStore.write(project, to: source)
        let state = fixture.state()
        state.loadProject(try ProjectStore.read(from: source), from: source)
        XCTAssertEqual(state.taskAudits, [task])
        state.recordTaskEvent(event("late", status: "completed"))
        XCTAssertEqual(state.taskAudits, [task], "An old run cannot acquire events from a new or stale callback.")
        await state.prepareToQuit()
        XCTAssertEqual(try ProjectStore.read(from: XCTUnwrap(state.projectURL)).taskAudits, [task])
    }

    @MainActor
    func testReopenedRunningTasksBecomeInterruptedWhileFinishedEventsStayComplete() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let user = ChatMessage(role: "user", content: "Build before interruption")
        let startedAt = Date().addingTimeInterval(-100)
        let task = ProjectTaskAudit(userMessageID: user.id, startedAt: startedAt,
                                    model: "audit-model", reasoningEffort: "high", status: "running",
                                    events: [event("pending", status: "running"), event("finished", status: "completed")])
        let project = LADProject(messages: [user], revisions: [], selectedRevisionID: nil,
                                 projectID: UUID(), taskAudits: [task])
        let source = fixture.directory.appendingPathComponent("Interrupted activity.lad")
        try ProjectStore.write(project, to: source)
        let state = fixture.state()
        state.loadProject(try ProjectStore.read(from: source), from: source)
        let restored = try XCTUnwrap(state.taskAudits.first)
        XCTAssertEqual(restored.id, task.id)
        XCTAssertEqual(restored.startedAt, startedAt)
        XCTAssertEqual(restored.status, "interrupted")
        XCTAssertNotNil(restored.finishedAt)
        XCTAssertEqual(restored.events.map(\.status), ["interrupted", "completed"])
        XCTAssertEqual(restored.events.map(\.input), task.events.map(\.input))
        XCTAssertEqual(restored.events.map(\.output), task.events.map(\.output))
        state.recordTaskEvent(event("late", status: "completed"))
        XCTAssertEqual(state.taskAudits, [restored])
        await state.prepareToQuit()
        XCTAssertEqual(try ProjectStore.read(from: XCTUnwrap(state.projectURL)).taskAudits, [restored])
    }

    @MainActor
    func testTaskAndEventIdentityRemainIndependentBetweenProjects() async throws {
        let firstFixture = try Fixture(), secondFixture = try Fixture()
        defer { firstFixture.cleanUp(); secondFixture.cleanUp() }
        let first = firstFixture.state(), second = secondFixture.state()
        first.newProject(); second.newProject()
        first.selectCodexModel("first-audit-model")
        second.selectCodexModel("second-audit-model")
        first.prompt = "First synthetic design"; first.submit()
        second.prompt = "Second synthetic design"; second.submit()
        first.recordTaskEvent(event("shared-cli-id", status: "running", output: "first output"))
        second.recordTaskEvent(event("shared-cli-id", status: "running", output: "second output"))
        XCTAssertNotEqual(first.taskAudits.first?.id, second.taskAudits.first?.id)
        XCTAssertNotEqual(first.taskAudits.first?.userMessageID, second.taskAudits.first?.userMessageID)
        XCTAssertEqual(first.taskAudits.first?.model, "first-audit-model")
        XCTAssertEqual(second.taskAudits.first?.model, "second-audit-model")
        first.cancel()
        XCTAssertEqual(first.taskAudits.first?.status, "canceled")
        XCTAssertEqual(second.taskAudits.first?.status, "running")
        XCTAssertEqual(first.taskAudits.first?.events.first?.output, "first output")
        XCTAssertEqual(second.taskAudits.first?.events.first?.output, "second output")
        second.cancel()
        await first.prepareToQuit(); await second.prepareToQuit()
        XCTAssertEqual(try ProjectStore.read(from: XCTUnwrap(first.projectURL)).taskAudits, first.taskAudits)
        XCTAssertEqual(try ProjectStore.read(from: XCTUnwrap(second.projectURL)).taskAudits, second.taskAudits)
    }

    @MainActor
    func testNewProjectClearsItsPriorAuditAndCannotReceiveOldTaskEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = "Previous synthetic design"; state.submit()
        state.recordTaskEvent(event("old", status: "running"))
        XCTAssertEqual(state.taskAudits.count, 1)
        state.newProject()
        XCTAssertTrue(state.taskAudits.isEmpty)
        XCTAssertTrue(state.messages.isEmpty)
        state.recordTaskEvent(event("late", status: "completed"))
        XCTAssertTrue(state.taskAudits.isEmpty)
        await state.prepareToQuit()
        XCTAssertNil(state.projectURL)
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    private func event(_ id: String, status: String, output: String = "native geometry checked") -> ProjectActivityEvent {
        ProjectActivityEvent(id: id, category: "tool", title: "Validate design", status: status,
                             input: "workspace/program.py", output: output)
    }

    private struct Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-activity-state-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        @MainActor
        func state() -> AppState { AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory)) }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
