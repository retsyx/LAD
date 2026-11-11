import Foundation

/// LAD uses a separately installed, user-configured Claude Code. Discovery never
/// launches a shell, installs or updates software, signs in, or changes settings.
enum ClaudeExecutable {
    static let preferenceKey = "claudePath"
    static let setupMessage = "Install, configure and sign in to Claude Code before sending a request. LAD discovers supported Claude Code installations automatically."

    /// An explicit choice is authoritative, including when it no longer exists.
    static func configuredPath(override: String?, searchDirectories: [URL] = CodexExecutable.searchDirectories(),
                               automatic: () -> String? = { find() }) -> String {
        let requested = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requested.isEmpty else { return automatic() ?? "" }
        return resolve(requested, searchDirectories: searchDirectories)?.path
            ?? (requested as NSString).expandingTildeInPath
    }

    static func find() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return find(installations: [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ], extensionDirectories: [
            home.appendingPathComponent(".vscode/extensions"),
            home.appendingPathComponent(".vscode-insiders/extensions"),
            home.appendingPathComponent(".cursor/extensions")
        ], searchDirectories: CodexExecutable.searchDirectories())
    }

    /// Stable selection order: self-updating native and Homebrew installations,
    /// then the newest editor-extension binary, then PATH and npm/nvm installs.
    /// Package-manager copies can be stale while an extension keeps updating.
    static func find(installations: [URL], extensionDirectories: [URL], searchDirectories: [URL]) -> String? {
        for binary in installations where isExecutableFile(binary) { return binary.path }
        for directory in extensionDirectories {
            let extensions = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for item in extensions.filter({ $0.lastPathComponent.hasPrefix("anthropic.claude-code-") })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }) {
                let binary = item.appendingPathComponent("resources/native-binary/claude")
                if isExecutableFile(binary) { return binary.path }
            }
        }
        return executable(named: "claude", in: searchDirectories)?.path
    }

    static func resolve(_ requested: String, searchDirectories: [URL] = CodexExecutable.searchDirectories()) -> URL? {
        let requested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return nil }
        if requested.contains("/") || requested.hasPrefix("~") {
            let path = (requested as NSString).expandingTildeInPath
            guard (path as NSString).isAbsolutePath else { return nil }
            let binary = URL(fileURLWithPath: path)
            return isExecutableFile(binary) ? binary : nil
        }
        return executable(named: requested, in: searchDirectories)
    }

    private static func executable(named name: String, in directories: [URL]) -> URL? {
        for directory in directories where (directory.path as NSString).isAbsolutePath {
            let binary = directory.appendingPathComponent(name)
            if isExecutableFile(binary) { return binary }
        }
        return nil
    }

    private static func isExecutableFile(_ binary: URL) -> Bool {
        let manager = FileManager.default
        var directory = ObjCBool(false)
        return manager.fileExists(atPath: binary.path, isDirectory: &directory) && !directory.boolValue
            && manager.isExecutableFile(atPath: binary.path)
    }
}
