import CryptoKit
import XCTest
@testable import LAD

final class ProjectRequestQueueStorageTests: XCTestCase {
    func testQueueOrderDraftAndCapturedChoicesRoundTripWithoutDuplicatingSourceBytes() throws {
        let text = "# complete reference source\nresult = cq.Solid.makeBox(2, 3, 4)\n"
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let input = SourceAttachment(name: "reference.py", path: "/original/reference.py", content: text, sha256: digest)
        let settings = CodexProjectSettings(model: "captured-model", reasoningEffort: "high", reasoningByModel: ["captured-model": "high"])
        let first = ProjectQueuedRequest(content: "Add a lid", attachments: [input], codexSettings: settings)
        let second = ProjectQueuedRequest(content: "Round the corners", attachments: [input], codexSettings: settings)
        var project = LADProject(messages: [ChatMessage(role: "user", content: "Use this reference", attachments: [input])],
                                 revisions: [], selectedRevisionID: nil)
        project.queuedRequests = [second, first]
        project.draftPrompt = "Add clearance around /original/reference.py"
        project.draftAttachments = [input]
        project.queuePaused = true
        let bytes = try ProjectStore.encode(project)
        let reopened = try ProjectStore.decode(bytes)
        XCTAssertEqual(reopened.queuedRequests, [second, first])
        XCTAssertEqual(reopened.draftPrompt, project.draftPrompt)
        XCTAssertEqual(reopened.draftAttachments, [input])
        XCTAssertEqual(reopened.queuePaused, true)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
        let assets = try XCTUnwrap(manifest["assets"] as? [String: String])
        XCTAssertEqual(assets.count, 1, "Sent, queued and draft references must share one exact source snapshot.")
        XCTAssertEqual(assets[digest], Data(text.utf8).base64EncodedString())
        let queue = try XCTUnwrap(manifest["queuedRequests"] as? [[String: Any]])
        let attachment = try XCTUnwrap((queue[0]["attachments"] as? [[String: Any]])?.first)
        XCTAssertNil(attachment["content"])
        XCTAssertEqual(attachment["contentAsset"] as? String, digest)
    }

    func testInvalidQueuedPayloadsAndChoicesCannotBeSaved() throws {
        var project = LADProject(messages: [], revisions: [], selectedRevisionID: nil)
        let request = ProjectQueuedRequest(content: "Add a lid")
        project.queuedRequests = [request, request]
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project.queuedRequests = [ProjectQueuedRequest(content: " \n")]
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project.queuedRequests = [ProjectQueuedRequest(content: "Add a lid", codexSettings: CodexProjectSettings(model: "invalid\nmodel", reasoningEffort: "high"))]
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project.queuedRequests = [ProjectQueuedRequest(content: "Add a lid", attachments: [
            SourceAttachment(name: "source.py", path: "/source.py", content: "changed source", sha256: "wrong")
        ])]
        XCTAssertThrowsError(try ProjectStore.encode(project))
    }

    func testSupplementalMessagesRemainLinkedToTheirTaskAndSaveNewOmitsPendingWork() throws {
        let user = ChatMessage(role: "user", content: "Create a bracket")
        let supplement = ChatMessage(role: "user", content: "Use 2 mm walls")
        let response = ChatMessage(role: "assistant", content: "Bracket completed", phase: "final_answer")
        let revision = ProjectRevision(model: .bracket, userMessageID: user.id, responseMessageID: response.id)
        let audit = ProjectTaskAudit(userMessageID: user.id, model: "cad", reasoningEffort: "high", status: "completed",
                                     additionalUserMessageIDs: [supplement.id])
        var project = LADProject(messages: [user, supplement, response], revisions: [revision], selectedRevisionID: revision.id)
        project.taskAudits = [audit]
        project.queuedRequests = [ProjectQueuedRequest(content: "Add a second part")]
        project.draftPrompt = "Another draft"
        let restored = try ProjectStore.decode(ProjectStore.encode(project))
        XCTAssertEqual(restored.taskAudits?.first?.additionalUserMessageIDs, [supplement.id])
        let copy = try SaveNewProject.snapshot(from: restored)
        XCTAssertTrue(copy.messages.isEmpty)
        XCTAssertNil(copy.queuedRequests)
        XCTAssertNil(copy.draftPrompt)
        XCTAssertNil(copy.draftAttachments)
        XCTAssertNil(copy.taskAudits)
        XCTAssertNoThrow(try ProjectStore.encode(copy))
        project.taskAudits?[0].additionalUserMessageIDs = [response.id]
        XCTAssertThrowsError(try ProjectStore.encode(project), "A supplemental input must reference an actual user message.")
    }
}
