import Foundation
import Network

struct LoopbackHTTPRequest {
    let method: String
    let target: String
    /// Header names are lowercase. Repeated headers are rejected at the boundary.
    let headers: [String: String]
    let body: Data
}

struct LoopbackHTTPResponse {
    let status: Int
    var headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    fileprivate func encoded(omitBody: Bool = false) -> Data {
        let valid = (200...599).contains(status) && headers.allSatisfy { name, value in
            LoopbackHTTPParser.isToken(name) && value.utf8.allSatisfy { $0 == 9 || (32...126).contains($0) }
        }
        guard valid else {
            return Self(status: 500, body: Data("The local server returned an invalid response.".utf8)).encoded()
        }
        let payload = status == 204 ? Data() : body
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nConnection: close\r\nContent-Length: \(payload.count)\r\n"
        var suppliedContentType = false
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let lower = name.lowercased()
            guard !["connection", "content-length", "transfer-encoding"].contains(lower) else { continue }
            if lower == "content-type" { suppliedContentType = true }
            head += "\(name): \(value)\r\n"
        }
        if !suppliedContentType { head += "Content-Type: application/octet-stream\r\n" }
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        var result = Data(head.utf8)
        if !omitBody { result.append(payload) }
        return result
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 417: return "Expectation Failed"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }
}

/// A deliberately small HTTP/1.1 boundary: one length-delimited request per
/// connection, no proxies, transfer codings, pipelining, or HTTP upgrades.
struct LoopbackHTTPParser {
    struct Failure: Error {
        let status: Int
    }

    static let maximumHeaderBytes = 16 * 1024
    private let maximumBodyBytes: Int
    private var receivedBytes = 0
    /// Bytes up to the end of the header block; released once it is parsed.
    private var headBytes = Data()
    /// The body has its own buffer, which the completed request shares rather
    /// than copying, so an upload is held in memory once.
    private var body = Data()
    private var reservedBody = false
    private var contentLength = 0
    private(set) var head: LoopbackHTTPRequest?

    init(maximumBodyBytes: Int) {
        self.maximumBodyBytes = max(0, maximumBodyBytes)
    }

    mutating func append(_ data: Data) throws {
        let maximumBytes = maximumBodyBytes.addingReportingOverflow(Self.maximumHeaderBytes)
        guard !maximumBytes.overflow, receivedBytes <= maximumBytes.partialValue,
              data.count <= maximumBytes.partialValue - receivedBytes else { throw Failure(status: 413) }
        receivedBytes += data.count
        guard head == nil else {
            guard data.count <= contentLength - body.count else { throw Failure(status: 400) }
            // Later reads follow admission. Size the buffer once from the
            // declared length instead of regrowing it while it fills.
            if !reservedBody { body.reserveCapacity(contentLength); reservedBody = true }
            body.append(data)
            return
        }
        headBytes.append(data)
        guard let separator = headBytes.range(of: Data([13, 10, 13, 10])) else {
            if headBytes.count > Self.maximumHeaderBytes { throw Failure(status: 431) }
            return
        }
        guard separator.upperBound <= Self.maximumHeaderBytes else { throw Failure(status: 431) }
        let parsed = try Self.parseHead(headBytes[..<separator.lowerBound])
        if let length = parsed.headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure(status: 400) }
            guard let value = Int(length), value <= maximumBodyBytes else { throw Failure(status: 413) }
            contentLength = value
        }
        let remainder = headBytes[separator.upperBound...]
        guard remainder.count <= contentLength else { throw Failure(status: 400) }
        body = Data(remainder)
        headBytes = Data()
        head = parsed
    }

    var request: LoopbackHTTPRequest? {
        guard let head, body.count == contentLength else { return nil }
        return LoopbackHTTPRequest(method: head.method, target: head.target, headers: head.headers, body: body)
    }

    private static func parseHead(_ bytes: Data.SubSequence) throws -> LoopbackHTTPRequest {
        guard bytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: Data(bytes), encoding: .ascii) else { throw Failure(status: 400) }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw Failure(status: 400) }
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, isToken(String(words[0])), words[2] == "HTTP/1.1",
              words[1].hasPrefix("/"), !words[1].contains("#"),
              words[1].utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure(status: 400) }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isToken(name), value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  headers[name.lowercased()] == nil else { throw Failure(status: 400) }
            headers[name.lowercased()] = value
        }
        guard let host = headers["host"], !host.isEmpty,
              headers["transfer-encoding"] == nil, headers["upgrade"] == nil else { throw Failure(status: 400) }
        guard headers["expect"] == nil else { throw Failure(status: 417) }
        return LoopbackHTTPRequest(method: String(words[0]), target: String(words[1]), headers: headers, body: Data())
    }

    fileprivate static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains($0)
        }
    }
}

/// A loopback-only listener owned by the app. Authorization can run immediately
/// after headers arrive, before an upload is accumulated in memory.
@MainActor
final class LoopbackHTTPServer {
    typealias Admission = @MainActor (LoopbackHTTPRequest) -> LoopbackHTTPResponse?
    typealias Handler = @MainActor (LoopbackHTTPRequest) async -> LoopbackHTTPResponse

    private let maximumBodyBytes: Int
    private let admit: Admission?
    private let handler: Handler
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: Connection] = [:]
    private(set) var port: UInt16?
    private let maximumConnections = 16

    init(maximumBodyBytes: Int = 64 * 1024 * 1024, admit: Admission? = nil, handler: @escaping Handler) {
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.admit = admit
        self.handler = handler
    }

    deinit { listener?.cancel() }

    func start(port requestedPort: UInt16 = 0) async throws -> UInt16 {
        guard listener == nil else {
            throw NSError(domain: "LAD.LoopbackHTTP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The external agent server is already running."])
        }
        let parameters = NWParameters.tcp
        let requested = NWEndpoint.Port(rawValue: requestedPort)!
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requested)
        parameters.allowLocalEndpointReuse = false
        // requiredLocalEndpoint supplies both the loopback address and port.
        // Passing a second nonzero port to NWListener conflicts with that bind.
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { self.stop(); return }
                    self.port = port
                    self.startup?.resume(returning: port)
                    self.startup = nil
                case .failed(let error):
                    self.startup?.resume(throwing: error)
                    self.startup = nil
                    self.stop()
                case .waiting(let error):
                    // A local port conflict must fail startup promptly rather
                    // than wait forever for an unrelated listener to exit.
                    guard self.startup != nil else { return }
                    self.startup?.resume(throwing: error)
                    self.startup = nil
                    self.stop()
                case .cancelled: self.stop()
                default: break
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { self.stop(); continuation.resume(throwing: CancellationError()); return }
                startup = continuation
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        let old = listener
        listener = nil
        port = nil
        startup?.resume(throwing: CancellationError())
        startup = nil
        old?.cancel()
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < maximumConnections else {
            connection.start(queue: .main)
            connection.send(content: LoopbackHTTPResponse(status: 429).encoded(), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let session = Connection(connection, owner: self, maximumBodyBytes: maximumBodyBytes)
        connections[session.id] = session
        session.start()
    }

    @MainActor
    private final class Connection {
        let id = UUID()
        private weak var owner: LoopbackHTTPServer?
        private let connection: NWConnection
        private var parser: LoopbackHTTPParser
        private var admitted = false
        private var closed = false
        private var task: Task<Void, Never>?
        private var readDeadline: Task<Void, Never>?

        init(_ connection: NWConnection, owner: LoopbackHTTPServer, maximumBodyBytes: Int) {
            self.connection = connection
            self.owner = owner
            parser = LoopbackHTTPParser(maximumBodyBytes: maximumBodyBytes)
        }

        deinit { connection.cancel(); task?.cancel(); readDeadline?.cancel() }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .failed, .cancelled: self?.close()
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
            readDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.respond(LoopbackHTTPResponse(status: 408))
            }
            receive()
        }

        func close() {
            guard !closed else { return }
            closed = true
            task?.cancel(); task = nil
            readDeadline?.cancel(); readDeadline = nil
            connection.cancel()
            owner?.connections.removeValue(forKey: id)
        }

        private func receive() {
            guard !closed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: admitted ? 65_536 : 16_384) { [weak self] data, _, complete, error in
                Task { @MainActor in self?.received(data, complete: complete, error: error) }
            }
        }

        private func received(_ data: Data?, complete: Bool, error: NWError?) {
            guard !closed, let owner else { close(); return }
            do {
                if let data { try parser.append(data) }
                if !admitted, let head = parser.head {
                    if let rejection = owner.admit?(head) { respond(rejection); return }
                    admitted = true
                }
                if let request = parser.request {
                    readDeadline?.cancel(); readDeadline = nil
                    guard error == nil, !complete else { close(); return }
                    task = Task { [weak self] in
                        let response = await owner.handler(request)
                        guard !Task.isCancelled else { return }
                        self?.respond(response, omitBody: request.method == "HEAD")
                    }
                    // Once the request is complete, any further data is an
                    // unsupported pipelined request. EOF cancels ongoing work.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                        Task { @MainActor in self?.close() }
                    }
                } else if complete || error != nil { close() }
                else { receive() }
            } catch let failure as LoopbackHTTPParser.Failure {
                respond(LoopbackHTTPResponse(status: failure.status))
            } catch { respond(LoopbackHTTPResponse(status: 400)) }
        }

        private func respond(_ response: LoopbackHTTPResponse, omitBody: Bool = false) {
            guard !closed else { return }
            readDeadline?.cancel()
            // CAD execution has no elapsed-time limit. Once it finishes, a
            // client that stops reading must not retain a connection forever.
            readDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.close()
            }
            connection.send(content: response.encoded(omitBody: omitBody), completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.close() }
            })
        }
    }
}
