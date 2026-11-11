import Darwin
import Foundation

extension CodexModelCatalog {
    /// Decode Claude Code's `initialize` and `get_settings` control responses.
    /// The CLI's `default` row only identifies which listed model is its default;
    /// the configured model and effort come from the CLI's applied settings.
    nonisolated static func decodeClaudeCatalog(initialize: Data, settings: Data?) throws -> AgentCatalogSnapshot {
        guard initialize.count <= 4_194_304,
              let object = (try? JSONSerialization.jsonObject(with: initialize)) as? [String: Any],
              let entries = object["models"] as? [[String: Any]], entries.count <= 1_000 else {
            throw AgentCatalogError.invalidResponse
        }
        let configuration = settings.flatMap { $0.count <= 4_194_304 ? (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] : nil }
        let applied = configuration?["applied"] as? [String: Any]
        let effective = configuration?["effective"] as? [String: Any]
        let appliedModel = applied?["model"] as? String
        let appliedEffort = (applied?["effort"] as? String).flatMap(CodexReasoningEffort.init(rawValue:))
            .flatMap { $0 == .defaultConfiguration ? nil : $0.rawValue }
        struct Row { var descriptor: CodexModelDescriptor; var resolved: String? }
        var rows: [Row] = []
        var seen = Set<String>()
        var defaultResolved: String?
        for entry in entries {
            guard let id = entry["value"] as? String, validIdentifier(id) else { throw AgentCatalogError.invalidResponse }
            let resolved = (entry["resolvedModel"] as? String).flatMap { validIdentifier($0) ? $0 : nil }
            if id == "default" { defaultResolved = resolved; continue }
            let name = entry["displayName"] as? String ?? id
            let description = entry["description"] as? String ?? ""
            guard seen.insert(id).inserted, validText(name, maximum: 256),
                  validText(description, maximum: 8_192, allowEmpty: true) else { throw AgentCatalogError.invalidResponse }
            let levels = entry["supportsEffort"] as? Bool == false ? [] : entry["supportedEffortLevels"] as? [String] ?? []
            guard levels.count <= 64 else { throw AgentCatalogError.invalidResponse }
            var efforts = Set<String>()
            let options = try levels.map { level -> CodexReasoningOption in
                guard let effort = CodexReasoningEffort(rawValue: level), effort != .defaultConfiguration,
                      efforts.insert(level).inserted else { throw AgentCatalogError.invalidResponse }
                return CodexReasoningOption(id: level)
            }
            // The CLI reports the applied effort only for its configured model.
            let configured = resolved != nil && resolved == appliedModel ? appliedEffort.flatMap { efforts.contains($0) ? $0 : nil } : nil
            let fallback = configured ?? (efforts.contains("high") ? "high" : options.first?.id)
            rows.append(Row(descriptor: CodexModelDescriptor(id: id, displayName: name, description: description,
                                                             reasoningEfforts: options, defaultReasoningEffort: fallback),
                            resolved: resolved))
        }
        guard !rows.isEmpty else { throw AgentCatalogError.invalidResponse }
        let defaultID = defaultResolved.flatMap { resolved in rows.first { $0.resolved == resolved }?.descriptor.id } ?? rows[0].descriptor.id
        let models = rows.map { row in
            CodexModelDescriptor(id: row.descriptor.id, displayName: row.descriptor.displayName, description: row.descriptor.description,
                                 reasoningEfforts: row.descriptor.reasoningEfforts,
                                 defaultReasoningEffort: row.descriptor.defaultReasoningEffort,
                                 isDefault: row.descriptor.id == defaultID)
        }
        var configuredModel: String?
        if let value = effective?["model"] as? String, validIdentifier(value), value != "default" {
            // A full model name can be listed under its alias. Custom names
            // remain the CLI's configured choice even when not listed.
            configuredModel = models.contains { $0.id == value } ? value : rows.first { $0.resolved == value }?.descriptor.id ?? value
        }
        return AgentCatalogSnapshot(models: models, configuredModelID: configuredModel, configuredReasoningEffort: appliedEffort)
    }
}

/// A bounded, short-lived Claude Code connection. Its only requests are the
/// `initialize` and `get_settings` control requests; no prompt is sent.
final class ClaudeCatalogJob: AgentCatalogLookup, @unchecked Sendable {
    private let executable: String
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    init(executable: String) { self.executable = executable }

    func run() async throws -> AgentCatalogSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do { continuation.resume(returning: try lookup()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pid = running && process.isRunning ? process.processIdentifier : 0
        if pid > 0 { process.terminate() }
        lock.unlock()
        if pid > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
                lock.lock(); defer { lock.unlock() }
                if running && process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
    }

    private func lookup() throws -> AgentCatalogSnapshot {
        guard let binary = ClaudeExecutable.resolve(executable) else { throw AgentCatalogError.executableMissing(.claude) }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = binary
        process.arguments = ClaudeCodeJob.controlArguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = ClaudeCodeJob.environment(executable: binary, overrides: [:])
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); running = true; lock.unlock() }
        catch { lock.unlock(); throw AgentCatalogError.failed("Check your installed Claude Code and its sign-in.") }
        defer {
            try? input.fileHandleForWriting.close()
            lock.lock()
            if process.isRunning { process.terminate() }
            lock.unlock()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            lock.lock(); running = false; lock.unlock()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        let outFD = output.fileHandleForReading.fileDescriptor, errorFD = errors.fileHandleForReading.fileDescriptor
        let inputFD = input.fileHandleForWriting.fileDescriptor
        for descriptor in [outFD, errorFD, inputFD] { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        let deadline = Date().addingTimeInterval(15)
        var request = Data()
        for (id, subtype) in [("lad-initialize", "initialize"), ("lad-settings", "get_settings")] {
            request.append(try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id,
                                                                      "request": ["subtype": subtype]], options: [.sortedKeys]))
            request.append(10)
        }
        var offset = 0
        while offset < request.count {
            lock.lock(); let isCancelled = cancelled; lock.unlock()
            if isCancelled { throw CancellationError() }
            guard Date() < deadline else { throw AgentCatalogError.timedOut }
            let written = request.withUnsafeBytes { Darwin.write(inputFD, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if written > 0 { offset += written }
            else if written < 0 && errno != EAGAIN && errno != EINTR {
                throw AgentCatalogError.failed("The model catalog connection closed unexpectedly.")
            } else {
                var writable = pollfd(fd: inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
                _ = Darwin.poll(&writable, 1, 50)
            }
        }
        var pending = Data(), receivedBytes = 0
        var initialize: Data?, settings: Data?, settingsAnswered = false
        while initialize == nil || !settingsAnswered {
            lock.lock(); let isCancelled = cancelled; lock.unlock()
            if isCancelled { throw CancellationError() }
            guard Date() < deadline else { throw AgentCatalogError.timedOut }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending.prefix(upTo: newline))
                pending.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      object["type"] as? String == "control_response",
                      let response = object["response"] as? [String: Any],
                      let id = response["request_id"] as? String else { continue }
                let success = response["subtype"] as? String == "success"
                let body = (response["response"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                if id == "lad-initialize" {
                    guard success, let body else {
                        let detail = String((response["error"] as? String ?? "The model catalog request was rejected.").prefix(512))
                        throw AgentCatalogError.failed(detail)
                    }
                    initialize = body
                } else if id == "lad-settings" {
                    settingsAnswered = true
                    settings = success ? body : nil
                }
            }
            if initialize != nil && settingsAnswered { break }
            var descriptors = [pollfd(fd: outFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                               pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)]
            _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), 50)
            var outputClosed = false
            for index in descriptors.indices where descriptors[index].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(descriptors[index].fd, &bytes, bytes.count)
                if count > 0, index == 0 {
                    receivedBytes += count
                    guard receivedBytes <= 8_388_608 else { throw AgentCatalogError.invalidResponse }
                    pending.append(contentsOf: bytes.prefix(count))
                } else if count == 0, index == 0 { outputClosed = true }
            }
            if outputClosed, pending.firstIndex(of: 10) == nil {
                if let initialize { return try CodexModelCatalog.decodeClaudeCatalog(initialize: initialize, settings: settings) }
                throw AgentCatalogError.failed("Check your installed Claude Code and its sign-in.")
            }
        }
        return try CodexModelCatalog.decodeClaudeCatalog(initialize: initialize!, settings: settings)
    }
}
