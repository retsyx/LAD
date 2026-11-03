import AppKit
import XCTest
@testable import LAD

final class AppStateInitialSaveTests: XCTestCase {
    @MainActor
    func testFreshProjectKeepsDraftAndConfigurationInMemoryThroughSaveAndClosePaths() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        var recentURLs: [URL] = []
        state.onRecentProjectChanged = { url, _ in recentURLs.append(url) }
        state.start(restoringRecent: false)
        XCTAssertNil(state.projectURL)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertFalse(state.canSaveProject)

        state.prompt = "An unsent first request"
        state.pendingAttachments = [try imageAttachment()]
        state.showGrid = false
        state.projectionMode = .isometric
        state.displayMode = .translucent
        state.setPartsPaneFraction(0.6)
        state.selectCodexModel("initial-save-model")
        state.selectCodexReasoningEffort("high")
        try state.renameProject(to: "Future enclosure")
        state.saveProject()
        state.saveProject(as: true) // Must return without presenting a save panel.
        try await state.saveProjectForQuit(to: fixture.directory.appendingPathComponent("Recovery.lad"))
        try await Task.sleep(for: .milliseconds(750))
        try await state.flushForReplacement()
        await state.prepareToQuit()
        let canQuit = await ProjectQuitSave.save(state, chooseAction: { _ in
            XCTFail("A design with no submitted request must not prompt to save.")
            return .cancel
        })

        XCTAssertTrue(canQuit)
        XCTAssertEqual(state.prompt, "An unsent first request")
        XCTAssertEqual(state.pendingAttachments.count, 1)
        XCTAssertEqual(state.title, "Future enclosure")
        XCTAssertNil(state.projectURL)
        XCTAssertNil(state.saveStatus)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertTrue(recentURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @MainActor
    func testFirstSubmittedRequestStartsAutosavingAndNewProjectResetsEligibility() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        try state.renameProject(to: "Requested enclosure")
        state.showGrid = false
        state.setPartsPaneFraction(0.6)
        state.prompt = "Create an enclosure"
        state.submit()
        XCTAssertTrue(state.canSaveProject)
        XCTAssertTrue(state.hasUnsavedChanges)
        state.cancel() // Keep request bookkeeping without launching external work.
        await state.prepareToQuit()

        let url = try XCTUnwrap(state.projectURL)
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.messages.first?.content, "Create an enclosure")
        XCTAssertEqual(saved.projectName, "Requested enclosure")
        XCTAssertEqual(saved.showGrid, false)
        XCTAssertEqual(saved.partsPaneFraction, 0.6)
        XCTAssertTrue(saved.revisions.isEmpty)
        XCTAssertFalse(state.hasUnsavedChanges)

        state.prompt = "A later unsent refinement"
        state.displayMode = .translucent
        await state.prepareToQuit()
        XCTAssertEqual(try ProjectStore.read(from: url).draftPrompt, state.prompt)
        XCTAssertEqual(try ProjectStore.read(from: url).displayMode, .translucent)
        let previousBytes = try ProjectStore.readArchive(from: url)
        state.newProject()
        state.prompt = "Another unsent first request"
        await state.prepareToQuit()
        XCTAssertFalse(state.canSaveProject)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.projectURL)
        XCTAssertEqual(try ProjectStore.readArchive(from: url), previousBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.saveDirectory.path).filter { $0.hasSuffix(".lad") }.count, 1)
    }

    @MainActor
    func testImageOnlyFirstRequestStartsSavingWithPortableAttachmentBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        let attachment = try imageAttachment()
        state.pendingAttachments = [attachment]
        XCTAssertFalse(state.canSaveProject)
        state.submit()
        XCTAssertTrue(state.canSaveProject)
        state.cancel()
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.messages.first?.role, "user")
        XCTAssertEqual(saved.messages.first?.attachments?.first?.imageData, attachment.imageData)
    }

    @MainActor
    func testAcceptedQueuedRequestStartsSavingBeforeItRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.isWorking = true
        state.prompt = "Create a queued enclosure"
        state.submit()
        XCTAssertTrue(state.canSaveProject)
        XCTAssertTrue(state.messages.isEmpty)
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.queuedRequests?.first?.content, "Create a queued enclosure")
        XCTAssertEqual(saved.queuePaused, true)
    }

    @MainActor
    func testRejectedOrEmptySubmissionDoesNotEnableSaving() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = " \n "
        state.submit()
        XCTAssertFalse(state.canSaveProject)
        state.prompt = String(repeating: "x", count: 1_000_001)
        state.submit()
        XCTAssertNotNil(state.error)
        XCTAssertFalse(state.canSaveProject)
        await state.prepareToQuit()
        XCTAssertNil(state.projectURL)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @MainActor
    func testOpenedEmptyProjectStillAutosavesWithoutANewRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let url = fixture.directory.appendingPathComponent("Existing empty design.lad")
        let project = LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: UUID())
        try ProjectStore.write(project, to: url)
        let state = fixture.state()
        state.loadProject(try ProjectStore.read(from: url), from: url)
        XCTAssertTrue(state.canSaveProject)
        state.prompt = "A draft in an existing file"
        state.showGrid = false
        await state.prepareToQuit()
        XCTAssertEqual(state.projectURL, url)
        XCTAssertFalse(state.hasUnsavedChanges)
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.draftPrompt, state.prompt)
        XCTAssertEqual(saved.showGrid, false)
        XCTAssertEqual(saved.projectID, project.projectID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.saveDirectory.path))
    }

    @MainActor
    private func imageAttachment() throws -> SourceAttachment {
        try SourceImport.imageAttachment(data: ImageAttachmentTestImage.png(.red), name: "Reference", path: "/missing/reference.png")
    }

    private struct Fixture {
        let directory: URL
        var saveDirectory: URL { directory.appendingPathComponent("Autosaves", isDirectory: true) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-initial-save-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        @MainActor
        func state() -> AppState { AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: saveDirectory)) }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
