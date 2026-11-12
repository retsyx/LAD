import Darwin
import Foundation

/// Non-blocking pipe plumbing shared by the agent task and model catalog
/// processes: polled reads and writes, a bounded stderr tail and escalating
/// shutdown. Each job keeps its own protocol handling.
final class AgentProcessPipes {
    let process: Process
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer: [UInt8]
    private var writing: Data?
    private var writeOffset = 0
    /// The last 16 KB of stderr, for failure messages.
    private(set) var stderrTail = Data()
    private(set) var outputClosed = false

    init(_ process: Process, readBufferSize: Int = 16_384) {
        self.process = process
        buffer = [UInt8](repeating: 0, count: readBufferSize)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
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

    /// Wait up to `timeout` milliseconds, write queued input taken from `next`,
    /// and deliver stdout to `onOutput`. Each stream yields after about 1 MB so
    /// the caller's loop stays responsive to cancellation. Returns false if the
    /// process closed its input.
    func step(timeout: Int32, next: () -> Data? = { nil }, onOutput: (Data) throws -> Void) rethrows -> Bool {
        if writing == nil, let data = next() { writing = data; writeOffset = 0 }
        var descriptors = [
            pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: writing == nil ? -1 : inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
        ]
        _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), timeout)
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
                if count == 0 { if index == 0 { outputClosed = true }; break }
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

    /// Write all of `data`, waiting for the pipe as needed. `check` runs before
    /// each attempt and throws to stop. Returns false if the input closed.
    func writeAll(_ data: Data, check: () throws -> Void) rethrows -> Bool {
        var offset = 0
        while offset < data.count {
            try check()
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(inputFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written }
            else if written < 0 && errno != EAGAIN && errno != EINTR { return false }
            else {
                var writable = pollfd(fd: inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
                _ = Darwin.poll(&writable, 1, 50)
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
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
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
