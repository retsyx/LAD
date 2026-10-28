import SwiftUI
import AppKit

@MainActor
struct LADSettingsView: View {
    @AppStorage("codexPath") private var codexPath = ""
    @AppStorage("pythonPath") private var pythonPath = ""
    @AppStorage("workerThreads") private var threads = 0
    @ObservedObject private var codexHealth = CodexHealth.shared
    @StateObject private var healthWindow = CodexSettingsWindowMonitor()

    private var codexExecutable: String {
        // Observe the hidden override without replacing the retained window anchor.
        _ = codexPath
        return CodexService.configuredExecutable
    }

    var body: some View {
        Form {
            if let issue = codexHealth.issue {
                Section("Codex") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.title).font(.headline)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(issue.details ?? issue.message)
                    }
                    HStack(spacing: 10) {
                        Button("Check again") { healthWindow.refresh(force: true) }
                            .disabled(codexHealth.isChecking)
                        if codexHealth.isChecking { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Codex setup documentation ↗", destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
                    }
                }
            }
            Section("CAD engine") {
                LabeledContent("Python runtime") {
                    TextField(EngineService.defaultPython, text: $pythonPath)
                    Button("Choose…") { chooseExecutable { pythonPath = $0 } }
                }
                Text("Use the Python environment created by Scripts/setup.sh. CadQuery and OpenCascade must be installed in this runtime.").font(.caption).foregroundStyle(.secondary)
                Picker("CAD threads", selection: $threads) {
                    Text("Automatic (\(ProcessInfo.processInfo.activeProcessorCount) cores)").tag(0)
                    ForEach(1...max(1, ProcessInfo.processInfo.activeProcessorCount), id: \.self) { n in Text("\(n)").tag(n) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 650, height: 420)
        .background(CodexSettingsWindowAnchor(monitor: healthWindow,
            executable: codexExecutable,
            refresh: { [health = codexHealth] executable, force in
                await health.refresh(executable: executable, force: force)
            })
            .frame(width: 0, height: 0))
    }

    private func chooseExecutable(_ selected: (String) -> Void) {
        let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let path = panel.url?.path { selected(path) }
    }
}

/// SwiftUI retains the native Settings window after it closes. Observe that
/// exact window so reopening it checks Codex without polling hidden content or
/// reacting to other design windows becoming active.
@MainActor
final class CodexSettingsWindowMonitor: ObservableObject {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var executable = ""
    private var action: (@MainActor (String, Bool) async -> Void)?
    private var task: Task<Void, Never>?
    private var deferredRefresh: Task<Void, Never>?
    private var generation: UUID?
    private var isClosed = false

    deinit {
        task?.cancel()
        deferredRefresh?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func configure(executable: String, refresh: @escaping @MainActor (String, Bool) async -> Void) {
        let changed = self.executable != executable
        self.executable = executable
        action = refresh
        if changed {
            cancelRefresh()
            self.refresh()
        }
    }

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        removeObservers()
        cancelRefresh()
        self.window = window
        isClosed = false
        guard let window else { return }
        observe(NSWindow.didBecomeKeyNotification, object: window) { monitor in
            monitor.isClosed = false
            monitor.refreshAfterVisibilityUpdate()
        }
        observe(NSWindow.willCloseNotification, object: window) { monitor in
            monitor.isClosed = true
            monitor.cancelRefresh()
        }
        observe(NSWindow.didMiniaturizeNotification, object: window) { $0.cancelRefresh() }
        observe(NSWindow.didDeminiaturizeNotification, object: window) { $0.refreshAfterVisibilityUpdate() }
        observe(NSApplication.didBecomeActiveNotification, object: NSApplication.shared) { $0.refreshAfterVisibilityUpdate() }
        refresh()
    }

    func refresh(force: Bool = false) {
        guard let window, window.isVisible, !window.isMiniaturized, !isClosed, let action else { return }
        if task != nil && !force { return }
        cancelRefresh()
        let token = UUID(), executable = executable
        generation = token
        task = Task { [weak self] in
            await action(executable, force)
            guard let self, self.generation == token else { return }
            self.task = nil
            self.generation = nil
        }
    }

    func disconnect() {
        removeObservers()
        cancelRefresh()
        window = nil
        action = nil
        isClosed = false
    }

    private func cancelRefresh() {
        deferredRefresh?.cancel()
        deferredRefresh = nil
        generation = nil
        task?.cancel()
        task = nil
    }

    private func refreshAfterVisibilityUpdate() {
        // AppKit can announce key/activation before finishing the window's
        // ordering transition. Recheck visibility after that call unwinds.
        deferredRefresh?.cancel()
        deferredRefresh = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.deferredRefresh = nil
            self?.refresh()
        }
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func observe(_ name: Notification.Name, object: AnyObject,
                         action: @escaping @MainActor (CodexSettingsWindowMonitor) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
}

struct CodexSettingsWindowAnchor: NSViewRepresentable {
    var monitor: CodexSettingsWindowMonitor
    var executable: String
    var refresh: @MainActor (String, Bool) async -> Void

    func makeNSView(context: Context) -> CodexSettingsWindowAnchorView {
        let view = CodexSettingsWindowAnchorView(frame: .zero)
        view.monitor = monitor
        monitor.configure(executable: executable, refresh: refresh)
        return view
    }

    func updateNSView(_ view: CodexSettingsWindowAnchorView, context: Context) {
        view.monitor = monitor
        monitor.configure(executable: executable, refresh: refresh)
        monitor.attach(to: view.window)
    }

    static func dismantleNSView(_ view: CodexSettingsWindowAnchorView, coordinator: ()) {
        view.monitor?.disconnect()
        view.monitor = nil
    }
}

@MainActor
final class CodexSettingsWindowAnchorView: NSView {
    weak var monitor: CodexSettingsWindowMonitor?
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor?.attach(to: window)
    }
}

/// Model and reasoning choices belong to the project shown in this composer.
/// Choosing a model first limits the following section to that model's efforts.
@MainActor
struct CodexModelMenu: View {
    @ObservedObject var state: AppState
    // The executable remains an application preference. Observe changes here
    // so its catalog refreshes even when the active project has not changed.
    @AppStorage("codexPath") private var codexPath = ""
    @ObservedObject private var catalog = CodexModelCatalog.shared
    @State private var showsCustomModel = false
    @State private var customModelID = ""
    @FocusState private var customModelFocused: Bool

    private var model: String { state.codexSettings.model }
    private var reasoningEffort: String { state.codexSettings.reasoningEffort }

    var body: some View {
        Menu {
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
                        await catalog.refresh(executable: state.executable, force: true)
                        state.normalizeCodexSelection()
                    }
                }.disabled(catalog.isLoading)
            }
        } label: {
            Text("\(modelTitle) · \(reasoningTitle)")
                .foregroundStyle(Palette.accent)
                .lineLimit(1).truncationMode(.middle)
                .font(.system(size: 11)).padding(.vertical, 6)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .fixedSize(horizontal: true, vertical: true).layoutPriority(1)
        .accessibilityLabel("Model and reasoning level")
        .accessibilityValue("\(modelTitle), \(reasoningTitle)")
        .help("\(modelTitle) · \(reasoningTitle). Applies to your next message.")
        .popover(isPresented: $showsCustomModel) { customModelEditor }
        .task(id: codexPath) {
            await catalog.refresh(executable: state.executable)
            state.normalizeCodexSelection()
        }
        .onChange(of: catalog.models) { _, _ in state.normalizeCodexSelection() }
        .onChange(of: catalog.configuredModelID) { _, _ in state.normalizeCodexSelection() }
        .onChange(of: catalog.configuredReasoningEffort) { _, _ in state.normalizeCodexSelection() }
        .onChange(of: catalog.isLoading) { _, loading in
            if !loading { state.normalizeCodexSelection() }
        }
        .onChange(of: state.codexSettings) { _, _ in state.normalizeCodexSelection() }
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
        CodexReasoningEffort(rawValue: value)?.title ?? value.capitalized
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
