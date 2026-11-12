import CryptoKit
import XCTest
@testable import LAD

final class ProjectRenameTests: XCTestCase {
    func testExplicitProjectNameTravelsWithCompleteZIPHistoryWithoutRenamingProjects() throws {
        let original = project()
        let before = try manifest(original)
        var renamed = original
        renamed.projectName = "PCB enclosure v2.0 + HDMI"
        let saved = try ProjectStore.encode(renamed)
        XCTAssertEqual(saved.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        let after = try manifest(renamed)
        XCTAssertEqual(after["projectName"] as? String, renamed.projectName)
        XCTAssertEqual(after["assets"] as? [String: String], before["assets"] as? [String: String])
        let restored = try ProjectStore.decode(saved)
        XCTAssertEqual(restored.projectName, renamed.projectName)
        XCTAssertEqual(restored.projectID, original.projectID)
        XCTAssertEqual(restored.codexSettings, original.codexSettings)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.selectedRevisionID, original.selectedRevisionID)
        XCTAssertEqual(restored.revisions.map(\.id), original.revisions.map(\.id))
        XCTAssertEqual(restored.revisions.map(\.date), original.revisions.map(\.date))
        XCTAssertEqual(restored.revisions.map(\.model), original.revisions.map(\.model))
        XCTAssertEqual(restored.revisions.map(\.partLayout), original.revisions.map(\.partLayout))
        XCTAssertEqual(restored.revisions.map(\.hiddenSolids), original.revisions.map(\.hiddenSolids))
        XCTAssertEqual(restored.revisions.map(\.runtime), original.revisions.map(\.runtime))
    }

    func testUserChosenNameSurvivesHistorySelectionAndNewGeneratedTitles() throws {
        var value = project()
        value.projectName = "Workshop enclosure"
        value.selectedRevisionID = value.revisions.first?.id
        var restored = try ProjectStore.decode(ProjectStore.encode(value))
        XCTAssertEqual(restored.projectName, "Workshop enclosure")
        XCTAssertEqual(restored.selectedRevisionID, value.revisions.first?.id)
        var refined = ModelSpec.bracket
        refined.title = "Codex generated a different design title"
        let next = ProjectRevision(model: refined)
        restored.revisions.append(next)
        restored.selectedRevisionID = next.id
        let updated = try ProjectStore.decode(ProjectStore.encode(restored))
        XCTAssertEqual(updated.projectName, "Workshop enclosure")
        XCTAssertEqual(updated.revisions.last?.model.title, refined.title)
        XCTAssertEqual(updated.revisions.first?.model.title, value.revisions.first?.model.title)
    }

    func testProjectsWithoutAnExplicitNameRetainGeneratedNaming() throws {
        let original = project()
        let restored = try ProjectStore.decode(ProjectStore.encode(original))
        XCTAssertNil(restored.projectName)
        XCTAssertNil(try manifest(original)["projectName"])
        XCTAssertEqual(restored.revisions.map(\.model.title), original.revisions.map(\.model.title))
    }

    func testLiteralExtensionInSavedBasenameRemainsIntact() throws {
        var value = project()
        value.projectName = "Workshop.lad"
        let restored = try ProjectStore.decode(ProjectStore.encode(value))
        XCTAssertEqual(restored.projectName, "Workshop.lad")
    }

    func testInvalidPersistedProjectNamesAreRejectedOnWriteAndRead() throws {
        let original = project()
        let before = try manifest(original)
        for invalid in ["", ".", "..", ".Hidden", "Not/a name", "Not:a name", "Null\u{0}name", "\nName", "Name ", String(repeating: "a", count: 221)] {
            var value = original
            value.projectName = invalid
            XCTAssertThrowsError(try ProjectStore.encode(value), invalid)
            var changed = before
            changed["projectName"] = invalid
            let corrupted = try ProjectZIP.encode(JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try ProjectStore.decode(corrupted), invalid)
        }
    }

    private func project() -> LADProject {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "body", name: "Body", solidIndices: [0])])]
        let layout = PartLayout(nodes: parts, collapsedNodeIDs: ["case"])
        let first = ProjectRevision(model: .bracket, partLayout: layout, hiddenSolids: [0], parts: parts,
                                   runtime: CADRuntime(python: "3.11.13", cadquery: "2.6.1", ocp: "7.8.1.1"))
        var wider = ModelSpec.bracket
        wider.title = "Wider mounting bracket"
        wider.script = wider.script.replacingOccurrences(of: "box(80, 50, 6", with: "box(100, 50, 6")
        let second = ProjectRevision(model: wider, partLayout: layout, hiddenSolids: [], parts: parts)
        let content = "(kicad_pcb (version 20240108) (general (thickness 1.6)))\n"
        let hash = SHA256.hexDigest(Data(content.utf8))
        let source = SourceAttachment(name: "board.kicad_pcb", path: "/original/board.kicad_pcb", content: content, sha256: hash)
        return LADProject(messages: [ChatMessage(role: "user", content: "Build an enclosure", attachments: [source]),
                                     ChatMessage(role: "assistant", content: "I’ll check the board and build its enclosure.", phase: "commentary"),
                                     ChatMessage(role: "assistant", content: "Model ready.", phase: "final_answer")],
                          revisions: [first, second], selectedRevisionID: second.id, projectID: UUID(),
                          codexSettings: CodexProjectSettings(model: "project-model", reasoningEffort: "ultra",
                                                              reasoningByModel: ["project-model": "ultra"]))
    }

    private func manifest(_ project: LADProject) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(ProjectStore.encode(project))) as? [String: Any])
    }
}
