import Combine
import Darwin
import Foundation

struct CodexReasoningOption: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let description: String

    init(id: String, description: String = "") {
        self.id = id
        self.description = description
    }
}

struct CodexModelDescriptor: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let reasoningEfforts: [CodexReasoningOption]
    let defaultReasoningEffort: String?
    let isDefault: Bool

    init(id: String, displayName: String, description: String = "",
         reasoningEfforts: [CodexReasoningOption] = [], defaultReasoningEffort: String? = nil,
         isDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.isDefault = isDefault
    }
}

/// Model names and capabilities come from the same Codex installation that
/// performs design requests. Catalog lookup never starts an inference turn.
@MainActor
final class CodexModelCatalog: ObservableObject {
    static let shared = CodexModelCatalog()

    @Published private(set) var models: [CodexModelDescriptor] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var configuredModelID: String?
    @Published private(set) var configuredReasoningEffort: String?

    var configuredModel: String? { configuredModelID }
    var executablePath: String? { loadedExecutable }

    func matches(executable: String) -> Bool {
        loadedExecutable == executable.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var job: CodexCatalogJob?
    private var generation = UUID()
    private var loadedExecutable: String?
    private var loadedAt: Date?

    func refresh(executable: String, force: Bool = false) async {
        let requested = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, requested == loadedExecutable {
            if isLoading { return }
            if error == nil, !models.isEmpty, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        }
        job?.cancel()
        let token = UUID()
        generation = token
        isLoading = true
        error = nil
        if loadedExecutable != requested {
            models = []; configuredModelID = nil; configuredReasoningEffort = nil
            loadedAt = nil
        }
        loadedExecutable = requested
        let current = CodexCatalogJob(executable: requested)
        job = current
        defer {
            if generation == token { isLoading = false; job = nil }
        }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await current.run()
            } onCancel: { current.cancel() }
            guard generation == token, !Task.isCancelled else { return }
            models = snapshot.models
            configuredModelID = snapshot.configuredModelID
            configuredReasoningEffort = snapshot.configuredReasoningEffort
            loadedAt = Date()
        } catch is CancellationError {
            if generation == token { error = nil }
        } catch {
            guard generation == token else { return }
            self.error = Task.isCancelled ? nil : error.localizedDescription
        }
    }

    /// Decode the model/list result, independently of transport, for protocol
    /// validation and regression tests. Preserve future advertised effort IDs.
    nonisolated static func decodePage(_ result: Data) throws -> (models: [CodexModelDescriptor], nextCursor: String?) {
        guard result.count <= 1_048_576 else { throw CatalogError.invalidResponse }
        let page = try JSONDecoder().decode(ModelPage.self, from: result)
        guard page.data.count <= 1_000 else { throw CatalogError.invalidResponse }
        var seen = Set<String>()
        let models = try page.data.compactMap { entry -> CodexModelDescriptor? in
            if entry.hidden == true { return nil }
            let id = entry.model ?? entry.id
            guard let id, validIdentifier(id), seen.insert(id).inserted else { throw CatalogError.invalidResponse }
            let name = entry.displayName ?? id
            guard validText(name, maximum: 256), validText(entry.description ?? "", maximum: 8_192, allowEmpty: true) else {
                throw CatalogError.invalidResponse
            }
            let advertised = entry.supportedReasoningEfforts ?? []
            guard advertised.count <= 64 else { throw CatalogError.invalidResponse }
            var efforts = Set<String>()
            let options = try advertised.map { option -> CodexReasoningOption in
                guard let effort = CodexReasoningEffort(rawValue: option.reasoningEffort), effort != .defaultConfiguration,
                      efforts.insert(option.reasoningEffort).inserted,
                      validText(option.description ?? "", maximum: 8_192, allowEmpty: true) else { throw CatalogError.invalidResponse }
                return CodexReasoningOption(id: option.reasoningEffort, description: option.description ?? "")
            }
            if let value = entry.defaultReasoningEffort {
                guard let effort = CodexReasoningEffort(rawValue: value), effort != .defaultConfiguration else {
                    throw CatalogError.invalidResponse
                }
            }
            return CodexModelDescriptor(id: id, displayName: name, description: entry.description ?? "",
                                        reasoningEfforts: options, defaultReasoningEffort: entry.defaultReasoningEffort,
                                        isDefault: entry.isDefault ?? false)
        }
        if let cursor = page.nextCursor, !validText(cursor, maximum: 4_096) { throw CatalogError.invalidResponse }
        return (models, page.nextCursor)
    }

    nonisolated static func decodeConfiguration(_ result: Data) -> (model: String?, effort: String?) {
        guard result.count <= 1_048_576,
              let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              let config = object["config"] as? [String: Any] else { return (nil, nil) }
        let model = config["model"] as? String
        let effort = config["model_reasoning_effort"] as? String
        return (model.flatMap { validIdentifier($0) ? $0 : nil }, effort.flatMap {
            CodexReasoningEffort(rawValue: $0).flatMap { $0 == .defaultConfiguration ? nil : $0.rawValue }
        })
    }

    private struct ModelPage: Decodable {
        let data: [WireModel]
        let nextCursor: String?
    }
    private struct WireModel: Decodable {
        let id: String?
        let model: String?
        let displayName: String?
        let description: String?
        let hidden: Bool?
        let supportedReasoningEfforts: [WireEffort]?
        let defaultReasoningEffort: String?
        let isDefault: Bool?
    }
    private struct WireEffort: Decodable { let reasoningEffort: String; let description: String? }

    nonisolated private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }
    }
    nonisolated private static func validText(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && value.utf8.count <= maximum &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
    }
}

private struct CatalogSnapshot: Sendable {
    var models: [CodexModelDescriptor]
    var configuredModelID: String?
    var configuredReasoningEffort: String?
}

private enum CatalogError: LocalizedError {
    case executableMissing, invalidResponse, timedOut, failed(String)
    var errorDescription: String? {
        switch self {
        case .executableMissing: return "Install the ChatGPT desktop app or Codex CLI to load models."
        case .invalidResponse: return "Codex returned an unreadable model catalog."
        case .timedOut: return "Codex model lookup timed out. Try refreshing the model list."
        case .failed(let detail): return "Could not load Codex models. \(detail)"
        }
    }
}

/// A bounded, short-lived app-server connection. Its only requests are
/// initialize, model/list, and config/read; no thread or turn is created.
private final class CodexCatalogJob: @unchecked Sendable {
    private let executable: String
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    init(executable: String) { self.executable = executable }

    func run() async throws -> CatalogSnapshot {
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

    private func lookup() throws -> CatalogSnapshot {
        guard let binary = CodexService.resolveExecutable(executable) else { throw CatalogError.executableMissing }
        let path = binary.path
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); running = true; lock.unlock() }
        catch { lock.unlock(); throw CatalogError.failed("Check the Codex installation and sign-in.") }
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
        _ = fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(errorFD, F_SETFL, fcntl(errorFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        var pending = Data(), stderrTail = Data(), receivedBytes = 0, outputClosed = false
        let deadline = Date().addingTimeInterval(10)

        func send(_ method: String, id: Int? = nil, params: [String: Any]? = nil) throws {
            var object: [String: Any] = ["method": method]
            if let id { object["id"] = id }
            if let params { object["params"] = params }
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            var offset = 0
            while offset < data.count {
                lock.lock(); let isCancelled = cancelled; lock.unlock()
                if isCancelled { throw CancellationError() }
                guard Date() < deadline else { throw CatalogError.timedOut }
                let written = data.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if written > 0 { offset += written }
                else if written < 0 && errno != EAGAIN && errno != EINTR {
                    throw CatalogError.failed("The model catalog connection closed unexpectedly.")
                } else {
                    var writable = pollfd(fd: inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
                    _ = Darwin.poll(&writable, 1, 50)
                }
            }
        }

        func response(_ id: Int, optional: Bool = false) throws -> Data? {
            while Date() < deadline {
                lock.lock(); let isCancelled = cancelled; lock.unlock()
                if isCancelled { throw CancellationError() }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending.prefix(upTo: newline))
                    pending.removeSubrange(...newline)
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        if optional { return nil }
                        let detail = String((error["message"] as? String ?? "Check the Codex connection.").prefix(512))
                        throw CatalogError.failed(detail)
                    }
                    guard let result = object["result"] else { throw CatalogError.invalidResponse }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                var descriptors = [pollfd(fd: outFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                                   pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)]
                _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), 50)
                for index in descriptors.indices where descriptors[index].revents != 0 {
                    var bytes = [UInt8](repeating: 0, count: 16_384)
                    let count = Darwin.read(descriptors[index].fd, &bytes, bytes.count)
                    if count > 0 {
                        if index == 0 {
                            receivedBytes += count
                            guard receivedBytes <= 4_194_304 else { throw CatalogError.invalidResponse }
                            pending.append(contentsOf: bytes.prefix(count))
                            guard pending.count <= 1_048_576 else { throw CatalogError.invalidResponse }
                        } else {
                            stderrTail.append(contentsOf: bytes.prefix(count))
                            if stderrTail.count > 65_536 { stderrTail.removeFirst(stderrTail.count - 65_536) }
                        }
                    } else if count == 0, index == 0 { outputClosed = true }
                }
                if outputClosed {
                    if !pending.isEmpty {
                        // The protocol requires JSONL; do not spin on a
                        // truncated response after the stream has closed.
                        throw CatalogError.invalidResponse
                    }
                    throw CatalogError.failed("Check the Codex installation and sign-in.")
                }
            }
            throw CatalogError.timedOut
        }

        try send("initialize", id: 1, params: ["clientInfo": ["name": "lad", "title": "LAD", "version": "1.0"],
                                              "capabilities": ["experimentalApi": false]])
        _ = try response(1)
        try send("initialized")
        var models: [CodexModelDescriptor] = [], cursor: String?, cursors = Set<String>(), id = 2
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            try send("model/list", id: id, params: params)
            guard let result = try response(id) else { throw CatalogError.invalidResponse }
            let page = try CodexModelCatalog.decodePage(result)
            models.append(contentsOf: page.models)
            guard models.count <= 1_000, id < 12 else { throw CatalogError.invalidResponse }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw CatalogError.invalidResponse }
            id += 1
        } while cursor != nil
        guard !models.isEmpty, Set(models.map(\.id)).count == models.count else { throw CatalogError.invalidResponse }
        try send("config/read", id: id, params: ["includeLayers": false])
        let config = try response(id, optional: true).map(CodexModelCatalog.decodeConfiguration) ?? (nil, nil)
        return CatalogSnapshot(models: models, configuredModelID: config.0, configuredReasoningEffort: config.1)
    }
}
