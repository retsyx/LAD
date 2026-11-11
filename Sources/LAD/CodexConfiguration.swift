import Foundation

/// A request-local override. Catalog values stay extensible as Codex adds
/// effort levels; the empty value leaves the CLI configuration in control.
struct CodexReasoningEffort: RawRepresentable, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.utf8.count <= 64,
              rawValue.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        self.rawValue = rawValue
    }

    private init(_ value: String) { rawValue = value }

    static let defaultConfiguration = Self("")
    static let none = Self("none")
    static let minimal = Self("minimal")
    static let low = Self("low")
    static let medium = Self("medium")
    static let high = Self("high")
    static let xhigh = Self("xhigh")
    static let max = Self("max")
    static let ultra = Self("ultra")
    static let allCases: [Self] = [.defaultConfiguration, .none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra]

    var id: String { rawValue }

    var title: String {
        switch rawValue {
        case "": return "Use model default"
        case "xhigh": return "Extra High"
        default: return rawValue.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.capitalized }.joined(separator: " ")
        }
    }
}

/// One agent's model, reasoning level and per-model reasoning memory.
struct AgentModelChoice: Codable, Sendable, Equatable {
    var model: String = ""
    var reasoningEffort: String = ""
    var reasoningByModel: [String: String] = [:]
}

/// Agent, model, reasoning and per-model reasoning memory belong to a single
/// LAD project. The top-level model fields describe the selected agent; the
/// other agents' last choices are kept so switching back restores them.
struct CodexProjectSettings: Codable, Sendable, Equatable {
    var vendor: AgentVendor = .codex
    var model: String = ""
    var reasoningEffort: String = ""
    var reasoningByModel: [String: String] = [:]
    var otherAgents: [String: AgentModelChoice] = [:]

    mutating func switchAgent(to vendor: AgentVendor) {
        guard vendor != self.vendor else { return }
        otherAgents[self.vendor.rawValue] = AgentModelChoice(model: model, reasoningEffort: reasoningEffort,
                                                             reasoningByModel: reasoningByModel)
        let restored = otherAgents.removeValue(forKey: vendor.rawValue) ?? AgentModelChoice()
        self.vendor = vendor
        model = restored.model
        reasoningEffort = restored.reasoningEffort
        reasoningByModel = restored.reasoningByModel
    }
}

extension CodexProjectSettings {
    /// Selections saved before agent choice existed were made with Codex.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try values.decodeIfPresent(AgentVendor.self, forKey: .vendor) ?? .codex
        model = try values.decode(String.self, forKey: .model)
        reasoningEffort = try values.decode(String.self, forKey: .reasoningEffort)
        reasoningByModel = try values.decode([String: String].self, forKey: .reasoningByModel)
        otherAgents = try values.decodeIfPresent([String: AgentModelChoice].self, forKey: .otherAgents) ?? [:]
    }
}

/// Selection policy for the conversation composer. Callers provide the current
/// project's memory so switching projects cannot share or overwrite choices.
enum CodexModelSelection {
    static func statusLabel(modelID: String, effort: CodexReasoningEffort,
                            models: [CodexModelDescriptor], configuredModelID: String?,
                            configuredReasoningEffort: String?) -> String {
        let descriptor = effectiveModel(id: modelID, models: models, configuredModelID: configuredModelID)
        let name = descriptor?.displayName ?? (modelID.isEmpty ? configuredModelID ?? "Default model" : modelID)
        let value = effort == .defaultConfiguration
            ? (modelID.isEmpty ? configuredReasoningEffort ?? descriptor?.defaultReasoningEffort : descriptor?.defaultReasoningEffort)
            : effort.rawValue
        let level = value.flatMap(CodexReasoningEffort.init(rawValue:))
        let title = level.flatMap { $0 == .defaultConfiguration ? nil : $0.title } ?? "Default"
        return "\(name) · \(title)"
    }

    static func effectiveModel(id: String, models: [CodexModelDescriptor], configuredModelID: String?) -> CodexModelDescriptor? {
        if !id.isEmpty { return models.first { $0.id == id } }
        if let configuredModelID, !configuredModelID.isEmpty { return models.first { $0.id == configuredModelID } }
        return models.first { $0.isDefault }
    }

    static func supportedEfforts(id: String, models: [CodexModelDescriptor], configuredModelID: String?) -> [CodexReasoningOption] {
        effectiveModel(id: id, models: models, configuredModelID: configuredModelID)?.reasoningEfforts ?? []
    }

    /// Return a catalog-supported value, or the model's advertised default. The
    /// agent's own default level is kept only where the catalog offers it. A
    /// model with no reasoning capability needs no override.
    static func normalizedEffort(_ effort: String, for model: CodexModelDescriptor) -> String? {
        let offered = model.reasoningEfforts.map(\.id).filter { CodexReasoningEffort(rawValue: $0) != nil }
        let supported = offered.filter { !$0.isEmpty }
        guard !supported.isEmpty else { return "" }
        if offered.contains(effort) { return effort }
        if let fallback = model.defaultReasoningEffort, offered.contains(fallback) { return fallback }
        return supported.first
    }

    @discardableResult
    static func selectModel(_ modelID: String, currentModel: String, currentEffort: String,
                            models: [CodexModelDescriptor], configuredModelID: String?,
                            preferences: inout [String: String]) -> String {
        rememberEffort(currentEffort, for: currentModel, preferences: &preferences)
        // Configuration mode can refer to the same actual model later chosen
        // explicitly. Preserve its deliberate override under both identities.
        // An empty value cannot reveal the CLI's effective configured effort.
        if currentModel.isEmpty, !currentEffort.isEmpty,
           let configured = effectiveModel(id: "", models: models, configuredModelID: configuredModelID),
           configured.reasoningEfforts.contains(where: { $0.id == currentEffort }) {
            rememberEffort(currentEffort, for: configured.id, preferences: &preferences)
        }
        let remembered = preferences[modelID]
        let descriptor = effectiveModel(id: modelID, models: models, configuredModelID: configuredModelID)
        let selected: String
        if modelID.isEmpty {
            // Choosing Codex configuration restores its semantics. Retain a
            // deliberate, supported override previously chosen for that mode.
            if let remembered, !remembered.isEmpty,
               CodexReasoningEffort(rawValue: remembered) != nil,
               descriptor == nil || descriptor?.reasoningEfforts.contains(where: { $0.id == remembered }) == true {
                selected = remembered
            } else { selected = "" }
        } else if let descriptor {
            let supported = Set(descriptor.reasoningEfforts.map(\.id))
            if let remembered, supported.contains(remembered), CodexReasoningEffort(rawValue: remembered) != nil {
                selected = remembered
            } else {
                selected = normalizedEffort(currentEffort, for: descriptor) ?? ""
            }
        } else {
            // Custom identifiers may not appear in a provider's picker catalog.
            // Do not fabricate their capabilities or erase a valid override.
            selected = [remembered, currentEffort].compactMap { $0 }.first {
                CodexReasoningEffort(rawValue: $0) != nil
            } ?? ""
        }
        rememberEffort(selected, for: modelID, preferences: &preferences)
        return selected
    }

    static func rememberEffort(_ effort: String, for modelID: String, preferences: inout [String: String]) {
        guard CodexReasoningEffort(rawValue: effort) != nil,
              modelID.utf8.count <= 256,
              modelID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        // Bound a preference store even if a user repeatedly enters custom IDs.
        if preferences[modelID] == nil, preferences.count >= 256 { return }
        preferences[modelID] = effort
    }
}
