import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class AppStateRequestQueueTests: XCTestCase {
    @MainActor
    func testBusySubmissionCapturesSettingsAndSupportsStableEditingRemovalAndReordering() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true // The CAD validation stage has no steerable CLI.
        state.selectCodexModel("first-model")
        state.selectCodexReasoningEffort("high")
        state.prompt = "Add a lid"
        state.submit()
        let first = try XCTUnwrap(state.queuedRequests.first)
        XCTAssertTrue(state.prompt.isEmpty)
        XCTAssertTrue(state.messages.isEmpty, "Queued requests are not yet sent conversation messages.")
        XCTAssertEqual(first.codexSettings?.model, "first-model")
        XCTAssertEqual(first.codexSettings?.reasoningEffort, "high")

        state.selectCodexModel("second-model")
        state.selectCodexReasoningEffort("low")
        state.prompt = "Add mounting holes"
        state.submit()
        let second = try XCTUnwrap(state.queuedRequests.last)
        state.beginEditingQueuedRequest(id: first.id)
        XCTAssertEqual(state.editingQueuedRequestID, first.id)
        state.prompt = "Add a removable lid"
        state.submit()
        XCTAssertNil(state.editingQueuedRequestID)
        XCTAssertEqual(state.queuedRequests.first?.id, first.id)
        XCTAssertEqual(state.queuedRequests.first?.content, "Add a removable lid")
        XCTAssertEqual(state.queuedRequests.first?.codexSettings, first.codexSettings)
        state.moveQueuedRequest(id: second.id, beforeID: first.id)
        XCTAssertEqual(state.queuedRequests.map(\.id), [second.id, first.id])
        state.moveQueuedRequest(id: second.id, beforeID: nil)
        XCTAssertEqual(state.queuedRequests.map(\.id), [first.id, second.id])
        state.removeQueuedRequest(id: first.id)
        XCTAssertEqual(state.queuedRequests.map(\.id), [second.id])
        XCTAssertEqual(state.model, "second-model", "Queue operations must not overwrite later composer choices.")
        state.prompt = "Unsent draft while the current task works"
        state.stopGeneration()
        XCTAssertTrue(state.queuePaused)
        XCTAssertEqual(state.queuedRequests.map(\.id), [second.id])
        XCTAssertEqual(state.prompt, "Unsent draft while the current task works")
        await state.prepareToQuit()
    }

    @MainActor
    func testComposerEditSavesQueuedTextAttachmentsAndChoicesThenRestoresTheUnsentDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        let queuedSource = attachment("queued.py", content: "width = 12\n", in: fixture)
        let draftSource = attachment("draft.py", content: "height = 34\n", in: fixture)
        let editedSource = attachment("edited.py", content: "clearance = 0.4\n", in: fixture)
        state.selectCodexModel("queued-model"); state.selectCodexReasoningEffort("high")
        state.prompt = "Add an enclosure"
        state.pendingAttachments = [queuedSource]
        state.submit()
        let original = try XCTUnwrap(state.queuedRequests.first)

        state.selectCodexModel("draft-model"); state.selectCodexReasoningEffort("low")
        state.prompt = "Keep my next request here"
        state.pendingAttachments = [draftSource]
        let draftSettings = state.codexSettings
        state.beginEditingQueuedRequest(id: original.id)
        XCTAssertEqual(state.prompt, original.content)
        XCTAssertEqual(state.pendingAttachments, [queuedSource])
        XCTAssertEqual(state.codexSettings, original.codexSettings)

        state.prompt = "Add a vented enclosure"
        state.pendingAttachments = [editedSource]
        state.selectCodexModel("edited-model"); state.selectCodexReasoningEffort("ultra")
        let editedSettings = state.codexSettings
        state.submit() // The normal composer action saves an edit instead of submitting another request.

        let edited = try XCTUnwrap(state.queuedRequests.first)
        XCTAssertEqual(state.queuedRequests.count, 1)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.date, original.date)
        XCTAssertEqual(edited.content, "Add a vented enclosure")
        XCTAssertEqual(edited.attachments, [editedSource])
        XCTAssertEqual(edited.codexSettings, editedSettings)
        XCTAssertNil(state.editingQueuedRequestID)
        XCTAssertEqual(state.prompt, "Keep my next request here")
        XCTAssertEqual(state.pendingAttachments, [draftSource])
        XCTAssertEqual(state.codexSettings, draftSettings, "Restore the complete per-model reasoning preferences as well as the visible selection.")
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty, "Saving a queued edit must not start a separate Codex task.")
        await state.prepareToQuit()
    }

    @MainActor
    func testCancelAndRemovingAnEditedRequestRestoreTheOriginalComposerState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        state.selectCodexModel("queued-model"); state.selectCodexReasoningEffort("high")
        state.prompt = "Add mounting holes"; state.submit()
        let original = try XCTUnwrap(state.queuedRequests.first)
        let draftSource = attachment("keep.py", content: "diameter = 3\n", in: fixture)
        state.selectCodexModel("draft-model"); state.selectCodexReasoningEffort("low")
        let draftSettings = state.codexSettings
        state.prompt = "Unsent follow-up"
        state.pendingAttachments = [draftSource]

        state.beginEditingQueuedRequest(id: original.id)
        state.prompt = "Discard this edit"
        state.selectCodexReasoningEffort("ultra")
        state.cancelEditingQueuedRequest()
        XCTAssertEqual(state.queuedRequests, [original])
        XCTAssertNil(state.editingQueuedRequestID)
        XCTAssertEqual(state.prompt, "Unsent follow-up")
        XCTAssertEqual(state.pendingAttachments, [draftSource])
        XCTAssertEqual(state.codexSettings, draftSettings)

        state.beginEditingQueuedRequest(id: original.id)
        let sourceURL = fixture.directory.appendingPathComponent("late-edited-source.py")
        try Data("# LATE_EDIT_ATTACHMENT\n".utf8).write(to: sourceURL)
        state.attachSourceFiles(urls: [sourceURL])
        XCTAssertTrue(state.isReadingQueuedAttachments)
        state.prompt = "Also discard when removing the item"
        state.removeQueuedRequest(id: original.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(state.queuedRequests.isEmpty)
        XCTAssertNil(state.editingQueuedRequestID)
        XCTAssertEqual(state.prompt, "Unsent follow-up")
        XCTAssertEqual(state.pendingAttachments, [draftSource])
        XCTAssertEqual(state.codexSettings, draftSettings)
        XCTAssertFalse(state.isReadingQueuedAttachments, "A late edited-source callback must not alter the restored ordinary draft.")
        await state.prepareToQuit()
    }

    @MainActor
    func testSwitchingQueuedEditorsKeepsOneOriginalDraftAndInvalidEditsStayOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        state.prompt = "First queued change"; state.submit()
        state.selectCodexModel("second-model"); state.selectCodexReasoningEffort("high")
        state.prompt = "Second queued change"; state.submit()
        let originals = state.queuedRequests
        state.selectCodexModel("draft-model"); state.selectCodexReasoningEffort("low")
        let draftSettings = state.codexSettings
        state.prompt = "Original unsent draft"

        state.beginEditingQueuedRequest(id: originals[0].id)
        state.prompt = "Uncommitted first change"
        state.beginEditingQueuedRequest(id: originals[1].id)
        XCTAssertEqual(state.editingQueuedRequestID, originals[1].id)
        XCTAssertEqual(state.prompt, originals[1].content)
        XCTAssertEqual(state.codexSettings, originals[1].codexSettings)
        XCTAssertEqual(state.queuedRequests, originals)

        state.prompt = " \n "
        XCTAssertFalse(state.canCommitQueuedRequest)
        XCTAssertFalse(state.commitEditingQueuedRequest())
        XCTAssertEqual(state.editingQueuedRequestID, originals[1].id)
        XCTAssertEqual(state.prompt, " \n ")
        XCTAssertEqual(state.queuedRequests, originals)
        state.cancelEditingQueuedRequest()
        XCTAssertEqual(state.prompt, "Original unsent draft")
        XCTAssertEqual(state.codexSettings, draftSettings)
        XCTAssertNil(state.editingQueuedRequestID)
        await state.prepareToQuit()
    }

    @MainActor
    func testAutosavingDuringAQueuedEditKeepsTheOriginalUnsentDraftAndUnchangedQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        state.selectCodexModel("queued-model"); state.selectCodexReasoningEffort("high")
        state.prompt = "Queued request before editing"; state.submit()
        let request = try XCTUnwrap(state.queuedRequests.first)
        let draftSource = attachment("draft.py", content: "width = 17\n", in: fixture)
        state.selectCodexModel("draft-model"); state.selectCodexReasoningEffort("low")
        let draftSettings = state.codexSettings
        state.prompt = "Original draft saved separately"
        state.pendingAttachments = [draftSource]
        state.beginEditingQueuedRequest(id: request.id)
        state.prompt = "Uncommitted edit must not overwrite either saved request"
        state.pendingAttachments = []
        state.selectCodexModel("temporary-edit-model")
        state.selectCodexReasoningEffort("ultra")
        await state.prepareToQuit()

        let savedURL = try XCTUnwrap(state.projectURL)
        let saved = try ProjectStore.read(from: savedURL)
        XCTAssertEqual(saved.draftPrompt, "Original draft saved separately")
        XCTAssertEqual(saved.draftAttachments, [draftSource])
        XCTAssertEqual(saved.codexSettings, draftSettings)
        XCTAssertEqual(saved.queuedRequests, [request])
        let restored = fixture.state()
        restored.loadProject(saved, from: savedURL)
        XCTAssertNil(restored.editingQueuedRequestID)
        XCTAssertEqual(restored.prompt, "Original draft saved separately")
        XCTAssertEqual(restored.pendingAttachments, [draftSource])
        XCTAssertEqual(restored.codexSettings, draftSettings)
        XCTAssertEqual(restored.queuedRequests, [request])
        restored.cancelEditingQueuedRequest()
        XCTAssertEqual(restored.prompt, "Original draft saved separately")
        await restored.prepareToQuit()
    }

    @MainActor
    func testSavedQueueAndDraftRestorePausedWithPortableSourceSnapshots() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        state.selectCodexModel("captured-model")
        state.selectCodexReasoningEffort("high")
        let source = fixture.directory.appendingPathComponent("board.kicad_pcb")
        let contents = "(kicad_pcb ; QUEUED_SOURCE_SENTINEL\n)\n"
        try Data(contents.utf8).write(to: source)
        state.prompt = "Create a case for \"\(source.path)\""
        state.submit()
        let requestID = try XCTUnwrap(state.queuedRequests.first?.id)
        try await waitForSources(state)
        XCTAssertEqual(state.queuedRequests.first?.attachments?.first?.content, contents)
        try FileManager.default.removeItem(at: source)
        state.prompt = "Unsent follow-up draft"
        state.pendingAttachments = state.queuedRequests.first?.attachments ?? []
        await state.prepareToQuit()
        let savedURL = try XCTUnwrap(state.projectURL)
        var saved = try ProjectStore.read(from: savedURL)
        XCTAssertEqual(saved.queuedRequests?.first?.id, requestID)
        XCTAssertEqual(saved.draftPrompt, "Unsent follow-up draft")
        XCTAssertEqual(saved.draftAttachments?.first?.content, contents)
        saved.queuePaused = false // A saved running queue must still reopen safely.
        try ProjectStore.write(saved, to: savedURL)

        let restored = fixture.state()
        restored.loadProject(try ProjectStore.read(from: savedURL), from: savedURL)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(restored.queuePaused)
        XCTAssertFalse(restored.isWorking)
        XCTAssertTrue(restored.taskAudits.isEmpty)
        XCTAssertTrue(restored.messages.isEmpty)
        XCTAssertEqual(restored.prompt, "Unsent follow-up draft")
        XCTAssertEqual(restored.queuedRequests.first?.id, requestID)
        restored.selectCodexModel("later-composer-model")
        restored.resumeQueue()
        XCTAssertEqual(restored.taskAudits.first?.model, "captured-model")
        XCTAssertEqual(restored.taskAudits.first?.reasoningEffort, "high")
        try await waitForWork(restored)
        XCTAssertEqual(restored.error, CodexExecutable.setupMessage,
                      "A queued source snapshot must not be reread from its deleted original path.")
        XCTAssertEqual(restored.messages.first(where: { $0.role == "user" })?.attachments?.first?.content, contents)
        XCTAssertEqual(restored.model, "later-composer-model")
        XCTAssertEqual(restored.prompt, "Unsent follow-up draft", "Starting a queued turn must not consume the current draft.")
        await restored.prepareToQuit()
    }

    @MainActor
    func testFailurePausesRemainingRequestsAndResumeStartsOnlyOne() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        state.prompt = "First queued change"; state.submit()
        state.prompt = "Second queued change"; state.submit()
        state.prompt = "Third queued change"; state.submit()
        let ids = state.queuedRequests.map(\.id)
        state.cancel()
        XCTAssertEqual(state.queuedRequests.map(\.id), ids)
        state.resumeQueue()
        XCTAssertEqual(state.queuedRequests.map(\.id), Array(ids.dropFirst()))
        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content), ["First queued change"])
        try await waitForWork(state)
        XCTAssertTrue(state.queuePaused)
        XCTAssertEqual(state.taskAudits.count, 1)
        XCTAssertEqual(state.queuedRequests.map(\.id), Array(ids.dropFirst()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.taskAudits.count, 1, "Failure must not silently start another queued turn.")
        state.resumeQueue()
        XCTAssertEqual(state.queuedRequests.map(\.id), [ids[2]])
        try await waitForWork(state)
        XCTAssertEqual(state.taskAudits.count, 2)
        XCTAssertTrue(state.queuePaused)
        await state.prepareToQuit()
    }

    @MainActor
    func testCapturedSymlinkReferenceSurvivesRemovalOrRetargetingAcrossSaveAndReopen() async throws {
        for retarget in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let source = fixture.directory.appendingPathComponent("original.py")
            let replacement = fixture.directory.appendingPathComponent("replacement.py")
            let alias = fixture.directory.appendingPathComponent("board-source.py")
            let original = "# CAPTURED_SYMLINK_SOURCE\nwidth = 23\n"
            try Data(original.utf8).write(to: source)
            try Data("# REPLACEMENT_MUST_NOT_OVERRIDE_SNAPSHOT\nwidth = 99\n".utf8).write(to: replacement)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            let state = fixture.state()
            state.isWorking = true
            state.prompt = "Use \"\(alias.path)\""
            state.submit()
            try await waitForSources(state)
            XCTAssertEqual(state.queuedRequests.first?.attachments?.first?.content, original)
            try FileManager.default.removeItem(at: alias)
            if retarget { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement) }
            await state.prepareToQuit()
            let file = try XCTUnwrap(state.projectURL)
            let saved = try ProjectStore.read(from: file)
            XCTAssertEqual(saved.queuedRequests?.first?.capturedSourcePaths, [alias.standardizedFileURL.path])
            let restored = fixture.state()
            restored.loadProject(saved, from: file)
            restored.resumeQueue()
            try await waitForWork(restored)
            XCTAssertEqual(restored.error, CodexExecutable.setupMessage,
                          "A captured alias must not be reopened or rebound to a different file at dispatch.")
            XCTAssertEqual(restored.messages.first(where: { $0.role == "user" })?.attachments?.first?.content, original)
            await restored.prepareToQuit()
        }
    }

    @MainActor
    func testSourcePreparationFailureRetainsTheEditableRequestAndPausesQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        let missing = fixture.directory.appendingPathComponent("missing.py")
        state.prompt = "Use \"\(missing.path)\""
        state.submit()
        let id = try XCTUnwrap(state.queuedRequests.first?.id)
        try await waitForSources(state)
        XCTAssertTrue(state.queuePaused)
        XCTAssertEqual(state.queuedRequests.map(\.id), [id])
        XCTAssertTrue(state.error?.contains(missing.path) == true)
        state.error = nil // A successful active turn clears its own error UI.
        XCTAssertTrue(state.queuedRequestErrors[id]?.contains(missing.path) == true,
                      "A queued request's diagnostic must survive unrelated active-task completion.")
        let replacement = fixture.directory.appendingPathComponent("replacement.py")
        let content = "result = cq.Workplane('XY').box(2, 3, 4)\n"
        try Data(content.utf8).write(to: replacement)
        state.editQueuedRequest(id: id, text: "Use \"\(replacement.path)\" instead")
        try await waitForSources(state)
        XCTAssertEqual(state.queuedRequests.first?.id, id)
        XCTAssertEqual(state.queuedRequests.first?.attachments?.first?.content, content)
        XCTAssertTrue(state.queuePaused, "Fixing a request should preserve an explicit paused queue until Resume.")
        state.removeQueuedRequest(id: id)
        XCTAssertTrue(state.queuedRequests.isEmpty)
        await state.prepareToQuit()
    }

    @MainActor
    func testSendNowUnavailableDuringValidationDoesNotConsumeOrSendAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        state.prompt = "Keep this follow-up queued"
        state.submit()
        let request = try XCTUnwrap(state.queuedRequests.first)
        XCTAssertFalse(state.canSteerQueuedRequests)
        state.sendQueuedRequestNow(id: request.id)
        XCTAssertEqual(state.queuedRequests, [request])
        XCTAssertNil(state.isSendingQueuedRequestID)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)
        await state.prepareToQuit()
    }

    @MainActor
    func testRequestQueuedDuringAnotherBusyOperationStartsWhenThatOperationFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true // Preview/export/source reading, not a Codex turn.
        state.prompt = "Create a design after the preview finishes"
        state.submit()
        XCTAssertEqual(state.queuedRequests.count, 1)
        XCTAssertTrue(state.taskAudits.isEmpty)
        state.isWorking = false
        let deadline = ContinuousClock.now + .seconds(5)
        while state.taskAudits.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await waitForWork(state)
        XCTAssertEqual(state.taskAudits.count, 1)
        XCTAssertTrue(state.queuedRequests.isEmpty)
        XCTAssertEqual(state.messages.first(where: { $0.role == "user" })?.content, "Create a design after the preview finishes")
        await state.prepareToQuit()
    }

    @MainActor
    func testNewProjectClearsQueuedRequestsAndDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.isWorking = true
        state.prompt = "Old queued change"; state.submit()
        let oldID = try XCTUnwrap(state.queuedRequests.first?.id)
        state.prompt = "Old draft"
        state.beginEditingQueuedRequest(id: oldID)
        state.prompt = "An in-progress edit of the old design"
        state.newProject()
        XCTAssertTrue(state.queuedRequests.isEmpty)
        XCTAssertTrue(state.prompt.isEmpty)
        XCTAssertTrue(state.pendingAttachments.isEmpty)
        XCTAssertFalse(state.queuePaused)
        XCTAssertNil(state.editingQueuedRequestID)
        XCTAssertNil(state.isSendingQueuedRequestID)
        state.cancelEditingQueuedRequest()
        XCTAssertTrue(state.prompt.isEmpty, "An old editor backup must never reappear in a new design.")
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertNil(saved.queuedRequests)
        XCTAssertNil(saved.draftPrompt)
        XCTAssertNil(saved.draftAttachments)
    }

    @MainActor
    private func attachment(_ name: String, content: String, in fixture: Fixture) -> SourceAttachment {
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        return SourceAttachment(name: name, path: fixture.directory.appendingPathComponent(name).path,
                                content: content, sha256: digest)
    }

    @MainActor
    private func waitForSources(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !state.preparingQueuedRequestIDs.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.preparingQueuedRequestIDs.isEmpty)
    }

    @MainActor
    private func waitForWork(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isWorking)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let oldCodex: Any?

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-request-queue-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
        }

        func state() -> AppState {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.newProject()
            return state
        }

        func cleanUp() {
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
