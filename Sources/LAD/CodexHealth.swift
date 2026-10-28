import Combine
import Darwin
import Foundation

/// Deliberately contains no account identity, credentials, or raw server text.
struct CodexHealthIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case missingExecutable, signInRequired, connectionUnavailable, usageLimited, spendingLimited
    }

    let kind: Kind
    let diagnostic: String?

    init(_ kind: Kind, diagnostic: String? = nil) {
        self.kind = kind
        self.diagnostic = diagnostic
    }

    var title: String {
        switch kind {
        case .missingExecutable: return "Codex is not installed"
        case .signInRequired: return "Sign in to Codex"
        case .connectionUnavailable: return "Could not verify Codex"
        case .usageLimited: return "Codex usage limit reached"
        case .spendingLimited: return "Codex spending limit reached"
        }
    }

    var message: String {
        switch kind {
        case .missingExecutable:
            return "Install the ChatGPT desktop app or Codex CLI to connect LAD."
        case .signInRequired:
            return "Sign in to the ChatGPT desktop app or Codex CLI, then check again."
        case .connectionUnavailable:
            return "Check your connection and Codex installation, then try again."
        case .usageLimited:
            return "Check your Codex usage limits or wait for your allowance to reset."
        case .spendingLimited:
            return "Check your Codex spending controls before sending another request."
        }
    }

    var description: String { message }
    var details: String? { diagnostic }
}

/// Settings observes problems only. A successful check stays silent and never
/// creates an agent thread, inference turn, task workspace, or CAD worker.
@MainActor
final class CodexHealth: ObservableObject {
    static let shared = CodexHealth()

    @Published private(set) var issue: CodexHealthIssue?
    @Published private(set) var isChecking = false

    private struct ActiveCheck {
        let id: UUID
        let executable: String
        let job: CodexHealthJob
        let task: Task<Void, Never>
        var waiters: Set<UUID>
    }

    private var active: ActiveCheck?
    private var loadedExecutable: String?
    private var checkedAt: Date?
    private let timeout: TimeInterval
    private let successCacheInterval: TimeInterval
    private let failureCacheInterval: TimeInterval
    private let now: () -> Date
    private let onRequest: @Sendable (String) -> Void

    init(timeout: TimeInterval = 8, successCacheInterval: TimeInterval = 30,
         failureCacheInterval: TimeInterval = 5, now: @escaping () -> Date = Date.init,
         onRequest: @escaping @Sendable (String) -> Void = { _ in }) {
        self.timeout = timeout
        self.successCacheInterval = successCacheInterval
        self.failureCacheInterval = failureCacheInterval
        self.now = now
        self.onRequest = onRequest
    }

    func refresh(executable: String, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let requested = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        if let active, active.executable == requested {
            await wait(for: active.id)
            return
        }
        if let active {
            self.active = nil
            active.job.cancel()
            active.task.cancel()
        }
        if !force, loadedExecutable == requested, let checkedAt,
           now().timeIntervalSince(checkedAt) < (issue == nil ? successCacheInterval : failureCacheInterval) {
            isChecking = false
            return
        }
        if loadedExecutable != requested {
            issue = nil
            checkedAt = nil
        }
        loadedExecutable = requested
        isChecking = true
        let id = UUID()
        let job = CodexHealthJob(executable: requested, timeout: timeout, onRequest: onRequest)
        let task = Task<Void, Never> { [weak self] in
            let result: Result<CodexHealthIssue?, Error>
            do { result = .success(try await job.run()) }
            catch { result = .failure(error) }
            self?.finish(id: id, result: result)
        }
        active = ActiveCheck(id: id, executable: requested, job: job, task: task, waiters: [])
        await wait(for: id)
    }

    private func wait(for id: UUID) async {
        guard active?.id == id, let task = active?.task else { return }
        let waiter = UUID()
        active?.waiters.insert(waiter)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeWaiter(waiter, from: id) }
        }
        removeWaiter(waiter, from: id)
    }

    private func removeWaiter(_ waiter: UUID, from id: UUID) {
        guard active?.id == id else { return }
        active?.waiters.remove(waiter)
        if active?.waiters.isEmpty == true {
            let abandoned = active
            active = nil
            isChecking = false
            abandoned?.job.cancel()
            abandoned?.task.cancel()
        }
    }

    private func finish(id: UUID, result: Result<CodexHealthIssue?, Error>) {
        guard active?.id == id else { return }
        active = nil
        isChecking = false
        switch result {
        case .success(let issue):
            self.issue = issue
            checkedAt = now()
        case .failure(is CancellationError):
            break
        case .failure:
            issue = CodexHealthIssue(.connectionUnavailable, diagnostic: "The Codex status check failed.")
            checkedAt = now()
        }
    }
}

private enum CodexHealthError: Error { case invalidResponse, timedOut, closed, rejected(String, Int?) }

/// Intentionally separate from the model catalog: authentication must not depend
/// on a nonempty model list or its longer cache. Keep this transport's fixed
/// read-only RPC allowlist auditable rather than coupling it to agent transport.
private final class CodexHealthJob: @unchecked Sendable {
    private let executable: String
    private let timeout: TimeInterval
    private let onRequest: @Sendable (String) -> Void
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    init(executable: String, timeout: TimeInterval, onRequest: @escaping @Sendable (String) -> Void) {
        self.executable = executable
        self.timeout = timeout
        self.onRequest = onRequest
    }

    func run() async throws -> CodexHealthIssue? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do { continuation.resume(returning: try lookup()) }
                catch is CancellationError { continuation.resume(throwing: CancellationError()) }
                catch {
                    let diagnostic: String
                    switch error {
                    case CodexHealthError.timedOut: diagnostic = "The Codex status check timed out."
                    case CodexHealthError.invalidResponse: diagnostic = "Codex returned an unreadable status response."
                    case CodexHealthError.rejected(let method, let code):
                        diagnostic = "Codex rejected \(method)\(code.map { " (RPC code \($0))" } ?? "")."
                    default: diagnostic = "The Codex status connection closed unexpectedly."
                    }
                    continuation.resume(returning: CodexHealthIssue(.connectionUnavailable, diagnostic: diagnostic))
                }
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
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [self] in
                lock.lock(); defer { lock.unlock() }
                if running && process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
    }

    private func lookup() throws -> CodexHealthIssue? {
        guard !executable.isEmpty, let binary = CodexService.resolveExecutable(executable) else {
            return CodexHealthIssue(.missingExecutable)
        }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = binary.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); running = true; lock.unlock() }
        catch { lock.unlock(); throw CodexHealthError.closed }
        defer {
            try? input.fileHandleForWriting.close()
            lock.lock()
            if process.isRunning { process.terminate() }
            lock.unlock()
            let deadline = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            lock.lock(); running = false; lock.unlock()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        for descriptor in [inputFD, outputFD, errorFD] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data(), receivedBytes = 0, outputClosed = false

        func check() throws {
            lock.lock(); let isCancelled = cancelled; lock.unlock()
            if isCancelled { throw CancellationError() }
            if Date() >= deadline { throw CodexHealthError.timedOut }
        }

        func send(_ method: String, id: Int? = nil, params: [String: Any]? = nil) throws {
            // This list is deliberately exhaustive; health checks cannot become
            // an agent request accidentally through a caller-supplied method.
            guard ["initialize", "initialized", "account/read", "account/rateLimits/read"].contains(method) else {
                throw CodexHealthError.invalidResponse
            }
            var request: [String: Any] = ["method": method]
            if let id { request["id"] = id }
            if let params { request["params"] = params }
            var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            onRequest(method)
            var offset = 0
            while offset < data.count {
                try check()
                let count = data.withUnsafeBytes {
                    Darwin.write(inputFD, $0.baseAddress!.advanced(by: offset), data.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { throw CodexHealthError.closed }
                else {
                    var descriptor = pollfd(fd: inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
                    _ = Darwin.poll(&descriptor, 1, 25)
                }
            }
        }

        func response(_ id: Int, method: String) throws -> Data {
            while true {
                try check()
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending.prefix(upTo: newline))
                    pending.removeSubrange(...newline)
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                        throw CodexHealthError.invalidResponse
                    }
                    // Notifications contain no required health state. Ignore
                    // them rather than retaining arbitrary account/event data.
                    guard object["id"] as? Int == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        throw CodexHealthError.rejected(method, error["code"] as? Int)
                    }
                    guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else {
                        throw CodexHealthError.invalidResponse
                    }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                if outputClosed { throw CodexHealthError.closed }
                var descriptors = [pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                                   pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)]
                _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), 25)
                for index in descriptors.indices where descriptors[index].revents != 0 {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                    if count > 0, index == 0 {
                        receivedBytes += count
                        guard receivedBytes <= 1_048_576 else { throw CodexHealthError.invalidResponse }
                        pending.append(contentsOf: buffer.prefix(count))
                        guard pending.count <= 262_144 else { throw CodexHealthError.invalidResponse }
                    } else if count == 0, index == 0 { outputClosed = true }
                    // Drain and discard stderr; it can contain account details.
                }
            }
        }

        try send("initialize", id: 1, params: ["clientInfo": ["name": "lad", "title": "LAD", "version": "1.0"],
                                             "capabilities": ["experimentalApi": false]])
        _ = try response(1, method: "initialize")
        try send("initialized")
        try send("account/read", id: 2, params: ["refreshToken": false])
        let account = try JSONDecoder().decode(HealthAccount.self, from: response(2, method: "account/read"))
        guard account.requiresOpenaiAuth else { return nil }
        guard let type = account.account?.type else { return CodexHealthIssue(.signInRequired) }
        guard type == "chatgpt" || type == "chatgptAuthTokens" else { return nil }
        try send("account/rateLimits/read", id: 3, params: [:])
        let limits = try JSONDecoder().decode(HealthRateLimits.self, from: response(3, method: "account/rateLimits/read"))
        guard let applicable = limits.rateLimits else { throw CodexHealthError.invalidResponse }
        if applicable.spendControlReached == true { return CodexHealthIssue(.spendingLimited) }
        if let reached = applicable.rateLimitReachedType, !reached.isEmpty {
            return CodexHealthIssue(.usageLimited)
        }
        let timestamp = Date().timeIntervalSince1970
        let exhausted = [applicable.primary, applicable.secondary].compactMap { $0 }.contains {
            $0.usedPercent >= 100 && ($0.resetsAt.map { $0 > timestamp } ?? true)
        }
        if exhausted, let credits = applicable.credits, !credits.hasCredits, !credits.unlimited {
            return CodexHealthIssue(.usageLimited)
        }
        return nil
    }
}

// Decode only the fields needed for the decision. Email, balances, tokens, and
// account IDs never become health state, diagnostics, or persisted preferences.
private struct HealthAccount: Decodable {
    struct Account: Decodable { let type: String }
    let account: Account?
    let requiresOpenaiAuth: Bool
}

private struct HealthRateLimits: Decodable {
    struct Window: Decodable { let usedPercent: Double; let resetsAt: Double? }
    struct Credits: Decodable { let hasCredits: Bool; let unlimited: Bool }
    struct Limit: Decodable {
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
        let spendControlReached: Bool?
        let rateLimitReachedType: String?
    }
    let rateLimits: Limit?
}
