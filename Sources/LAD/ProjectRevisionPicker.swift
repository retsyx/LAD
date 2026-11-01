import SwiftUI

/// A popover keeps version names editable without turning a rename into a
/// history selection, as a native menu action would do.
struct ProjectRevisionPicker: View {
    @ObservedObject var state: AppState
    @State private var isPresented = false

    private var currentName: String {
        guard let id = state.selectedRevisionID ?? state.revisions.last?.id else { return "" }
        return state.revisionName(for: id)
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Text(currentName)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: 140, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.revisions.isEmpty)
        .help("Choose or rename a version")
        .accessibilityLabel("Design version")
        .accessibilityValue(currentName)
        .accessibilityIdentifier("projectRevisionPicker")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ProjectRevisionPickerList(state: state, onSelect: { id in
                isPresented = false
                state.selectRevision(id)
            }, onDismiss: { isPresented = false })
        }
        .onChange(of: state.projectEditingID) { _, _ in isPresented = false }
    }
}

/// Its edit state is local to the open list; dismissal always discards an
/// unfinished name.
struct ProjectRevisionPickerList: View {
    @ObservedObject var state: AppState
    let onSelect: (UUID) -> Void
    let onDismiss: () -> Void
    @State private var editingRevisionID: UUID?
    @State private var editingProjectID: UUID?
    @State private var nameDraft = ""
    @State private var renameError: String?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.revisions) { revision in
                        revisionRow(revision.id)
                            .id(revision.id)
                    }
                }
                .padding(6)
            }
            .frame(width: 300, height: listHeight)
            .background(Palette.panel)
            .onAppear {
                if let id = state.selectedRevisionID { scroll.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Design versions")
        .accessibilityIdentifier("projectRevisionList")
        .onExitCommand {
            if editingRevisionID != nil { cancelRename() } else { onDismiss() }
        }
        .onChange(of: state.projectEditingID) { _, _ in
            cancelRename()
            onDismiss()
        }
        .onChange(of: state.revisions.map(\.id)) { _, ids in
            if let id = editingRevisionID, !ids.contains(id) { cancelRename() }
        }
        .onDisappear { cancelRename() }
    }

    private var listHeight: CGFloat {
        // Leave room for wrapped names and an inline validation message, while
        // keeping long histories scrollable within the current screen.
        min(360, max(48, CGFloat(state.revisions.count) * 42 + (renameError == nil ? 12 : 42)))
    }

    private func revisionRow(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 14)
                    .opacity(state.selectedRevisionID == id ? 1 : 0)
                    .accessibilityHidden(true)
                if editingRevisionID == id {
                    nameField(id)
                    Button { commitRename() } label: {
                        Image(systemName: "checkmark").frame(width: 22, height: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Apply version name")
                    .accessibilityLabel("Apply version name")
                    .accessibilityIdentifier("projectRevisionRenameCommit-\(id.uuidString)")
                    Button { cancelRename() } label: {
                        Image(systemName: "xmark").frame(width: 22, height: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Cancel version rename")
                    .accessibilityLabel("Cancel version rename")
                    .accessibilityIdentifier("projectRevisionRenameCancel-\(id.uuidString)")
                } else {
                    Button {
                        guard !state.isWorking else { return }
                        cancelRename()
                        onSelect(id)
                    } label: {
                        Text(state.revisionName(for: id))
                            .lineLimit(2).truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(state.isWorking)
                    .accessibilityLabel(state.revisionName(for: id))
                    .accessibilityValue(state.selectedRevisionID == id ? "Selected" : "")
                    .accessibilityIdentifier("projectRevisionSelect-\(id.uuidString)")
                    Button { beginRename(id) } label: {
                        Image(systemName: "pencil").frame(width: 22, height: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Rename version")
                    .accessibilityLabel("Rename version \(state.revisionName(for: id))")
                    .accessibilityIdentifier("projectRevisionRename-\(id.uuidString)")
                }
            }
            if editingRevisionID == id, let renameError {
                Text(renameError)
                    .font(.system(size: 10)).foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                    .accessibilityLabel("Version name error: \(renameError)")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(state.selectedRevisionID == id ? Palette.raised : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Save New…") { saveNew(from: id) }
                .disabled(!state.canSaveNew)
                .accessibilityIdentifier("projectRevisionSaveNew-\(id.uuidString)")
        }
        .background {
            if editingRevisionID == id {
                // Include Apply and Cancel in the edit region, so their clicks
                // reach the intended action before any outside cancellation.
                ProjectRenameOutsideClickRegion(onCancel: cancelRename)
            }
        }
    }

    private func saveNew(from id: UUID) {
        let projectID = state.projectEditingID
        cancelRename()
        onDismiss()
        // A main-queue block can run inside AppKit's menu-tracking loop.
        // Present the modal dialog only after returning to the default mode.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                guard state.projectEditingID == projectID else { return }
                state.saveNewProject(revisionID: id)
            }
        }
    }

    private func nameField(_ id: UUID) -> some View {
        TextField("Version name", text: $nameDraft)
            .textFieldStyle(.plain)
            .padding(.horizontal, 5).padding(.vertical, 5)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.accent.opacity(0.6), lineWidth: 1))
            .focused($nameFieldFocused)
            .accessibilityLabel("Version name")
            .accessibilityIdentifier("projectRevisionNameField-\(id.uuidString)")
            .onSubmit { commitRename() }
            .onExitCommand { cancelRename() }
            .onChange(of: nameDraft) { _, _ in renameError = nil }
            .task(id: id) {
                await Task.yield()
                guard !Task.isCancelled, editingRevisionID == id else { return }
                nameFieldFocused = true
            }
    }

    private func beginRename(_ id: UUID) {
        guard state.revisions.contains(where: { $0.id == id }) else { return }
        nameFieldFocused = false
        editingProjectID = state.projectEditingID
        nameDraft = state.revisionName(for: id)
        renameError = nil
        editingRevisionID = id
    }

    private func commitRename() {
        guard let id = editingRevisionID else { return }
        guard editingProjectID == state.projectEditingID,
              state.revisions.contains(where: { $0.id == id }) else {
            cancelRename()
            return
        }
        do {
            try state.renameRevision(id: id, to: nameDraft)
            cancelRename()
        } catch {
            renameError = error.localizedDescription
            nameFieldFocused = true
        }
    }

    private func cancelRename() {
        editingRevisionID = nil
        editingProjectID = nil
        nameDraft = ""
        renameError = nil
        nameFieldFocused = false
    }
}
