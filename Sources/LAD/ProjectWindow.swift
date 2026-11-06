import AppKit
import Combine
import SwiftUI

struct ProjectWindowRequest: Hashable, Codable {
    var id: UUID
    var fileURL: URL?

    init(id: UUID = UUID(), fileURL: URL? = nil) {
        self.id = id
        self.fileURL = fileURL
    }

    static func initialSource(request: Self?, storedPath: String, storedProjectID: String) -> (url: URL?, projectID: UUID?) {
        let stored = storedPath.isEmpty ? nil : URL(fileURLWithPath: storedPath)
        let source = request?.fileURL ?? stored
        let sameFile = source.map(ProjectFileOrigin.canonicalURL)?.path == stored.map(ProjectFileOrigin.canonicalURL)?.path
        return (source, sameFile ? UUID(uuidString: storedProjectID) : nil)
    }
}

/// A window can change documents while SwiftUI keeps the same window identity.
/// Several windows may display one document, sharing its worker and autosave writer.
@MainActor
final class ProjectWindowSession: ObservableObject {
    @Published var state: AppState {
        didSet { observeState() }
    }
    @Published var sourceURL: URL?
    private var stateObservation: AnyCancellable?

    init(state: AppState? = nil) {
        self.state = state ?? AppState()
        observeState()
    }

    fileprivate var canReceiveInitialProject: Bool {
        state.projectURL == nil && state.projectName == nil && state.revisions.isEmpty && state.messages.isEmpty &&
            state.prompt.isEmpty && state.pendingAttachments.isEmpty && state.queuedRequests.isEmpty &&
            !state.isReadingPromptAttachments && !state.hasUnsavedChanges && !state.canSaveProject
    }

    private func observeState() {
        stateObservation = state.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

/// Owns documents until their last window closes and its final save completes.
/// Native windows remain weak references; document state may have several views.
@MainActor
final class ProjectWindowCoordinator: ObservableObject {
    private struct Entry {
        var session: ProjectWindowSession
        var sourceURL: URL?
        var inheritedAliases: Set<URL> = []
        @MainActor var state: AppState { session.state }
    }

    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private struct ClosingSession {
        var state: AppState
        var task: Task<Void, Never>
    }

    private struct PendingRequest {
        var windowID: UUID
        var token: UUID
    }

    private struct Replacement {
        var token: UUID
        var state: AppState
        var task: Task<Void, Never>
    }

    private enum ReplacementTarget {
        case open(AppState, URL)
        case package(LADProject, URL)
    }

    private var entries: [UUID: Entry] = [:]
    private var windows: [UUID: WindowReference] = [:]
    private var pendingURLs: [URL: PendingRequest] = [:]
    private var initialExternalURLs: [UUID: URL] = [:]
    private var receivedExternalProject = false
    private var unusedInitialWindows: Set<UUID> = []
    private var implicitInitialWindows: Set<UUID> = []
    private var retiringInitialWindows = false
    private var replacements: [UUID: Replacement] = [:]
    // Canceled reads/saves may still be finishing after their window closes.
    private var replacementTasks: [UUID: Replacement] = [:]
    private var focusOrder: [UUID] = []
    private var activeID: UUID?
    private var initialRestoreClaimed = false
    private var closeTasks: [UUID: ClosingSession] = [:]
    private var closingURLs: [URL: UUID] = [:]
    private var reopeningStates: [UUID: AppState] = [:]
    private let closeSession: @MainActor (AppState) async -> Void
    private let saveUnsavedProject: @MainActor (AppState) async -> Bool
    private let readProject: @Sendable (URL) async throws -> LADProject
    private let loadProject: @MainActor (LADProject, URL) -> AppState
    private let loadExistingProject: @MainActor (AppState, LADProject, URL) -> Void
    private let flushProject: @MainActor (AppState) async throws -> Void
    private var quitTask: Task<Bool, Never>?
    private var isQuitting = false
    var onReopenProjectWindow: (@MainActor (ProjectWindowRequest) -> Void)?

    /// External tools address shared documents, independently of key-window routing.
    var agentProjects: [AppState] {
        guard !isQuitting else { return [] }
        var seen = Set<ObjectIdentifier>()
        return (uniqueStates() + Array(reopeningStates.values)).filter {
            $0.canRenameProject && seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    func agentWindow(for state: AppState) -> NSWindow? {
        focusOrder.reversed().compactMap { id in entries[id]?.state === state ? windows[id]?.window : nil }.first
    }

    func createAgentProject() throws -> AppState {
        guard !isQuitting, let opening = onReopenProjectWindow else {
            throw LADError.message("Open a LAD design window before creating another design.")
        }
        let state = AppState()
        state.newProject()
        let request = ProjectWindowRequest()
        reopeningStates[request.id] = state
        opening(request)
        return state
    }

    func openAgentProject(at url: URL) throws {
        guard !isQuitting, let opening = onReopenProjectWindow else {
            throw LADError.message("Open a LAD design window before opening another design.")
        }
        openProject(at: url, createWindow: opening)
    }

    init(closeSession: @escaping @MainActor (AppState) async -> Void = { await $0.prepareToQuit() },
         saveUnsavedProject: @escaping @MainActor (AppState) async -> Bool = { await ProjectQuitSave.save($0) },
         readProject: @escaping @Sendable (URL) async throws -> LADProject = { url in
             try await Task.detached { try ProjectAutosaveStore.readProject(from: url) }.value
         },
         loadProject: @escaping @MainActor (LADProject, URL) -> AppState = { project, url in
             let state = AppState()
             state.loadProject(project, from: url)
             return state
         },
         loadExistingProject: @escaping @MainActor (AppState, LADProject, URL) -> Void = { state, project, url in
             state.loadProject(project, from: url)
         },
         flushProject: @escaping @MainActor (AppState) async throws -> Void = { try await $0.flushForReplacement() }) {
        self.closeSession = closeSession
        self.saveUnsavedProject = saveUnsavedProject
        self.readProject = readProject
        self.loadProject = loadProject
        self.loadExistingProject = loadExistingProject
        self.flushProject = flushProject
    }

    func claimInitialRestore() -> Bool {
        guard !initialRestoreClaimed else { return false }
        initialRestoreClaimed = true
        return true
    }

    /// Claim a document before starting its initial read. Restored windows can
    /// register the same file before either read has completed.
    /// Returns whether this window owns the document's initial start.
    @discardableResult
    func register(_ session: ProjectWindowSession, id: UUID, sourceURL: URL?, isImplicitWindow: Bool = false) -> Bool {
        if isImplicitWindow { implicitInitialWindows.insert(id) }
        else { implicitInitialWindows.remove(id) }
        var aliases = Set<URL>()
        var shouldStart = !hasWindow(for: session.state)
        let source = sourceURL.map(Self.canonicalURL)
        if let retained = reopeningStates.removeValue(forKey: id) {
            session.state = retained
            aliases = adoptClosedState(retained)
            shouldStart = false
        } else if let source,
                  let existingID = entryID(matching: source, excluding: id, includingUnstarted: true),
                  let existing = entries[existingID] {
            session.state = existing.state
            aliases = existing.inheritedAliases
            shouldStart = false
        }
        session.sourceURL = source
        entries[id] = Entry(session: session, sourceURL: source, inheritedAliases: aliases)
        pendingURLs = pendingURLs.filter { $0.value.windowID != id }
        if !focusOrder.contains(id) { focusOrder.append(id) }
        if windows[id]?.window?.isKeyWindow == true || activeID == nil || activeID == id {
            markActive(id)
        } else {
            updateActiveStates()
        }
        retireUnusedInitialWindows()
        return shouldStart
    }

    @discardableResult
    func register(_ state: AppState, id: UUID, sourceURL: URL?) -> Bool {
        register(ProjectWindowSession(state: state), id: id, sourceURL: sourceURL)
    }

    func openProject(at url: URL, createWindow: @escaping (ProjectWindowRequest) -> Void) {
        guard !isQuitting else { return }
        let canonical = Self.canonicalURL(url)
        // During a drop, the receiving window owns the pending destination.
        if let pending = pendingURLs[canonical] {
            focus(pending.windowID)
            return
        }
        if let existing = entryID(matching: canonical) {
            entries[existing]?.state.noteProjectOpened(fallbackURL: entries[existing]?.sourceURL)
            focus(existing)
            return
        }
        let request = ProjectWindowRequest(fileURL: canonical)
        reserve(canonical, for: request.id, token: request.id)
        if let token = closingURLs[canonical], let closing = closeTasks[token] {
            for (alias, owner) in closingURLs where owner == token { reserve(alias, for: request.id, token: request.id) }
            Task { [self] in
                await closing.task.value
                guard !isQuitting, pendingURLs.values.contains(where: { $0.token == request.id }) else {
                    clearReservations(token: request.id)
                    return
                }
                // An inline rename may finish as the old window closes. Open
                // that saved document, retaining its identity and final bytes.
                let destination = Self.canonicalURL(closing.state.projectURL ?? canonical)
                if let existing = entryID(matching: destination) {
                    clearReservations(token: request.id)
                    entries[existing]?.state.noteProjectOpened(fallbackURL: entries[existing]?.sourceURL)
                    focus(existing)
                    return
                }
                if let other = pendingURLs[destination], other.windowID != request.id {
                    clearReservations(token: request.id)
                    focus(other.windowID)
                    return
                }
                reserve(destination, for: request.id, token: request.id)
                if closing.state.hasUnsavedChanges { reopeningStates[request.id] = closing.state }
                createWindow(ProjectWindowRequest(id: request.id, fileURL: destination))
            }
            return
        }
        createWindow(request)
    }

    /// SwiftUI may create an implicit window to deliver a Finder open event.
    /// Let that pristine receiver become the requested design instead of
    /// creating another window and leaving an empty launch window above it.
    /// Explicit New Design windows, restored files and drafts remain separate.
    func openExternalProject(at url: URL, in session: ProjectWindowSession, id: UUID,
                             reusingInitialWindow: Bool,
                             createWindow: @escaping (ProjectWindowRequest) -> Void) -> ProjectWindowRequest? {
        guard !isQuitting else { return nil }
        receivedExternalProject = true
        initialRestoreClaimed = true
        guard reusingInitialWindow, session.canReceiveInitialProject,
              !unusedInitialWindows.contains(id), initialExternalURLs[id] == nil else {
            openProject(at: url, createWindow: createWindow)
            discardRegisteredInitialWindows()
            return nil
        }
        implicitInitialWindows.remove(id)
        let canonical = Self.canonicalURL(url)
        let request = ProjectWindowRequest(id: id, fileURL: canonical)
        if entries[id] != nil {
            replaceProject(at: canonical, in: id)
        } else {
            // onOpenURL can precede the root's task/registration. The scene's
            // bound request carries this source into that single initial start.
            reserve(canonical, for: id, token: id)
            initialExternalURLs[id] = canonical
            session.sourceURL = canonical
        }
        discardRegisteredInitialWindows()
        return request
    }

    private func discardRegisteredInitialWindows() {
        for id in Array(implicitInitialWindows) {
            guard let session = entries[id]?.session, replacements[id] == nil else { continue }
            _ = discardUnusedInitialWindow(session, id: id, isImplicitWindow: true)
        }
    }

    /// SwiftUI can finish creating its ordinary launch window after opening
    /// the external file's scene. Retire only this untouched implicit window;
    /// explicit New Design and restored document windows remain independent.
    func discardUnusedInitialWindow(_ session: ProjectWindowSession, id: UUID, isImplicitWindow: Bool) -> Bool {
        guard isImplicitWindow, receivedExternalProject, session.canReceiveInitialProject,
              initialExternalURLs[id] == nil else { return false }
        unusedInitialWindows.insert(id)
        windows[id]?.window?.orderOut(nil)
        retireUnusedInitialWindows()
        return true
    }

    /// Finish an event delivered before the SwiftUI root registered. Reuse
    /// the coordinated replacement flow so a closing writer can finish before
    /// this window reads the file, including an in-flight filename change.
    @discardableResult
    func startInitialExternalProject(in id: UUID) -> Bool {
        guard let url = initialExternalURLs.removeValue(forKey: id) else { return false }
        replaceProject(at: url, in: id, sharingInitialRead: true)
        return true
    }

    /// Open a dropped design in its receiving window. Keep the old document
    /// intact until the incoming package validates and the outgoing save succeeds.
    func replaceProject(at url: URL, in id: UUID) {
        replaceProject(at: url, in: id, sharingInitialRead: false)
    }

    private func replaceProject(at url: URL, in id: UUID, sharingInitialRead: Bool) {
        guard !isQuitting, let entry = entries[id] else { return }
        let canonical = Self.canonicalURL(url)
        let previous = cancelReplacement(in: id)
        if matches(canonical, entry: entry) {
            entry.state.noteProjectOpened(fallbackURL: entry.sourceURL)
            // Dropping the currently displayed file also cancels a pending
            // switch, but its in-flight save still belongs to this window.
            if let previous {
                let token = UUID()
                let task = Task { [self] in
                    await previous.task.value
                    finishReplacement(token, in: id)
                }
                let replacement = Replacement(token: token, state: entry.state, task: task)
                replacements[id] = replacement
                replacementTasks[token] = replacement
            }
            focus(id)
            return
        }
        let token = UUID()
        reserve(canonical, for: id, token: token)
        let session = entry.session
        let task = Task { [self] in
            // A superseded flush may ignore cancellation while coordinating a
            // disk write. Finish it before another transition can save this state.
            await previous?.task.value
            defer { finishReplacement(token, in: id) }
            guard replacementIsCurrent(token, in: id, session: session) else { return }
            do {
                let target = try await replacementTarget(at: canonical, in: id, token: token)
                guard replacementIsCurrent(token, in: id, session: session) else { return }
                let outgoing = session.state
                if !hasOtherWindow(for: outgoing, excluding: id) { try await flushProject(outgoing) }
                guard replacementIsCurrent(token, in: id, session: session) else { return }

                let incoming: AppState
                var source: URL
                switch target {
                case .open(let state, let url):
                    // Its other window may have closed during the outgoing
                    // flush. Await that save before sharing the document again.
                    if let closing = closeTasks.values.first(where: { $0.state === state }) {
                        await closing.task.value
                    }
                    guard replacementIsCurrent(token, in: id, session: session) else { return }
                    incoming = state
                    source = hasWindow(for: state) ? url : Self.canonicalURL(state.projectURL ?? url)
                case .package(let project, let url):
                    source = url
                    // Two simultaneous drops must converge on a single writer.
                    if let existing = entryID(matching: url), let state = entries[existing]?.state {
                        // Another window may still be reading this package. Use
                        // our validated snapshot to finish that same document,
                        // canceling its stale read instead of sharing empty state.
                        if !hasLoadedProject(state) { loadExistingProject(state, project, url) }
                        incoming = state
                    } else if let closingToken = closingURLs[url], let closing = closeTasks[closingToken] {
                        await closing.task.value
                        guard replacementIsCurrent(token, in: id, session: session) else { return }
                        source = Self.canonicalURL(closing.state.projectURL ?? url)
                        incoming = hasLoadedProject(closing.state) ? closing.state : loadProject(project, source)
                    } else {
                        incoming = loadProject(project, url)
                    }
                }
                guard replacementIsCurrent(token, in: id, session: session) else { return }
                var aliases = Set<URL>()
                for other in entries.values where other.state === incoming {
                    aliases.formUnion(other.inheritedAliases)
                }
                aliases.formUnion(adoptClosedState(incoming))
                // Restored views may have joined this document before its
                // initial read completed. Finish that shared read for all of
                // them; an ordinary file drop still replaces only its receiver.
                let receivers = sharingInitialRead
                    ? entries.filter { $0.value.state === outgoing }.map(\.key) : [id]
                for receiverID in receivers {
                    guard let receiver = entries[receiverID]?.session else { continue }
                    entries[receiverID] = Entry(session: receiver, sourceURL: source, inheritedAliases: aliases)
                    receiver.sourceURL = source
                    receiver.state = incoming
                }
                if !hasWindow(for: outgoing) {
                    outgoing.setActiveProject(false)
                    if sharingInitialRead { outgoing.cancel() }
                }
                focus(id)
            } catch {
                guard replacementIsCurrent(token, in: id, session: session) else { return }
                session.state.error = "Unable to open design. \(error.localizedDescription)"
            }
        }
        let replacement = Replacement(token: token, state: entry.state, task: task)
        replacements[id] = replacement
        replacementTasks[token] = replacement
    }

    func markActive(_ id: UUID) {
        guard !isQuitting else { return }
        if unusedInitialWindows.contains(id) {
            windows[id]?.window?.orderOut(nil)
            retireUnusedInitialWindows()
            return
        }
        activeID = id
        focusOrder.removeAll { $0 == id }
        focusOrder.append(id)
        updateActiveStates()
        retireUnusedInitialWindows()
    }

    func windowClosed(_ id: UUID) {
        implicitInitialWindows.remove(id)
        unusedInitialWindows.remove(id)
        initialExternalURLs.removeValue(forKey: id)
        reopeningStates.removeValue(forKey: id)
        cancelReplacement(in: id)
        windows.removeValue(forKey: id)
        pendingURLs = pendingURLs.filter { $0.value.windowID != id }
        focusOrder.removeAll { $0 == id }
        let entry = entries.removeValue(forKey: id)
        if activeID == id {
            activeID = focusOrder.last(where: { entries[$0] != nil })
        }
        if !isQuitting { updateActiveStates() }
        guard let entry, !hasWindow(for: entry.state) else { return }
        if !isQuitting { entry.state.setActiveProject(false) }
        guard !isQuitting else { return }
        entry.state.cancel()
        let token = UUID()
        var aliases = Set<URL>()
        if let url = entry.state.projectURL { aliases.insert(Self.canonicalURL(url)) }
        else {
            aliases = entry.inheritedAliases
            if let source = entry.sourceURL { aliases.insert(source) }
        }
        for alias in aliases { closingURLs[alias] = token }
        let replacing = replacementTasks.values.filter { $0.state === entry.state }.map(\.task)
        let task = Task { [self, state = entry.state] in
            for replacement in replacing { await replacement.value }
            await closeSession(state)
            // A closed window must not discard a failed autosave. Keep its
            // state and aliases until quit, or until another window reuses it.
            if !state.hasUnsavedChanges {
                closeTasks.removeValue(forKey: token)
                closingURLs = closingURLs.filter { $0.value != token }
            }
        }
        closeTasks[token] = ClosingSession(state: entry.state, task: task)
    }

    @discardableResult
    func prepareToQuit() async -> Bool {
        if let quitTask { return await quitTask.value }
        isQuitting = true
        let replacing = replacementTasks.values.map(\.task)
        for id in Array(replacements.keys) { cancelReplacement(in: id) }
        let closing = Array(closeTasks.values)
        let sessions = uniqueStates()
        for state in sessions { state.cancel() }
        let task = Task { [closeSession, saveUnsavedProject] in
            for replacement in replacing { await replacement.value }
            for closingSession in closing { await closingSession.task.value }
            for state in sessions { await closeSession(state) }
            var seen = Set<ObjectIdentifier>()
            for state in sessions + closing.map(\.state) where seen.insert(ObjectIdentifier(state)).inserted {
                if state.hasUnsavedChanges, !(await saveUnsavedProject(state)) { return false }
            }
            return true
        }
        quitTask = task
        let shouldQuit = await task.value
        if !shouldQuit {
            quitTask = nil
            isQuitting = false
            updateActiveStates()
            reopenUnsavedClosedProjects()
        }
        return shouldQuit
    }

    private func reopenUnsavedClosedProjects() {
        guard let onReopenProjectWindow else { return }
        for closing in closeTasks.values where closing.state.hasUnsavedChanges && !hasWindow(for: closing.state) {
            guard !reopeningStates.values.contains(where: { $0 === closing.state }) else { continue }
            let request = ProjectWindowRequest(fileURL: closing.state.projectURL)
            reopeningStates[request.id] = closing.state
            onReopenProjectWindow(request)
        }
    }

    fileprivate func bind(_ window: NSWindow, id: UUID) {
        windows[id] = WindowReference(window)
        if unusedInitialWindows.contains(id) { window.orderOut(nil) }
        else if window.isKeyWindow { markActive(id) }
        retireUnusedInitialWindows()
    }

    private func retireUnusedInitialWindows() {
        guard !isQuitting, !retiringInitialWindows, !unusedInitialWindows.isEmpty,
              let targetID = focusOrder.reversed().first(where: { id in
                  !unusedInitialWindows.contains(id) && entries[id] != nil && windows[id]?.window?.isVisible == true
              }) else { return }
        // Keep a hidden placeholder alive until the requested file has a
        // visible window, so closing it cannot terminate the application.
        let closing = unusedInitialWindows.compactMap { id -> (UUID, NSWindow)? in
            guard let window = windows[id]?.window else { return nil }
            return (id, window)
        }
        guard !closing.isEmpty else { return }
        retiringInitialWindows = true
        defer { retiringInitialWindows = false }
        for (id, window) in closing {
            unusedInitialWindows.remove(id)
            window.close()
            // bind() may run before the anchor installs its close observer.
            windowClosed(id)
        }
        focus(targetID)
    }

    fileprivate func unbind(_ window: NSWindow?, id: UUID) {
        if windows[id]?.window === window { windows.removeValue(forKey: id) }
    }

    private func replacementTarget(at url: URL, in id: UUID, token: UUID) async throws -> ReplacementTarget {
        if let closingToken = closingURLs[url], let closing = closeTasks[closingToken] {
            for (alias, owner) in closingURLs where owner == closingToken { reserve(alias, for: id, token: token) }
            await closing.task.value
            try Task.checkCancellation()
            let destination = Self.canonicalURL(closing.state.projectURL ?? url)
            reserve(destination, for: id, token: token)
            if hasLoadedProject(closing.state) { return .open(closing.state, destination) }
            // A closing window may have canceled its very first read. It has
            // no validated document to reuse, so validate before saving the receiver.
            return .package(try await readProject(destination), destination)
        }
        if let existing = entryID(matching: url), let state = entries[existing]?.state {
            // Registration precedes the initial asynchronous read. Its source
            // alias alone does not establish that the package is a valid design.
            if hasLoadedProject(state) { return .open(state, url) }
        }
        return .package(try await readProject(url), url)
    }

    private func replacementIsCurrent(_ token: UUID, in id: UUID, session: ProjectWindowSession) -> Bool {
        !isQuitting && !Task.isCancelled && replacements[id]?.token == token && entries[id]?.session === session
    }

    @discardableResult
    private func cancelReplacement(in id: UUID) -> Replacement? {
        let replacement = replacements.removeValue(forKey: id)
        replacement?.task.cancel()
        if let replacement { clearReservations(token: replacement.token) }
        return replacement
    }

    private func finishReplacement(_ token: UUID, in id: UUID) {
        if replacements[id]?.token == token { replacements.removeValue(forKey: id) }
        replacementTasks.removeValue(forKey: token)
        clearReservations(token: token)
    }

    private func reserve(_ url: URL, for id: UUID, token: UUID) {
        pendingURLs[url] = PendingRequest(windowID: id, token: token)
    }

    private func clearReservations(token: UUID) {
        pendingURLs = pendingURLs.filter { $0.value.token != token }
    }

    private func hasLoadedProject(_ state: AppState) -> Bool { state.projectURL != nil || state.canRenameProject }

    private func adoptClosedState(_ state: AppState) -> Set<URL> {
        var aliases = Set<URL>()
        let tokens = closeTasks.filter { $0.value.state === state }.map(\.key)
        for token in tokens {
            if state.projectURL == nil { aliases.formUnion(closingURLs.filter { $0.value == token }.map(\.key)) }
            closeTasks.removeValue(forKey: token)
            closingURLs = closingURLs.filter { $0.value != token }
        }
        return aliases
    }

    private func hasWindow(for state: AppState) -> Bool { entries.values.contains { $0.state === state } }

    private func hasOtherWindow(for state: AppState, excluding id: UUID) -> Bool {
        entries.contains { $0.key != id && $0.value.state === state }
    }

    private func uniqueStates() -> [AppState] {
        var seen = Set<ObjectIdentifier>()
        return entries.values.compactMap { entry in seen.insert(ObjectIdentifier(entry.state)).inserted ? entry.state : nil }
    }

    private func updateActiveStates() {
        let activeState = activeID.flatMap { entries[$0]?.state }
        for state in uniqueStates() { state.setActiveProject(state === activeState) }
    }

    private func focus(_ id: UUID) {
        markActive(id)
        guard let window = windows[id]?.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func entryID(matching url: URL, excluding excludedID: UUID? = nil, includingUnstarted: Bool = false) -> UUID? {
        focusOrder.reversed().first { id in
            guard id != excludedID, let entry = entries[id] else { return false }
            if matches(url, entry: entry) { return true }
            // Registration precedes start(), so an initial file reservation
            // must also cover the interval before isWorking becomes true.
            // A failed read has started already and remains retryable.
            return includingUnstarted && entry.sourceURL == url && entry.state.projectURL == nil &&
                !entry.state.hasStartedProjectSession
        }
    }

    private func matches(_ url: URL, entry: Entry) -> Bool {
        if let current = entry.state.projectURL { return Self.canonicalURL(current) == url }
        if entry.inheritedAliases.contains(url) { return true }
        guard entry.sourceURL == url else { return false }
        // A former path must be released after a rename.
        return entry.state.projectURL == nil && entry.state.isWorking
    }

    private static func canonicalURL(_ url: URL) -> URL {
        ProjectFileOrigin.canonicalURL(url)
    }
}

struct ProjectWindowBridge: NSViewRepresentable {
    let id: UUID
    @ObservedObject var state: AppState
    let coordinator: ProjectWindowCoordinator

    func makeNSView(context: Context) -> ProjectWindowAnchor {
        let view = ProjectWindowAnchor()
        view.configure(id: id, state: state, coordinator: coordinator)
        return view
    }

    func updateNSView(_ view: ProjectWindowAnchor, context: Context) {
        view.configure(id: id, state: state, coordinator: coordinator)
    }

    static func dismantleNSView(_ view: ProjectWindowAnchor, coordinator: ()) { view.disconnect() }
}

@MainActor
final class ProjectWindowAnchor: NSView {
    private var projectID: UUID?
    private weak var state: AppState?
    private weak var windowCoordinator: ProjectWindowCoordinator?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func configure(id: UUID, state: AppState, coordinator: ProjectWindowCoordinator) {
        if projectID != id || windowCoordinator !== coordinator { disconnect() }
        projectID = id
        self.state = state
        windowCoordinator = coordinator
        connectWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectWindow()
    }

    func disconnect() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let projectID { windowCoordinator?.unbind(observedWindow, id: projectID) }
        observedWindow = nil
    }

    private func connectWindow() {
        guard let window, let projectID, let state, let windowCoordinator else { return }
        window.title = state.projectDisplayName
        window.representedURL = state.projectURL
        window.isDocumentEdited = state.hasUnsavedChanges
        window.tabbingMode = .disallowed
        guard observedWindow !== window else { return }
        disconnect()
        observedWindow = window
        windowCoordinator.bind(window, id: projectID)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak windowCoordinator] _ in
            MainActor.assumeIsolated { windowCoordinator?.markActive(projectID) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak windowCoordinator] _ in
            MainActor.assumeIsolated { windowCoordinator?.windowClosed(projectID) }
        })
    }
}
