import Combine
import Foundation
import XCTest
@testable import LAD

final class ProjectWindowRestorationTests: XCTestCase {
    @MainActor
    func testRestoredCanonicalFileRegistrationsShareStateBeforeStarting() async {
        let closed = expectation(description: "Shared document closed once")
        let coordinator = ProjectWindowCoordinator(closeSession: { _ in closed.fulfill() })
        let source = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Restored shared design.lad")
        let alias = source.deletingLastPathComponent().appendingPathComponent("unused/../Restored shared design.lad")
        let first = ProjectWindowSession(), second = ProjectWindowSession()
        let firstID = UUID(), secondID = UUID()

        XCTAssertTrue(coordinator.register(first, id: firstID, sourceURL: source))
        XCTAssertFalse(coordinator.register(second, id: secondID, sourceURL: alias))
        XCTAssertTrue(first.state === second.state)
        XCTAssertEqual(second.sourceURL, ProjectFileOrigin.canonicalURL(source))

        first.state.prompt = "Keep the same unsent request in both restored views"
        XCTAssertEqual(second.state.prompt, first.state.prompt)
        first.state.isWorking = true
        coordinator.windowClosed(firstID)
        XCTAssertTrue(second.state.isWorking, "Closing one restored view must leave the shared document running")
        coordinator.windowClosed(secondID)
        XCTAssertFalse(first.state.isWorking)
        await fulfillment(of: [closed], timeout: 2)
    }

    @MainActor
    func testRestoredRegistrationJoinsAnInitialReadAndSharesItsLoadedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-window-restoration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Loading shared design.lad")
        let message = ChatMessage(role: "user", content: "Saved conversation shared by both views")
        let project = LADProject(messages: [message], revisions: [], selectedRevisionID: nil, projectID: UUID())
        try ProjectStore.write(project, to: source)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        let first = ProjectWindowSession(state: state), second = ProjectWindowSession()
        let coordinator = ProjectWindowCoordinator(saveUnsavedProject: { _ in XCTFail("The restored document must save to its existing local folder"); return false })
        let firstID = UUID(), secondID = UUID()
        let loaded = expectation(description: "Initial read completed")
        let observation = state.$messages.filter { $0 == [message] }.prefix(1).sink { _ in loaded.fulfill() }

        XCTAssertTrue(coordinator.register(first, id: firstID, sourceURL: source))
        first.state.start(restoringRecent: false, opening: source)
        XCTAssertTrue(first.state.hasStartedProjectSession)
        XCTAssertTrue(first.state.isWorking)
        XCTAssertFalse(coordinator.register(second, id: secondID, sourceURL: source))
        XCTAssertTrue(second.state === first.state)

        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(second.state.messages, [message])
        XCTAssertEqual(second.state.projectDocumentID, first.state.projectDocumentID)
        second.state.prompt = "A follow-up from the second restored view"
        XCTAssertEqual(first.state.prompt, second.state.prompt)
        await coordinator.prepareToQuit()
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testRestoredRegistrationSharesCurrentFileAndReleasesFormerExternalPath() async {
        let coordinator = ProjectWindowCoordinator(closeSession: { _ in })
        let original = URL(fileURLWithPath: "/tmp/Imported restored shared design.lad")
        let managed = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Restored imported copy.lad")
        let first = ProjectWindowSession(), second = ProjectWindowSession()
        first.state.projectURL = managed
        first.state.messages = [ChatMessage(role: "user", content: "Latest loaded history")]
        let firstID = UUID(), secondID = UUID()

        XCTAssertTrue(coordinator.register(first, id: firstID, sourceURL: original))
        XCTAssertFalse(coordinator.register(second, id: secondID, sourceURL: managed))
        XCTAssertTrue(first.state === second.state)
        XCTAssertEqual(second.state.messages, first.state.messages)
        coordinator.windowClosed(firstID)

        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: original) { requests.append($0) }
        XCTAssertEqual(requests.count, 1, "A former external filename can now contain another design")
        await coordinator.prepareToQuit()
    }

    @MainActor
    func testRegisteringAFormerManagedFilenameAfterRenameKeepsDocumentsIndependent() async {
        let coordinator = ProjectWindowCoordinator(closeSession: { _ in })
        let original = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Restored old filename.lad")
        let renamed = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Restored new filename.lad")
        let first = ProjectWindowSession(), second = ProjectWindowSession()
        first.state.projectURL = renamed

        XCTAssertTrue(coordinator.register(first, id: UUID(), sourceURL: original))
        XCTAssertTrue(coordinator.register(second, id: UUID(), sourceURL: original))
        XCTAssertFalse(first.state === second.state, "A released filename may now contain another document")
        await coordinator.prepareToQuit()
    }

    @MainActor
    func testFailedInitialReadDoesNotPreventRegisteringAFreshRetry() async {
        let coordinator = ProjectWindowCoordinator(closeSession: { _ in })
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-missing-restoration-\(UUID()).lad")
        let first = ProjectWindowSession(), retry = ProjectWindowSession()
        let failed = expectation(description: "Initial read failed")
        let observation = first.state.$error.compactMap { $0 }.prefix(1).sink { _ in failed.fulfill() }
        XCTAssertTrue(coordinator.register(first, id: UUID(), sourceURL: source))
        first.state.start(restoringRecent: false, opening: source)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(first.state.isWorking)

        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertEqual(requests.count, 1)
        if let request = requests.first {
            XCTAssertTrue(coordinator.register(retry, id: request.id, sourceURL: request.fileURL))
            XCTAssertFalse(retry.state === first.state)
        }
        await coordinator.prepareToQuit()
        withExtendedLifetime(observation) {}
    }
}
