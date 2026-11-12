import Foundation
import XCTest
@testable import LAD

final class CodexActivityTests: XCTestCase {
    func testCommandEventsPreserveFullTextStableIdentityAndOriginalStartTime() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let command = "python /workspace/shape.py\n--export /workspace/shape.step"
        let output = String(repeating: "native output complete\n", count: 60_000)
        var starts = ["cli:command-1": startedAt]
        let start = try XCTUnwrap(event(id: "command-1", kind: "commandExecution",
                                        fields: ["command": command, "status": "inProgress"], starts: &starts))
        let update = try XCTUnwrap(event(id: "command-1", kind: "commandExecution",
                                         fields: ["command": command, "aggregatedOutput": "partial output"], starts: &starts))
        let complete = try XCTUnwrap(event(id: "command-1", kind: "commandExecution", completed: true,
                                           fields: ["command": command, "aggregatedOutput": output,
                                                    "exitCode": 0, "durationMs": 1250.0], starts: &starts))
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
        let started = try XCTUnwrap(event(id: "long", kind: "commandExecution", fields: ["command": command], starts: &starts))
        XCTAssertLessThanOrEqual(started.title.count, 180)
        XCTAssertEqual(started.input, command)
        XCTAssertNil(started.durationSeconds)
    }

    func testFailuresCancellationAndInterruptionRetainTheirActualOutcome() throws {
        var starts: [String: Date] = [:]
        let failed = try XCTUnwrap(event(id: "fail", kind: "commandExecution", completed: true,
                                         fields: ["command": "external-tool", "exitCode": 2, "aggregatedOutput": "Invalid mesh"],
                                         starts: &starts))
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.output, "Invalid mesh")
        for (raw, expected) in [("canceled", "canceled"), ("cancelled", "canceled"), ("interrupted", "interrupted")] {
            let ended = try XCTUnwrap(event(id: raw, kind: "commandExecution", completed: true,
                                            fields: ["command": "external-tool", "status": raw], starts: &starts))
            XCTAssertEqual(ended.status, expected)
        }
    }

    func testPrivateReasoningAndAgentMessagesNeverBecomeActivityPayloads() {
        var starts: [String: Date] = [:]
        for (kind, fields) in [
            ("reasoning", ["text": "PRIVATE_REASONING_SENTINEL"]),
            ("agentMessage", ["phase": "analysis", "text": "PRIVATE_REASONING_SENTINEL"]),
            ("agentMessage", ["phase": "commentary", "text": "A public chat update"]),
            ("agentMessage", ["phase": "final_answer", "text": "{\"model\":{\"script\":\"result = cq.Workplane()\"}}"])
        ] {
            XCTAssertNil(event(id: kind, kind: kind, completed: true, fields: fields, starts: &starts))
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
        let call = try XCTUnwrap(event(id: "external", kind: "mcpToolCall", completed: true,
                                       fields: ["server": "meshing", "tool": "inspect", "arguments": ["path": "/workspace/mesh.stl"],
                                                "result": result], starts: &starts))
        XCTAssertEqual(call.category, "tool")
        XCTAssertEqual(call.title, "meshing · inspect")
        XCTAssertTrue(try XCTUnwrap(call.input).contains("/workspace/mesh.stl"))
        XCTAssertTrue(try XCTUnwrap(call.output).contains("Inspected the external mesh"))
        XCTAssertFalse(try XCTUnwrap(call.output).contains(imageData))
        XCTAssertTrue(try XCTUnwrap(call.output).contains("encodedByteCount"))
    }

    func testNativeLADMCPEventsAreNotDuplicatedIntoTheAgentAudit() {
        var starts: [String: Date] = [:]
        XCTAssertNil(event(id: "native", kind: "mcpToolCall", completed: true,
                           fields: ["server": "lad", "tool": "lad_render", "result": ["content": [["type": "image", "data": "PNG_SENTINEL"]]]],
                           starts: &starts))
        XCTAssertTrue(starts.isEmpty)
    }

    func testNullErrorOnSuccessfulExternalMCPResultIsNotAFailure() throws {
        var starts: [String: Date] = [:]
        let call = try XCTUnwrap(event(id: "external", kind: "mcpToolCall", completed: true,
                                       fields: ["server": "external", "tool": "inspect", "error": NSNull(), "result": ["ok": true]],
                                       starts: &starts))
        XCTAssertEqual(call.status, "completed")
        XCTAssertTrue(try XCTUnwrap(call.output).contains("true"))
    }

    func testFileSearchAndPlanEventsRetainPublicDetails() throws {
        var starts: [String: Date] = [:]
        let changes = [["path": "/workspace/program.py", "kind": "add"]]
        let file = try XCTUnwrap(event(id: "file", kind: "fileChange", completed: true, fields: ["changes": changes], starts: &starts))
        XCTAssertEqual(file.category, "file_change")
        XCTAssertTrue(try XCTUnwrap(file.input).contains("/workspace/program.py"))
        let search = try XCTUnwrap(event(id: "search", kind: "webSearch", completed: true, fields: ["query": "CadQuery surface API"], starts: &starts))
        XCTAssertEqual(search.category, "web_search")
        XCTAssertEqual(search.input, "CadQuery surface API")
        let plan = try XCTUnwrap(event(id: "plan", kind: "plan", fields: ["items": [["text": "Validate the solid", "completed": false]]], starts: &starts))
        XCTAssertEqual(plan.category, "plan")
        XCTAssertTrue(try XCTUnwrap(plan.output).contains("Validate the solid"))
    }

    private func event(id: String, kind: String, completed: Bool = false, fields: [String: Any] = [:],
                       starts: inout [String: Date]) -> ProjectActivityEvent? {
        var item = fields
        item["id"] = id; item["type"] = kind
        return CodexActivity.event(item: item, id: id, completed: completed, starts: &starts)
    }
}
