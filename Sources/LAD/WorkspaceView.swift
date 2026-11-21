import SwiftUI

@MainActor
final class ViewportSectionControl: ObservableObject {
    @Published var isEnabled = false
}

@MainActor
private final class WorkspaceViewportReference: ObservableObject {
    let assemblyGrabOwnerID = UUID()
    weak var view: CADSceneView?
    weak var window: NSWindow?
    private weak var cube: ViewportOrientationCube?
    @Published private(set) var gridSpacing: Double?

    func bindViewport(_ view: CADSceneView) {
        guard self.view !== view else { return }
        self.view?.onCameraOrientationChanged = nil
        self.view?.onGridSpacingChanged = nil
        self.view = view
        view.onCameraOrientationChanged = { [weak self] right, up, backward in
            self?.cube?.setOrientation(right: right, up: up, backward: backward)
        }
        view.onGridSpacingChanged = { [weak self, weak view] _ in
            // Grid rebuilding can occur during updateNSView. Publish the latest
            // drawn spacing after SwiftUI finishes that update.
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, self.view === view,
                      self.gridSpacing != view.gridSpacing else { return }
                self.gridSpacing = view.gridSpacing
            }
        }
    }

    func bindCube(_ cube: ViewportOrientationCube) {
        guard self.cube !== cube else { return }
        self.cube?.onSelectCorner = nil
        self.cube?.onSelectFace = nil
        self.cube = cube
        cube.onSelectFace = { [weak self] face in self?.view?.selectOrientationCubeFace(face) }
        cube.onSelectCorner = { [weak self] corner in self?.view?.selectOrientationCubeCorner(corner) }
        if let orientation = view?.cameraOrientation {
            cube.setOrientation(right: orientation.right, up: orientation.up, backward: orientation.backward)
        }
    }

    func unbindCube(_ cube: ViewportOrientationCube) {
        guard self.cube === cube else { return }
        cube.onSelectCorner = nil
        cube.onSelectFace = nil
        self.cube = nil
    }
}

private struct ViewportOrientationCubeControl: NSViewRepresentable {
    let reference: WorkspaceViewportReference

    func makeNSView(context: Context) -> ViewportOrientationCube {
        let cube = ViewportOrientationCube(frame: .zero)
        reference.bindCube(cube)
        return cube
    }

    func updateNSView(_ cube: ViewportOrientationCube, context: Context) { reference.bindCube(cube) }

    func makeCoordinator() -> WorkspaceViewportReference { reference }

    static func dismantleNSView(_ cube: ViewportOrientationCube, coordinator: WorkspaceViewportReference) {
        coordinator.unbindCube(cube)
    }
}

/// Each pane is its own view, so Observation re-renders only the pane whose
/// state changed: typing updates the composer, streamed messages the
/// conversation, and selection the viewer.
struct WorkspaceView: View {
    let state: AppState
    @State private var promptFocused = false
    @FocusState private var projectNameFocused: Bool
    @State private var isRenamingProject = false
    @State private var projectNameDraft = ""
    @State private var projectRenameError: String?
    @State private var renamingProjectID: UUID?
    @State private var isProgramExpanded = false
    @State private var previewImageAttachment: SourceAttachment?
    @StateObject private var activityPanel = ProjectActivityPanelController()
    @StateObject private var viewportReference = WorkspaceViewportReference()
    @StateObject private var sectionControl = ViewportSectionControl()
    @State private var conversationSearch: ConversationSearchController

    init(state: AppState, conversationSearch: ConversationSearchController? = nil) {
        self.state = state
        _conversationSearch = State(initialValue: conversationSearch ?? ConversationSearchController())
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Palette.line).frame(height: 1)
            HSplitView {
                partsPanel.frame(minWidth: 180, idealWidth: 230, maxWidth: 340, maxHeight: .infinity)
                WorkspaceViewer(state: state, viewportReference: viewportReference, sectionControl: sectionControl)
                    .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                WorkspaceConversation(state: state, activityPanel: activityPanel, viewportReference: viewportReference,
                                      search: conversationSearch,
                                      promptFocused: $promptFocused, previewImageAttachment: $previewImageAttachment)
                    .frame(minWidth: 340, idealWidth: 390, maxWidth: 520, maxHeight: .infinity)
            }
            WorkspaceStatusBar(state: state)
        }
        // The header takes the place of the hidden title bar.
        .ignoresSafeArea(.container, edges: .top)
        .background(Palette.background)
        .background(ProjectActivityWindowAnchor {
            viewportReference.window = $0
            state.presentSaveConflict(in: $0)
        })
        .focusedSceneValue(\.conversationSearch, conversationSearch)
        .focusedSceneObject(sectionControl)
        .onChange(of: state.projectEditingID) { _, _ in
            cancelProjectRename()
            sectionControl.isEnabled = false
            isProgramExpanded = false
            previewImageAttachment = nil
            activityPanel.close()
            conversationSearch.hide()
        }
        .onChange(of: state.selectedRevisionID) { _, _ in sectionControl.isEnabled = false }
        .onChange(of: state.printLayoutView) { _, enabled in
            if enabled { sectionControl.isEnabled = false }
        }
        .onDisappear { activityPanel.close() }
        .onChange(of: state.canRenameProject) { _, allowed in
            if !allowed { cancelProjectRename() }
        }
        .onChange(of: state.saveConflict) { _, conflict in
            if conflict != nil { state.presentSaveConflict(in: viewportReference.window) }
        }
        .sheet(item: $previewImageAttachment) { attachment in PromptImagePreview(attachment: attachment) }
    }

    private var topBar: some View {
        WorkspaceHeaderLayout(leadingReserve: WindowHeaderChrome.windowButtonsWidth, spacing: 14) {
            projectName
                .frame(maxWidth: .infinity)
                // Use the header's bottom padding for transient feedback;
                // changing save state must not resize the header or viewport.
                .overlay(alignment: .bottom) {
                    if let message = projectRenameError ?? state.saveStatus {
                        Group {
                            if projectRenameError == nil, state.saveConflict != nil {
                                Button { state.retrySaveConflict(in: viewportReference.window) } label: { Text(message).underline() }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Choose how to save the conflicting design")
                            } else { Text(message) }
                        }
                            .font(.system(size: 10)).foregroundStyle(Palette.accent)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity)
                            .offset(y: 14)
                            .help(message)
                            .accessibilityLabel(projectRenameError == nil ? message : "Design name error: \(message)")
                    }
                }
            HStack(spacing: 14) {
                Button { state.saveNewProject() } label: {
                    Label("Save New", systemImage: "square.and.arrow.down").frame(height: 30)
                }
                .help("Save the latest design as a new file (⌘S)")
                .disabled(!state.canSaveNew)
                Button { state.exportSTEP() } label: {
                    // A 28-point label gives the prominent bezel a 30-point height.
                    HStack(spacing: 7) { Image(systemName: "arrow.up.right.square"); Text("Export STEP").fontWeight(.semibold) }
                        .padding(.horizontal, 8).frame(height: 28)
                }
                .buttonStyle(.borderedProminent).disabled(!state.canExport)
            }
            .fixedSize()
            .padding(.trailing, 16)
        }
        .buttonStyle(.borderless)
        .frame(height: WindowHeaderChrome.height)
        .background(WindowHeaderChrome())
        .background(Palette.panel)
    }

    @ViewBuilder
    private var projectName: some View {
        if isRenamingProject {
            // The hidden text sizes the field to its contents, so the name
            // stays centered where it was shown while it is edited.
            Text(projectNameDraft)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .frame(minWidth: 120)
                .padding(.horizontal, 6)
                .hidden()
                .accessibilityHidden(true)
                .overlay {
                    TextField("Design name", text: $projectNameDraft)
                        .font(.system(size: 13, weight: .semibold))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .focused($projectNameFocused)
                        .accessibilityLabel("Design name")
                        .accessibilityIdentifier("projectNameField")
                        .onSubmit { finishProjectRename() }
                        .onExitCommand { cancelProjectRename() }
                        .onChange(of: projectNameFocused) { _, focused in
                            if !focused { cancelProjectRename() }
                        }
                        .onChange(of: projectNameDraft) { _, _ in projectRenameError = nil }
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.accent.opacity(0.6), lineWidth: 1))
                .background(ProjectRenameOutsideClickRegion(onCancel: cancelProjectRename))
                .task {
                    await Task.yield()
                    if !Task.isCancelled, isRenamingProject { projectNameFocused = true }
                }
        } else {
            Button {
                guard state.canRenameProject else { return }
                projectNameDraft = state.projectDisplayName
                projectRenameError = nil
                renamingProjectID = state.projectEditingID
                isRenamingProject = true
            } label: {
                Text(state.projectDisplayName)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.canRenameProject)
            .accessibilityLabel("Rename design")
            .accessibilityValue(state.projectDisplayName)
            .help(state.projectURL?.path ?? "Rename design")
        }
    }

    private func finishProjectRename() {
        guard isRenamingProject else { return }
        guard state.canRenameProject, renamingProjectID == state.projectEditingID else {
            cancelProjectRename()
            return
        }
        do {
            try state.renameProject(to: projectNameDraft)
            cancelProjectRename()
        } catch {
            projectRenameError = error.localizedDescription
            projectNameFocused = true
        }
    }

    private func cancelProjectRename() {
        isRenamingProject = false
        renamingProjectID = nil
        projectRenameError = nil
        projectNameFocused = false
    }

    private var partsPanel: some View {
        ProjectSidebarSplitView(state: state, isProgramExpanded: $isProgramExpanded,
                                showsSection: sectionControl.isEnabled && state.displayedMesh != nil && !state.printLayoutView)
        .background(Palette.panel)
        .accessibilityIdentifier("projectSidebarSplitView")
    }
}

/// Centers the design name in the header, truncating it before it reaches the
/// window buttons or the trailing actions.
private struct WorkspaceHeaderLayout: Layout {
    let leadingReserve: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.replacingUnspecifiedDimensions().width,
               height: proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let name = subviews[0], actions = subviews[1]
        let actionsSize = actions.sizeThatFits(.unspecified)
        actions.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(actionsSize))
        let reserve = max(leadingReserve, actionsSize.width) + spacing
        name.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                   proposal: ProposedViewSize(width: max(0, bounds.width - 2 * reserve), height: nil))
    }
}

/// The 3D view and its overlay controls.
private struct WorkspaceViewer: View {
    @Bindable var state: AppState
    @ObservedObject var viewportReference: WorkspaceViewportReference
    @ObservedObject var sectionControl: ViewportSectionControl

    private var canSection: Bool { state.displayedMesh != nil && !state.printLayoutView }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CADViewport(mesh: state.displayedMesh, displayMode: state.displayMode, projectionMode: state.projectionMode, showGrid: state.showGrid,
                        command: state.viewportCommand,
                        selectedSolids: state.selectedSolids, hiddenSolids: state.hiddenSolids, solidColors: state.solidColors,
                        selectedFeatures: state.selectedFeatures,
                        solidTransforms: state.displayedSolidTransforms, cameraKey: state.viewportCameraKey,
                        sectionEnabled: sectionControl.isEnabled, canSection: canSection,
                        onSectionFromFace: { sectionControl.isEnabled = true },
                        onSelectionChanged: { state.selectParts($0) },
                        onFeatureSelectionChanged: { state.selectFeatures($0) }, onDeselectAll: { state.clearSelections() },
                        onHideSelected: { state.hideSelectedParts() }, onShowAll: { state.showAllParts() },
                        canExport: state.canExport, onExportSelectedPartsSTEP: { state.exportSelectedPartsSTEP() },
                        onExportFaceDXF: { state.exportFaceDXF($0) },
                        onViewReady: { view in
                            viewportReference.bindViewport(view)
                            if view.window?.isKeyWindow == true || state.viewportView == nil { state.viewportView = view }
                        },
                        assemblyGrabbingEnabled: state.canManipulateAssembly,
                        onAssemblyGrabBegan: { solid, point, projection in
                            state.beginAssemblyGrab(ownerID: viewportReference.assemblyGrabOwnerID, solidIndex: solid,
                                                    point: point, projection: projection)
                        },
                        onAssemblyGrabMoved: { point in
                            state.moveAssemblyGrab(ownerID: viewportReference.assemblyGrabOwnerID, screenPoint: point)
                        },
                        onAssemblyGrabEnded: { state.endAssemblyGrab(ownerID: viewportReference.assemblyGrabOwnerID) },
                        onAssemblyGrabCancelled: { state.cancelAssemblyGrab(ownerID: viewportReference.assemblyGrabOwnerID) })
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            viewportToggle($sectionControl.isEnabled, label: "Section View", help: "Toggle section view",
                                           icon: Image(systemName: "square.split.diagonal"))
                                .disabled(!canSection)
                                .accessibilityIdentifier("sectionViewToggle")
                            viewportToggle($state.showGrid, label: "Grid", help: "Toggle grid",
                                           icon: Image(systemName: "grid"))
                            if state.showGrid, let gridSpacing = viewportReference.gridSpacing {
                                let spacing = gridSpacing.formatted(.number.precision(.fractionLength(0...2)))
                                Text("\(spacing) mm")
                                    .font(.system(size: 12)).monospacedDigit()
                                    .foregroundStyle(Palette.muted).fixedSize()
                                    .help("Grid square size")
                                    .accessibilityLabel("Grid square size: \(spacing) millimetres")
                                    .accessibilityIdentifier("gridSquareSize")
                            }
                        }
                        HStack(spacing: 8) {
                            viewportToggle($state.printVersionView, label: "3D Printing Version",
                                           help: "3D printing version", icon: PrinterIcon().frame(width: 19, height: 19))
                            viewportToggle($state.printLayoutView, label: "3D Printing Layout",
                                           help: "3D printing orientation and layout", icon: PrintLayoutIcon().frame(width: 19, height: 19))
                        }
                    }
                    Spacer()
                    ViewportOrientationCubeControl(reference: viewportReference).frame(width: 108, height: 108)
                }.padding(22)
                Spacer()
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Picker("Projection", selection: $state.projectionMode) {
                        Text("Perspective").tag(ViewportProjectionMode.perspective)
                        Text("Isometric").tag(ViewportProjectionMode.isometric)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    Picker("Display", selection: $state.displayMode) {
                        Text("Shaded").tag(ViewportDisplayMode.shaded)
                        Text("Edges").tag(ViewportDisplayMode.edges)
                        Text("Translucent").tag(ViewportDisplayMode.translucent)
                        Text("Wire").tag(ViewportDisplayMode.wireframe)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                }
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 22).padding(.vertical, 12).background(Palette.panel.opacity(0.7))
            }
            if state.displayedMesh == nil {
                let preparing = state.isWorking || state.isPreparingPrintView
                VStack(spacing: 12) {
                    if preparing { ProgressView().controlSize(.large) }
                    else { Image(systemName: "cube.transparent").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Palette.muted) }
                    Text(preparing ? "Preparing your design" : "Your design starts here").font(.system(size: 17, weight: .medium))
                    if !preparing {
                        Text("Describe a part in the conversation to get started.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
        }.background(Palette.background)
    }

    private func viewportToggle<Icon: View>(_ isOn: Binding<Bool>, label: String, help: String, icon: Icon) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return Button { isOn.wrappedValue.toggle() } label: {
            icon.frame(width: 28, height: 28)
                .foregroundStyle(isOn.wrappedValue ? Palette.accent : Palette.muted)
                .padding(5)
                .background(Palette.panel.opacity(0.93), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help).accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }
}

/// The conversation column. Messages and the composer are separate views so
/// typing does not re-render the message history.
private struct WorkspaceConversation: View {
    let state: AppState
    @ObservedObject var activityPanel: ProjectActivityPanelController
    @ObservedObject var viewportReference: WorkspaceViewportReference
    let search: ConversationSearchController
    @Binding var promptFocused: Bool
    @Binding var previewImageAttachment: SourceAttachment?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle").foregroundStyle(Palette.accent)
                Text("Design").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { search.toggle() } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(search.isVisible ? Palette.accent : Palette.muted)
                }
                .buttonStyle(.plain).help(search.isVisible ? "Hide search" : "Search conversation (⌘F)")
                .accessibilityLabel("Search Conversation").accessibilityValue(search.isVisible ? "Shown" : "Hidden")
                Button { activityPanel.toggle(state: state, owner: viewportReference.window ?? viewportReference.view?.window) } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(activityPanel.isVisible ? Palette.accent : Palette.muted)
                }
                .buttonStyle(.plain).help(activityPanel.isVisible ? "Hide tool activity" : "Show tool activity")
                .accessibilityLabel("Tool Activity").accessibilityValue(activityPanel.isVisible ? "Shown" : "Hidden")
            }.padding(.horizontal, 20).padding(.vertical, 19)
            Rectangle().fill(Palette.line).frame(height: 1)
            WorkspaceMessageList(state: state, search: search, onPreview: { previewImageAttachment = $0 })
            if let error = state.error { errorPanel(error) }
            if !state.queuedRequests.isEmpty {
                ProjectRequestQueueView(state: state).padding(.horizontal, 16).padding(.top, 6)
            }
            WorkspaceComposer(state: state, promptFocused: $promptFocused, previewImageAttachment: $previewImageAttachment)
        }.background(Palette.panel)
    }

    private func errorPanel(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Needs attention", systemImage: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold))
                Spacer()
                CopyButton(text: error, label: "Copy error")
                Button { state.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.foregroundStyle(Palette.accent)
            ViewThatFits(in: .vertical) {
                errorText(error).fixedSize(horizontal: false, vertical: true)
                ScrollView { errorText(error) }
            }.frame(maxHeight: 96)
        }.padding(13).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func errorText(_ error: String) -> some View {
        Text(error).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceMessageList: View {
    let state: AppState
    let search: ConversationSearchController
    let onPreview: (SourceAttachment) -> Void
    @State private var textWidth = ConversationTextWidth()
    /// Version navigation keeps its request in place instead of following
    /// replay activity to the bottom, until the conversation changes.
    @State private var heldMessageID: UUID?
    @State private var highlightedFocus: AppState.ConversationFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let textFontSize: CGFloat = 12
    private static let textLineSpacing: CGFloat = 5
    private static let userMessagePadding: CGFloat = 13

    private var searchMatches: [ConversationSearchMatch] {
        search.isActive ? ConversationSearch.matches(in: state.messages, for: search.query) : []
    }

    var body: some View {
        let matches = searchMatches
        let current = matches.isEmpty ? nil : min(search.index, matches.count - 1)
        let highlights = Dictionary(grouping: matches, by: \.messageID)
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if search.isVisible {
                    ConversationSearchBar(search: search, current: current)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 8) {
                            Rectangle().fill(Palette.line).frame(height: 1)
                            Text("DESIGN CONVERSATION").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundStyle(Palette.muted).fixedSize()
                            Rectangle().fill(Palette.line).frame(height: 1)
                        }.padding(.top, 6)
                        ForEach(state.messages) { message in
                            messageView(message, highlights: highlights[message.id], current: current.map { matches[$0] })
                                .id(message.id)
                        }
                        if state.isWorking {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(state.activityStatus).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }.id("activity")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    // Read only when revealing a match; resizing must not
                    // re-render the conversation.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth.value = $0 }
                    .padding(20)
                }
            }
            // Keep a found match in place while the conversation continues.
            .onChange(of: state.messages.count) { _, _ in
                heldMessageID = nil
                if !search.isActive { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: state.messages.last?.content) { _, _ in
                if state.isWorking, !search.isActive, heldMessageID == nil { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: state.isWorking) { _, _ in
                if !search.isActive, heldMessageID == nil { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: state.conversationFocus) { _, focus in
                guard let focus else { return }
                heldMessageID = focus.messageID
                guard focus.reveals else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(focus.messageID, anchor: .top) }
                highlightedFocus = focus
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard highlightedFocus?.id == focus.id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { highlightedFocus = nil }
                }
            }
            .onChange(of: matches.count, initial: true) { _, count in search.matchCount = count }
            .onChange(of: search.query) { _, _ in revealMatch(0, proxy: proxy) }
            .onChange(of: search.stepRequest) { _, step in
                guard let step else { return }
                let matches = searchMatches
                guard !matches.isEmpty else { return }
                revealMatch(ConversationSearch.step(from: min(search.index, matches.count - 1), count: matches.count,
                                                    forward: step.forward), proxy: proxy)
            }
        }
    }

    /// Selects a match and scrolls its line into view.
    private func revealMatch(_ index: Int, proxy: ScrollViewProxy) {
        search.index = index
        let matches = searchMatches
        guard matches.indices.contains(index),
              let message = state.messages.first(where: { $0.id == matches[index].messageID }) else { return }
        let width = textWidth.value - (message.role == "user" ? 2 * Self.userMessagePadding : 0)
        let fraction = ConversationSearch.verticalFraction(of: matches[index].range, in: message.content, width: width,
                                                           font: .systemFont(ofSize: Self.textFontSize),
                                                           lineSpacing: Self.textLineSpacing)
        // Aligning the same relative point of the text and the visible area
        // keeps the match's line on screen even in messages taller than it.
        proxy.scrollTo(ConversationSearchTextID(messageID: message.id), anchor: UnitPoint(x: 0, y: fraction))
    }

    private func messageText(_ message: ChatMessage, highlights: [ConversationSearchMatch]?,
                             current: ConversationSearchMatch?) -> Text {
        guard let highlights else { return Text(message.content) }
        var text = AttributedString(message.content)
        for match in highlights {
            guard let range = Range(match.range, in: text) else { continue }
            if match == current {
                text[range].backgroundColor = Palette.accent
                text[range].foregroundColor = Palette.background
            } else {
                text[range].backgroundColor = Palette.accent.opacity(0.3)
            }
        }
        return Text(text)
    }

    private func messageView(_ message: ChatMessage, highlights: [ConversationSearchMatch]?,
                             current: ConversationSearchMatch?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: message.role == "user" ? "person.crop.circle" : message.role == "system" ? "exclamationmark.circle" : "sparkle")
                    .foregroundStyle(message.role == "assistant" ? Palette.accent : Palette.muted)
                Text(message.role == "user" ? "YOU" : message.role == "system" ? "STATUS" :
                     message.phase == "commentary" ? "UPDATE" : message.phase == "final_answer" ? "COMPLETE" : "LAD")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted)
                Spacer()
                if message.role == "user" { RequestRevisionButton(state: state, message: message) }
                Text(message.date, style: .time).font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.6))
                CopyButton(text: message.content, label: "Copy message")
            }
            messageText(message, highlights: highlights, current: current)
                .font(.system(size: Self.textFontSize)).lineSpacing(Self.textLineSpacing)
                .foregroundStyle(Color.white.opacity(0.85)).textSelection(.enabled)
                .id(ConversationSearchTextID(messageID: message.id))
            if let attachments = message.attachments, !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    let images = attachments.filter(\.isImage)
                    if !images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(images) { attachment in
                                    PromptImageAttachmentView(attachment: attachment, onPreview: { onPreview(attachment) })
                                }
                            }
                        }.frame(height: 124)
                    }
                    ForEach(attachments.filter { !$0.isImage }) { attachment in
                        HStack(alignment: .top, spacing: 4) {
                            DisclosureGroup {
                                ScrollView([.horizontal, .vertical]) {
                                    Text(attachment.content).font(.system(size: 10, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 170).padding(.top, 6)
                            } label: {
                                Label(attachment.name, systemImage: "doc.text").font(.system(size: 10)).foregroundStyle(Palette.accent)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            CopyButton(text: attachment.content, label: "Copy \(attachment.name)")
                        }
                    }
                }
            }
        }
        .padding(message.role == "user" ? Self.userMessagePadding : 0)
        .background(message.role == "user" ? Palette.raised.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if highlightedFocus?.messageID == message.id {
                RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.accent, lineWidth: 1.5)
            }
        }
    }
}

/// Shows the design version a request was made on, with the request's selection.
private struct RequestRevisionButton: View {
    let state: AppState
    let message: ChatMessage

    var body: some View {
        if state.canShowRequestRevision(message), let id = message.requestRevisionID {
            let name = state.revisionName(for: id)
            let hasSelection = message.selection?.revisionID == id
            Button { state.showRequestRevision(messageID: message.id) } label: {
                HStack(spacing: 3) {
                    if hasSelection { Image(systemName: "scope").font(.system(size: 8, weight: .semibold)) }
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Palette.accent.opacity(0.1), in: Capsule())
                .frame(maxWidth: 140)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(state.isWorking)
            .opacity(state.isWorking ? 0.5 : 1)
            .help(hasSelection ? "Show \(name) with this request's selection" : "Show \(name)")
            .accessibilityLabel(hasSelection ? "Show version \(name) with selection" : "Show version \(name)")
        }
    }
}

private struct ConversationSearchTextID: Hashable {
    let messageID: UUID
}

private final class ConversationTextWidth {
    var value: CGFloat = 0
}

private struct ConversationSearchBar: View {
    @Bindable var search: ConversationSearchController
    let current: Int?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("Search conversation", text: $search.query)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit {
                    let event = NSApp.currentEvent
                    search.step(forward: !(event?.type == .keyDown && event?.modifierFlags.contains(.shift) == true))
                }
                .onExitCommand { search.hide() }
                .accessibilityLabel("Search conversation")
                .accessibilityIdentifier("conversationSearchField")
            Group {
                if search.isActive {
                    Text(current.map { "\($0 + 1) of \(search.matchCount)" } ?? "No matches")
                        .font(.system(size: 10)).monospacedDigit().fixedSize()
                        .accessibilityIdentifier("conversationSearchCount")
                    Button { search.step(forward: false) } label: { Image(systemName: "chevron.up") }
                        .help("Previous match (⇧⌘G)").accessibilityLabel("Previous match")
                        .disabled(!search.canStep)
                    Button { search.step(forward: true) } label: { Image(systemName: "chevron.down") }
                        .help("Next match (⌘G)").accessibilityLabel("Next match")
                        .disabled(!search.canStep)
                }
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
        }
        // Runs when the bar appears and for each later Find request.
        .task(id: search.focusRequest) {
            await Task.yield()
            if !Task.isCancelled { fieldFocused = true }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Palette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 12)
    }
}

private struct WorkspaceComposer: View {
    @Bindable var state: AppState
    @Binding var promptFocused: Bool
    @Binding var previewImageAttachment: SourceAttachment?

    var body: some View {
        let editingRequestID = state.editingQueuedRequestID
        let submissionLabel = editingRequestID != nil ? "Save queued request" :
            state.submissionWillQueue ? "Queue request" : state.awaitingResponse ? "Send reply" : "Generate design"
        let canSubmit = !state.isReadingPromptAttachments && (editingRequestID != nil ? state.canCommitQueuedRequest :
            !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.pendingAttachments.isEmpty)
        let submitRequest = {
            // A removed or replaced queued edit must not turn a stale action
            // into sending the restored draft.
            guard state.editingQueuedRequestID == editingRequestID else { return }
            state.submit()
        }
        return VStack(spacing: 10) {
            VStack(spacing: 5) {
                if state.editingQueuedRequestID != nil {
                    HStack {
                        Text("Edit queued request").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("Cancel") {
                            guard state.editingQueuedRequestID == editingRequestID else { return }
                            state.cancelEditingQueuedRequest()
                        }
                            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.muted)
                            .keyboardShortcut(.escape, modifiers: [])
                            .help("Cancel editing and restore your draft")
                            .accessibilityLabel("Cancel queued request edit")
                    }.padding(.bottom, 4)
                }
                if !state.pendingAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        let images = state.pendingAttachments.filter(\.isImage)
                        if !images.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 4) {
                                    ForEach(images) { attachment in
                                        PromptImageAttachmentView(attachment: attachment,
                                            onRemove: { state.removeAttachment(id: attachment.id) },
                                            onPreview: { previewImageAttachment = attachment })
                                    }
                                }
                            }.frame(height: 124)
                        }
                        ForEach(state.pendingAttachments.filter { !$0.isImage }) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").foregroundStyle(Palette.accent)
                                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button { state.removeAttachment(id: attachment.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Remove \(attachment.name)")
                            }.font(.system(size: 10)).padding(8).background(Palette.raised, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.padding(.bottom, 5)
                }
                ZStack(alignment: .topLeading) {
                    if state.prompt.isEmpty {
                        Text(state.awaitingResponse && editingRequestID == nil ? "Reply…" : "Describe your next design…")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 5).allowsHitTesting(false)
                    }
                    PromptTextEditor(text: $state.prompt, isFocused: promptFocused,
                        onFocus: { promptFocused = true }, onBlur: { promptFocused = false },
                        onAttachFiles: { state.attachSourceFiles(urls: $0) }, onAttachImages: { state.attachPromptImages($0) },
                        onSubmit: submitRequest, onDispatchNextQueuedRequest: {
                            if let next = state.queuedRequests.first { state.sendQueuedRequestNow(id: next.id) }
                            else { submitRequest() }
                        })
                        .frame(height: 78)
                        .accessibilityLabel("Design prompt")
                }
                HStack(spacing: 10) {
                    Button { state.attachSourceFiles(); promptFocused = true } label: {
                        Group {
                            if state.isReadingPromptAttachments { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "paperclip").font(.system(size: 13)) }
                        }.frame(width: 16, height: 16)
                    }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                        .disabled(state.isReadingPromptAttachments)
                        .help("Attach images or CAD source")
                        .accessibilityLabel("Attach files or images")
                    Spacer(minLength: 0)
                    reasoningSelector
                    if state.isWorking {
                        Button { state.stopGeneration() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 20, height: 22)
                        }.controlSize(.small).buttonStyle(.bordered).help("Stop current request").accessibilityLabel("Stop")
                    }
                    Button(action: submitRequest) {
                        Image(systemName: state.editingQueuedRequestID == nil ? "arrow.up" : "checkmark")
                            .font(.system(size: 13, weight: .semibold)).frame(width: 20, height: 22)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit)
                        .help("\(submissionLabel) (\(state.queuedRequests.isEmpty ? "Return or ⌘Return" : "Return"))")
                        .accessibilityLabel(submissionLabel)
                        .accessibilityIdentifier("projectSubmitRequest")
                }
            }.padding(12).background(Palette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .background(PromptFilePathDropRegion(text: $state.prompt, onFocus: { promptFocused = true },
                    onAttachFiles: { state.attachSourceFiles(urls: $0) }, onAttachImages: { state.attachPromptImages($0) }))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
        }.padding(16)
            .onChange(of: state.editingQueuedRequestID) { _, _ in promptFocused = true }
            .onChange(of: state.awaitingResponse, initial: true) { _, awaiting in
                if awaiting { promptFocused = true }
            }
    }

    private var reasoningSelector: some View {
        CodexModelMenu(state: state)
    }
}

private struct WorkspaceStatusBar: View {
    let state: AppState

    private var statusText: String? {
        if let notice = state.notice, !notice.isEmpty, notice != "Design saved" { return notice }
        return state.activity.isEmpty || state.activity == "Ready" ? nil : state.activityStatus
    }

    var body: some View {
        if let statusText {
            HStack(spacing: 7) {
                Circle().fill(state.isWorking || state.error != nil ? Palette.accent : Palette.muted).frame(width: 5, height: 5)
                Text(statusText).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 20).padding(.vertical, 8).background(Palette.panel)
                .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
    }
}
