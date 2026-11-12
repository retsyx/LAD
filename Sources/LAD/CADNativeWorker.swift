import Darwin
import Foundation

/// One long-lived worker process per engine for native-geometry requests:
/// runtime inspection, measurement, clearance and export. CadQuery loads once,
/// and the worker keeps recently read solids between requests. Generated
/// programs never run here; each build keeps its own sandboxed process.
///
/// Requests run one at a time. A canceled caller returns at once; if its
/// abandoned request has not finished after a short grace period, the worker
/// is stopped so a long stale request cannot delay the next one. The process
/// exits when idle, when its engine is released, and when LAD exits, because
/// it reads its requests from LAD's pipe.
actor CADNativeWorker {
    struct Reply: Decodable, Sendable {
        var id: Int?
        var status: String
        var message: String?
    }

    private let temporaryDirectory: URL
    private let idleTimeout: Duration
    private let cancellationGrace: Duration
    private var server: CADNativeServer?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextID = 0
    private var runningID: Int?
    private var idleTask: Task<Void, Never>?
    /// Worker processes started, for diagnostics and regression tests.
    private(set) var launches = 0

    init(temporaryDirectory: URL, idleTimeout: Duration = .seconds(120), cancellationGrace: Duration = .seconds(2)) {
        self.temporaryDirectory = temporaryDirectory
        self.idleTimeout = idleTimeout
        self.cancellationGrace = cancellationGrace
    }

    deinit {
        idleTask?.cancel()
        server?.terminate()
    }

    var isRunning: Bool { server?.isRunning ?? false }

    /// Perform the request staged as `request.json` in `folder`. Results and
    /// any error report stay in that folder.
    func perform(folder: URL, threads: Int, python: String) async throws -> Reply {
        await acquire()
        guard !Task.isCancelled else { release(); throw CancellationError() }
        idleTask?.cancel(); idleTask = nil
        let server: CADNativeServer
        do { server = try running(python: python) } catch { release(); throw error }
        nextID += 1
        let id = nextID
        runningID = id
        let request = folder.appendingPathComponent("request.json")
        let handoff = ReplyHandoff()
        // The request runs in its own task so a canceled caller can return
        // while the worker finishes or is stopped; the next request waits.
        Task { [weak self] in
            let result: Result<Reply, Error>
            do { result = .success(try await server.send(id: id, request: request, output: folder, threads: threads)) }
            catch { result = .failure(error) }
            handoff.resume(with: result)
            await self?.finished(id: id, server: server)
        }
        let grace = cancellationGrace
        return try await withTaskCancellationHandler {
            try await handoff.value()
        } onCancel: {
            handoff.resume(with: .failure(CancellationError()))
            Task { [weak self] in
                try? await Task.sleep(for: grace)
                await self?.stop(ifStillRunning: id)
            }
        }
    }

    /// Stop the worker now. The next request starts a new one.
    func stop() {
        idleTask?.cancel(); idleTask = nil
        server?.terminate()
        server = nil
    }

    private func running(python: String) throws -> CADNativeServer {
        if let server, server.isRunning { return server }
        let launch = try EngineService.workerLaunch(python: python)
        let started = try CADNativeServer(launch: launch, temporaryDirectory: temporaryDirectory)
        server = started
        launches += 1
        return started
    }

    private func finished(id: Int, server finishedServer: CADNativeServer) {
        if runningID == id { runningID = nil }
        if server === finishedServer, !finishedServer.isRunning { server = nil }
        release()
    }

    private func stop(ifStillRunning id: Int) {
        guard runningID == id else { return }
        server?.terminate()
        server = nil
    }

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard waiters.isEmpty else { waiters.removeFirst().resume(); return }
        busy = false
        guard server != nil else { return }
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard !busy else { return }
        stop()
    }
}

/// Resumes a waiting caller exactly once, with whichever of the reply or the
/// caller's cancellation comes first.
private final class ReplyHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CADNativeWorker.Reply, Error>?
    private var result: Result<CADNativeWorker.Reply, Error>?

    func value() async throws -> CADNativeWorker.Reply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(with result: Result<CADNativeWorker.Reply, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// The worker process and its line protocol: one JSON request per line on
/// stdin, one JSON reply per line on stdout.
private final class CADNativeServer: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let scratch: EngineBuildArtifacts
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<CADNativeWorker.Reply, Error>] = [:]
    private var buffer = Data()
    private var stopped = false

    init(launch: EngineService.WorkerLaunch, temporaryDirectory: URL) throws {
        // Matplotlib, cache and temporary files live as long as the process.
        scratch = try EngineBuildArtifacts.create(in: temporaryDirectory, token: UUID(), containsSTEP: false)
        let environment = try EngineService.workerEnvironment(folder: scratch.folder, launch: launch)
        let requests = Pipe(), replies = Pipe()
        input = requests.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = launch.runtime
        process.arguments = [launch.worker.path, "--serve"]
        process.currentDirectoryURL = scratch.folder
        process.environment = environment
        process.standardInput = requests
        process.standardOutput = replies
        let log = scratch.folder.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        replies.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.markStopped()
                return
            }
            self.receive(data)
        }
        process.terminationHandler = { [weak self] _ in self?.markStopped() }
        try process.run()
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && process.isRunning
    }

    func send(id: Int, request: URL, output: URL, threads: Int) async throws -> CADNativeWorker.Reply {
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "request": request.path,
                                                              "output": output.path, "threads": threads])
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !stopped else { lock.unlock(); continuation.resume(throwing: stoppedError()); return }
            pending[id] = continuation
            lock.unlock()
            if !write(line) {
                lock.lock()
                let waiting = pending.removeValue(forKey: id)
                lock.unlock()
                waiting?.resume(throwing: stoppedError())
            }
        }
    }

    func terminate() {
        try? input.close()
        let pid = process.isRunning ? process.processIdentifier : 0
        if pid > 0 {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
        markStopped()
    }

    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(input.fileDescriptor, raw.baseAddress! + offset, raw.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var ready: [(CheckedContinuation<CADNativeWorker.Reply, Error>, CADNativeWorker.Reply)] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let reply = try? JSONDecoder().decode(CADNativeWorker.Reply.self, from: Data(line)),
               let id = reply.id, let waiting = pending.removeValue(forKey: id) {
                ready.append((waiting, reply))
            }
        }
        // Replies are short; a runaway line means the protocol is broken.
        let broken = buffer.count > 1_000_000
        lock.unlock()
        for (waiting, reply) in ready { waiting.resume(returning: reply) }
        if broken { terminate() }
    }

    private func markStopped() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        let error = stoppedError()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func stoppedError() -> LADError {
        let log = scratch.folder.appendingPathComponent("stderr.log")
        let tail = (try? EngineArtifact.tail(log, in: scratch.folder, maximumBytes: 3_000)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return LADError.message("The CAD engine stopped before finishing.\(tail.isEmpty ? "" : "\n\n\(tail)")")
    }
}
