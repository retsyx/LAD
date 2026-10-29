import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class CodexServiceTests: XCTestCase {
    @MainActor
    func testCommentaryStreamsBeforeFinalResponseAndUpsertsEachItem() async throws {
        let initial = "I’ll inspect the PCB and create a two-part case. 📐"
        let milestone = "The PCB dimensions are confirmed.\nI’m checking HDMI clearance."
        let expanded = milestone + " The lid will retain its existing fit."
        let start = try event("item.started", id: "plan", text: "")
        let plan = try event("item.completed", id: "plan", text: initial)
        let bytes = Array(plan.utf8)
        let split = try XCTUnwrap(bytes.firstIndex(of: 0xF0)) + 1 // Split inside the emoji’s UTF-8 sequence.
        let first = shellBytes(bytes[..<split])
        let remainder = shellBytes(bytes[split...])
        let fixture = try FakeCodex(body: """
        printf '%s\\n' \(shellLiteral(start))
        printf '%b' \(shellLiteral(first))
        /bin/sleep 0.05
        printf '%b\\n' \(shellLiteral(remainder))
        printf '%s\\n' \(shellLiteral(try event("item.updated", id: "clearance", text: milestone)))
        printf '%s\\n' \(shellLiteral(try event("item.updated", id: "clearance", text: expanded)))
        printf '%s\\n' \(shellLiteral(try event("item.completed", id: "clearance", text: expanded)))
        /bin/sleep 0.25
        \(outputBody(try readyResponse(.bracket)))
        """)
        defer { fixture.remove() }
        let received = expectation(description: "Plan arrives before final output exists")
        let capture = ProgressCapture()
        let service = CodexService()
        let task = Task {
            try await service.generate(prompt: "Design a PCB enclosure", current: nil, history: [],
                                       executable: fixture.executable.path, model: "", onProgress: { _ in }, onMessage: { message in
                capture.append(message)
                if message.id == "plan" {
                    // The fixture writes the final response only after a delay.
                    let directory = (try? String(contentsOf: fixture.workingDirectoryURL, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    XCTAssertNotNil(directory)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: (directory ?? "") + "/model.json"),
                                   "Commentary must arrive before the final response is written")
                    received.fulfill()
                }
            })
        }
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(capture.messages.first, CodexProgressMessage(id: "plan", text: initial))
        let result = try await task.value
        XCTAssertEqual(result, .ready(.bracket))
        XCTAssertEqual(capture.messages, [CodexProgressMessage(id: "plan", text: initial),
                                          CodexProgressMessage(id: "clearance", text: milestone),
                                          CodexProgressMessage(id: "clearance", text: expanded)])
    }

    @MainActor
    func testProgressFiltersFinalModelsReasoningAndFileOutputButRetainsError() async throws {
        let final = try readyResponse(.bracket)
        let events: [[String: Any]] = [
            ["type": "item.completed", "item": ["id": "reasoning", "type": "reasoning", "text": "PRIVATE_REASONING_SENTINEL"]],
            ["type": "item.completed", "item": ["id": "command", "type": "command_execution", "aggregated_output": "SOURCE_FILE_SENTINEL"]],
            ["type": "item.completed", "item": ["id": "analysis", "type": "agent_message", "phase": "analysis", "text": "PRIVATE_ANALYSIS_SENTINEL"]],
            ["type": "item.completed", "item": ["id": "final-prose", "type": "agent_message", "phase": "final_answer", "text": "This is finished before solid validation."]],
            ["type": "item.completed", "item": ["id": "final-model", "type": "agent_message", "text": final]],
            ["type": "item.completed", "item": ["id": "code", "type": "agent_message", "text": "```python\nresult = cq.Solid.makeBox(1, 2, 3)\n```"]],
            ["type": "item.completed", "item": ["id": "source", "type": "agent_message", "text": "FeatureScript 2500;\nconst SOURCE_FILE_SENTINEL = true;"]],
            ["type": "item.completed", "item": ["id": "plan", "type": "agent_message", "phase": "commentary", "text": "I’ll check connector clearance before changing the shell."]],
            ["type": "turn.failed", "error": ["message": "The design source could not be read."]]
        ]
        let body = try events.map { "printf '%s\\n' \(shellLiteral(try jsonText($0)))" }.joined(separator: "\n")
        let fixture = try FakeCodex(body: body + "\nexit 1")
        defer { fixture.remove() }
        let capture = ProgressCapture()
        do {
            _ = try await CodexService().generate(prompt: "Design a case", current: nil, history: [],
                                                  executable: fixture.executable.path, model: "", onProgress: { _ in },
                                                  onMessage: { capture.append($0) })
            XCTFail("The failed turn should retain its diagnostic")
        } catch { XCTAssertTrue(error.localizedDescription.contains("The design source could not be read.")) }
        XCTAssertEqual(capture.messages, [CodexProgressMessage(id: "plan", text: "I’ll check connector clearance before changing the shell.")])
    }

    @MainActor
    func testCommentaryIsBoundedAcrossMalformedAndFragmentedProcessOutput() async throws {
        let longUpdate = "I’m checking clearances. " + String(repeating: "detail ", count: 1_000)
        var events = [try event("item.completed", id: "long", text: longUpdate)]
        events += try (0..<270).map { try event("item.completed", id: "update-\($0)", text: "Checked component \($0) for enclosure clearance.") }
        let emissions = events.map { "printf '%s\\n' \(shellLiteral($0))" }.joined(separator: "\n")
        let fixture = try FakeCodex(body: """
        \(outputBody(try readyResponse(.bracket)))
        /usr/bin/head -c 32100000 /dev/zero | /usr/bin/tr '\\000' x
        printf '\\n'
        \(emissions)
        printf '%s' \(shellLiteral(try event("item.completed", id: "update-0", text: "The first component clearance is confirmed.")))
        """)
        defer { fixture.remove() }
        let capture = ProgressCapture()
        _ = try await CodexService().generate(prompt: "Design a case", current: nil, history: [],
                                              executable: fixture.executable.path, model: "", onProgress: { _ in },
                                              onMessage: { capture.append($0) })
        XCTAssertEqual(capture.messages.count, 257, "At most 256 separate messages plus an update to an existing item")
        XCTAssertEqual(capture.messages.first?.text.count, 4_000)
        XCTAssertEqual(capture.messages.last, CodexProgressMessage(id: "update-0", text: "The first component clearance is confirmed."))
    }

    @MainActor
    func testMilestoneHistoryDoesNotDisplaceProjectRequirementsOrFinalSummary() async throws {
        var history = [ChatMessage(role: "user", content: "Preserve the 12 mm bore and the front mounting holes."),
                       ChatMessage(role: "assistant", content: "Created the bracket with a 12 mm bore.", phase: "final_answer")]
        history += (0..<40).map { ChatMessage(role: "assistant", content: "COMMENTARY_ONLY_MARKER milestone \($0)", phase: "commentary") }
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Add a lid", current: .bracket, history: history,
                                              executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        XCTAssertTrue(request.contains("Preserve the 12 mm bore and the front mounting holes."))
        XCTAssertTrue(request.contains("ASSISTANT [final_answer]: Created the bracket with a 12 mm bore."))
        XCTAssertFalse(request.contains("COMMENTARY_ONLY_MARKER"))
        XCTAssertFalse(try currentModelPath(request).isEmpty)
        XCTAssertTrue(request.contains("For construction work, start with the brief user-facing plan"))
    }

    @MainActor
    func testCustomPartsLayoutIsReferencedWithoutInliningItsContents() async throws {
        let marker = "USER_PART_LAYOUT_CONTENT_MUST_STAY_LOCAL"
        let layout = PartLayout(nodes: [PartNode(id: "stable-body", name: marker, solidIndices: [0])], movedNodeIDs: ["stable-body"])
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Add a lid", current: .bracket, history: [], partLayout: layout,
                                               executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        let path = try JSONDecoder().decode(String.self, from: contextSection("CURRENT PARTS LAYOUT FILE:", in: request))
        let saved = try JSONDecoder().decode(PartLayout.self, from: fixture.capturedData(at: path))
        var expected = layout
        expected.nodes[0].color = PartColorState.defaultFinish
        XCTAssertEqual(saved, expected)
        XCTAssertFalse(request.contains(marker))
        XCTAssertFalse(request.contains("stable-body"))
        XCTAssertTrue(request.contains("reorganizePartIDs"))
    }

    @MainActor
    func testExternalToolsAndReferenceOnlyImportPolicyReachCodex() async throws {
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Use the supplied reference geometry", current: nil,
            history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        XCTAssertFalse(request.contains("lad_convert_kicad"))
        XCTAssertTrue(request.contains("External tools are user-managed"))
        XCTAssertTrue(request.contains("lad_request_permission"))
        XCTAssertTrue(request.contains("The tool returns a decision only"))
        XCTAssertTrue(request.contains("each new proposed operation"))
        XCTAssertTrue(request.contains("saved chat, audit records or earlier-turn decisions"))
        XCTAssertTrue(request.contains("without new user direction"))
        XCTAssertTrue(request.contains("bundled CAD dependencies only"))
        XCTAssertFalse(request.contains("never download or install tools or dependencies"))
        XCTAssertTrue(request.contains("Never use lad_import for geometry you create or modify as part of this design"))
        XCTAssertTrue(request.contains("design-generated SDF/mesh outputs"))
        XCTAssertTrue(request.contains("faithful format conversions of user-provided inputs"))
        XCTAssertFalse(request.contains("before invoking you"), "The prompt must not describe the removed automatic dispatch.")
    }

    @MainActor
    func testNativeSTEPDataStaysLocalAndIsCarriedIntoRefinedPrograms() async throws {
        let marker = "NATIVE_STEP_BINARY_MUST_STAY_LOCAL"
        let step = Data("ISO-10303-21;\n\(marker)\nEND-ISO-10303-21;".utf8)
        let current = ModelSpec(title: "Native PCB", summary: "Exact imported PCB.", units: "mm", script: "result = imported_model", sourceSTEP: step, sourceName: "pcb.step")
        let refined = ModelSpec(title: "PCB clearance", summary: "A design using actual native geometry.", units: "mm", script: "result = imported_model.translate((10, 0, 0))")
        let fixture = try FakeCodex(body: outputBody(try readyResponse(refined)))
        defer { fixture.remove() }
        let response = try await CodexService().generate(prompt: "Use the exact native PCB", current: current, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        XCTAssertTrue(request.contains("imported_model"))
        XCTAssertTrue(request.contains("pcb.step"))
        XCTAssertFalse(request.contains(step.base64EncodedString()))
        XCTAssertFalse(request.contains(marker))
        let stagedModel = try JSONDecoder().decode(ModelSpec.self, from: fixture.capturedData(at: currentModelPath(request)))
        XCTAssertNil(stagedModel.sourceSTEP)
        XCTAssertEqual(stagedModel.script, current.script)
        guard case .ready(let specification) = response else { return XCTFail("Expected a completed CAD design.") }
        XCTAssertEqual(specification.sourceSTEP, step)
        XCTAssertEqual(specification.sourceName, "pcb.step")
    }

    @MainActor
    func testReasoningEffortIsSentAsATurnParameter() async throws {
        for effort in CodexReasoningEffort.allCases where effort != .defaultConfiguration {
            let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
            defer { fixture.remove() }
            _ = try await CodexService().generate(prompt: "Create a bracket", current: nil, history: [], executable: fixture.executable.path, model: "", reasoningEffort: effort, onProgress: { _ in })
            let arguments = try fixture.arguments()
            XCTAssertEqual(try fixture.turnRequest()["effort"] as? String, effort.rawValue)
            XCTAssertFalse(configurations(arguments).contains { $0.hasPrefix("model_reasoning_effort=") })
            XCTAssertEqual(Array(arguments.prefix(3)), ["app-server", "--listen", "stdio://"])
        }
    }

    @MainActor
    func testDefaultReasoningKeepsCodexConfigurationWithoutAnOverride() async throws {
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Create a bracket", current: nil, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
        let arguments = try fixture.arguments()
        XCTAssertTrue(configurations(arguments).contains("mcp_servers.lad.required=true"))
        XCTAssertEqual(try fixture.threadRequest()["sandbox"] as? String, "workspace-write")
        let turn = try fixture.turnRequest()
        XCTAssertNil(turn["effort"])
        XCTAssertNil(turn["model"])
        XCTAssertTrue(configurations(arguments).contains("sandbox_workspace_write.network_access=true"))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("model_reasoning_effort=") }))
        XCTAssertFalse(arguments.contains("--model"))
    }

    @MainActor
    func testModelAndReasoningSelectionsAreForwardedTogether() async throws {
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        let modelID = "test-model-id"
        _ = try await CodexService().generate(prompt: "Create a bracket", current: nil, history: [], executable: fixture.executable.path, model: modelID, reasoningEffort: .high, onProgress: { _ in })
        let turn = try fixture.turnRequest()
        XCTAssertEqual(turn["model"] as? String, modelID)
        XCTAssertEqual(turn["effort"] as? String, "high")
        XCTAssertEqual(try fixture.threadRequest()["model"] as? String, modelID)
        XCTAssertFalse(try fixture.arguments().contains("--model"))
    }

    @MainActor
    func testCatalogEffortTokensAreForwardedWithoutBeingDropped() async throws {
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        let effort = try XCTUnwrap(CodexReasoningEffort(rawValue: "future_level"))
        _ = try await CodexService().generate(prompt: "Create a bracket", current: nil, history: [],
                                              executable: fixture.executable.path, model: "catalog-model",
                                              reasoningEffort: effort, onProgress: { _ in })
        let turn = try fixture.turnRequest()
        XCTAssertEqual(turn["model"] as? String, "catalog-model")
        XCTAssertEqual(turn["effort"] as? String, "future_level")
    }

    @MainActor
    func testStructuredModelIsReadFromTheFinalAgentMessage() async throws {
        let encoded = try readyResponse(.bracket)
        let fixture = try FakeCodex(body: """
        cat > "$output" <<'LAD_MODEL'
        \(encoded)
        LAD_MODEL
        printf '%s\\n' '{"type":"turn.completed"}'
        """)
        defer { fixture.remove() }
        let model = try await CodexService().generate(prompt: "Create a bracket", current: nil, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
        XCTAssertEqual(model, .ready(.bracket))
        XCTAssertNotNil(try fixture.turnRequest()["outputSchema"] as? [String: Any])
    }

    @MainActor
    func testFinalAgentMessageIsAuthoritativeOverUnrelatedWorkspaceLinks() async throws {
        let encoded = try readyResponse(.bracket)
        let externalBytes = Data("EXTERNAL_FILE_MUST_NEVER_BECOME_THE_FINAL_RESPONSE".utf8)
        for symbolic in [true, false] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-external-response-\(UUID().uuidString).json")
            try externalBytes.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let final = try jsonText(["type": "item.completed", "item": ["id": "final", "type": "agent_message", "phase": "final_answer", "text": encoded]])
            let fixture = try FakeCodex(body: """
            /bin/ln \(symbolic ? "-s " : "")\(shellLiteral(source.path)) "$output"
            printf '%s\\n' \(shellLiteral(final))
            """)
            defer { fixture.remove() }
            let result = try await CodexService().generate(prompt: "Create a bracket", current: nil, history: [],
                executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTAssertEqual(result, .ready(.bracket))
            XCTAssertEqual(try Data(contentsOf: source), externalBytes)
        }
    }

    @MainActor
    func testUnwrappedModelIsRejectedInsteadOfTreatingItAsAnImportSuccess() async throws {
        let rawModel = String(decoding: try JSONEncoder().encode(ModelSpec.bracket), as: UTF8.self)
        let fixture = try FakeCodex(body: """
        cat > "$output" <<'LAD_MODEL'
        \(rawModel)
        LAD_MODEL
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexService().generate(prompt: "Import an enclosure", current: .bracket, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTFail("Expected a structured-response error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unreadable CAD design"))
        }
    }

    @MainActor
    func testAssistantQuestionsAndLimitationsReturnConversationWithoutAReplacementDesign() async throws {
        let reply = "Yes—I can use existing fonts or create custom raised lettering for HALO. What style would you like?"
        for status in ["message", "unsupported"] {
            let encoded = try jsonText(["status": status, "message": "  \(reply)\n", "model": NSNull(), "assetIDs": []])
            let fixture = try FakeCodex(responseJSON: encoded, delay: 0.01)
            defer { fixture.remove() }
            let service = CodexService()
            let result = try await service.generate(prompt: "Can we use a different font?", current: .bracket,
                history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTAssertEqual(result, .response(reply))
            XCTAssertNil(service.validatedPreview(for: .bracket), "A conversation reply must not supply replacement geometry.")
            let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
            XCTAssertTrue(request.contains("For questions, explanations or clarification, return a message response"))
            XCTAssertTrue(request.contains("Do not create or change geometry merely to answer a question."))
            let schema = try XCTUnwrap(try fixture.turnRequest()["outputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let statusSchema = try XCTUnwrap(properties["status"] as? [String: Any])
            XCTAssertTrue((statusSchema["enum"] as? [String])?.contains("message") == true)
            try fixture.assertJobWasCleanedUp()
        }
    }

    @MainActor
    func testConversationResponseRejectsUnknownEmptyOversizedAndContradictoryResults() async throws {
        let completed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ModelSpec.bracket))
        let invalid: [[String: Any]] = [
            ["status": "unknown", "message": "Hello", "model": NSNull()],
            ["status": "message", "message": "Missing the required null design field."],
            ["status": "message", "message": " \n\t", "model": NSNull()],
            ["status": "unsupported", "message": "", "model": NSNull()],
            ["status": "message", "message": String(repeating: "界", count: 333_334), "model": NSNull()],
            ["status": "message", "message": "Which style?", "model": completed],
            ["status": "unsupported", "message": "A source dependency is missing.", "model": completed]
        ]
        for response in invalid {
            let fixture = try FakeCodex(responseJSON: try jsonText(response), delay: 0.01)
            defer { fixture.remove() }
            do {
                _ = try await CodexService().generate(prompt: "Discuss the design", current: .bracket, history: [],
                    executable: fixture.executable.path, model: "", onProgress: { _ in })
                XCTFail("Malformed or contradictory responses must remain actual errors.")
            } catch let error as CodexError {
                guard case .invalidModel = error else { return XCTFail("Expected an invalid response, got \(error).") }
            }
        }
    }

    @MainActor
    func testReadyScriptModelIsAccepted() async throws {
        let script = "import cadquery as cq\nresult = cq.Workplane('XY').box(40, 25, 10).edges('|Z').fillet(2).val()\n"
        let response: [String: Any] = [
            "status": "ready", "message": "Translated the attached source into CadQuery.",
            "model": ["title": "Source enclosure", "summary": "A 40 × 25 × 10 mm rounded enclosure translated from the supplied source.", "units": "mm", "script": script]
        ]
        let encoded = try jsonText(response)
        let fixture = try FakeCodex(body: """
        cat > "$output" <<'LAD_MODEL'
        \(encoded)
        LAD_MODEL
        """)
        defer { fixture.remove() }
        let model = try await CodexService().generate(prompt: "Translate the FeatureScript", current: nil, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
        guard case .ready(let specification) = model else { return XCTFail("Expected a completed CAD design.") }
        XCTAssertEqual(specification.script, script)
    }

    @MainActor
    func testCompleteCurrentAndOldHistoricalSourcesAreReferencedWithoutInlining() async throws {
        let content = "FeatureScript 2500;\n" + String(repeating: "const sample = 42 * millimeter;\n", count: 1_700) + "const FINAL_FULL_SOURCE_SENTINEL = true;\n"
        XCTAssertGreaterThan(content.utf8.count, 50_000)
        let current = attachment("amity-case-2.fs", content: content)
        let historic = attachment("old-case.fs", content: "FeatureScript 2000;\nconst OLD_SOURCE_END_SENTINEL = true;\n")
        var history = [ChatMessage(role: "user", content: "Import the original source", attachments: [historic])]
        history += (0..<20).map { ChatMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "Later conversation \($0)") }
        var imported = ModelSpec.bracket
        imported.title = "Imported bracket"
        imported.summary = "Imported a 100 mm wide bracket from the source."
        imported.script = imported.script.replacingOccurrences(of: "box(80, 50, 6", with: "box(100, 50, 6")
        let fixture = try FakeCodex(body: outputBody(try readyResponse(imported)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Import the attached design", current: .bracket, history: history, attachments: [current], executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        try assertReferencedSources([current, historic], request: request, fixture: fixture)
        XCTAssertFalse(request.contains("FINAL_FULL_SOURCE_SENTINEL"))
        XCTAssertFalse(request.contains("OLD_SOURCE_END_SENTINEL"))
        try fixture.assertJobWasCleanedUp()
    }

    @MainActor
    func testRenamingAnUnchangedModelDoesNotCountAsImportingTheSource() async throws {
        var unchanged = ModelSpec.bracket
        unchanged.title = "Imported enclosure"
        unchanged.summary = "The source is unavailable, so the existing enclosure is preserved unchanged."
        let source = attachment("requested-case.fs", content: "FeatureScript 2500;\nconst actualWidth = 110 * millimeter;\n")
        let fixture = try FakeCodex(body: outputBody(try readyResponse(unchanged)))
        defer { fixture.remove() }
        do {
            _ = try await CodexService().generate(prompt: "Import the attached enclosure", current: .bracket, history: [], attachments: [source], executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTFail("An unchanged program with a new title is not a successful source import")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("existing design"))
        }
    }

    @MainActor
    func testCurrentSourcesTakePriorityOverOlderSourcesAndContextIsBounded() async throws {
        let current = attachment("current.fs", content: "FeatureScript 2500;\nconst CURRENT_PRIORITY_SENTINEL = true;")
        let historic = (0..<5).map { attachment("historic-\($0).fs", content: "FeatureScript 2500;\nconst HISTORY_SENTINEL_\($0) = true;") }
        let history = historic.map { ChatMessage(role: "user", content: "Earlier source", attachments: [$0]) }
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Refine the current source", current: nil, history: history, attachments: [current], executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        try assertReferencedSources([current, historic[4], historic[3], historic[2]], request: request, fixture: fixture)
        XCTAssertFalse(request.contains("CURRENT_PRIORITY_SENTINEL"))
        for index in 0..<5 { XCTAssertFalse(request.contains("HISTORY_SENTINEL_\(index)")) }
    }

    @MainActor
    func testSourceContextHonorsCombinedByteBudgetWithoutTruncatingIncludedFiles() async throws {
        let currentContent = "const CURRENT_BUDGET_START = true;\n" + String(repeating: "x", count: 740_000) + "\nconst CURRENT_BUDGET_END = true;"
        let current = attachment("current-large.fs", content: currentContent)
        let historic = (0..<3).map { index in
            attachment("older-large-\(index).fs", content: "const OLD_BUDGET_\(index)_START = true;\n" + String(repeating: "y", count: 740_000) + "\nconst OLD_BUDGET_\(index)_END = true;")
        }
        let history = historic.map { ChatMessage(role: "user", content: "Earlier large source", attachments: [$0]) }
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Use the latest attached source", current: nil, history: history, attachments: [current], executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        try assertReferencedSources([current, historic[2]], request: request, fixture: fixture)
        XCTAssertLessThan(request.utf8.count, 65_536)
        XCTAssertFalse(request.contains("CURRENT_BUDGET_START"))
        for index in 0..<3 { XCTAssertFalse(request.contains("OLD_BUDGET_\(index)_START")) }
    }

    @MainActor
    func testExcludingLatestHistoricalSourceForBudgetDoesNotResurrectAnOlderVersion() async throws {
        let current = (0..<2).map { index in
            attachment("current-\(index).fs", content: "const CURRENT_VERSION_\(index) = true;\n" + String(repeating: "x", count: 740_000))
        }
        let older = attachment("same-case.fs", content: "const STALE_VERSION_MUST_NOT_RETURN = true;\n" + String(repeating: "y", count: 100_000))
        let latest = attachment("same-case.fs", content: "const LATEST_VERSION_TOO_LARGE = true;\n" + String(repeating: "z", count: 740_000))
        let history = [ChatMessage(role: "user", content: "Initial source snapshot", attachments: [older]),
                       ChatMessage(role: "user", content: "Updated source snapshot", attachments: [latest])]
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Import the current designs", current: nil, history: history, attachments: current, executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        try assertReferencedSources(current, request: request, fixture: fixture)
        XCTAssertFalse(request.contains("CURRENT_VERSION_0"))
        XCTAssertFalse(request.contains("CURRENT_VERSION_1"))
        XCTAssertFalse(request.contains("LATEST_VERSION_TOO_LARGE"))
        XCTAssertFalse(request.contains("STALE_VERSION_MUST_NOT_RETURN"), "Excluding a newer snapshot must not substitute an obsolete version of the same source path")
    }

    @MainActor
    func testPCBSizeSourceWithTabsQuotesAndBackslashesStaysOutOfPrompt() async throws {
        let content = "(kicad_pcb\n; PCB_FULL_SOURCE_SENTINEL\n" + String(repeating: "\t(property \"Value\" \"HDMI\\A\")\n", count: 28_000) + "; PCB_SOURCE_END_SENTINEL\n)\n"
        XCTAssertGreaterThan(content.utf8.count, 740_000)
        XCTAssertLessThan(content.utf8.count, SourceImport.maximumFileBytes)
        let source = attachment("PCB \"quoted\" \\ source.kicad_pcb", content: content)
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        _ = try await CodexService().generate(prompt: "Design a case around this PCB", current: nil, history: [], attachments: [source], executable: fixture.executable.path, model: "", onProgress: { _ in })
        let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
        try assertReferencedSources([source], request: request, fixture: fixture)
        XCTAssertLessThan(request.utf8.count, 65_536)
        XCTAssertFalse(request.contains("PCB_FULL_SOURCE_SENTINEL"))
        XCTAssertFalse(request.contains("PCB_SOURCE_END_SENTINEL"))
        try fixture.assertJobWasCleanedUp()
    }

    @MainActor
    func testCurrentProgramsAreOnlyAvailableThroughReferencedFile() async throws {
        let programMarker = "CURRENT_PROGRAM_FILE_SENTINEL"
        let bracketMarker = "CURRENT_BRACKET_PROGRAM_SENTINEL"
        var bracket = ModelSpec.bracket
        bracket.script = "# \(bracketMarker)\n" + bracket.script
        let program = ModelSpec(title: "Current design", summary: "A saved program.", units: "mm", script: "# \(programMarker)\nresult = cq.Workplane('XY').box(40, 25, 10)\n")
        for (current, marker) in [(program, programMarker), (bracket, bracketMarker)] {
            let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
            defer { fixture.remove() }
            _ = try await CodexService().generate(prompt: "Refine the saved design", current: current, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
            let request = try String(contentsOf: fixture.inputURL, encoding: .utf8)
            let path = try currentModelPath(request)
            let saved = try JSONDecoder().decode(ModelSpec.self, from: fixture.capturedData(at: path))
            XCTAssertEqual(saved, current)
            XCTAssertFalse(request.contains(marker))
            try fixture.assertJobWasCleanedUp()
        }
    }

    @MainActor
    func testOversizedPromptIsRejectedBeforeCodexLaunch() async throws {
        let fixture = try FakeCodex(body: outputBody(try readyResponse(.bracket)))
        defer { fixture.remove() }
        do {
            _ = try await CodexService().generate(prompt: String(repeating: "界", count: 400_000), current: nil, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTFail("A request larger than the UTF-8 budget must be rejected locally")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("too long"))
            XCTAssertTrue(error.localizedDescription.lowercased().contains("shorten"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.argumentsURL.path), "Codex must not launch for an oversized request")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inputURL.path))
    }

    @MainActor
    func testAuthenticationFailureHasActionableMessage() async throws {
        let fixture = try FakeCodex(body: "printf '%s\\n' '401 unauthorized: authentication required' >&2\nexit 1")
        defer { fixture.remove() }
        do {
            _ = try await CodexService().generate(prompt: "Make a box", current: nil, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTFail("Expected a sign-in error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Complete setup in your Codex installation"))
        }
    }

    @MainActor
    func testMalformedOutputIsRejected() async throws {
        let fixture = try FakeCodex(body: "printf '%s' 'not a model' > \"$output\"")
        defer { fixture.remove() }
        do {
            _ = try await CodexService().generate(prompt: "Make a box", current: nil, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTFail("Expected invalid model error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unreadable CAD design"))
        }
    }

    @MainActor
    func testCancellationDoesNotWaitForDescendantPipeEOF() async throws {
        // A shell's child inherits stdout and outlives its parent. Cancellation must still return.
        let fixture = try FakeCodex(body: "/bin/sleep 3 &\nwait")
        defer { fixture.remove() }
        let service = CodexService()
        let task = Task {
            try await service.generate(prompt: "Make a box", current: nil, history: [], executable: fixture.executable.path, model: "", onProgress: { _ in })
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = Date()
        service.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.8)
        }
    }

    @MainActor
    func testCancellationKillsSilentProcessThatIgnoresTermination() async throws {
        // The mock app-server and its silent operation both ignore SIGTERM, so
        // responsive Stop requires the transport's delayed SIGKILL fallback.
        let fixture = try FakeCodex(body: """
        trap '' TERM
        printf '%s\\n' \(shellLiteral(try event("item.completed", id: "ready", text: "Waiting for the design operation.")))
        exec /bin/sleep 30
        """)
        defer { fixture.remove() }
        let ready = expectation(description: "Codex is running and ignores SIGTERM")
        let service = CodexService()
        let task = Task {
            try await service.generate(prompt: "Make a box", current: nil, history: [],
                                       executable: fixture.executable.path, model: "", onProgress: { _ in },
                                       onMessage: { message in
                if message.id == "ready" { ready.fulfill() }
            })
        }
        defer { task.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let start = ProcessInfo.processInfo.systemUptime
        service.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            XCTAssertGreaterThanOrEqual(elapsed, 0.5, "The silent process must require the delayed SIGKILL fallback")
            XCTAssertLessThan(elapsed, 4, "Stop must finish promptly even when Codex ignores SIGTERM")
        }
        try fixture.assertJobWasCleanedUp()
    }

    private func attachment(_ name: String, content: String) -> SourceAttachment {
        SourceAttachment(name: name, path: "/tmp/LAD-test-imports/\(name)", content: content,
                         sha256: SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    private func jsonText(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func event(_ type: String, id: String, text: String) throws -> String {
        try jsonText(["type": type, "item": ["id": id, "type": "agent_message", "text": text]])
    }

    private func shellLiteral(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellBytes<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "\\0%03o", Int($0)) }.joined()
    }

    private func configurations(_ arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            arguments[index] == "--config" && index + 1 < arguments.count ? arguments[index + 1] : nil
        }
    }

    private func readyResponse(_ model: ModelSpec) throws -> String {
        var encodedModel = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        if encodedModel["reorganizePartIDs"] == nil { encodedModel["reorganizePartIDs"] = [] as [String] }
        if encodedModel["assetIDs"] == nil { encodedModel["assetIDs"] = [] as [String] }
        return try jsonText(["status": "ready", "message": model.summary, "model": encodedModel])
    }

    private func outputBody(_ encoded: String) -> String {
        """
        cat > "$output" <<'LAD_MODEL'
        \(encoded)
        LAD_MODEL
        """
    }

    private struct SourceReference: Decodable {
        let name: String
        let path: String
        let readPath: String
        let sha256: String
        let byteCount: Int
    }

    private func contextSection(_ heading: String, in request: String) throws -> Data {
        let start = try XCTUnwrap(request.range(of: heading + "\n"))
        let body = request[start.upperBound...].components(separatedBy: "\n\n")[0]
        return Data(body.utf8)
    }

    private func currentModelPath(_ request: String) throws -> String {
        try JSONDecoder().decode(String.self, from: contextSection("CURRENT MODEL FILE:", in: request))
    }

    private func assertReferencedSources(_ expected: [SourceAttachment], request: String, fixture: FakeCodex, file: StaticString = #filePath, line: UInt = #line) throws {
        let references = try JSONDecoder().decode([SourceReference].self, from: contextSection("ATTACHED SOURCE FILE REFERENCES (JSON):", in: request))
        XCTAssertEqual(references.map(\.path), expected.map(\.path), file: file, line: line)
        for (reference, source) in zip(references, expected) {
            XCTAssertEqual(reference.name, source.name, file: file, line: line)
            XCTAssertEqual(reference.sha256, source.sha256, file: file, line: line)
            XCTAssertEqual(reference.byteCount, source.content.utf8.count, file: file, line: line)
            XCTAssertNotEqual(reference.readPath, source.path, "A saved snapshot must not depend on its provenance path", file: file, line: line)
            let staged = try fixture.capturedData(at: reference.readPath)
            XCTAssertEqual(staged, Data(source.content.utf8), "The file available during the Codex process must retain the complete snapshot", file: file, line: line)
            XCTAssertFalse(request.contains(source.content), "Source contents must never be inlined", file: file, line: line)
            let escaped = String(decoding: try JSONEncoder().encode(source.content), as: UTF8.self)
            XCTAssertFalse(request.contains(escaped), "JSON escaping must not hide inlined source contents", file: file, line: line)
        }
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexProgressMessage] = []

    func append(_ message: CodexProgressMessage) {
        lock.lock(); defer { lock.unlock() }
        storage.append(message)
    }

    var messages: [CodexProgressMessage] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

