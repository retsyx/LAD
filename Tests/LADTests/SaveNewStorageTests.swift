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
        let originalBytes = try Data(contentsOf: source)
        var new = try SaveNewProject.snapshot(from: original)
        new.projectName = "New design"
        let destination = directory.appendingPathComponent("New design.lad")

        try await store.writeCopy(new, to: destination, preserving: source, projectID: id)

        let saved = try ProjectStore.read(from: destination)
        XCTAssertNotEqual(saved.projectID, id)
        XCTAssertEqual(saved.revisions.map(\.id), [try XCTUnwrap(original.revisions.last?.id)])
        XCTAssertEqual(saved.messages, Array(original.messages.suffix(2)))
        XCTAssertEqual(saved.projectName, "New design")
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        let autosaved = try await store.write(project: original, projectID: id, title: "Original", sequence: 2, preferredURL: source)
        XCTAssertEqual(autosaved, source)
        XCTAssertEqual(try ProjectStore.read(from: source).revisions.count, 2)
        XCTAssertEqual(try ProjectStore.read(from: source).messages.count, 4)
    }

    func testSaveNewCannotReplaceOriginalThroughPathOrIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectAutosaveStore(rootDirectory: directory)
        let original = project()
        let id = try XCTUnwrap(original.projectID)
        let source = try await store.write(project: original, projectID: id, title: "Original", sequence: 1)
        let bytes = try Data(contentsOf: source)
        let new = try SaveNewProject.snapshot(from: original)
        let alias = directory.appendingPathComponent("Alias.lad")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let sameIdentity = directory.appendingPathComponent("Original copy.lad")
        try bytes.write(to: sameIdentity)

        for destination in [source, alias, sameIdentity] {
            do {
                try await store.writeCopy(new, to: destination, preserving: source, projectID: id)
                XCTFail("Save New must preserve the original design")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("different filename"))
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: sameIdentity), bytes)
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
