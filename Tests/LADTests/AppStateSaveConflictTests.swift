import AppKit
import Combine
import Foundation
import XCTest
@testable import LAD

final class AppStateSaveConflictTests: XCTestCase {
    @MainActor
    func testEditsDuringConflictResolutionAreSavedAfterTheChosenSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        var remote = try ProjectStore.read(from: url)
        remote.draftPrompt = "Remote edit"
        try ProjectStore.write(remote, to: url)
        state.prompt = "Local edit"
        await state.prepareToQuit()
        XCTAssertNotNil(state.saveConflict)

        let held = expectation(description: "External coordinator holds the file")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var failure: NSError?
            coordinator.coordinate(writingItemAt: url, options: [], error: &failure) { _ in
                held.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        defer { release.signal() }
        await fulfillment(of: [held], timeout: 2)
        let saving = expectation(description: "Resolution captured its snapshot")
        let observation = state.$saveStatus.filter { $0 == "Saving…" }.prefix(1).sink { _ in saving.fulfill() }
        let resolving = Task { try await state.resolveSaveConflict(.overwrite) }
        await fulfillment(of: [saving], timeout: 2)
        state.showGrid = false // A direct autosave request while the writer is waiting.
        release.signal()
        try await resolving.value
        await holding.value
        for _ in 0..<100 {
            if !state.hasUnsavedChanges, try ProjectStore.read(from: url).showGrid == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try ProjectStore.read(from: url).showGrid, false)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveConflict)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testSharedViewsAndLaterLayoutUpdatesDoNotRepeatACanceledConflictPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        var remote = try ProjectStore.read(from: url)
        remote.draftPrompt = "Remote edit"
        try ProjectStore.write(remote, to: url)
        state.prompt = "Local edit"
        await state.prepareToQuit()
        XCTAssertNotNil(state.saveConflict)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var prompts = 0
        let choose: @MainActor (ProjectSaveConflict, NSWindow) async -> ProjectSaveConflictPrompt.Choice = { _, _ in
            prompts += 1
            return .cancel
        }
        state.presentSaveConflict(in: window, choose: choose)
        state.presentSaveConflict(in: window, choose: choose)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(prompts, 1)
        state.prompt = "Typing must not reopen the canceled dialog"
        state.presentSaveConflict(in: window, choose: choose)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertNotNil(state.saveConflict)
    }

    @MainActor
    func testCancelKeepsBothVersionsAndOverwriteUsesTheLatestLocalDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        var remote = try ProjectStore.read(from: url)
        remote.draftPrompt = "Remote draft"
        try ProjectStore.write(remote, to: url)
        let remoteBytes = try ProjectStore.readArchive(from: url)
        state.prompt = "Local draft"
        await state.prepareToQuit()
        XCTAssertNotNil(state.saveConflict)
        XCTAssertTrue(state.hasUnsavedChanges)
        try await state.resolveSaveConflict(.cancel)
        XCTAssertEqual(try ProjectStore.readArchive(from: url), remoteBytes)
        XCTAssertEqual(state.prompt, "Local draft")
        XCTAssertTrue(state.hasUnsavedChanges)

        state.prompt = "Local draft edited while the conflict is pending"
        try await state.resolveSaveConflict(.overwrite)
        XCTAssertNil(state.saveConflict)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.saveStatus)
        XCTAssertEqual(try ProjectStore.read(from: url).draftPrompt, state.prompt)
        state.prompt = "Later ordinary autosave"
        await state.prepareToQuit()
        XCTAssertNil(state.saveConflict)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(try ProjectStore.read(from: url).draftPrompt, state.prompt)
    }

    @MainActor
    func testSavingDifferentNameForksTheCompleteLocalDocumentAndContinuesAutosavingThere() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest("Keep my complete conversation")
        await state.prepareToQuit()
        let original = try XCTUnwrap(state.projectURL)
        let identity = state.projectDocumentID
        var remote = try ProjectStore.read(from: original)
        remote.draftPrompt = "Remote changes"
        try ProjectStore.write(remote, to: original)
        let remoteBytes = try ProjectStore.readArchive(from: original)
        state.prompt = "My local changes"
        await state.prepareToQuit()
        let destination = fixture.directory.appendingPathComponent("Local copy.lad")
        try await state.resolveSaveConflict(.saveAs(destination))
        XCTAssertNil(state.saveConflict)
        XCTAssertNotEqual(state.projectDocumentID, identity)
        XCTAssertEqual(state.projectURL, destination)
        XCTAssertEqual(try ProjectStore.readArchive(from: original), remoteBytes)
        let copy = try ProjectStore.read(from: destination)
        XCTAssertEqual(copy.messages, state.messages)
        XCTAssertEqual(copy.draftPrompt, state.prompt)
        XCTAssertEqual(copy.projectName, "Local copy")
        XCTAssertFalse(state.hasUnsavedChanges)
        state.prompt = "Later local edits"
        await state.prepareToQuit()
        XCTAssertEqual(state.projectURL, destination)
        XCTAssertEqual(try ProjectStore.read(from: destination).draftPrompt, state.prompt)
        XCTAssertEqual(try ProjectStore.readArchive(from: original), remoteBytes)
        XCTAssertNil(state.saveConflict)
    }

    @MainActor
    func testOverwriteRequiresASecondDecisionWhenTheFileChangesAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.newProjectWithSubmittedRequest()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        var remote = try ProjectStore.read(from: url)
        remote.draftPrompt = "First remote edit"
        try ProjectStore.write(remote, to: url)
        state.prompt = "Local edit"
        await state.prepareToQuit()
        let first = try XCTUnwrap(state.saveConflict)
        remote.draftPrompt = "Second remote edit while the dialog is open"
        try ProjectStore.write(remote, to: url)
        let secondBytes = try ProjectStore.readArchive(from: url)
        do {
            try await state.resolveSaveConflict(.overwrite)
            XCTFail("An overwrite decision must apply only to the observed file")
        } catch is ProjectSaveConflict {}
        XCTAssertNotEqual(state.saveConflict?.file.sha256, first.file.sha256)
        XCTAssertEqual(try ProjectStore.readArchive(from: url), secondBytes)
        XCTAssertTrue(state.hasUnsavedChanges)
        state.newProject()
        XCTAssertNil(state.saveConflict)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let state: AppState
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-save-conflict-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        }
        func cleanUp() {
            state.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
