import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import LAD

final class CodexAppServerJobTests: XCTestCase {
    func testUnsupportedProtocolOperationsExplainHowToRepairCodex() async throws {
        for (method, code) in [("initialize", -32601), ("thread/start", -32602), ("turn/start", -32602)] {
            let fixture = try AppServerFixture(onTurn: "finish({'unexpected': True})", rejectMethod: method, rejectionCode: code)
            defer { fixture.remove() }
            do {
                _ = try await fixture.job().run(input: Data("initial request".utf8))
                XCTFail("Unsupported \(method) must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Update the app or CLI and check its configuration"))
                XCTAssertTrue(error.localizedDescription.contains("Unsupported \(method)"))
            }
            let requests = try fixture.requests()
            XCTAssertEqual(requests.filter { $0["method"] as? String == method }.count, 1,
                           "A rejected operation must not be retried or start another turn")
        }
    }

    func testSteeringUsesOneThreadAndOneTurnWithCapturedExecutionOptions() async throws {
        let fixture = try AppServerFixture(onSteer: """
        reply(rpc, {'turnId': 'turn-1'})
        finish({'supplement': params['input'][0]['text']})
        """)
        defer { fixture.remove() }
        let capture = AppServerCapture()
        let job = fixture.job(capture: capture)
        defer { job.cancel() }
        let task = Task { try await job.run(input: Data("initial request".utf8)) }
        try await waitUntil { job.canSteer }
        XCTAssertEqual(job.currentTurnID, "turn-1")
        let accepted = try await job.steer(text: "Make the wall 3 mm")
        XCTAssertEqual(accepted, "turn-1")
        let response = try await task.value
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: String])
        XCTAssertEqual(object["supplement"], "Make the wall 3 mm")
        let requests = try fixture.requests()
        let initialization = try XCTUnwrap(requests.first { $0["method"] as? String == "initialize" }?["params"] as? [String: Any])
        XCTAssertEqual(initialization["clientInfo"] as? [String: String], CodexAppServerClient.info())
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
        let start = try XCTUnwrap(requests.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        XCTAssertEqual(start["model"] as? String, "captured-model")
        XCTAssertEqual(start["effort"] as? String, "ultra")
        XCTAssertNotNil(start["outputSchema"] as? [String: Any])
        XCTAssertEqual(start["approvalPolicy"] as? String, "never")
        let policy = try XCTUnwrap(start["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(policy["type"] as? String, "workspaceWrite")
        XCTAssertEqual(policy["writableRoots"] as? [String], [fixture.directory.path])
        XCTAssertEqual(policy["excludeSlashTmp"] as? Bool, true)
        XCTAssertEqual(policy["excludeTmpdirEnvVar"] as? Bool, true)
        let steer = try XCTUnwrap(requests.first { $0["method"] as? String == "turn/steer" }?["params"] as? [String: Any])
        XCTAssertEqual(steer["expectedTurnId"] as? String, "turn-1")
        XCTAssertEqual(steer["threadId"] as? String, "thread-1")
        XCTAssertFalse(job.canSteer)
        XCTAssertNil(job.currentTurnID)
        XCTAssertEqual(capture.availability.first, true)
        XCTAssertEqual(capture.availability.last, false)
    }

    func testCompletionBeforeSteeringAcknowledgementStillAcceptsTheSameTurn() async throws {
        let fixture = try AppServerFixture(onSteer: """
        finish({'complete': True})
        time.sleep(0.08)
        reply(rpc, {'turnId': 'turn-1'})
        """)
        defer { fixture.remove() }
        let job = fixture.job()
        defer { job.cancel() }
        let task = Task { try await job.run(input: Data("initial".utf8)) }
        try await waitUntil { job.canSteer }
        let accepted = try await job.steer(text: "extra information")
        XCTAssertEqual(accepted, "turn-1")
        let response = try await task.value
        XCTAssertFalse(response.isEmpty)
        do {
            _ = try await job.steer(text: "too late")
            XCTFail("Completed turns cannot receive a new message")
        } catch let error as CodexSteeringError {
            XCTAssertFalse(error.mayHaveBeenAccepted)
        }
        XCTAssertEqual(try fixture.requests().filter { $0["method"] as? String == "turn/start" }.count, 1)
    }

    func testExplicitRejectionDiffersFromLostAcknowledgement() async throws {
        for losesAcknowledgement in [false, true] {
            let fixture = try AppServerFixture(onSteer: losesAcknowledgement ? """
            finish({'complete': True})
            sys.exit(0)
            """ : """
            send({'id': rpc['id'], 'error': {'code': -32600, 'message': 'Turn has already ended'}})
            finish({'complete': True})
            """)
            defer { fixture.remove() }
            let job = fixture.job()
            defer { job.cancel() }
            let task = Task { try await job.run(input: Data("initial".utf8)) }
            try await waitUntil { job.canSteer }
            do {
                _ = try await job.steer(text: "extra")
                XCTFail("Missing/rejected acknowledgement must fail")
            } catch let error as CodexSteeringError {
                XCTAssertEqual(error.mayHaveBeenAccepted, losesAcknowledgement,
                    "Uncertain acceptance must pause automatic queue replay")
            }
            let response = try await task.value
            XCTAssertFalse(response.isEmpty)
        }
    }

    func testRootCommentaryAndPublicActivityStreamWithoutPrivateReasoningOrFinalJSON() async throws {
        let fixture = try AppServerFixture(onTurn: """
        note('item/started', {'item': {'id': 'message', 'type': 'agentMessage', 'phase': 'commentary', 'text': ''}})
        note('item/agentMessage/delta', {'itemId': 'message', 'delta': 'I will check the wall.'})
        note('item/completed', {'item': {'id': 'private', 'type': 'reasoning', 'text': 'PRIVATE_REASONING'}})
        note('item/completed', {'item': {'id': 'private-message', 'type': 'agentMessage', 'phase': 'analysis', 'text': 'PRIVATE_ANALYSIS'}})
        note('item/agentMessage/delta', {'itemId': 'unknown-phase', 'delta': 'SOURCE_FRAGMENT'})
        note('item/completed', {'item': {'id': 'unknown-phase', 'type': 'agentMessage', 'phase': 'final_answer', 'text': '{"opaque":true}'}})
        note('item/started', {'item': {'id': 'command', 'type': 'commandExecution', 'command': 'python check.py', 'status': 'inProgress'}})
        note('item/commandExecution/outputDelta', {'itemId': 'command', 'delta': 'dimensions checked'})
        note('item/completed', {'item': {'id': 'command', 'type': 'commandExecution', 'command': 'python check.py', 'status': 'completed', 'exitCode': 0, 'durationMs': 20}})
        note('item/completed', {'item': {'id': 'native', 'type': 'mcpToolCall', 'server': 'lad', 'tool': 'lad_build', 'arguments': {}, 'result': {'content': []}, 'status': 'completed'}})
        note('item/completed', {'item': {'id': 'external', 'type': 'mcpToolCall', 'server': 'other', 'tool': 'image', 'arguments': {}, 'result': {'content': [{'type': 'image', 'mimeType': 'image/png', 'data': 'BASE64_SENTINEL'}]}, 'status': 'completed'}})
        finish({'final': True})
        """)
        defer { fixture.remove() }
        let capture = AppServerCapture()
        let job = fixture.job(capture: capture)
        _ = try await job.run(input: Data("initial".utf8))
        XCTAssertEqual(capture.messages.map(\.text), ["I will check the wall."])
        let events = capture.events
        let completed = try XCTUnwrap(events.last { $0.category == "command" && $0.status == "completed" })
        XCTAssertEqual(completed.output, "dimensions checked")
        XCTAssertEqual(completed.durationSeconds, 0.02)
        XCTAssertFalse(events.contains { $0.title.contains("lad_build") })
        let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for forbidden in ["PRIVATE_REASONING", "PRIVATE_ANALYSIS", "BASE64_SENTINEL", "SOURCE_FRAGMENT", "opaque", "\"final\""] {
            XCTAssertFalse(serialized.contains(forbidden), "Must omit \(forbidden) from execution records")
        }
        XCTAssertTrue(serialized.contains("encodedByteCount"))
    }

    func testCompletedImageViewsRetainExactWorkspaceImagesAfterTaskCleanup() async throws {
        let fixture = try AppServerFixture(onTurn: """
        note('item/started', {'item': {'id': 'png', 'type': 'imageView', 'path': os.path.join(ROOT, 'images', 'render.png')}})
        note('item/completed', {'item': {'id': 'png', 'type': 'imageView', 'path': os.path.join(ROOT, 'images', 'render.png')}})
        note('item/completed', {'threadId': 'child-thread', 'item': {'id': 'jpeg', 'type': 'imageView', 'path': 'images/reference.jpg'}})
        finish({'imagesViewed': True})
        """)
        defer { fixture.remove() }
        let imageDirectory = fixture.directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: false)
        let png = try imageData(type: "public.png")
        let jpeg = try imageData(type: "public.jpeg")
        let pngURL = imageDirectory.appendingPathComponent("render.png")
        try png.write(to: pngURL)
        try jpeg.write(to: imageDirectory.appendingPathComponent("reference.jpg"))
        let capture = AppServerCapture()
        let result = try await fixture.job(capture: capture).run(input: Data("Inspect these images".utf8))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: result) as? [String: Bool])?["imagesViewed"], true)
        fixture.remove()

        let events = capture.events.filter { $0.title == "imageView" }
        XCTAssertEqual(events.count, 3)
        XCTAssertNil(events.first?.imageData, "Started events retain metadata only.")
        let completedPNG = try XCTUnwrap(events.first { $0.id == "server:thread-1:png" && $0.status == "completed" })
        let completedJPEG = try XCTUnwrap(events.first { $0.id == "server:child-thread:jpeg" })
        XCTAssertEqual(completedPNG.imageData, png)
        XCTAssertEqual(completedJPEG.imageData, jpeg, "Image viewing preserves the original encoding and bytes.")
        let output = try XCTUnwrap(completedPNG.output)
        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        XCTAssertEqual(metadata, ["id": "png", "type": "imageView", "path": pngURL.path])
        let archived = try JSONEncoder().encode(events)
        XCTAssertTrue(try JSONDecoder().decode([ProjectActivityEvent].self, from: archived).allSatisfy { $0.imageData == nil })
    }

    func testUnsafeOrUnavailableImageViewsKeepMetadataWithoutFailingTheTask() async throws {
        let fixture = try AppServerFixture(onTurn: """
        paths = {
            'missing': 'missing.png',
            'empty': '',
            'no-path': None,
            'directory': 'images',
            'oversized': 'oversized.png',
            'traversal': '../' + os.path.basename(ROOT) + '-outside/reference.png',
            'outside': ROOT + '-outside/reference.png',
            'symlink': 'linked.png',
            'parent-symlink': 'linked-directory/reference.png',
            'hardlink': 'hardlinked.png',
            'pipe': 'pipe.png',
        }
        for id, path in paths.items():
            note('item/completed', {'item': {'id': id, 'type': 'imageView', 'path': path}})
        finish({'imagesUnavailable': True})
        """)
        defer { fixture.remove() }
        let manager = FileManager.default
        let outside = URL(fileURLWithPath: fixture.directory.path + "-outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: outside) }
        let reference = outside.appendingPathComponent("reference.png")
        try imageData(type: "public.png").write(to: reference)
        try manager.createDirectory(at: fixture.directory.appendingPathComponent("images"), withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: fixture.directory.appendingPathComponent("linked.png"), withDestinationURL: reference)
        try manager.createSymbolicLink(at: fixture.directory.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        try manager.linkItem(at: reference, to: fixture.directory.appendingPathComponent("hardlinked.png"))
        let oversized = fixture.directory.appendingPathComponent("oversized.png")
        XCTAssertTrue(manager.createFile(atPath: oversized.path, contents: nil))
        let file = try FileHandle(forWritingTo: oversized)
        try file.truncate(atOffset: 32 * 1024 * 1024 + 1)
        try file.close()
        XCTAssertEqual(Darwin.mkfifo(fixture.directory.appendingPathComponent("pipe.png").path, 0o600), 0)
        let capture = AppServerCapture()
        let result = try await fixture.job(capture: capture).run(input: Data("Inspect these images".utf8))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: result) as? [String: Bool])?["imagesUnavailable"], true)
        let events = capture.events.filter { $0.title == "imageView" }
        XCTAssertEqual(events.count, 11)
        XCTAssertTrue(events.allSatisfy { $0.status == "completed" && $0.imageData == nil && $0.output != nil })
    }

    func testFragmentedOversizedFrameIsScannedOnceAndValidFramesAfterItSurvive() async throws {
        let fixture = try AppServerFixture(onTurn: """
        chunk = 'x' * 16384
        for _ in range(1960):
            sys.stdout.write(chunk)
        sys.stdout.write('\\n')
        sys.stdout.flush()
        note('item/completed', {'item': {'id': 'after-large-frame', 'type': 'agentMessage', 'phase': 'commentary', 'text': 'The connection recovered.'}})
        finish({'complete': True})
        """)
        defer { fixture.remove() }
        let capture = AppServerCapture()
        let started = Date()
        let response = try await fixture.job(capture: capture).run(input: Data("initial".utf8))
        XCTAssertFalse(response.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
            "Incremental framing must remain linear for an unterminated 32 MB event")
        XCTAssertEqual(capture.events.filter { $0.title == "Oversized task event" }.count, 1)
        XCTAssertEqual(capture.messages.map(\.text), ["The connection recovered."])
    }

    func testExitedServerFinalFramesAreDrainedBeforeReportingConnectionFailure() async throws {
        let fixture = try AppServerFixture(onTurn: "finish({'quick': True})\nsys.exit(0)")
        defer { fixture.remove() }
        let response = try await fixture.job().run(input: Data("initial".utf8))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: response) as? [String: Bool])?["quick"], true)
    }

    func testStopInterruptsAndKillsUnresponsiveServerWithoutWaitingForDescendantPipes() async throws {
        let fixture = try AppServerFixture(onTurn: """
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen(['/bin/sleep', '15'])
        with open(os.path.join(ROOT, 'child.pid'), 'w') as file: file.write(str(child.pid))
        """, onInterrupt: "pass")
        defer {
            if let text = try? String(contentsOf: fixture.directory.appendingPathComponent("child.pid")), let pid = Int32(text) { kill(pid, SIGKILL) }
            fixture.remove()
        }
        let job = fixture.job()
        let task = Task { try await job.run(input: Data("initial".utf8)) }
        try await waitUntil { job.canSteer && FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("child.pid").path) }
        let start = Date()
        job.cancel()
        do { _ = try await task.value; XCTFail("Stop must cancel the current turn") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(job.canSteer)
        XCTAssertTrue(try fixture.requests().contains { $0["method"] as? String == "turn/interrupt" })
    }

    @MainActor
    func testServiceSteeringStagesPortableSourceReferencesWithoutInliningTheirContents() async throws {
        let response: [String: Any] = ["status": "ready", "message": "Created the design.", "model": [
            "title": ModelSpec.bracket.title, "summary": ModelSpec.bracket.summary, "units": "mm", "script": ModelSpec.bracket.script]]
        let responseText = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        let encodedLiteral = String(decoding: try JSONSerialization.data(withJSONObject: responseText, options: .fragmentsAllowed), as: UTF8.self)
        let fixture = try AppServerFixture(onSteer: """
        text = params['input'][0]['text']
        with open(os.path.join(ROOT, 'steer-input.txt'), 'w') as file: file.write(text)
        marker = 'ATTACHED SOURCE FILE REFERENCES (JSON):\\n'
        references = json.loads(text.split(marker)[1].split('\\n')[0])
        check = []
        for reference in references:
            with open(reference['readPath']) as file: content = file.read()
            check.append({'path': reference['path'], 'readPath': reference['readPath'], 'matches': content.startswith('SOURCE_STEERING_SENTINEL')})
        with open(os.path.join(ROOT, 'staged-check.json'), 'w') as file: json.dump(check, file)
        reply(rpc, {'turnId': 'turn-1'})
        finish(json.loads(\(encodedLiteral)))
        """)
        defer { fixture.remove() }
        let service = CodexService()
        defer { service.cancel() }
        let task = Task {
            try await service.generate(prompt: "Create a bracket", current: nil, history: [],
                executable: fixture.executable.path, model: "captured-model", onProgress: { _ in })
        }
        let deadline = Date().addingTimeInterval(3)
        while !service.canSteer {
            guard Date() < deadline else { throw NSError(domain: "AppServerTest", code: 2) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let source = SourceAttachment(name: "portable.py", path: "/missing/original/portable.py",
            content: "SOURCE_STEERING_SENTINEL" + String(repeating: "x", count: 100_000), sha256: "not-trusted")
        let accepted = try await service.steer(prompt: "Use this reference", attachments: [source])
        XCTAssertEqual(accepted, "turn-1")
        let model = try await task.value
        XCTAssertEqual(model, .ready(.bracket))
        let input = try String(contentsOf: fixture.directory.appendingPathComponent("steer-input.txt"), encoding: .utf8)
        XCTAssertTrue(input.contains("Use this reference"))
        XCTAssertTrue(input.contains(source.path))
        XCTAssertTrue(input.contains("readPath"))
        XCTAssertFalse(input.contains("SOURCE_STEERING_SENTINEL"))
        XCTAssertLessThan(input.utf8.count, 3_000)
        let check = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("staged-check.json"))) as? [[String: Any]])
        XCTAssertEqual(check.first?["matches"] as? Bool, true)
        XCTAssertNotEqual(check.first?["readPath"] as? String, source.path)
    }

    private func imageData(type: String) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { throw NSError(domain: "AppServerTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "App-server did not become ready"]) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class AppServerCapture: @unchecked Sendable {
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

/// Deliberately uses actual app-server frames, independent of the old exec-event
/// compatibility fixture used by higher-level request/context tests.
private struct AppServerFixture {
    let directory: URL
    let executable: URL
    init(onTurn: String = "pass", onSteer: String = "reply(rpc, {'turnId': 'turn-1'})", onInterrupt: String = "reply(rpc, {})",
         rejectMethod: String = "", rejectionCode: Int = -32601) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-AppServer-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        executable = directory.appendingPathComponent("codex")
        let methodEncoder = JSONEncoder()
        methodEncoder.outputFormatting = .withoutEscapingSlashes
        let rejectedMethod = String(decoding: try methodEncoder.encode(rejectMethod), as: UTF8.self)
        func indent(_ code: String) -> String { code.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") }
        let script = """
        #!/usr/bin/python3
        import json, os, signal, subprocess, sys, time
        ROOT = os.path.dirname(os.path.abspath(__file__))
        def send(frame):
            print(json.dumps(frame), flush=True)
        def reply(rpc, result):
            send({'id': rpc['id'], 'result': result})
        def note(method, values):
            send({'method': method, 'params': dict({'threadId': 'thread-1', 'turnId': 'turn-1'}, **values)})
        def finish(result):
            note('item/completed', {'item': {'id': 'final', 'type': 'agentMessage', 'phase': 'final_answer', 'text': json.dumps(result)}})
            note('turn/completed', {'turn': {'id': 'turn-1', 'status': 'completed', 'items': []}})
        def on_turn(params, rpc):
        \(indent(onTurn))
        def on_steer(params, rpc):
        \(indent(onSteer))
        def on_interrupt(params, rpc):
        \(indent(onInterrupt))
        for line in sys.stdin:
            rpc = json.loads(line)
            with open(os.path.join(ROOT, 'requests.jsonl'), 'a') as file:
                file.write(json.dumps(rpc) + '\\n')
            method, params = rpc.get('method'), rpc.get('params', {})
            if method == \(rejectedMethod):
                send({'id': rpc['id'], 'error': {'code': \(rejectionCode), 'message': 'Unsupported ' + method}})
                continue
            if method == 'initialize': reply(rpc, {})
            elif method == 'thread/start': reply(rpc, {'thread': {'id': 'thread-1'}})
            elif method == 'turn/start':
                reply(rpc, {'turn': {'id': 'turn-1', 'status': 'inProgress', 'items': []}})
                on_turn(params, rpc)
            elif method == 'turn/steer': on_steer(params, rpc)
            elif method == 'turn/interrupt': on_interrupt(params, rpc)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func requests() throws -> [[String: Any]] {
        try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
    func job(capture: AppServerCapture = AppServerCapture()) -> CodexAppServerJob {
        CodexAppServerJob(executable: executable, arguments: ["app-server", "--listen", "stdio://"], directory: directory,
            model: "captured-model", effort: "ultra", schema: Data("{\"type\":\"object\"}".utf8),
            onProgress: { _ in }, onMessage: { capture.append($0) }, onActivity: { capture.append($0) },
            onSteeringAvailability: { capture.setAvailability($0) }, environment: [:])
    }
}
