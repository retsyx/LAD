import Combine
import Foundation
import XCTest
@testable import LAD

final class ProjectWindowTests: XCTestCase {
    @MainActor
    func testRecentProjectRestoreCanOnlyBeClaimedOnce() {
        let coordinator = ProjectWindowCoordinator()
        XCTAssertTrue(coordinator.claimInitialRestore())
        XCTAssertFalse(coordinator.claimInitialRestore())
        coordinator.windowClosed(UUID())
        XCTAssertFalse(coordinator.claimInitialRestore())
    }

    func testWindowRequestsHaveIndependentIdentityAndRoundtripFileLocation() throws {
        let file = URL(fileURLWithPath: "/tmp/Window design.lad")
        let first = ProjectWindowRequest(fileURL: file)
        let second = ProjectWindowRequest(fileURL: file)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second)
        let restored = try JSONDecoder().decode(ProjectWindowRequest.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(restored, first)
        XCTAssertEqual(restored.fileURL, file)
    }

    @MainActor
    func testPendingAndLoadingFileRequestsDeduplicateCanonicalPaths() {
        let coordinator = ProjectWindowCoordinator()
        let source = URL(fileURLWithPath: "/tmp/LAD-window-tests/Design.lad")
        let alias = URL(fileURLWithPath: "/tmp/LAD-window-tests/unused/../Design.lad")
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        coordinator.openProject(at: alias) { requests.append($0) }
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.fileURL, ProjectFileOrigin.canonicalURL(source))

        let state = AppState()
        state.isWorking = true
        coordinator.register(state, id: request.id, sourceURL: source)
        coordinator.openProject(at: alias) { requests.append($0) }
        XCTAssertEqual(requests.count, 1)
        coordinator.windowClosed(request.id)
    }

    @MainActor
    func testRenamingReleasesFormerPathsInDefaultAndExternalFolders() {
        let coordinator = ProjectWindowCoordinator()
        let old = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Old name.lad")
        let renamed = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("New name.lad")
        let managed = AppState()
        managed.projectURL = old
        let managedID = UUID()
        coordinator.register(managed, id: managedID, sourceURL: old)
        managed.projectURL = renamed
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: renamed) { requests.append($0) }
        XCTAssertTrue(requests.isEmpty)
        coordinator.openProject(at: old) { requests.append($0) }
        XCTAssertEqual(requests.count, 1, "A former managed path may now identify a different design")

        let imported = AppState()
        let source = URL(fileURLWithPath: "/tmp/Imported window design.lad")
        imported.projectURL = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Imported copy.lad")
        let importedID = UUID()
        coordinator.register(imported, id: importedID, sourceURL: source)
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertEqual(requests.count, 2, "A former external filename may now identify a different design")
        coordinator.windowClosed(managedID)
        coordinator.windowClosed(importedID)
    }

    @MainActor
    func testClosingOneWindowCancelsOnlyItsWorkAndQuitWaitsForAllSessions() async {
        let coordinator = ProjectWindowCoordinator()
        let first = state(prompt: "First design"), second = state(prompt: "Second design")
        let firstID = UUID(), secondID = UUID()
        coordinator.register(first, id: firstID, sourceURL: nil)
        coordinator.register(second, id: secondID, sourceURL: nil)
        first.isWorking = true
        second.isWorking = true
        coordinator.windowClosed(firstID)

        XCTAssertFalse(first.isWorking)
        XCTAssertTrue(second.isWorking, "Closing a sibling window must leave this worker running")
        XCTAssertEqual(first.messages.first?.content, "First design")
        XCTAssertEqual(second.messages.first?.content, "Second design")
        await coordinator.prepareToQuit()
        XCTAssertFalse(second.isWorking)
        XCTAssertEqual(first.revisions.count, 1)
        XCTAssertEqual(second.revisions.count, 1)
        XCTAssertEqual(first.messages.count, 1)
        XCTAssertEqual(second.messages.count, 1)
        // A close notification after application-level flushing is harmless.
        coordinator.windowClosed(secondID)
        await coordinator.prepareToQuit()
    }

    @MainActor
    func testClosingAnUnregisteredPendingWindowAllowsOpeningTheFileAgain() {
        let coordinator = ProjectWindowCoordinator()
        let source = URL(fileURLWithPath: "/tmp/Cancelled pending design.lad")
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        coordinator.windowClosed(requests[0].id)
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].id, requests[1].id)
    }

    @MainActor
    func testReopeningWaitsForClosingSaveAndDeduplicatesWhileWaiting() async {
        let gate = AsyncStream<Void>.makeStream()
        let started = expectation(description: "Close save started")
        let opened = expectation(description: "Saved design reopened")
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            started.fulfill()
            for await _ in gate.stream { break }
            await state.prepareToQuit()
        })
        let original = state(prompt: "Latest unsaved change")
        let source = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Waiting design.lad")
        original.projectURL = source
        let id = UUID()
        coordinator.register(original, id: id, sourceURL: source)
        coordinator.windowClosed(id)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0); opened.fulfill() }
        coordinator.openProject(at: source) { requests.append($0); opened.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(requests.isEmpty, "A new window must not read bytes before the close save finishes")

        gate.continuation.yield(())
        gate.continuation.finish()
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNotEqual(requests[0].id, id)
        XCTAssertEqual(requests[0].fileURL, ProjectFileOrigin.canonicalURL(source))
        XCTAssertEqual(original.messages.first?.content, "Latest unsaved change")
    }

    @MainActor
    func testReopeningExternalFileWaitsForItsClosingRename() async {
        let gate = AsyncStream<Void>.makeStream()
        let started = expectation(description: "Close rename started")
        let opened = expectation(description: "Renamed design reopened")
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            started.fulfill()
            for await _ in gate.stream { break }
            await state.prepareToQuit()
        })
        let original = state(prompt: "External design")
        let old = URL(fileURLWithPath: "/tmp/Before rename.lad")
        let renamed = URL(fileURLWithPath: "/tmp/After rename.lad")
        original.projectURL = old
        let id = UUID()
        coordinator.register(original, id: id, sourceURL: old)
        coordinator.windowClosed(id)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: old) { requests.append($0); opened.fulfill() }
        coordinator.openProject(at: old) { requests.append($0); opened.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(requests.isEmpty)
        original.projectURL = renamed
        gate.continuation.yield(())
        gate.continuation.finish()
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].fileURL, ProjectFileOrigin.canonicalURL(renamed))
    }

    @MainActor
    func testQuitDoesNotOpenAWindowQueuedBehindAClosingSave() async {
        let gate = AsyncStream<Void>.makeStream()
        let started = expectation(description: "Close save started")
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            started.fulfill()
            for await _ in gate.stream { break }
            await state.prepareToQuit()
        })
        let original = state(prompt: "Closing design")
        let source = ProjectAutosaveStore.defaultDirectory.appendingPathComponent("Closing design.lad")
        original.projectURL = source
        let id = UUID()
        coordinator.register(original, id: id, sourceURL: source)
        coordinator.windowClosed(id)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        await fulfillment(of: [started], timeout: 2)
        let releasing = Task {
            gate.continuation.yield(())
            gate.continuation.finish()
        }
        await coordinator.prepareToQuit()
        await releasing.value
        await Task.yield()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testWindowSessionForwardsOnlyItsCurrentDocumentChanges() {
        let first = state(prompt: "First"), second = state(prompt: "Second")
        let session = ProjectWindowSession(state: first)
        var changes = 0
        let observation = session.objectWillChange.sink { changes += 1 }
        first.prompt = "Changed first"
        XCTAssertEqual(changes, 1)
        session.state = second
        changes = 0
        first.prompt = "Detached first"
        XCTAssertEqual(changes, 0)
        second.prompt = "Changed second"
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testDropValidatesAndFlushesBeforeReplacingOnlyTheReceivingWindow() async {
        let readGate = AsyncStream<Void>.makeStream()
        let flushGate = AsyncStream<Void>.makeStream()
        let readStarted = expectation(description: "Incoming archive read")
        let flushStarted = expectation(description: "Outgoing design flush")
        let replaced = expectation(description: "Receiving document replaced")
        let source = URL(fileURLWithPath: "/tmp/Dropped design.lad")
        let originalSource = URL(fileURLWithPath: "/tmp/Original design.lad")
        let original = state(prompt: "Preserve outgoing history")
        let sibling = state(prompt: "Keep sibling open")
        let incoming = state(prompt: "Dropped history")
        incoming.projectURL = source
        let session = ProjectWindowSession(state: original)
        let receiverID = UUID(), siblingID = UUID()
        var flushes = 0, loads = 0
        let project = archive(prompt: "Dropped history")
        let coordinator = ProjectWindowCoordinator(readProject: { _ in
            readStarted.fulfill()
            for await _ in readGate.stream { break }
            return project
        }, loadProject: { _, _ in
            loads += 1
            return incoming
        }, flushProject: { state in
            XCTAssertTrue(state === original)
            XCTAssertTrue(session.state === original)
            flushes += 1
            flushStarted.fulfill()
            for await _ in flushGate.stream { break }
        })
        coordinator.register(session, id: receiverID, sourceURL: originalSource)
        coordinator.register(sibling, id: siblingID, sourceURL: nil)
        let observation = session.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: source, in: receiverID)
        await fulfillment(of: [readStarted], timeout: 2)
        XCTAssertTrue(session.state === original)
        XCTAssertEqual(session.sourceURL, ProjectFileOrigin.canonicalURL(originalSource))
        XCTAssertEqual(flushes, 0)
        readGate.continuation.yield(())
        readGate.continuation.finish()
        await fulfillment(of: [flushStarted], timeout: 2)
        XCTAssertTrue(session.state === original)
        XCTAssertEqual(loads, 0)
        flushGate.continuation.yield(())
        flushGate.continuation.finish()
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(session.state === incoming)
        XCTAssertEqual(session.sourceURL, ProjectFileOrigin.canonicalURL(source))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(original.messages.first?.content, "Preserve outgoing history")
        XCTAssertEqual(sibling.messages.first?.content, "Keep sibling open")
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertTrue(requests.isEmpty)
        coordinator.openProject(at: originalSource) { requests.append($0) }
        XCTAssertEqual(requests.count, 1, "Successful replacement releases the outgoing source alias")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testInvalidDroppedArchivePreservesTheReceivingProjectAndReleasesReservation() async {
        let original = state(prompt: "Original validated design")
        let session = ProjectWindowSession(state: original)
        let id = UUID()
        let source = URL(fileURLWithPath: "/tmp/Broken dropped design.lad")
        let originalSource = URL(fileURLWithPath: "/tmp/Current design.lad")
        let failed = expectation(description: "Invalid archive reported")
        var flushes = 0, loads = 0
        let coordinator = ProjectWindowCoordinator(readProject: { _ in
            throw LADError.message("Invalid ZIP archive")
        }, loadProject: { _, _ in
            loads += 1
            return AppState()
        }, flushProject: { _ in flushes += 1 })
        coordinator.register(session, id: id, sourceURL: originalSource)
        let observation = original.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        coordinator.replaceProject(at: source, in: id)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(session.state === original)
        XCTAssertEqual(session.sourceURL, ProjectFileOrigin.canonicalURL(originalSource))
        XCTAssertEqual(original.messages.first?.content, "Original validated design")
        XCTAssertTrue(original.error?.contains("Invalid ZIP archive") == true)
        XCTAssertEqual(flushes, 0)
        XCTAssertEqual(loads, 0)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertEqual(requests.count, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testDroppingAStillLoadingInvalidProjectDoesNotReplaceTheReceiver() async {
        let original = state(prompt: "Preserve receiving design")
        let loading = AppState()
        let source = URL(fileURLWithPath: "/tmp/Still loading invalid design.lad")
        let session = ProjectWindowSession(state: original)
        let receiverID = UUID(), loadingID = UUID()
        let failed = expectation(description: "Unvalidated target rejected")
        let coordinator = ProjectWindowCoordinator(readProject: { _ in
            throw LADError.message("Unreadable design archive")
        }, flushProject: { _ in XCTFail("Unvalidated target must not flush the receiver") })
        loading.isWorking = true
        coordinator.register(loading, id: loadingID, sourceURL: source)
        coordinator.register(session, id: receiverID, sourceURL: nil)
        let observation = original.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        coordinator.replaceProject(at: source, in: receiverID)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(session.state === original)
        XCTAssertTrue(loading.isWorking)
        XCTAssertTrue(original.error?.contains("Unreadable design archive") == true)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testValidatedDropFinishesAnExistingInitialLoadBeforeSharingThatDocument() async {
        let original = state(prompt: "Receiving design")
        let loading = AppState()
        let source = URL(fileURLWithPath: "/tmp/Initially loading dropped design.lad")
        let receiver = ProjectWindowSession(state: original)
        let other = ProjectWindowSession(state: loading)
        let receiverID = UUID(), otherID = UUID()
        let project = archive(prompt: "Validated incoming history")
        let replaced = expectation(description: "Validated document shared")
        var initializations = 0, flushes = 0
        let coordinator = ProjectWindowCoordinator(readProject: { _ in project }, loadProject: { _, _ in
            XCTFail("An existing initial load must retain one shared document state")
            return AppState()
        }, loadExistingProject: { target, validated, url in
            XCTAssertTrue(target === loading)
            XCTAssertTrue(receiver.state === original)
            XCTAssertEqual(validated.messages.first?.content, "Validated incoming history")
            target.cancel()
            target.messages = validated.messages
            target.revisions = validated.revisions
            target.selectedRevisionID = validated.selectedRevisionID
            target.projectURL = url
            initializations += 1
        }, flushProject: { state in
            XCTAssertTrue(state === original)
            flushes += 1
        })
        loading.isWorking = true
        coordinator.register(other, id: otherID, sourceURL: source)
        coordinator.register(receiver, id: receiverID, sourceURL: nil)
        let observation = receiver.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: source, in: receiverID)
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(receiver.state === loading)
        XCTAssertTrue(other.state === loading)
        XCTAssertFalse(loading.isWorking, "Completing the validated load cancels the stale original read")
        XCTAssertEqual(receiver.state.messages.first?.content, "Validated incoming history")
        XCTAssertEqual(receiver.state.revisions.count, 1)
        XCTAssertEqual(initializations, 1)
        XCTAssertEqual(flushes, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testDroppingAClosingUnvalidatedArchiveReadsItBeforeFlushingTheReceiver() async {
        let gate = AsyncStream<Void>.makeStream()
        let closing = expectation(description: "Initial load closing")
        let failed = expectation(description: "Invalid closing archive reported")
        let original = state(prompt: "Preserve outgoing history")
        let loading = AppState()
        let source = URL(fileURLWithPath: "/tmp/Closing invalid initial load.lad")
        let receiver = ProjectWindowSession(state: original)
        let receiverID = UUID(), loadingID = UUID()
        var flushes = 0
        let coordinator = ProjectWindowCoordinator(closeSession: { _ in
            closing.fulfill()
            for await _ in gate.stream { break }
        }, readProject: { _ in
            throw LADError.message("Corrupt closing archive")
        }, loadProject: { _, _ in
            XCTFail("A corrupt closing design cannot be loaded")
            return AppState()
        }, loadExistingProject: { _, _, _ in
            XCTFail("A corrupt closing design cannot initialize another document")
        }, flushProject: { _ in flushes += 1 })
        loading.isWorking = true
        coordinator.register(loading, id: loadingID, sourceURL: source)
        coordinator.register(receiver, id: receiverID, sourceURL: nil)
        coordinator.windowClosed(loadingID)
        await fulfillment(of: [closing], timeout: 2)
        let observation = original.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        coordinator.replaceProject(at: source, in: receiverID)
        await Task.yield()
        XCTAssertTrue(receiver.state === original)
        XCTAssertEqual(flushes, 0)
        gate.continuation.yield(())
        gate.continuation.finish()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(receiver.state === original)
        XCTAssertEqual(original.messages.first?.content, "Preserve outgoing history")
        XCTAssertTrue(original.error?.contains("Corrupt closing archive") == true)
        XCTAssertEqual(flushes, 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testInitialTargetClosingDuringReceiverFlushCannotCommitItsEmptyState() async {
        let flushGate = AsyncStream<Void>.makeStream()
        let closeGate = AsyncStream<Void>.makeStream()
        let flushing = expectation(description: "Receiver flushing after validation")
        let closing = expectation(description: "Initial target closing")
        let replaced = expectation(description: "Validated archive loaded")
        let original = state(prompt: "Receiving history")
        let loading = AppState()
        let source = URL(fileURLWithPath: "/tmp/Target closes during drop flush.lad")
        let incoming = state(prompt: "Validated incoming history")
        incoming.projectURL = source
        let project = archive(prompt: "Validated incoming history")
        let receiver = ProjectWindowSession(state: original)
        let receiverID = UUID(), loadingID = UUID()
        var loads = 0
        let coordinator = ProjectWindowCoordinator(closeSession: { _ in
            closing.fulfill()
            for await _ in closeGate.stream { break }
        }, readProject: { _ in project }, loadProject: { validated, _ in
            XCTAssertEqual(validated.messages.first?.content, "Validated incoming history")
            loads += 1
            return incoming
        }, loadExistingProject: { _, _, _ in
            XCTFail("A closed empty state is not an open document to share")
        }, flushProject: { _ in
            flushing.fulfill()
            for await _ in flushGate.stream { break }
        })
        loading.isWorking = true
        coordinator.register(loading, id: loadingID, sourceURL: source)
        coordinator.register(receiver, id: receiverID, sourceURL: nil)
        let observation = receiver.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: source, in: receiverID)
        await fulfillment(of: [flushing], timeout: 2)
        coordinator.windowClosed(loadingID)
        await fulfillment(of: [closing], timeout: 2)
        flushGate.continuation.yield(())
        flushGate.continuation.finish()
        await Task.yield()
        XCTAssertTrue(receiver.state === original)
        closeGate.continuation.yield(())
        closeGate.continuation.finish()
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(receiver.state === incoming)
        XCTAssertFalse(receiver.state === loading)
        XCTAssertEqual(receiver.state.messages.first?.content, "Validated incoming history")
        XCTAssertEqual(loads, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testOutgoingSaveFailurePreventsDropCommit() async {
        let original = state(prompt: "Unsaved work")
        let session = ProjectWindowSession(state: original)
        let id = UUID()
        let source = URL(fileURLWithPath: "/tmp/Valid incoming design.lad")
        let failed = expectation(description: "Outgoing save error reported")
        let project = archive(prompt: "Incoming work")
        var loads = 0
        let coordinator = ProjectWindowCoordinator(readProject: { _ in project }, loadProject: { _, _ in
            loads += 1
            return AppState()
        }, flushProject: { _ in throw LADError.message("Disk is full") })
        coordinator.register(session, id: id, sourceURL: nil)
        let observation = original.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        coordinator.replaceProject(at: source, in: id)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(session.state === original)
        XCTAssertNil(session.sourceURL)
        XCTAssertEqual(original.messages.first?.content, "Unsaved work")
        XCTAssertTrue(original.error?.contains("Disk is full") == true)
        XCTAssertEqual(loads, 0)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertEqual(requests.count, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testDroppingAnOpenProjectSharesItsDocumentAndClosingOneViewLeavesItsWorkerRunning() async {
        let original = state(prompt: "Outgoing design")
        let target = state(prompt: "Already open design")
        target.projectURL = URL(fileURLWithPath: "/tmp/Shared dropped design.lad")
        let receiver = ProjectWindowSession(state: original)
        let other = ProjectWindowSession(state: target)
        let receiverID = UUID(), otherID = UUID()
        let replaced = expectation(description: "Open document shared")
        let closed = expectation(description: "Last document view saved")
        var flushes = 0, closes = 0
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            XCTAssertTrue(state === target)
            closes += 1
            closed.fulfill()
        }, readProject: { _ in
            XCTFail("An already-open design must use its live document")
            return LADProject(messages: [], revisions: [], selectedRevisionID: nil)
        }, flushProject: { state in
            XCTAssertTrue(state === original)
            flushes += 1
        })
        coordinator.register(receiver, id: receiverID, sourceURL: nil)
        coordinator.register(other, id: otherID, sourceURL: target.projectURL)
        target.isWorking = true
        let observation = receiver.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: target.projectURL!, in: receiverID)
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(receiver.state === target)
        XCTAssertTrue(other.state === target)
        XCTAssertTrue(target.isWorking)
        XCTAssertEqual(flushes, 1)
        coordinator.windowClosed(otherID)
        await Task.yield()
        XCTAssertTrue(target.isWorking, "Closing one shared view must not cancel its document")
        XCTAssertEqual(closes, 0)
        coordinator.windowClosed(receiverID)
        XCTAssertFalse(target.isWorking)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(closes, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testLeavingOneSharedViewDoesNotFlushOrCancelTheDocumentStillOpenElsewhere() async {
        let shared = state(prompt: "Shared outgoing design")
        let receiver = ProjectWindowSession(state: shared)
        let sibling = ProjectWindowSession(state: shared)
        let receiverID = UUID(), siblingID = UUID()
        let source = URL(fileURLWithPath: "/tmp/New incoming design.lad")
        let incoming = state(prompt: "Incoming design")
        incoming.projectURL = source
        let project = archive(prompt: "Incoming design")
        let replaced = expectation(description: "One view replaced")
        var flushes = 0, closes: [ObjectIdentifier: Int] = [:]
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            closes[ObjectIdentifier(state), default: 0] += 1
        }, readProject: { _ in project }, loadProject: { _, _ in incoming }, flushProject: { _ in flushes += 1 })
        coordinator.register(receiver, id: receiverID, sourceURL: nil)
        coordinator.register(sibling, id: siblingID, sourceURL: nil)
        shared.isWorking = true
        let observation = receiver.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: source, in: receiverID)
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(receiver.state === incoming)
        XCTAssertTrue(sibling.state === shared)
        XCTAssertTrue(shared.isWorking)
        XCTAssertEqual(flushes, 0)
        await coordinator.prepareToQuit()
        XCTAssertEqual(closes[ObjectIdentifier(shared)], 1)
        XCTAssertEqual(closes[ObjectIdentifier(incoming)], 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testQuittingSavesASharedDocumentOnlyOnce() async {
        let shared = state(prompt: "Shared document")
        var closes = 0
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            XCTAssertTrue(state === shared)
            closes += 1
        })
        coordinator.register(ProjectWindowSession(state: shared), id: UUID(), sourceURL: nil)
        coordinator.register(ProjectWindowSession(state: shared), id: UUID(), sourceURL: nil)
        shared.isWorking = true
        await coordinator.prepareToQuit()
        XCTAssertFalse(shared.isWorking)
        XCTAssertEqual(closes, 1)
        await coordinator.prepareToQuit()
        XCTAssertEqual(closes, 1)
    }

    @MainActor
    func testSupersededDropCannotCommitOrClearTheNewDropReservation() async {
        let gate = AsyncStream<Void>.makeStream()
        let readStarted = expectation(description: "First drop read started")
        let secondReadStarted = expectation(description: "Second drop read started")
        let secondGate = AsyncStream<Void>.makeStream()
        let replaced = expectation(description: "Latest drop committed")
        let firstURL = URL(fileURLWithPath: "/tmp/First drop.lad")
        let secondURL = URL(fileURLWithPath: "/tmp/Second drop.lad")
        let firstProject = archive(prompt: "First"), secondProject = archive(prompt: "Second")
        let original = state(prompt: "Original")
        let incoming = state(prompt: "Second")
        incoming.projectURL = secondURL
        let session = ProjectWindowSession(state: original)
        let id = UUID()
        var loads: [String] = [], flushes = 0
        let coordinator = ProjectWindowCoordinator(readProject: { url in
            if url.lastPathComponent == firstURL.lastPathComponent {
                readStarted.fulfill()
                for await _ in gate.stream { break }
                return firstProject
            }
            secondReadStarted.fulfill()
            for await _ in secondGate.stream { break }
            return secondProject
        }, loadProject: { project, _ in
            loads.append(project.messages.first?.content ?? "")
            return incoming
        }, flushProject: { _ in flushes += 1 })
        coordinator.register(session, id: id, sourceURL: nil)
        let observation = session.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: firstURL, in: id)
        await fulfillment(of: [readStarted], timeout: 2)
        coordinator.replaceProject(at: secondURL, in: id)
        gate.continuation.yield(())
        gate.continuation.finish()
        await fulfillment(of: [secondReadStarted], timeout: 2)
        XCTAssertTrue(session.state === original)
        XCTAssertTrue(loads.isEmpty)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: secondURL) { requests.append($0) }
        XCTAssertTrue(requests.isEmpty, "A pending drop must own its destination until it finishes")
        secondGate.continuation.yield(())
        secondGate.continuation.finish()
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(session.state === incoming)
        XCTAssertEqual(loads, ["Second"])
        XCTAssertEqual(flushes, 1)
        coordinator.openProject(at: firstURL) { requests.append($0) }
        XCTAssertEqual(requests.count, 1, "The superseded destination is no longer reserved")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testClosingAWindowDuringDropPreventsCommitAndWaitsBeforeClosingSave() async {
        let gate = AsyncStream<Void>.makeStream()
        let readStarted = expectation(description: "Drop read started")
        let closed = expectation(description: "Outgoing document closed")
        let original = state(prompt: "Keep outgoing work")
        let session = ProjectWindowSession(state: original)
        let source = URL(fileURLWithPath: "/tmp/Interrupted drop.lad")
        let project = archive(prompt: "Incoming")
        let id = UUID()
        var loads = 0, closes = 0
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            XCTAssertTrue(state === original)
            closes += 1
            closed.fulfill()
        }, readProject: { _ in
            readStarted.fulfill()
            for await _ in gate.stream { break }
            return project
        }, loadProject: { _, _ in
            loads += 1
            return AppState()
        }, flushProject: { _ in XCTFail("A canceled drop must not flush for replacement") })
        coordinator.register(session, id: id, sourceURL: nil)
        coordinator.replaceProject(at: source, in: id)
        await fulfillment(of: [readStarted], timeout: 2)
        coordinator.windowClosed(id)
        gate.continuation.yield(())
        gate.continuation.finish()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertTrue(session.state === original)
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(closes, 1)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testDropWaitsForClosingProjectSaveAndUsesItsFinalRenamedState() async {
        let gate = AsyncStream<Void>.makeStream()
        let closeStarted = expectation(description: "Target close started")
        let replaced = expectation(description: "Closing target shared")
        let target = state(prompt: "Latest target edits")
        let source = URL(fileURLWithPath: "/tmp/Before drop rename.lad")
        let renamed = URL(fileURLWithPath: "/tmp/After drop rename.lad")
        target.projectURL = source
        let session = ProjectWindowSession(state: state(prompt: "Receiving design"))
        let targetID = UUID(), receiverID = UUID()
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            closeStarted.fulfill()
            for await _ in gate.stream { break }
            state.projectURL = renamed
        }, readProject: { _ in
            XCTFail("The closing document already has the newest saved state")
            return LADProject(messages: [], revisions: [], selectedRevisionID: nil)
        }, flushProject: { _ in })
        coordinator.register(target, id: targetID, sourceURL: source)
        coordinator.register(session, id: receiverID, sourceURL: nil)
        coordinator.windowClosed(targetID)
        await fulfillment(of: [closeStarted], timeout: 2)
        let observation = session.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: source, in: receiverID)
        await Task.yield()
        XCTAssertFalse(session.state === target)
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertTrue(requests.isEmpty)
        gate.continuation.yield(())
        gate.continuation.finish()
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(session.state === target)
        XCTAssertEqual(session.sourceURL, ProjectFileOrigin.canonicalURL(renamed))
        XCTAssertEqual(session.state.messages.first?.content, "Latest target edits")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testSimultaneousDropsOfOneFileConvergeOnOneDocumentWriter() async {
        let first = ProjectWindowSession(state: state(prompt: "First outgoing"))
        let second = ProjectWindowSession(state: state(prompt: "Second outgoing"))
        let firstID = UUID(), secondID = UUID()
        let source = URL(fileURLWithPath: "/tmp/Simultaneous drops.lad")
        let project = archive(prompt: "Shared incoming")
        let flushGate = AsyncStream<Void>.makeStream()
        let flushing = expectation(description: "Both outgoing documents flushing")
        flushing.expectedFulfillmentCount = 2
        let replaced = expectation(description: "Both windows replaced")
        replaced.expectedFulfillmentCount = 2
        var loads = 0
        let coordinator = ProjectWindowCoordinator(readProject: { _ in project }, loadProject: { _, url in
            loads += 1
            let incoming = AppState()
            incoming.projectURL = url
            return incoming
        }, flushProject: { _ in
            flushing.fulfill()
            for await _ in flushGate.stream { break }
        })
        coordinator.register(first, id: firstID, sourceURL: nil)
        coordinator.register(second, id: secondID, sourceURL: nil)
        let firstObservation = first.$state.dropFirst().sink { _ in replaced.fulfill() }
        let secondObservation = second.$state.dropFirst().sink { _ in replaced.fulfill() }
        coordinator.replaceProject(at: source, in: firstID)
        coordinator.replaceProject(at: source, in: secondID)
        await fulfillment(of: [flushing], timeout: 2)
        flushGate.continuation.finish()
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertTrue(first.state === second.state)
        XCTAssertEqual(loads, 1)
        withExtendedLifetime((firstObservation, secondObservation)) {}
    }

    @MainActor
    func testQuittingDuringDropPreservesAndSavesTheOutgoingDocument() async {
        let gate = AsyncStream<Void>.makeStream()
        let readStarted = expectation(description: "Drop read started")
        let original = state(prompt: "Outgoing work")
        let session = ProjectWindowSession(state: original)
        let source = URL(fileURLWithPath: "/tmp/Quit interrupted drop.lad")
        let project = archive(prompt: "Incoming work")
        let id = UUID()
        var loads = 0, closes = 0
        let coordinator = ProjectWindowCoordinator(closeSession: { state in
            XCTAssertTrue(state === original)
            closes += 1
        }, readProject: { _ in
            readStarted.fulfill()
            for await _ in gate.stream { break }
            return project
        }, loadProject: { _, _ in
            loads += 1
            return AppState()
        }, flushProject: { _ in XCTFail("Quitting must not commit an unfinished drop") })
        coordinator.register(session, id: id, sourceURL: nil)
        coordinator.replaceProject(at: source, in: id)
        await fulfillment(of: [readStarted], timeout: 2)
        let releasing = Task {
            gate.continuation.yield(())
            gate.continuation.finish()
        }
        await coordinator.prepareToQuit()
        await releasing.value
        XCTAssertTrue(session.state === original)
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(original.messages.first?.content, "Outgoing work")
        var requests: [ProjectWindowRequest] = []
        coordinator.openProject(at: source) { requests.append($0) }
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    private func archive(prompt: String) -> LADProject {
        let source = state(prompt: prompt)
        return LADProject(messages: source.messages, revisions: source.revisions, selectedRevisionID: source.selectedRevisionID)
    }

    @MainActor
    private func state(prompt: String) -> AppState {
        let state = AppState()
        state.messages = [ChatMessage(role: "user", content: prompt)]
        let revision = ProjectRevision(model: .bracket)
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        return state
    }
}
