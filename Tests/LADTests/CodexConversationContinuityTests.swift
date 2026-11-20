import Foundation
import XCTest
@testable import LAD

/// A design's requests continue one agent conversation in one private task
/// workspace, so the agent keeps what it already read and analyzed.
final class CodexConversationContinuityTests: XCTestCase {
    @MainActor
    func testFollowUpResumesTheDesignConversationInItsWorkspace() async throws {
        let fixture = try FakeCodex(responseJSON: try reply("The board outline is 80 x 50 mm."), delay: 0.01, resumable: true)
        defer { fixture.remove() }
        let service = CodexService()
        _ = try await service.generate(prompt: "Analyze the attached board", current: nil,
            history: [ChatMessage(role: "user", content: "EARLIER_REQUEST_MARKER")],
            executable: fixture.executable.path, model: "", onProgress: { _ in })
        let workspace = try workingDirectory(fixture)
        let first = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        XCTAssertTrue(first.contains("RECENT CONVERSATION:\nUSER: EARLIER_REQUEST_MARKER"))
        XCTAssertFalse(first.contains("CONTINUING THIS DESIGN'S CONVERSATION"))
        let start = try XCTUnwrap(try fixture.rpcRequests().first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        XCTAssertEqual(start["ephemeral"] as? Bool, false, "The app-server must save the thread so it can be resumed.")
        let instructions = try XCTUnwrap(start["developerInstructions"] as? String)
        XCTAssertTrue(instructions.contains("You are the CAD designer inside LAD"))
        XCTAssertFalse(first.contains("You are the CAD designer inside LAD"),
                       "Design instructions are developer instructions, which survive the agent's context compaction.")
        // Analysis the agent wrote during the first request.
        try Data("outline 80 x 50".utf8).write(to: workspace.appendingPathComponent("board-notes.txt"))

        let history = [ChatMessage(role: "user", content: "EARLIER_REQUEST_MARKER"),
                       ChatMessage(role: "user", content: "Analyze the attached board"),
                       ChatMessage(role: "assistant", content: "Reading the board file.", phase: "commentary"),
                       ChatMessage(role: "assistant", content: "The board outline is 80 x 50 mm.", phase: "response")]
        _ = try await service.generate(prompt: "Add mounting holes", current: nil, history: history,
            executable: fixture.executable.path, model: "", onProgress: { _ in })
        XCTAssertEqual(try threadMethods(fixture), ["thread/start", "thread/resume"])
        let resume = try fixture.threadRequest()
        XCTAssertEqual(resume["threadId"] as? String, "thread")
        XCTAssertEqual(resume["excludeTurns"] as? Bool, true, "Resuming must not return the thread's complete history to LAD.")
        XCTAssertEqual(resume["developerInstructions"] as? String, instructions,
                       "A resumed thread keeps the design instructions for later compaction.")
        XCTAssertEqual(try workingDirectory(fixture), workspace)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("board-notes.txt"), encoding: .utf8), "outline 80 x 50",
                       "Files the agent wrote stay available to its next request.")
        let second = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        XCTAssertTrue(second.hasPrefix("CONTINUING THIS DESIGN'S CONVERSATION\n"))
        XCTAssertTrue(second.contains("SINCE YOUR LAST TURN:\nASSISTANT [response]: The board outline is 80 x 50 mm.\n\nUSER REQUEST:\nAdd mounting holes"))
        XCTAssertFalse(second.contains("RECENT CONVERSATION"))
        XCTAssertFalse(second.contains("EARLIER_REQUEST_MARKER"), "The resumed conversation already holds the earlier requests.")
        XCTAssertFalse(second.contains("Reading the board file."))

        service.endConversation()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path),
                       "The task workspace is removed when the design's conversation ends.")
    }

    @MainActor
    func testUnresumableConversationContinuesInANewConversation() async throws {
        let fixture = try FakeCodex(responseJSON: try reply("Ready."), delay: 0.01, resumable: false)
        defer { fixture.remove() }
        let service = CodexService()
        _ = try await service.generate(prompt: "Analyze the attached board", current: nil, history: [],
            executable: fixture.executable.path, model: "", onProgress: { _ in })
        let original = try workingDirectory(fixture)

        let capture = ConversationActivityCapture()
        let result = try await service.generate(prompt: "Add mounting holes", current: nil,
            history: [ChatMessage(role: "user", content: "Analyze the attached board")],
            executable: fixture.executable.path, model: "", onProgress: { _ in }, onActivity: { capture.append($0) })
        XCTAssertEqual(result, .response("Ready."))
        let notice = try XCTUnwrap(capture.events.first { $0.title == "Earlier session not resumed" },
                                   "The task audit must show that the request continued in a new session.")
        XCTAssertTrue(notice.output?.contains("No saved thread was found.") == true)
        XCTAssertEqual(try threadMethods(fixture), ["thread/start", "thread/resume", "thread/start"])
        XCTAssertEqual(try fixture.rpcRequests().filter { $0["method"] as? String == "turn/start" }.count, 2,
                       "The request runs once, in the new conversation.")
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        XCTAssertTrue(request.contains("RECENT CONVERSATION:\nUSER: Analyze the attached board"),
                      "A new conversation receives the recent conversation instead.")
        XCTAssertFalse(request.contains("CONTINUING THIS DESIGN'S CONVERSATION"))
        let replacement = try workingDirectory(fixture)
        XCTAssertNotEqual(replacement, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        try fixture.assertJobWasCleanedUp(ending: service)
    }

    @MainActor
    func testFailedTaskStartsTheNextRequestInANewConversation() async throws {
        let fixture = try FakeCodex(body: "echo 'The model service failed.' >&2; exit 3")
        defer { fixture.remove() }
        let service = CodexService()
        for prompt in ["Make a box", "Make a box again"] {
            do {
                _ = try await service.generate(prompt: prompt, current: nil, history: [],
                    executable: fixture.executable.path, model: "", onProgress: { _ in })
                XCTFail("The failing task must not complete.")
            } catch let error as CodexError {
                XCTAssertTrue(error.localizedDescription.contains("The model service failed."))
            }
        }
        XCTAssertEqual(try threadMethods(fixture), ["thread/start", "thread/start"],
                       "A conversation whose task failed is not resumed.")
        try fixture.assertJobWasCleanedUp()
    }

    @MainActor
    func testLADRestagesItsOwnFoldersForEveryRequest() throws {
        let conversation = try AgentConversation(vendor: .codex)
        let workspace = conversation.workspace
        for folder in AgentConversation.restagedFolders {
            let url = workspace.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: url.appendingPathComponent("stale.json"))
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("keep".utf8).write(to: outside.appendingPathComponent("user.txt"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("tmp"), withDestinationURL: outside)
        try Data("analysis".utf8).write(to: workspace.appendingPathComponent("notes.txt"))

        try conversation.prepareForRequest()
        for folder in AgentConversation.restagedFolders {
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(folder).path), folder)
        }
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("notes.txt"), encoding: .utf8), "analysis")
        for folder in ["tmp", ".cache"] {
            let values = try workspace.appendingPathComponent(folder).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isDirectory, true, folder)
            XCTAssertEqual(values.isSymbolicLink, false, "\(folder) must be a real folder inside the workspace")
        }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("user.txt"), encoding: .utf8), "keep",
                       "Replacing a linked folder must not touch its destination.")
    }

    private func reply(_ message: String) throws -> String {
        let object: [String: Any] = ["status": "message", "message": message, "model": NSNull(), "assetIDs": []]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func workingDirectory(_ fixture: FakeCodex) throws -> URL {
        URL(fileURLWithPath: try String(contentsOf: fixture.workingDirectoryURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func threadMethods(_ fixture: FakeCodex) throws -> [String] {
        try fixture.rpcRequests().compactMap { $0["method"] as? String }.filter { $0.hasPrefix("thread/") }
    }
}

private final class ConversationActivityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProjectActivityEvent] = []
    var events: [ProjectActivityEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ event: ProjectActivityEvent) { lock.lock(); stored.append(event); lock.unlock() }
}
