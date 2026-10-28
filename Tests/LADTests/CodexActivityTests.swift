import Foundation
import XCTest
@testable import LAD

final class CodexActivityTests: XCTestCase {
    func testCommandEventsPreserveFullTextStableIdentityAndOriginalStartTime() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let command = "python /workspace/shape.py\n--export /workspace/shape.step"
        let output = String(repeating: "native output complete\n", count: 60_000)
        var starts = ["cli:command-1": startedAt]
        let start = try XCTUnwrap(CodexActivity.event(item("item.started", id: "command-1", kind: "command_execution",
                                                          fields: ["command": command, "status": "in_progress"]), starts: &starts))
        let update = try XCTUnwrap(CodexActivity.event(item("item.updated", id: "command-1", kind: "command_execution",
                                                           fields: ["command": command, "aggregated_output": "partial output"]), starts: &starts))
        let complete = try XCTUnwrap(CodexActivity.event(item("item.completed", id: "command-1", kind: "command_execution",
                                                             fields: ["command": command, "aggregated_output": output,
                                                                      "exit_code": 0, "duration_ms": 1250.0]), starts: &starts))
        XCTAssertEqual(start.id, update.id)
        XCTAssertEqual(start.id, complete.id)
        XCTAssertEqual([start.date, update.date, complete.date], [startedAt, startedAt, startedAt])
        XCTAssertEqual(starts["cli:command-1"], startedAt)
        XCTAssertEqual(start.status, "running")
        XCTAssertEqual(update.status, "running")
        XCTAssertEqual(complete.status, "completed")
        XCTAssertEqual(complete.input, command)
        XCTAssertEqual(complete.output, output, "Audit output must not inherit commentary truncation.")
        XCTAssertEqual(try XCTUnwrap(complete.durationSeconds), 1.25, accuracy: 1e-9)
    }

    func testLongCommandTitlesAreBoundedWhileCommandInputRemainsComplete() throws {
        let command = "python -c " + String(repeating: "long_command_argument", count: 2_000)
        var starts: [String: Date] = [:]
        let event = try XCTUnwrap(CodexActivity.event(item("item.started", id: "long", kind: "command_execution",
                                                          fields: ["command": command]), starts: &starts))
        XCTAssertLessThanOrEqual(event.title.count, 180)
        XCTAssertEqual(event.input, command)
        XCTAssertNil(event.durationSeconds)
    }

    func testFailuresCancellationAndInterruptionRetainTheirActualOutcome() throws {
        var starts: [String: Date] = [:]
        let failed = try XCTUnwrap(CodexActivity.event(item("item.completed", id: "fail", kind: "command_execution",
                                                           fields: ["command": "external-tool", "exit_code": 2, "aggregated_output": "Invalid mesh"]), starts: &starts))
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.output, "Invalid mesh")
        for (raw, expected) in [("canceled", "canceled"), ("cancelled", "canceled"), ("interrupted", "interrupted")] {
            let event = try XCTUnwrap(CodexActivity.event(item("item.completed", id: raw, kind: "command_execution",
                                                              fields: ["command": "external-tool", "status": raw]), starts: &starts))
            XCTAssertEqual(event.status, expected)
        }
    }

    func testPrivateReasoningAndAgentMessagesNeverBecomeActivityPayloads() {
        var starts: [String: Date] = [:]
        for (kind, fields) in [
            ("reasoning", ["text": "PRIVATE_REASONING_SENTINEL"]),
            ("agent_message", ["phase": "analysis", "text": "PRIVATE_REASONING_SENTINEL"]),
            ("agent_message", ["phase": "commentary", "text": "A public chat update"]),
            ("agent_message", ["phase": "final_answer", "text": "{\"model\":{\"script\":\"result = cq.Workplane()\"}}"])
        ] {
            XCTAssertNil(CodexActivity.event(item("item.completed", id: kind, kind: kind, fields: fields), starts: &starts))
        }
        XCTAssertTrue(starts.isEmpty)
    }

    func testExternalMCPToolArgumentsAndTextSurviveButDerivedImageBytesDoNot() throws {
        let imageData = "DERIVED_PNG_BASE64_SENTINEL"
        let result: [String: Any] = ["content": [
            ["type": "text", "text": "Inspected the external mesh"],
            ["type": "image", "mimeType": "image/png", "data": imageData],
            ["type": "image_url", "image_url": "data:image/png;base64," + imageData],
            ["type": "input_image", "image_url": "data:image/png;base64," + imageData],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64," + imageData]]
        ]]
        var starts: [String: Date] = [:]
        let event = try XCTUnwrap(CodexActivity.event(item("item.completed", id: "external", kind: "mcp_tool_call",
                                                          fields: ["server": "meshing", "tool": "inspect", "arguments": ["path": "/workspace/mesh.stl"], "result": result]), starts: &starts))
        XCTAssertEqual(event.category, "tool")
        XCTAssertEqual(event.title, "meshing · inspect")
        XCTAssertTrue(try XCTUnwrap(event.input).contains("/workspace/mesh.stl"))
        XCTAssertTrue(try XCTUnwrap(event.output).contains("Inspected the external mesh"))
        XCTAssertFalse(try XCTUnwrap(event.output).contains(imageData))
        XCTAssertTrue(try XCTUnwrap(event.output).contains("encodedByteCount"))
    }

    func testNativeLADMCPEventsAreNotDuplicatedIntoTheCLIAudit() {
        var starts: [String: Date] = [:]
        for serverField in ["server", "server_name"] {
            let event = item("item.completed", id: "native", kind: "mcp_tool_call",
                             fields: [serverField: "lad", "tool": "lad_render", "result": ["content": [["type": "image", "data": "PNG_SENTINEL"]]]])
            XCTAssertNil(CodexActivity.event(event, starts: &starts))
        }
        XCTAssertTrue(starts.isEmpty)
    }

    func testNullErrorOnSuccessfulExternalMCPResultIsNotAFailure() throws {
        var starts: [String: Date] = [:]
        let event = try XCTUnwrap(CodexActivity.event(item("item.completed", id: "external", kind: "mcp_tool_call",
                                                          fields: ["server": "external", "tool": "inspect", "error": NSNull(), "result": ["ok": true]]), starts: &starts))
        XCTAssertEqual(event.status, "completed")
        XCTAssertTrue(try XCTUnwrap(event.output).contains("true"))
    }

    func testFileSearchPlanAndLifecycleEventsRetainPublicDetails() throws {
        var starts: [String: Date] = [:]
        let changes = [["path": "/workspace/program.py", "kind": "add"]]
        let file = try XCTUnwrap(CodexActivity.event(item("item.completed", id: "file", kind: "file_change", fields: ["changes": changes]), starts: &starts))
        XCTAssertEqual(file.category, "file_change")
        XCTAssertTrue(try XCTUnwrap(file.input).contains("/workspace/program.py"))
        let search = try XCTUnwrap(CodexActivity.event(item("item.completed", id: "search", kind: "web_search", fields: ["query": "CadQuery surface API"]), starts: &starts))
        XCTAssertEqual(search.category, "web_search")
        XCTAssertEqual(search.input, "CadQuery surface API")
        let plan = try XCTUnwrap(CodexActivity.event(item("item.updated", id: "plan", kind: "todo_list", fields: ["items": [["text": "Validate the solid", "completed": false]]]), starts: &starts))
        XCTAssertEqual(plan.category, "plan")
        XCTAssertTrue(try XCTUnwrap(plan.output).contains("Validate the solid"))
        let failed = try XCTUnwrap(CodexActivity.event(["type": "turn.failed", "error": ["message": "Connection lost"]], starts: &starts))
        XCTAssertEqual(failed.category, "diagnostic")
        XCTAssertEqual(failed.status, "failed")
        XCTAssertTrue(try XCTUnwrap(failed.output).contains("Connection lost"))
    }

    private func item(_ type: String, id: String, kind: String, fields: [String: Any] = [:]) -> [String: Any] {
        var value = fields
        value["id"] = id; value["type"] = kind
        return ["type": type, "item": value]
    }
}
