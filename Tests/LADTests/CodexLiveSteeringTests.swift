import Foundation
import XCTest
@testable import LAD

/// Explicit opt-in: exercises the installed signed-in CLI, the actual Swift
/// app-server transport and LAD's native MCP host in a private task workspace.
final class CodexLiveSteeringTests: XCTestCase {
    @MainActor
    func testSameTurnSupplementChangesNativeGeometryAndRetainsToolAudit() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LAD_RUN_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_CODEX_TESTS=1 to run the signed-in Codex integration test.")
        }
        let configured = environment["LAD_CODEX_EXECUTABLE"] ?? CodexService.findExecutable() ?? ""
        let executable = try XCTUnwrap(CodexService.resolveExecutable(configured), "A signed-in Codex CLI is required")
        let python = environment["LAD_CAD_PYTHON"] ?? EngineService.defaultPython
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: python), "The configured CAD runtime must be installed")
        let ready = expectation(description: "The native Swift transport exposes an active turn")
        ready.assertForOverFulfill = true
        let capture = LiveSteeringCapture()
        let service = CodexService()
        let engine = EngineService()
        defer { service.cancel(); engine.cancel() }
        let generation = Task {
            try await service.generate(
                prompt: """
                This is an isolated LAD integration test. Create exactly one rectangular solid box measuring 5 mm along X, 2 mm along Y and 3 mm along Z. No holes, bevels, fillets, extra parts or imported geometry. Name the design "Steering box". Use only the private task workspace and LAD's installed CAD runtime; do not inspect unrelated files or change any settings.

                Call lad_runtime, write a complete replayable CadQuery program in the workspace, and call lad_build. Before returning the final design response, call lad_validate and lad_render on the final candidate. If additional user information arrives during this turn, apply it to the final CAD program and repeat the native build/validate/render checks for the updated dimensions. Return the exact final program you built so LAD can reuse its validated geometry. Keep commentary brief.
                """,
                current: nil, history: [], executable: executable.path,
                model: environment["LAD_CODEX_MODEL"] ?? "", onProgress: { _ in },
                onActivity: { capture.append($0) }, python: python, threads: 2, engine: engine,
                onSteeringAvailability: { available in
                    if available, capture.markReadyOnce() { ready.fulfill() }
                })
        }
        defer { generation.cancel() }
        await fulfillment(of: [ready], timeout: 30)
        guard service.canSteer else {
            XCTFail("The actual Codex turn did not become available for steering. \(capture.failureSummary)")
            service.cancel()
            throw LiveSteeringFailure.notReady
        }
        let activeTurn = try XCTUnwrap(service.currentTurnID)
        let acceptedTurn = try await service.steer(prompt: "Set X to 7 mm instead of 5 mm. Keep Y exactly 2 mm and Z exactly 3 mm. No holes or extras. Rebuild, validate and render this updated box before the final response.")
        XCTAssertEqual(acceptedTurn, activeTurn, "Supplemental information must be acknowledged by the same active turn")
        let specification = try await generation.value
        let preview = try XCTUnwrap(service.validatedPreview(for: specification),
            "Final geometry must reuse the agent's matching native MCP build. \(capture.failureSummary)")
        XCTAssertEqual(preview.solids, 1)
        XCTAssertEqual(preview.volume, 42, accuracy: 1e-8)
        XCTAssertEqual(preview.size.count, 3)
        for (actual, expected) in zip(preview.size, [7.0, 2.0, 3.0]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-8)
        }
        let successfulTools = Set(capture.events.filter { $0.category == "tool" && $0.status == "completed" }.map(\.title))
        for name in ["lad_runtime", "lad_build", "lad_validate", "lad_render"] {
            XCTAssertTrue(successfulTools.contains(name), "Missing successful native \(name) audit. \(capture.failureSummary)")
        }
        XCTAssertFalse(service.canSteer)
        XCTAssertNil(service.currentTurnID)
    }
}

private enum LiveSteeringFailure: Error { case notReady }

private final class LiveSteeringCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var recorded: [ProjectActivityEvent] = []
    var events: [ProjectActivityEvent] { lock.lock(); defer { lock.unlock() }; return recorded }
    func markReadyOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ready else { return false }
        ready = true
        return true
    }
    func append(_ event: ProjectActivityEvent) { lock.lock(); recorded.append(event); lock.unlock() }
    var failureSummary: String {
        events.filter { $0.status == "failed" }.suffix(3)
            .map { "\($0.title): \(String(($0.output ?? "").suffix(400)))" }.joined(separator: "\n")
    }
}
