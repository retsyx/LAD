import Foundation

/// Convert public CLI execution events into audit facts. Agent messages and
/// reasoning are deliberately handled elsewhere, never copied into this log.
enum CodexActivity {
    static func event(_ object: [String: Any], starts: inout [String: Date]) -> ProjectActivityEvent? {
        guard let eventType = object["type"] as? String else { return nil }
        if eventType == "thread.started" || eventType == "turn.completed" || eventType == "turn.failed" || eventType == "error" {
            let failed = eventType == "turn.failed" || eventType == "error"
            let title = eventType == "thread.started" ? "Session started" : eventType == "turn.completed" ? "Task finished" : "Task error"
            return ProjectActivityEvent(id: "cli:\(eventType):\(object["thread_id"] as? String ?? UUID().uuidString)",
                category: failed ? "diagnostic" : "lifecycle", title: title,
                status: failed ? "failed" : "completed", output: json(sanitize(object)))
        }
        guard ["item.started", "item.updated", "item.completed"].contains(eventType),
              let item = object["item"] as? [String: Any], let kind = item["type"] as? String,
              let rawID = item["id"] as? String, !rawID.isEmpty, rawID.utf8.count <= 900,
              rawID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let category: String
        let title: String
        let input: String?
        let output: String?
        switch kind {
        case "command_execution":
            category = "command"
            title = String((item["command"] as? String ?? "Command").prefix(180))
            input = item["command"] as? String
            output = item["aggregated_output"] as? String ?? item["output"] as? String
        case "mcp_tool_call":
            let server = item["server"] as? String ?? item["server_name"] as? String ?? "MCP"
            // Native LAD calls are logged by the trusted host with exact
            // results and timing; the CLI copy can contain PNG base64.
            guard server != "lad" else { return nil }
            category = "tool"
            title = "\(server) · \(item["tool"] as? String ?? item["tool_name"] as? String ?? "Tool")"
            input = item["arguments"].map { json(sanitize($0)) }
            output = (item["result"] ?? item["error"]).map { json(sanitize($0)) }
        case "file_change":
            category = "file_change"; title = "Workspace file changes"
            input = item["changes"].map { json(sanitize($0)) }; output = nil
        case "web_search":
            category = "web_search"; title = "Web search"
            input = item["query"] as? String
            output = json(sanitize(item))
        case "plan", "plan_update", "todo_list":
            category = "plan"; title = "Task plan"
            input = nil; output = json(sanitize(item))
        default: return nil
        }
        let id = "cli:\(rawID)"
        let now = Date()
        let started = starts[id] ?? now
        starts[id] = started
        let rawStatus = item["status"] as? String
        let status: String
        let hasError = item["error"].map { !($0 is NSNull) } ?? false
        if rawStatus == "canceled" || rawStatus == "cancelled" { status = "canceled" }
        else if rawStatus == "interrupted" { status = "interrupted" }
        else if rawStatus == "failed" || hasError || (item["exit_code"] as? Int).map({ $0 != 0 }) == true { status = "failed" }
        else if eventType == "item.completed" { status = "completed" }
        else { status = "running" }
        let duration = (item["duration_ms"] as? Double).map { $0 / 1_000 }
            ?? (eventType == "item.completed" ? now.timeIntervalSince(started) : nil)
        return ProjectActivityEvent(id: id, date: started, category: category, title: title, status: status,
                                    input: input, output: output, durationSeconds: duration)
    }

    static func sanitize(_ value: Any) -> Any {
        if let text = value as? String, text.hasPrefix("data:image/") || text.hasPrefix("data:audio/") {
            return "Derived media attachment (not stored)"
        }
        if let values = value as? [Any] { return values.map(sanitize) }
        guard var object = value as? [String: Any] else { return value }
        let mediaType = object["type"] as? String ?? ""
        let mimeType = object["mimeType"] as? String ?? ""
        if ["image", "audio", "image_url", "input_image"].contains(mediaType) || mimeType.hasPrefix("image/") || mimeType.hasPrefix("audio/") {
            if let data = object.removeValue(forKey: "data") as? String { object["encodedByteCount"] = data.utf8.count }
            if let data = object.removeValue(forKey: "blob") as? String { object["encodedByteCount"] = data.utf8.count }
            if let url = object["image_url"] as? String, url.hasPrefix("data:") { object["image_url"] = "Derived image attachment (not stored)" }
            if let url = object["url"] as? String, url.hasPrefix("data:") { object["url"] = "Derived image attachment (not stored)" }
        }
        return object.mapValues(sanitize)
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
            options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}
