import AppKit
import Darwin
import Foundation
import XCTest
@testable import LAD

final class CADAgentBridgeTests: XCTestCase {
    @MainActor
    func testInvocationConfigurationQuotesPathsAndStaysLocalToTheInvocation() throws {
        let workspace = URL(fileURLWithPath: "/tmp/LAD workspace \"quoted\" \\ ü")
        let python = "/runtime with spaces/\"quoted\"\\python"
        let server = URL(fileURLWithPath: "/engine with spaces/agent_server.py")
        let args = try CADAgentBridge.codexArguments(workspace: workspace, python: python, server: server)
        XCTAssertEqual(args.count % 2, 0)
        var values = [String: String]()
        for index in stride(from: 0, to: args.count, by: 2) {
            XCTAssertEqual(args[index], "--config")
            let assignment = args[index + 1]
            let split = try XCTUnwrap(assignment.firstIndex(of: "="))
            values[String(assignment[..<split])] = String(assignment[assignment.index(after: split)...])
        }
        let command = try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(values["mcp_servers.lad.command"]).utf8))
        let serverArgs = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(values["mcp_servers.lad.args"]).utf8))
        XCTAssertEqual(command, python)
        XCTAssertEqual(serverArgs, [server.path, "--workspace", workspace.path])
        XCTAssertEqual(values["mcp_servers.lad.required"], "true")
        XCTAssertEqual(values["sandbox_workspace_write.network_access"], "true")
        XCTAssertEqual(values["sandbox_workspace_write.writable_roots"], "[]")
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(args.contains("danger-full-access"))
        XCTAssertFalse(args.contains("mcp add"), "The app must configure its tools on this invocation rather than edit global Codex configuration.")
    }

    @MainActor
    func testRealStdioHandshakeToolDiscoveryAndTypedNativeFailuresAreAudited() async throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let capture = BridgeActivityCapture()
        let bridge = try makeBridge(workspace: fixture, capture: capture, python: "/unavailable/cad-python")
        let client = try NativeMCPTestClient(workspace: fixture, python: testPython(), server: serverURL)
        defer { bridge.stop(); client.close() }
        bridge.start()
        let initialized = try await rpc(client, method: "initialize", params: ["protocolVersion": "2024-11-05",
            "capabilities": [:], "clientInfo": ["name": "LAD integration test", "version": "1"]])
        XCTAssertEqual((initialized["serverInfo"] as? [String: Any])?["name"] as? String, "LAD")
        XCTAssertTrue((initialized["instructions"] as? String)?.contains("lad_build") == true)
        XCTAssertTrue((initialized["instructions"] as? String)?.contains("lad_convert_kicad") == true)
        try await client.notify(method: "notifications/initialized")
        let listed = try await rpc(client, method: "tools/list")
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(Set(["lad_runtime", "lad_build", "lad_inspect", "lad_measure", "lad_validate", "lad_render", "lad_screenshot", "lad_export_step", "lad_convert_kicad", "lad_import"]).isSubset(of: names))
        let render = try XCTUnwrap(tools.first { $0["name"] as? String == "lad_render" })
        XCTAssertNotNil(render["inputSchema"])

        // These fail before resolving any CAD runtime. Their public MCP result
        // is a typed tool error and the native bridge retains exact input/output.
        let missing = try await tool(client, name: "lad_inspect", arguments: [:], expectError: true)
        XCTAssertTrue(try text(missing).contains("There is no current design"))
        let escape = try await tool(client, name: "lad_build", arguments: ["programPath": "../outside.py"], expectError: true)
        XCTAssertTrue(try text(escape).contains("workspace"))
        let completed = capture.events.filter { $0.status == "failed" }
        XCTAssertEqual(Set(completed.map(\.title)), ["lad_inspect", "lad_build"])
        XCTAssertTrue(completed.first { $0.title == "lad_build" }?.input?.contains("../outside.py") == true)
        XCTAssertTrue(completed.allSatisfy { $0.output?.isEmpty == false && $0.durationSeconds != nil })
        for folder in [fixture.appendingPathComponent(".lad-tools"), fixture.appendingPathComponent(".lad-tools/requests")] {
            let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
        }
    }

    @MainActor
    func testStoppingTheBridgeReleasesARealStdioCallWaitingForNativeTools() async throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let bridge = try makeBridge(workspace: fixture, capture: BridgeActivityCapture(), python: "/unavailable/cad-python")
        let client = try NativeMCPTestClient(workspace: fixture, python: testPython(), server: serverURL)
        defer { bridge.stop(); client.close() }
        // Leave the native loop unstarted so the server is genuinely waiting
        // for its first filesystem response when cancellation arrives.
        let pending = Task { try await tool(client, name: "lad_inspect", arguments: [:], expectError: true) }
        let requests = fixture.appendingPathComponent(".lad-tools/requests")
        try await waitUntil {
            (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil).contains { $0.pathExtension == "json" }) == true
        }
        let stoppedAt = ContinuousClock.now
        bridge.stop()
        let result = try await pending.value
        XCTAssertTrue(try text(result).contains("stopped"))
        XCTAssertLessThan(stoppedAt.duration(to: ContinuousClock.now), .seconds(2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".lad-tools/closed").path))
    }

    @MainActor
    func testNativeBuildInspectMeasureRenderAndExportRoundTripThroughMCP() async throws {
        try requireNativeRuntime()
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let capture = BridgeActivityCapture()
        let engine = EngineService()
        let bridge = try makeBridge(workspace: fixture, capture: capture, python: EngineService.defaultPython, engine: engine)
        let client = try NativeMCPTestClient(workspace: fixture, python: testPython(), server: serverURL)
        defer { bridge.stop(); client.close() }
        bridge.start()
        _ = try await rpc(client, method: "initialize", params: ["protocolVersion": "2024-11-05"])
        try await client.notify(method: "notifications/initialized")
        let runtime = try object(try await tool(client, name: "lad_runtime", arguments: [:]))
        XCTAssertEqual(runtime["pythonExecutable"] as? String, EngineService.defaultPython)
        XCTAssertTrue((runtime["capabilities"] as? [String])?.contains("lofts") == true)

        let script = """
        base = cq.Workplane('XY').box(20,10,4).val()
        pin = cq.Workplane('XY').circle(2).extrude(3).val().translate((30,0,0))
        result = cq.Assembly(name='Fixture', metadata={'lad_id':'fixture'})
        result.add(base, name='Base', metadata={'lad_id':'base'})
        result.add(pin, name='Pin', metadata={'lad_id':'pin'})
        """
        try Data(script.utf8).write(to: fixture.appendingPathComponent("program.py"), options: .atomic)
        let built = try object(try await tool(client, name: "lad_build", arguments: ["programPath": "program.py", "title": "Bridge fixture"]))
        let artifact = try XCTUnwrap(built["artifactID"] as? String)
        XCTAssertEqual(built["solids"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(built["volume"] as? Double), 800 + 12 * .pi, accuracy: 1e-7)
        let summaryResult = try await tool(client, name: "lad_inspect", arguments: ["artifactID": artifact])
        XCTAssertFalse(try text(summaryResult).contains(script),
                       "Tools must return file references and metadata, not inline complete CAD programs.")
        let inspected = try object(try await tool(client, name: "lad_inspect", arguments: ["artifactID": artifact, "kind": "parts"]))
        let parts = try XCTUnwrap(inspected["items"] as? [[String: Any]])
        XCTAssertEqual(Set(parts.compactMap { $0["name"] as? String }), ["Base", "Pin"])
        let measured = try object(try await tool(client, name: "lad_measure", arguments: ["artifactID": artifact, "solidIndices": [0]]))
        let metrics = try XCTUnwrap(measured["metrics"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap((metrics.first { $0["id"] as? String == "parts:volume" }?["values"] as? [Double])?.first), 800, accuracy: 1e-8)
        let valid = try object(try await tool(client, name: "lad_validate", arguments: ["artifactID": artifact]))
        XCTAssertEqual(valid["valid"] as? Bool, true)
        let rendered = try await tool(client, name: "lad_render", arguments: ["artifactID": artifact, "view": "isometric",
            "yawDegrees": 28.5, "elevationDegrees": 38.2, "rollDegrees": -12, "zoom": 1.5, "width": 512, "height": 512])
        let camera = try object(rendered)
        XCTAssertEqual(camera["customCamera"] as? Bool, true)
        XCTAssertEqual(camera["zoom"] as? Double, 1.5)
        XCTAssertEqual((camera["cameraParameters"] as? [String: Any])?["yawDegrees"] as? Double, 28.5)
        XCTAssertEqual((camera["cameraTransform"] as? [Double])?.count, 16)
        let image = try XCTUnwrap((rendered["content"] as? [[String: Any]])?.first { $0["type"] as? String == "image" })
        XCTAssertEqual(image["mimeType"] as? String, "image/png")
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(image["data"] as? String)))
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 512)
        XCTAssertEqual(bitmap.pixelsHigh, 512)
        let exported = try object(try await tool(client, name: "lad_export_step", arguments: ["artifactID": artifact, "solidIndices": [1], "path": "exports/pin.step"]))
        XCTAssertEqual(exported["solidIndices"] as? [Int], [1])
        let stepPath = try XCTUnwrap(exported["path"] as? String)
        XCTAssertTrue(stepPath.hasPrefix(fixture.path + "/"))
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: stepPath)).starts(with: Data("ISO-10303-21;".utf8)))
        let final = ModelSpec(title: "Final title", summary: "Final closeout", units: "mm", script: script)
        let reusable = try XCTUnwrap(bridge.tools.validatedPreview(for: final))
        XCTAssertEqual(reusable.solids, 2, "Final commit should reuse native geometry that the agent already built and reviewed.")

        let completed = capture.events.filter { $0.status == "completed" }
        XCTAssertTrue(Set(["lad_runtime", "lad_build", "lad_inspect", "lad_measure", "lad_validate", "lad_render", "lad_export_step"]).isSubset(of: Set(completed.map(\.title))))
        let imageAudit = try XCTUnwrap(completed.first { $0.title == "lad_render" }?.output)
        XCTAssertTrue(imageAudit.contains("image_path"))
        XCTAssertFalse(imageAudit.contains(try XCTUnwrap(image["data"] as? String)), "Derived PNG bytes must not be duplicated into the saved audit.")
    }

    @MainActor
    func testStoppingANativeBuildProducesCancellationAuditAndReleasesStdio() async throws {
        try requireNativeRuntime()
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let capture = BridgeActivityCapture()
        let bridge = try makeBridge(workspace: fixture, capture: capture, python: EngineService.defaultPython)
        let client = try NativeMCPTestClient(workspace: fixture, python: testPython(), server: serverURL)
        defer { bridge.stop(); client.close() }
        bridge.start()
        try Data("import time\ntime.sleep(60)\nresult = cq.Solid.makeBox(1,1,1)\n".utf8)
            .write(to: fixture.appendingPathComponent("slow.py"), options: .atomic)
        let pending = Task { try await tool(client, name: "lad_build", arguments: ["programPath": "slow.py"], expectError: true) }
        try await waitUntil { capture.events.contains { $0.title == "lad_build" && $0.status == "running" } }
        try await Task.sleep(for: .milliseconds(150))
        let stoppedAt = ContinuousClock.now
        bridge.stop()
        let result = try await pending.value
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertLessThan(stoppedAt.duration(to: ContinuousClock.now), .seconds(4))
        try await waitUntil { capture.events.contains { $0.title == "lad_build" && $0.status == "canceled" } }
        XCTAssertTrue(capture.events.last { $0.title == "lad_build" }?.output?.contains("canceled") == true)
    }

    private var serverURL: URL { ResourcePaths.root.appendingPathComponent("Engine/agent_server.py") }

    @MainActor
    private func makeBridge(workspace: URL, capture: BridgeActivityCapture, python: String, engine: EngineService? = nil) throws -> CADAgentBridge {
        try CADAgentBridge(workspace: workspace, python: python, threads: 2, current: nil, currentPreview: nil,
                           engine: engine ?? EngineService(), viewport: nil, hiddenSolids: [], solidColors: [:],
                           onActivity: { capture.append($0) })
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-MCP-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return try EngineArtifact.canonicalDirectory(directory)
    }

    @MainActor
    private func testPython() throws -> String {
        guard let python = [EngineService.defaultPython, "/usr/bin/python3", "/opt/homebrew/bin/python3"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Python is required to run the real dependency-free MCP stdio adapter.")
        }
        return python
    }

    @MainActor
    private func requireNativeRuntime() throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to check native CAD build/render/export through the real MCP bridge.")
        }
    }

    @MainActor
    private func rpc(_ client: NativeMCPTestClient, method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let response = try await client.request(data)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(envelope["id"] as? String, id)
        XCTAssertNil(envelope["error"], String(describing: envelope["error"]))
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    @MainActor
    private func tool(_ client: NativeMCPTestClient, name: String, arguments: [String: Any], expectError: Bool = false) async throws -> [String: Any] {
        let result = try await rpc(client, method: "tools/call", params: ["name": name, "arguments": arguments])
        let description = try text(result)
        XCTAssertEqual(result["isError"] as? Bool ?? false, expectError, description)
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
            guard ContinuousClock.now < deadline else { XCTFail("The bridge did not reach its expected state."); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class BridgeActivityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProjectActivityEvent] = []
    var events: [ProjectActivityEvent] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ event: ProjectActivityEvent) { lock.lock(); values.append(event); lock.unlock() }
}

/// Blocking stdio always runs on its own serial queue, leaving the main actor
/// available to poll filesystem requests and execute native LAD tool calls.
private final class NativeMCPTestClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "LAD MCP integration client")
    private var buffered = Data()

    init(workspace: URL, python: String, server: URL) throws {
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [server.path, "--workspace", workspace.path]
        process.currentDirectoryURL = workspace
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
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

    func notify(method: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func readLine() throws -> Data {
        let deadline = ContinuousClock.now + .seconds(90)
        let descriptor = output.fileHandleForReading.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while ContinuousClock.now < deadline {
            if let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered.prefix(upTo: newline))
                buffered.removeSubrange(...newline)
                return line
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollDescriptor, 1, 50)
            if ready > 0 {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    buffered.append(contentsOf: bytes.prefix(count))
                    guard buffered.count <= 64 * 1024 * 1024 else { throw LADError.message("The test MCP response is oversized.") }
                } else if !process.isRunning {
                    throw LADError.message("The MCP adapter exited before responding.")
                }
            } else if !process.isRunning { throw LADError.message("The MCP adapter exited before responding.") }
        }
        throw LADError.message("The MCP adapter did not respond within the integration test deadline.")
    }
}
