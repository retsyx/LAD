import Foundation

/// One audited native tool call. The built-in agent bridge and external agent
/// sessions share its source snapshots, activity events and the handoff of
/// the exact PNG an image tool rendered.
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
                 checkAvailable: () throws -> Void = {}) async throws -> (result: [String: Any], image: Data?) {
        // Invalid, failed and canceled calls must not inherit an earlier PNG.
        defer { _ = tools.consumeRenderedImage() }
        let started = Date()
        let input = CADAgentBridge.json(arguments)
        var files: [ProjectActivityFile] = []
        do {
            let prepared = try prepare()
            let native = prepared.arguments.isEmpty ? arguments : prepared.arguments
            files = try sourceSnapshots(name: name, arguments: native) + prepared.snapshots
            onActivity(ProjectActivityEvent(id: id, date: started, category: "tool", title: name, status: "running",
                                            input: input, files: files.isEmpty ? nil : files))
            let result = try await tools.handle(name: name, arguments: native)
            try checkAvailable()
            if name.hasPrefix("lad_mesh_"), let program = Self.metadata(result)?["programPath"] as? String {
                files += try sourceSnapshots(name: "lad_build", arguments: ["programPath": program])
            }
            let failed = result["isError"] as? Bool == true
            let image = failed ? nil : tools.consumeRenderedImage()
            onActivity(ProjectActivityEvent(id: id, date: started, category: "tool", title: name,
                status: failed ? "failed" : "completed", input: input, output: CADAgentBridge.json(result),
                durationSeconds: Date().timeIntervalSince(started), files: files.isEmpty ? nil : files, imageData: image))
            return (result, image)
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
    func sourceSnapshots(name: String, arguments: [String: Any]) throws -> [ProjectActivityFile] {
        var paths: [String] = []
        if name == "lad_build", let program = arguments["programPath"] as? String { paths.append(program) }
        if name == "lad_import" { paths += arguments["producerPaths"] as? [String] ?? [] }
        if name.hasPrefix("lad_mesh_") {
            paths += ["queryPath", "constraintsPath", "editPath", "programPath", "policyPath"].compactMap { arguments[$0] as? String }
            if let path = arguments["editPath"] as? String,
               let edit = try JSONSerialization.jsonObject(with: workspace.read(path, maximumBytes: ProjectActivityFile.maximumBytes)) as? [String: Any],
               let program = edit["programPath"] as? String { paths.append(program) }
        }
        guard paths.count <= 64 else { throw LADError.message("Choose at most 64 source files for the tool activity record.") }
        var seen = Set<String>()
        return try paths.compactMap { path in
            let url = try workspace.url(path)
            guard seen.insert(url.path).inserted else { return nil }
            var filename = url.lastPathComponent
            if name == "lad_build", url.pathExtension.isEmpty { filename += ".py" }
            let snapshot = ProjectActivityFile(name: filename, path: url.path,
                data: try workspace.read(path, maximumBytes: ProjectActivityFile.maximumBytes, allowEmpty: true))
            try ProjectStore.validateActivityFile(snapshot)
            return snapshot
        }
    }

    /// The JSON metadata in a tool result's first text block.
    static func metadata(_ result: [String: Any]) -> [String: Any]? {
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let bytes = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
}
