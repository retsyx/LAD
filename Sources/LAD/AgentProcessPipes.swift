import Darwin
import Foundation

/// Non-blocking pipe plumbing shared by the agent task and model catalog
/// processes: event-driven reads and writes, a bounded stderr tail and
/// escalating shutdown. Each job keeps its own protocol handling.
///
/// Waits end on stream activity, process exit or `wake()`, and otherwise only
/// at the caller's next deadline, so idle jobs do not poll.
final class AgentProcessPipes {
    let process: Process
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer: [UInt8]
    private var writing: Data?
    private var writeOffset = 0
    /// The last 16 KB of stderr, for failure messages.
    private(set) var stderrTail = Data()
    private(set) var outputClosed = false
    private var errorsClosed = false
    /// Read and write ends of a self-pipe that interrupts a wait.
    private let wakeFDs: (read: Int32, write: Int32)
    private let exitLock = NSLock()
    private var exitedValue = false
    private let exitSignal = DispatchSemaphore(value: 0)

    init(_ process: Process, readBufferSize: Int = 16_384) {
        self.process = process
        buffer = [UInt8](repeating: 0, count: readBufferSize)
        var descriptors: [Int32] = [-1, -1]
        if Darwin.pipe(&descriptors) == 0 {
            for descriptor in descriptors {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }
        }
        wakeFDs = (descriptors[0], descriptors[1])
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            exitLock.lock(); exitedValue = true; exitLock.unlock()
            exitSignal.signal()
            wake()
        }
    }

    deinit {
        if wakeFDs.read >= 0 { Darwin.close(wakeFDs.read) }
        if wakeFDs.write >= 0 { Darwin.close(wakeFDs.write) }
    }

    /// True once the process has exited, whether or not its streams closed.
    var hasExited: Bool {
        exitLock.lock(); defer { exitLock.unlock() }
        return exitedValue
    }

    /// Ends the current or next wait, for example after queuing input or
    /// cancelling. Safe from any thread.
    func wake() {
        var byte: UInt8 = 1
        _ = Darwin.write(wakeFDs.write, &byte, 1)
    }

    /// Milliseconds until `deadline` for poll(2): -1 waits indefinitely.
    private static func pollTimeout(until deadline: Date?) -> Int32 {
        guard let deadline else { return -1 }
        let milliseconds = (deadline.timeIntervalSinceNow * 1_000).rounded(.up)
        return Int32(clamping: Int(max(0, min(milliseconds, Double(Int32.max)))))
    }

    private func drainWake() {
        var bytes = [UInt8](repeating: 0, count: 64)
        while Darwin.read(wakeFDs.read, &bytes, bytes.count) > 0 {}
    }

    private var inputFD: Int32 { input.fileHandleForWriting.fileDescriptor }
    private var outputFD: Int32 { output.fileHandleForReading.fileDescriptor }
    private var errorFD: Int32 { errors.fileHandleForReading.fileDescriptor }

    /// Call once the process has launched.
    func configure() {
        for descriptor in [outputFD, errorFD, inputFD] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
    }

    /// Wait until stream activity, process exit, `wake()` or `deadline` (nil
    /// waits indefinitely), write queued input taken from `next`, and deliver
    /// stdout to `onOutput`. Each stream yields after about 1 MB so the
    /// caller's loop stays responsive to cancellation. Returns false if the
    /// process closed its input.
    func step(until deadline: Date?, next: () -> Data? = { nil }, onOutput: (Data) throws -> Void) rethrows -> Bool {
        if writing == nil, let data = next() { writing = data; writeOffset = 0 }
        var descriptors = [
            pollfd(fd: outputClosed ? -1 : outputFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: errorsClosed ? -1 : errorFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: writing == nil ? -1 : inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: wakeFDs.read, events: Int16(POLLIN), revents: 0)
        ]
        // Exit is a wake source, but the exit grace period still needs a
        // deadline when the streams stay open.
        _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), Self.pollTimeout(until: deadline))
        if descriptors[3].revents != 0 { drainWake() }
        if descriptors[2].revents != 0, let data = writing {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(inputFD, bytes.baseAddress!.advanced(by: writeOffset), bytes.count - writeOffset)
            }
            if written > 0 {
                writeOffset += written
                if writeOffset == data.count { writing = nil }
            } else if written < 0, errno != EAGAIN, errno != EINTR {
                return false
            }
        }
        for index in 0..<2 where descriptors[index].revents != 0 {
            var received = 0
            while received < 1_048_576 {
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count == 0 { if index == 0 { outputClosed = true } else { errorsClosed = true }; break }
                if count < 0 { break }
                let data = Data(buffer.prefix(count))
                if index == 0 { try onOutput(data) }
                else {
                    stderrTail.append(data)
                    if stderrTail.count > 16_384 { stderrTail.removeFirst(stderrTail.count - 16_384) }
                }
                received += count
            }
        }
        return true
    }

    /// Write all of `data`, waiting for the pipe, process exit, `wake()` or
    /// `deadline` as needed. `check` runs before each attempt and throws to
    /// stop. Returns false if the input closed.
    func writeAll(_ data: Data, until deadline: Date?, check: () throws -> Void) rethrows -> Bool {
        var offset = 0
        while offset < data.count {
            try check()
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(inputFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written }
            else if written < 0 && errno != EAGAIN && errno != EINTR { return false }
            else {
                var descriptors = [pollfd(fd: inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0),
                                   pollfd(fd: wakeFDs.read, events: Int16(POLLIN), revents: 0)]
                _ = Darwin.poll(&descriptors, 2, Self.pollTimeout(until: deadline))
                if descriptors[1].revents != 0 { drainWake() }
            }
        }
        return true
    }

    /// Close input, ask the process to exit and kill it if it is still running
    /// half a second later. `terminate` lets a job synchronize with its own
    /// cancellation.
    func shutdown(terminate: () -> Void) {
        try? input.fileHandleForWriting.close()
        terminate()
        if !hasExited, exitSignal.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
}

/// Splits a stream into newline-terminated lines, scanning only new bytes so
/// a large malformed line stays linear. A line over `maximumBytes` is dropped
/// whole, and `oversized` is called once for it.
struct AgentLineBuffer {
    let maximumBytes: Int
    private var line = Data()
    private var discarding = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    mutating func append(_ chunk: Data, oversized: () -> Void, receive: (Data) throws -> Void) rethrows {
        try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let newline = memchr(base.advanced(by: offset), 10, bytes.count - offset)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                let count = end - offset
                if !discarding {
                    if count > maximumBytes - line.count {
                        oversized()
                        line.removeAll(keepingCapacity: false)
                        discarding = true
                    } else if count > 0 {
                        line.append(base.assumingMemoryBound(to: UInt8.self).advanced(by: offset), count: count)
                    }
                }
                guard newline != nil else { break }
                if !discarding {
                    let complete = line
                    line = Data()
                    try receive(complete)
                }
                discarding = false
                offset = end + 1
            }
        }
    }
}
