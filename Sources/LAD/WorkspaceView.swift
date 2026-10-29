import SwiftUI

@MainActor
private final class WorkspaceViewportReference: ObservableObject {
    weak var view: CADSceneView?
    weak var window: NSWindow?
    private weak var cube: ViewportOrientationCube?

    func bindViewport(_ view: CADSceneView) {
        guard self.view !== view else { return }
        self.view?.onCameraOrientationChanged = nil
        self.view = view
        view.onCameraOrientationChanged = { [weak self] right, up, backward in
            self?.cube?.setOrientation(right: right, up: up, backward: backward)
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

struct WorkspaceView: View {
    @ObservedObject var state: AppState
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

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Palette.line).frame(height: 1)
            HSplitView {
                partsPanel.frame(minWidth: 180, idealWidth: 230, maxWidth: 340, maxHeight: .infinity)
                viewer.frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                chat.frame(minWidth: 340, idealWidth: 390, maxWidth: 520, maxHeight: .infinity)
            }
            statusBar
        }
        .background(Palette.background)
        .background(ProjectActivityWindowAnchor {
            viewportReference.window = $0
            state.presentSaveConflict(in: $0)
        })
        .toolbarBackground(Palette.panel, for: .windowToolbar)
        .onChange(of: state.projectEditingID) { _, _ in
            cancelProjectRename()
            isProgramExpanded = false
            previewImageAttachment = nil
            activityPanel.close()
        }
        .onDisappear { activityPanel.close() }
        .onChange(of: state.canRenameProject) { _, allowed in
            if !allowed { cancelProjectRename() }
        }
        .onChange(of: state.editingQueuedRequestID) { _, _ in promptFocused = true }
        .onChange(of: state.awaitingResponse, initial: true) { _, awaiting in
            if awaiting { promptFocused = true }
        }
        .onChange(of: state.saveConflict) { _, conflict in
            if conflict != nil { state.presentSaveConflict(in: viewportReference.window) }
        }
        .sheet(item: $previewImageAttachment) { attachment in PromptImagePreview(attachment: attachment) }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "cube.transparent.fill").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.accent)
                Text("LAD").font(.system(size: 20, weight: .bold, design: .rounded)).tracking(2)
            }
            Rectangle().fill(Palette.line).frame(width: 1, height: 25)
            projectName
                .frame(minWidth: 120, idealWidth: 360, maxWidth: 600, alignment: .leading)
                // Use the existing bottom padding for transient feedback;
                // changing save state must not resize the header or viewport.
                .overlay(alignment: .bottomLeading) {
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(y: 14)
                            .help(message)
                            .accessibilityLabel(projectRenameError == nil ? message : "Design name error: \(message)")
                    }
                }
                .layoutPriority(1)
            Spacer()
            Button { state.openProject() } label: { Image(systemName: "folder") }.help("Open design (⌘O)")
            Button { state.saveNewProject() } label: { Label("Save New", systemImage: "square.and.arrow.down") }
                .help("Save the latest design with its prompt and response (⌘S)")
                .disabled(!state.canSaveNew)
            Button { state.exportSTEP() } label: {
                HStack(spacing: 7) { Image(systemName: "arrow.up.right.square"); Text("Export STEP").fontWeight(.semibold) }
                    .padding(.horizontal, 8).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).disabled(!state.canExport)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Palette.panel)
    }

    @ViewBuilder
    private var projectName: some View {
        if isRenamingProject {
            TextField("Design name", text: $projectNameDraft)
                .font(.system(size: 13, weight: .semibold))
                .textFieldStyle(.plain)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.accent.opacity(0.6), lineWidth: 1))
                .focused($projectNameFocused)
                .accessibilityLabel("Design name")
                .accessibilityIdentifier("projectNameField")
                .onSubmit { finishProjectRename() }
                .onExitCommand { cancelProjectRename() }
                .onChange(of: projectNameFocused) { _, focused in
                    if !focused { cancelProjectRename() }
                }
                .background(ProjectRenameOutsideClickRegion(onCancel: cancelProjectRename))
                .onChange(of: projectNameDraft) { _, _ in projectRenameError = nil }
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
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        ProjectSidebarSplitView(state: state, isProgramExpanded: $isProgramExpanded)
        .background(Palette.panel)
        .accessibilityIdentifier("projectSidebarSplitView")
    }

    private var viewer: some View {
        ZStack(alignment: .topLeading) {
            CADViewport(mesh: state.mesh, displayMode: state.displayMode, projectionMode: state.projectionMode, showGrid: state.showGrid,
                        command: state.viewportCommand,
                        selectedSolids: state.selectedSolids, hiddenSolids: state.hiddenSolids, solidColors: state.solidColors,
                        selectedFeatures: state.selectedFeatures,
                        onSelectionChanged: { state.selectParts($0) },
                        onFeatureSelectionChanged: { state.selectFeatures($0) }, onDeselectAll: { state.clearSelections() },
                        onHideSelected: { state.hideSelectedParts() }, onShowAll: { state.showAllParts() },
                        onViewReady: { view in
                            viewportReference.bindViewport(view)
                            if view.window?.isKeyWindow == true || state.viewportView == nil { state.viewportView = view }
                        })
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Button { state.showGrid.toggle() } label: {
                        Image(systemName: "grid").frame(width: 28, height: 28)
                            .foregroundStyle(state.showGrid ? Palette.accent : Palette.muted)
                    }
                    .buttonStyle(.plain).padding(5)
                    .background(Palette.panel.opacity(0.93), in: RoundedRectangle(cornerRadius: 9))
                    .help("Toggle grid").accessibilityValue(state.showGrid ? "On" : "Off")
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
            if state.mesh == nil {
                VStack(spacing: 12) {
                    if state.isWorking { ProgressView().controlSize(.large) }
                    else { Image(systemName: "cube.transparent").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Palette.muted) }
                    Text(state.isWorking ? "Preparing your design" : "Your design starts here").font(.system(size: 17, weight: .medium))
                    if !state.isWorking {
                        Text("Describe a part in the conversation to get started.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
        }.background(Palette.background)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle").foregroundStyle(Palette.accent)
                Text("Design with Codex").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { activityPanel.toggle(state: state, owner: viewportReference.window ?? viewportReference.view?.window) } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(activityPanel.isVisible ? Palette.accent : Palette.muted)
                }
                .buttonStyle(.plain).help(activityPanel.isVisible ? "Hide tool activity" : "Show tool activity")
                .accessibilityLabel("Tool Activity").accessibilityValue(activityPanel.isVisible ? "Shown" : "Hidden")
                SettingsLink { Image(systemName: "slider.horizontal.3").foregroundStyle(Palette.muted) }.buttonStyle(.plain).help("LAD Settings (⌘,)")
            }.padding(.horizontal, 20).padding(.vertical, 19)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 8) {
                            Rectangle().fill(Palette.line).frame(height: 1)
                            Text("DESIGN CONVERSATION").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundStyle(Palette.muted).fixedSize()
                            Rectangle().fill(Palette.line).frame(height: 1)
                        }.padding(.top, 6)
                        ForEach(state.messages) { message in messageView(message).id(message.id) }
                        if state.isWorking {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(state.activityStatus).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }.id("activity")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }
                .onChange(of: state.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: state.messages.last?.content) { _, _ in
                    if state.isWorking { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: state.isWorking) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if let error = state.error { errorPanel(error) }
            if !state.queuedRequests.isEmpty {
                ProjectRequestQueueView(state: state).padding(.horizontal, 16).padding(.top, 6)
            }
            composer
        }.background(Palette.panel)
    }

    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: message.role == "user" ? "person.crop.circle" : message.role == "system" ? "exclamationmark.circle" : "sparkle")
                    .foregroundStyle(message.role == "assistant" ? Palette.accent : Palette.muted)
                Text(message.role == "user" ? "YOU" : message.role == "system" ? "STATUS" :
                     message.phase == "commentary" ? "UPDATE" : message.phase == "final_answer" ? "COMPLETE" : "LAD / CODEX")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted)
                Spacer()
                Text(message.date, style: .time).font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.6))
                CopyButton(text: message.content, label: "Copy message")
            }
            Text(message.content).font(.system(size: 12)).lineSpacing(5).foregroundStyle(Color.white.opacity(0.85)).textSelection(.enabled)
            if let attachments = message.attachments, !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    let images = attachments.filter(\.isImage)
                    if !images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(images) { attachment in
                                    PromptImageAttachmentView(attachment: attachment, onPreview: { previewImageAttachment = attachment })
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
        .padding(message.role == "user" ? 13 : 0)
        .background(message.role == "user" ? Palette.raised.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 9))
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

    private var reasoningSelector: some View {
        CodexModelMenu(state: state)
    }

    private var composer: some View {
        let editingRequestID = state.editingQueuedRequestID
        let submissionLabel = editingRequestID != nil ? "Save queued request" :
            state.submissionWillQueue ? "Queue request" : state.awaitingResponse ? "Send reply" : "Generate design"
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
                        onAttachFiles: { state.attachSourceFiles(urls: $0) }, onAttachImages: { state.attachPromptImages($0) })
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
                        .help("Attach images, CAD source or a KiCad PCB (.kicad_pcb)")
                        .accessibilityLabel("Attach files or images")
                    Spacer(minLength: 0)
                    reasoningSelector
                    if state.isWorking {
                        Button { state.stopGeneration() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 20, height: 22)
                        }.controlSize(.small).buttonStyle(.bordered).help("Stop current request").accessibilityLabel("Stop")
                    }
                    Button {
                        // A removed or replaced queued edit must not turn a
                        // stale Save click into sending the restored draft.
                        guard state.editingQueuedRequestID == editingRequestID else { return }
                        if editingRequestID != nil { state.commitEditingQueuedRequest() }
                        else { state.submit() }
                    } label: {
                        Image(systemName: state.editingQueuedRequestID == nil ? "arrow.up" : "checkmark")
                            .font(.system(size: 13, weight: .semibold)).frame(width: 20, height: 22)
                    }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(state.isReadingPromptAttachments || (state.editingQueuedRequestID != nil ? !state.canCommitQueuedRequest :
                                  state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.pendingAttachments.isEmpty))
                        .help("\(submissionLabel) (⌘Return)")
                        .accessibilityLabel(submissionLabel)
                        .accessibilityIdentifier("projectSubmitRequest")
                }
            }.padding(12).background(Palette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .background(PromptFilePathDropRegion(text: $state.prompt, onFocus: { promptFocused = true },
                    onAttachFiles: { state.attachSourceFiles(urls: $0) }, onAttachImages: { state.attachPromptImages($0) }))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
        }.padding(16)
    }

    private var statusText: String? {
        if let notice = state.notice, !notice.isEmpty, notice != "Design saved" { return notice }
        return state.activity.isEmpty || state.activity == "Ready" ? nil : state.activityStatus
    }

    @ViewBuilder
    private var statusBar: some View {
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
