import Foundation
import XCTest
@testable import LAD

/// This opt-in test uses the installed, signed-in Codex CLI. It works in an
/// empty temporary task, never opens or changes a user's LAD document.
final class CodexAgentIntegrationTests: XCTestCase {
    @MainActor
    func testInstalledCodexCanBuildInspectMeasureValidateRenderAndExportThroughLAD() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_CODEX_AGENT_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_CODEX_AGENT_TESTS=1 for the signed-in Codex/MCP/native CAD workflow.")
        }
        let executable = ProcessInfo.processInfo.environment["LAD_TEST_CODEX_PATH"] ?? CodexService.findExecutable() ?? ""
        guard !executable.isEmpty else { throw XCTSkip("Install and sign in to Codex before running this integration check.") }
        let model = ProcessInfo.processInfo.environment["LAD_TEST_CODEX_MODEL"] ?? ""
        let capture = AgentIntegrationCapture()
        let service = CodexService()
        let result = try await service.generate(prompt: """
        This is a small LAD tool integration verification in an empty design.
        Create one solid: a circular loft from radius 5 mm at Z=0 to radius 3 mm at Z=12,
        with a concentric radius 1 mm through-hole. Use the installed CadQuery runtime.
        Call lad_runtime; write a complete .py recipe; call lad_build; call lad_inspect for
        the exact edges and lad_measure for at least one circular edge; call lad_validate;
        call lad_render and review the returned image; call lad_export_step to a path in
        the task workspace. Finish with the schema JSON, the exact program you built,
        assetIDs=[] and a short summary mentioning what the rendered shape shows.
        Do not install packages or inspect unrelated files. Do not rebuild the CAD runtime.
        """, current: nil, history: [], executable: executable, model: model,
            onProgress: { _ in }, onMessage: { _ in }, onActivity: { capture.append($0) },
            python: EngineService.defaultPython, threads: 4)
        guard case .ready(let spec) = result else { return XCTFail("Expected a completed CAD design.") }
        let preview = try XCTUnwrap(service.validatedPreview(for: spec), "The final recipe must reuse geometry validated during the agent turn.")
        XCTAssertEqual(preview.solids, 1)
        XCTAssertEqual(preview.volume, 184 * .pi, accuracy: 1e-5)
        let completed = Set(capture.events.filter { $0.category == "tool" && $0.status == "completed" }.map(\.title))
        for tool in ["lad_runtime", "lad_build", "lad_inspect", "lad_measure", "lad_validate", "lad_render", "lad_export_step"] {
            XCTAssertTrue(completed.contains(tool), "The live Codex turn did not successfully use \(tool).")
        }
        XCTAssertTrue(capture.events.contains { $0.title == "lad_render" && $0.output?.contains("image_path") == true })
        XCTAssertTrue(capture.events.contains { $0.title == "lad_build" && $0.files?.contains(where: { $0.data == Data(spec.script.utf8) }) == true })
        XCTAssertFalse(capture.events.contains { $0.output?.contains("\"data\":") == true && $0.output?.contains("image/png") == true })
        print("Live Codex verified LAD tools: \(completed.sorted().joined(separator: ", ")); \(preview.solids) solid, \(preview.volume) mm³; validated native geometry reused.")
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: preview.stepPath).deletingLastPathComponent())
    }

    /// A follow-up resumes the design's conversation. The resumed request
    /// omits the earlier user message, so only the agent's own context holds
    /// the code word. Set LAD_TEST_AGENT=claude to check Claude Code instead.
    @MainActor
    func testInstalledAgentRemembersEarlierRequestsInTheDesignConversation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LAD_RUN_CODEX_AGENT_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_CODEX_AGENT_TESTS=1 for the signed-in design conversation check.")
        }
        let vendor = AgentVendor(rawValue: environment["LAD_TEST_AGENT"] ?? "codex") ?? .codex
        let executable = environment["LAD_TEST_AGENT_PATH"] ?? (vendor == .codex ? CodexExecutable.find() : ClaudeExecutable.find()) ?? ""
        guard !executable.isEmpty else { throw XCTSkip("Install and sign in to \(vendor.displayName) first.") }
        let model = environment["LAD_TEST_CODEX_MODEL"] ?? ""
        let service = CodexService()
        defer { service.endConversation() }
        let first = "This is a LAD conversation check in an empty design. Remember this code word for later in our conversation: TANGERINE-58. Do not call tools. Reply with a message response that says only: Noted."
        let noted = try await service.generate(vendor: vendor, prompt: first, current: nil, history: [], executable: executable,
            model: model, reasoningEffort: .low, onProgress: { _ in }, python: EngineService.defaultPython, threads: 2)
        guard case .response(let acknowledgement) = noted else { return XCTFail("Expected a message response, received \(noted).") }

        let capture = AgentIntegrationCapture()
        let history = [ChatMessage(role: "user", content: first),
                       ChatMessage(role: "assistant", content: acknowledgement, phase: "response")]
        let recalled = try await service.generate(vendor: vendor,
            prompt: "What code word did I ask you to remember? Do not call tools. Reply with a message response containing only the code word.",
            current: nil, history: history, executable: executable, model: model, reasoningEffort: .low,
            onProgress: { _ in }, onActivity: { capture.append($0) }, python: EngineService.defaultPython, threads: 2)
        guard case .response(let answer) = recalled else { return XCTFail("Expected a message response, received \(recalled).") }
        XCTAssertTrue(capture.events.contains { $0.title == "Session resumed" }, "The follow-up must resume the design's conversation.")
        XCTAssertFalse(capture.events.contains { $0.title == "Earlier session not resumed" })
        XCTAssertTrue(answer.contains("TANGERINE-58"), "The resumed agent must remember the earlier request; it answered: \(answer)")
        print("Live \(vendor.displayName) resumed the design conversation and recalled: \(answer)")
    }
}

private final class AgentIntegrationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [String: ProjectActivityEvent]()
    private var order = [String]()
    func append(_ event: ProjectActivityEvent) {
        lock.lock(); defer { lock.unlock() }
        if stored[event.id] == nil { order.append(event.id) }
        stored[event.id] = event
    }
    var events: [ProjectActivityEvent] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { stored[$0] }
    }
}
