import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published private(set) var taskAudits: [ProjectTaskAudit] = []
    let activityImages = ProjectActivityImages()
    weak var viewportView: CADSceneView?
    @Published var revisions: [ProjectRevision] = [] {
        didSet { agentStateGeneration &+= 1; projectThumbnailRevisionsChanged(from: oldValue) }
    }
    @Published var selectedRevisionID: UUID? {
        didSet {
            if selectedRevisionID != oldValue {
                cancelAssemblyGrab()
                agentStateGeneration &+= 1; scheduleProjectThumbnail()
            }
        }
    }
    @Published var mesh: PreviewMesh? {
        didSet {
            projectThumbnailMeshModel = mesh == nil ? nil : current
            loadAssemblyPose()
            // Feature IDs belong to one native topology. Even a replacement
            // at the same artifact path must not keep old feature selections.
            selectedFeatures = []
            refreshMeasurements()
            scheduleProjectThumbnail()
        }
    }
    @Published var prompt = "" {
        didSet { if prompt != oldValue { scheduleDebouncedAutosave() } }
    }
    @Published private(set) var queuedRequests: [ProjectQueuedRequest] = []
    @Published private(set) var queuePaused = false
    @Published private(set) var isSendingQueuedRequestID: UUID?
    @Published private(set) var editingQueuedRequestID: UUID?
    @Published private(set) var isReadingQueuedAttachments = false
    @Published private(set) var isReadingDraftAttachments = false
    @Published private(set) var preparingQueuedRequestIDs: Set<UUID> = []
    @Published private(set) var canSteerQueuedRequests = false
    @Published private(set) var queuedRequestErrors: [UUID: String] = [:]
    @Published private(set) var queuePauseReason: String?
    @Published var isWorking = false {
        didSet {
            if isWorking && !oldValue { cancelAssemblyGrab() }
            if oldValue && !isWorking { scheduleQueueAfterBusyOperation() }
        }
    }
    @Published var activity = "Ready"
    @Published private(set) var runningCodexSelection: String?
    @Published private(set) var codexSettings = CodexProjectSettings()
    @Published private(set) var projectName: String? {
        didSet { if projectName != oldValue { agentStateGeneration &+= 1 } }
    }
    @Published private(set) var recentPartColors: [PartColor] = []
    @Published private(set) var partsPaneFraction = 0.75
    @Published var error: String?
    @Published var displayMode: ViewportDisplayMode = .edges {
        didSet {
            if displayMode != oldValue { scheduleProjectThumbnail(); autosave() }
        }
    }
    @Published var projectionMode: ViewportProjectionMode = .perspective {
        didSet {
            if projectionMode != oldValue {
                if isGrabbingAssembly { cancelAssemblyGrab() }
                scheduleProjectThumbnail(); autosave()
            }
        }
    }
    @Published var showGrid = true {
        didSet {
            if showGrid != oldValue { autosave() }
        }
    }
    @Published var viewportCommand: ViewportCommand? {
        didSet { if viewportCommand != oldValue && isGrabbingAssembly { cancelAssemblyGrab() } }
    }
    @Published var projectURL: URL?
    @Published var saveStatus: String?
    @Published private(set) var saveConflict: ProjectSaveConflict?
    @Published private(set) var hasUnsavedChanges = false
    @Published var notice: String?
    @Published var selectedSolids: Set<Int> = [] {
        didSet { if selectedSolids != oldValue { refreshMeasurements() } }
    }
    @Published private(set) var selectedFeatures: [CADFeatureID] = [] {
        didSet { if selectedFeatures != oldValue { refreshMeasurements() } }
    }
    @Published private(set) var measurementReport: CADMeasurementReport?
    @Published private(set) var assemblyPose: AssemblyPose?
    @Published private(set) var isSolvingAssembly = false
    @Published private(set) var assemblyMotionError: String?
    @Published private(set) var isGrabbingAssembly = false
    private var assemblyMotionTask: Task<Void, Never>?
    private var assemblyMotionToken = UUID()
    private var requestedJointPositions: [String: Double] = [:]
    private final class AssemblyGrabSession {
        let ownerID: UUID
        let revisionID: UUID
        let projectSessionID: UUID
        let geometryToken: UUID
        let solidIndex: Int
        let context: AssemblyGrabContext
        var pendingTarget: [Double]?
        var lastTarget: [Double]?
        var ended = false

        init(ownerID: UUID, revisionID: UUID, projectSessionID: UUID, geometryToken: UUID,
             solidIndex: Int, context: AssemblyGrabContext) {
            self.ownerID = ownerID; self.revisionID = revisionID; self.projectSessionID = projectSessionID
            self.geometryToken = geometryToken; self.solidIndex = solidIndex; self.context = context
        }
    }
    private var assemblyGrabSession: AssemblyGrabSession?
    private var assemblyGrabTask: Task<Void, Never>?
    private let assemblyGrabSolver: @Sendable (AssemblyGrabContext, [String: Double], [Double]) async throws -> AssemblyPose
    @Published private(set) var measurementError: String?
    @Published private(set) var isMeasuring = false
    @Published var selectedPartNodeIDs: Set<String> = []
    @Published var hiddenSolids: Set<Int> = [] {
        didSet {
            if hiddenSolids != oldValue {
                if let grabbed = assemblyGrabSession?.solidIndex, hiddenSolids.contains(grabbed) { cancelAssemblyGrab() }
                agentStateGeneration &+= 1; scheduleProjectThumbnail()
            }
        }
    }
    @Published var pendingAttachments: [SourceAttachment] = [] {
        didSet { if pendingAttachments != oldValue { scheduleDebouncedAutosave() } }
    }
    var onOpenProject: ((URL) -> Void)?
    var onRecentProjectChanged: ((URL, URL?) -> Void)?
    var onProjectAgentInvalidated: (() -> Void)?
    private var agentStateGeneration: UInt64 = 0
    var awaitingResponse: Bool {
        !isWorking && messages.last(where: { $0.role == "assistant" && $0.phase != "commentary" })?.phase == "response"
    }
    var submissionWillQueue: Bool {
        isWorking || isSendingQueuedRequestID != nil || (!queuedRequests.isEmpty && !awaitingResponse)
    }
    private let codex = CodexService()
    private let engine = EngineService()
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var generationFeedback: CodexConversationFeedback?
    private var activeTaskAuditID: UUID?
    private var auditSaveTask: Task<Void, Never>?
    private var autosaveDebounceTask: Task<Void, Never>?
    private var steeringTask: Task<Void, Never>?
    private var queueSourceTasks: [UUID: Task<Void, Never>] = [:]
    private var queueSourceTokens: [UUID: UUID] = [:]
    private var queueCanAdvance = false
    private var steeringAvailable = false
    private struct QueuedRequestComposerDraft {
        var prompt: String
        var attachments: [SourceAttachment]
        var codexSettings: CodexProjectSettings
    }
    private var queuedRequestComposerDraft: QueuedRequestComposerDraft?
    private var queuedEditorInitialAttachments: [SourceAttachment] = []
    private var queuedEditorReferenceTargets: [String: String] = [:]
    private var queuedAttachmentTask: Task<Void, Never>?
    private var queuedAttachmentToken = UUID()
    private var promptAttachmentReads: [PromptAttachmentInput] = []
    private var loaded = false
    private var projectReady = false
    private var projectSavingEnabled = false
    private var pendingProjectRename = false
    private var builtRevisionID: UUID? {
        didSet { if builtRevisionID != oldValue { scheduleProjectThumbnail() } }
    }
    private var projectSessionID = UUID()
    private var projectID = UUID()
    private var autosavedProjectURL: URL?
    private var projectFileOrigin: ProjectFileOrigin?
    private var projectThumbnailTask: Task<Void, Never>?
    private var projectThumbnailToken = UUID()
    private var projectThumbnailInput: ProjectThumbnail.Input?
    private var projectThumbnailData: Data?
    private var projectThumbnailMeshModel: ModelSpec?
    private var projectThumbnailRevisionGeneration: UInt64 = 0
    private struct ProjectThumbnailPresentation: Equatable {
        var revisionID: UUID
        var generation: UInt64
        var validationHash: String?
        var projection: ViewportProjectionMode
        var display: ViewportDisplayMode
        var hiddenSolids: Set<Int>
    }
    private var projectThumbnailImagePresentation: ProjectThumbnailPresentation?
    private struct ProjectThumbnailInputKey: Equatable {
        var presentation: ProjectThumbnailPresentation
        var geometryPath: String
        var nativePath: String?
    }
    private var projectThumbnailInputKey: ProjectThumbnailInputKey?
    private var projectThumbnailCachedInput: ProjectThumbnail.Input?
    struct ProjectThumbnailWork {
        var inputResolutions = 0
        var scheduledRenders = 0
        var renders = 0
        var reusedImages = 0
    }
    private(set) var projectThumbnailWork = ProjectThumbnailWork()
    private let projectThumbnailRenderer: @MainActor (PreviewMesh, ProjectThumbnail.Input) async throws -> Data
    private var saveConflictPromptTask: Task<Void, Never>?
    private var presentedSaveConflict: ProjectSaveConflict?
    private var autosaveSequence = 0
    private var preserveUnreadableSession = false
    private let autosaveStore: ProjectAutosaveStore
    private let runtimeOverride: String?
    private var isActiveProject = false
    private var lastNotedRecentURL: URL?
    private var lastRememberedProjectURL: URL?
    private var measurementTask: Task<Void, Never>?
    private var measurementToken = UUID()
    private struct MeasurementKey: Hashable {
        var previewPath: String
        var brepPath: String?
        var features: [CADFeatureID]
        var solids: [Int]
        var transforms: [AssemblySolidTransform]
    }
    private var measurementCache: [MeasurementKey: CADMeasurementReport] = [:]

    init(autosaveStore: ProjectAutosaveStore = ProjectAutosaveStore(), python: String? = nil,
         thumbnailRenderer: @escaping @MainActor (PreviewMesh, ProjectThumbnail.Input) async throws -> Data = { preview, input in
             try await ProjectThumbnail.render(preview: preview, projection: input.projection, display: input.display,
                                               hiddenSolids: input.hiddenSolids, solidColors: input.solidColors)
         },
         assemblyGrabSolver: @escaping @Sendable (AssemblyGrabContext, [String: Double], [Double]) async throws -> AssemblyPose = {
             try $0.solve(positions: $1, screenPoint: $2)
         }) {
        self.autosaveStore = autosaveStore
        runtimeOverride = python
        projectThumbnailRenderer = thumbnailRenderer
        self.assemblyGrabSolver = assemblyGrabSolver
    }

    private static let recentProjectPathKey = "lastAutosavedProjectPath"
    private static let recentProjectIDKey = "lastAutosavedProjectID"
    static var recentProjectURL: URL? {
        UserDefaults.standard.string(forKey: recentProjectPathKey).map { URL(fileURLWithPath: $0) }
    }

    var posedPreview: PreviewMesh? {
        guard var preview = mesh else { return nil }
        preview.assemblyPose = assemblyPose
        return preview
    }

    var current: ModelSpec? { revisions.first(where: { $0.id == selectedRevisionID })?.model }
    var title: String { projectName ?? revisions.last?.model.title ?? "Untitled design" }
    /// The header names the active file, including any collision suffix chosen
    /// by the store. Only an explicit pending rename shows a requested name;
    /// ordinary autosaves must keep the actual filename stable.
    var projectDisplayName: String {
        if !pendingProjectRename, let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        return title
    }
    var canRenameProject: Bool { projectReady && !preserveUnreadableSession }
    var projectEditingID: UUID { projectSessionID }
    var hasStartedProjectSession: Bool { loaded }
    var projectDocumentID: UUID { projectID }
    var partTree: [PartNode] {
        guard let revision = revisions.first(where: { $0.id == selectedRevisionID }) else { return [] }
        if let layout = revision.partLayout { return layout.nodes }
        if let parts = revision.parts { return parts }
        if let preview = revision.preview { return Self.defaultParts(for: preview) }
        return []
    }
    var solidColors: [Int: PartColor] {
        guard let revision = revisions.first(where: { $0.id == selectedRevisionID }) else { return [:] }
        return PartColorState.solidColors(in: partTree, overrides: revision.partColors ?? [:])
    }
    private var currentSolidCount: Int {
        guard let revision = revisions.first(where: { $0.id == selectedRevisionID }) else { return 0 }
        if let parts = revision.parts { return parts.flatMap { $0.allSolidIndices }.max().map { $0 + 1 } ?? 0 }
        return revision.preview?.solids ?? (partTree.flatMap { $0.allSolidIndices }.max().map { $0 + 1 } ?? 0)
    }
    var canExport: Bool { mesh != nil && builtRevisionID == selectedRevisionID && !isWorking && !isSolvingAssembly }
    var canManipulateAssembly: Bool {
        !isWorking && builtRevisionID == selectedRevisionID && mesh?.assemblyMotion != nil
    }
    var featureSelectedSolids: Set<Int> { Set(selectedFeatures.map(\.solidIndex)) }

    func setPartsPaneFraction(_ fraction: Double) {
        guard fraction.isFinite, (0...1).contains(fraction), fraction != partsPaneFraction else { return }
        partsPaneFraction = fraction
        scheduleDebouncedAutosave()
    }
    var selectedPartSolids: Set<Int> { selectedSolids.union(featureSelectedSolids) }
    var canExportSelectedParts: Bool { canExport && !selectedPartSolids.isEmpty }
    var hasMeasurementSelection: Bool { !selectedSolids.isEmpty || !selectedFeatures.isEmpty }
    var canSaveProject: Bool { projectReady && projectSavingEnabled && !preserveUnreadableSession }
    var canSaveNew: Bool { canSaveProject && !revisions.isEmpty && !isWorking }
    var python: String { runtimeOverride ?? EngineService.defaultPython }
    var executable: String { CodexService.configuredExecutable }
    var model: String { codexSettings.model }
    var reasoningEffort: CodexReasoningEffort {
        let effort = CodexReasoningEffort(rawValue: codexSettings.reasoningEffort) ?? .defaultConfiguration
        let catalog = CodexModelCatalog.shared
        guard effort != .defaultConfiguration, catalog.matches(executable: executable),
              let selected = CodexModelSelection.effectiveModel(id: model, models: catalog.models,
                                                                configuredModelID: catalog.configuredModelID),
              !selected.reasoningEfforts.contains(where: { $0.id == effort.rawValue }) else { return effort }
        // Catalog capabilities can change while LAD is running. Keep the
        // captured request pair valid even before the picker refreshes.
        let fallback = CodexModelSelection.normalizedEffort(effort.rawValue, for: selected) ?? ""
        return CodexReasoningEffort(rawValue: fallback) ?? .defaultConfiguration
    }
    var threads: Int { let count = UserDefaults.standard.integer(forKey: "workerThreads"); return count > 0 ? count : ProcessInfo.processInfo.activeProcessorCount }
    var isCodexInstalled: Bool { CodexService.resolveExecutable(executable) != nil }
    var activityStatus: String {
        guard let runningCodexSelection else { return activity }
        return "\(activity) · \(runningCodexSelection)"
    }

    func renameProject(to enteredName: String) throws {
        guard canRenameProject else { throw LADError.message("Open a design before renaming it.") }
        // A literal basename can itself end in .lad. Committing the unchanged
        // field must not strip that suffix as though it were a new extension.
        guard enteredName != projectDisplayName else { return }
        let name = try ProjectNaming.userName(enteredName)
        guard name != projectDisplayName else { return }
        pendingProjectRename = true
        projectName = name
        autosave()
    }

    func revisionName(for id: UUID) -> String {
        guard let index = revisions.firstIndex(where: { $0.id == id }) else { return "" }
        return revisions[index].name ?? "v\(index + 1)"
    }

    /// Naming is independent of history navigation and native CAD preparation.
    func renameRevision(id: UUID, to enteredName: String) throws {
        guard let index = revisions.firstIndex(where: { $0.id == id }) else {
            throw LADError.message("This design version no longer exists.")
        }
        let name = try ProjectRevisionNaming.userName(enteredName)
        guard revisions[index].name != name else { return }
        revisions[index].name = name
        autosave()
    }

    func selectCodexModel(_ id: String) {
        let selected = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.utf8.count <= 256,
              selected.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        var settings = codexSettings
        let catalog = CodexModelCatalog.shared
        settings.reasoningEffort = CodexModelSelection.selectModel(selected, currentModel: settings.model,
                                                                  currentEffort: settings.reasoningEffort,
                                                                  models: catalog.matches(executable: executable) ? catalog.models : [],
                                                                  configuredModelID: catalog.matches(executable: executable) ? catalog.configuredModelID : nil,
                                                                  preferences: &settings.reasoningByModel)
        settings.model = selected
        updateCodexSettings(normalizedCodexSettings(settings))
    }

    func selectCodexReasoningEffort(_ value: String) {
        guard CodexReasoningEffort(rawValue: value) != nil else { return }
        var settings = codexSettings
        settings.reasoningEffort = value
        settings = normalizedCodexSettings(settings)
        CodexModelSelection.rememberEffort(settings.reasoningEffort, for: settings.model,
                                           preferences: &settings.reasoningByModel)
        updateCodexSettings(settings)
    }

    func normalizeCodexSelection() {
        guard projectReady else { return }
        updateCodexSettings(normalizedCodexSettings(codexSettings))
    }

    private func updateCodexSettings(_ settings: CodexProjectSettings) {
        guard settings != codexSettings else { return }
        codexSettings = settings
        if projectReady { autosave() }
    }

    private func normalizedCodexSettings(_ settings: CodexProjectSettings) -> CodexProjectSettings {
        let catalog = CodexModelCatalog.shared
        guard catalog.matches(executable: executable), !catalog.isLoading else { return settings }
        return Self.normalizedCodexSettings(settings, models: catalog.models,
                                            configuredModelID: catalog.configuredModelID,
                                            configuredReasoningEffort: catalog.configuredReasoningEffort)
    }

    /// Resolve an initial CLI default once, then retain the project's explicit
    /// selection even if another file or the CLI configuration chooses differently.
    static func normalizedCodexSettings(_ original: CodexProjectSettings, models: [CodexModelDescriptor],
                                        configuredModelID: String?, configuredReasoningEffort: String?) -> CodexProjectSettings {
        var settings = original
        if settings.model.isEmpty {
            guard let initialModel = configuredModelID.flatMap({ $0.isEmpty ? nil : $0 }) ?? models.first(where: \.isDefault)?.id else { return settings }
            settings.model = initialModel
            if settings.reasoningEffort.isEmpty, let configuredReasoningEffort,
               CodexReasoningEffort(rawValue: configuredReasoningEffort) != nil {
                settings.reasoningEffort = configuredReasoningEffort
            }
        }
        if let selected = models.first(where: { $0.id == settings.model }) {
            settings.reasoningEffort = CodexModelSelection.normalizedEffort(settings.reasoningEffort, for: selected) ?? ""
        }
        CodexModelSelection.rememberEffort(settings.reasoningEffort, for: settings.model,
                                           preferences: &settings.reasoningByModel)
        return settings
    }

    func start(restoringRecent: Bool = true, opening url: URL? = nil, restoringProjectID: UUID? = nil) {
        guard !loaded else { return }; loaded = true
        if let url { openProject(url, restoringProjectID: restoringProjectID); return }
        if !restoringRecent { newProject(); return }
        let token = UUID()
        let recentURL = Self.recentProjectURL
        let recentID = UserDefaults.standard.string(forKey: Self.recentProjectIDKey).flatMap(UUID.init(uuidString:))
        operationID = token; isWorking = true; activity = "Restoring session…"
        operation = Task {
            do {
                let saved: LADProject
                let source: URL?
                if recentURL != nil || recentID != nil {
                    guard let restored = try await autosaveStore.restoreRecent(preferredURL: recentURL, projectID: recentID) else {
                        throw LADError.message("The last design could not be found. Open its .lad file to continue.")
                    }
                    saved = restored.project; source = restored.url
                } else if let restored = try await autosaveStore.restoreRecent(preferredURL: nil, projectID: nil) {
                    saved = restored.project; source = restored.url
                } else {
                    guard operationID == token else { return }
                    newProject()
                    return
                }
                guard operationID == token else { return }
                restore(saved)
                autosavedProjectURL = source; projectURL = source
                projectReady = true
                if let source { rememberAutosavedProject(source) }
                if !loadStoredRevision(), let model = current { buildExisting(model) }
                else if current == nil { isWorking = false; activity = "Ready"; operation = nil }
                if source == nil || saved.projectID == nil || saved.codexSettings != codexSettings { autosave() }
            } catch {
                guard operationID == token else { return }
                preserveUnreadableSession = true
                self.error = "The previous design could not be restored. Its file has been preserved. Open a design or start a new design.\n\n\(error.localizedDescription)"
                saveStatus = "Not saved: \(error.localizedDescription)"
                isWorking = false; activity = "Design could not be restored"; operation = nil
            }
        }
    }

    func prepareToQuit() async {
        onProjectAgentInvalidated?()
        await finishAssemblyMotion(cancelActiveGrab: true)
        cancel()
        cancelProjectThumbnail(clearImage: false)
        auditSaveTask?.cancel(); auditSaveTask = nil
        autosaveDebounceTask?.cancel(); autosaveDebounceTask = nil
        await waitForPromptAttachments()
        await waitForQueuedSources()
        do { try await flushProject() }
        catch { saveStatus = "Not saved: \(error.localizedDescription)" }
    }

    func flushForReplacement() async throws {
        onProjectAgentInvalidated?()
        await finishAssemblyMotion(cancelActiveGrab: true)
        let wasGenerating = generationFeedback != nil
        cancel()
        cancelProjectThumbnail(clearImage: false)
        autosaveDebounceTask?.cancel(); autosaveDebounceTask = nil
        await waitForPromptAttachments()
        await waitForQueuedSources()
        if wasGenerating {
            messages.append(ChatMessage(role: "system", content: "Generation canceled. The last validated design is still available."))
        }
        try await flushProject()
    }

    private func flushProject() async throws {
        await finishAssemblyMotion()
        guard canSaveProject else { return }
        if let saveConflict { throw saveConflict }
        autosaveSequence += 1
        let sequence = autosaveSequence, sessionID = projectSessionID
        hasUnsavedChanges = true
        let preferExactName = pendingProjectRename
        do {
            let url = try await autosaveStore.write(project: projectSnapshot(), projectID: projectID, title: autosaveTitle,
                                                   sequence: sequence, preferredURL: autosavedProjectURL,
                                                   preferExactName: preferExactName)
            guard projectSessionID == sessionID else { return }
            autosavedProjectURL = url
            rememberAutosavedProject(url)
            if sequence == autosaveSequence {
                if projectURL != url { projectURL = url }
                pendingProjectRename = false
                hasUnsavedChanges = false
                saveStatus = nil
            }
        } catch {
            if projectSessionID == sessionID, autosaveSequence == sequence {
                recordSaveFailure(error)
            }
            throw error
        }
    }

    /// A quit-time recovery copy preserves the complete design. Unlike the
    /// ordinary Save As action, it is awaited and does not retry cloud autosave.
    func saveProjectForQuit(to url: URL) async throws {
        await finishAssemblyMotion(cancelActiveGrab: true)
        guard canSaveProject else { return }
        autosaveDebounceTask?.cancel(); autosaveDebounceTask = nil
        let sequence = autosaveSequence, sessionID = projectSessionID
        do {
            let origin = try await autosaveStore.writeCopy(projectSnapshot(), to: url)
            onRecentProjectChanged?(url, nil)
            if projectSessionID == sessionID, autosaveSequence == sequence {
                projectFileOrigin = origin
                autosavedProjectURL = url
                if projectURL != url { projectURL = url }
                pendingProjectRename = false
                hasUnsavedChanges = false
                saveStatus = nil
            }
        } catch {
            if projectSessionID == sessionID, autosaveSequence == sequence {
                saveStatus = "Not saved: \(error.localizedDescription)"
            }
            throw error
        }
    }

    func stopGeneration() {
        cancel()
        messages.append(ChatMessage(role: "system", content: "Generation canceled. The last validated design is still available."))
        activity = "Canceled"; autosave()
    }

    func newProject() {
        onProjectAgentInvalidated?()
        cancel()
        cancelProjectThumbnail()
        activityImages.reset()
        projectReady = false
        projectSavingEnabled = false
        saveConflict = nil
        presentedSaveConflict = nil
        saveConflictPromptTask?.cancel(); saveConflictPromptTask = nil
        projectFileOrigin = nil
        projectSessionID = UUID()
        projectID = UUID()
        autosavedProjectURL = nil
        lastNotedRecentURL = nil
        lastRememberedProjectURL = nil
        measurementCache = [:]
        preserveUnreadableSession = false
        projectURL = nil
        saveStatus = nil
        hasUnsavedChanges = false
        pendingProjectRename = false
        projectName = nil
        recentPartColors = []
        partsPaneFraction = 0.75
        showGrid = true
        projectionMode = .perspective
        displayMode = .edges
        codexSettings = normalizedCodexSettings(CodexProjectSettings())
        messages = []; revisions = []; selectedRevisionID = nil
        auditSaveTask?.cancel(); auditSaveTask = nil
        taskAudits = []; activeTaskAuditID = nil
        resetQueueWork()
        queuedRequests = []; queuePaused = false
        mesh = nil; builtRevisionID = nil; prompt = ""; error = nil; notice = nil; pendingAttachments = []
        viewportCommand = nil
        selectedSolids = []; selectedPartNodeIDs = []; hiddenSolids = []
        projectReady = true
    }

    func submit() {
        guard !isReadingPromptAttachments else { return }
        if editingQueuedRequestID != nil {
            commitEditingQueuedRequest()
            return
        }
        let enteredText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard enteredText.utf8.count <= 1_000_000 else {
            error = "The request exceeds the design file's 1 MB message limit."; return
        }
        let enqueue = submissionWillQueue
        guard !enqueue || queuedRequests.count < 10_000 else {
            error = "The design already contains the maximum number of queued requests."; return
        }
        normalizeCodexSelection()
        var settings = codexSettings
        settings.reasoningEffort = reasoningEffort.rawValue
        let selection = capturedRequestSelection()
        do { try selection?.validate() }
        catch { self.error = error.localizedDescription; return }
        let request = ProjectQueuedRequest(content: enteredText, attachments: pendingAttachments.isEmpty ? nil : pendingAttachments,
                                           codexSettings: settings, selection: selection)
        // A submitted request starts persistence, even if it is later canceled
        // or fails. Drafts and settings alone must not create an empty file.
        projectSavingEnabled = true
        prompt = ""; pendingAttachments = []
        if enqueue {
            queuedRequests.append(request)
            if generationFeedback == nil { queueCanAdvance = true }
            prepareQueuedSources(for: request.id)
            autosave()
            drainQueueIfPossible()
        } else {
            queuePaused = false
            startRequest(request)
        }
    }

    private func capturedRequestSelection() -> ProjectSelectionContext? {
        guard let revisionID = selectedRevisionID else { return nil }
        return ProjectSelectionContext.capture(revisionID: revisionID, preview: mesh, nodes: partTree,
            selectedSolids: selectedSolids, selectedNodeIDs: selectedPartNodeIDs, selectedFeatures: selectedFeatures,
            assemblyPose: assemblyPose)
    }

    func editQueuedRequest(id: UUID, text: String) {
        guard text.utf8.count <= 1_000_000 else {
            error = "The request exceeds the design file's 1 MB message limit."; return
        }
        guard id != isSendingQueuedRequestID, let index = queuedRequests.firstIndex(where: { $0.id == id }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(queuedRequests[index].attachments ?? []).isEmpty else { return }
        queuedRequests[index].content = text
        prepareQueuedSources(for: id)
        autosave()
    }

    var canBeginEditingQueuedRequests: Bool { !isReadingDraftAttachments }

    var canCommitQueuedRequest: Bool {
        guard let id = editingQueuedRequestID, id != isSendingQueuedRequestID,
              queuedRequests.contains(where: { $0.id == id }), !isReadingQueuedAttachments else { return false }
        return prompt.utf8.count <= 1_000_000 &&
            (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    func beginEditingQueuedRequest(id: UUID) {
        guard canBeginEditingQueuedRequests, id != isSendingQueuedRequestID,
              let request = queuedRequests.first(where: { $0.id == id }), editingQueuedRequestID != id else { return }
        if queuedRequestComposerDraft == nil {
            queuedRequestComposerDraft = QueuedRequestComposerDraft(prompt: prompt, attachments: pendingAttachments,
                                                                   codexSettings: codexSettings)
        }
        cancelQueuedAttachmentRead()
        editingQueuedRequestID = id
        queuedEditorInitialAttachments = request.attachments ?? []
        queuedEditorReferenceTargets = Dictionary(SourceImport.referencedURLs(in: request.content).map {
            ($0.standardizedFileURL.path, $0.standardizedFileURL.resolvingSymlinksInPath().path)
        }, uniquingKeysWith: { first, _ in first })
        prompt = request.content
        pendingAttachments = queuedEditorInitialAttachments
        codexSettings = normalizedCodexSettings(request.codexSettings ?? queuedRequestComposerDraft!.codexSettings)
        refreshSteeringAvailability()
    }

    @discardableResult
    func commitEditingQueuedRequest() -> Bool {
        guard let id = editingQueuedRequestID, id != isSendingQueuedRequestID,
              !isReadingQueuedAttachments, let index = queuedRequests.firstIndex(where: { $0.id == id }) else { return false }
        guard prompt.utf8.count <= 1_000_000 else {
            error = "The request exceeds the design file's 1 MB message limit."; return false
        }
        guard canCommitQueuedRequest else { return false }
        normalizeCodexSelection()
        let latest = queuedRequests[index]
        let references = SourceImport.referencedURLs(in: prompt)
        let referencePaths = Set(references.map { $0.standardizedFileURL.path })
        let originalPaths = Set(SourceImport.referencedURLs(in: latest.content).map { $0.standardizedFileURL.path })
        let initialAttachmentPaths = Set(queuedEditorInitialAttachments.map(\.path))
        let referencedTargets = Set(references.map { reference in
            queuedEditorReferenceTargets[reference.standardizedFileURL.path] ?? reference.resolvingSymlinksInPath().path
        })
        // Source capture can finish after editing begins. Retain those exact
        // snapshots for unchanged references instead of rereading their files.
        let lateAttachments = (latest.attachments ?? []).filter {
            !initialAttachmentPaths.contains($0.path) &&
                (referencePaths == originalPaths || referencedTargets.contains($0.path))
        }
        let attachments: [SourceAttachment]
        do { attachments = try Self.mergedSources(lateAttachments, pendingAttachments) }
        catch { self.error = error.localizedDescription; return false }
        let attachmentPaths = Set(attachments.map(\.path))
        let allOriginalAttachmentsRetained = (latest.attachments ?? []).allSatisfy { attachmentPaths.contains($0.path) }
        let verified = (latest.capturedSourcePaths ?? []).filter { path in
            guard referencePaths.contains(path) else { return false }
            return allOriginalAttachmentsRetained || attachmentPaths.contains(queuedEditorReferenceTargets[path] ?? path)
        }
        var settings = codexSettings
        settings.reasoningEffort = reasoningEffort.rawValue
        queuedRequests[index].content = prompt
        queuedRequests[index].attachments = attachments.isEmpty ? nil : attachments
        queuedRequests[index].codexSettings = settings
        queuedRequests[index].capturedSourcePaths = verified.isEmpty ? nil : verified
        prepareQueuedSources(for: id)
        restoreQueuedRequestComposerDraft()
        refreshSteeringAvailability()
        autosave()
        drainQueueIfPossible()
        return true
    }

    func cancelEditingQueuedRequest() {
        guard editingQueuedRequestID != nil else { return }
        restoreQueuedRequestComposerDraft()
        refreshSteeringAvailability()
        autosave()
        drainQueueIfPossible()
    }

    func endEditingQueuedRequest(id: UUID) {
        guard editingQueuedRequestID == id else { return }
        cancelEditingQueuedRequest()
    }

    private func restoreQueuedRequestComposerDraft() {
        cancelQueuedAttachmentRead()
        let draft = queuedRequestComposerDraft
        queuedRequestComposerDraft = nil
        editingQueuedRequestID = nil
        queuedEditorInitialAttachments = []
        queuedEditorReferenceTargets = [:]
        if let draft {
            prompt = draft.prompt
            pendingAttachments = draft.attachments
            codexSettings = draft.codexSettings
        }
    }

    func removeQueuedRequest(id: UUID) {
        guard id != isSendingQueuedRequestID else { return }
        queueSourceTasks.removeValue(forKey: id)?.cancel()
        queueSourceTokens.removeValue(forKey: id)
        preparingQueuedRequestIDs.remove(id)
        queuedRequestErrors.removeValue(forKey: id)
        queuedRequests.removeAll { $0.id == id }
        if editingQueuedRequestID == id { restoreQueuedRequestComposerDraft() }
        refreshSteeringAvailability()
        autosave()
        drainQueueIfPossible()
    }

    func moveQueuedRequest(id: UUID, beforeID: UUID?) {
        guard id != beforeID, id != isSendingQueuedRequestID,
              let index = queuedRequests.firstIndex(where: { $0.id == id }),
              beforeID == nil || queuedRequests.contains(where: { $0.id == beforeID }) else { return }
        let request = queuedRequests.remove(at: index)
        let target = beforeID.flatMap { targetID in queuedRequests.firstIndex(where: { $0.id == targetID }) } ?? queuedRequests.endIndex
        queuedRequests.insert(request, at: target)
        autosave()
    }

    func resumeQueue() {
        guard !queuedRequests.isEmpty else { return }
        queuePaused = false
        queuePauseReason = nil
        queueCanAdvance = true
        autosave()
        drainQueueIfPossible()
    }

    func sendQueuedRequestNow(id: UUID) {
        guard canSteerQueuedRequests, codex.canSteer, !preparingQueuedRequestIDs.contains(id),
              let request = queuedRequests.first(where: { $0.id == id }), let auditID = activeTaskAuditID else { return }
        let token = operationID, session = projectSessionID
        isSendingQueuedRequestID = id
        refreshSteeringAvailability()
        steeringTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Use the attached source files as additional information for the current design request." : request.content
                let origin = request.selection.flatMap { selection in self.revisions.first { $0.id == selection.revisionID }?.model }
                let turn = try await self.codex.steer(prompt: content, attachments: request.attachments ?? [],
                                                      selection: request.selection, selectionModel: origin)
                guard self.projectSessionID == session, self.operationID == token, self.isSendingQueuedRequestID == id else { return }
                // Keep the item in the queue until this acknowledgement. A
                // final result may arrive while the steering RPC is in flight.
                let message = ChatMessage(role: "user", content: content, date: request.date, attachments: request.attachments,
                                          selection: request.selection)
                if let audit = self.taskAudits.first(where: { $0.id == auditID }), let userMessageID = audit.userMessageID,
                   let revision = self.revisions.last(where: { $0.userMessageID == userMessageID }),
                   let responseID = revision.responseMessageID,
                   let responseIndex = self.messages.firstIndex(where: { $0.id == responseID }) {
                    self.messages.insert(message, at: responseIndex)
                } else { self.messages.append(message) }
                if let index = self.taskAudits.firstIndex(where: { $0.id == auditID }) {
                    self.taskAudits[index].additionalUserMessageIDs = (self.taskAudits[index].additionalUserMessageIDs ?? []) + [message.id]
                    self.taskAudits[index].events.append(ProjectActivityEvent(id: "steer:\(id.uuidString)", category: "steering",
                        title: "Additional design information sent", status: "completed", input: content,
                        output: "Accepted by task turn \(turn)."))
                }
                self.queuedRequests.removeAll { $0.id == id }
                self.queuedRequestErrors.removeValue(forKey: id)
                self.isSendingQueuedRequestID = nil
                self.steeringTask = nil
                self.refreshSteeringAvailability()
                self.autosave()
                self.drainQueueIfPossible()
            } catch {
                guard self.projectSessionID == session, self.operationID == token, self.isSendingQueuedRequestID == id else { return }
                self.isSendingQueuedRequestID = nil
                self.steeringTask = nil
                self.refreshSteeringAvailability()
                // A failed RPC can have an uncertain delivery outcome. Do
                // not automatically replay information Codex may have received.
                self.queuePaused = true
                let diagnostic = "Delivery to the running task could not be confirmed. The request remains queued; review the result before resuming.\n\n\(error.localizedDescription)"
                self.queuedRequestErrors[id] = diagnostic
                self.queuePauseReason = diagnostic
                self.error = diagnostic
                self.autosave()
                self.drainQueueIfPossible()
            }
        }
    }

    private func setSteeringAvailable(_ available: Bool) {
        steeringAvailable = available
        refreshSteeringAvailability()
    }

    private func refreshSteeringAvailability() {
        canSteerQueuedRequests = steeringAvailable && isWorking && generationFeedback != nil &&
            isSendingQueuedRequestID == nil && editingQueuedRequestID == nil
    }

    private func prepareQueuedSources(for id: UUID) {
        queueSourceTasks.removeValue(forKey: id)?.cancel()
        queueSourceTokens.removeValue(forKey: id)
        preparingQueuedRequestIDs.remove(id)
        guard let request = queuedRequests.first(where: { $0.id == id }) else { return }
        let captured = request.attachments ?? []
        let references = SourceImport.referencedURLs(in: request.content)
        let urls = unpreparedSourceURLs(for: request)
        let missingPaths = Set(urls.map { $0.standardizedFileURL.path })
        let verified = Self.uniqueReferencePaths(references.filter { !missingPaths.contains($0.standardizedFileURL.path) })
        if let index = queuedRequests.firstIndex(where: { $0.id == id }) {
            queuedRequests[index].capturedSourcePaths = verified.isEmpty ? nil : verified
        }
        guard !urls.isEmpty else {
            queuedRequestErrors.removeValue(forKey: id)
            return
        }
        let token = UUID(), session = projectSessionID
        queueSourceTokens[id] = token
        preparingQueuedRequestIDs.insert(id)
        queueSourceTasks[id] = Task { [weak self] in
            do {
                let read = try await Task.detached(priority: .userInitiated) { try SourceImport.load(urls: urls) }.value
                guard let self, self.projectSessionID == session, self.queueSourceTokens[id] == token,
                      let index = self.queuedRequests.firstIndex(where: { $0.id == id }) else { return }
                self.queuedRequests[index].attachments = try Self.mergedSources(captured, read)
                self.queuedRequests[index].capturedSourcePaths = Self.uniqueReferencePaths(references)
                self.finishQueuedSourcePreparation(id: id)
                self.queuedRequestErrors.removeValue(forKey: id)
                self.autosave()
                self.drainQueueIfPossible()
            } catch {
                guard let self, self.projectSessionID == session, self.queueSourceTokens[id] == token else { return }
                self.finishQueuedSourcePreparation(id: id)
                self.queuePaused = true
                let diagnostic = "A queued request's source files could not be prepared. The request remains queued.\n\n\(error.localizedDescription)"
                self.queuedRequestErrors[id] = diagnostic
                self.queuePauseReason = diagnostic
                self.error = diagnostic
                self.autosave()
            }
        }
    }

    private func finishQueuedSourcePreparation(id: UUID) {
        queueSourceTasks.removeValue(forKey: id)
        queueSourceTokens.removeValue(forKey: id)
        preparingQueuedRequestIDs.remove(id)
    }

    private func drainQueueIfPossible() {
        guard queueCanAdvance, !queuePaused, !isWorking, isSendingQueuedRequestID == nil,
              editingQueuedRequestID == nil, let first = queuedRequests.first,
              !preparingQueuedRequestIDs.contains(first.id) else { return }
        if !unpreparedSourceURLs(for: first).isEmpty { prepareQueuedSources(for: first.id); return }
        queuedRequests.removeFirst()
        queuedRequestErrors.removeValue(forKey: first.id)
        // startRequest saves the queue removal together with the sent user
        // message and audit. Never persist an intermediate handoff that could
        // lose the request from both pending work and conversation history.
        startRequest(first)
    }

    private func unpreparedSourceURLs(for request: ProjectQueuedRequest) -> [URL] {
        let verifiedReferences = Set(request.capturedSourcePaths ?? [])
        let capturedFiles = Set((request.attachments ?? []).map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path
        })
        return SourceImport.referencedURLs(in: request.content).filter { url in
            guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return true }
            // Exact original references remain authoritative even if a file
            // alias was removed or now points at different source bytes.
            if verifiedReferences.contains(url.standardizedFileURL.path) { return false }
            return !capturedFiles.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }

    private static func uniqueReferencePaths(_ urls: [URL]) -> [String] {
        var seen = Set<String>()
        return urls.map { $0.standardizedFileURL.path }.filter { seen.insert($0).inserted }
    }

    private func scheduleDebouncedAutosave() {
        guard canSaveProject else { return }
        // Invalidate older in-flight writes immediately, and coalesce typing
        // or divider dragging before serializing the complete project.
        autosaveSequence += 1
        hasUnsavedChanges = true
        autosaveDebounceTask?.cancel()
        let session = projectSessionID
        autosaveDebounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, self.projectSessionID == session, !Task.isCancelled else { return }
            self.autosaveDebounceTask = nil
            self.autosave()
        }
    }

    private func scheduleQueueAfterBusyOperation() {
        guard queueCanAdvance, !queuePaused, !queuedRequests.isEmpty else { return }
        let session = projectSessionID
        Task { [weak self] in
            await Task.yield()
            guard let self, self.projectSessionID == session, !self.isWorking, !self.queuePaused else { return }
            if let error = self.error {
                self.queuePaused = true
                self.queuePauseReason = error
                self.autosave()
            } else { self.drainQueueIfPossible() }
        }
    }

    private func resetQueueWork() {
        autosaveDebounceTask?.cancel(); autosaveDebounceTask = nil
        steeringTask?.cancel(); steeringTask = nil
        for task in queueSourceTasks.values { task.cancel() }
        queueSourceTasks.removeAll(); queueSourceTokens.removeAll(); preparingQueuedRequestIDs = []
        isSendingQueuedRequestID = nil; editingQueuedRequestID = nil
        cancelQueuedAttachmentRead()
        queuedRequestComposerDraft = nil
        queuedEditorInitialAttachments = []
        queuedEditorReferenceTargets = [:]
        isReadingDraftAttachments = false
        queuedRequestErrors = [:]; queuePauseReason = nil
        queueCanAdvance = false
        setSteeringAvailable(false)
    }

    private func waitForQueuedSources() async {
        for task in Array(queueSourceTasks.values) { await task.value }
    }

    private func startRequest(_ request: ProjectQueuedRequest) {
        guard !isWorking else { return }
        queueCanAdvance = false
        setSteeringAvailable(false)
        let hasImages = (request.attachments ?? []).contains(where: \.isImage)
        let fallback = hasImages
            ? "Create or refine the design using the attached image references and any attached source files. Explain any dimensional assumptions."
            : "Import the attached source design as faithfully as possible. Explain any unsupported features; do not substitute another design."
        let text = request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : request.content
        let previous = current
        let previousLayout = selectedPartLayout
        let previouslyHidden = hiddenPartIDs
        let sourceRevisionID = selectedRevisionID
        let previousColors = Self.completePartColors(in: previousLayout.nodes,
            stored: revisions.first(where: { $0.id == sourceRevisionID })?.partColors ?? [:])
        let previousPreview = posedPreview
        let previousSolidColors = PartColorState.solidColors(in: previousLayout.nodes, overrides: previousColors)
        let previousHiddenSolids = hiddenSolids
        let versions = ProjectVersionContext(revisions: revisions, selectedRevisionID: selectedRevisionID)
        let selectionModels = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0.model) })
        let selectionModel = request.selection.flatMap { selectionModels[$0.revisionID] }
        let history = messages
        let attached = request.attachments ?? []
        let userMessage = ChatMessage(role: "user", content: text, attachments: attached.isEmpty ? nil : attached,
                                      selection: request.selection)
        messages.append(userMessage)
        error = nil; notice = nil; isWorking = true; activity = "Designing…"
        let token = UUID(); operationID = token
        let feedback = CodexConversationFeedback()
        generationFeedback = feedback
        let settings = request.codexSettings ?? codexSettings
        let path = executable, modelName = settings.model, runtime = python, cores = threads
        let effort = CodexReasoningEffort(rawValue: settings.reasoningEffort) ?? .defaultConfiguration
        let catalog = CodexModelCatalog.shared
        let modelStatus = CodexModelSelection.statusLabel(modelID: modelName, effort: effort,
                                                          models: catalog.matches(executable: path) ? catalog.models : [],
                                                          configuredModelID: catalog.matches(executable: path) ? catalog.configuredModelID : nil,
                                                          configuredReasoningEffort: catalog.matches(executable: path) ? catalog.configuredReasoningEffort : nil)
        let audit = ProjectTaskAudit(userMessageID: userMessage.id, model: modelName, reasoningEffort: effort.rawValue)
        taskAudits.append(audit)
        activeTaskAuditID = audit.id
        autosave()
        operation = Task { [self] in
            let progress: @Sendable (String) -> Void = { [weak self] status in
                feedback.enqueueActivity(status)
                Task { @MainActor in
                    self?.drainGenerationFeedback(feedback, token: token)
                }
            }
            let commentary: @Sendable (String, CodexProgressMessage) -> Void = { [weak self] scope, message in
                feedback.enqueue(message, scope: scope)
                Task { @MainActor in
                    self?.drainGenerationFeedback(feedback, token: token)
                }
            }
            let toolActivity: @Sendable (String, ProjectActivityEvent) -> Void = { [weak self] scope, event in
                feedback.enqueue(event, scope: scope)
                Task { @MainActor in self?.drainGenerationFeedback(feedback, token: token) }
            }
            func briefDiagnostic(_ failure: Error) -> String {
                EngineFailureDiagnostic.repairText(for: failure)
            }
            do {
                activity = "Reading referenced source files…"
                runningCodexSelection = modelStatus
                // Snapshot only explicit source-file references. The agent
                // chooses whether to inspect directories or invoke a converter.
                let sourceURLs = unpreparedSourceURLs(for: request)
                let read = try await Task.detached(priority: .userInitiated) { try SourceImport.load(urls: sourceURLs) }.value
                guard operationID == token else { return }
                try Task.checkCancellation()
                let sources = try Self.mergedSources(attached, read)
                if let index = messages.firstIndex(where: { $0.id == userMessage.id }) {
                    messages[index].attachments = sources.isEmpty ? nil : sources
                }
                autosave()
                guard isCodexInstalled else { throw LADError.message(CodexExecutable.setupMessage) }
                let result = try await codex.generate(prompt: text, current: previous, history: history, attachments: sources, partLayout: previousLayout, partColors: previousColors,
                                                    executable: path, model: modelName, reasoningEffort: effort, onProgress: progress,
                                                    onMessage: { commentary("project", $0) }, onActivity: { toolActivity("project", $0) },
                                                    python: runtime, threads: cores, engine: engine, currentPreview: previousPreview,
                                                    viewport: viewportView, hiddenSolids: previousHiddenSolids, solidColors: previousSolidColors,
                                                    onSteeringAvailability: { [weak self] available in
                    Task { @MainActor in
                        guard let self, self.operationID == token else { return }
                        self.setSteeringAvailable(available)
                    }
                }, selection: request.selection, selectionModel: selectionModel, selectionModelsByRevision: selectionModels, versions: versions)
                guard operationID == token else { return }
                drainGenerationFeedback(feedback, token: token)
                try Task.checkCancellation()
                var spec: ModelSpec
                switch result {
                case .ready(let project): spec = project
                case .response(let message):
                    try applyAgentPartColorChanges(codex.partColorChanges, to: sourceRevisionID,
                                                  matching: previous, startedWith: previousColors)
                    finishConversationResponse(message)
                    return
                }
                activity = "Building solid geometry…"
                var preview: PreviewMesh
                do {
                    if let validated = codex.validatedPreview(for: spec) {
                        preview = validated
                        recordTaskEvent(ProjectActivityEvent(id: "final:validation", category: "validation",
                            title: "Final design matches validated CAD geometry", status: "completed",
                            output: "Reused the geometry built through LAD tools; no additional program replay was needed."))
                    } else {
                        recordTaskEvent(ProjectActivityEvent(id: "final:validation", category: "validation",
                            title: "Validate final CAD program", status: "running"))
                        preview = try await engine.buildPreview(spec, python: runtime, threads: cores)
                        recordTaskEvent(ProjectActivityEvent(id: "final:validation", category: "validation",
                            title: "Validate final CAD program", status: "completed",
                            output: "\(preview.solids) valid solids; \(preview.faces) faces; volume \(preview.volume) mm³."))
                    }
                    guard operationID == token else { return }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard operationID == token else { return }
                    try Task.checkCancellation()
                    let description = error.localizedDescription
                    let lower = description.lowercased()
                    let runtimeErrors = ["no module named", "missing dependencies", "runtime not found", "engine missing", "dlopen", "library not loaded", "symbol not found", "incompatible architecture", "bad cpu type", "permission denied", "operation not permitted", "no such file or directory", "thread count must"]
                    guard description.hasPrefix("The CAD engine could not build this design."),
                          description.contains("LAD CAD engine:"),
                          !runtimeErrors.contains(where: lower.contains) else { throw error }
                    let diagnostic = briefDiagnostic(error)
                    recordTaskEvent(ProjectActivityEvent(id: "final:validation", category: "validation",
                        title: "Final CAD validation failed", status: "failed", output: description))
                    messages.append(ChatMessage(role: "system", content: "CAD validation failed: \(diagnostic)\nRepairing the design (one attempt)."))
                    activity = "Repairing the geometry…"
                    autosave()
                    let repairRequest = """
                    Repair the current design for the original request below. The CAD engine rejected its CadQuery program.

                    Original request: \(text)
                    CAD validation error: \(diagnostic)

                    Preserve the intended shape and dimensions. Fix or simplify the failing operations and return the complete replacement design.
                    """
                    let repairResult = try await codex.generate(prompt: repairRequest, current: spec, history: messages, attachments: sources, partLayout: previousLayout, partColors: previousColors,
                                                     executable: path, model: modelName, reasoningEffort: effort, onProgress: progress,
                                                     onMessage: { commentary("repair", $0) }, onActivity: { toolActivity("repair", $0) },
                                                     python: runtime, threads: cores, engine: engine, viewport: viewportView,
                                                     hiddenSolids: previousHiddenSolids, solidColors: previousSolidColors,
                                                     onSteeringAvailability: { [weak self] available in
                        Task { @MainActor in
                            guard let self, self.operationID == token else { return }
                            self.setSteeringAvailable(available)
                        }
                    }, selection: request.selection, selectionModel: selectionModel, selectionModelsByRevision: selectionModels, versions: versions)
                    guard operationID == token else { return }
                    drainGenerationFeedback(feedback, token: token)
                    try Task.checkCancellation()
                    switch repairResult {
                    case .ready(let project): spec = project
                    case .response(let message):
                        try applyAgentPartColorChanges(codex.partColorChanges, to: sourceRevisionID,
                                                      matching: previous, startedWith: previousColors)
                        finishConversationResponse(message)
                        return
                    }
                    activity = "Validating the repaired geometry…"
                    if let validated = codex.validatedPreview(for: spec) { preview = validated }
                    else { preview = try await engine.buildPreview(spec, python: runtime, threads: cores) }
                    guard operationID == token else { return }
                    try Task.checkCancellation()
                    messages.append(ChatMessage(role: "system", content: "CAD repair passed solid geometry validation."))
                    recordTaskEvent(ProjectActivityEvent(id: "repair:validation", category: "validation",
                        title: "Repaired design passed CAD validation", status: "completed",
                        output: "\(preview.solids) valid solids; \(preview.faces) faces; volume \(preview.volume) mm³."))
                    autosave()
                }
                guard operationID == token else { return }
                try Task.checkCancellation()
                let sourceRevision = revisions.first(where: { $0.id == sourceRevisionID })
                if let previous, sourceRevision?.model != previous {
                    throw LADError.message("The original design version changed before the update could be applied.")
                }
                let liveLayout = sourceRevision?.partLayout ?? previousLayout
                let liveHidden = Set(sourceRevision?.hiddenSolids ?? [])
                let hiddenIDs = sourceRevision?.hiddenSolids == nil ? previouslyHidden : Set(liveLayout.nodes.flatMap(\.flattened).filter {
                    !$0.solidIndices.isEmpty && Set($0.solidIndices).isSubset(of: liveHidden)
                }.map(\.id))
                try commit(spec, preview: preview, previousLayout: liveLayout, previouslyHidden: hiddenIDs, userMessageID: userMessage.id,
                           previousColors: Self.completePartColors(in: liveLayout.nodes, stored: sourceRevision?.partColors ?? [:]),
                           colorChanges: codex.partColorChanges,
                           startedColors: previousColors)
            } catch is CancellationError {
                if operationID == token {
                    queuePaused = true; queueCanAdvance = false
                    setSteeringAvailable(false)
                    finishGenerationFeedback()
                    finishTaskAudit(status: "canceled")
                    messages.append(ChatMessage(role: "system", content: "Generation canceled. The last validated design is still available."))
                    isWorking = false; activity = "Canceled"; operation = nil
                    autosave()
                }
            } catch {
                guard operationID == token else { return }
                queuePaused = true; queueCanAdvance = false
                queuePauseReason = error.localizedDescription
                setSteeringAvailable(false)
                finishGenerationFeedback()
                recordTaskEvent(ProjectActivityEvent(id: "task:failure", category: "diagnostic",
                    title: "Design task failed", status: "failed", output: error.localizedDescription))
                finishTaskAudit(status: "failed")
                self.error = error.localizedDescription
                self.messages.append(ChatMessage(role: "system", content: "Design could not be completed: \(briefDiagnostic(error))"))
                self.activity = "Design needs attention"; self.isWorking = false; self.operation = nil
                self.autosave()
            }
        }
    }

    private func finishConversationResponse(_ response: String) {
        // A question or explanation completes the turn without replacing the
        // design. Keep pending work paused so the next composer submission can
        // answer this response before unrelated queued refinements continue.
        queuePaused = true; queueCanAdvance = false; queuePauseReason = nil
        setSteeringAvailable(false)
        finishGenerationFeedback()
        finishTaskAudit(status: "completed")
        messages.append(ChatMessage(role: "assistant", content: response, phase: "response"))
        error = nil; activity = "Ready"; isWorking = false; operation = nil
        autosave()
    }

    private func commit(_ spec: ModelSpec, preview: PreviewMesh, previousLayout: PartLayout? = nil, previouslyHidden: Set<String> = [], userMessageID: UUID, previousColors: [String: PartColor] = [:], colorChanges: [CADPartColorChange] = [], startedColors: [String: PartColor] = [:]) throws {
        let response = ChatMessage(role: "assistant", content: spec.summary + "\n\nDesign ready.", phase: "final_answer")
        _ = try appendValidatedRevision(spec, preview: preview, previousLayout: previousLayout,
            previouslyHidden: previouslyHidden, previousColors: previousColors, colorChanges: colorChanges,
            startedColors: startedColors, date: response.date, userMessageID: userMessageID, responseMessageID: response.id)
        finishGenerationFeedback()
        finishTaskAudit(status: "completed")
        messages.append(response)
        activity = "Ready"; isWorking = false; operation = nil; error = nil
        setSteeringAvailable(false)
        queueCanAdvance = true
        autosave()
        drainQueueIfPossible()
    }

    /// Both agent entry points publish through the same revision transaction.
    /// Callers own task completion; this operation never finishes another task.
    @discardableResult
    private func appendValidatedRevision(_ spec: ModelSpec, preview: PreviewMesh, previousLayout: PartLayout?,
        previouslyHidden: Set<String>, previousColors: [String: PartColor], colorChanges: [CADPartColorChange],
        startedColors: [String: PartColor], date: Date = Date(), userMessageID: UUID? = nil,
        responseMessageID: UUID? = nil) throws -> UUID {
        let defaults = Self.defaultParts(for: preview)
        let layout = previousLayout?.reconciled(with: defaults, allowingPlacementChanges: Set(spec.reorganizePartIDs ?? [])) ?? PartLayout(nodes: defaults)
        try ProjectStore.validatePartHierarchy(layout.nodes, solidCount: preview.solids)
        let colors = try Self.partColors(applying: colorChanges, in: layout.nodes,
                                        current: previousColors, startedWith: startedColors)
        let hidden = Set(layout.nodes.flatMap(\.flattened).filter { previouslyHidden.contains($0.id) }.flatMap(\.solidIndices))
        let revision = ProjectRevision(model: spec, date: date, preview: preview, partLayout: layout, hiddenSolids: hidden.sorted(), parts: defaults, runtime: preview.runtime,
                                      userMessageID: userMessageID, responseMessageID: responseMessageID,
                                      partColors: colors.isEmpty ? nil : colors, validatedHash: preview.validatedHash,
                                      jointPositions: preview.assemblyPose?.positions)
        revisions.append(revision)
        selectedRevisionID = revision.id; builtRevisionID = revision.id
        mesh = preview; selectedSolids = []; selectedPartNodeIDs = []; hiddenSolids = hidden
        viewportCommand = ViewportCommand(.fit)
        return revision.id
    }

    private func drainGenerationFeedback(_ feedback: CodexConversationFeedback, token: UUID) {
        guard operationID == token, generationFeedback === feedback else { return }
        let update = feedback.apply(to: &messages)
        if let latestActivity = update.activity { activity = latestActivity }
        for event in update.events { recordTaskEvent(event) }
    }

    private func finishGenerationFeedback() {
        runningCodexSelection = nil
        guard let feedback = generationFeedback else { return }
        let update = feedback.apply(to: &messages)
        for event in update.events { recordTaskEvent(event) }
        feedback.close()
        generationFeedback = nil
    }

    func recordTaskEvent(_ incoming: ProjectActivityEvent) {
        guard let id = activeTaskAuditID else { return }
        recordTaskEvent(incoming, taskID: id)
    }

    func recordTaskEvent(_ incoming: ProjectActivityEvent, taskID id: UUID) {
        guard let index = taskAudits.firstIndex(where: { $0.id == id }) else { return }
        if incoming.category == "tool", incoming.status == "completed",
           ["lad_render", "lad_screenshot", "imageView"].contains(incoming.title), let image = incoming.imageData {
            activityImages.store(image, for: ProjectActivityImageKey(taskID: id, eventID: incoming.id))
        }
        var event = incoming
        // Keep heavy derived media separate from persistent audit state.
        event.imageData = nil
        if let item = taskAudits[index].events.firstIndex(where: { $0.id == event.id }) {
            var updated = event
            let previous = taskAudits[index].events[item]
            updated.date = previous.date
            if updated.input == nil { updated.input = previous.input }
            if updated.output == nil { updated.output = previous.output }
            if updated.files == nil { updated.files = previous.files }
            taskAudits[index].events[item] = updated
        } else { taskAudits[index].events.append(event) }
        scheduleAuditSave()
    }

    private func finishTaskAudit(status: String) {
        guard let id = activeTaskAuditID, let index = taskAudits.firstIndex(where: { $0.id == id }) else { return }
        for event in taskAudits[index].events.indices where taskAudits[index].events[event].status == "running" {
            taskAudits[index].events[event].status = status == "completed" ? "interrupted" : status
        }
        taskAudits[index].status = status
        taskAudits[index].finishedAt = Date()
        activeTaskAuditID = nil
    }

    private func scheduleAuditSave() {
        autosaveSequence += 1
        hasUnsavedChanges = true
        guard auditSaveTask == nil else { return }
        let session = projectSessionID
        auditSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self, self.projectSessionID == session else { return }
            self.auditSaveTask = nil
            self.autosave()
        }
    }

    var isReadingPromptAttachments: Bool { isReadingDraftAttachments || isReadingQueuedAttachments }

    func attachSourceFiles() {
        guard !isReadingPromptAttachments else { return }
        let editID = editingQueuedRequestID, session = projectSessionID
        let panel = NSOpenPanel()
        panel.title = "Attach images or CAD source"
        panel.allowedContentTypes = [.image] + SourceImport.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        guard projectSessionID == session, editingQueuedRequestID == editID else { return }
        attachSourceFiles(urls: panel.urls)
    }

    func attachSourceFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        readPromptAttachments(.files(urls))
    }

    func attachPromptImages(_ images: [PromptImagePayload]) {
        guard !images.isEmpty else { return }
        readPromptAttachments(.images(images))
    }

    private func readPromptAttachments(_ input: PromptAttachmentInput) {
        guard promptAttachmentReads.count < SourceImport.maximumAttachmentCount else {
            error = "Too many attachments are being added. Wait for them to finish, then try again."
            return
        }
        promptAttachmentReads.append(input)
        isReadingDraftAttachments = editingQueuedRequestID == nil
        isReadingQueuedAttachments = editingQueuedRequestID != nil
        guard queuedAttachmentTask == nil else { return }
        let token = queuedAttachmentToken, session = projectSessionID, editID = editingQueuedRequestID
        queuedAttachmentTask = Task { [weak self] in
            while let self, self.projectSessionID == session, self.queuedAttachmentToken == token,
                  self.editingQueuedRequestID == editID, !Task.isCancelled, !self.promptAttachmentReads.isEmpty {
                let next = self.promptAttachmentReads.removeFirst()
                do {
                    let read = try await Task.detached(priority: .userInitiated) { try next.attachments() }.value
                    guard self.projectSessionID == session, self.queuedAttachmentToken == token,
                          self.editingQueuedRequestID == editID, !Task.isCancelled else { return }
                    self.pendingAttachments = try Self.mergedSources(self.pendingAttachments, read)
                } catch {
                    guard self.projectSessionID == session, self.queuedAttachmentToken == token,
                          self.editingQueuedRequestID == editID, !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
            guard let self, self.projectSessionID == session, self.queuedAttachmentToken == token else { return }
            self.isReadingQueuedAttachments = false
            self.isReadingDraftAttachments = false
            self.queuedAttachmentTask = nil
        }
    }

    private func waitForPromptAttachments() async {
        while let task = queuedAttachmentTask { await task.value }
    }

    private func cancelQueuedAttachmentRead() {
        queuedAttachmentTask?.cancel(); queuedAttachmentTask = nil
        queuedAttachmentToken = UUID()
        promptAttachmentReads = []
        isReadingQueuedAttachments = false
        isReadingDraftAttachments = false
    }

    func removeAttachment(id: UUID) { pendingAttachments.removeAll { $0.id == id } }

    private var selectedPartLayout: PartLayout {
        revisions.first(where: { $0.id == selectedRevisionID })?.partLayout ?? PartLayout(nodes: partTree)
    }

    private var hiddenPartIDs: Set<String> {
        Set(partTree.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty && Set($0.solidIndices).isSubset(of: hiddenSolids) }.map(\.id))
    }

    func selectParts(_ solids: Set<Int>, extending: Bool = false) {
        selectedFeatures = []
        let valid = solids.intersection(Set(0..<currentSolidCount))
        selectedSolids = extending ? selectedSolids.symmetricDifference(valid) : valid
        selectedPartNodeIDs = PartSelection.nodeIDs(for: selectedSolids, keeping: [], in: partTree)
    }

    func selectPartNodes(_ ids: Set<String>, extending: Bool = false) {
        selectedFeatures = []
        let nodes = partTree.flatMap(\.flattened)
        let valid = ids.intersection(Set(nodes.map(\.id)))
        let clickedSolids = Set(nodes.filter { valid.contains($0.id) }.flatMap { $0.allSolidIndices })
        var preferred = valid
        if extending {
            preferred.formUnion(selectedPartNodeIDs)
            for node in nodes where valid.contains(node.id) && node.allSolidIndices.isEmpty && selectedPartNodeIDs.contains(node.id) {
                preferred.remove(node.id)
            }
            if !clickedSolids.isEmpty && clickedSolids.isSubset(of: selectedSolids) { selectedSolids.subtract(clickedSolids) }
            else { selectedSolids.formUnion(clickedSolids) }
        } else { selectedSolids = clickedSolids }
        selectedPartNodeIDs = PartSelection.nodeIDs(for: selectedSolids, keeping: preferred, in: partTree)
    }

    func selectFeatures(_ features: [CADFeatureID]) {
        guard let topology = mesh?.topology else { return }
        var seen = Set<CADFeatureID>()
        let valid = features.filter {
            seen.insert($0).inserted && topology.contains($0) && !hiddenSolids.contains($0.solidIndex)
        }
        if !valid.isEmpty {
            selectedSolids = []
            selectedPartNodeIDs = []
        }
        selectedFeatures = valid
    }

    func clearSelections() {
        selectedSolids = []
        selectedPartNodeIDs = []
        selectedFeatures = []
        refreshMeasurements()
    }

    private func cancelMeasurement() {
        measurementTask?.cancel()
        measurementTask = nil
        measurementToken = UUID()
        isMeasuring = false
    }

    private func finishAssemblyMotion(cancelActiveGrab: Bool = false) async {
        if cancelActiveGrab && isGrabbingAssembly { cancelAssemblyGrab() }
        await assemblyMotionTask?.value
        // One worker drains the latest queued pointer target through mouse-up.
        await assemblyGrabTask?.value
    }

    func beginAssemblyGrab(ownerID: UUID, solidIndex: Int, point: [Double], projection: AssemblyGrabProjection) -> Bool {
        guard canManipulateAssembly, !isSolvingAssembly, assemblyGrabSession == nil,
              !hiddenSolids.contains(solidIndex), let preview = mesh, (0..<preview.solids).contains(solidIndex),
              let motion = preview.assemblyMotion, let pose = assemblyPose, let revisionID = selectedRevisionID else { return false }
        do {
            guard let context = try motion.prepareGrab(parts: preview.parts ?? partTree, positions: pose.positions,
                                                       solidIndex: solidIndex, point: point, projection: projection) else { return false }
            assemblyGrabSession = AssemblyGrabSession(ownerID: ownerID, revisionID: revisionID,
                projectSessionID: projectSessionID, geometryToken: assemblyMotionToken, solidIndex: solidIndex, context: context)
            isGrabbingAssembly = true
            assemblyMotionError = nil
            return true
        } catch {
            assemblyMotionError = error.localizedDescription
            return false
        }
    }

    func moveAssemblyGrab(ownerID: UUID, screenPoint: [Double]) {
        guard let session = assemblyGrabSession, session.ownerID == ownerID, !session.ended,
              canManipulateAssembly, screenPoint.count == 2,
              screenPoint.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }), session.lastTarget != screenPoint else { return }
        session.lastTarget = screenPoint
        session.pendingTarget = screenPoint
        if assemblyGrabTask == nil { startAssemblyGrabWorker(session) }
    }

    func endAssemblyGrab(ownerID: UUID) {
        guard let session = assemblyGrabSession, session.ownerID == ownerID, !session.ended else { return }
        session.ended = true
        isGrabbingAssembly = false
        if assemblyGrabTask == nil { assemblyGrabSession = nil }
    }

    func cancelAssemblyGrab(ownerID: UUID? = nil) {
        guard let session = assemblyGrabSession, ownerID == nil || session.ownerID == ownerID else { return }
        assemblyGrabSession = nil
        assemblyGrabTask?.cancel(); assemblyGrabTask = nil
        isGrabbingAssembly = false
        if assemblyMotionTask == nil { isSolvingAssembly = false }
        requestedJointPositions = assemblyPose?.positions ?? [:]
    }

    private func isCurrentAssemblyGrab(_ session: AssemblyGrabSession) -> Bool {
        assemblyGrabSession === session && projectSessionID == session.projectSessionID &&
            selectedRevisionID == session.revisionID && assemblyMotionToken == session.geometryToken && !isWorking
    }

    private func startAssemblyGrabWorker(_ session: AssemblyGrabSession) {
        isSolvingAssembly = true
        assemblyGrabTask = Task { [weak self] in
            while let self, self.isCurrentAssemblyGrab(session), !Task.isCancelled {
                guard let target = session.pendingTarget else {
                    self.assemblyGrabTask = nil
                    self.isSolvingAssembly = false
                    if session.ended { self.assemblyGrabSession = nil }
                    return
                }
                session.pendingTarget = nil
                let context = session.context, positions = self.assemblyPose?.positions ?? [:]
                let solver = self.assemblyGrabSolver
                let calculation = Task.detached(priority: .userInitiated) { try await solver(context, positions, target) }
                do {
                    let pose = try await withTaskCancellationHandler { try await calculation.value }
                        onCancel: { calculation.cancel() }
                    guard self.isCurrentAssemblyGrab(session), !Task.isCancelled else { return }
                    self.acceptAssemblyPose(pose, revisionID: session.revisionID)
                } catch is CancellationError {
                    if self.isCurrentAssemblyGrab(session) { self.cancelAssemblyGrab(ownerID: session.ownerID) }
                    return
                } catch {
                    guard self.isCurrentAssemblyGrab(session), !Task.isCancelled else { return }
                    self.assemblyMotionError = error.localizedDescription
                    // Retain the last valid pose and allow the next cursor
                    // target to recover without abandoning the grab.
                }
            }
        }
    }

    private func acceptAssemblyPose(_ pose: AssemblyPose, revisionID: UUID, fit: Bool = false) {
        assemblyMotionError = nil
        if assemblyPose != pose {
            assemblyPose = pose
            requestedJointPositions = pose.positions
            agentStateGeneration &+= 1
            refreshMeasurements()
        }
        if fit { viewportCommand = ViewportCommand(.fit) }
        if let index = revisions.firstIndex(where: { $0.id == revisionID }), revisions[index].jointPositions != pose.positions {
            revisions[index].jointPositions = pose.positions
            scheduleDebouncedAutosave()
        }
    }

    private func loadAssemblyPose() {
        cancelAssemblyGrab()
        assemblyMotionTask?.cancel(); assemblyMotionTask = nil
        assemblyMotionToken = UUID()
        isSolvingAssembly = false; assemblyMotionError = nil
        assemblyPose = mesh?.assemblyPose
        requestedJointPositions = assemblyPose?.positions ?? [:]
        guard let motion = mesh?.assemblyMotion else { return }
        let saved = revisions.first(where: { $0.id == selectedRevisionID })?.jointPositions
        if let saved, saved != assemblyPose?.positions {
            requestAssemblyPose(positions: saved, driving: nil, fit: true)
        } else if assemblyPose == nil {
            requestAssemblyPose(positions: Dictionary(uniqueKeysWithValues: motion.joints.map { ($0.id, $0.position) }),
                                driving: nil, fit: true)
        }
    }

    func jointPosition(_ joint: AssemblyJoint) -> Double {
        requestedJointPositions[joint.id] ?? assemblyPose?.positions[joint.id] ?? joint.position
    }

    func setJointPosition(_ id: String, to value: Double) {
        guard !isWorking, value.isFinite,
              mesh?.assemblyMotion?.joints.contains(where: { $0.id == id && $0.type != .fixed }) == true else { return }
        cancelAssemblyGrab()
        var positions = requestedJointPositions
        positions[id] = value
        requestAssemblyPose(positions: positions, driving: id)
    }

    func resetAssemblyMotion() {
        guard !isWorking, let motion = mesh?.assemblyMotion else { return }
        cancelAssemblyGrab()
        requestAssemblyPose(positions: Dictionary(uniqueKeysWithValues: motion.joints.map { ($0.id, $0.position) }), driving: nil)
    }

    private func requestAssemblyPose(positions: [String: Double], driving: String?, fit: Bool = false) {
        guard let preview = mesh, let motion = preview.assemblyMotion, let revisionID = selectedRevisionID else { return }
        assemblyMotionTask?.cancel()
        let token = UUID(); assemblyMotionToken = token
        requestedJointPositions = positions
        isSolvingAssembly = true; assemblyMotionError = nil
        let parts = preview.parts ?? partTree
        let calculation = Task.detached(priority: .userInitiated) {
            try motion.solve(parts: parts, positions: positions, driving: driving)
        }
        assemblyMotionTask = Task { [weak self] in
            do {
                let pose = try await withTaskCancellationHandler { try await calculation.value }
                    onCancel: { calculation.cancel() }
                guard let self, self.assemblyMotionToken == token, self.selectedRevisionID == revisionID,
                      self.mesh?.stepPath == preview.stepPath, !Task.isCancelled else { return }
                self.isSolvingAssembly = false; self.assemblyMotionTask = nil
                self.acceptAssemblyPose(pose, revisionID: revisionID, fit: fit)
            } catch is CancellationError {
            } catch {
                guard let self, self.assemblyMotionToken == token else { return }
                self.isSolvingAssembly = false; self.assemblyMotionTask = nil
                self.requestedJointPositions = self.assemblyPose?.positions ?? [:]
                self.assemblyMotionError = error.localizedDescription
            }
        }
    }

    private func refreshMeasurements() {
        cancelMeasurement()
        measurementError = nil
        guard let preview = mesh, hasMeasurementSelection else { measurementReport = nil; return }
        let features = selectedFeatures, solids = selectedSolids
        let transforms = assemblyPose?.solidTransforms ?? [:]
        let key = MeasurementKey(previewPath: preview.stepPath, brepPath: preview.brepPath, features: features, solids: solids.sorted(),
                                 transforms: AssemblySolidTransform.records(transforms))
        if let cached = measurementCache[key] { measurementReport = cached; return }
        do { measurementReport = transforms.isEmpty ? try CADMeasurements.report(preview, features: features, solids: solids) : nil }
        catch { measurementReport = nil; measurementError = error.localizedDescription; return }
        let needsNativeDistance = features.count + solids.count == 2 &&
            !(solids.isEmpty && features.allSatisfy { $0.kind == .vertex })
        guard needsNativeDistance || !transforms.isEmpty else { return }
        let token = measurementToken, sessionID = projectSessionID
        let runtime = python, cores = threads
        isMeasuring = true
        measurementTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                let report = try await self.engine.measure(preview, features: features, solids: solids, solidTransforms: transforms,
                                                          python: runtime, threads: cores)
                guard self.measurementToken == token, self.projectSessionID == sessionID,
                      self.mesh?.stepPath == preview.stepPath, !Task.isCancelled else { return }
                if self.measurementCache.count >= 128 { self.measurementCache.removeAll() }
                self.measurementCache[key] = report
                self.measurementReport = report
                self.isMeasuring = false
                self.measurementTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.measurementToken == token, self.projectSessionID == sessionID else { return }
                self.measurementError = error.localizedDescription
                self.isMeasuring = false
                self.measurementTask = nil
            }
        }
    }

    private func colorTargets(for nodeID: String) -> [PartNode] {
        let nodes = partTree.flatMap(\.flattened)
        guard let clicked = nodes.first(where: { $0.id == nodeID }) else { return [] }
        let clickedSolids = clicked.allSolidIndices
        let targets = !clickedSolids.isEmpty && clickedSolids.isSubset(of: selectedPartSolids) ? selectedPartSolids : clickedSolids
        return nodes.filter { !$0.solidIndices.isEmpty && !Set($0.solidIndices).isDisjoint(with: targets) }
    }

    func partColor(for nodeID: String) -> PartColor? {
        guard let revision = revisions.first(where: { $0.id == selectedRevisionID }) else { return nil }
        let targets = colorTargets(for: nodeID)
        let colors = Self.completePartColors(in: partTree, stored: revision.partColors ?? [:])
        guard let first = targets.first, let color = colors[first.id],
              targets.allSatisfy({ colors[$0.id] == color }) else { return nil }
        return color
    }

    func setPartColor(_ color: PartColor?, for nodeID: String) {
        guard color?.isValid != false,
              let index = revisions.firstIndex(where: { $0.id == selectedRevisionID }) else { return }
        let targets = colorTargets(for: nodeID)
        guard !targets.isEmpty else { return }
        var colors = revisions[index].partColors ?? [:]
        for node in targets {
            colors[node.id] = color ?? (node.color == nil ? nil : PartColorState.defaultFinish)
        }
        let changed = colors != (revisions[index].partColors ?? [:])
        var recent = recentPartColors
        if let color {
            recent.removeAll { $0 == color }
            recent.insert(color, at: 0)
            recent = Array(recent.prefix(PartColor.maximumRecentCount))
        }
        guard changed || recent != recentPartColors else { return }
        revisions[index].partColors = colors.isEmpty ? nil : colors
        recentPartColors = recent
        autosave()
    }

    /// Apply only a successful turn's staged display edits to its captured
    /// source revision. Navigating history must not redirect those edits.
    func applyAgentPartColorChanges(_ changes: [CADPartColorChange], to sourceRevisionID: UUID?,
                                   matching source: ModelSpec?, startedWith snapshot: [String: PartColor]) throws {
        guard !changes.isEmpty else { return }
        guard let sourceRevisionID, let source,
              let index = revisions.firstIndex(where: { $0.id == sourceRevisionID }),
              revisions[index].model == source else {
            throw LADError.message("The original design version changed before its colors could be applied.")
        }
        let revision = revisions[index]
        let nodes = revision.partLayout?.nodes ?? revision.parts ?? revision.preview.map(Self.defaultParts(for:)) ?? []
        let colors = try Self.partColors(applying: changes, in: nodes,
                                        current: Self.completePartColors(in: nodes, stored: revision.partColors ?? [:]),
                                        startedWith: snapshot)
        revisions[index].partColors = colors.isEmpty ? nil : colors
    }

    /// A task can replace existing colors; a newer edit made during that
    /// task remains current on the physical parts it changed.
    static func partColors(applying changes: [CADPartColorChange], in nodes: [PartNode],
                           current: [String: PartColor], startedWith snapshot: [String: PartColor]) throws -> [String: PartColor] {
        let retained = retainedPartColors(current, in: nodes) ?? [:]
        let colors = completePartColors(in: nodes, stored: retained)
        var result = try PartColorState.applyingPhysical(changes: changes, to: colors, in: nodes)
        let physicalIDs = Set(nodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map(\.id))
        for id in snapshot.keys where physicalIDs.contains(id) && current[id] != snapshot[id] {
            result[id] = current[id] ?? PartColorState.defaultFinish
        }
        return result
    }

    /// Capture every physical part's current RGB, including the neutral finish.
    /// Stable IDs retain these values when a later build supplies new parts.
    static func completePartColors(in nodes: [PartNode], stored: [String: PartColor]) -> [String: PartColor] {
        let colors = PartColorState.resolved(in: nodes, overrides: stored)
        var result: [String: PartColor] = [:]
        for node in nodes.flatMap(\.flattened) where !node.solidIndices.isEmpty {
            result[node.id] = colors[node.id] ?? PartColorState.defaultFinish
        }
        return result
    }

    /// Stable part identities preserve colors across refinements. Only an
    /// explicit rebuild of the same program may migrate old generic IDs.
    static func retainedPartColors(_ colors: [String: PartColor], in nodes: [PartNode],
                                   remappingGenericFrom previous: [PartNode] = []) -> [String: PartColor]? {
        let parts = nodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }
        let ids = Set(parts.map(\.id))
        var result = colors.filter { ids.contains($0.key) }
        for old in previous.flatMap(\.flattened) where old.solidIndices.count == 1 && old.id == "solid/\(old.solidIndices[0])" {
            guard !ids.contains(old.id), let color = colors[old.id] else { continue }
            let matches = parts.filter { $0.solidIndices == old.solidIndices }
            if matches.count == 1, let id = matches.first?.id, result[id] == nil { result[id] = color }
        }
        return result.isEmpty ? nil : result
    }

    func togglePartVisibility(_ solids: Set<Int>) {
        let valid = solids.intersection(Set(0..<currentSolidCount))
        guard !valid.isEmpty else { return }
        if hiddenSolids.isDisjoint(with: valid) { hiddenSolids.formUnion(valid) }
        else { hiddenSolids.subtract(valid) }
        selectedSolids.subtract(hiddenSolids)
        selectedFeatures.removeAll { hiddenSolids.contains($0.solidIndex) }
        selectedPartNodeIDs = PartSelection.nodeIDs(for: selectedSolids, keeping: selectedPartNodeIDs, in: partTree)
        persistPartVisibility()
    }

    func hideSelectedParts() {
        let visibleSelection = selectedPartSolids.subtracting(hiddenSolids)
        guard !visibleSelection.isEmpty else { return }
        hiddenSolids.formUnion(visibleSelection)
        clearSelections()
        persistPartVisibility()
    }

    func showAllParts() {
        guard !hiddenSolids.isEmpty else { return }
        hiddenSolids = []
        persistPartVisibility()
    }

    private func persistPartVisibility() {
        guard let index = revisions.firstIndex(where: { $0.id == selectedRevisionID }) else { return }
        revisions[index].hiddenSolids = hiddenSolids.sorted()
        autosave()
    }

    func movePartNodes(_ ids: Set<String>, toParent parentID: String?) {
        editPartLayout { try $0.move(ids, toParent: parentID) }
    }

    func createPartFolder(named name: String, parentID: String? = nil) {
        editPartLayout { _ = try $0.createFolder(named: name, parentID: parentID) }
    }

    func renamePartNode(_ id: String, to name: String) {
        editPartLayout { try $0.rename(id, to: name) }
    }

    func ungroupPartFolder(_ id: String) {
        editPartLayout { try $0.ungroup(id) }
    }

    func isPartFolderExpanded(_ id: String) -> Bool {
        !selectedPartLayout.collapsedNodeIDs.contains(id)
    }

    func setPartFolderExpanded(_ id: String, isExpanded: Bool) {
        guard let node = partTree.flatMap(\.flattened).first(where: { $0.id == id }), node.isGroup,
              isPartFolderExpanded(id) != isExpanded else { return }
        editPartLayout { try $0.setExpanded(isExpanded, for: id) }
    }

    func resetPartHierarchy() {
        guard let index = revisions.firstIndex(where: { $0.id == selectedRevisionID }),
              let defaults = revisions[index].parts ?? revisions[index].preview.map(Self.defaultParts(for:)) else { return }
        let folderIDs = Set(defaults.flatMap(\.flattened).filter(\.isGroup).map(\.id))
        let collapsed = selectedPartLayout.collapsedNodeIDs.filter { folderIDs.contains($0) }
        revisions[index].partLayout = PartLayout(nodes: defaults, collapsedNodeIDs: collapsed)
        selectedPartNodeIDs = PartSelection.nodeIDs(for: selectedSolids, keeping: [], in: defaults)
        autosave()
    }

    private func editPartLayout(_ edit: (inout PartLayout) throws -> Void) {
        guard let index = revisions.firstIndex(where: { $0.id == selectedRevisionID }) else { return }
        do {
            var layout = selectedPartLayout
            try edit(&layout)
            try ProjectStore.validatePartHierarchy(layout.nodes, solidCount: currentSolidCount)
            revisions[index].partLayout = layout
            selectedPartNodeIDs = PartSelection.nodeIDs(for: selectedSolids, keeping: selectedPartNodeIDs, in: layout.nodes)
            autosave()
        } catch { self.error = error.localizedDescription }
    }

    private static func mergedSources(_ existing: [SourceAttachment], _ added: [SourceAttachment]) throws -> [SourceAttachment] {
        try SourceImport.mergeAttachments(existing: existing, added: added)
    }

    func cancel(preservingAssemblyMotion: Bool = false) {
        if !preservingAssemblyMotion || isGrabbingAssembly { cancelAssemblyGrab() }
        if !preservingAssemblyMotion {
            assemblyMotionTask?.cancel(); assemblyMotionTask = nil
            assemblyMotionToken = UUID(); isSolvingAssembly = false
            requestedJointPositions = assemblyPose?.positions ?? [:]
        }
        queuePaused = true; queueCanAdvance = false
        queuePauseReason = nil
        steeringTask?.cancel(); steeringTask = nil
        isSendingQueuedRequestID = nil
        setSteeringAvailable(false)
        cancelMeasurement()
        let hadGenerationFeedback = generationFeedback != nil
        finishGenerationFeedback()
        finishTaskAudit(status: "canceled")
        operationID = UUID()
        operation?.cancel(); operation = nil
        codex.cancel(); engine.cancel()
        isWorking = false; activity = "Ready"
        if hadGenerationFeedback { autosave() }
    }

    func selectRevision(_ id: UUID) {
        guard id != selectedRevisionID, let revision = revisions.first(where: { $0.id == id }) else { return }
        cancel(); selectedRevisionID = id
        if !loadStoredRevision() { buildExisting(revision.model) }
        autosave()
    }

    func rebuild() { if let current { cancel(); buildExisting(current) } }

    private func buildExisting(_ spec: ModelSpec) {
        let token = UUID(); operationID = token
        let revisionID = selectedRevisionID, runtime = python, cores = threads
        let validatedHash = revisions.first(where: { $0.id == revisionID })?.validatedHash
        let previousLayout = selectedPartLayout, previouslyHidden = hiddenSolids
        isWorking = true; activity = "Building solid geometry…"; error = nil
        operation = Task {
            do {
                let preview = try await engine.buildPreview(spec, python: runtime, threads: cores, validatedHash: validatedHash)
                guard operationID == token, !Task.isCancelled else { return }
                if let index = revisions.firstIndex(where: { $0.id == revisionID }) {
                    let defaults = Self.defaultParts(for: preview)
                    let oldNodes = revisions[index].partLayout?.nodes ?? revisions[index].parts ?? previousLayout.nodes
                    let migrated = (revisions[index].partLayout ?? previousLayout).remappingGenericParts(to: defaults)
                    let layout = migrated.reconciled(with: defaults)
                    try ProjectStore.validatePartHierarchy(layout.nodes, solidCount: preview.solids)
                    let oldHidden = Set(revisions[index].hiddenSolids ?? previouslyHidden.sorted())
                    let hiddenIDs = Set(migrated.nodes.flatMap(\.flattened).filter {
                        !$0.solidIndices.isEmpty && Set($0.solidIndices).isSubset(of: oldHidden)
                    }.map(\.id))
                    revisions[index].preview = preview; revisions[index].stepData = nil
                    revisions[index].validatedHash = preview.validatedHash
                    if revisions[index].runtime == nil { revisions[index].runtime = preview.runtime }
                    revisions[index].parts = defaults
                    revisions[index].partLayout = layout
                    revisions[index].partColors = Self.retainedPartColors(revisions[index].partColors ?? [:], in: layout.nodes,
                                                                          remappingGenericFrom: oldNodes)
                    hiddenSolids = Set(layout.nodes.flatMap(\.flattened).filter { hiddenIDs.contains($0.id) }.flatMap(\.solidIndices))
                    revisions[index].hiddenSolids = hiddenSolids.sorted()
                }
                mesh = preview; builtRevisionID = revisionID; selectedSolids = []; selectedPartNodeIDs = []
                viewportCommand = ViewportCommand(.fit)
                isWorking = false; activity = "Ready"; operation = nil
                autosave()
            } catch is CancellationError {
                if operationID == token { isWorking = false; operation = nil }
            } catch {
                guard operationID == token else { return }
                self.error = error.localizedDescription; isWorking = false; activity = "Engine unavailable"; operation = nil
            }
        }
    }

    func saveNewProject(revisionID: UUID? = nil) {
        guard canSaveNew else { return }
        let snapshot: LADProject
        do { snapshot = try SaveNewProject.snapshot(from: projectSnapshot(), revisionID: revisionID) }
        catch { self.error = error.localizedDescription; return }
        let sessionID = projectSessionID, sourceID = projectID, sourceURL = projectURL
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("LAD.SaveNewProject")
        panel.title = "Save New"
        panel.prompt = "Save New"
        panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .package]
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? ProjectAutosaveStore.defaultDirectory
        panel.nameFieldStringValue = "\(safeName(title)) copy.lad"
        guard SavePanelPresentation.runModal(panel) == .OK, let target = panel.url,
              projectSessionID == sessionID else { return }
        var newProject = snapshot
        newProject.projectName = target.deletingPathExtension().lastPathComponent
        Task {
            do {
                try await autosaveStore.writeCopy(newProject, to: target, preserving: sourceURL, projectID: sourceID)
                onRecentProjectChanged?(target, nil)
            } catch {
                guard projectSessionID == sessionID else { return }
                self.error = "Could not save the new design. \(error.localizedDescription)"
            }
        }
    }

    func saveProject(as newLocation: Bool = false) {
        guard canSaveProject else { return }
        // The regular Save command flushes the open project. Save As
        // still offers an explicit portable copy at a user-selected location.
        if !newLocation {
            if saveConflict != nil {
                presentedSaveConflict = nil
                presentSaveConflict(in: viewportView?.window)
                return
            }
            autosave()
            return
        }
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("LAD.SaveProject")
        panel.title = "Save LAD design"
        panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .package]
        panel.nameFieldStringValue = "\(safeName(title)).lad"
        guard SavePanelPresentation.runModal(panel) == .OK, let target = panel.url else { return }
        let snapshot = projectSnapshot(), sessionID = projectSessionID
        saveStatus = "Saving…"
        Task {
            do {
                try await autosaveStore.writeCopy(snapshot, to: target)
                onRecentProjectChanged?(target, nil)
                guard projectSessionID == sessionID else { return }
                autosave()
            } catch {
                if projectSessionID == sessionID {
                    self.error = error.localizedDescription
                    saveStatus = "Not saved: \(error.localizedDescription)"
                }
            }
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .package]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let onOpenProject { onOpenProject(url) }
        else { openProject(url) }
    }

    func openProject(_ url: URL, restoringProjectID: UUID? = nil) {
        cancel(); isWorking = true; activity = "Opening design…"
        let wasReady = projectReady
        projectReady = false
        let token = UUID(); operationID = token
        operation = Task {
            do {
                let project: LADProject
                let source: URL
                if let restoringProjectID,
                   let restored = try await autosaveStore.restoreRecent(preferredURL: url, projectID: restoringProjectID) {
                    project = restored.project; source = restored.url
                } else {
                    project = try await Task.detached(priority: .userInitiated) { try ProjectAutosaveStore.readProject(from: url) }.value
                    source = url
                }
                guard operationID == token else { return }
                loadProject(project, from: source)
            } catch {
                guard operationID == token else { return }
                projectReady = wasReady
                self.error = "Unable to open design. \(error.localizedDescription)"; isWorking = false; activity = "Ready"
            }
        }
    }

    /// Commit an already validated file after the receiving window's old
    /// document has been safely flushed. Opening can never partially replace it.
    func loadProject(_ project: LADProject, from source: URL) {
        loaded = true
        cancel()
        restore(project)
        autosavedProjectURL = source
        projectURL = source
        isWorking = false
        projectReady = true
        noteRecentProject(at: source)
        if !loadStoredRevision(), let current { buildExisting(current) }
        autosave()
    }

    func exportSTEP() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("LAD.ExportSTEP")
        panel.title = "Export design"
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data]
        panel.nameFieldStringValue = "\(safeName(title)).step"
        let options = STEPExportOptionsView(panel: panel, projectName: STEPIndividualExport.folderName(for: title))
        panel.accessoryView = options
        guard SavePanelPresentation.runModal(panel) == .OK, let url = panel.url else { return }
        exportSTEP(to: url, arrangeFor3DPrinting: options.arrangeFor3DPrinting,
                   exportIndividualParts: options.exportIndividualParts, replaceExisting: true)
    }

    func exportSelectedPartsSTEP(_ solidIndices: Set<Int>? = nil) {
        let solids = (solidIndices ?? selectedPartSolids).intersection(Set(0..<currentSolidCount))
        guard canExport, !solids.isEmpty else { return }
        let revisionID = selectedRevisionID, sessionID = projectSessionID
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("LAD.ExportSelectedPartsSTEP")
        panel.title = "Export selected parts"
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data]
        panel.nameFieldStringValue = "\(safeName(title)) selected parts.step"
        let options = STEPExportOptionsView(panel: panel, projectName: STEPIndividualExport.folderName(for: title))
        panel.accessoryView = options
        guard SavePanelPresentation.runModal(panel) == .OK, let url = panel.url,
              revisionID == selectedRevisionID, sessionID == projectSessionID else { return }
        exportSTEP(to: url, solidIndices: solids, arrangeFor3DPrinting: options.arrangeFor3DPrinting,
                   exportIndividualParts: options.exportIndividualParts, replaceExisting: true)
    }

    /// Export the captured geometry and current colors. The engine caches
    /// session bytes by geometry, selected solids, RGB assignments and arrangement.
    func exportSTEP(to url: URL, solidIndices: Set<Int>? = nil, arrangeFor3DPrinting: Bool = false,
                    exportIndividualParts: Bool = false, replaceExisting: Bool = false) {
        guard canExport, let preview = posedPreview, let revisionID = selectedRevisionID,
              let revision = revisions.first(where: { $0.id == revisionID }) else { return }
        if let solidIndices, solidIndices.isEmpty || !solidIndices.isSubset(of: Set(0..<preview.solids)) { return }
        let nodes = revision.partLayout?.nodes ?? revision.parts ?? Self.defaultParts(for: preview)
        let colors = Self.completePartColors(in: nodes, stored: revision.partColors ?? [:])
        let exportColors = PartColorState.solidColors(in: nodes, overrides: colors)
        let token = UUID(), sessionID = projectSessionID
        operationID = token
        let runtime = python, cores = threads
        isWorking = true; activity = "Exporting STEP…"; error = nil
        operation = Task {
            do {
                let output: (files: [Data], parts: [STEPIndividualExport.Part])
                do {
                    output = try await stepExportOutput(preview, solidIndices: solidIndices, nodes: nodes,
                                                        colors: exportColors, arrangeFor3DPrinting: arrangeFor3DPrinting,
                                                        individualParts: exportIndividualParts, python: runtime, threads: cores)
                } catch EngineExportError.nativeArtifactUnavailable {
                    // Replay can enumerate solids differently. Bind the
                    // captured colors and subset to fresh stable ownership.
                    var rebuilt = try await engine.buildPreview(revision.model, python: runtime, threads: cores, validatedHash: revision.validatedHash)
                    if let motion = rebuilt.assemblyMotion {
                        rebuilt.assemblyPose = try motion.solve(parts: rebuilt.parts ?? [], positions: preview.assemblyPose?.positions ?? [:])
                    }
                    guard operationID == token, projectSessionID == sessionID, selectedRevisionID == revisionID,
                          !Task.isCancelled, let index = revisions.firstIndex(where: { $0.id == revisionID }) else { return }
                    let restored = try Self.restoredPartState(for: revision, preview: rebuilt, selected: solidIndices ?? [])
                    let rebuiltNodes = restored.layout?.nodes ?? restored.parts
                    let rebuiltColors = PartColorState.solidColors(in: rebuiltNodes, overrides: colors)
                    try cacheReplayedPreview(rebuilt, at: index)
                    output = try await stepExportOutput(rebuilt, solidIndices: solidIndices == nil ? nil : restored.selected,
                                                        nodes: rebuiltNodes, colors: rebuiltColors,
                                                        arrangeFor3DPrinting: arrangeFor3DPrinting,
                                                        individualParts: exportIndividualParts, python: runtime, threads: cores)
                }
                guard operationID == token, projectSessionID == sessionID, selectedRevisionID == revisionID,
                      !Task.isCancelled, let index = revisions.firstIndex(where: { $0.id == revisionID }) else { return }
                revisions[index].stepData = nil
                let writing = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    if exportIndividualParts {
                        try STEPIndividualExport.write(output.files, parts: output.parts, to: url,
                                                       replaceExisting: replaceExisting)
                    } else {
                        try output.files[0].write(to: url, options: .atomic)
                    }
                }
                try await withTaskCancellationHandler {
                    try await writing.value
                } onCancel: { writing.cancel() }
                guard operationID == token, projectSessionID == sessionID, selectedRevisionID == revisionID,
                      !Task.isCancelled else { return }
                notice = "STEP exported · \(url.lastPathComponent)"
                activity = "Ready"; isWorking = false; operation = nil
            } catch is CancellationError {
                if operationID == token { isWorking = false; activity = "Ready"; operation = nil }
            } catch {
                guard operationID == token, projectSessionID == sessionID else { return }
                self.error = "Export failed. \(error.localizedDescription)"
                activity = "Export needs attention"; isWorking = false; operation = nil
            }
        }
    }

    private func stepExportOutput(_ preview: PreviewMesh, solidIndices: Set<Int>?, nodes: [PartNode],
                                  colors: [Int: PartColor], arrangeFor3DPrinting: Bool, individualParts: Bool,
                                  python: String, threads: Int) async throws -> (files: [Data], parts: [STEPIndividualExport.Part]) {
        if individualParts {
            let parts = STEPIndividualExport.parts(in: nodes, selected: solidIndices, solidCount: preview.solids)
            let files = try await engine.exportSTEPParts(preview, parts: parts.map(\.solidIndices), solidColors: colors,
                                                         arrangeFor3DPrinting: arrangeFor3DPrinting, python: python, threads: threads)
            return (files, parts)
        }
        let data = try await engine.exportSTEP(preview, solidIndices: solidIndices, solidColors: colors,
                                               arrangeFor3DPrinting: arrangeFor3DPrinting, python: python, threads: threads)
        return ([data], [])
    }

    private func safeName(_ name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted).joined()
        return safe.isEmpty ? "Design" : String(safe.prefix(100))
    }
    private var autosaveTitle: String { title }

    private func rememberAutosavedProject(_ url: URL) {
        guard projectReady else { return }
        // Ordinary saves keep their established URL. Canonicalization and
        // recent-menu updates are needed only for a newly opened/moved file.
        if url != lastRememberedProjectURL || (lastNotedRecentURL == nil && onRecentProjectChanged != nil) {
            let canonical = ProjectFileOrigin.canonicalURL(url)
            if canonical != lastNotedRecentURL { noteRecentProject(at: canonical) }
            lastRememberedProjectURL = url
        }
        guard isActiveProject else { return }
        if UserDefaults.standard.string(forKey: Self.recentProjectPathKey) != url.path {
            UserDefaults.standard.set(url.path, forKey: Self.recentProjectPathKey)
        }
        if UserDefaults.standard.string(forKey: Self.recentProjectIDKey) != projectID.uuidString {
            UserDefaults.standard.set(projectID.uuidString, forKey: Self.recentProjectIDKey)
        }
    }

    func noteProjectOpened(fallbackURL: URL? = nil) {
        guard projectReady, !preserveUnreadableSession,
              let url = autosavedProjectURL ?? projectURL ?? fallbackURL else { return }
        noteRecentProject(at: url)
    }

    private func noteRecentProject(at url: URL) {
        guard let onRecentProjectChanged else { return }
        let canonical = ProjectFileOrigin.canonicalURL(url)
        let previous = lastNotedRecentURL.flatMap { $0 == canonical ? nil : $0 }
        onRecentProjectChanged(canonical, previous)
        lastNotedRecentURL = canonical
    }

    func setActiveProject(_ active: Bool) {
        isActiveProject = active
        if active, let url = autosavedProjectURL { rememberAutosavedProject(url) }
    }

    private func restore(_ project: LADProject) {
        onProjectAgentInvalidated?()
        cancelProjectThumbnail()
        projectReady = false
        // Existing files retain normal autosaving, including empty archives.
        projectSavingEnabled = true
        saveConflict = nil
        presentedSaveConflict = nil
        saveConflictPromptTask?.cancel(); saveConflictPromptTask = nil
        projectFileOrigin = project.fileOrigin
        hasUnsavedChanges = false
        activityImages.reset()
        resetQueueWork()
        projectSessionID = UUID()
        projectID = project.projectID ?? UUID()
        autosavedProjectURL = nil
        lastNotedRecentURL = nil
        lastRememberedProjectURL = nil
        measurementCache = [:]
        preserveUnreadableSession = false
        pendingProjectRename = false
        projectName = project.projectName
        recentPartColors = project.recentPartColors ?? []
        partsPaneFraction = project.partsPaneFraction
        auditSaveTask?.cancel(); auditSaveTask = nil
        taskAudits = project.taskAudits ?? []
        for index in taskAudits.indices where taskAudits[index].status == "running" {
            taskAudits[index].status = "interrupted"
            taskAudits[index].finishedAt = Date()
            for event in taskAudits[index].events.indices where taskAudits[index].events[event].status == "running" {
                taskAudits[index].events[event].status = "interrupted"
            }
        }
        activeTaskAuditID = nil
        showGrid = project.showGrid ?? true
        projectionMode = project.projectionMode ?? .perspective
        displayMode = project.displayMode ?? .edges
        codexSettings = normalizedCodexSettings(project.codexSettings ?? CodexProjectSettings())
        messages = project.messages; revisions = project.revisions
        selectedRevisionID = project.selectedRevisionID ?? revisions.last?.id
        mesh = nil; builtRevisionID = nil
        queuedRequests = project.queuedRequests ?? []
        // Reopening a file restores intent, never starts agent work by itself.
        queuePaused = !queuedRequests.isEmpty
        prompt = project.draftPrompt ?? ""
        pendingAttachments = project.draftAttachments ?? []
        error = nil; notice = nil; saveStatus = nil
        selectedSolids = []; selectedPartNodeIDs = []; hiddenSolids = []
        // Package loading already checks this optional image against its
        // persisted presentation identity. Keep it during replay; a matching
        // validation receipt can bind it to the new session's artifact paths.
        if let bytes = project.thumbnailData,
           let revision = revisions.first(where: { $0.id == selectedRevisionID }) {
            projectThumbnailData = bytes
            projectThumbnailImagePresentation = ProjectThumbnailPresentation(revisionID: revision.id,
                generation: projectThumbnailRevisionGeneration, validationHash: revision.validatedHash,
                projection: projectionMode, display: displayMode, hiddenSolids: Set(revision.hiddenSolids ?? []))
        }
    }
    private func autosave() {
        guard canSaveProject else { return }
        // This snapshot includes the latest draft, divider and audit edits.
        // Their pending timers would only request the same save again.
        autosaveDebounceTask?.cancel(); autosaveDebounceTask = nil
        auditSaveTask?.cancel(); auditSaveTask = nil
        hasUnsavedChanges = true
        autosaveSequence += 1
        guard saveConflict == nil else { return }
        let snapshot = projectSnapshot(), sequence = autosaveSequence, sessionID = projectSessionID
        let documentID = projectID, name = autosaveTitle, preferredURL = autosavedProjectURL
        let preferExactName = pendingProjectRename
        saveStatus = "Saving…"
        Task {
            do {
                let url = try await autosaveStore.write(project: snapshot, projectID: documentID, title: name,
                                                       sequence: sequence, preferredURL: preferredURL,
                                                       preferExactName: preferExactName)
                guard projectSessionID == sessionID, autosaveSequence == sequence else { return }
                if projectURL != url { projectURL = url }
                autosavedProjectURL = url
                rememberAutosavedProject(url)
                pendingProjectRename = false
                hasUnsavedChanges = false
                saveStatus = nil
            } catch {
                guard projectSessionID == sessionID, autosaveSequence == sequence else { return }
                recordSaveFailure(error)
            }
        }
    }

    private func recordSaveFailure(_ failure: Error) {
        saveStatus = "Not saved: \(failure.localizedDescription)"
        if let conflict = failure as? ProjectSaveConflict { saveConflict = conflict }
    }

    /// Shared document views coalesce onto one native conflict sheet.
    func presentSaveConflict(in window: NSWindow?,
        choose: @escaping @MainActor (ProjectSaveConflict, NSWindow) async -> ProjectSaveConflictPrompt.Choice = ProjectSaveConflictPrompt.choose) {
        guard let window, let conflict = saveConflict, saveConflictPromptTask == nil,
              presentedSaveConflict != conflict else { return }
        presentedSaveConflict = conflict
        let session = projectSessionID
        saveConflictPromptTask = Task { [weak self] in
            let choice = await choose(conflict, window)
            guard let self, self.projectSessionID == session else { return }
            self.saveConflictPromptTask = nil
            do { try await self.resolveSaveConflict(choice) }
            catch { self.recordSaveFailure(error) }
        }
    }

    func retrySaveConflict(in window: NSWindow?) {
        presentedSaveConflict = nil
        presentSaveConflict(in: window)
    }

    func resolveSaveConflict(_ choice: ProjectSaveConflictPrompt.Choice) async throws {
        guard let conflict = saveConflict, projectReady, !preserveUnreadableSession else { return }
        if case .cancel = choice { return }
        autosaveDebounceTask?.cancel(); autosaveDebounceTask = nil
        autosaveSequence += 1
        let sequence = autosaveSequence, session = projectSessionID
        var snapshot = projectSnapshot()
        saveStatus = "Saving…"; hasUnsavedChanges = true
        do {
            switch choice {
            case .cancel: return
            case .overwrite:
                let url = try await autosaveStore.write(project: snapshot, projectID: projectID, title: autosaveTitle,
                    sequence: sequence, preferredURL: conflict.file.url, preferExactName: pendingProjectRename,
                    resolving: conflict)
                guard projectSessionID == session else { return }
                autosavedProjectURL = url
                if projectURL != url { projectURL = url }
                rememberAutosavedProject(url)
                pendingProjectRename = false
            case .saveAs(let target):
                guard !conflict.file.matches(target) else {
                    throw LADError.message("Choose a different filename to preserve the other design file.")
                }
                let name = try ProjectNaming.userName(target.deletingPathExtension().lastPathComponent)
                let identity = UUID()
                snapshot.projectID = identity
                snapshot.projectName = name
                snapshot.fileOrigin = nil
                let origin = try await autosaveStore.writeCopy(snapshot, to: target,
                    preserving: conflict.file.url, projectID: projectID)
                guard projectSessionID == session else { return }
                projectID = identity; projectName = name; projectFileOrigin = origin
                autosavedProjectURL = target
                projectURL = target
                pendingProjectRename = false
                noteRecentProject(at: target)
            }
            saveConflict = nil
            if autosaveSequence == sequence {
                hasUnsavedChanges = false; saveStatus = nil
            } else { autosave() }
        } catch {
            if projectSessionID == session { recordSaveFailure(error) }
            throw error
        }
    }

    @discardableResult
    func loadStoredRevision() -> Bool {
        guard let revision = revisions.first(where: { $0.id == selectedRevisionID }) else { return false }
        mesh = nil; builtRevisionID = nil; selectedSolids = []; selectedPartNodeIDs = []
        hiddenSolids = Set(revision.hiddenSolids ?? [])
        if let preview = revision.preview {
            // Session previews retain their native solid artifact for a later
            // export. Returning to a visited revision needs no worker process.
            mesh = preview; builtRevisionID = revision.id
            viewportCommand = ViewportCommand(.fit)
            activity = "Ready"; isWorking = false; operation = nil
            return true
        }

        // Generated geometry is reconstructed from the exact saved program.
        // Native and temporary STEP validation finish before preview acceptance.
        let token = UUID(); operationID = token
        let runtime = python, cores = threads
        isWorking = true; activity = "Preparing preview…"; error = nil
        operation = Task {
            do {
                let preview = try await engine.buildPreview(revision.model, python: runtime, threads: cores, validatedHash: revision.validatedHash)
                guard operationID == token, selectedRevisionID == revision.id, !Task.isCancelled,
                      let index = revisions.firstIndex(where: { $0.id == revision.id }) else { return }
                // Only transient geometry changes here. User edits made while
                // the worker was busy remain authoritative.
                try cacheReplayedPreview(preview, at: index)
                if revision.validatedHash != preview.validatedHash { autosave() }
                viewportCommand = ViewportCommand(.fit)
                activity = "Ready"; isWorking = false; operation = nil
            } catch is CancellationError {
                if operationID == token { isWorking = false; activity = "Ready"; operation = nil }
            } catch {
                guard operationID == token else { return }
                self.error = error.localizedDescription
                activity = "Preview needs attention"; isWorking = false; operation = nil
            }
        }
        return true
    }

    private func cacheReplayedPreview(_ generated: PreviewMesh, at index: Int) throws {
        let restored = try Self.restoredPartState(for: revisions[index], preview: generated, selected: selectedSolids)
        var preview = generated
        preview.parts = restored.parts
        revisions[index].parts = restored.parts
        revisions[index].partLayout = restored.layout
        revisions[index].hiddenSolids = restored.hidden.sorted()
        revisions[index].preview = preview
        revisions[index].validatedHash = preview.validatedHash
        if revisions[index].runtime == nil { revisions[index].runtime = preview.runtime }
        revisions[index].stepData = nil
        mesh = preview; builtRevisionID = revisions[index].id
        hiddenSolids = restored.hidden; selectedSolids = restored.selected
        selectedPartNodeIDs = PartSelection.nodeIDs(for: selectedSolids, keeping: selectedPartNodeIDs, in: partTree)
    }

    /// Kernel versions can enumerate the same named solids in a different
    /// order. Retain user structure and names, replacing only solid ownership.
    static func restoredPartState(for revision: ProjectRevision, preview: PreviewMesh, selected: Set<Int>) throws
        -> (parts: [PartNode], layout: PartLayout?, hidden: Set<Int>, selected: Set<Int>) {
        let generated = Self.defaultParts(for: preview)
        let previous = revision.parts ?? revision.partLayout?.nodes ?? generated
        try ProjectStore.validatePartHierarchy(previous, solidCount: preview.solids)
        try ProjectStore.validatePartHierarchy(generated, solidCount: preview.solids)
        let oldOwners = Dictionary(uniqueKeysWithValues: previous.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map { ($0.id, $0.solidIndices) })
        let newOwners = Dictionary(uniqueKeysWithValues: generated.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map { ($0.id, $0.solidIndices) })
        let generic = oldOwners.allSatisfy { id, indices in indices.count == 1 && id == "solid/\(indices[0])" }
        var mapping: [Int: Int] = [:]
        if generic {
            // Early generic-only histories have no semantic identities; their
            // program order is the sole available ownership reference.
            mapping = Dictionary(uniqueKeysWithValues: (0..<preview.solids).map { ($0, $0) })
        } else {
            guard Set(oldOwners.keys) == Set(newOwners.keys) else {
                throw LADError.message("The saved program rebuilt different part identities. Use Rebuild Design to reconcile the changed geometry.")
            }
            for (identity, oldIndices) in oldOwners {
                guard let newIndices = newOwners[identity], oldIndices.count == newIndices.count else {
                    throw LADError.message("The saved program rebuilt a different number of solids for a part. Use Rebuild Design to reconcile the changed geometry.")
                }
                for (old, new) in zip(oldIndices, newIndices) { mapping[old] = new }
            }
        }
        func remapped(_ nodes: [PartNode]) -> [PartNode] {
            nodes.map { node in
                var updated = node
                updated.solidIndices = node.solidIndices.compactMap { mapping[$0] }
                if let children = node.children { updated.children = remapped(children) }
                return updated
            }
        }
        var layout = revision.partLayout
        if let original = layout { layout?.nodes = remapped(original.nodes) }
        if let layout { try ProjectStore.validatePartHierarchy(layout.nodes, solidCount: preview.solids) }
        return (remapped(previous), layout, Set((revision.hiddenSolids ?? []).compactMap { mapping[$0] }),
                Set(selected.compactMap { mapping[$0] }))
    }

    private static func defaultParts(for preview: PreviewMesh) -> [PartNode] {
        preview.parts ?? (0..<preview.solids).map {
            PartNode(id: "solid/\($0)", name: "Part \($0 + 1)", solidIndices: [$0])
        }
    }

    private func projectSnapshot() -> LADProject {
        // Editing borrows the composer, but its temporary text and control
        // choices must never overwrite the user's suspended unsent request.
        let draft = queuedRequestComposerDraft
        let draftPrompt = draft?.prompt ?? prompt
        let draftAttachments = draft?.attachments ?? pendingAttachments
        return LADProject(messages: messages, revisions: revisions, selectedRevisionID: selectedRevisionID,
                   projectID: projectID, codexSettings: draft?.codexSettings ?? codexSettings, projectName: projectName,
                   showGrid: showGrid, projectionMode: projectionMode, displayMode: displayMode,
                   recentPartColors: recentPartColors.isEmpty ? nil : recentPartColors,
                   taskAudits: taskAudits.isEmpty ? nil : taskAudits,
                   queuedRequests: queuedRequests.isEmpty ? nil : queuedRequests,
                   draftPrompt: draftPrompt.isEmpty ? nil : draftPrompt,
                   draftAttachments: draftAttachments.isEmpty ? nil : draftAttachments,
                   queuePaused: queuedRequests.isEmpty ? nil : queuePaused,
                   partsPaneFraction: partsPaneFraction, fileOrigin: projectFileOrigin,
                   thumbnailData: currentProjectThumbnailPresentation() == projectThumbnailImagePresentation ? projectThumbnailData : nil)
    }

    /// This descriptor is cheap to compare during an unrelated autosave. Its
    /// generation changes only for the selected recipe or effective colors.
    private func currentProjectThumbnailPresentation() -> ProjectThumbnailPresentation? {
        guard let revision = revisions.first(where: { $0.id == selectedRevisionID }) else { return nil }
        return ProjectThumbnailPresentation(revisionID: revision.id, generation: projectThumbnailRevisionGeneration,
            validationHash: revision.validatedHash, projection: projectionMode, display: displayMode, hiddenSolids: hiddenSolids)
    }

    private static func projectThumbnailNodes(_ revision: ProjectRevision) -> [PartNode] {
        revision.partLayout?.nodes ?? revision.parts ?? revision.preview?.parts ?? []
    }

    private func projectThumbnailRevisionsChanged(from previous: [ProjectRevision]) {
        // An unrendered history selection can still retain the previous
        // version's image. Editing that inactive version must invalidate it.
        if let imageID = projectThumbnailImagePresentation?.revisionID, imageID != selectedRevisionID,
           Self.projectThumbnailRevisionChanged(previous.first(where: { $0.id == imageID }),
                                                revisions.first(where: { $0.id == imageID })) {
            projectThumbnailInput = nil; projectThumbnailData = nil; projectThumbnailImagePresentation = nil
        }
        let old = previous.first(where: { $0.id == selectedRevisionID })
        let new = revisions.first(where: { $0.id == selectedRevisionID })
        guard Self.projectThumbnailRevisionChanged(old, new) else { return }
        projectThumbnailRevisionGeneration &+= 1
        if var image = projectThumbnailImagePresentation, image.revisionID != selectedRevisionID {
            // The inactive-image check above proved this other version's
            // presentation unchanged. A selected version's edits must not
            // invalidate that image when navigation returns to its owner.
            image.generation = projectThumbnailRevisionGeneration
            projectThumbnailImagePresentation = image
        }
        projectThumbnailInputKey = nil; projectThumbnailCachedInput = nil
        scheduleProjectThumbnail()
    }

    private static func projectThumbnailRevisionChanged(_ old: ProjectRevision?, _ new: ProjectRevision?) -> Bool {
        var changed = !sameProjectThumbnailRecipe(old?.model, new?.model) || old?.validatedHash != new?.validatedHash || old?.jointPositions != new?.jointPositions
        if !changed, let old, let new {
            let oldNodes = Self.projectThumbnailNodes(old), newNodes = Self.projectThumbnailNodes(new)
            if oldNodes != newNodes || old.partColors != new.partColors {
                changed = PartColorState.solidColors(in: oldNodes, overrides: old.partColors ?? [:]) !=
                          PartColorState.solidColors(in: newNodes, overrides: new.partColors ?? [:])
            }
        }
        return changed
    }

    private static func sameProjectThumbnailRecipe(_ first: ModelSpec?, _ second: ModelSpec?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        let firstInputs = first.inputAssets ?? [], secondInputs = second.inputAssets ?? []
        return first.units == second.units && first.script == second.script && first.sourceSTEP == second.sourceSTEP &&
            firstInputs.count == secondInputs.count && zip(firstInputs, secondInputs).allSatisfy { pair in
                pair.0.id == pair.1.id && pair.0.format == pair.1.format && pair.0.data == pair.1.data
            }
    }

    private func currentProjectThumbnailInput() -> ProjectThumbnail.Input? {
        guard let mesh, let selectedRevisionID, builtRevisionID == selectedRevisionID,
              Self.sameProjectThumbnailRecipe(current, projectThumbnailMeshModel),
              let presentation = currentProjectThumbnailPresentation(),
              presentation.validationHash == mesh.validatedHash else { return nil }
        let key = ProjectThumbnailInputKey(presentation: presentation, geometryPath: mesh.stepPath, nativePath: mesh.brepPath)
        if key == projectThumbnailInputKey { return projectThumbnailCachedInput }
        let input = ProjectThumbnail.Input(revisionID: selectedRevisionID, geometryPath: mesh.stepPath,
            nativePath: mesh.brepPath, validationHash: mesh.validatedHash,
            projection: projectionMode, display: displayMode, hiddenSolids: hiddenSolids, solidColors: solidColors)
        projectThumbnailInputKey = key; projectThumbnailCachedInput = input
        projectThumbnailWork.inputResolutions += 1
        return input
    }

    private func cancelProjectThumbnail(clearImage: Bool = true) {
        projectThumbnailToken = UUID()
        projectThumbnailTask?.cancel(); projectThumbnailTask = nil
        if clearImage {
            projectThumbnailInput = nil; projectThumbnailData = nil; projectThumbnailImagePresentation = nil
            projectThumbnailInputKey = nil; projectThumbnailCachedInput = nil
        }
    }

    /// Coalesce presentation edits without delaying typing, geometry acceptance,
    /// or normal saves. Stale captures cannot attach to a replacement design.
    private func scheduleProjectThumbnail() {
        projectThumbnailTask?.cancel()
        let token = UUID(), session = projectSessionID
        projectThumbnailToken = token
        projectThumbnailTask = nil
        guard projectReady, let input = currentProjectThumbnailInput(),
              let presentation = currentProjectThumbnailPresentation() else { return }
        if presentation == projectThumbnailImagePresentation, projectThumbnailData != nil,
           projectThumbnailInput == input || (presentation.validationHash != nil && presentation.validationHash == input.validationHash) {
            if projectThumbnailInput != input { projectThumbnailWork.reusedImages += 1 }
            projectThumbnailInput = input
            return
        }
        projectThumbnailWork.scheduledRenders += 1
        projectThumbnailTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self, self.projectSessionID == session, self.projectThumbnailToken == token,
                      self.currentProjectThumbnailPresentation() == presentation,
                      self.currentProjectThumbnailInput() == input, let preview = self.posedPreview else { return }
                self.projectThumbnailWork.renders += 1
                let data = try await self.projectThumbnailRenderer(preview, input)
                guard !Task.isCancelled, self.projectSessionID == session, self.projectThumbnailToken == token,
                      self.currentProjectThumbnailPresentation() == presentation,
                      self.currentProjectThumbnailInput() == input else { return }
                self.projectThumbnailInput = input
                self.projectThumbnailData = data
                self.projectThumbnailImagePresentation = presentation
                self.projectThumbnailTask = nil
                self.autosave()
            } catch {
                // Finder can fall back to the registered LAD icon. Thumbnail
                // failure must never fail a required save or interrupt CAD work.
                guard let self, self.projectSessionID == session, self.projectThumbnailToken == token else { return }
                self.projectThumbnailTask = nil
            }
        }
    }
}

extension AppState {
    var agentStateToken: String { "\(projectSessionID.uuidString):\(agentStateGeneration)" }

    func agentSnapshot() -> ProjectAgentSnapshot {
        ProjectAgentSnapshot(projectID: projectID, editingID: projectSessionID, stateToken: agentStateToken,
            current: current, preview: builtRevisionID == selectedRevisionID ? posedPreview : nil,
            versions: ProjectVersionContext(revisions: revisions, selectedRevisionID: selectedRevisionID),
            partLayout: selectedPartLayout, partColors: revisions.first(where: { $0.id == selectedRevisionID })?.partColors ?? [:],
            hiddenSolids: hiddenSolids, solidColors: solidColors)
    }

    func beginExternalAgentAudit(id: UUID, client: ProjectExternalAgentIdentity, request: String,
                                 model: String? = nil, effort: String? = nil) throws {
        guard projectReady, !preserveUnreadableSession, taskAudits.count < 10_000 else {
            throw LADError.message("The design is unavailable for another agent task.")
        }
        let audit = ProjectTaskAudit(id: id, model: model, reasoningEffort: effort, externalClient: client, request: request)
        try ProjectStore.validateTaskAudits([audit], messages: messages, revisionIDs: Set(revisions.map(\.id)))
        taskAudits.append(audit)
        projectSavingEnabled = true
        autosave()
    }

    func finishExternalAgentAudit(id: UUID, status: String) {
        guard let index = taskAudits.firstIndex(where: { $0.id == id }), taskAudits[index].externalClient != nil,
              taskAudits[index].status == "running" else { return }
        taskAudits[index].status = status
        taskAudits[index].finishedAt = Date()
        for item in taskAudits[index].events.indices where taskAudits[index].events[item].status == "running" {
            taskAudits[index].events[item].status = status == "completed" ? "interrupted" : status
        }
        autosave()
    }

    func externalAgentReceipt(clientID: String, key: String) -> ProjectTaskAudit? {
        taskAudits.first { $0.externalClient?.clientID == clientID && $0.commitKey == key }
    }

    func commitExternalAgent(_ candidate: ProjectAgentCandidate, taskID: UUID, artifactID: String,
                             expectedStateToken: String, key: String, snapshot: ProjectAgentSnapshot) throws -> UUID {
        guard projectReady, !preserveUnreadableSession, projectID == snapshot.projectID,
              projectSessionID == snapshot.editingID, agentStateToken == expectedStateToken,
              expectedStateToken == snapshot.stateToken, !isWorking else {
            throw ProjectAgentError.conflict("The design changed or is busy. Start a new task against its current state before committing.")
        }
        guard let index = taskAudits.firstIndex(where: { $0.id == taskID }), taskAudits[index].status == "running",
              taskAudits[index].externalClient != nil else { throw ProjectAgentError.unavailable }
        try ProjectStore.validateModel(candidate.model)
        guard revisions.count < 1_000 else { throw LADError.message("The design already has the maximum number of versions.") }
        let revisionID: UUID
        if artifactID == "current", let selectedRevisionID, current == candidate.model {
            try applyAgentPartColorChanges(candidate.colorChanges, to: selectedRevisionID,
                matching: current, startedWith: snapshot.partColors)
            revisionID = selectedRevisionID
        } else {
            revisionID = try appendValidatedRevision(candidate.model, preview: candidate.preview,
                previousLayout: selectedPartLayout, previouslyHidden: hiddenPartIDs,
                previousColors: Self.completePartColors(in: partTree, stored: revisions.first(where: { $0.id == selectedRevisionID })?.partColors ?? [:]),
                colorChanges: candidate.colorChanges, startedColors: snapshot.partColors)
        }
        taskAudits[index].committedRevisionID = revisionID
        taskAudits[index].commitKey = key
        taskAudits[index].commitArtifactID = artifactID
        taskAudits[index].status = "completed"
        taskAudits[index].finishedAt = Date()
        error = nil
        autosave()
        return revisionID
    }

    /// Await the existing writer without canceling any other design work.
    func flushExternalAgentCommit() async throws { try await flushProject() }

    var agentPersistenceStatus: [String: Any] {
        var value: [String: Any] = ["status": hasUnsavedChanges ? "pending" : (projectURL == nil ? "memory" : "saved")]
        if let saveStatus, saveStatus.hasPrefix("Not saved:") { value["status"] = "failed"; value["error"] = saveStatus }
        return value
    }
}

/// The CLI calls back from its stream reader. Queue complete message snapshots
/// there, then apply them on the main actor. An explicit final drain preserves
/// ordering even when queued UI notifications run after the process finishes.
final class CodexConversationFeedback: @unchecked Sendable {
    struct Update {
        var changed: Bool
        var activity: String?
        var events: [ProjectActivityEvent]
    }

    private let lock = NSLock()
    private var pending: [String: String] = [:]
    private var order: [String] = []
    private var knownItems: Set<String> = []
    private var messageIDs: [String: UUID] = [:]
    private var latestActivity: String?
    private var closed = false
    private var pendingEvents = [String: ProjectActivityEvent]()
    private var eventOrder = [String]()

    func enqueue(_ event: ProjectActivityEvent, scope: String) {
        var scoped = event
        scoped.id = scope + ":" + event.id
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if pendingEvents[scoped.id] == nil { eventOrder.append(scoped.id) }
        pendingEvents[scoped.id] = scoped
    }

    func enqueue(_ message: CodexProgressMessage, scope: String) {
        let text = String(message.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !text.isEmpty, message.id.utf8.count <= 1_024, scope.utf8.count <= 128 else { return }
        let key = scope + "\u{1f}" + message.id
        lock.lock(); defer { lock.unlock() }
        guard !closed, knownItems.contains(key) || knownItems.count < 128 else { return }
        knownItems.insert(key)
        if pending[key] == nil { order.append(key) }
        pending[key] = text
    }

    func enqueueActivity(_ activity: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        latestActivity = String(activity.prefix(256))
    }

    @MainActor
    func apply(to messages: inout [ChatMessage]) -> Update {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for key in order {
            guard let text = pending[key] else { continue }
            if let id = messageIDs[key], let index = messages.firstIndex(where: { $0.id == id }) {
                if messages[index].content != text {
                    messages[index].content = text
                    changed = true
                }
            } else {
                // Repeated commentary from a new stream item adds no useful
                // transcript entry. A later different update still gets one.
                guard messages.last?.phase != "commentary" || messages.last?.content != text else { continue }
                let message = ChatMessage(role: "assistant", content: text, phase: "commentary")
                messages.append(message)
                messageIDs[key] = message.id
                changed = true
            }
        }
        let activity = latestActivity
        let events = eventOrder.compactMap { pendingEvents[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        latestActivity = nil
        pendingEvents.removeAll(keepingCapacity: true); eventOrder.removeAll(keepingCapacity: true)
        return Update(changed: changed || !events.isEmpty, activity: activity, events: events)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        pending.removeAll(); order.removeAll(); latestActivity = nil
        pendingEvents.removeAll(); eventOrder.removeAll()
    }
}
