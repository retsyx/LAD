import AppKit
import Darwin
import Foundation
import XCTest
@testable import LAD

final class CADAgentPermissionBridgeTests: XCTestCase {
    @MainActor
    func testPermissionSchemaAndPolicyDecisionsRoundTripWithoutExecutingAnything() async throws {
        let preferences = try PermissionBridgePreferences()
        defer { preferences.remove() }
        let presenter = PermissionBridgePresenter()
        let controller = AgentPermissionController(defaults: preferences.defaults, presenter: presenter)
        controller.policy = .alwaysDeny
        let fixture = try PermissionBridgeFixture(controller: controller)
        defer { fixture.close() }

        let initialized = try await rpc(fixture.client, method: "initialize", parameters: ["protocolVersion": "2024-11-05"])
        XCTAssertTrue((initialized["instructions"] as? String)?.contains("lad_request_permission") == true)
        let listed = try await rpc(fixture.client, method: "tools/list")
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        let permission = try XCTUnwrap(tools.first { $0["name"] as? String == "lad_request_permission" })
        let schema = try XCTUnwrap(permission["inputSchema"] as? [String: Any])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["operation", "reason"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["operation", "reason"])

        // An operation describes a requested action. Even an allowance must not
        // launch a command, create a file, or require the deliberately absent CAD runtime.
        let marker = fixture.root.appendingPathComponent("permission-must-not-execute.txt")
        let arguments = ["operation": "touch \(marker.path)", "reason": "A permission-only integration check"]
        let denied = try object(try await tool(fixture.client, arguments: arguments))
        XCTAssertEqual(denied["allowed"] as? Bool, false)
        XCTAssertEqual(denied["source"] as? String, "policy")
        XCTAssertEqual(denied["executionPerformed"] as? Bool, false)
        XCTAssertEqual(denied["scope"] as? String, "task_workspace")

        controller.policy = .alwaysAllow
        let allowed = try object(try await tool(fixture.client, arguments: arguments))
        XCTAssertEqual(allowed["allowed"] as? Bool, true)
        XCTAssertEqual(allowed["source"] as? String, "policy")
        XCTAssertEqual(allowed["executionPerformed"] as? Bool, false)
        XCTAssertEqual((allowed["workspace"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, fixture.root.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(presenter.entries.isEmpty, "Stored policies must not display a prompt.")
        let completed = fixture.capture.events.filter { $0.title == "lad_request_permission" && $0.status == "completed" }
        XCTAssertEqual(completed.count, 2, "A denial is a permission decision rather than a tool failure.")
        XCTAssertTrue(completed.allSatisfy { $0.input?.contains(arguments["reason"]!) == true && $0.durationSeconds != nil })
        XCTAssertEqual(Set(fixture.capture.events.map(\.title)), ["lad_request_permission"])
    }

    @MainActor
    func testNativeArgumentValidationRejectsCommandPayloadsBeforeAsking() async throws {
        let preferences = try PermissionBridgePreferences()
        defer { preferences.remove() }
        let presenter = PermissionBridgePresenter()
        let controller = AgentPermissionController(defaults: preferences.defaults, presenter: presenter)
        controller.policy = .ask
        let fixture = try PermissionBridgeFixture(controller: controller)
        defer { fixture.close() }
        let invalidArguments: [[String: Any]] = [
            ["operation": "Install a helper", "reason": "Needed for analysis", "command": "touch should-not-run"],
            ["operation": " \n", "reason": "Needed for analysis"],
            ["operation": "Use a helper", "reason": String(repeating: "x", count: 2_001)]
        ]
        for arguments in invalidArguments {
            let result = try await tool(fixture.client, arguments: arguments, expectError: true)
            XCTAssertFalse(try text(result).isEmpty)
        }
        XCTAssertTrue(presenter.entries.isEmpty)
        XCTAssertEqual(controller.policy, .ask)
        XCTAssertEqual(fixture.capture.events.filter { $0.status == "failed" }.count, 3)
    }

    @MainActor
    func testRememberedUserDecisionAppliesToAnotherDesignBridge() async throws {
        let preferences = try PermissionBridgePreferences()
        defer { preferences.remove() }
        let presenter = PermissionBridgePresenter()
        let controller = AgentPermissionController(defaults: preferences.defaults, presenter: presenter)
        controller.policy = .ask
        let first = try PermissionBridgeFixture(controller: controller)
        let second = try PermissionBridgeFixture(controller: controller)
        defer { first.close(); second.close() }
        let pending = Task { try await tool(first.client, arguments: ["operation": "Use supplied helper", "reason": "Inspect the reference geometry"]) }
        try await waitUntil { presenter.entries.count == 1 }
        XCTAssertEqual(presenter.entries[0].prompt.operation, "Use supplied helper")
        XCTAssertEqual(presenter.entries[0].prompt.reason, "Inspect the reference geometry")
        presenter.respond(0, with: .decision(allowed: true, remember: true))
        let granted = try object(try await pending.value)
        XCTAssertEqual(granted["allowed"] as? Bool, true)
        XCTAssertEqual(granted["source"] as? String, "user")
        XCTAssertEqual(granted["rememberedPolicy"] as? String, AgentPermissionPolicy.alwaysAllow.rawValue)
        XCTAssertEqual(controller.policy, .alwaysAllow)

        let inherited = try object(try await tool(second.client, arguments: ["operation": "Use another supplied helper", "reason": "Inspect this design"]))
        XCTAssertEqual(inherited["allowed"] as? Bool, true)
        XCTAssertEqual(inherited["source"] as? String, "policy")
        XCTAssertEqual(presenter.entries.count, 1)
        XCTAssertEqual(AgentPermissionController(defaults: preferences.defaults, presenter: presenter).policy, .alwaysAllow)
        XCTAssertTrue(first.capture.events.contains { $0.status == "completed" })
        XCTAssertTrue(second.capture.events.contains { $0.status == "completed" })
    }

    @MainActor
    func testStoppingOneDesignCancelsItsPromptAndAuditWithoutDenyingAnotherDesign() async throws {
        let preferences = try PermissionBridgePreferences()
        defer { preferences.remove() }
        let presenter = PermissionBridgePresenter()
        let controller = AgentPermissionController(defaults: preferences.defaults, presenter: presenter)
        controller.policy = .ask
        let first = try PermissionBridgeFixture(controller: controller)
        let second = try PermissionBridgeFixture(controller: controller)
        defer { first.close(); second.close() }
        let firstCall = Task { try await tool(first.client, arguments: ["operation": "First design operation", "reason": "First reason"], expectError: true) }
        try await waitUntil { presenter.entries.count == 1 }
        let secondCall = Task { try await tool(second.client, arguments: ["operation": "Second design operation", "reason": "Second reason"]) }
        try await waitUntil { second.capture.events.contains { $0.status == "running" } }
        XCTAssertEqual(presenter.entries.count, 1, "The shared controller must serialize prompts.")

        first.bridge.stop()
        _ = try await firstCall.value
        try await waitUntil { first.capture.events.contains { $0.status == "canceled" } && presenter.entries.count == 2 }
        XCTAssertTrue(presenter.dismissed.contains(0))
        XCTAssertFalse(first.capture.events.contains { $0.status == "completed" })
        XCTAssertEqual(controller.policy, .ask)

        // A late native completion from the dismissed prompt cannot remember a
        // policy or complete the second design's still-pending request.
        presenter.respond(0, with: .decision(allowed: true, remember: true))
        XCTAssertEqual(controller.policy, .ask)
        XCTAssertFalse(second.capture.events.contains { $0.status == "completed" })
        presenter.respond(1, with: .decision(allowed: false, remember: false))
        let denial = try object(try await secondCall.value)
        XCTAssertEqual(denial["allowed"] as? Bool, false)
        XCTAssertEqual(denial["source"] as? String, "user")
        XCTAssertEqual(controller.policy, .ask)
        XCTAssertTrue(second.capture.events.contains { $0.status == "completed" })
        XCTAssertFalse(second.capture.events.contains { $0.status == "canceled" })
    }

    @MainActor
    private func rpc(_ client: PermissionMCPClient, method: String, parameters: [String: Any] = [:]) async throws -> [String: Any] {
        let identity = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": identity, "method": method, "params": parameters])
        let response = try await client.request(data)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["id"] as? String, identity)
        XCTAssertNil(envelope["error"], String(describing: envelope["error"]))
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    @MainActor
    private func tool(_ client: PermissionMCPClient, arguments: [String: Any], expectError: Bool = false) async throws -> [String: Any] {
        let result = try await rpc(client, method: "tools/call", parameters: ["name": "lad_request_permission", "arguments": arguments])
        let diagnostic = try text(result)
        XCTAssertEqual(result["isError"] as? Bool ?? false, expectError, diagnostic)
        return result
    }

    private func text(_ result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first { $0["type"] as? String == "text" }?["text"] as? String)
    }

    private func object(_ result: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LADError.message("The permission bridge did not reach its expected state.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class PermissionBridgePresenter: AgentPermissionPresenting {
    struct Entry {
        let prompt: AgentPermissionPrompt
        let completion: @MainActor (AgentPermissionPromptResponse) -> Void
    }
    var entries: [Entry] = []
    var dismissed = Set<Int>()

    func present(_ prompt: AgentPermissionPrompt, completion: @escaping @MainActor (AgentPermissionPromptResponse) -> Void) -> AgentPermissionPresentation {
        let index = entries.count
        entries.append(Entry(prompt: prompt, completion: completion))
        return AgentPermissionPresentation { [weak self] in self?.dismissed.insert(index) }
    }

    func respond(_ index: Int, with response: AgentPermissionPromptResponse) { entries[index].completion(response) }
}

private struct PermissionBridgePreferences {
    let name = "LAD.PermissionBridgeTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }
    func remove() { defaults.removePersistentDomain(forName: name) }
}

@MainActor
private final class PermissionBridgeFixture {
    let root: URL
    let bridge: CADAgentBridge
    let client: PermissionMCPClient
    let capture = PermissionBridgeActivityCapture()

    init(controller: AgentPermissionController) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-permission-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = try EngineArtifact.canonicalDirectory(directory)
        let capture = capture
        bridge = try CADAgentBridge(workspace: root, python: "/unavailable/permission-test-cad-python", threads: 1,
            current: nil, currentPreview: nil, engine: EngineService(), viewport: nil, hiddenSolids: [], solidColors: [:],
            onActivity: { capture.append($0) }, permissionController: controller)
        guard let python = [EngineService.defaultPython, "/usr/bin/python3", "/opt/homebrew/bin/python3"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            bridge.stop()
            try? FileManager.default.removeItem(at: root)
            throw XCTSkip("Python is required for LAD's dependency-free MCP stdio adapter.")
        }
        do { client = try PermissionMCPClient(workspace: root, python: python) }
        catch {
            bridge.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        bridge.start()
    }

    func close() {
        bridge.stop()
        client.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PermissionBridgeActivityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProjectActivityEvent] = []
    var events: [ProjectActivityEvent] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: ProjectActivityEvent) { lock.lock(); values.append(value); lock.unlock() }
}

/// Keep pipe I/O off the main actor so the real bridge and permission controller
/// can continue handling native requests, responses and cancellation.
private final class PermissionMCPClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "LAD permission MCP integration")
    private var buffered = Data()

    init(workspace: URL, python: String) throws {
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [ResourcePaths.root.appendingPathComponent("Engine/agent_server.py").path, "--workspace", workspace.path]
        process.currentDirectoryURL = workspace
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        try process.run()
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func request(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
                    continuation.resume(returning: try readLine())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func readLine() throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = ContinuousClock.now + .seconds(8)
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while ContinuousClock.now < deadline {
            if let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered.prefix(upTo: newline))
                buffered.removeSubrange(...newline)
                return line
            }
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            if Darwin.poll(&descriptorState, 1, 40) > 0 {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    buffered.append(contentsOf: bytes.prefix(count))
                    guard buffered.count <= 1_048_576 else { throw LADError.message("The permission MCP test response is oversized.") }
                } else if !process.isRunning { throw LADError.message("The MCP adapter exited before responding.") }
            } else if !process.isRunning { throw LADError.message("The MCP adapter exited before responding.") }
        }
        throw LADError.message("The permission MCP adapter did not respond within its test deadline.")
    }
}
