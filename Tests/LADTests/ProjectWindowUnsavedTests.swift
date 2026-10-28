import Combine
import Foundation
import XCTest
@testable import LAD

final class ProjectWindowUnsavedTests: XCTestCase {
    @MainActor
    func testClosedFailedSaveStaysAliveAndIsOfferedOnceAtQuit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var state: AppState? = fixture.state()
        weak var retained = state
        let identity = ObjectIdentifier(try XCTUnwrap(state))
        var offered: [ObjectIdentifier] = []
        let coordinator = ProjectWindowCoordinator(saveUnsavedProject: { offered.append(ObjectIdentifier($0)) })
        let id = UUID()
        coordinator.register(try XCTUnwrap(state), id: id, sourceURL: nil)
        coordinator.windowClosed(id)
        state = nil

        await coordinator.prepareToQuit()
        XCTAssertNotNil(retained, "A closed window must retain its failed-save design until quit")
        XCTAssertEqual(retained?.prompt, "Latest unsaved draft")
        XCTAssertEqual(offered, [identity])
        await coordinator.prepareToQuit()
        XCTAssertEqual(offered, [identity], "Repeated termination requests must not duplicate the save panel")
    }

    @MainActor
    func testClosingASharedViewDoesNotSaveOrPromptUntilItsLastViewCloses() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        var saves = 0, prompts = 0
        let closed = expectation(description: "Last view saved")
        let coordinator = ProjectWindowCoordinator(closeSession: {
            saves += 1
            await $0.prepareToQuit()
            closed.fulfill()
        }, saveUnsavedProject: { _ in prompts += 1 })
        let first = UUID(), second = UUID()
        coordinator.register(state, id: first, sourceURL: nil)
        coordinator.register(state, id: second, sourceURL: nil)
        coordinator.windowClosed(first)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(prompts, 0)
        coordinator.windowClosed(second)
        await fulfillment(of: [closed], timeout: 3)
        await coordinator.prepareToQuit()
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(prompts, 1)
    }

    @MainActor
    func testQuitWaitsForAnInFlightClosingSaveBeforeOfferingItsUnsavedState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let gate = AsyncStream<Void>.makeStream()
        let started = expectation(description: "Closing save started")
        var prompts = 0
        let coordinator = ProjectWindowCoordinator(closeSession: {
            started.fulfill()
            for await _ in gate.stream { break }
            await $0.prepareToQuit()
        }, saveUnsavedProject: {
            XCTAssertTrue($0 === state)
            XCTAssertTrue($0.hasUnsavedChanges)
            prompts += 1
        })
        let id = UUID()
        coordinator.register(state, id: id, sourceURL: nil)
        coordinator.windowClosed(id)
        await fulfillment(of: [started], timeout: 3)
        let quitting = Task { await coordinator.prepareToQuit() }
        await Task.yield()
        XCTAssertEqual(prompts, 0)
        gate.continuation.finish()
        await quitting.value
        XCTAssertEqual(prompts, 1)
    }

    @MainActor
    func testReopeningAFailedSaveReusesItsLatestStateInsteadOfReadingStaleBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let source = fixture.directory.appendingPathComponent("Original.lad")
        let closed = expectation(description: "Failed closing save completed")
        var prompts = 0, saves = 0
        let coordinator = ProjectWindowCoordinator(closeSession: {
            await $0.prepareToQuit()
            saves += 1
            if saves == 1 { closed.fulfill() }
        }, saveUnsavedProject: { _ in prompts += 1 })
        let id = UUID()
        coordinator.register(state, id: id, sourceURL: source)
        coordinator.windowClosed(id)
        await fulfillment(of: [closed], timeout: 3)
        let opened = expectation(description: "Retained design reopened")
        let session = ProjectWindowSession()
        coordinator.openProject(at: source) { request in
            coordinator.register(session, id: request.id, sourceURL: request.fileURL)
            opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 3)
        XCTAssertTrue(session.state === state)
        XCTAssertEqual(session.state.prompt, "Latest unsaved draft")
        XCTAssertTrue(session.state.hasUnsavedChanges)
        // A reattached design is now an ordinary open session and must appear
        // just once in quit recovery, even after sharing its old source alias.
        await coordinator.prepareToQuit()
        XCTAssertEqual(prompts, 1)
    }

    @MainActor
    func testSuccessfulFinalAutosaveDoesNotOfferAQuitSavePanel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.saveDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: false)
        let state = fixture.state()
        var prompts = 0
        let coordinator = ProjectWindowCoordinator(saveUnsavedProject: { _ in prompts += 1 })
        coordinator.register(state, id: UUID(), sourceURL: nil)
        await coordinator.prepareToQuit()
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(try ProjectStore.read(from: XCTUnwrap(state.projectURL)).draftPrompt, state.prompt)
    }

    @MainActor
    func testDroppingARetainedDesignReleasesItsFormerManagedPathAfterRename() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let incoming = fixture.state()
        let oldURL = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Retained old name.lad")
        let newURL = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Retained new name.lad")
        incoming.projectURL = oldURL
        let receiver = ProjectWindowSession(state: fixture.state())
        let closed = expectation(description: "Failed closing save completed")
        var saves = 0
        let coordinator = ProjectWindowCoordinator(closeSession: {
            await $0.prepareToQuit()
            saves += 1
            if saves == 1 { closed.fulfill() }
        }, saveUnsavedProject: { _ in }, readProject: { _ in
            XCTFail("A retained design must be reused without rereading disk")
            throw LADError.message("Unexpected disk read")
        }, flushProject: { _ in })
        let incomingID = UUID(), receiverID = UUID()
        coordinator.register(incoming, id: incomingID, sourceURL: oldURL)
        coordinator.register(receiver, id: receiverID, sourceURL: nil)
        coordinator.windowClosed(incomingID)
        await fulfillment(of: [closed], timeout: 3)

        let replaced = expectation(description: "Retained design adopted")
        let observation = receiver.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: oldURL, in: receiverID)
        await fulfillment(of: [replaced], timeout: 3)
        XCTAssertTrue(receiver.state === incoming)
        incoming.projectURL = newURL
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: oldURL) { requests.append($0) }
        XCTAssertEqual(requests.count, 1, "The old managed path may now refer to a different design")
        await coordinator.prepareToQuit()
        withExtendedLifetime(observation) {}
    }

    private struct Fixture {
        let directory: URL
        let saveDirectory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-closed-unsaved-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            saveDirectory = directory.appendingPathComponent("missing-parent/LAD", isDirectory: true)
        }

        @MainActor
        func state() -> AppState {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: saveDirectory))
            state.start(restoringRecent: false)
            state.prompt = "Latest unsaved draft"
            return state
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
