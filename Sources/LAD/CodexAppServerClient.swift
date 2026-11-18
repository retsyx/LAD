import Foundation

/// Both short-lived catalog lookups and design requests identify the same app
/// release and explain unsupported protocol operations at the point of failure.
enum CodexAppServerClient {
    static func info(in bundle: Bundle = .main) -> [String: String] {
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ["name": "lad", "title": "LAD", "version": version.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"]
    }

    static func errorMessage(_ error: [String: Any]) -> String {
        if let message = modelUnavailableMessage(error) { return message }
        let detail = error["message"] as? String ?? "The request was rejected."
        guard let code = error["code"] as? Int, code == -32601 || code == -32602 else { return detail }
        return "The installed app or CLI does not support this LAD operation. Update the app or CLI and check its configuration, then try again.\n\n\(detail)"
    }

    /// A failed turn can carry the provider's entire error envelope as its message.
    static func modelUnavailableMessage(_ error: [String: Any]) -> String? {
        var payload = error["data"] as? [String: Any] ?? error
        if let message = error["message"] as? String, message.contains("model_not_found"),
           let decoded = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] {
            payload = decoded
        }
        let providerError = payload["error"] as? [String: Any] ?? payload
        guard providerError["code"] as? String == "model_not_found" else { return nil }
        let reason = (providerError["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = reason.flatMap { $0.isEmpty ? nil : $0 } ?? "The selected model is unavailable."
        return "\(detail) Choose another model in the chat composer and send your request again."
    }
}
