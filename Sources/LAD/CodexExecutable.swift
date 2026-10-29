import Foundation

/// LAD uses a separately installed, user-configured Codex. Discovery never
/// launches a shell, installs software, signs in, or changes Codex settings.
enum CodexExecutable {
    static let preferenceKey = "codexPath"
    static let setupMessage = "Install, configure and sign in to Codex before sending a request. LAD discovers supported Codex installations automatically."

    /// An explicit choice is authoritative, including when it no longer exists.
    /// Silently falling back could select a different installation or account.
    static func configuredPath(override: String?, searchDirectories: [URL] = searchDirectories(),
                               automatic: () -> String? = { find() }) -> String {
        let requested = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requested.isEmpty else { return automatic() ?? "" }
        return resolve(requested, searchDirectories: searchDirectories)?.path
            ?? (requested as NSString).expandingTildeInPath
    }

    static func find() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if arch(arm64)
        let platform = "macos-aarch64"
        #else
        let platform = "macos-x86_64"
        #endif
        return find(applicationBundles: [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app")
        ], searchDirectories: searchDirectories(), extensionDirectories: [
            home.appendingPathComponent(".vscode/extensions"),
            home.appendingPathComponent(".vscode-insiders/extensions")
        ], platform: platform)
    }

    /// Stable selection order: app launchers, standalone CLI, editor extension.
    /// Keep these installation layouts explicit so fallback changes are tested.
    static func find(applicationBundles: [URL], searchDirectories: [URL],
                     extensionDirectories: [URL], platform: String) -> String? {
        let entries = ["Contents/Resources/codex-cli/bin/codex",
                       "Contents/Resources/codex",
                       "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
        for bundle in applicationBundles {
            for entry in entries {
                let binary = bundle.appendingPathComponent(entry)
                if isExecutableFile(binary) { return binary.path }
            }
        }
        if let binary = executable(named: "codex", in: searchDirectories) { return binary.path }
        for directory in extensionDirectories {
            let extensions = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for item in extensions.filter({ $0.lastPathComponent.hasPrefix("openai.chatgpt-") })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }) {
                let binary = item.appendingPathComponent("bin/\(platform)/codex")
                if isExecutableFile(binary) { return binary.path }
            }
        }
        return nil
    }

    static func resolve(_ requested: String, searchDirectories: [URL] = searchDirectories()) -> URL? {
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

    /// Finder launches do not inherit interactive shell setup. Search common
    /// installation locations directly, including nvm-managed CLI installations.
    static func searchDirectories(path: String? = ProcessInfo.processInfo.environment["PATH"],
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  installationDirectories: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"),
                                                                      URL(fileURLWithPath: "/usr/local/bin")]) -> [URL] {
        var directories = (path ?? "").split(separator: ":").map(String.init)
        directories += installationDirectories.map(\.path)
        directories += [home.appendingPathComponent(".local/bin").path,
                        home.appendingPathComponent(".npm-global/bin").path]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? []
        directories += versions.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending })
            .map { $0.appendingPathComponent("bin").path }
        var seen = Set<String>()
        return directories.compactMap { directory in
            // Empty, relative and dot entries must never execute task-local code.
            guard (directory as NSString).isAbsolutePath else { return nil }
            let url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
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
