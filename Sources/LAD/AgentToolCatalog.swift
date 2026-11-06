import Foundation

/// The CAD tool schemas have one source, shared with Engine/agent_server.py.
/// The external transport adds explicit task routing and opaque file handles.
enum AgentToolCatalog {
    static func nativeTools() throws -> [[String: Any]] {
        let url = ResourcePaths.root.appendingPathComponent("Engine/agent-tools.json")
        let data = try Data(contentsOf: url)
        guard data.count <= 1_000_000,
              let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !tools.isEmpty, tools.count <= 128,
              Set(tools.compactMap { $0["name"] as? String }).count == tools.count else {
            throw LADError.message("LAD's CAD tool catalog is unavailable.")
        }
        return tools
    }

    static func externalTools() throws -> [[String: Any]] {
        try nativeTools().map { native in
            var tool = native
            guard let name = native["name"] as? String,
                  var schema = native["inputSchema"] as? [String: Any],
                  var properties = schema["properties"] as? [String: Any] else {
                throw LADError.message("LAD's CAD tool catalog is invalid.")
            }
            var required = schema["required"] as? [String] ?? []
            if let program = properties.removeValue(forKey: "programPath") {
                properties["programID"] = program
                required = required.map { $0 == "programPath" ? "programID" : $0 }
            }
            if ["lad_export_step", "lad_mesh_export_step"].contains(name) {
                properties.removeValue(forKey: "path")
                required.removeAll { $0 == "path" }
            }
            for key in properties.keys where key == "path" || key.hasSuffix("Path") || key.hasSuffix("Paths") || key == "programID" {
                guard var property = properties[key] as? [String: Any] else { continue }
                property["description"] = "Opaque file ID returned by a task upload or a previous tool result; filesystem paths are not accepted."
                properties[key] = property
            }
            properties["taskID"] = ["type": "string", "description": "Task ID returned by lad_task_begin for the explicitly chosen design."]
            required.append("taskID")
            schema["properties"] = properties
            schema["required"] = required
            tool["inputSchema"] = schema
            let original = native["description"] as? String ?? ""
            tool["description"] = original.replacingOccurrences(of: "programPath", with: "programID")
                .replacingOccurrences(of: "local paths", with: "opaque file IDs")
                .replacingOccurrences(of: "workspace path", with: "task file ID")
                .replacingOccurrences(of: "successful final response", with: "successful lad_commit")
                .replacingOccurrences(of: "final response", with: "lad_commit")
                + " External task files use opaque upload/download IDs. Builds and color edits are speculative until lad_commit."
            return tool
        }
    }
}
