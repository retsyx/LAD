import Foundation
import XCTest
@testable import LAD

final class RevisionConversationTests: XCTestCase {
    func testSuccessfulTurnLinksRoundtripWithoutIncludingLaterFailedTurn() throws {
        let original = project()
        let restored = try ProjectStore.decode(ProjectStore.encode(original))

        XCTAssertNil(restored.revisions[0].userMessageID)
        XCTAssertNil(restored.revisions[0].responseMessageID)
        XCTAssertEqual(restored.revisions[1].userMessageID, original.messages[0].id)
        XCTAssertEqual(restored.revisions[1].responseMessageID, original.messages[3].id)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.revisions[1].model, original.revisions[1].model)
    }

    func testInvalidLinksCannotAssociateAModelWithAnUnrelatedOrIncompleteTurn() throws {
        let original = project()
        let corruptions: [(inout LADProject) -> Void] = [
            { $0.revisions[1].userMessageID = nil },
            { $0.revisions[1].responseMessageID = nil },
            { $0.revisions[1].userMessageID = UUID() },
            { $0.revisions[1].responseMessageID = UUID() },
            { $0.revisions[1].userMessageID = $0.messages[1].id },
            { $0.revisions[1].responseMessageID = $0.messages[2].id },
            { $0.revisions[1].responseMessageID = $0.messages[1].id },
            { $0.revisions[1].responseMessageID = $0.messages[4].id },
            { $0.revisions[1].userMessageID = $0.messages[4].id }
        ]
        for (index, corrupt) in corruptions.enumerated() {
            var value = original
            corrupt(&value)
            XCTAssertThrowsError(try ProjectStore.encode(value), "Corruption \(index) must not be saved")
        }
    }

    func testArchiveReaderRejectsDanglingConversationReferences() throws {
        let encoded = try ProjectStore.encode(project())
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(encoded)) as? [String: Any])
        var revisions = try XCTUnwrap(manifest["revisions"] as? [[String: Any]])
        revisions[1]["responseMessageID"] = UUID().uuidString
        manifest["revisions"] = revisions
        let corrupted = try ProjectZIP.encode(JSONSerialization.data(withJSONObject: manifest))

        XCTAssertThrowsError(try ProjectStore.decode(corrupted))
    }

    private func project() -> LADProject {
        let messages = [
            ChatMessage(role: "user", content: "Add four mounting holes"),
            ChatMessage(role: "assistant", content: "I’ll check the hole positions.", phase: "commentary"),
            ChatMessage(role: "system", content: "The geometry needed one repair."),
            ChatMessage(role: "assistant", content: "Added the four mounting holes.\n\nModel ready.", phase: "final_answer"),
            ChatMessage(role: "user", content: "Add a lid"),
            ChatMessage(role: "system", content: "The lid could not be completed.")
        ]
        let unlinked = ProjectRevision(model: .bracket)
        var successful = ProjectRevision(model: .bracket)
        successful.userMessageID = messages[0].id
        successful.responseMessageID = messages[3].id
        return LADProject(messages: messages, revisions: [unlinked, successful], selectedRevisionID: successful.id)
    }
}
