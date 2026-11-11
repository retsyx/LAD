import XCTest
@testable import LAD

final class ConversationProgressTests: XCTestCase {
    @MainActor
    func testToolOnlyFeedbackDoesNotRequirePublishingConversation() {
        let feedback = CodexConversationFeedback()
        var messages = [ChatMessage(role: "user", content: "Inspect the design")]
        let original = messages
        feedback.enqueue(ProjectActivityEvent(id: "inspect", category: "tool", title: "lad_inspect", status: "completed"), scope: "project")
        let update = feedback.apply(to: &messages)
        XCTAssertTrue(update.changed)
        XCTAssertFalse(update.messagesChanged)
        XCTAssertEqual(update.events.map(\.id), ["project:inspect"])
        XCTAssertEqual(messages, original)
    }

    @MainActor
    func testCommentaryUpdatesOneCopyableHistoryItemWithoutChangingItsIdentity() {
        let feedback = CodexConversationFeedback()
        var messages = [ChatMessage(role: "user", content: "Create an enclosure")]
        feedback.enqueue(CodexProgressMessage(id: "plan", text: "I’ll inspect the PCB and design a fitted enclosure."), scope: "project")
        XCTAssertTrue(feedback.apply(to: &messages).changed)
        let original = messages[1]
        XCTAssertEqual(original.role, "assistant")
        XCTAssertEqual(original.phase, "commentary")

        let complete = "I’ll inspect the PCB and design a fitted enclosure with aligned connector openings."
        feedback.enqueue(CodexProgressMessage(id: "plan", text: complete), scope: "project")
        XCTAssertTrue(feedback.apply(to: &messages).changed)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].content, complete)
        XCTAssertEqual(messages[1].id, original.id)
        XCTAssertEqual(messages[1].date, original.date)
        feedback.enqueue(CodexProgressMessage(id: "plan", text: complete), scope: "project")
        XCTAssertFalse(feedback.apply(to: &messages).changed)
    }

    @MainActor
    func testPendingSnapshotsCoalesceAndRepairItemIDsDoNotOverwriteInitialUpdates() {
        let feedback = CodexConversationFeedback()
        var messages: [ChatMessage] = []
        feedback.enqueue(CodexProgressMessage(id: "item_1", text: "Inspecting the board."), scope: "project")
        feedback.enqueue(CodexProgressMessage(id: "item_1", text: "The board outline and connector positions are confirmed."), scope: "project")
        feedback.enqueue(CodexProgressMessage(id: "item_2", text: "I’m adding the base and lid."), scope: "project")
        _ = feedback.apply(to: &messages)
        XCTAssertEqual(messages.map(\.content), ["The board outline and connector positions are confirmed.", "I’m adding the base and lid."])
        feedback.enqueue(CodexProgressMessage(id: "item_1", text: "I’ll reduce the fillet radius to fix the failing operation."), scope: "repair")
        _ = feedback.apply(to: &messages)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(Set(messages.map(\.id)).count, 3)
        XCTAssertEqual(messages[0].content, "The board outline and connector positions are confirmed.")
    }

    @MainActor
    func testFinalDrainPreservesUpdatesBeforeOutcomeAndRejectsLateCallbacks() throws {
        let feedback = CodexConversationFeedback()
        var messages = [ChatMessage(role: "user", content: "Create a bracket")]
        feedback.enqueue(CodexProgressMessage(id: "plan", text: "I’ll create the bracket and its mounting holes."), scope: "project")
        feedback.enqueueActivity("Building solid geometry…")
        let drained = feedback.apply(to: &messages)
        XCTAssertEqual(drained.activity, "Building solid geometry…")
        feedback.close()
        messages.append(ChatMessage(role: "assistant", content: "Created the bracket.\n\nModel ready.", phase: "final_answer"))
        feedback.enqueue(CodexProgressMessage(id: "late", text: "An outdated update."), scope: "project")
        feedback.enqueueActivity("An outdated activity")
        let late = feedback.apply(to: &messages)
        XCTAssertFalse(late.changed)
        XCTAssertNil(late.activity)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.map(\.phase), [nil, "commentary", "final_answer"])

        let project = LADProject(messages: messages, revisions: [], selectedRevisionID: nil)
        let restored = try ProjectStore.decode(ProjectStore.encode(project))
        XCTAssertEqual(restored.messages, messages)
    }

    @MainActor
    func testRepeatedConsecutiveCommentaryDoesNotFloodConversation() {
        let feedback = CodexConversationFeedback()
        var messages: [ChatMessage] = []
        for id in ["a", "b", "c"] {
            feedback.enqueue(CodexProgressMessage(id: id, text: "I’m checking the connector clearances."), scope: "project")
            _ = feedback.apply(to: &messages)
        }
        XCTAssertEqual(messages.count, 1)
        feedback.enqueue(CodexProgressMessage(id: "c", text: "The connectors have sufficient plug clearance."), scope: "project")
        _ = feedback.apply(to: &messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.content, "I’m checking the connector clearances.")
    }
}
