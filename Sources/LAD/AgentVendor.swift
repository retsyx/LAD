import AppKit
import Foundation

/// The installed agent that performs a project's design requests. Each project
/// records its agent together with that agent's model and reasoning choice.
enum AgentVendor: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex, claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var setupMessage: String {
        switch self {
        case .codex: return CodexExecutable.setupMessage
        case .claude: return ClaudeExecutable.setupMessage
        }
    }

    /// An explicit (hidden) path preference is authoritative; otherwise the
    /// supported installations are discovered automatically.
    var configuredExecutable: String {
        switch self {
        case .codex:
            return CodexExecutable.configuredPath(override: UserDefaults.standard.string(forKey: CodexExecutable.preferenceKey))
        case .claude:
            return ClaudeExecutable.configuredPath(override: UserDefaults.standard.string(forKey: ClaudeExecutable.preferenceKey))
        }
    }

    func resolveExecutable(_ requested: String) -> URL? {
        switch self {
        case .codex: return CodexExecutable.resolve(requested)
        case .claude: return ClaudeExecutable.resolve(requested)
        }
    }

    var isInstalled: Bool { resolveExecutable(configuredExecutable) != nil }

    private var preferenceKey: String {
        switch self {
        case .codex: return CodexExecutable.preferenceKey
        case .claude: return ClaudeExecutable.preferenceKey
        }
    }

    /// An explicit executable preference is authoritative even after its file
    /// disappears, so that agent remains a deliberate choice rather than being
    /// silently replaced by another installation or account.
    var isAvailable: Bool {
        let explicit = UserDefaults.standard.string(forKey: preferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !explicit.isEmpty || isInstalled
    }
}

/// The agent for new designs. When both agents are installed, the user makes
/// one explicit choice; each design then keeps its own agent selection.
enum AgentVendorPreference {
    static let preferenceKey = "agentVendor"
    static let changed = Notification.Name("LADAgentVendorPreferenceChanged")

    static var stored: AgentVendor? {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(AgentVendor.init(rawValue:))
    }

    static func availableVendors() -> Set<AgentVendor> {
        Set(AgentVendor.allCases.filter(\.isAvailable))
    }

    /// An explicit choice is authoritative, like an explicit executable path.
    /// Without one, a sole available agent is used; Codex remains the fallback.
    static func defaultVendor(stored: AgentVendor?, available: Set<AgentVendor>) -> AgentVendor {
        if let stored { return stored }
        if available.count == 1, let only = available.first { return only }
        return .codex
    }

    static var defaultVendor: AgentVendor { defaultVendor(stored: stored, available: availableVendors()) }

    static func needsChoice(stored: AgentVendor?, available: Set<AgentVendor>) -> Bool {
        stored == nil && available.count > 1
    }

    static func choose(_ vendor: AgentVendor) {
        UserDefaults.standard.set(vendor.rawValue, forKey: preferenceKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

@MainActor
enum AgentVendorChoicePrompt {
    /// Ask once, at the first launch that finds both agents installed.
    static func presentIfNeeded() {
        let available = AgentVendorPreference.availableVendors()
        guard AgentVendorPreference.needsChoice(stored: AgentVendorPreference.stored, available: available) else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Choose an agent for new designs"
        alert.informativeText = "Codex and Claude are both installed. Each design can switch agents later from the model menu beside Send."
        alert.addButton(withTitle: "Codex")
        alert.addButton(withTitle: "Claude")
        let response = alert.runModal()
        AgentVendorPreference.choose(response == .alertSecondButtonReturn ? .claude : .codex)
    }
}

/// One private agent process and one task per LAD generation. Additional user
/// input joins that same task only after the agent acknowledges it.
protocol AgentTaskJob: AnyObject, Sendable {
    var canSteer: Bool { get }
    var currentTurnID: String? { get }
    func run(input: Data, imagePaths: [String]) async throws -> Data
    func steer(text: String, imagePaths: [String]) async throws -> String
    func cancel()
    /// Task sandboxes start without network access. An allowed permission
    /// decision enables it for the rest of the task.
    func grantNetworkAccess(for operation: String)
}

extension CodexAppServerJob: AgentTaskJob {}

/// Progress commentary is user-facing prose. Code, JSON and tool output stay in
/// the activity record and the final structured response.
enum AgentCommentary {
    static func visibleText(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("{"), !text.hasPrefix("["), !text.contains("```"), !text.contains("~~~"),
              text.range(of: #"(?m)^\s*(?:import\s+|from\s+\w.*\s+import\s+|result\s*=|def\s+|class\s+|FeatureScript\s+|ISO-10303-21;|\(kicad_pcb\b|(?:const|let|var)\s+\w+\s*=)"#, options: .regularExpression) == nil else { return nil }
        return String(text.prefix(4_000))
    }
}
