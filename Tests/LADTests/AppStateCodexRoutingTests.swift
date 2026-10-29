import Foundation
import XCTest
@testable import LAD

final class AppStateCodexRoutingTests: XCTestCase {
    @MainActor
    func testPCBSTEPRequestUsesSelectedCodexAndOnlyReferencesTheExplicitBoardSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let board = fixture.directory.appendingPathComponent("controller.kicad_pcb")
        let source = "(kicad_pcb (version 20241229) ; BOARD_SOURCE_CONTENT_SENTINEL\n)\n"
        try Data(source.utf8).write(to: board)
        let state = fixture.state()
        defer { state.cancel() }
        let prompt = "Generate the STEP file for the PCB using KiCad from \"\(board.path)\"."
        let request = try await fixture.submit(prompt, to: state)

        XCTAssertTrue(request.contains(prompt), "PCB/STEP wording must be forwarded to Codex without an automatic conversion route.")
        XCTAssertNil(state.error)
        XCTAssertTrue(state.messages.contains { $0.role == "assistant" && $0.content == "AGENT_ROUTING_RESPONSE" })
        XCTAssertEqual(state.taskAudits.first?.model, "routing-model")
        XCTAssertEqual(state.taskAudits.first?.reasoningEffort, "high")
        XCTAssertTrue(state.revisions.isEmpty, "Only a validated agent result may create a revision.")
        let attachment = try XCTUnwrap(state.messages.first(where: { $0.role == "user" })?.attachments?.first)
        XCTAssertEqual(attachment.path, board.resolvingSymlinksInPath().path)
        XCTAssertEqual(attachment.content, source)
        XCTAssertTrue(request.contains("ATTACHED SOURCE FILE REFERENCES"))
        XCTAssertFalse(request.contains("BOARD_SOURCE_CONTENT_SENTINEL"))
        XCTAssertEqual(try fixture.capturedSource(), source)
    }

    @MainActor
    func testNamingAPCBDirectoryDoesNotEnumerateOrChooseABoardBeforeCodexRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let directory = fixture.directory.appendingPathComponent("PCB files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["first.kicad_pcb", "second.kicad_pcb"] {
            try Data("(kicad_pcb ; DIRECTORY_SOURCE_SENTINEL)\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        let state = fixture.state()
        defer { state.cancel() }
        let prompt = "Create a case for the PCB in \"\(directory.path)\" and review its STEP geometry."
        let request = try await fixture.submit(prompt, to: state)

        XCTAssertTrue(request.contains(prompt))
        XCTAssertNil(state.error)
        XCTAssertTrue(state.messages.contains { $0.role == "assistant" && $0.content == "AGENT_ROUTING_RESPONSE" },
                      "Directory ambiguity belongs to agent-directed inspection and conversation, not a pre-Codex importer.")
        XCTAssertNil(state.messages.first(where: { $0.role == "user" })?.attachments)
        XCTAssertFalse(request.contains("DIRECTORY_SOURCE_SENTINEL"))
        XCTAssertFalse(request.contains("ATTACHED SOURCE FILE REFERENCES"))
        XCTAssertTrue(state.revisions.isEmpty)
    }

    @MainActor
    func testPCBSTEPRequestCanReferenceAPortableAttachmentAfterItsOriginalIsDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let board = fixture.directory.appendingPathComponent("portable.kicad_pcb")
        let source = "(kicad_pcb (version 20241229) ; PORTABLE_BOARD_SOURCE_SENTINEL\n)\n"
        try Data(source.utf8).write(to: board)
        let attachments = try SourceImport.load(urls: [board])
        try FileManager.default.removeItem(at: board)
        let state = fixture.state()
        defer { state.cancel() }
        state.pendingAttachments = attachments
        let request = try await fixture.submit("Export the attached PCB as STEP using KiCad if needed.", to: state)

        XCTAssertNil(state.error)
        XCTAssertTrue(state.messages.contains { $0.role == "assistant" && $0.content == "AGENT_ROUTING_RESPONSE" })
        XCTAssertEqual(state.messages.first(where: { $0.role == "user" })?.attachments, attachments)
        XCTAssertTrue(request.contains("ATTACHED SOURCE FILE REFERENCES"))
        XCTAssertFalse(request.contains("PORTABLE_BOARD_SOURCE_SENTINEL"))
        XCTAssertEqual(try fixture.capturedSource(), source)
        XCTAssertTrue(state.revisions.isEmpty)
    }

    @MainActor
    private struct Fixture {
        let codex: FakeCodex
        let directory: URL
        let executable: URL
        let input: URL
        let capturedContext: URL
        let autosaves: URL
        let oldCodex: Any?
        let oldPython: Any?

        init() throws {
            codex = try FakeCodex(responseJSON: "{\"status\":\"unsupported\",\"message\":\"AGENT_ROUTING_RESPONSE\",\"model\":null,\"assetIDs\":[]}", delay: 0.05)
            directory = codex.directory
            executable = codex.executable
            input = codex.inputURL
            capturedContext = codex.captureURL.appendingPathComponent("context", isDirectory: true)
            autosaves = directory.appendingPathComponent("autosaves", isDirectory: true)
            try FileManager.default.createDirectory(at: autosaves, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            oldPython = UserDefaults.standard.object(forKey: "pythonPath")
            UserDefaults.standard.set(executable.path, forKey: "codexPath")
            UserDefaults.standard.set(EngineService.defaultPython, forKey: "pythonPath")
        }

        func state() -> AppState {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: autosaves))
            state.newProject()
            state.selectCodexModel("routing-model")
            state.selectCodexReasoningEffort("high")
            return state
        }

        func submit(_ prompt: String, to state: AppState) async throws -> String {
            state.prompt = prompt
            state.submit()
            let deadline = ContinuousClock.now + .seconds(10)
            while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            if state.isWorking { XCTFail("The mock Codex request did not finish."); state.cancel() }
            await state.prepareToQuit()
            XCTAssertTrue(FileManager.default.fileExists(atPath: input.path), "The request must reach the configured Codex executable.")
            return try String(contentsOf: input, encoding: .utf8)
        }

        func capturedSource() throws -> String {
            try String(contentsOf: capturedContext.appendingPathComponent("sources/source-001.kicad_pcb"), encoding: .utf8)
        }

        func cleanUp() {
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            if let oldPython { UserDefaults.standard.set(oldPython, forKey: "pythonPath") }
            else { UserDefaults.standard.removeObject(forKey: "pythonPath") }
            codex.remove()
        }
    }
}
