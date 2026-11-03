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
        let detail = error["message"] as? String ?? "The request was rejected."
        guard let code = error["code"] as? Int, code == -32601 || code == -32602 else { return detail }
        return "The installed app or CLI does not support this LAD operation. Update the app or CLI and check its configuration, then try again.\n\n\(detail)"
    }
}
