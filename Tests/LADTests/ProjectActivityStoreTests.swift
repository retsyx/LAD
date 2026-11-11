import XCTest
@testable import LAD

final class ProjectActivityStoreTests: XCTestCase {
    @MainActor
    func testAcknowledgedSteeringRemainsLinkedAfterTaskCompletion() throws {
        let store = ProjectActivityStore()
        let userID = UUID(), supplementalID = UUID(), requestID = UUID()
        store.beginCodex(userMessageID: userID, model: "test", effort: "high")
        let taskID = try XCTUnwrap(store.activeTaskID)
        store.record(ProjectActivityEvent(id: "inspect", category: "tool", title: "lad_inspect", status: "running"))
        store.finishActive(status: "completed")
        store.acknowledgeSteering(taskID: taskID, requestID: requestID, messageID: supplementalID,
                                 content: "Keep the mounting holes", turn: "turn-1")
        store.record(ProjectActivityEvent(id: "late", category: "tool", title: "lad_inspect", status: "completed"))
        let task = try XCTUnwrap(store.task(id: taskID))
        XCTAssertNil(store.activeTaskID)
        XCTAssertEqual(task.status, "completed")
        XCTAssertEqual(task.additionalUserMessageIDs, [supplementalID])
        XCTAssertEqual(task.events.map(\.id), ["inspect", "steer:\(requestID.uuidString)"])
        XCTAssertEqual(task.events.map(\.status), ["interrupted", "completed"])
        store.cancelPendingSave()
    }

    @MainActor
    func testRestoreCancelsOldActivitySaveAndClearsActiveTask() async throws {
        let store = ProjectActivityStore()
        var changes = 0
        store.onChange = { changes += 1 }
        let obsoleteSave = expectation(description: "Restoring another design cancels the old activity save")
        obsoleteSave.isInverted = true
        store.onSaveRequested = { obsoleteSave.fulfill() }
        store.beginCodex(userMessageID: UUID(), model: "test", effort: "high")
        let oldID = try XCTUnwrap(store.activeTaskID)
        store.record(ProjectActivityEvent(id: "old", category: "tool", title: "lad_inspect", status: "running"))
        store.restore()
        store.record(ProjectActivityEvent(id: "late", category: "tool", title: "lad_inspect", status: "completed"), taskID: oldID)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(store.activeTaskID)
        XCTAssertTrue(store.tasks.isEmpty)
        await fulfillment(of: [obsoleteSave], timeout: 1.1)
    }
}
