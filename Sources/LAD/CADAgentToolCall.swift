import Foundation

/// A CAD tool's result on its way to a transport: the JSON metadata an agent
/// reads, the exact PNG an image tool rendered, and whether the call failed in
/// its domain. The metadata is serialized once, here; each transport wraps
/// that text in its own envelope and consumers read `metadata` directly.
struct CADAgentToolResult {
    struct Image {
        /// The PNG's file in the task workspace.
        let path: String
        let data: Data
    }

    let metadata: [String: Any]
    /// `metadata` as the agent reads it.
    let text: String
    let image: Image?
    let isError: Bool

    init(metadata: [String: Any], image: Image? = nil, isError: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
        self.metadata = metadata
        text = String(decoding: data, as: UTF8.self)
        self.image = image
        self.isError = isError
    }

    /// The built-in bridge's response, which Engine/agent_server.py turns into
    /// MCP content. It is also the call's activity output.
    var envelope: [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let image { content.append(["type": "image_path", "path": image.path, "mimeType": "image/png"]) }
        var value: [String: Any] = ["content": content]
        if isError { value["isError"] = true }
        return value
    }
}

/// One audited native tool call. The built-in agent bridge and external agent
/// sessions share its source snapshots, activity events and the exact PNG an
/// image tool rendered.
@MainActor
struct CADAgentToolCall {
    let tools: CADAgentTools
    let workspace: CADAgentWorkspace
    let onActivity: (ProjectActivityEvent) -> Void

    /// Run one call. `prepare` turns the agent's arguments into native
    /// arguments and may add snapshots; it runs inside the audited call so its
    /// failures are recorded too. `checkAvailable` runs after the tool returns.
    func perform(id: String, name: String, arguments: [String: Any],
                 prepare: () throws -> (arguments: [String: Any], snapshots: [ProjectActivityFile]) = { ([:], []) },
                 checkAvailable: () throws -> Void = {}) async throws -> CADAgentToolResult {
        let started = Date()
        let input = CADAgentBridge.json(arguments)
        var files: [ProjectActivityFile] = []
        do {
            let tool = try AgentToolCatalog.native()[name]
            let prepared = try prepare()
            let native = prepared.arguments.isEmpty ? arguments : prepared.arguments
            files = try tool.map { try sourceSnapshots(tool: $0, arguments: native) } ?? []
            files += prepared.snapshots
            onActivity(ProjectActivityEvent(id: id, date: started, category: "tool", title: name, status: "running",
                                            input: input, files: files.isEmpty ? nil : files))
            let result = try await tools.handle(name: name, arguments: native)
            try checkAvailable()
            if tool?.host.resultProgram == true, let program = result.metadata["programPath"] as? String {
                files += try snapshots(programs: [program], sources: []).filter { new in !files.contains { $0.path == new.path } }
            }
            onActivity(ProjectActivityEvent(id: id, date: started, category: "tool", title: name,
                status: result.isError ? "failed" : "completed", input: input, output: CADAgentBridge.json(result.envelope),
                durationSeconds: Date().timeIntervalSince(started), files: files.isEmpty ? nil : files,
                imageData: result.isError ? nil : result.image?.data))
            return result
        } catch {
            let canceled = error is CancellationError
            onActivity(ProjectActivityEvent(id: id, date: started, category: "tool", title: name,
                status: canceled ? "canceled" : "failed", input: input,
                output: canceled ? "The CAD tool call was canceled." : error.localizedDescription,
                durationSeconds: Date().timeIntervalSince(started), files: files.isEmpty ? nil : files))
            throw error
        }
    }

    /// The source files a call reads, recorded with its activity.
    func sourceSnapshots(tool: AgentTool, arguments: [String: Any]) throws -> [ProjectActivityFile] {
        let programs = tool.host.programs.compactMap { arguments[$0] as? String }
        var sources: [String] = []
        for key in tool.host.sources {
            if let path = arguments[key] as? String { sources.append(path) }
            else if let paths = arguments[key] as? [String] { sources += paths }
        }
        for key in tool.host.sourceDocuments {
            guard let path = arguments[key] as? String,
                  let document = try JSONSerialization.jsonObject(with: workspace.read(path, maximumBytes: ProjectActivityFile.maximumBytes)) as? [String: Any],
                  let program = document["programPath"] as? String else { continue }
            sources.append(program)
        }
        return try snapshots(programs: programs, sources: sources)
    }

    /// Programs without an extension are recorded as Python files.
    private func snapshots(programs: [String], sources: [String]) throws -> [ProjectActivityFile] {
        let paths = programs.map { ($0, true) } + sources.map { ($0, false) }
        guard paths.count <= 64 else { throw LADError.message("Choose at most 64 source files for the tool activity record.") }
        var seen = Set<String>()
        return try paths.compactMap { path, program in
            let url = try workspace.url(path)
            guard seen.insert(url.path).inserted else { return nil }
            var filename = url.lastPathComponent
            if program, url.pathExtension.isEmpty { filename += ".py" }
            let snapshot = ProjectActivityFile(name: filename, path: url.path,
                data: try workspace.read(path, maximumBytes: ProjectActivityFile.maximumBytes, allowEmpty: true))
            try ProjectStore.validateActivityFile(snapshot)
            return snapshot
        }
    }
}
