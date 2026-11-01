import Darwin
import Foundation

/// A lost acknowledgement is not proof that the additional information was
/// rejected. The queue must pause instead of silently replaying uncertain input.
enum CodexSteeringError: LocalizedError {
    case unavailable
    case rejected(String)
    case uncertain(String)

    var mayHaveBeenAccepted: Bool {
        if case .uncertain = self { return true }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex is no longer accepting information for this turn. The follow-up remains queued."
        case .rejected(let detail): return "Codex did not accept the additional information: \(detail) The follow-up remains queued."
        case .uncertain(let detail): return "\(detail) Codex may have received the information. Review the conversation before resuming the queue."
        }
    }
}

/// One private app-server process and one ephemeral thread per LAD generation.
/// The input pipe stays open so additional information can steer its active turn.
final class CodexAppServerJob: @unchecked Sendable {
    private enum Purpose: Equatable { case initialize, threadStart, turnStart, steer, interrupt }
    private struct PendingRPC {
        var purpose: Purpose
        var deadline: Date?
        var expectedTurnID: String?
        var continuation: CheckedContinuation<String, Error>?
    }
    private enum Terminal {
        case completed(Data), failed(String), interrupted
    }
    private struct Message {
        var text: String
        var phase: String?
    }

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationDate: Date?
    private var running = false
    private var finished = false
    private var threadID: String?
    private var turnID: String?
    private var terminal: Terminal?
    private var completedAt: Date?
    private var nextRequestID = 1
    private var pending: [Int: PendingRPC] = [:]
    private var outbound: [Data] = []
    private var publishedAvailability = false
    private let directory: URL
    private let model: String
    private let effort: String?
    private let schema: Data
    private let onProgress: @Sendable (String) -> Void
    private let onMessage: @Sendable (CodexProgressMessage) -> Void
    private let onActivity: @Sendable (ProjectActivityEvent) -> Void
    private let onSteeringAvailability: @Sendable (Bool) -> Void
    // Stream state below is touched only by the utility I/O thread.
    private var stdoutLine = Data()
    private var discardingOversizedLine = false
    private var stderrTail = Data()
    private var messages: [String: Message] = [:]
    private var emittedCommentary: [String: String] = [:]
    private var activityStarts: [String: Date] = [:]
    private var commandOutputs: [String: String] = [:]
    private var commandItems: [String: [String: Any]] = [:]
    private var commandOutputBytes = 0
    private var incompleteCommands = Set<String>()
    private var lastCommandUpdate: [String: Date] = [:]
    private var finalResponse: String?
    private static let maximumEventBytes = 32_000_000
    private static let maximumFinalBytes = 4_000_000

    init(executable: URL, arguments: [String], directory: URL, model: String, effort: String?, schema: Data,
         onProgress: @escaping @Sendable (String) -> Void,
         onMessage: @escaping @Sendable (CodexProgressMessage) -> Void,
         onActivity: @escaping @Sendable (ProjectActivityEvent) -> Void,
         onSteeringAvailability: @escaping @Sendable (Bool) -> Void,
         environment overrides: [String: String]) {
        self.directory = directory
        self.model = model
        self.effort = effort
        self.schema = schema
        self.onProgress = onProgress
        self.onMessage = onMessage
        self.onActivity = onActivity
        self.onSteeringAvailability = onSteeringAvailability
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [executable.deletingLastPathComponent().path, environment["PATH"] ?? "/usr/bin:/bin",
                               "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"].joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment.merge(overrides) { _, new in new }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
    }

    var canSteer: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && !finished && terminal == nil && threadID != nil && turnID != nil
    }
    var currentTurnID: String? {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && !finished && terminal == nil ? turnID : nil
    }

    /// The app-server resolves each image file directly. Media bytes never
    /// become text or JSON base64 in LAD's bounded design request.
    private static func userInput(text: String, imagePaths: [String]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        if !text.isEmpty { input.append(["type": "text", "text": text, "text_elements": []]) }
        input.append(contentsOf: imagePaths.map { ["type": "localImage", "path": $0] })
        return input
    }

    func run(input: Data, imagePaths: [String] = []) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    let data = try execute(input: input, imagePaths: imagePaths)
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// The acknowledgement is authoritative even if turn/completed arrives
    /// while the response is in flight. No new thread or turn is created.
    func steer(text: String, imagePaths: [String] = []) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled, !finished, terminal == nil, let threadID, let turnID else {
                lock.unlock()
                continuation.resume(throwing: CodexSteeringError.unavailable)
                return
            }
            do {
                let id = nextRequestID; nextRequestID += 1
                let params: [String: Any] = ["threadId": threadID, "expectedTurnId": turnID,
                    "clientUserMessageId": UUID().uuidString,
                    "input": Self.userInput(text: text, imagePaths: imagePaths)]
                let data = try Self.frame(["id": id, "method": "turn/steer", "params": params])
                pending[id] = PendingRPC(purpose: .steer, deadline: Date().addingTimeInterval(30),
                                          expectedTurnID: turnID, continuation: continuation)
                outbound.append(data)
                lock.unlock()
            } catch {
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        guard !finished, !cancelled else { lock.unlock(); return }
        cancelled = true
        cancellationDate = Date()
        let currentThread = threadID, currentTurn = turnID
        lock.unlock()
        publishAvailability(false)
        if let currentThread, let currentTurn {
            try? enqueue("turn/interrupt", purpose: .interrupt,
                         params: ["threadId": currentThread, "turnId": currentTurn])
        }
        // First allow the protocol interrupt to stop commands/agents. Always
        // terminate a server that does not promptly honor it.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); let shouldStop = running && !finished && process.isRunning; lock.unlock()
            if shouldStop { process.terminate() }
        }
    }

    private func execute(input: Data, imagePaths: [String]) throws -> Data {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); running = true; lock.unlock() }
        catch { lock.unlock(); throw CodexError.failed("Could not start Codex: \(error.localizedDescription)") }
        defer { shutdown() }
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let errorFD = errorPipe.fileHandleForReading.fileDescriptor
        let inputFD = inputPipe.fileHandleForWriting.fileDescriptor
        for descriptor in [outputFD, errorFD, inputFD] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        try enqueue("initialize", purpose: .initialize, params: [
            "clientInfo": CodexAppServerClient.info(),
            "capabilities": ["experimentalApi": false]
        ])
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var writeBuffer: Data?, writeOffset = 0
        let prompt = String(decoding: input, as: UTF8.self)
        var outputClosed = false
        var exitedAt: Date?
        while true {
            try expireRequests()
            lock.lock()
            let isCancelled = cancelled
            let cancelDate = cancellationDate
            let ending = terminal
            let endingDate = completedAt
            let awaitingSteer = pending.values.contains { $0.purpose == .steer }
            if writeBuffer == nil, !outbound.isEmpty { writeBuffer = outbound.removeFirst(); writeOffset = 0 }
            lock.unlock()
            if isCancelled, Date().timeIntervalSince(cancelDate ?? Date()) >= 0.35 { throw CancellationError() }
            if let ending, !awaitingSteer { return try terminalData(ending) }
            if ending != nil, awaitingSteer, Date().timeIntervalSince(endingDate ?? Date()) > 5 {
                rejectPendingSteers("Codex finished before acknowledging this information.")
                continue
            }
            if !process.isRunning, exitedAt == nil { exitedAt = Date() }
            if outputClosed || exitedAt.map({ Date().timeIntervalSince($0) > 0.15 }) == true {
                if isCancelled { throw CancellationError() }
                if let ending { return try terminalData(ending) }
                let status = process.isRunning ? "" : " with status \(process.terminationStatus)"
                let detail = String(decoding: stderrTail, as: UTF8.self)
                throw CodexError.failed("Codex exited\(status).\n\n\(detail.isEmpty ? "The app-server connection closed before the design was complete." : String(detail.suffix(2_400)))")
            }
            var descriptors = [
                pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                pollfd(fd: writeBuffer == nil ? -1 : inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
            ]
            _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), 40)
            if descriptors[2].revents != 0, let writing = writeBuffer {
                let written = writing.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: writeOffset), bytes.count - writeOffset)
                }
                if written > 0 {
                    writeOffset += written
                    if writeOffset == writing.count { writeBuffer = nil }
                } else if written < 0, errno != EAGAIN, errno != EINTR {
                    if isCancelled { throw CancellationError() }
                    throw CodexError.failed("The Codex app-server input connection closed unexpectedly.")
                }
            }
            for index in 0..<2 where descriptors[index].revents != 0 {
                var received = 0
                while true {
                    let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                    if count == 0 { if index == 0 { outputClosed = true }; break }
                    if count < 0 { break }
                    let data = Data(buffer.prefix(count))
                    if index == 0 { try consume(data, prompt: prompt, imagePaths: imagePaths) }
                    else {
                        stderrTail.append(data)
                        if stderrTail.count > 16_384 { stderrTail.removeFirst(stderrTail.count - 16_384) }
                    }
                    received += count
                    if received >= 1_048_576 { break }
                }
            }
        }
    }

    private func terminalData(_ terminal: Terminal) throws -> Data {
        lock.lock(); let isCancelled = cancelled; lock.unlock()
        if isCancelled { throw CancellationError() }
        switch terminal {
        case .completed(let data): return data
        case .failed(let message): throw CodexError.failed(message)
        case .interrupted: throw CodexError.failed("Codex’s turn was interrupted before the design was complete.")
        }
    }

    private func shutdown() {
        lock.lock()
        finished = true
        let remaining = pending.values.compactMap(\.continuation)
        pending.removeAll(); turnID = nil; threadID = nil
        let wasCancelled = cancelled
        lock.unlock()
        publishAvailability(false)
        for continuation in remaining {
            continuation.resume(throwing: CodexSteeringError.uncertain(wasCancelled ? "The task stopped before Codex acknowledged the additional information." : "The Codex connection closed before it acknowledged the additional information."))
        }
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        lock.lock(); running = false; lock.unlock()
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
    }

    private static func frame(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }
    private func enqueue(_ method: String, purpose: Purpose, params: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let id = nextRequestID; nextRequestID += 1
        outbound.append(try Self.frame(["id": id, "method": method, "params": params]))
        pending[id] = PendingRPC(purpose: purpose, deadline: purpose == .interrupt ? nil : Date().addingTimeInterval(60))
    }
    private func notification(_ method: String) throws {
        let data = try Self.frame(["method": method])
        lock.lock(); outbound.append(data); lock.unlock()
    }
    private func publishAvailability(_ value: Bool) {
        lock.lock()
        let changed = publishedAvailability != value
        publishedAvailability = value
        lock.unlock()
        if changed { onSteeringAvailability(value) }
    }
    private func expireRequests() throws {
        lock.lock()
        let expired = pending.filter { $0.value.deadline.map { $0 < Date() } ?? false }
        for (id, _) in expired { pending.removeValue(forKey: id) }
        lock.unlock()
        for (_, request) in expired {
            if request.purpose == .steer {
                request.continuation?.resume(throwing: CodexSteeringError.uncertain("Codex did not acknowledge the additional information."))
            } else if request.purpose != .interrupt {
                throw CodexError.failed("The Codex app-server connection timed out while starting the task. Check the installed CLI and its sign-in.")
            }
        }
    }
    private func rejectPendingSteers(_ message: String) {
        lock.lock()
        let steers = pending.filter { $0.value.purpose == .steer }
        for (id, _) in steers { pending.removeValue(forKey: id) }
        lock.unlock()
        for (_, request) in steers { request.continuation?.resume(throwing: CodexSteeringError.uncertain(message)) }
    }

    private func consume(_ chunk: Data, prompt: String, imagePaths: [String]) throws {
        // Search only new bytes. Rescanning an accumulated unterminated frame
        // for every pipe read makes a large malformed line quadratic and can
        // prevent cancellation from reaching the I/O loop promptly.
        try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let newline = memchr(base.advanced(by: offset), 10, bytes.count - offset)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                let count = end - offset
                if !discardingOversizedLine {
                    if count > Self.maximumEventBytes - stdoutLine.count {
                        oversizedEvent()
                        stdoutLine.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    } else if count > 0 {
                        stdoutLine.append(base.assumingMemoryBound(to: UInt8.self).advanced(by: offset), count: count)
                    }
                }
                guard newline != nil else { break }
                if !discardingOversizedLine {
                    let line = stdoutLine
                    stdoutLine = Data()
                    try receive(line, prompt: prompt, imagePaths: imagePaths)
                }
                discardingOversizedLine = false
                offset = end + 1
            }
        }
    }
    private func oversizedEvent() {
        onActivity(ProjectActivityEvent(id: "server:oversized:\(UUID().uuidString)", category: "diagnostic",
            title: "Oversized Codex event", status: "failed", output: "An app-server event exceeded 32 MB and could not be retained. This execution record is incomplete."))
    }

    private func receive(_ line: Data, prompt: String, imagePaths: [String]) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = object["id"] { try answerServerRequest(id: id, method: method, params: params) }
            else { handleNotification(method, params: params) }
            return
        }
        guard let id = object["id"] as? Int else { return }
        lock.lock(); let request = pending.removeValue(forKey: id); lock.unlock()
        guard let request else { return }
        if let error = object["error"] as? [String: Any] {
            let message = CodexAppServerClient.errorMessage(error)
            if request.purpose == .steer {
                request.continuation?.resume(throwing: CodexSteeringError.rejected(message))
                return
            }
            if request.purpose == .interrupt { return }
            throw CodexError.failed(message)
        }
        let result = object["result"] as? [String: Any] ?? [:]
        switch request.purpose {
        case .initialize:
            try notification("initialized")
            var params: [String: Any] = ["cwd": directory.path, "sandbox": "workspace-write", "approvalPolicy": "never", "ephemeral": true,
                                       "experimentalRawEvents": false]
            if !model.isEmpty { params["model"] = model }
            try enqueue("thread/start", purpose: .threadStart, params: params)
        case .threadStart:
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty else {
                throw CodexError.failed("Codex returned an unreadable thread identifier.")
            }
            lock.lock(); threadID = id; lock.unlock()
            onActivity(ProjectActivityEvent(id: "server:thread:\(id)", category: "lifecycle", title: "Codex session started", status: "completed", output: "Ephemeral thread \(id)"))
            guard let schema = try JSONSerialization.jsonObject(with: schema) as? [String: Any] else { throw CodexError.resourcesMissing }
            var params: [String: Any] = ["threadId": id, "input": Self.userInput(text: prompt, imagePaths: imagePaths),
                "cwd": directory.path, "approvalPolicy": "never", "outputSchema": schema,
                "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": [directory.path], "networkAccess": true,
                                  "excludeTmpdirEnvVar": true, "excludeSlashTmp": true]]
            if !model.isEmpty { params["model"] = model }
            if let effort, !effort.isEmpty { params["effort"] = effort }
            onProgress("Creating your design…")
            try enqueue("turn/start", purpose: .turnStart, params: params)
        case .turnStart:
            guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else {
                throw CodexError.failed("Codex returned an unreadable turn identifier.")
            }
            activateTurn(id)
            if turn["status"] as? String != "inProgress" { completeTurn(turn) }
        case .steer:
            guard let accepted = result["turnId"] as? String, accepted == request.expectedTurnID else {
                request.continuation?.resume(throwing: CodexSteeringError.uncertain("Codex did not acknowledge the expected active turn."))
                return
            }
            request.continuation?.resume(returning: accepted)
        case .interrupt: break
        }
    }

    private func activateTurn(_ id: String) {
        lock.lock()
        let active = !cancelled && !finished && terminal == nil
        if active { turnID = id }
        lock.unlock()
        if active { publishAvailability(true) }
    }
    private func handleNotification(_ method: String, params: [String: Any]) {
        lock.lock(); let rootThread = threadID; lock.unlock()
        let isRoot = params["threadId"] as? String == rootThread
        switch method {
        case "turn/started":
            if isRoot, let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String { activateTurn(id) }
        case "turn/completed":
            if isRoot, let turn = params["turn"] as? [String: Any] { completeTurn(turn) }
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            handleItem(item, completed: method == "item/completed", root: isRoot, thread: params["threadId"] as? String ?? "")
        case "item/agentMessage/delta":
            guard isRoot, let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            var message = messages[id] ?? Message(text: "", phase: nil)
            if message.text.utf8.count + delta.utf8.count <= Self.maximumFinalBytes { message.text += delta }
            else {
                onActivity(ProjectActivityEvent(id: "server:message-limit:\(id)", category: "diagnostic", title: "Codex message exceeded its size limit", status: "failed"))
            }
            messages[id] = message
            // Unknown-phase deltas might be final JSON or tool/code text. Wait
            // for their completed item before classifying them as commentary.
            if message.phase == "commentary" { emitCommentary(id, message: message) }
        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            let key = (params["threadId"] as? String ?? "") + ":" + id
            if commandOutputBytes + delta.utf8.count <= Self.maximumEventBytes {
                commandOutputs[key, default: ""] += delta; commandOutputBytes += delta.utf8.count
            } else if incompleteCommands.insert(key).inserted {
                onActivity(ProjectActivityEvent(id: "server:command-limit:\(key)", category: "diagnostic", title: "Command output exceeded its size limit", status: "failed", output: "The public command output exceeded LAD’s 32 MB buffer; this execution record is incomplete."))
            }
            if let item = commandItems[key], Date().timeIntervalSince(lastCommandUpdate[key] ?? .distantPast) >= 0.25 {
                lastCommandUpdate[key] = Date()
                var updated = item; updated["aggregatedOutput"] = commandOutputs[key] ?? ""
                emitActivity(updated, completed: false, thread: params["threadId"] as? String ?? "")
            }
        case "turn/plan/updated":
            onActivity(ProjectActivityEvent(id: "server:plan:\(params["turnId"] as? String ?? "plan")", category: "plan", title: "Task plan", status: "running", output: CodexActivity.json(CodexActivity.sanitize(params))))
        case "error":
            onActivity(ProjectActivityEvent(id: "server:error:\(UUID().uuidString)", category: "diagnostic", title: "Codex error", status: "failed", output: CodexActivity.json(CodexActivity.sanitize(params))))
        default: break
        }
    }
    private func handleItem(_ item: [String: Any], completed: Bool, root: Bool, thread: String) {
        guard let id = item["id"] as? String, let kind = item["type"] as? String else { return }
        if kind == "agentMessage", root {
            var message = messages[id] ?? Message(text: "", phase: nil)
            if let phase = item["phase"] as? String { message.phase = phase }
            if let text = item["text"] as? String, !text.isEmpty { message.text = text }
            messages[id] = message
            if completed, message.phase == "final_answer" || (message.phase == nil && message.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")) {
                finalResponse = message.text
            }
            emitCommentary(id, message: message)
            return
        }
        if kind == "commandExecution" {
            let key = thread + ":" + id
            if completed {
                var canonical = item
                if canonical["aggregatedOutput"] == nil || canonical["aggregatedOutput"] is NSNull {
                    canonical["aggregatedOutput"] = commandOutputs[key] ?? ""
                }
                emitActivity(canonical, completed: true, thread: thread)
                commandOutputBytes -= commandOutputs.removeValue(forKey: key)?.utf8.count ?? 0
                commandItems.removeValue(forKey: key); lastCommandUpdate.removeValue(forKey: key)
            } else { commandItems[key] = item; emitActivity(item, completed: false, thread: thread) }
            return
        }
        emitActivity(item, completed: completed, thread: thread)
    }
    private func emitActivity(_ source: [String: Any], completed: Bool, thread: String) {
        var item = source
        guard let originalKind = source["type"] as? String, let id = source["id"] as? String else { return }
        item["id"] = thread + ":" + id
        switch originalKind {
        case "commandExecution":
            item["type"] = "command_execution"
            item["aggregated_output"] = source["aggregatedOutput"]
            item["exit_code"] = source["exitCode"]
            item["duration_ms"] = source["durationMs"]
        case "fileChange": item["type"] = "file_change"
        case "mcpToolCall": item["type"] = "mcp_tool_call"; item["duration_ms"] = source["durationMs"]
        case "webSearch": item["type"] = "web_search"
        case "plan": item["type"] = "plan"
        case "collabAgentToolCall", "dynamicToolCall", "imageView", "sleep", "subAgentActivity":
            onActivity(ProjectActivityEvent(id: "server:\(thread):\(id)", category: "tool", title: source["tool"] as? String ?? originalKind,
                status: completed ? "completed" : "running", output: CodexActivity.json(CodexActivity.sanitize(source))))
            return
        default: return
        }
        if let event = CodexActivity.event(["type": completed ? "item.completed" : "item.started", "item": item], starts: &activityStarts) { onActivity(event) }
    }
    private func emitCommentary(_ id: String, message: Message) {
        guard message.phase == nil || message.phase == "commentary" else { return }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("{"), !text.hasPrefix("["), !text.contains("```"), !text.contains("~~~"),
              text.range(of: #"(?m)^\s*(?:import\s+|from\s+\w.*\s+import\s+|result\s*=|def\s+|class\s+|FeatureScript\s+|ISO-10303-21;|\(kicad_pcb\b|(?:const|let|var)\s+\w+\s*=)"#, options: .regularExpression) == nil else { return }
        let visible = String(text.prefix(4_000))
        guard emittedCommentary[id] != visible, emittedCommentary.count < 256 || emittedCommentary[id] != nil else { return }
        emittedCommentary[id] = visible
        onMessage(CodexProgressMessage(id: id, text: visible))
    }
    private func completeTurn(_ turn: [String: Any]) {
        for item in turn["items"] as? [[String: Any]] ?? [] where item["type"] as? String == "agentMessage" {
            handleItem(item, completed: true, root: true, thread: "")
        }
        let status = turn["status"] as? String ?? "failed"
        let ending: Terminal
        if status == "completed" {
            if let response = finalResponse, !response.isEmpty, response.utf8.count <= Self.maximumFinalBytes {
                ending = .completed(Data(response.utf8))
            } else { ending = .failed("Codex completed without a bounded structured CAD response.") }
        } else if status == "interrupted" { ending = .interrupted }
        else {
            let error = turn["error"] as? [String: Any]
            ending = .failed(error?["message"] as? String ?? "Codex could not complete the design.")
        }
        lock.lock()
        if terminal == nil { terminal = ending; completedAt = Date(); turnID = nil }
        lock.unlock()
        publishAvailability(false)
        onProgress("Checking the CAD design…")
        onActivity(ProjectActivityEvent(id: "server:turn:\(turn["id"] as? String ?? "turn")", category: "lifecycle", title: "Codex turn finished",
            status: status == "completed" ? "completed" : status == "interrupted" ? "canceled" : "failed", output: "Turn \(turn["id"] as? String ?? "") · \(status)"))
    }

    private func answerServerRequest(id: Any, method: String, params: [String: Any]) throws {
        let result: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval": result = ["decision": "decline"]
        case "execCommandApproval", "applyPatchApproval": result = ["decision": "denied"]
        case "item/permissions/requestApproval": result = ["permissions": [:], "scope": "turn"]
        case "item/tool/requestUserInput": result = ["answers": [:]]
        case "mcpServer/elicitation/request": result = ["action": "decline"]
        case "item/tool/call": result = ["success": false, "contentItems": [["type": "inputText", "text": "This dynamic tool is not available in LAD. Use the configured LAD MCP tools."]]]
        default:
            let data = try Self.frame(["id": id, "error": ["code": -32601, "message": "LAD does not support this interactive request."]])
            lock.lock(); outbound.append(data); lock.unlock()
            return
        }
        onActivity(ProjectActivityEvent(id: "server:request:\(String(describing: id))", category: "diagnostic", title: "Interactive Codex request declined", status: "failed",
            input: method, output: "The task’s configured approval policy does not allow this interactive request. \(CodexActivity.json(CodexActivity.sanitize(params)))"))
        let data = try Self.frame(["id": id, "result": result])
        lock.lock(); outbound.append(data); lock.unlock()
    }
}
