import SwiftUI
import AppKit

@MainActor
struct LADSettingsView: View {
    @AppStorage(ProjectSaveLocation.preferenceKey) private var projectSaveDirectory = ""
    @AppStorage("workerThreads") private var threads = 0
    @ObservedObject private var cadRuntime = CADRuntimeManager.shared
    @ObservedObject private var agentPermissions = AgentPermissionController.shared
    @State private var folderChoice: ProjectSaveFolderChoice = .cloud

    private enum ProjectSaveFolderChoice: Hashable { case cloud, documents, custom, choose }

    private var saveDirectory: URL {
        _ = projectSaveDirectory
        return ProjectSaveLocation.directory()
    }

    private var savedFolderChoice: ProjectSaveFolderChoice {
        let path = saveDirectory.resolvingSymlinksInPath().path
        if path == ProjectSaveLocation.cloudDirectory().resolvingSymlinksInPath().path { return .cloud }
        if path == ProjectSaveLocation.documentsDirectory().resolvingSymlinksInPath().path { return .documents }
        return .custom
    }

    private var folderSelection: Binding<ProjectSaveFolderChoice> {
        Binding(get: { folderChoice }, set: { choice in
            folderChoice = choice
            switch choice {
            case .cloud: projectSaveDirectory = ""
            case .documents: projectSaveDirectory = ProjectSaveLocation.documentsDirectory().path
            case .custom, .choose: break
            }
        })
    }

    var body: some View {
        Form {
            Section("Design files") {
                Picker("New designs", selection: folderSelection) {
                    Text("iCloud Drive").tag(ProjectSaveFolderChoice.cloud)
                        .disabled(!ProjectSaveLocation.isCloudAvailable())
                    Text("Documents/LAD").tag(ProjectSaveFolderChoice.documents)
                    if savedFolderChoice == .custom {
                        Text(ProjectSaveLocation.displayName(for: saveDirectory))
                            .tag(ProjectSaveFolderChoice.custom)
                    }
                    Divider()
                    Text("Choose Folder…").tag(ProjectSaveFolderChoice.choose)
                }
                .pickerStyle(.menu)
                .help(ProjectSaveLocation.displayName(for: saveDirectory))
                .onAppear { folderChoice = savedFolderChoice }
                .onChange(of: projectSaveDirectory) { _, _ in folderChoice = savedFolderChoice }
                .task(id: folderChoice) {
                    guard folderChoice == .choose else { return }
                    // Let native popup tracking finish before opening a panel.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    chooseProjectDirectory()
                    folderChoice = savedFolderChoice
                }
            }
            Section("Agent permissions") {
                Picker("Requests", selection: $agentPermissions.policy) {
                    Text("Ask each time").tag(AgentPermissionPolicy.ask)
                    Text("Always allow").tag(AgentPermissionPolicy.alwaysAllow)
                    Text("Always deny").tag(AgentPermissionPolicy.alwaysDeny)
                }
                .pickerStyle(.menu)
            }
            ExternalAgentSettingsView()
            Section("CAD engine") {
                if cadRuntime.phase == .preparing {
                    HStack { ProgressView().controlSize(.small); Text("Preparing CAD runtime…") }
                } else if case .failed(let message) = cadRuntime.phase {
                    Text(message).font(.caption).foregroundStyle(.secondary).help(message)
                }
                Picker("CAD threads", selection: $threads) {
                    Text("Automatic (\(ProcessInfo.processInfo.activeProcessorCount) cores)").tag(0)
                    ForEach(1...max(1, ProcessInfo.processInfo.activeProcessorCount), id: \.self) { n in Text("\(n)").tag(n) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 650, height: 620)
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder for New Designs"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = ProjectSaveLocation.directory()
        if panel.runModal() == .OK, let url = panel.url {
            projectSaveDirectory = url.standardizedFileURL.path
        }
    }
}

/// Agent, model and reasoning choices belong to the project shown in this
/// composer. The agent limits the models; a model limits the reasoning levels.
@MainActor
struct CodexModelMenu: View {
    let state: AppState
    // Executables remain application preferences. Observe changes here so the
    // catalogs refresh even when the active project has not changed.
    @AppStorage(CodexExecutable.preferenceKey) private var codexPath = ""
    @AppStorage(ClaudeExecutable.preferenceKey) private var claudePath = ""
    @ObservedObject private var codexCatalog = CodexModelCatalog.shared
    @ObservedObject private var claudeCatalog = CodexModelCatalog.claude
    @State private var availableAgents: Set<AgentVendor> = []
    @State private var showsCustomModel = false
    @State private var customModelID = ""
    @FocusState private var customModelFocused: Bool

    private var vendor: AgentVendor { state.codexSettings.vendor }
    private var catalog: CodexModelCatalog { vendor == .codex ? codexCatalog : claudeCatalog }
    private var model: String { state.codexSettings.model }
    private var reasoningEffort: String { state.codexSettings.reasoningEffort }
    /// Available agents, plus this design's agent even when it is unavailable.
    private var agentChoices: [AgentVendor] {
        AgentVendor.allCases.filter { availableAgents.contains($0) || $0 == vendor }
    }

    var body: some View {
        Menu {
            if agentChoices.count > 1 {
                Section("Agent") {
                    Picker("Agent", selection: vendorBinding) {
                        ForEach(agentChoices) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }.pickerStyle(.inline).labelsHidden()
                }
            }
            Section("Model") {
                Picker("Model", selection: modelBinding) {
                    if model.isEmpty {
                        Text("Choose a model").tag("").disabled(true)
                    }
                    ForEach(catalog.models) { option in
                        Text(option.displayName).tag(option.id)
                    }
                    if !model.isEmpty, !catalog.models.contains(where: { $0.id == model }) {
                        Text(model).tag(model)
                    }
                }.pickerStyle(.inline).labelsHidden()
                Button("Custom model…") {
                    customModelID = model
                    showsCustomModel = true
                }
            }
            Section("Reasoning level") {
                Picker("Reasoning level", selection: effortBinding) {
                    if selectedModel == nil || selectedModel?.reasoningEfforts.isEmpty == true {
                        Text("Use model default").tag("")
                    }
                    ForEach(selectedModel?.reasoningEfforts ?? []) { effort in
                        Text(effortTitle(effort.id)).tag(effort.id)
                    }
                    if selectedModel == nil, !reasoningEffort.isEmpty {
                        Text(effortTitle(reasoningEffort)).tag(reasoningEffort)
                    }
                }.pickerStyle(.inline).labelsHidden()
            }
            Section {
                if catalog.isLoading {
                    Text("Loading models…").disabled(true)
                }
                if let error = catalog.error {
                    Text(catalog.models.isEmpty ? "Model list unavailable" : "Model refresh failed")
                        .disabled(true).help(error)
                }
                Button("Refresh models") {
                    Task {
                        availableAgents = await Task.detached(priority: .utility) { AgentVendorPreference.availableVendors() }.value
                        await catalog.refresh(executable: state.executable, force: true)
                        state.normalizeCodexSelection()
                    }
                }.disabled(catalog.isLoading)
            }
        } label: {
            Text(selectionTitle)
                .foregroundStyle(Palette.accent)
                .lineLimit(1).truncationMode(.middle)
                .font(.system(size: 11)).padding(.vertical, 6)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .fixedSize(horizontal: true, vertical: true).layoutPriority(1)
        .accessibilityLabel(agentChoices.count > 1 ? "Agent, model and reasoning level" : "Model and reasoning level")
        .accessibilityValue(agentChoices.count > 1 ? "\(vendor.displayName), \(modelTitle), \(reasoningTitle)" : "\(modelTitle), \(reasoningTitle)")
        .help("\(selectionTitle). Applies to your next message.")
        .popover(isPresented: $showsCustomModel) { customModelEditor }
        .task(id: "\(vendor.rawValue)|\(codexPath)|\(claudePath)") {
            await catalog.refresh(executable: state.executable)
            state.normalizeCodexSelection()
        }
        .task(id: "\(codexPath)|\(claudePath)") {
            availableAgents = await Task.detached(priority: .utility) { AgentVendorPreference.availableVendors() }.value
        }
        .onChange(of: codexCatalog.models) { _, _ in state.normalizeCodexSelection() }
        .onChange(of: claudeCatalog.models) { _, _ in state.normalizeCodexSelection() }
        .onChange(of: catalog.configuredModelID) { _, _ in state.normalizeCodexSelection() }
        .onChange(of: catalog.configuredReasoningEffort) { _, _ in state.normalizeCodexSelection() }
        .onChange(of: catalog.isLoading) { _, loading in
            if !loading { state.normalizeCodexSelection() }
        }
        .onChange(of: state.codexSettings) { _, _ in state.normalizeCodexSelection() }
    }

    private var selectionTitle: String {
        agentChoices.count > 1 ? "\(vendor.displayName) · \(modelTitle) · \(reasoningTitle)" : "\(modelTitle) · \(reasoningTitle)"
    }

    private var vendorBinding: Binding<AgentVendor> {
        Binding(get: { vendor }, set: { state.selectAgentVendor($0) })
    }

    private var selectedModel: CodexModelDescriptor? {
        CodexModelSelection.effectiveModel(id: model, models: catalog.models, configuredModelID: catalog.configuredModelID)
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model }, set: { state.selectCodexModel($0) })
    }

    private var effortBinding: Binding<String> {
        Binding(get: { reasoningEffort }, set: { state.selectCodexReasoningEffort($0) })
    }

    private var modelTitle: String {
        if let selectedModel { return selectedModel.displayName }
        if !model.isEmpty { return model }
        return catalog.configuredModelID ?? "Default model"
    }

    private var reasoningTitle: String {
        let selected: String?
        if !reasoningEffort.isEmpty { selected = reasoningEffort }
        else if model.isEmpty { selected = catalog.configuredReasoningEffort ?? selectedModel?.defaultReasoningEffort }
        else { selected = selectedModel?.defaultReasoningEffort }
        guard let selected, !selected.isEmpty else { return "Default" }
        let resolved = selectedModel.flatMap { CodexModelSelection.normalizedEffort(selected, for: $0) } ?? selected
        return resolved.isEmpty ? "Default" : effortTitle(resolved)
    }

    private func effortTitle(_ value: String) -> String {
        // An offered empty level is the agent's own default level.
        value.isEmpty ? "Default" : CodexReasoningEffort(rawValue: value)?.title ?? value.capitalized
    }

    private var customModelEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom model").font(.headline)
            TextField("Model ID", text: $customModelID)
                .textFieldStyle(.roundedBorder)
                .focused($customModelFocused)
                .onSubmit { applyCustomModel() }
            HStack {
                Spacer()
                Button("Cancel") { showsCustomModel = false }
                    .keyboardShortcut(.cancelAction)
                Button("Use model") { applyCustomModel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validCustomModel)
            }
        }
        .padding(16).frame(width: 340)
        .onAppear { customModelFocused = true }
    }

    private var validCustomModel: Bool {
        let value = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.utf8.count <= 256 &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func applyCustomModel() {
        guard validCustomModel else { return }
        state.selectCodexModel(customModelID.trimmingCharacters(in: .whitespacesAndNewlines))
        showsCustomModel = false
    }
}
