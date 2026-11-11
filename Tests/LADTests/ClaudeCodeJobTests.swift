import Foundation
import XCTest
@testable import LAD

final class ClaudeCodeJobTests: XCTestCase {
    func testStructuredResponseCommentaryAndPublicActivity() async throws {
        let fixture = try ClaudeFixture(scenario: """
        init()
        text('I will model the bracket and check its holes.')
        tool('t1', 'Bash', {'command': 'python3 build.py'})
        tool_result('t1', 'built')
        tool('t2', 'mcp__lad__lad_build', {'programPath': 'design.py'})
        tool_result('t2', 'ok')
        tool('t3', 'Read', {'file_path': 'context/image.png'})
        tool_result('t3', [{'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AAAA'}}])
        text('The bracket is ready.')
        tool('t4', 'StructuredOutput', {'status': 'message', 'message': 'done', 'model': None, 'assetIDs': []})
        tool_result('t4', 'Structured output provided successfully')
        result({'status': 'message', 'message': 'done', 'model': None, 'assetIDs': []})
        """)
        defer { fixture.remove() }
        let capture = ClaudeCapture()
        let data = try await fixture.job(capture: capture).run(input: Data("Make a bracket".utf8))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["status"] as? String, "message")
        XCTAssertEqual(response["message"] as? String, "done")
        XCTAssertEqual(capture.messages.map(\.text), ["I will model the bracket and check its holes."],
                       "Prose immediately before the structured response must not duplicate the final answer")
        let events = Dictionary(capture.events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        XCTAssertEqual(events["claude:t1"]?.category, "command")
        XCTAssertEqual(events["claude:t1"]?.status, "completed")
        XCTAssertEqual(events["claude:t1"]?.output, "built")
        XCTAssertNil(events["claude:t2"], "Native LAD tool calls are recorded by the LAD bridge")
        XCTAssertNil(events["claude:t4"], "The final structured response is not activity")
        XCTAssertEqual(events["claude:t3"]?.output, "Derived media attachment (not stored)")
        XCTAssertFalse(capture.events.contains { ($0.output ?? "").contains("AAAA") })
        XCTAssertTrue(capture.events.contains { $0.title == "Session started" })
        let initial = try XCTUnwrap(fixture.requests().first)
        XCTAssertEqual(initial["type"] as? String, "user")
        XCTAssertNotNil(UUID(uuidString: initial["uuid"] as? String ?? ""))
        let message = try XCTUnwrap(initial["message"] as? [String: Any])
        XCTAssertEqual((message["content"] as? [[String: Any]])?.first?["text"] as? String, "Make a bracket")
        XCTAssertEqual(capture.availability.first, true)
        XCTAssertEqual(capture.availability.last, false)
    }

    func testAcknowledgedSteeringJoinsTheActiveTask() async throws {
        let fixture = try ClaudeFixture(scenario: """
        init()
        steer = read()
        lifecycle(steer['uuid'], 'queued')
        send({'type': 'user', 'isReplay': True, 'uuid': steer['uuid'], 'message': steer['message']})
        lifecycle(steer['uuid'], 'started')
        lifecycle(steer['uuid'], 'completed')
        result({'status': 'message', 'message': steer['message']['content'][0]['text'], 'model': None, 'assetIDs': []})
        lifecycle(FIRST['uuid'], 'completed')
        """)
        defer { fixture.remove() }
        let capture = ClaudeCapture()
        let job = fixture.job(capture: capture)
        defer { job.cancel() }
        let task = Task { try await job.run(input: Data("initial request".utf8)) }
        try await waitUntil { job.canSteer }
        XCTAssertEqual(job.currentTurnID, "session-1")
        let accepted = try await job.steer(text: "Make the wall 3 mm")
        XCTAssertEqual(accepted, "session-1")
        let data = try await task.value
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["message"] as? String, "Make the wall 3 mm")
        XCTAssertFalse(job.canSteer)
        XCTAssertNil(job.currentTurnID)
        do {
            _ = try await job.steer(text: "too late")
            XCTFail("A finished task cannot receive a new message")
        } catch let error as CodexSteeringError {
            XCTAssertFalse(error.mayHaveBeenAccepted)
        }
    }

    func testMessageAcknowledgedAsTheTurnEndsKeepsTheTaskOpenForItsResult() async throws {
        let fixture = try ClaudeFixture(scenario: """
        init()
        steer = read()
        result({'status': 'message', 'message': 'first', 'model': None, 'assetIDs': []})
        time.sleep(0.3)
        lifecycle(steer['uuid'], 'queued')
        lifecycle(FIRST['uuid'], 'completed')
        lifecycle(steer['uuid'], 'started')
        time.sleep(0.3)
        result({'status': 'message', 'message': 'second', 'model': None, 'assetIDs': []})
        lifecycle(steer['uuid'], 'completed')
        """)
        defer { fixture.remove() }
        let job = fixture.job()
        defer { job.cancel() }
        let task = Task { try await job.run(input: Data("initial request".utf8)) }
        try await waitUntil { job.canSteer }
        let accepted = try await job.steer(text: "One more change")
        XCTAssertEqual(accepted, "session-1")
        let data = try await task.value
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["message"] as? String, "second")
    }

    func testPermissionPromptsAreDeclinedInsteadOfWaitingForAPerson() async throws {
        let fixture = try ClaudeFixture(scenario: """
        init()
        send({'type': 'control_request', 'request_id': 'perm-1', 'request': {'subtype': 'can_use_tool', 'tool_name': 'Write', 'input': {'file_path': '/etc/hosts'}}})
        reply = read()
        decision = reply['response']['response']['behavior'] if reply['response']['request_id'] == 'perm-1' else 'unexpected'
        result({'status': 'message', 'message': decision, 'model': None, 'assetIDs': []})
        """)
        defer { fixture.remove() }
        let capture = ClaudeCapture()
        let data = try await fixture.job(capture: capture).run(input: Data("initial".utf8))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["message"] as? String, "deny")
        XCTAssertTrue(capture.events.contains { $0.title == "Interactive request declined" && $0.input == "Write" })
    }

    func testUnavailableLADToolsFailTheTaskPromptly() async throws {
        let fixture = try ClaudeFixture(scenario: "init(status='failed')\ntime.sleep(20)")
        defer { fixture.remove() }
        let started = Date()
        do {
            _ = try await fixture.job().run(input: Data("initial".utf8))
            XCTFail("A task without LAD tools must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("CAD tools could not start"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testErrorResultsReportTheCLIExplanation() async throws {
        let fixture = try ClaudeFixture(scenario: """
        init()
        send({'type': 'result', 'subtype': 'success', 'is_error': True, 'result': 'Not logged in · Please run /login'})
        """)
        defer { fixture.remove() }
        do {
            _ = try await fixture.job().run(input: Data("initial".utf8))
            XCTFail("An error result must fail the task")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Please run /login"))
        }
        let missing = try ClaudeFixture(scenario: "init()\nsend({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'plain text'})")
        defer { missing.remove() }
        do {
            _ = try await missing.job().run(input: Data("initial".utf8))
            XCTFail("A result without a structured response must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("structured CAD response"))
        }
    }

    func testStopInterruptsAndKillsAnUnresponsiveCLI() async throws {
        let fixture = try ClaudeFixture(scenario: """
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        init()
        read()
        time.sleep(30)
        """)
        defer { fixture.remove() }
        let job = fixture.job()
        let task = Task { try await job.run(input: Data("initial".utf8)) }
        try await waitUntil { job.canSteer }
        let started = Date()
        job.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the task")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let requests = try fixture.requests()
        XCTAssertTrue(requests.contains { ($0["request"] as? [String: Any])?["subtype"] as? String == "interrupt" })
    }

    func testArgumentsConfineEditsAndCommandsToTheTaskWorkspace() throws {
        let workspace = URL(fileURLWithPath: "/tmp/LAD-Claude-task")
        let schema = Data(#"{"type":"object","properties":{"status":{"type":"string"}}}"#.utf8)
        let arguments = try ClaudeCodeJob.arguments(model: "opus", effort: "xhigh", schema: schema, workspace: workspace,
                                                    python: "/runtime/bin/python3", server: URL(fileURLWithPath: "/app/agent_server.py"))
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        for flag in ["-p", "--no-session-persistence", "--strict-mcp-config", "--replay-user-messages", "--verbose"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        XCTAssertEqual(value(after: "--input-format"), "stream-json")
        XCTAssertEqual(value(after: "--output-format"), "stream-json")
        XCTAssertEqual(value(after: "--permission-mode"), "acceptEdits")
        XCTAssertEqual(value(after: "--model"), "opus")
        XCTAssertEqual(value(after: "--effort"), "xhigh")
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value(after: "--settings")).utf8)) as? [String: Any])
        let sandbox = try XCTUnwrap(settings["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox["autoAllowBashIfSandboxed"] as? Bool, true)
        XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false)
        let allowed = try XCTUnwrap((settings["permissions"] as? [String: Any])?["allow"] as? [String])
        XCTAssertFalse(allowed.contains { ["Bash", "Edit", "Write"].contains($0) }, "Edits and commands are limited by the workspace and sandbox")
        let mcp = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value(after: "--mcp-config")).utf8)) as? [String: Any])
        let lad = try XCTUnwrap((mcp["mcpServers"] as? [String: Any])?["lad"] as? [String: Any])
        XCTAssertEqual(lad["command"] as? String, "/runtime/bin/python3")
        XCTAssertEqual(lad["args"] as? [String], ["/app/agent_server.py", "--workspace", workspace.path])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value(after: "--json-schema")).utf8)) as? [String: Any])
        for model in ["", "default"] {
            let defaults = try ClaudeCodeJob.arguments(model: model, effort: nil, schema: schema, workspace: workspace,
                                                       python: "/runtime/bin/python3", server: URL(fileURLWithPath: "/app/agent_server.py"))
            XCTAssertFalse(defaults.contains("--model"))
            XCTAssertFalse(defaults.contains("--effort"))
        }
    }

    func testTaskEnvironmentNeverUpdatesTheInstallationOrInheritsAnotherSession() async throws {
        let fixture = try ClaudeFixture(scenario: "init()\nresult({'status': 'message', 'message': 'ok', 'model': None, 'assetIDs': []})")
        defer { fixture.remove() }
        setenv("CLAUDECODE", "1", 1)
        defer { unsetenv("CLAUDECODE") }
        _ = try await fixture.job(environment: ["TMPDIR": fixture.directory.appendingPathComponent("tmp").path]).run(input: Data("initial".utf8))
        let environment = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("environment.json"))) as? [String: String])
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1")
        XCTAssertEqual(environment["TMPDIR"], fixture.directory.appendingPathComponent("tmp").path)
        XCTAssertEqual(environment["PATH"]?.split(separator: ":").first.map(String.init), fixture.directory.path)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { throw NSError(domain: "ClaudeCodeJobTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The task did not become ready"]) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class ClaudeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [CodexProgressMessage] = []
    private var storedEvents: [ProjectActivityEvent] = []
    private var storedAvailability: [Bool] = []
    var messages: [CodexProgressMessage] { lock.lock(); defer { lock.unlock() }; return storedMessages }
    var events: [ProjectActivityEvent] { lock.lock(); defer { lock.unlock() }; return storedEvents }
    var availability: [Bool] { lock.lock(); defer { lock.unlock() }; return storedAvailability }
    func append(_ message: CodexProgressMessage) { lock.lock(); storedMessages.append(message); lock.unlock() }
    func append(_ event: ProjectActivityEvent) { lock.lock(); storedEvents.append(event); lock.unlock() }
    func setAvailability(_ value: Bool) { lock.lock(); storedAvailability.append(value); lock.unlock() }
}

/// A stream-json CLI fixture using the frame shapes Claude Code emits.
private struct ClaudeFixture {
    let directory: URL
    let executable: URL

    init(scenario: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-Claude-Job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        executable = directory.appendingPathComponent("claude")
        let body = scenario.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        let script = """
        #!/usr/bin/python3
        import json, os, signal, sys, time, uuid
        ROOT = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(ROOT, 'arguments.json'), 'w') as f: json.dump(sys.argv[1:], f)
        with open(os.path.join(ROOT, 'environment.json'), 'w') as f: json.dump(dict(os.environ), f)
        def send(frame): print(json.dumps(frame), flush=True)
        def record(frame):
            with open(os.path.join(ROOT, 'requests.jsonl'), 'a') as f: f.write(json.dumps(frame) + '\\n')
        def read():
            line = sys.stdin.readline()
            if not line: sys.exit(0)
            frame = json.loads(line); record(frame); return frame
        def init(status='connected'):
            send({'type': 'system', 'subtype': 'init', 'session_id': 'session-1', 'model': 'claude-test',
                  'mcp_servers': [{'name': 'lad', 'status': status}]})
        def lifecycle(identity, state): send({'type': 'command_lifecycle', 'command_uuid': identity, 'state': state})
        def assistant(block, parent=None):
            send({'type': 'assistant', 'uuid': str(uuid.uuid4()), 'parent_tool_use_id': parent, 'message': {'content': [block]}})
        def text(value): assistant({'type': 'text', 'text': value})
        def tool(identity, name, values): assistant({'type': 'tool_use', 'id': identity, 'name': name, 'input': values})
        def tool_result(identity, content, error=False):
            send({'type': 'user', 'parent_tool_use_id': None, 'message': {'content': [{'type': 'tool_result', 'tool_use_id': identity, 'content': content, 'is_error': error}]}})
        def result(output):
            send({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': json.dumps(output), 'structured_output': output, 'num_turns': 2})
        def scenario():
        \(body)
        FIRST = read()
        lifecycle(FIRST['uuid'], 'queued')
        lifecycle(FIRST['uuid'], 'started')
        scenario()
        while True:
            read()
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func requests() throws -> [[String: Any]] {
        try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func job(capture: ClaudeCapture = ClaudeCapture(), environment: [String: String] = [:]) -> ClaudeCodeJob {
        ClaudeCodeJob(executable: executable, arguments: ClaudeCodeJob.controlArguments + ["--replay-user-messages"], directory: directory,
            onProgress: { _ in }, onMessage: { capture.append($0) }, onActivity: { capture.append($0) },
            onSteeringAvailability: { capture.setAvailability($0) }, environment: environment)
    }
}
