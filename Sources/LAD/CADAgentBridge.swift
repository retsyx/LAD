import Foundation
import Darwin

/// A private, per-turn bridge between the stdio MCP server and LAD's native
/// tools. No listener or global Codex configuration is installed.
@MainActor
final class CADAgentBridge {
    let tools: CADAgentTools
    let workspace: URL
    private let control: URL
    private let requests: URL
    private let responses: URL
    private let controlDescriptor: Int32
    private let responseDescriptor: Int32
    private let onActivity: @Sendable (ProjectActivityEvent) -> Void
    private var loop: Task<Void, Never>?
    private var stopped = false
    private var processed = Set<String>()

    init(workspace: URL, python: String, threads: Int, current: ModelSpec?, currentPreview: PreviewMesh?,
         engine: EngineService, viewport: CADSceneView?, hiddenSolids: Set<Int>, solidColors: [Int: PartColor],
         onActivity: @escaping @Sendable (ProjectActivityEvent) -> Void,
         referenceAssets: [CADInputAsset] = [], versions: ProjectVersionContext = .empty) throws {
        self.workspace = try EngineArtifact.canonicalDirectory(workspace)
        control = self.workspace.appendingPathComponent(".lad-tools", isDirectory: true)
        requests = control.appendingPathComponent("requests", isDirectory: true)
        responses = control.appendingPathComponent("responses", isDirectory: true)
        for folder in [control, requests, responses] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let controlFD = Darwin.open(control.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard controlFD >= 0 else { throw LADError.message("LAD could not start its CAD tool connection.") }
        let responseFD = Darwin.open(responses.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard responseFD >= 0 else {
            Darwin.close(controlFD)
            throw LADError.message("LAD could not start its CAD tool connection.")
        }
        controlDescriptor = controlFD
        responseDescriptor = responseFD
        self.onActivity = onActivity
        do {
            tools = try CADAgentTools(directory: self.workspace, python: python, threads: threads, current: current,
                                      currentPreview: currentPreview, engine: engine, viewport: viewport,
                                      hiddenSolids: hiddenSolids, solidColors: solidColors,
                                      referenceAssets: referenceAssets, versions: versions)
        } catch {
            Darwin.close(controlFD); Darwin.close(responseFD)
            throw error
        }
    }

    deinit {
        Darwin.close(controlDescriptor)
        Darwin.close(responseDescriptor)
    }

    static func codexArguments(workspace: URL, python: String, server: URL) throws -> [String] {
        func toml(_ value: String) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        }
        let args = try [server.path, "--workspace", workspace.path].map(toml).joined(separator: ",")
        return ["--config", "mcp_servers.lad.command=\(try toml(python))",
                "--config", "mcp_servers.lad.args=[\(args)]",
                "--config", "mcp_servers.lad.required=true",
                "--config", "mcp_servers.lad.enabled=true",
                "--config", "mcp_servers.lad.default_tools_approval_mode=\"auto\"",
                "--config", "mcp_servers.lad.startup_timeout_sec=30",
                "--config", "mcp_servers.lad.tool_timeout_sec=3600",
                "--config", "approval_policy=\"never\"",
                "--config", "sandbox_workspace_write.network_access=true",
                "--config", "sandbox_workspace_write.writable_roots=[]",
                "--config", "sandbox_workspace_write.exclude_slash_tmp=true",
                "--config", "sandbox_workspace_write.exclude_tmpdir_env_var=true"]
    }

    func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                do {
                    // Refuse replaced directories instead of following a
                    // workspace symlink into an unrelated user directory.
                    guard try EngineArtifact.canonicalDirectory(self.requests) == self.requests,
                          try EngineArtifact.canonicalDirectory(self.responses) == self.responses else {
                        throw LADError.message("The CAD tool workspace changed unexpectedly.")
                    }
                    let pending = try FileManager.default.contentsOfDirectory(at: self.requests,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension == "json" && !self.processed.contains($0.lastPathComponent) }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for file in pending {
                        guard !self.stopped, !Task.isCancelled else { return }
                        self.processed.insert(file.lastPathComponent)
                        await self.handle(file)
                    }
                    try await Task.sleep(for: .milliseconds(40))
                } catch is CancellationError { return }
                catch {
                    self.onActivity(ProjectActivityEvent(id: "bridge:failure", category: "diagnostic",
                        title: "CAD tool connection failed", status: "failed", output: error.localizedDescription))
                    self.stop()
                    return
                }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        loop?.cancel(); loop = nil
        tools.cancel()
        // The open directory descriptor keeps this write in the original
        // private bridge even if a task renames its workspace directories.
        if let data = "closed".data(using: .utf8) {
            try? Self.write(data, named: "closed", in: controlDescriptor)
        }
    }

    private func handle(_ file: URL) async {
        // Invalid, failed and canceled calls must not inherit an earlier PNG.
        defer { _ = tools.consumeRenderedImage() }
        let requestID = file.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: requestID) != nil else { return }
        let started = Date()
        var name = "CAD tool"
        var arguments: [String: Any] = [:]
        var snapshots: [ProjectActivityFile] = []
        do {
            let data = try EngineArtifact.read(file, in: requests, maximumBytes: 1_000_000)
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  request["id"] as? String == requestID,
                  let toolName = request["name"] as? String,
                  toolName.utf8.count <= 256,
                  let input = request["arguments"] as? [String: Any] else {
                throw LADError.message("The CAD tool request is invalid.")
            }
            name = toolName; arguments = input
            snapshots = try auditSnapshots(name: name, arguments: arguments)
            onActivity(ProjectActivityEvent(id: "tool:\(requestID)", date: started, category: "tool",
                title: name, status: "running", input: Self.json(arguments), files: snapshots.isEmpty ? nil : snapshots))
            let result = try await tools.handle(name: name, arguments: arguments)
            try Task.checkCancellation()
            guard !stopped else { return }
            try writeResponse(result, id: requestID)
            onActivity(ProjectActivityEvent(id: "tool:\(requestID)", date: started, category: "tool",
                title: name, status: result["isError"] as? Bool == true ? "failed" : "completed",
                input: Self.json(arguments), output: Self.json(result), durationSeconds: Date().timeIntervalSince(started),
                files: snapshots.isEmpty ? nil : snapshots,
                imageData: result["isError"] as? Bool == true ? nil : tools.consumeRenderedImage()))
        } catch {
            let message = error is CancellationError ? "The CAD tool call was canceled." : error.localizedDescription
            let result: [String: Any] = ["isError": true, "content": [["type": "text", "text": message]]]
            try? writeResponse(result, id: requestID)
            onActivity(ProjectActivityEvent(id: "tool:\(requestID)", date: started, category: "tool",
                title: name, status: error is CancellationError ? "canceled" : "failed",
                input: Self.json(arguments), output: message, durationSeconds: Date().timeIntervalSince(started),
                files: snapshots.isEmpty ? nil : snapshots))
        }
    }

    private func auditSnapshots(name: String, arguments: [String: Any]) throws -> [ProjectActivityFile] {
        let paths: [String]
        if name == "lad_build", let program = arguments["programPath"] as? String { paths = [program] }
        else if name == "lad_import" { paths = arguments["producerPaths"] as? [String] ?? [] }
        else { return [] }
        guard paths.count <= 64 else { throw LADError.message("Choose at most 64 source files for the tool activity record.") }
        let access = try CADAgentWorkspace(directory: workspace)
        var seen = Set<String>()
        return try paths.compactMap { path in
            let url = try access.url(path)
            guard seen.insert(url.path).inserted else { return nil }
            let data = try access.read(path, maximumBytes: 2_000_000, allowEmpty: true)
            var filename = url.lastPathComponent
            if name == "lad_build", url.pathExtension.isEmpty { filename += ".py" }
            let snapshot = ProjectActivityFile(name: filename, path: url.path, data: data)
            try ProjectStore.validateActivityFile(snapshot)
            return snapshot
        }
    }

    private func writeResponse(_ object: [String: Any], id: String) throws {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try Self.write(bytes, named: id + ".json", in: responseDescriptor)
    }

    private static func write(_ data: Data, named name: String, in directory: Int32) throws {
        let temporary = ".response-\(UUID().uuidString)"
        let descriptor = Darwin.openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LADError.message("The CAD tool response could not be written.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard Darwin.renameat(directory, temporary, directory, name) == 0 else {
                throw LADError.message("The CAD tool response could not be delivered.")
            }
        } catch {
            try? handle.close()
            Darwin.unlinkat(directory, temporary, 0)
            throw error
        }
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
