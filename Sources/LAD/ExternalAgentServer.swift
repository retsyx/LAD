import AppKit
import Foundation
import UniformTypeIdentifiers

/// An app-owned, opt-in loopback endpoint. Transport connections never own a
/// document; every CAD call names an authorized application task explicitly.
@MainActor
final class ExternalAgentServer: ObservableObject {
    static let shared = ExternalAgentServer()
    static let enabledKey = "externalAgentServerEnabled"
    static let portKey = "externalAgentServerPort"
    static let defaultPort: UInt16 = 47512
    static let protocolVersions = ["2026-07-28", "2025-11-25", "2025-06-18"]
    static let instructions = "LAD is a native CAD service. List authorized designs with lad_projects, or explicitly create/open a design. Start a task against a projectID with lad_task_begin and a concise request. Upload complete CadQuery/OCP Python programs and original reference inputs to that task's uploadURL using authenticated binary HTTP uploads; keep source contents out of prompts. Programs assign their final geometry to result. All file arguments are opaque task file IDs. Use lad_runtime, lad_build, lad_inspect/lad_measure, lad_validate and lad_render to iterate. Builds and color edits are speculative. Publish only a reviewed, validated candidate with lad_commit, passing the task's expectedStateToken and a unique idempotencyKey. A conflict requires a fresh task and review against current state. Read saved versions through lad_versions/lad_version without changing the live design. Generated geometry must stay in the complete replayable program; lad_import is only for original external references or faithful conversions of user-provided inputs, never generated CAD exports. Optional downloads/installations require a fresh allowed lad_request_permission decision, remain user-managed and task-local, and cannot change LAD's bundled runtime. LAD does not execute shell commands for external clients. lad_render is independent of the viewport; lad_screenshot captures the explicitly bound design window. End tasks to release temporary files. Only committed programs, required original inputs and public activity records persist; generated images and STEP exports are temporary."

    @Published private(set) var isRunning = false
    @Published private(set) var endpoint: String?
    @Published private(set) var error: String?
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey); restart() } }
    @Published var preferredPort: Int { didSet { defaults.set(preferredPort, forKey: Self.portKey); restart() } }
    let access: ExternalAgentAccess
    private let defaults: UserDefaults
    private weak var coordinator: ProjectWindowCoordinator?
    private var server: LoopbackHTTPServer?
    private var startTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var tasks: [UUID: AgentTask] = [:]
    private var pendingTasks = Set<UUID>()
    private var pendingPreparations: [UUID: (state: AppState, editingID: UUID, task: Task<String, Error>)] = [:]
    private var runningCalls = 0
    private var epoch = UUID()
    private enum MCPRequestID: Hashable {
        case string(String)
        case number(NSNumber)

        @MainActor init?(_ value: Any) {
            guard ExternalAgentServer.validRequestID(value) else { return nil }
            if let string = value as? String { self = .string(string) }
            else if let number = value as? NSNumber { self = .number(number) }
            else { return nil }
        }
    }
    private struct MCPRequestKey: Hashable {
        let clientID: UUID
        let id: MCPRequestID
    }
    private struct MCPRequestOperation {
        let generation: UUID
        let method: String
        let task: Task<LoopbackHTTPResponse, Never>
    }
    private var mcpRequests: [MCPRequestKey: MCPRequestOperation] = [:]

    private final class AgentTask {
        let session: ProjectAgentSession
        let snapshot: ProjectAgentSnapshot
        let clientID: UUID
        weak var state: AppState?
        weak var ownerWindow: NSWindow?
        var windowObserver: NSObjectProtocol?
        var lastUsed = Date()
        init(session: ProjectAgentSession, snapshot: ProjectAgentSnapshot, clientID: UUID, state: AppState) {
            self.session = session; self.snapshot = snapshot; self.clientID = clientID; self.state = state
        }
        deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    }

    init(defaults: UserDefaults = .standard, coordinator: ProjectWindowCoordinator? = nil) {
        self.defaults = defaults
        self.coordinator = coordinator
        enabled = defaults.bool(forKey: Self.enabledKey)
        preferredPort = defaults.object(forKey: Self.portKey) == nil ? Int(Self.defaultPort) : defaults.integer(forKey: Self.portKey)
        access = ExternalAgentAccess(defaults: defaults)
        access.onChange = { [weak self] in
            self?.cancelRevokedMCPRequests()
            self?.cancelUnauthorizedTasks()
        }
    }

    func configure(coordinator: ProjectWindowCoordinator) { self.coordinator = coordinator; restart() }

    func restart() {
        stop()
        guard enabled, coordinator != nil else { return }
        guard (1024...65535).contains(preferredPort), let port = UInt16(exactly: preferredPort) else {
            error = "Choose a local server port between 1024 and 65535."
            return
        }
        let generation = epoch
        startTask = Task { [weak self] in
            guard let self else { return }
            let listener = LoopbackHTTPServer(admit: { [weak self] request in
                guard let self else { return Self.httpError(503, "The LAD server is unavailable.") }
                return self.admit(request)
            }, handler: { [weak self] request in
                guard let self else { return Self.httpError(503, "The LAD server is unavailable.") }
                return await self.handle(request)
            })
            self.server = listener
            do {
                let boundPort = try await listener.start(port: port)
                guard !Task.isCancelled, self.epoch == generation else { listener.stop(); return }
                self.endpoint = "http://127.0.0.1:\(boundPort)/mcp"
                self.isRunning = true
                self.error = nil
                self.expiryTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        self?.expireTasks()
                    }
                }
            } catch {
                guard self.epoch == generation, !Task.isCancelled else { return }
                self.error = "Unable to start the local MCP server: \(error.localizedDescription)"
                self.isRunning = false; self.endpoint = nil; self.server = nil
            }
        }
    }

    func stop() {
        epoch = UUID()
        for request in mcpRequests.values { request.task.cancel() }
        mcpRequests.removeAll()
        startTask?.cancel(); startTask = nil
        expiryTask?.cancel(); expiryTask = nil
        server?.stop(); server = nil
        for id in Array(tasks.keys) { endTask(id, status: "canceled") }
        let preparing = pendingPreparations
        pendingPreparations.removeAll(); pendingTasks.removeAll()
        for (id, pending) in preparing {
            pending.task.cancel()
            if pending.state.projectEditingID == pending.editingID { pending.state.finishExternalAgentAudit(id: id, status: "canceled") }
        }
        isRunning = false; endpoint = nil
    }

    var projects: [AppState] { coordinator?.agentProjects ?? [] }

    func configuration(token: String) throws -> String {
        guard let endpoint else { throw LADError.message("Enable the local MCP server before copying its configuration.") }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["mcpServers": ["lad": ["url": endpoint,
            "headers": ["Authorization": "Bearer \(token)"]]]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Used both before upload body accumulation and again before dispatch.
    func admit(_ request: LoopbackHTTPRequest) -> LoopbackHTTPResponse? {
        guard let port = server?.port, request.headers["host"] == "127.0.0.1:\(port)" else {
            return Self.httpError(403, "The request must address LAD's loopback endpoint directly.")
        }
        if let origin = request.headers["origin"], origin != "http://127.0.0.1:\(port)" {
            return Self.httpError(403, "This browser origin is not allowed.")
        }
        guard let client = access.authenticate(request.headers["authorization"]) else {
            var response = Self.httpError(401, "A valid LAD client credential is required.")
            response.headers["WWW-Authenticate"] = "Bearer realm=\"LAD\""
            return response
        }
        guard let components = URLComponents(string: "http://127.0.0.1" + request.target),
              components.host == "127.0.0.1", components.fragment == nil else { return Self.httpError(400, "Invalid request target.") }
        if components.path == "/mcp", request.target != "/mcp" {
            return Self.httpError(404, "Use the canonical /mcp endpoint.")
        }
        if request.target == "/mcp", let size = request.headers["content-length"].flatMap(Int.init), size > 4 * 1024 * 1024 {
            return Self.httpError(413, "The MCP request is too large; upload source files separately.")
        }
        let segments = components.path.split(separator: "/").map(String.init)
        if segments.count >= 3, segments[0] == "tasks", let taskID = UUID(uuidString: segments[1]), segments[2] == "files" {
            do {
                let task = try authorizedTask(taskID, client: client)
                if request.method == "POST" {
                    try require(client, .build, projectID: task.snapshot.projectID)
                    try requireRunning(task)
                }
            } catch { return Self.httpError(Self.status(error), error.localizedDescription) }
        }
        return nil
    }

    func handle(_ request: LoopbackHTTPRequest) async -> LoopbackHTTPResponse {
        if let rejected = admit(request) { return rejected }
        guard let client = access.authenticate(request.headers["authorization"]) else { return Self.httpError(401, "Client access was revoked.") }
        guard let components = URLComponents(string: "http://127.0.0.1" + request.target),
              components.host == "127.0.0.1", components.fragment == nil else { return Self.httpError(400, "Invalid request target.") }
        if components.path == "/mcp", components.query == nil {
            return await handleMCP(request, client: client)
        }
        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count >= 3, segments[0] == "tasks", let id = UUID(uuidString: segments[1]), segments[2] == "files" else {
            return Self.httpError(404, "The requested endpoint is unavailable.")
        }
        do {
            let task = try authorizedTask(id, client: client)
            if request.method == "POST", segments.count == 3 {
                try require(client, .build, projectID: task.snapshot.projectID)
                try requireRunning(task)
                guard request.headers["content-type"]?.lowercased() == "application/octet-stream" else {
                    return Self.httpError(415, "Upload files with Content-Type: application/octet-stream.")
                }
                let query = components.queryItems ?? []
                guard query.count == 1, query.first?.name == "name", let name = query.first?.value else {
                    return Self.httpError(400, "Provide one upload filename in the name query parameter.")
                }
                var descriptor = try await task.session.uploadFile(data: request.body, name: name)
                descriptor["downloadURL"] = downloadURL(taskID: id, fileID: descriptor["fileID"] as? String ?? "")
                return Self.json(201, descriptor)
            }
            if request.method == "GET", segments.count == 4, components.query == nil {
                let result = try await task.session.downloadFile(fileID: segments[3])
                let name = String(result.name.unicodeScalars.map { scalar in
                    scalar.isASCII && scalar.value >= 32 && scalar != "\"" && scalar != "\\" ? Character(String(scalar)) : "_"
                })
                return LoopbackHTTPResponse(status: 200, headers: ["Content-Type": Self.mimeType(result.name),
                    "Content-Disposition": "attachment; filename=\"\(name)\""], body: result.data)
            }
            return Self.httpError(405, "This file endpoint does not support that operation.")
        } catch { return Self.httpError(Self.status(error), error.localizedDescription) }
    }

    func handleMCP(_ request: LoopbackHTTPRequest, client: ExternalAgentClient) async -> LoopbackHTTPResponse {
        guard request.method == "POST" else {
            var response = Self.httpError(405, "Send MCP requests with HTTP POST.")
            response.headers["Allow"] = "POST"
            return response
        }
        guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            return Self.httpError(415, "MCP requests require application/json.")
        }
        let accepted = request.headers["accept"]?.lowercased().split(separator: ",").map {
            $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        } ?? []
        guard accepted.contains("*/*") || (accepted.contains("application/json") && accepted.contains("text/event-stream")) else {
            return Self.httpError(406, "MCP clients must accept application/json and text/event-stream.")
        }
        let headerVersion = request.headers["mcp-protocol-version"]
        let legacyError = headerVersion != nil && headerVersion != "2026-07-28"
        guard let decoded = try? JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed]) else {
            return Self.rpcError(nil, code: -32700, message: "Invalid JSON.", status: 400, legacy: legacyError)
        }
        guard let message = decoded as? [String: Any] else {
            return Self.rpcError(nil, code: -32600, message: "Send one JSON-RPC request object.", status: 400, legacy: legacyError)
        }
        let id = message["id"]
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String,
              id == nil || Self.validRequestID(id!), message["params"] == nil || message["params"] is [String: Any] else {
            return Self.rpcError(nil, code: -32600, message: "Invalid JSON-RPC request.", status: 400, legacy: legacyError)
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let initializing = method == "initialize"
        let initializeVersion = initializing ? params["protocolVersion"] as? String : nil
        if initializing, initializeVersion == nil {
            return Self.rpcError(id, code: -32602, message: "Initialization requires protocolVersion.", legacy: legacyError)
        }
        guard let version = headerVersion ?? initializeVersion else {
            return Self.rpcError(id, code: -32020, message: "The MCP-Protocol-Version header is required.", status: 400)
        }
        if let initializeVersion, let headerVersion, initializeVersion != headerVersion {
            return Self.rpcError(id, code: -32020, message: "The initialization version must match MCP-Protocol-Version.", status: 400,
                                 legacy: headerVersion != "2026-07-28")
        }
        guard Self.protocolVersions.contains(version) else {
            return Self.rpcError(id, code: -32022, message: "Unsupported protocol version.", status: 400,
                                 data: ["supported": Self.protocolVersions, "requested": version], legacy: legacyError)
        }
        if let metadataVersion = (params["_meta"] as? [String: Any])?["io.modelcontextprotocol/protocolVersion"] as? String,
           metadataVersion != version {
            return Self.rpcError(id, code: -32020, message: "The request metadata version must match MCP-Protocol-Version.", status: 400,
                                 legacy: version != "2026-07-28")
        }
        let modern = version == "2026-07-28"
        if modern {
            let meta = params["_meta"] as? [String: Any] ?? [:]
            let requiresName = ["tools/call", "prompts/get", "resources/read"].contains(method)
            let name = method == "resources/read" ? params["uri"] as? String : params["name"] as? String
            guard request.headers["mcp-protocol-version"] == version,
                  meta["io.modelcontextprotocol/protocolVersion"] as? String == version,
                  request.headers["mcp-method"] == method,
                  !requiresName || (name != nil && Self.decodedMCPHeader(request.headers["mcp-name"]) == name) else {
                return Self.rpcError(id, code: -32020, message: "Required MCP headers and request metadata must match.", status: 400)
            }
            guard meta["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
                return Self.rpcError(id, code: -32602, message: "Each request must declare its clientCapabilities.", status: 400)
            }
        }
        if id == nil {
            if method == "notifications/initialized", !modern { return LoopbackHTTPResponse(status: 202) }
            if method == "notifications/cancelled", !modern {
                guard let cancelID = params["requestId"], let identity = MCPRequestID(cancelID),
                      params["reason"] == nil || params["reason"] is String else {
                    return Self.httpError(400, "Cancellation requires a valid requestId and optional reason.")
                }
                let key = MCPRequestKey(clientID: client.id, id: identity)
                if let pending = mcpRequests[key], pending.method != "initialize" { pending.task.cancel() }
                return LoopbackHTTPResponse(status: 202)
            }
            return Self.httpError(400, "This MCP method requires a request ID.")
        }
        return await runMCPRequest(clientID: client.id, id: id!, method: method) { [weak self] in
            guard let self else { return Self.httpError(503, "The LAD server is unavailable.") }
            return await self.performMCP(method: method, params: params, id: id!, modern: modern, version: version, client: client)
        }
    }

    /// Request identity belongs to an authenticated client, independently of
    /// application task IDs and of the short-lived HTTP connection.
    func runMCPRequest(clientID: UUID, id: Any, method: String,
                       operation: @escaping @MainActor () async -> LoopbackHTTPResponse) async -> LoopbackHTTPResponse {
        guard let identity = MCPRequestID(id) else {
            return Self.rpcError(nil, code: -32600, message: "Provide a string or integer request ID.", status: 400)
        }
        let key = MCPRequestKey(clientID: clientID, id: identity)
        guard mcpRequests[key] == nil else {
            return Self.rpcError(id, code: -32600, message: "This client already has an unfinished request with that ID.", status: 400)
        }
        guard mcpRequests.count < 32 else { return Self.httpError(429, "Too many MCP requests are running.") }
        let generation = UUID()
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return LoopbackHTTPResponse(status: 204) }
            return await operation()
        }
        mcpRequests[key] = MCPRequestOperation(generation: generation, method: method, task: task)
        defer { if mcpRequests[key]?.generation == generation { mcpRequests.removeValue(forKey: key) } }
        return await withTaskCancellationHandler {
            let response = await task.value
            // No JSON-RPC result is delivered after a cancellation. For a
            // disconnected HTTP client the transport also suppresses this reply.
            return task.isCancelled ? LoopbackHTTPResponse(status: 204) : response
        } onCancel: { task.cancel() }
    }

    private func cancelRevokedMCPRequests() {
        for (key, request) in mcpRequests where access.current(key.clientID) == nil { request.task.cancel() }
    }

    private func performMCP(method: String, params: [String: Any], id: Any, modern: Bool, version: String,
                            client: ExternalAgentClient) async -> LoopbackHTTPResponse {
        do {
            var result: [String: Any]
            switch method {
            case "initialize":
                guard !modern else { return Self.rpcError(id, code: -32601, message: "Use server/discover for this protocol version.", status: 404) }
                result = ["protocolVersion": version, "serverInfo": Self.serverInfo, "capabilities": Self.capabilities, "instructions": Self.instructions]
            case "server/discover":
                guard modern else { return Self.rpcError(id, code: -32601, message: "Method not found.", legacy: true) }
                result = ["supportedVersions": Self.protocolVersions, "capabilities": Self.capabilities,
                          "instructions": Self.instructions, "ttlMs": 0, "cacheScope": "private",
                          "_meta": ["io.modelcontextprotocol/serverInfo": Self.serverInfo]]
            case "ping": result = [:]
            case "tools/list":
                guard params["cursor"] == nil else { return Self.rpcError(id, code: -32602, message: "This tool list has no continuation cursor.", legacy: !modern) }
                result = ["tools": try (Self.controlTools + AgentToolCatalog.externalTools()).filter {
                    guard let name = $0["name"] as? String else { return false }
                    return client.capabilities.contains(Self.capability(for: name))
                }]
                if modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
            case "tools/call":
                guard let name = params["name"] as? String,
                      params["arguments"] == nil || params["arguments"] is [String: Any] else {
                    return Self.rpcError(id, code: -32602, message: "Provide a tool name and argument object.", legacy: !modern)
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                guard let tool = try (Self.controlTools + AgentToolCatalog.externalTools()).first(where: { $0["name"] as? String == name }) else {
                    return Self.rpcError(id, code: -32602, message: "Unknown LAD tool.", legacy: !modern)
                }
                if let schema = tool["inputSchema"] as? [String: Any], !Self.validToolArguments(arguments, schema: schema) {
                    return Self.rpcError(id, code: -32602, message: "The tool arguments do not match its input schema.", legacy: !modern)
                }
                do { result = try await call(name: name, arguments: arguments, client: client) }
                catch {
                    result = Self.toolResult(["error": error.localizedDescription, "code": Self.errorCode(error)], isError: true)
                }
            default: return Self.rpcError(id, code: -32601, message: "Method not found.", status: modern ? 404 : 200, legacy: !modern)
            }
            if modern {
                result["resultType"] = "complete"
                result["_meta"] = ["io.modelcontextprotocol/serverInfo": Self.serverInfo]
            }
            return Self.json(200, ["jsonrpc": "2.0", "id": id, "result": result])
        } catch { return Self.rpcError(id, code: -32603, message: error.localizedDescription, legacy: !modern) }
    }

    func call(name: String, arguments: [String: Any], client: ExternalAgentClient) async throws -> [String: Any] {
        guard let current = access.current(client.id) else { throw ProjectAgentError.denied }
        try require(current, Self.capability(for: name))
        switch name {
        case "lad_projects":
            try only(arguments, [])
            return Self.toolResult(["projects": projects.filter { allowed(current, projectID: $0.projectDocumentID) }.map(projectInfo)])
        case "lad_project_create":
            try only(arguments, [])
            guard current.projectIDs == nil, let coordinator else { throw ProjectAgentError.denied }
            return Self.toolResult(projectInfo(try coordinator.createAgentProject()))
        case "lad_project_open":
            try only(arguments, [])
            guard current.projectIDs == nil, let coordinator else { throw ProjectAgentError.denied }
            let panel = NSOpenPanel()
            panel.title = "Open Design for \(current.name)"
            panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .package]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            let accepted = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0 == .OK) } }
            } onCancel: { Task { @MainActor in panel.cancel(nil) } }
            try Task.checkCancellation()
            guard access.current(current.id) != nil else { throw ProjectAgentError.denied }
            guard accepted, let url = panel.url else { return Self.toolResult(["status": "canceled"]) }
            try coordinator.openAgentProject(at: url)
            return Self.toolResult(["status": "opening", "name": url.deletingPathExtension().lastPathComponent,
                                    "next": "Use lad_projects to obtain the opened design's stable projectID."])
        case "lad_task_begin":
            try only(arguments, ["projectID", "request", "model", "reasoningEffort"])
            guard tasks.count + pendingTasks.count < 8 else { throw LADError.message("End an existing agent task before starting another; up to eight are supported.") }
            let projectID = try uuid("projectID", arguments)
            try require(current, .read, projectID: projectID)
            guard let state = projects.first(where: { $0.projectDocumentID == projectID }) else { throw ProjectAgentError.unavailable }
            let request = try text("request", arguments, maximum: 1_000_000)
            let model = try optionalText("model", arguments, maximum: 256)
            let effort = try optionalText("reasoningEffort", arguments, maximum: 256)
            let id = UUID(), snapshot = state.agentSnapshot(), generation = epoch
            pendingTasks.insert(id)
            defer { pendingTasks.remove(id); pendingPreparations.removeValue(forKey: id) }
            try state.beginExternalAgentAudit(id: id, client: ProjectExternalAgentIdentity(clientID: current.id.uuidString, name: current.name),
                                              request: request, model: model, effort: effort)
            state.onProjectAgentInvalidated = { [weak self, weak state] in
                guard let state else { return }; self?.cancelTasks(for: state)
            }
            do {
                let requestedPython = state.python
                let preparation = Task { try await CADRuntimeManager.resolvePython(requestedPython) }
                pendingPreparations[id] = (state, snapshot.editingID, preparation)
                let python = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
                try Task.checkCancellation()
                guard generation == epoch, let refreshed = access.current(current.id), allowed(refreshed, projectID: projectID),
                      state.projectEditingID == snapshot.editingID, projects.contains(where: { $0 === state }) else { throw ProjectAgentError.unavailable }
                let viewport = state.viewportView
                let ownerWindow = viewport?.window ?? coordinator?.agentWindow(for: state)
                let session = try ProjectAgentSession(id: id, python: python, threads: min(state.threads, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)),
                    current: snapshot.current, currentPreview: snapshot.preview, versions: snapshot.versions,
                    partLayout: snapshot.partLayout, partColors: snapshot.partColors, viewport: viewport,
                    permissionWindow: ownerWindow, hiddenSolids: snapshot.hiddenSolids, solidColors: snapshot.solidColors,
                    onActivity: { [weak state] event in MainActor.assumeIsolated { state?.recordTaskEvent(event, taskID: id) } })
                tasks[id] = AgentTask(session: session, snapshot: snapshot, clientID: current.id, state: state)
                if let window = ownerWindow {
                    tasks[id]?.ownerWindow = window
                    tasks[id]?.windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                        object: window, queue: .main) { [weak self] _ in
                            Task { @MainActor in self?.endTask(id, status: "canceled") }
                        }
                }
                state.onProjectAgentInvalidated = { [weak self, weak state] in
                    guard let state else { return }; self?.cancelTasks(for: state)
                }
                return Self.toolResult(taskInfo(tasks[id]!))
            } catch {
                state.finishExternalAgentAudit(id: id, status: error is CancellationError ? "canceled" : "failed")
                throw error
            }
        case "lad_task_status", "lad_task_cancel", "lad_task_end":
            try only(arguments, ["taskID"])
            let id = try uuid("taskID", arguments), task = try authorizedTask(id, client: current)
            if name == "lad_task_status" { return Self.toolResult(taskInfo(task)) }
            endTask(id, status: name == "lad_task_cancel" ? "canceled" : "completed")
            return Self.toolResult(["taskID": id.uuidString, "status": name == "lad_task_cancel" ? "canceled" : "ended"])
        case "lad_commit":
            try only(arguments, ["taskID", "artifactID", "expectedStateToken", "idempotencyKey"])
            let id = try uuid("taskID", arguments)
            let artifactID = try text("artifactID", arguments, maximum: 256)
            let key = try text("idempotencyKey", arguments, maximum: 128)
            let expected = try text("expectedStateToken", arguments, maximum: 256)
            let prior = projects.compactMap { state -> (AppState, ProjectTaskAudit)? in
                guard allowed(current, projectID: state.projectDocumentID),
                      let receipt = state.externalAgentReceipt(clientID: current.id.uuidString, key: key) else { return nil }
                return (state, receipt)
            }.first
            let state: AppState
            let revisionID: UUID
            if let (owner, receipt) = prior {
                guard receipt.id == id, receipt.commitArtifactID == artifactID, let saved = receipt.committedRevisionID else {
                    throw ProjectAgentError.conflict("This idempotency key already identifies another commit.")
                }
                try require(current, .commit, projectID: owner.projectDocumentID)
                state = owner
                revisionID = saved
            } else {
                let task = try authorizedTask(id, client: current)
                try require(current, .commit, projectID: task.snapshot.projectID)
                guard let owner = task.state else { throw ProjectAgentError.unavailable }
                state = owner
                let started = Date(), eventID = "commit:\(key)"
                state.recordTaskEvent(ProjectActivityEvent(id: eventID, date: started, category: "tool", title: name,
                    status: "running", input: CADAgentBridge.json(arguments)), taskID: id)
                do {
                    let candidate = try await task.session.candidate(artifactID: artifactID)
                    revisionID = try state.commitExternalAgent(candidate, taskID: id, artifactID: artifactID,
                        expectedStateToken: expected, key: key, snapshot: task.snapshot)
                    state.recordTaskEvent(ProjectActivityEvent(id: eventID, date: started, category: "tool", title: name,
                        status: "completed", input: CADAgentBridge.json(arguments),
                        output: CADAgentBridge.json(["revisionID": revisionID.uuidString, "committed": true]),
                        durationSeconds: Date().timeIntervalSince(started)), taskID: id)
                } catch {
                    state.recordTaskEvent(ProjectActivityEvent(id: eventID, date: started, category: "tool", title: name,
                        status: "failed", input: CADAgentBridge.json(arguments), output: error.localizedDescription,
                        durationSeconds: Date().timeIntervalSince(started)), taskID: id)
                    throw error
                }
            }
            do { try await state.flushExternalAgentCommit() } catch { /* Accepted revision and receipt remain retryable. */ }
            return Self.toolResult(["projectID": state.projectDocumentID.uuidString, "revisionID": revisionID.uuidString,
                "committed": true, "stateToken": state.agentStateToken, "persistence": state.agentPersistenceStatus])
        default:
            guard try AgentToolCatalog.nativeTools().contains(where: { $0["name"] as? String == name }) else {
                throw LADError.message("Unknown LAD tool.")
            }
            let id = try uuid("taskID", arguments), task = try authorizedTask(id, client: current)
            try require(current, Self.capability(for: name), projectID: task.snapshot.projectID)
            try requireRunning(task)
            if name == "lad_request_permission" {
                guard let state = task.state,
                      let window = task.ownerWindow ?? coordinator?.agentWindow(for: state) else {
                    throw ProjectAgentError.conflict("Wait for this design's window to open before requesting an agent permission.")
                }
                try task.session.bindPermissionWindow(window)
                if task.ownerWindow == nil {
                    task.ownerWindow = window
                    task.windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                        object: window, queue: .main) { [weak self] _ in
                            Task { @MainActor in self?.endTask(id, status: "canceled") }
                        }
                }
            }
            guard runningCalls < 2 else { throw LADError.message("LAD is running two external CAD operations. Retry when one finishes.") }
            runningCalls += 1
            defer { runningCalls -= 1 }
            var nativeArguments = arguments
            nativeArguments.removeValue(forKey: "taskID")
            return try await withTaskCancellationHandler {
                let result = try await task.session.call(name: name, arguments: nativeArguments)
                return addingDownloadURLs(result, taskID: id)
            } onCancel: { Task { @MainActor [weak self] in self?.endTask(id, status: "canceled") } }
        }
    }

    private func authorizedTask(_ id: UUID, client: ExternalAgentClient) throws -> AgentTask {
        guard let task = tasks[id], task.clientID == client.id else { throw ProjectAgentError.unavailable }
        try require(client, .read, projectID: task.snapshot.projectID)
        guard let state = task.state, state.projectEditingID == task.snapshot.editingID,
              projects.contains(where: { $0 === state }), !task.session.isCancelled else { throw ProjectAgentError.unavailable }
        task.lastUsed = Date()
        return task
    }

    private func requireRunning(_ task: AgentTask) throws {
        guard task.state?.taskAudits.first(where: { $0.id == task.session.id })?.status == "running" else {
            throw ProjectAgentError.conflict("This task is complete. Start a new task before uploading files or calling CAD tools.")
        }
    }

    private func allowed(_ client: ExternalAgentClient, projectID: UUID) -> Bool { client.projectIDs?.contains(projectID) ?? true }
    private func require(_ client: ExternalAgentClient, _ capability: ExternalAgentCapability, projectID: UUID? = nil) throws {
        guard client.capabilities.contains(capability), projectID.map({ allowed(client, projectID: $0) }) ?? true else { throw ProjectAgentError.denied }
    }
    private func cancelUnauthorizedTasks() {
        for (id, task) in tasks {
            if let client = access.current(task.clientID), allowed(client, projectID: task.snapshot.projectID) { continue }
            endTask(id, status: "canceled")
        }
        for (id, pending) in pendingPreparations {
            guard let audit = pending.state.taskAudits.first(where: { $0.id == id }),
                  let clientID = audit.externalClient?.clientID, let uuid = UUID(uuidString: clientID) else { continue }
            if let client = access.current(uuid), allowed(client, projectID: pending.state.projectDocumentID) { continue }
            pending.task.cancel()
            pending.state.finishExternalAgentAudit(id: id, status: "canceled")
        }
    }
    private func cancelTasks(for state: AppState) {
        for (id, task) in tasks where task.state === state { endTask(id, status: "canceled") }
        for (id, pending) in pendingPreparations where pending.state === state {
            pending.task.cancel()
            pending.state.finishExternalAgentAudit(id: id, status: "canceled")
        }
    }
    private func expireTasks() {
        for (id, task) in tasks where !task.session.isBusy && Date().timeIntervalSince(task.lastUsed) > 30 * 60 { endTask(id, status: "interrupted") }
    }
    private func endTask(_ id: UUID, status: String) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        task.session.cancel()
        if let state = task.state, state.projectEditingID == task.snapshot.editingID { state.finishExternalAgentAudit(id: id, status: status) }
    }
    private func projectInfo(_ state: AppState) -> [String: Any] {
        var info: [String: Any] = ["projectID": state.projectDocumentID.uuidString, "name": state.projectDisplayName,
            "stateToken": state.agentStateToken, "versionCount": state.revisions.count, "busy": state.isWorking,
            "persistence": state.agentPersistenceStatus]
        if let id = state.selectedRevisionID { info["selectedRevisionID"] = id.uuidString }
        return info
    }
    private func taskInfo(_ task: AgentTask) -> [String: Any] {
        var info: [String: Any] = ["taskID": task.session.id.uuidString, "projectID": task.snapshot.projectID.uuidString,
            "expectedStateToken": task.snapshot.stateToken, "busy": task.session.isBusy,
            "status": task.state?.taskAudits.first(where: { $0.id == task.session.id })?.status ?? "interrupted",
            "uploadURL": baseURL + "/tasks/\(task.session.id.uuidString)/files",
            "uploadLimitBytes": ProjectAgentSession.maximumUploadBytes]
        if let state = task.state { info["persistence"] = state.agentPersistenceStatus }
        return info
    }
    private var baseURL: String { endpoint.map { String($0.dropLast(4)) } ?? "" }
    private func downloadURL(taskID: UUID, fileID: String) -> String { baseURL + "/tasks/\(taskID.uuidString)/files/\(fileID)" }
    private func addingDownloadURLs(_ result: [String: Any], taskID: UUID) -> [String: Any] {
        var result = result
        if let files = result["files"] as? [[String: Any]] {
            let descriptors = files.map { item -> [String: Any] in
                var item = item
                if let id = item["fileID"] as? String { item["downloadURL"] = downloadURL(taskID: taskID, fileID: id) }
                return item
            }
            result["files"] = descriptors
            result["structuredContent"] = ["files": descriptors]
            if !descriptors.isEmpty {
                let fileContent = Self.toolResult(["files": descriptors])["content"] as? [[String: Any]] ?? []
                result["content"] = (result["content"] as? [[String: Any]] ?? []) + fileContent
            }
        }
        return result
    }

    static func capability(for name: String) -> ExternalAgentCapability {
        switch name {
        case "lad_project_create", "lad_project_open": return .manageProjects
        case "lad_commit": return .commit
        case "lad_screenshot": return .capture
        case "lad_export_step", "lad_mesh_export_step": return .export
        case "lad_build", "lad_import", "lad_request_permission", "lad_set_part_colors": return .build
        default: return name.hasPrefix("lad_mesh_") ? .build : .read
        }
    }
    private static let serverInfo: [String: Any] = ["name": "LAD", "version": "1.0.0"]
    private static let capabilities: [String: Any] = ["tools": ["listChanged": false]]
    private func only(_ args: [String: Any], _ keys: Set<String>) throws {
        guard Set(args.keys).isSubset(of: keys) else { throw LADError.message("The tool request contains unsupported arguments.") }
    }
    private func uuid(_ key: String, _ args: [String: Any]) throws -> UUID {
        guard let raw = args[key] as? String, let id = UUID(uuidString: raw) else { throw LADError.message("Provide a valid \(key).") }
        return id
    }
    private func text(_ key: String, _ args: [String: Any], maximum: Int) throws -> String {
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximum, !value.contains("\0"),
              maximum > 256 || value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LADError.message("Provide valid \(key) text of at most \(maximum) bytes.")
        }
        return value
    }
    private func optionalText(_ key: String, _ args: [String: Any], maximum: Int) throws -> String? {
        args[key] == nil ? nil : try text(key, args, maximum: maximum)
    }
    private static func validRequestID(_ value: Any) -> Bool {
        if let string = value as? String { return string.utf8.count <= 256 }
        if let number = value as? NSNumber {
            let value = number.doubleValue
            return CFGetTypeID(number) != CFBooleanGetTypeID() && value.isFinite && value.rounded(.towardZero) == value
        }
        return false
    }
    private static func decodedMCPHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let prefix = "=?base64?", suffix = "?="
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return value }
        guard value.count >= prefix.count + suffix.count,
              let bytes = Data(base64Encoded: String(value.dropFirst(prefix.count).dropLast(suffix.count))) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    /// Validate the JSON Schema vocabulary used by the shared tool catalog at
    /// the protocol boundary. Native tools retain their semantic validation.
    private static func validToolArguments(_ value: Any, schema: [String: Any]) -> Bool {
        if let alternatives = schema["anyOf"] as? [[String: Any]] {
            return alternatives.contains { validToolArguments(value, schema: $0) }
        }
        if let choices = schema["enum"] as? [Any], !NSArray(array: choices).contains(value) { return false }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { return false }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = schema["required"] as? [String] ?? []
            guard required.allSatisfy({ object[$0] != nil }) else { return false }
            if schema["additionalProperties"] as? Bool == false, !Set(object.keys).isSubset(of: Set(properties.keys)) { return false }
            return object.allSatisfy { key, value in
                properties[key].map { validToolArguments(value, schema: $0) } ?? true
            }
        case "array":
            guard let array = value as? [Any] else { return false }
            if let minimum = schema["minItems"] as? Int, array.count < minimum { return false }
            if let maximum = schema["maxItems"] as? Int, array.count > maximum { return false }
            guard let items = schema["items"] as? [String: Any] else { return true }
            return array.allSatisfy { validToolArguments($0, schema: items) }
        case "string":
            guard let string = value as? String else { return false }
            if let minimum = schema["minLength"] as? Int, string.unicodeScalars.count < minimum { return false }
            if let maximum = schema["maxLength"] as? Int, string.unicodeScalars.count > maximum { return false }
            return true
        case "integer", "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return false }
            let value = number.doubleValue
            if schema["type"] as? String == "integer", value.rounded(.towardZero) != value { return false }
            if let minimum = schema["minimum"] as? Double, value < minimum { return false }
            if let maximum = schema["maximum"] as? Double, value > maximum { return false }
            return true
        case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "null": return value is NSNull
        default: return true
        }
    }
    private static func status(_ error: Error) -> Int {
        switch error { case ProjectAgentError.denied: return 403; case ProjectAgentError.unavailable: return 404; case ProjectAgentError.conflict: return 409; default: return 400 }
    }
    private static func errorCode(_ error: Error) -> String {
        switch error { case ProjectAgentError.denied: return "denied"; case ProjectAgentError.unavailable: return "unavailable"; case ProjectAgentError.conflict: return "conflict"; case is CancellationError: return "canceled"; default: return "invalid_operation" }
    }
    static func toolResult(_ value: [String: Any], isError: Bool = false) -> [String: Any] {
        let bytes = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return ["content": [["type": "text", "text": String(decoding: bytes, as: UTF8.self)]], "isError": isError]
    }
    private static func json(_ status: Int, _ value: [String: Any]) -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8))
    }
    private static func httpError(_ status: Int, _ message: String) -> LoopbackHTTPResponse { json(status, ["error": message]) }
    private static func rpcError(_ id: Any?, code: Int, message: String, status: Int = 200, data: [String: Any]? = nil, legacy: Bool = false) -> LoopbackHTTPResponse {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var response: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id, validRequestID(id) { response["id"] = id }
        else if legacy { response["id"] = NSNull() }
        return json(status, response)
    }
    private static func mimeType(_ name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() { case "png": return "image/png"; case "json": return "application/json"; case "py", "md", "txt": return "text/plain; charset=utf-8"; default: return "application/octet-stream" }
    }

    private static var controlTools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], _ required: [String] = [], readOnly: Bool = false) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
        }
        let string: [String: Any] = ["type": "string"]
        let task = ["taskID": string]
        return [
            tool("lad_projects", "List authorized open designs and their stable projectIDs, current state tokens and persistence status.", readOnly: true),
            tool("lad_project_create", "Open a new independent empty design window. Connecting alone never creates a design or starts CAD."),
            tool("lad_project_open", "Ask the user to choose a LAD design in a native open dialog; list designs afterward to obtain its projectID."),
            tool("lad_task_begin", "Begin an isolated task against an explicitly chosen design snapshot. Provide a concise initiating request and actual model/effort when known. Returns taskID, expectedStateToken and authenticated binary uploadURL.", ["projectID": string, "request": string, "model": string, "reasoningEffort": string], ["projectID", "request"]),
            tool("lad_task_status", "Read a task's operation and save status.", task, ["taskID"], readOnly: true),
            tool("lad_task_cancel", "Cancel only this external task and release its temporary files; committed revisions remain saved.", task, ["taskID"]),
            tool("lad_task_end", "Finish an external task and release its temporary files; committed revisions remain saved.", task, ["taskID"]),
            tool("lad_commit", "Atomically publish an exact validated candidate as a new design version. Reject stale state; reuse idempotencyKey for a retry of the same task/artifact. Returns revision identity and separate disk persistence status. Failed saving leaves the accepted revision and receipt available to retry.", ["taskID": string, "artifactID": string, "expectedStateToken": string, "idempotencyKey": string], ["taskID", "artifactID", "expectedStateToken", "idempotencyKey"])
        ]
    }
}
