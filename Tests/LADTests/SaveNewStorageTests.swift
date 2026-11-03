import Foundation
import XCTest
@testable import LAD

final class SaveNewStorageTests: XCTestCase {
    func testNewFileIsIndependentAndOriginalKeepsItsHistoryAndAutosave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectAutosaveStore(rootDirectory: directory)
        let original = project()
        let id = try XCTUnwrap(original.projectID)
        let source = try await store.write(project: original, projectID: id, title: "Original", sequence: 1)
        let originalBytes = try ProjectStore.readArchive(from: source)
        var new = try SaveNewProject.snapshot(from: original)
        new.projectName = "New design"
        let destination = directory.appendingPathComponent("New design.lad")

        try await store.writeCopy(new, to: destination, preserving: source, projectID: id)

        let saved = try ProjectStore.read(from: destination)
        XCTAssertNotEqual(saved.projectID, id)
        XCTAssertEqual(saved.revisions.map(\.id), [try XCTUnwrap(original.revisions.last?.id)])
        XCTAssertTrue(saved.messages.isEmpty)
        XCTAssertEqual(saved.projectName, "New design")
        XCTAssertEqual(try ProjectStore.readArchive(from: source), originalBytes)
        let autosaved = try await store.write(project: original, projectID: id, title: "Original", sequence: 2, preferredURL: source)
        XCTAssertEqual(autosaved, source)
        XCTAssertEqual(try ProjectStore.read(from: source).revisions.count, 2)
        XCTAssertEqual(try ProjectStore.read(from: source).messages.count, 4)
    }

    func testHistoricalRevisionFilePreservesTheOriginalBytesHistoryAndSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectAutosaveStore(rootDirectory: directory)
        var original = project()
        let requested = try XCTUnwrap(original.revisions.first)
        original.selectedRevisionID = original.revisions.last?.id
        let id = try XCTUnwrap(original.projectID)
        let source = try await store.write(project: original, projectID: id, title: "Original", sequence: 1)
        let originalBytes = try ProjectStore.readArchive(from: source)
        var copy = try SaveNewProject.snapshot(from: original, revisionID: requested.id)
        copy.projectName = "First version copy"
        let target = directory.appendingPathComponent("First version copy.lad")
        try await store.writeCopy(copy, to: target, preserving: source, projectID: id)

        let saved = try ProjectStore.read(from: target)
        XCTAssertNotEqual(saved.projectID, id)
        XCTAssertEqual(saved.selectedRevisionID, requested.id)
        XCTAssertEqual(saved.revisions.map(\.id), [requested.id])
        XCTAssertEqual(saved.revisions[0].model, requested.model)
        XCTAssertTrue(saved.messages.isEmpty)
        XCTAssertNil(saved.taskAudits)
        XCTAssertEqual(try ProjectStore.readArchive(from: source), originalBytes)
        let unchanged = try ProjectStore.read(from: source)
        XCTAssertEqual(unchanged.revisions.map(\.id), original.revisions.map(\.id))
        XCTAssertEqual(unchanged.messages, original.messages)
        XCTAssertEqual(unchanged.selectedRevisionID, original.selectedRevisionID)
    }

    func testSaveNewCannotReplaceOriginalThroughPathOrIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectAutosaveStore(rootDirectory: directory)
        let original = project()
        let id = try XCTUnwrap(original.projectID)
        let source = try await store.write(project: original, projectID: id, title: "Original", sequence: 1)
        let bytes = try ProjectStore.readArchive(from: source)
        let new = try SaveNewProject.snapshot(from: original)
        let alias = directory.appendingPathComponent("Alias.lad")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let sameIdentity = directory.appendingPathComponent("Original copy.lad")
        try FileManager.default.copyItem(at: source, to: sameIdentity)

        for destination in [source, alias, sameIdentity] {
            do {
                try await store.writeCopy(new, to: destination, preserving: source, projectID: id)
                XCTFail("Save New must preserve the original design")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("different filename"))
            }
            XCTAssertEqual(try ProjectStore.readArchive(from: source), bytes)
            XCTAssertEqual(try ProjectStore.readArchive(from: sameIdentity), bytes)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-save-new-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func project() -> LADProject {
        let firstPrompt = ChatMessage(role: "user", content: "Make a bracket")
        let first = ProjectRevision(model: .bracket)
        let firstResponse = ChatMessage(role: "assistant", content: first.model.summary, phase: "final_answer")
        let prompt = ChatMessage(role: "user", content: "Make it wider")
        var model = ModelSpec.bracket
        model.title = "Wider bracket"
        model.summary = "Widened the bracket."
        model.script = model.script.replacingOccurrences(of: "box(80, 50, 6", with: "box(100, 50, 6")
        let response = ChatMessage(role: "assistant", content: model.summary, phase: "final_answer")
        let last = ProjectRevision(model: model, userMessageID: prompt.id, responseMessageID: response.id)
        return LADProject(messages: [firstPrompt, firstResponse, prompt, response], revisions: [first, last],
                          selectedRevisionID: first.id, projectID: UUID(), projectName: "Original", showGrid: false)
    }
}
