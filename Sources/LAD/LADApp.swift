import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct LADApp: App {
    @NSApplicationDelegateAdaptor(LADAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("LAD", id: "project", for: ProjectWindowRequest.self) { $request in
            ProjectWindowRoot(request: $request, coordinator: delegate.projectWindows, recentProjects: delegate.recentProjects)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { ProjectCommands(coordinator: delegate.projectWindows, recentProjects: delegate.recentProjects,
                                    helpWindow: delegate.helpWindow) }
        Settings { LADSettingsView().preferredColorScheme(.dark).tint(Palette.accent) }
    }
}

private struct ProjectStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    /// The design shown in the key window, for menu commands.
    var projectState: AppState? {
        get { self[ProjectStateFocusedValueKey.self] }
        set { self[ProjectStateFocusedValueKey.self] = newValue }
    }
}

@MainActor
private struct ProjectWindowRoot: View {
    @Binding var request: ProjectWindowRequest?
    let coordinator: ProjectWindowCoordinator
    let recentProjects: RecentProjects
    @StateObject private var session = ProjectWindowSession()
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("projectWindowID") private var storedWindowID = UUID().uuidString
    @SceneStorage("projectFilePath") private var storedFilePath = ""
    @SceneStorage("projectDocumentID") private var storedDocumentID = ""
    @State private var started = false
    @State private var fallbackWindowID = UUID()

    private var windowID: UUID { request?.id ?? UUID(uuidString: storedWindowID) ?? fallbackWindowID }
    private var state: AppState { session.state }

    var body: some View {
        WorkspaceView(state: state)
            .id(ObjectIdentifier(state))
            .frame(minWidth: 1080, minHeight: 700)
            .navigationTitle(state.projectDisplayName)
            .preferredColorScheme(.dark)
            .tint(Palette.accent)
            .focusedSceneValue(\.projectState, state)
            .background(ProjectWindowBridge(id: windowID, state: state, coordinator: coordinator))
            .overlay(ProjectFileDropTarget { url in coordinator.replaceProject(at: url, in: windowID) })
            .task {
                guard !started else { return }
                started = true
                let initial = ProjectWindowRequest.initialSource(request: request, storedPath: storedFilePath,
                                                                 storedProjectID: storedDocumentID)
                let source = initial.url
                if coordinator.discardUnusedInitialWindow(session, id: windowID,
                    isImplicitWindow: request == nil && storedFilePath.isEmpty) { return }
                let restoreRecent = source == nil && request == nil && coordinator.claimInitialRestore()
                let shouldStart = coordinator.register(session, id: windowID,
                    sourceURL: source ?? (restoreRecent ? AppState.recentProjectURL : nil),
                    isImplicitWindow: request == nil && storedFilePath.isEmpty)
                configureOpenHandler()
                let openedExternal = coordinator.startInitialExternalProject(in: windowID)
                if shouldStart && !openedExternal {
                    state.start(restoringRecent: restoreRecent, opening: source, restoringProjectID: initial.projectID)
                }
            }
            .onChange(of: state.projectURL) { _, _ in
                persistWindowProject()
            }
            .onChange(of: ObjectIdentifier(state)) { _, _ in
                configureOpenHandler()
                persistWindowProject()
            }
            .onChange(of: session.sourceURL) { _, _ in
                persistWindowProject()
            }
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { url in
                if let adopted = coordinator.openExternalProject(at: url, in: session, id: windowID,
                    reusingInitialWindow: request == nil && storedFilePath.isEmpty,
                    createWindow: { openWindow(id: "project", value: $0) }) {
                    request = adopted
                }
            }
    }

    private func configureOpenHandler() {
        let opening = openWindow
        let router = coordinator
        router.onReopenProjectWindow = { opening(id: "project", value: $0) }
        state.onOpenProject = { [weak router] url in
            router?.openProject(at: url) { opening(id: "project", value: $0) }
        }
        let recent = recentProjects
        state.onRecentProjectChanged = { [weak recent] url, previous in
            recent?.record(url, replacing: previous)
        }
        state.noteProjectOpened(fallbackURL: session.sourceURL)
    }

    private func persistWindowProject() {
        if let url = state.projectURL {
            storedFilePath = url.path
            storedDocumentID = state.projectDocumentID.uuidString
        } else {
            let path = session.sourceURL?.path ?? ""
            if storedFilePath != path { storedDocumentID = "" }
            storedFilePath = path
        }
        // SwiftUI restores this value as well as SceneStorage. Keep it in
        // sync after an inline rename or a file dropped into this window.
        let source = state.projectURL ?? session.sourceURL
        if var current = request, current.fileURL != source {
            current.fileURL = source
            request = current
        }
    }
}

@MainActor
private struct ProjectCommands: Commands {
    let coordinator: ProjectWindowCoordinator
    @ObservedObject var recentProjects: RecentProjects
    let helpWindow: LADHelpWindowController
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.projectState) private var state: AppState?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Design") { openWindow(id: "project", value: ProjectWindowRequest()) }
                .keyboardShortcut("n")
            Button("Open Design…", action: openProject).keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(recentProjects.urls, id: \.self) { url in
                    Button(recentProjectTitle(url)) {
                        coordinator.openProject(at: url) { openWindow(id: "project", value: $0) }
                    }.help(url.path)
                }
                Divider()
                Button("Clear Menu") { recentProjects.clear() }
            }.disabled(recentProjects.urls.isEmpty)
            Divider()
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save New…") { state?.saveNewProject() }.keyboardShortcut("s")
                .disabled(state?.canSaveNew != true)
            Button("Save Design As…") { state?.saveProject(as: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(state?.canSaveProject != true)
            Divider()
            Button("Export STEP…") { state?.exportSTEP() }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(state?.canExport != true)
        }
        CommandGroup(replacing: .help) {
            Button("LAD Help") { helpWindow.showWindow(nil) }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandMenu("Design") {
            Button("Fit to View") { state?.viewportCommand = ViewportCommand(.fit) }
                .keyboardShortcut("f", modifiers: .command).disabled(state == nil)
            Button("Isometric") { state?.viewportCommand = ViewportCommand(.isometric) }
                .keyboardShortcut("0").disabled(state == nil)
            Button("Front") { state?.viewportCommand = ViewportCommand(.front) }
                .keyboardShortcut("1").disabled(state == nil)
            Button("Top") { state?.viewportCommand = ViewportCommand(.top) }
                .keyboardShortcut("2").disabled(state == nil)
            Button("Right") { state?.viewportCommand = ViewportCommand(.right) }
                .keyboardShortcut("3").disabled(state == nil)
            Divider()
            Toggle("Show Grid", isOn: Binding(get: { state?.showGrid ?? true }, set: { state?.showGrid = $0 }))
                .disabled(state == nil)
            Button("Rebuild Design") { state?.rebuild() }.disabled(state?.isWorking != false)
        }
    }

    private func recentProjectTitle(_ url: URL) -> String {
        let name = url.lastPathComponent
        guard recentProjects.urls.filter({ $0.lastPathComponent == name }).count > 1 else { return name }
        return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .package]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.openProject(at: url) { openWindow(id: "project", value: $0) }
    }
}

@MainActor
final class LADAppDelegate: NSObject, NSApplicationDelegate {
    let projectWindows = ProjectWindowCoordinator()
    let recentProjects = RecentProjects(initialURL: AppState.recentProjectURL)
    let helpWindow = LADHelpWindowController()
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        ExternalAgentServer.shared.configure(coordinator: projectWindows)
        if let iconURL = Bundle.main.url(forResource: "LAD", withExtension: "icns"),
           let data = try? Data(contentsOf: iconURL), let icon = NSImage(data: data) {
            NSApp.applicationIconImage = icon
            NSApp.dockTile.display()
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { AgentVendorChoicePrompt.presentIfNeeded() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            let shouldQuit = await projectWindows.prepareToQuit()
            if shouldQuit { ExternalAgentServer.shared.stop() }
            else { isTerminating = false }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { ExternalAgentServer.shared.stop() }
}

enum Palette {
    static let background = Color(red: 0.071, green: 0.086, blue: 0.106)
    static let panel = Color(red: 0.106, green: 0.118, blue: 0.137)
    static let raised = Color(red: 0.145, green: 0.161, blue: 0.184)
    static let line = Color.white.opacity(0.08)
    static let muted = Color(red: 0.55, green: 0.59, blue: 0.65)
    static let accent = Color(red: 0.96, green: 0.70, blue: 0.36)
}
