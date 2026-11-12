import Foundation
import Network
import XCTest
@testable import LAD

final class LoopbackHTTPServerTests: XCTestCase {
    func testParserPreservesBinaryBodiesAcrossArbitraryPacketBoundaries() throws {
        let body = Data([0, 13, 10, 255, 1, 2])
        var parser = LoopbackHTTPParser(maximumBodyBytes: 100)
        let header = Data("POST /tasks/a/files?name=part.py HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Length: 6\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        for byte in header { try parser.append(Data([byte])) }
        XCTAssertEqual(parser.head?.method, "POST")
        XCTAssertEqual(parser.head?.headers["content-type"], "application/octet-stream")
        XCTAssertEqual(parser.head?.body.count, 0, "Admission sees metadata before receiving the body.")
        XCTAssertNil(parser.request)
        for byte in body { try parser.append(Data([byte])) }
        XCTAssertEqual(parser.request?.target, "/tasks/a/files?name=part.py")
        XCTAssertEqual(parser.request?.body, body)
    }

    func testCompletedRequestSharesTheReceivedBodyInsteadOfCopyingIt() throws {
        let body = Data((0..<(256 * 1024 + 7)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var parser = LoopbackHTTPParser(maximumBodyBytes: 1 << 20)
        // The first packet carries the head and the start of the upload.
        var first = Data("POST /tasks/a/files?name=part.step HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        first.append(body.prefix(100))
        try parser.append(first)
        var offset = 100
        while offset < body.count {
            let end = min(offset + 65_536, body.count)
            try parser.append(body[offset..<end])
            offset = end
        }
        let request = try XCTUnwrap(parser.request)
        let again = try XCTUnwrap(parser.request)
        XCTAssertEqual(request.body, body)
        let address = request.body.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(address, again.body.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) },
                       "Requests must share the parser's body buffer rather than holding another copy.")
        XCTAssertThrowsError(try parser.append(Data([0]))) {
            XCTAssertEqual(($0 as? LoopbackHTTPParser.Failure)?.status, 400)
        }
    }

    func testParserRejectsAmbiguousFramingAndHeaderInjection() {
        let invalid = [
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\ncontent-length: 1\r\n\r\nx",
            "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: +1\r\n\r\nx",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1, 1\r\n\r\nx",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\nextra",
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: one\r\nAuthorization: two\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\n Folded: value\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nX-Test: injected\nvalue\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nX-Test: injected\rvalue\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nX-Test: nul\0value\r\n\r\n",
            "POST http://localhost/mcp HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "POST / HTTP/1.1\r\n\r\n",
            "POST / HTTP/1.0\r\nHost: localhost\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n\r\n"
        ]
        for request in invalid {
            var parser = LoopbackHTTPParser(maximumBodyBytes: 100)
            XCTAssertThrowsError(try parser.append(Data(request.utf8)), request)
        }
    }

    func testParserBoundsDeclaredAndActualBodiesAndHeaders() throws {
        var declared = LoopbackHTTPParser(maximumBodyBytes: 4)
        XCTAssertThrowsError(try declared.append(Data("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n".utf8))) {
            XCTAssertEqual(($0 as? LoopbackHTTPParser.Failure)?.status, 413)
        }
        var overflowing = LoopbackHTTPParser(maximumBodyBytes: 4)
        XCTAssertThrowsError(try overflowing.append(Data("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999999999999999999999999\r\n\r\n".utf8))) {
            XCTAssertEqual(($0 as? LoopbackHTTPParser.Failure)?.status, 413)
        }
        var headers = LoopbackHTTPParser(maximumBodyBytes: 100)
        XCTAssertThrowsError(try headers.append(Data(repeating: 65, count: LoopbackHTTPParser.maximumHeaderBytes + 1))) {
            XCTAssertEqual(($0 as? LoopbackHTTPParser.Failure)?.status, 431)
        }
        var pipeline = LoopbackHTTPParser(maximumBodyBytes: 100)
        XCTAssertThrowsError(try pipeline.append(Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\nGET /other HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))) {
            XCTAssertEqual(($0 as? LoopbackHTTPParser.Failure)?.status, 400)
        }
    }

    @MainActor
    func testLiveRequestReturnsExactBodyAndStopsListening() async throws {
        let binary = Data([0, 255, 13, 10, 42])
        let server = LoopbackHTTPServer { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.target, "/mcp")
            XCTAssertEqual(request.body, binary)
            return LoopbackHTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], body: request.body)
        }
        let port = try await server.start()
        defer { server.stop() }
        XCTAssertEqual(server.port, port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = binary
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, binary)
        server.stop()
        XCTAssertNil(server.port)
        do {
            _ = try await session.data(for: request)
            XCTFail("Stopping the server must close its listener.")
        } catch {}
    }

    @MainActor
    func testExplicitPortRejectsAnotherListenerAndCanRestartAfterARequest() async throws {
        let probe = LoopbackHTTPServer { _ in LoopbackHTTPResponse(status: 200) }
        let chosenPort = try await probe.start()
        probe.stop()
        try await Task.sleep(for: .milliseconds(20))
        let server = LoopbackHTTPServer { _ in LoopbackHTTPResponse(status: 200, body: Data("bound".utf8)) }
        let boundPort = try await server.start(port: chosenPort)
        defer { server.stop() }
        XCTAssertEqual(boundPort, chosenPort)
        let conflict = LoopbackHTTPServer { _ in LoopbackHTTPResponse(status: 200) }
        defer { conflict.stop() }
        do {
            _ = try await conflict.start(port: chosenPort)
            XCTFail("Another listener must not share LAD's configured port.")
        } catch { XCTAssertNil(conflict.port) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(chosenPort)/")!
        let (first, _) = try await session.data(from: url)
        XCTAssertEqual(first, Data("bound".utf8))
        server.stop()
        try await Task.sleep(for: .milliseconds(20))
        let restarted = try await server.start(port: chosenPort)
        XCTAssertEqual(restarted, chosenPort)
        let (second, _) = try await session.data(from: url)
        XCTAssertEqual(second, first)
    }

    @MainActor
    func testAdmissionRejectsBeforeTheUploadArrives() async throws {
        var admittedBodyBytes: Int?
        var handled = false
        let server = LoopbackHTTPServer(admit: { head in
            admittedBodyBytes = head.body.count
            return LoopbackHTTPResponse(status: 401)
        }, handler: { _ in
            handled = true
            return LoopbackHTTPResponse(status: 200)
        })
        let port = try await server.start()
        defer { server.stop() }
        let client = RawClient(port: port)
        let response = try await client.exchange(Data("POST /upload HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 10000\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 401 "))
        XCTAssertEqual(admittedBodyBytes, 0)
        XCTAssertFalse(handled)
    }

    @MainActor
    func testDisconnectCancelsOnlyItsRunningHandler() async throws {
        let started = expectation(description: "Handler started")
        let cancelled = expectation(description: "Handler cancelled")
        let server = LoopbackHTTPServer { request in
            if request.target == "/slow" {
                started.fulfill()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled.fulfill() }
            }
            return LoopbackHTTPResponse(status: 200, body: Data("ready".utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let slow = session.dataTask(with: URL(string: "http://127.0.0.1:\(port)/slow")!)
        slow.resume()
        await fulfillment(of: [started], timeout: 5)
        slow.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/ready")!)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ready")
    }

    @MainActor
    func testInvalidResponseHeadersCannotInjectAnotherResponse() async throws {
        let server = LoopbackHTTPServer { _ in
            LoopbackHTTPResponse(status: 200, headers: ["X-Test": "value\r\nInjected: yes"])
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = RawClient(port: port)
        let response = try await client.exchange(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 500 "))
        XCTAssertFalse(text.contains("Injected:"))
    }

    @MainActor
    private final class RawClient {
        private let connection: NWConnection
        private var completion: CheckedContinuation<Data, Error>?
        private var timeout: Task<Void, Never>?
        private var response = Data()

        init(port: UInt16) {
            connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }

        func exchange(_ request: Data) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.send(content: request, completion: .contentProcessed { [weak self] error in
                                if let error { Task { @MainActor in self?.finish(.failure(error)) } }
                            })
                            self.receive()
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data { self.response.append(data) }
                    if let error { self.finish(.failure(error)) }
                    else if complete { self.finish(.success(self.response)) }
                    else { self.receive() }
                }
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard let continuation = completion else { return }
            completion = nil
            timeout?.cancel(); timeout = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
