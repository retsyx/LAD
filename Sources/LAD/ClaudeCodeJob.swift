import Darwin
import Foundation

/// One private Claude Code process per LAD generation, using the CLI's
/// stream-json protocol. Input stays open so user messages that the CLI
/// acknowledges join the same task instead of starting another one.
final class ClaudeCodeJob: AgentTaskJob, @unchecked Sendable {
    /// A non-interactive control connection without session persistence or
    /// globally configured MCP servers. No prompt is sent by these arguments.
    static let controlArguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                   "--no-session-persistence", "--strict-mcp-config"]

    /// File edits are accepted only inside the task workspace, Bash runs in the
    /// CLI's OS sandbox with writes limited to that workspace, and anything that
    /// would prompt is declined. Network access matches Codex task workspaces.
    static func arguments(model: String, effort: String?, schema: Data, workspace: URL, python: String,
                          server: URL) throws -> [String] {
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
                   as: UTF8.self)
        }
        let mcp: [String: Any] = ["mcpServers": ["lad": ["type": "stdio", "command": python,
                                                         "args": [server.path, "--workspace", workspace.path]]]]
        let settings: [String: Any] = [
            "sandbox": ["enabled": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false,
                        "network": ["allowedDomains": ["*"]]],
            "permissions": ["allow": ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "mcp__lad"]]
        ]
        var arguments = controlArguments + ["--replay-user-messages", "--mcp-config", try json(mcp),
                                            "--permission-mode", "acceptEdits", "--settings", try json(settings),
                                            "--json-schema", try json(try JSONSerialization.jsonObject(with: schema))]
        if !model.isEmpty, model != "default" { arguments += ["--model", model] }
        if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
        return arguments
    }

    static func environment(executable: URL, overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // A task must not inherit the identity of an enclosing Claude Code session.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { environment.removeValue(forKey: key) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [executable.deletingLastPathComponent().path, environment["PATH"] ?? "/usr/bin:/bin",
                               "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"].joined(separator: ":")
        environment["NO_COLOR"] = "1"
        // LAD never updates the user's installation, and memory written from an
        // ephemeral task workspace would outlive the task.
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        environment["MCP_TIMEOUT"] = "30000"
        environment["MCP_TOOL_TIMEOUT"] = "3600000"
        environment.merge(overrides) { _, new in new }
        return environment
    }

    private enum Terminal { case completed(Data), failed(String) }
    private struct PendingSteer {
        var deadline: Date
        var continuation: CheckedContinuation<String, Error>
    }
    private struct ToolUse {
        var category: String
        var title: String
        var input: String?
        var started: Date
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
    private var sessionID: String?
    private var result: Terminal?
    private var resultDate: Date?
    private var outbound: [Data] = []
    /// Written messages awaiting the CLI's acknowledgement.
    private var pendingSteers: [String: PendingSteer] = [:]
    /// Acknowledged messages the CLI has not finished processing.
    private var unfinishedSteers = Set<String>()
    /// Older CLIs without lifecycle events acknowledge by replaying injected input.
    private var replayedSteers = Set<String>()
    private var lifecycleSupported = false
    private var publishedAvailability = false
    private var nextControlID = 1
    private let onProgress: @Sendable (String) -> Void
    private let onMessage: @Sendable (CodexProgressMessage) -> Void
    private let onActivity: @Sendable (ProjectActivityEvent) -> Void
    private let onSteeringAvailability: @Sendable (Bool) -> Void
    // Stream state below is touched only by the utility I/O thread.
    private var stdoutLine = Data()
    private var discardingOversizedLine = false
    private var stderrTail = Data()
    private var heldCommentary: CodexProgressMessage?
    private var emittedCommentary = 0
    private var toolUses: [String: ToolUse] = [:]
    private var structuredFallback: Data?
    private var resultCount = 0
    private static let maximumEventBytes = 32_000_000
    private static let maximumFinalBytes = 4_000_000

    init(executable: URL, arguments: [String], directory: URL,
         onProgress: @escaping @Sendable (String) -> Void,
         onMessage: @escaping @Sendable (CodexProgressMessage) -> Void,
         onActivity: @escaping @Sendable (ProjectActivityEvent) -> Void,
         onSteeringAvailability: @escaping @Sendable (Bool) -> Void,
         environment overrides: [String: String]) {
        self.onProgress = onProgress
        self.onMessage = onMessage
        self.onActivity = onActivity
        self.onSteeringAvailability = onSteeringAvailability
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = Self.environment(executable: executable, overrides: overrides)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
    }

    var canSteer: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && !finished && result == nil && sessionID != nil
    }

    var currentTurnID: String? {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && !finished && result == nil ? sessionID : nil
    }

    /// Image references are part of the text: Claude views the staged files
    /// with its file reader, so no image bytes enter the request.
    func run(input: Data, imagePaths: [String] = []) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do { continuation.resume(returning: try execute(input: input)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// The CLI's queue acknowledgement is authoritative: an acknowledged message
    /// is processed within this task even if its current turn completes first.
    func steer(text: String, imagePaths: [String] = []) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled, !finished, result == nil, sessionID != nil else {
                lock.unlock()
                continuation.resume(throwing: CodexSteeringError.unavailable)
                return
            }
            do {
                let id = UUID().uuidString.lowercased()
                let data = try Self.frame(Self.userMessage(text: text, id: id))
                pendingSteers[id] = PendingSteer(deadline: Date().addingTimeInterval(30), continuation: continuation)
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
        let id = "lad-interrupt-\(nextControlID)"; nextControlID += 1
        if let data = try? Self.frame(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]]) {
            outbound.append(data)
        }
        lock.unlock()
        publishAvailability(false)
        // First allow the protocol interrupt to stop tools and subagents.
        // Always terminate a CLI that does not promptly honor it.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); let shouldStop = running && !finished && process.isRunning; lock.unlock()
            if shouldStop { process.terminate() }
        }
    }

    static func userMessage(text: String, id: String) -> [String: Any] {
        ["type": "user", "uuid": id, "session_id": "", "parent_tool_use_id": NSNull(),
         "message": ["role": "user", "content": [["type": "text", "text": text]]]]
    }

    private func execute(input: Data) throws -> Data {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); running = true; lock.unlock() }
        catch { lock.unlock(); throw CodexError.failed("Could not start the design task: \(error.localizedDescription)") }
        defer { shutdown() }
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let errorFD = errorPipe.fileHandleForReading.fileDescriptor
        let inputFD = inputPipe.fileHandleForWriting.fileDescriptor
        for descriptor in [outputFD, errorFD, inputFD] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        let initial = try Self.frame(Self.userMessage(text: String(decoding: input, as: UTF8.self), id: UUID().uuidString.lowercased()))
        lock.lock(); outbound.insert(initial, at: 0); lock.unlock()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var writeBuffer: Data?, writeOffset = 0
        var outputClosed = false
        var exitedAt: Date?
        while true {
            expireSteers()
            lock.lock()
            let isCancelled = cancelled
            let cancelDate = cancellationDate
            let ending = result
            let endingDate = resultDate
            let unfinished = !unfinishedSteers.isEmpty
            let awaitingAcknowledgement = !pendingSteers.isEmpty
            let lifecycle = lifecycleSupported
            if writeBuffer == nil, !outbound.isEmpty { writeBuffer = outbound.removeFirst(); writeOffset = 0 }
            lock.unlock()
            if isCancelled, Date().timeIntervalSince(cancelDate ?? Date()) >= 0.35 { throw CancellationError() }
            if let ending, !unfinished {
                let elapsed = Date().timeIntervalSince(endingDate ?? Date())
                if awaitingAcknowledgement {
                    // Input written as the turn ended may still be queued for
                    // this task; never treat a lost acknowledgement as rejection.
                    if elapsed > 5 { rejectPendingSteers("The task finished before acknowledging this information.") }
                } else if lifecycle || elapsed >= 0.5 {
                    return try terminalData(ending)
                }
            }
            if !process.isRunning, exitedAt == nil { exitedAt = Date() }
            if outputClosed || exitedAt.map({ Date().timeIntervalSince($0) > 0.15 }) == true {
                if isCancelled { throw CancellationError() }
                if let ending { return try terminalData(ending) }
                let status = process.isRunning ? "" : " with status \(process.terminationStatus)"
                let detail = String(decoding: stderrTail, as: UTF8.self)
                throw CodexError.failed("The design task exited\(status).\n\n\(detail.isEmpty ? "The Claude Code connection closed before the design was complete." : String(detail.suffix(2_400)))")
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
                    if let ending { return try terminalData(ending) }
                    throw CodexError.failed("The task’s input connection closed unexpectedly.")
                }
            }
            for index in 0..<2 where descriptors[index].revents != 0 {
                var received = 0
                while true {
                    let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                    if count == 0 { if index == 0 { outputClosed = true }; break }
                    if count < 0 { break }
                    let data = Data(buffer.prefix(count))
                    if index == 0 { try consume(data) }
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
        }
    }

    private func shutdown() {
        lock.lock()
        finished = true
        let remaining = pendingSteers.values.map(\.continuation)
        pendingSteers.removeAll(); unfinishedSteers.removeAll(); sessionID = nil
        let wasCancelled = cancelled
        lock.unlock()
        publishAvailability(false)
        for continuation in remaining {
            continuation.resume(throwing: CodexSteeringError.uncertain(wasCancelled
                ? "The task stopped before acknowledging the additional information."
                : "The task’s connection closed before acknowledging the additional information."))
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

    private func publishAvailability(_ value: Bool) {
        lock.lock()
        let changed = publishedAvailability != value
        publishedAvailability = value
        lock.unlock()
        if changed { onSteeringAvailability(value) }
    }

    private func expireSteers() {
        lock.lock()
        let expired = pendingSteers.filter { $0.value.deadline < Date() }
        for id in expired.keys { pendingSteers.removeValue(forKey: id) }
        lock.unlock()
        for steer in expired.values {
            steer.continuation.resume(throwing: CodexSteeringError.uncertain("The additional information was not acknowledged."))
        }
    }

    private func rejectPendingSteers(_ message: String) {
        lock.lock()
        let steers = pendingSteers
        pendingSteers.removeAll()
        lock.unlock()
        for steer in steers.values { steer.continuation.resume(throwing: CodexSteeringError.uncertain(message)) }
    }

    private func acknowledgeSteer(_ id: String, replayed: Bool) {
        lock.lock()
        let pending = pendingSteers.removeValue(forKey: id)
        if pending != nil { unfinishedSteers.insert(id) }
        if replayed, !lifecycleSupported, unfinishedSteers.contains(id) { replayedSteers.insert(id) }
        let session = sessionID ?? id
        lock.unlock()
        pending?.continuation.resume(returning: session)
    }

    private func consume(_ chunk: Data) throws {
        // Search only new bytes so a large malformed line stays linear.
        try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let newline = memchr(base.advanced(by: offset), 10, bytes.count - offset)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                let count = end - offset
                if !discardingOversizedLine {
                    if count > Self.maximumEventBytes - stdoutLine.count {
                        onActivity(ProjectActivityEvent(id: "server:oversized:\(UUID().uuidString)", category: "diagnostic",
                            title: "Oversized task event", status: "failed",
                            output: "A Claude Code event exceeded 32 MB and could not be retained. This execution record is incomplete."))
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
                    try receive(line)
                }
                discardingOversizedLine = false
                offset = end + 1
            }
        }
    }

    private func receive(_ line: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "system": handleSystem(object)
        case "assistant": handleAssistant(object)
        case "user": handleUser(object)
        case "result": handleResult(object)
        case "command_lifecycle": handleLifecycle(object)
        case "control_request": try answerControlRequest(object)
        default: break
        }
    }

    private func handleSystem(_ object: [String: Any]) {
        guard object["subtype"] as? String == "init" else { return }
        let session = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
        let servers = object["mcp_servers"] as? [[String: Any]] ?? []
        let status = servers.first { $0["name"] as? String == "lad" }?["status"] as? String
        lock.lock()
        let first = sessionID == nil
        sessionID = session
        if first, status != "connected", status != "pending", result == nil {
            result = .failed("LAD’s CAD tools could not start for this Claude Code task (\(status ?? "not connected")). Check the installed Claude Code and its MCP configuration, then try again.")
            resultDate = Date()
        }
        let failed = result != nil
        lock.unlock()
        guard first else { return }
        onActivity(ProjectActivityEvent(id: "server:session:\(session)", category: "lifecycle", title: "Session started",
            status: "completed", output: "Session \(session)\((object["model"] as? String).map { " · \($0)" } ?? "")"))
        guard !failed else { return }
        onProgress("Creating your design…")
        publishAvailability(true)
    }

    private func handleAssistant(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        let isRoot = object["parent_tool_use_id"] as? String == nil
        let eventID = object["uuid"] as? String ?? UUID().uuidString
        for (index, block) in content.enumerated() {
            switch block["type"] as? String {
            case "text":
                guard isRoot, let text = block["text"] as? String else { continue }
                flushCommentary()
                // Hold prose until it is known not to restate the final answer
                // immediately before the structured response is delivered.
                heldCommentary = AgentCommentary.visibleText(text).map { CodexProgressMessage(id: "\(eventID):\(index)", text: $0) }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                if name == "StructuredOutput" {
                    guard isRoot else { continue }
                    heldCommentary = nil
                    if let values = block["input"] as? [String: Any] {
                        structuredFallback = try? JSONSerialization.data(withJSONObject: values)
                    }
                    continue
                }
                if isRoot { flushCommentary() }
                // The LAD bridge records native tool calls with exact results.
                guard !name.hasPrefix("mcp__lad__") else { continue }
                let description = Self.describeTool(name: name, input: block["input"] ?? [:])
                let tool = ToolUse(category: description.category, title: description.title, input: description.input, started: Date())
                toolUses["claude:\(id)"] = tool
                onActivity(ProjectActivityEvent(id: "claude:\(id)", date: tool.started, category: tool.category,
                                                title: tool.title, status: "running", input: tool.input))
            default:
                continue // Thinking is private reasoning and never becomes activity.
            }
        }
    }

    private func flushCommentary() {
        guard let message = heldCommentary else { return }
        heldCommentary = nil
        guard emittedCommentary < 256 else { return }
        emittedCommentary += 1
        onMessage(message)
    }

    private func handleUser(_ object: [String: Any]) {
        if object["isReplay"] as? Bool == true {
            if let id = object["uuid"] as? String { acknowledgeSteer(id, replayed: true) }
            return
        }
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        for block in content where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String, let tool = toolUses.removeValue(forKey: "claude:\(id)") else { continue }
            onActivity(ProjectActivityEvent(id: "claude:\(id)", date: tool.started, category: tool.category, title: tool.title,
                status: block["is_error"] as? Bool == true ? "failed" : "completed", input: tool.input,
                output: Self.resultText(block["content"]), durationSeconds: Date().timeIntervalSince(tool.started)))
        }
    }

    private func handleLifecycle(_ object: [String: Any]) {
        guard let id = object["command_uuid"] as? String ?? object["uuid"] as? String,
              let state = object["state"] as? String else { return }
        lock.lock(); lifecycleSupported = true; lock.unlock()
        if state == "queued" || state == "started" {
            acknowledgeSteer(id, replayed: false)
        } else {
            lock.lock(); unfinishedSteers.remove(id); lock.unlock()
        }
    }

    private func handleResult(_ object: [String: Any]) {
        heldCommentary = nil
        resultCount += 1
        let subtype = object["subtype"] as? String ?? "error"
        let isError = object["is_error"] as? Bool ?? (subtype != "success")
        let ending: Terminal
        if subtype == "success", !isError {
            if let data = finalResponse(object), data.count <= Self.maximumFinalBytes { ending = .completed(data) }
            else { ending = .failed("The task completed without a bounded structured CAD response.") }
        } else {
            ending = .failed(Self.failureMessage(object, subtype: subtype))
        }
        structuredFallback = nil
        lock.lock()
        result = ending
        resultDate = Date()
        if !lifecycleSupported { unfinishedSteers.subtract(replayedSteers); replayedSteers.removeAll() }
        let wasCancelled = cancelled
        lock.unlock()
        publishAvailability(false)
        onProgress("Checking the CAD design…")
        let status: String
        if case .completed = ending { status = "completed" } else { status = wasCancelled ? "canceled" : "failed" }
        onActivity(ProjectActivityEvent(id: "server:result:\(resultCount)", category: "lifecycle", title: "Task finished",
            status: status, output: "Result \(subtype) · \(object["num_turns"] as? Int ?? 0) turns"))
    }

    private func finalResponse(_ object: [String: Any]) -> Data? {
        if let structured = object["structured_output"] as? [String: Any] {
            return try? JSONSerialization.data(withJSONObject: structured)
        }
        if let structuredFallback { return structuredFallback }
        return (object["result"] as? String).flatMap(Self.jsonObjectData)
    }

    static func jsonObjectData(in text: String) -> Data? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```"), let firstLine = body.firstIndex(of: "\n"), body.hasSuffix("```") {
            body = String(body[body.index(after: firstLine)..<body.index(body.endIndex, offsetBy: -3)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.hasPrefix("{"), let data = body.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }

    static func failureMessage(_ object: [String: Any], subtype: String) -> String {
        if let errors = object["errors"] as? [String], !errors.isEmpty { return String(errors.joined(separator: "\n").prefix(4_000)) }
        if let text = object["result"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(text.prefix(4_000))
        }
        switch subtype {
        case "error_max_turns": return "The task reached its turn limit before the design was complete."
        case "error_max_structured_output_retries": return "The task could not produce a valid structured CAD response."
        default: return "The task could not complete the design."
        }
    }

    static func describeTool(name: String, input: Any) -> (category: String, title: String, input: String?) {
        let values = input as? [String: Any] ?? [:]
        switch name {
        case "Bash":
            let command = values["command"] as? String ?? "Command"
            return ("command", String(command.prefix(180)), command)
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            let path = values["file_path"] as? String ?? values["notebook_path"] as? String ?? ""
            let title = path.isEmpty ? "Workspace file changes" : "\(name) · \((path as NSString).lastPathComponent)"
            return ("file_change", title, CodexActivity.json(CodexActivity.sanitize(values)))
        case "WebSearch":
            return ("web_search", "Web search", values["query"] as? String ?? CodexActivity.json(CodexActivity.sanitize(values)))
        case "TodoWrite":
            return ("plan", "Task plan", CodexActivity.json(CodexActivity.sanitize(values)))
        default:
            let parts = name.components(separatedBy: "__")
            let title = name.hasPrefix("mcp__") && parts.count >= 3 ? "\(parts[1]) · \(parts[2...].joined(separator: "__"))" : name
            return ("tool", title, values.isEmpty ? nil : CodexActivity.json(CodexActivity.sanitize(values)))
        }
    }

    /// Tool results keep their complete text; derived media never enters the record.
    static func resultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else {
            return content.map { CodexActivity.json(CodexActivity.sanitize($0)) }
        }
        return blocks.map { block -> String in
            switch block["type"] as? String {
            case "text": return block["text"] as? String ?? ""
            case "image", "document": return "Derived media attachment (not stored)"
            default: return CodexActivity.json(CodexActivity.sanitize(block))
            }
        }.joined(separator: "\n")
    }

    private func answerControlRequest(_ object: [String: Any]) throws {
        guard let id = object["request_id"] as? String else { return }
        let request = object["request"] as? [String: Any] ?? [:]
        let subtype = request["subtype"] as? String ?? ""
        let response: [String: Any]
        if subtype == "can_use_tool" {
            response = ["subtype": "success", "request_id": id, "response": [
                "behavior": "deny",
                "message": "LAD does not allow this operation in design tasks. Work inside the task workspace with the available tools."]]
            onActivity(ProjectActivityEvent(id: "server:request:\(id)", category: "diagnostic", title: "Interactive request declined",
                status: "failed", input: request["tool_name"] as? String ?? subtype,
                output: "The task’s permission settings do not allow this request. \(CodexActivity.json(CodexActivity.sanitize(request)))"))
        } else {
            response = ["subtype": "error", "request_id": id, "error": "LAD does not support this interactive request."]
        }
        let data = try Self.frame(["type": "control_response", "response": response])
        lock.lock(); outbound.append(data); lock.unlock()
    }
}
