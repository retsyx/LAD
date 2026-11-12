import CryptoKit
import XCTest
@testable import LAD

final class ProjectIncrementalValidationTests: XCTestCase {
    private func project() -> LADProject {
        let attachmentText = "print('source')\n"
        let attachment = SourceAttachment(name: "source.py", path: "/missing/source.py", content: attachmentText,
            sha256: SHA256.hash(data: Data(attachmentText.utf8)).map { String(format: "%02x", $0) }.joined())
        let user = ChatMessage(role: "user", content: "Make a box", attachments: [attachment])
        let supplemental = ChatMessage(role: "user", content: "Keep the dimensions")
        let response = ChatMessage(role: "assistant", content: "Ready", phase: "final_answer")
        let revision = ProjectRevision(model: ModelSpec(title: "Box", summary: "A simple box", units: "mm",
            script: "result = cq.Solid.makeBox(1, 2, 3)"),
            parts: [PartNode(id: "body", name: "Body", solidIndices: [0])],
            userMessageID: user.id, responseMessageID: response.id)
        let source = ProjectActivityFile(name: "candidate.py", path: "/private/candidate.py", data: Data(revision.model.script.utf8))
        let event = ProjectActivityEvent(id: "call-1", category: "tool", title: "Build", status: "completed", files: [source])
        let task = ProjectTaskAudit(userMessageID: user.id, model: "test", reasoningEffort: "high", events: [event],
            additionalUserMessageIDs: [supplemental.id])
        return LADProject(messages: [user, supplemental, response], revisions: [revision], selectedRevisionID: revision.id,
            taskAudits: [task], queuedRequests: [ProjectQueuedRequest(content: "Continue", attachments: [attachment])],
            draftAttachments: [attachment])
    }

    private func validate(_ changed: LADProject, after previous: LADProject) throws {
        var verified = [String: Data]()
        try ProjectStore.validate(previous, verifiedAttachmentPayloads: &verified)
        try ProjectStore.validate(changed, verifiedAttachmentPayloads: &verified, validatedPrevious: previous)
    }

    func testAppendingConversationPreservesUnchangedValidatedHistory() throws {
        let previous = project()
        var changed = previous
        changed.messages.append(ChatMessage(role: "assistant", content: "Checking the next change", phase: "commentary"))
        XCTAssertNoThrow(try validate(changed, after: previous))
        var verified = [String: Data]()
        XCTAssertNoThrow(try ProjectStore.validate(changed, verifiedAttachmentPayloads: &verified, validatedPrevious: nil))
    }

    func testMessageChangesRecheckUnchangedRevisionConversationLinks() throws {
        var previous = project()
        previous.taskAudits = nil
        let corruptions: [(inout LADProject) -> Void] = [
            { $0.messages.removeFirst() },
            { $0.messages.swapAt(0, 2) },
            { $0.messages[0].role = "assistant" },
            { $0.messages[2].phase = "commentary" },
            { $0.messages[2].phase = "response" }
        ]
        for corrupt in corruptions {
            var changed = previous
            corrupt(&changed)
            XCTAssertThrowsError(try validate(changed, after: previous))
        }
    }

    func testMessageChangesRecheckUnchangedTaskUserReferences() throws {
        var previous = project()
        previous.revisions = []
        previous.selectedRevisionID = nil
        let corruptions: [(inout LADProject) -> Void] = [
            { $0.messages.removeFirst() },
            { $0.messages.remove(at: 1) },
            { $0.messages[0].role = "assistant" },
            { $0.messages[1].role = "system" }
        ]
        for corrupt in corruptions {
            var changed = previous
            corrupt(&changed)
            XCTAssertThrowsError(try validate(changed, after: previous))
        }
    }

    func testChangedRevisionsStillValidateProgramsPartsAndTransientPayloads() throws {
        let previous = project()
        let corruptions: [(inout ProjectRevision) -> Void] = [
            { $0.model.script = "\0" },
            { $0.model.sourceSTEP = Data("invalid STEP".utf8) },
            { $0.parts![0].solidIndices = [-1] },
            { $0.partLayout = PartLayout(nodes: [PartNode(id: "body", name: "Body", solidIndices: [0])], collapsedNodeIDs: ["body"]) },
            { $0.hiddenSolids = [1] },
            { $0.name = "invalid\nname" }
        ]
        for corrupt in corruptions {
            var changed = previous
            corrupt(&changed.revisions[0])
            XCTAssertThrowsError(try validate(changed, after: previous))
        }
        var changed = previous
        changed.revisions[0].preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1],
            volume: 1, area: 1, solids: 1, faces: 6, buildSeconds: 0, threads: 1, stepPath: "/temporary/model.step")
        XCTAssertThrowsError(try validate(changed, after: previous))
    }

    func testChangedEventsAndTaskMetadataAreNotAuthorizedByTheirIDs() throws {
        let previous = project()
        let corruptions: [(inout ProjectTaskAudit) -> Void] = [
            { $0.events[0].category = "private_reasoning" },
            { $0.events[0].status = "unknown" },
            { $0.events[0].durationSeconds = -1 },
            { $0.events[0].files![0].data = Data([0xff]) },
            { $0.events[0].files![0].name = "geometry.brep" },
            { $0.events.append($0.events[0]) },
            { $0.model = "invalid\nmodel" },
            { $0.additionalUserMessageIDs = [$0.userMessageID!] }
        ]
        for corrupt in corruptions {
            var changed = previous
            corrupt(&changed.taskAudits![0])
            XCTAssertThrowsError(try validate(changed, after: previous))
        }
        var changed = previous
        var second = changed.taskAudits![0]
        second.id = UUID()
        second.events[0].output = "A different task may reuse its own call-1 identifier"
        changed.taskAudits!.append(second)
        XCTAssertNoThrow(try validate(changed, after: previous))
    }

    func testChangedMessagesQueueAndDraftAttachmentsAreValidated() throws {
        let previous = project()
        var renamed = previous
        renamed.draftAttachments![0].name = "unsupported.brep"
        // Portable text snapshots accept generic filenames, independently of
        // the formats supported by the source-file picker.
        XCTAssertNoThrow(try ProjectStore.validate(renamed))
        XCTAssertNoThrow(try validate(renamed, after: previous))
        let corruptions: [(inout LADProject) -> Void] = [
            { $0.messages[0].attachments![0].content = "different bytes with the old digest" },
            { $0.messages[2].phase = "unknown" },
            { $0.queuedRequests![0].content = ""; $0.queuedRequests![0].attachments = nil },
            { $0.queuedRequests![0].attachments![0].sha256 = "invalid" },
            { $0.draftAttachments![0].name = "" },
            { $0.queuedRequests!.append($0.queuedRequests![0]) }
        ]
        for (index, corrupt) in corruptions.enumerated() {
            var changed = previous
            corrupt(&changed)
            XCTAssertThrowsError(try ProjectStore.validate(changed), "Full validation, corruption \(index)")
            XCTAssertThrowsError(try validate(changed, after: previous), "Incremental validation, corruption \(index)")
        }
    }

    func testRemovingRecordsAndNilOrEmptyOptionalCollectionsRemainValid() throws {
        let previous = project()
        var changed = previous
        changed.taskAudits![0].additionalUserMessageIDs = []
        changed.taskAudits![0].events[0].files = []
        changed.queuedRequests = []
        changed.draftAttachments = []
        XCTAssertNoThrow(try validate(changed, after: previous))
        changed.taskAudits![0].additionalUserMessageIDs = nil
        changed.taskAudits![0].events[0].files = nil
        changed.queuedRequests = nil
        changed.draftAttachments = nil
        XCTAssertNoThrow(try validate(changed, after: previous))
        changed.taskAudits = []
        changed.revisions = []
        changed.selectedRevisionID = nil
        changed.messages = []
        XCTAssertNoThrow(try validate(changed, after: previous))
        changed.taskAudits = nil
        XCTAssertNoThrow(try validate(changed, after: previous))
    }

    func testGlobalIdentitySelectionAndAggregateEventLimitsStillApplyToReusedRecords() throws {
        let previous = project()
        let corruptions: [(inout LADProject) -> Void] = [
            { $0.messages.append($0.messages[0]) },
            { $0.revisions.append($0.revisions[0]) },
            { $0.taskAudits!.append($0.taskAudits![0]) },
            { $0.selectedRevisionID = UUID() }
        ]
        for corrupt in corruptions {
            var changed = previous
            corrupt(&changed)
            XCTAssertThrowsError(try validate(changed, after: previous))
        }
        var full = previous
        let events = (0..<50_000).map { ProjectActivityEvent(id: "event-\($0)", category: "tool", title: "Inspect", status: "completed") }
        var first = full.taskAudits![0]
        first.events = events
        var second = first
        second.id = UUID()
        full.taskAudits = [first, second]
        var overflowing = full
        var extra = first
        extra.id = UUID()
        extra.events = [events[0]]
        overflowing.taskAudits!.append(extra)
        XCTAssertThrowsError(try validate(overflowing, after: full))
    }
}
