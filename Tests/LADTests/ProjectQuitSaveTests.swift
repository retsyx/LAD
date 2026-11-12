import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class ProjectQuitSaveTests: XCTestCase {
    @MainActor
    func testRecoveryFileRemainsAutosaveDestinationWhenQuittingIsCanceledLater() async throws {
        let fixture = try Fixture(unavailable: true)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProjectWithSubmittedRequest()
        state.prompt = "Recovered draft"
        await state.prepareToQuit()
        let target = fixture.directory.appendingPathComponent("Recovered.lad")
        let saved = await ProjectQuitSave.save(state, chooseAction: { _ in .save }, chooseURL: { _ in target })
        XCTAssertTrue(saved)
        XCTAssertEqual(state.projectURL, target)
        state.prompt = "Edited after another design canceled quitting"
        await state.prepareToQuit()
        XCTAssertFalse(state.hasUnsavedChanges, state.saveStatus ?? "")
        XCTAssertEqual(try ProjectStore.read(from: target).draftPrompt, state.prompt)
    }

    @MainActor
    func testCancelAndDontSaveHaveDistinctTerminationResultsWithoutWriting() async throws {
        let fixture = try Fixture(unavailable: true)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProjectWithSubmittedRequest()
        state.prompt = "Keep this draft"
        await state.prepareToQuit()
        let canceled = await ProjectQuitSave.save(state, chooseAction: { _ in .cancel }, chooseURL: { _ in
            XCTFail("Cancel must not open a save panel")
            return nil
        })
        XCTAssertFalse(canceled)
        XCTAssertTrue(state.hasUnsavedChanges)
        let discarded = await ProjectQuitSave.save(state, chooseAction: { _ in .dontSave }, chooseURL: { _ in
            XCTFail("Don't Save must not open a save panel")
            return nil
        })
        XCTAssertTrue(discarded)
        XCTAssertTrue(state.hasUnsavedChanges, "Discarding must not claim a successful save")
        let panelCanceled = await ProjectQuitSave.save(state, chooseAction: { _ in .save }, chooseURL: { _ in nil })
        XCTAssertFalse(panelCanceled)
        XCTAssertEqual(state.prompt, "Keep this draft")
    }

    @MainActor
    func testFailedAutosaveStaysUnsavedUntilALaterWriteSucceeds() async throws {
        let fixture = try Fixture(unavailable: true)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProjectWithSubmittedRequest()
        state.prompt = "Keep this draft after the failed autosave"
        await state.prepareToQuit()

        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertNotNil(state.saveStatus)
        XCTAssertNil(state.projectURL)

        try FileManager.default.createDirectory(at: fixture.saveDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: false)
        await state.prepareToQuit()

        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveStatus)
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.draftPrompt, state.prompt)

        var prompts = 0
        await ProjectQuitSave.save(state, chooseAction: { _ in .save }, chooseURL: { _ in
            prompts += 1
            return nil
        }, onFailure: { error in
            XCTFail("A saved design must not need recovery: \(error)")
        })
        XCTAssertEqual(prompts, 0)
    }

    @MainActor
    func testQuitSavePreservesCompleteHistoryQueueDraftAndSettings() async throws {
        let fixture = try Fixture(unavailable: true)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.selectCodexModel("quit-save-model")
        state.selectCodexReasoningEffort("high")

        let firstUser = ChatMessage(role: "user", content: "Create a bracket")
        let firstResponse = ChatMessage(role: "assistant", content: "Created the bracket", phase: "final_answer")
        let secondUser = ChatMessage(role: "user", content: "Add clearance")
        let secondResponse = ChatMessage(role: "assistant", content: "Added clearance", phase: "final_answer")
        let first = ProjectRevision(model: .bracket, userMessageID: firstUser.id,
                                    responseMessageID: firstResponse.id, name: "Original")
        var revised = ModelSpec.bracket
        revised.title = "Bracket with clearance"
        let second = ProjectRevision(model: revised, userMessageID: secondUser.id,
                                     responseMessageID: secondResponse.id, name: "With clearance")
        state.messages = [firstUser, firstResponse, secondUser, secondResponse]
        state.revisions = [first, second]
        state.selectedRevisionID = second.id
        state.showGrid = false
        state.projectionMode = .isometric
        state.displayMode = .translucent

        // A pending follow-up is preserved without launching a CAD request.
        state.isWorking = true
        state.prompt = "Add a matching lid"
        state.submit()
        let queued = state.queuedRequests
        XCTAssertEqual(queued.count, 1)
        let attachment = sourceAttachment()
        state.pendingAttachments = [attachment]
        state.prompt = "Keep this unsent draft"
        await state.prepareToQuit()
        XCTAssertTrue(state.hasUnsavedChanges)

        let destination = fixture.directory.appendingPathComponent("Recovered design.lad")
        var prompts = 0
        await ProjectQuitSave.save(state, chooseAction: { _ in .save }, chooseURL: { selected in
            XCTAssertTrue(selected === state)
            prompts += 1
            return destination
        }, onFailure: { error in
            XCTFail("The recovery copy should save: \(error)")
        })

        XCTAssertEqual(prompts, 1)
        XCTAssertFalse(state.hasUnsavedChanges)
        let saved = try ProjectStore.read(from: destination)
        XCTAssertEqual(saved.projectID, state.projectDocumentID)
        XCTAssertEqual(saved.messages.map(\.id), state.messages.map(\.id))
        XCTAssertEqual(saved.messages.map(\.content), state.messages.map(\.content))
        XCTAssertEqual(saved.revisions.map(\.id), [first.id, second.id])
        XCTAssertEqual(saved.revisions.map(\.model), [.bracket, revised])
        XCTAssertEqual(saved.revisions.map(\.name), ["Original", "With clearance"])
        XCTAssertEqual(saved.selectedRevisionID, second.id)
        XCTAssertEqual(saved.queuedRequests, queued)
        XCTAssertEqual(saved.queuePaused, true)
        XCTAssertEqual(saved.draftPrompt, "Keep this unsent draft")
        XCTAssertEqual(saved.draftAttachments, [attachment])
        XCTAssertEqual(saved.codexSettings, state.codexSettings)
        XCTAssertEqual(saved.showGrid, false)
        XCTAssertEqual(saved.projectionMode, .isometric)
        XCTAssertEqual(saved.displayMode, .translucent)
    }

    @MainActor
    func testCancelingQuitSaveLeavesExistingBytesAndUnsavedStateIntact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProjectWithSubmittedRequest()
        await state.prepareToQuit()
        let originalURL = try XCTUnwrap(state.projectURL)

        // Simulate another writer so the local final autosave must preserve
        // the existing package and leave this window's later changes unsaved.
        var remote = try ProjectStore.read(from: originalURL)
        remote.messages.append(ChatMessage(role: "user", content: "A change from another Mac"))
        try ProjectStore.write(remote, to: originalURL)
        let originalBytes = try ProjectStore.readArchive(from: originalURL)
        state.prompt = "My local unsaved draft"
        await state.prepareToQuit()
        XCTAssertTrue(state.hasUnsavedChanges)

        var prompts = 0
        await ProjectQuitSave.save(state, chooseAction: { _ in .save }, chooseURL: { _ in
            prompts += 1
            return nil
        }, onFailure: { error in
            XCTFail("Cancel must not attempt a write: \(error)")
        })

        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(state.hasUnsavedChanges, "Cancel preserves the unsaved design and prevents quitting")
        XCTAssertEqual(state.prompt, "My local unsaved draft")
        XCTAssertEqual(try ProjectStore.readArchive(from: originalURL), originalBytes)
    }

    @MainActor
    func testFailedQuitSaveReportsFailureAndPromptsAgainUntilCanceled() async throws {
        let fixture = try Fixture(unavailable: true)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProjectWithSubmittedRequest()
        state.prompt = "Preserve this draft after an unsuccessful recovery write"
        await state.prepareToQuit()
        let invalidDestination = fixture.directory.appendingPathComponent("missing-destination/Recovered.lad")

        var prompts = 0
        var failures = 0
        await ProjectQuitSave.save(state, chooseAction: { _ in .save }, chooseURL: { _ in
            prompts += 1
            return prompts == 1 ? invalidDestination : nil
        }, onFailure: { error in
            failures += 1
            XCTAssertFalse(error.localizedDescription.isEmpty)
        })

        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertEqual(state.prompt, "Preserve this draft after an unsuccessful recovery write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidDestination.path))
    }

    @MainActor
    func testQuitSaveIncludesDraftChangesMadeWhileChoosingItsDestination() async throws {
        let fixture = try Fixture(unavailable: true)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProjectWithSubmittedRequest()
        state.prompt = "Earlier draft"
        await state.prepareToQuit()
        let destination = fixture.directory.appendingPathComponent("Latest draft.lad")

        await ProjectQuitSave.save(state, chooseAction: { _ in .save }, chooseURL: { selected in
            selected.prompt = "Latest draft"
            return destination
        }, onFailure: { error in
            XCTFail("The latest draft should save: \(error)")
        })

        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(try ProjectStore.read(from: destination).draftPrompt, "Latest draft")
    }

    private func sourceAttachment() -> SourceAttachment {
        let text = "# complete retained reference\nwidth = 23\n"
        let digest = SHA256.hexDigest(Data(text.utf8))
        return SourceAttachment(name: "dimensions.py", path: "/original/dimensions.py", content: text, sha256: digest)
    }

    private struct Fixture {
        let directory: URL
        let saveDirectory: URL

        init(unavailable: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-quit-save-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            saveDirectory = unavailable
                ? directory.appendingPathComponent("missing-parent/LAD", isDirectory: true)
                : directory.appendingPathComponent("LAD", isDirectory: true)
        }

        @MainActor
        func state() -> AppState { AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: saveDirectory)) }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
