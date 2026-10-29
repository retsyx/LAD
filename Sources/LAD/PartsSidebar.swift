import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PartsSidebar: View {
    @ObservedObject var state: AppState
    @State private var rootDropTargeted = false
    @State private var folderParentID: String?
    @State private var editedName = ""
    @State private var showingNameEditor = false
    @State private var renamingNodeID: String?
    @State private var renamingRevisionID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "cube").foregroundStyle(Palette.muted)
                Text("Parts").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if let mesh = state.mesh {
                    Text(mesh.solids.formatted()).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .help("\(mesh.solids) parts")
                }
                Button { newFolder(parentID: nil) } label: {
                    PartGroupIcon(showsAddBadge: true).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .help("New folder").accessibilityLabel("New folder")
            }
            .padding(.horizontal, 15).padding(.vertical, 19)
            .background(rootDropTargeted ? Palette.accent.opacity(0.13) : .clear)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.text], isTargeted: $rootDropTargeted) { providers in
                receivePartDrop(providers, state: state, parentID: nil)
            }
            .contextMenu {
                PartActionsMenu(state: state, onNewFolder: newFolder, onRename: rename)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                // Each root can contain a complete expanded assembly. Lazy
                // height estimates for these subtrees change during selection
                // updates and move the scroll position.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(state.partTree) { node in
                        PartTreeItem(node: node, state: state, renamingNodeID: $renamingNodeID,
                                     renameText: $renameText, onFinishRename: finishRename,
                                     onNewFolder: newFolder, onRename: rename)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PartsScrollAnchor(state: state).allowsHitTesting(false))
            }
            .contextMenu {
                PartActionsMenu(state: state, onNewFolder: newFolder, onRename: rename)
            }
        }
        .background(Palette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parts")
        .onChange(of: state.selectedRevisionID) { _, _ in finishRename(true) }
        .alert("New Folder", isPresented: $showingNameEditor) {
            TextField("Name", text: $editedName)
            Button("Create") { saveName() }
                .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func newFolder(parentID: String?) {
        finishRename(false)
        folderParentID = parentID
        editedName = "New Folder"
        showingNameEditor = true
    }

    private func rename(_ node: PartNode) {
        finishRename(false)
        renamingRevisionID = state.selectedRevisionID
        renameText = node.name
        renamingNodeID = node.id
    }

    private func finishRename(_ cancelled: Bool) {
        guard let id = renamingNodeID else { return }
        renamingNodeID = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cancelled, renamingRevisionID == state.selectedRevisionID, !name.isEmpty,
              let node = state.partTree.flatMap(\.flattened).first(where: { $0.id == id }),
              name != node.name else { return }
        state.renamePartNode(id, to: name)
    }

    private func saveName() {
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        state.createPartFolder(named: name, parentID: folderParentID)
    }
}

private struct PartTreeItem: View {
    let node: PartNode
    @ObservedObject var state: AppState
    @Binding var renamingNodeID: String?
    @Binding var renameText: String
    let onFinishRename: (Bool) -> Void
    let onNewFolder: (String?) -> Void
    let onRename: (PartNode) -> Void
    @State private var dropTargeted = false
    @State private var showingColorPicker = false
    @State private var colorRevisionID: UUID?
    @State private var colorProjectID: UUID?
    @FocusState private var renameFocused: Bool

    private var solids: Set<Int> { node.allSolidIndices }
    private var hiddenCount: Int { solids.intersection(state.hiddenSolids).count }
    private var selection: PartSelectionPresentation {
        PartSelectionPresentation(solidIndices: solids, selectedSolids: state.selectedSolids,
                                  featureSelectedSolids: state.featureSelectedSolids,
                                  explicitlySelected: state.selectedPartNodeIDs.contains(node.id))
    }
    private var isGroup: Bool { node.isGroup }
    private var allHidden: Bool { !solids.isEmpty && hiddenCount == solids.count }
    private var partiallyHidden: Bool { hiddenCount > 0 && hiddenCount < solids.count }

    var body: some View {
        Group {
            if node.isGroup {
                DisclosureGroup(isExpanded: Binding(
                    get: { state.isPartFolderExpanded(node.id) },
                    set: { expanded in
                        onFinishRename(false)
                        state.setPartFolderExpanded(node.id, isExpanded: expanded)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(node.children ?? []) { child in
                            PartTreeItem(node: child, state: state, renamingNodeID: $renamingNodeID,
                                         renameText: $renameText, onFinishRename: onFinishRename,
                                         onNewFolder: onNewFolder, onRename: onRename)
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    row
                }
                .tint(Palette.muted)
            } else {
                row.padding(.leading, 17)
            }
        }
        .contextMenu {
            PartActionsMenu(state: state, node: node, onNewFolder: onNewFolder, onRename: onRename,
                            onColor: { _ in
                                onFinishRename(false)
                                colorRevisionID = state.selectedRevisionID
                                colorProjectID = state.projectEditingID
                                showingColorPicker = true
                            })
        }
        .onChange(of: state.selectedRevisionID) { _, _ in showingColorPicker = false }
        .onChange(of: state.projectEditingID) { _, _ in showingColorPicker = false }
        .onChange(of: state.selectedSolids) { _, _ in showingColorPicker = false }
        .onChange(of: state.featureSelectedSolids) { _, _ in showingColorPicker = false }
    }

    private var row: some View {
        Group {
            if isRenaming {
                rowContent
            } else {
                rowContent.onDrag {
                    onFinishRename(false)
                    let ids: Set<String>
                    if state.selectedPartNodeIDs.contains(node.id) {
                        ids = state.selectedPartNodeIDs
                    } else {
                        state.selectPartNodes([node.id])
                        ids = [node.id]
                    }
                    return NSItemProvider(object: ids.sorted().joined(separator: "\n") as NSString)
                }
            }
        }
        .onDrop(of: [UTType.text], isTargeted: $dropTargeted) { providers in
            guard isGroup else { return false }
            return receivePartDrop(providers, state: state, parentID: node.id)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 2) {
            if isRenaming {
                HStack(spacing: 7) {
                    partIcon
                    TextField("Name", text: $renameText)
                        .font(.system(size: 11, weight: isGroup ? .medium : .regular))
                        .textFieldStyle(.plain)
                        .focused($renameFocused)
                        .accessibilityLabel("Rename \(node.name)")
                        .onSubmit { if isRenaming { onFinishRename(false) } }
                        .onExitCommand { if isRenaming { onFinishRename(true) } }
                        .onChange(of: renameFocused) { _, focused in
                            if !focused, isRenaming { onFinishRename(false) }
                        }
                        .task {
                            await Task.yield()
                            if !Task.isCancelled, isRenaming { renameFocused = true }
                        }
                        .onDisappear { if isRenaming { onFinishRename(false) } }
                    partCount
                }
                .padding(.leading, 5).padding(.vertical, 7)
            } else {
                Button {
                    onFinishRename(false)
                    let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                    let extending = selection.isFull || modifiers.contains(.command) || modifiers.contains(.shift)
                    state.selectPartNodes([node.id], extending: extending)
                } label: {
                    HStack(spacing: 7) {
                        partIcon
                        Text(node.name).font(.system(size: 11, weight: isGroup ? .medium : .regular))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(selection.isSelected ? Palette.accent : Color.white.opacity(allHidden ? 0.42 : 0.86))
                        Spacer(minLength: 2)
                        partCount
                    }
                    .padding(.leading, 5).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.name)
                .accessibilityLabel(node.name)
                .accessibilityAddTraits(selection.isSelected ? .isSelected : [])
                .accessibilityValue(selection.isPartial ? "Partially selected" : selection.isFull ? "Selected" : "")
            }

            Button { onFinishRename(false); state.togglePartVisibility(solids) } label: {
                Image(systemName: allHidden ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(allHidden ? Palette.muted.opacity(0.6) : Palette.muted)
                    .overlay(alignment: .bottomTrailing) {
                        if partiallyHidden {
                            Image(systemName: "minus.circle.fill").font(.system(size: 7))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Palette.accent, Palette.panel)
                                .offset(x: 3, y: 3)
                        }
                    }
                    .frame(width: 25, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(solids.isEmpty)
            .help(visibilityHelp)
            .accessibilityLabel(hiddenCount > 0 ? "Show \(node.name)" : "Hide \(node.name)")
            .accessibilityValue(allHidden ? "Hidden" : partiallyHidden ? "Some parts hidden" : "Visible")
        }
        .background(selection.isSelected ? Palette.accent.opacity(selection.isFull ? 0.13 : 0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(dropTargeted && isGroup ? Palette.accent : .clear))
        .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) { colorPicker }
    }

    private var colorPicker: some View {
        PartColorPicker(initialColor: state.partColor(for: node.id), recentColors: state.recentPartColors,
                        onApply: { color in
                            if colorRevisionID == state.selectedRevisionID, colorProjectID == state.projectEditingID {
                                state.setPartColor(color, for: node.id)
                            }
                            showingColorPicker = false
                        }, onCancel: { showingColorPicker = false })
    }

    private var isRenaming: Bool { renamingNodeID == node.id }

    private var partIcon: some View {
        Group {
            if isGroup {
                PartGroupIcon().frame(width: 15, height: 15)
            } else {
                Image(systemName: "cube").font(.system(size: 12))
            }
        }
            .frame(width: 15)
            .foregroundStyle(selection.isSelected ? Palette.accent : Palette.muted)
            .overlay(alignment: .bottomTrailing) {
                if selection.isPartial {
                    Image(systemName: "minus.circle.fill").font(.system(size: 7))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Palette.accent, Palette.panel)
                        .offset(x: 3, y: 3)
                }
            }
    }

    @ViewBuilder
    private var partCount: some View {
        if isGroup {
            Text(solids.count.formatted()).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Palette.muted)
        }
    }

    private var visibilityHelp: String {
        if partiallyHidden { return "Show all parts in \(node.name) · \(hiddenCount) of \(solids.count) hidden" }
        return "\(allHidden ? "Show" : "Hide") \(node.name)"
    }
}

private struct PartActionsMenu: View {
    @ObservedObject var state: AppState
    var node: PartNode? = nil
    let onNewFolder: (String?) -> Void
    let onRename: (PartNode) -> Void
    var onColor: ((PartNode) -> Void)? = nil

    var body: some View {
        Section {
            Button("Export STEP…") {
                if let node, node.allSolidIndices.isDisjoint(with: state.selectedPartSolids) {
                    state.selectPartNodes([node.id])
                }
                state.exportSelectedPartsSTEP()
            }
            .disabled(!state.canExport || exportSolidIndices.isEmpty)
        }
        Section {
            if !state.selectedPartSolids.isEmpty {
                Button("Hide Selected Parts") { state.hideSelectedParts() }
                    .disabled(state.selectedPartSolids.isSubset(of: state.hiddenSolids))
            }
            if !state.hiddenSolids.isEmpty {
                Button("Show All Parts") { state.showAllParts() }
            }
        }
        if let node, let onColor {
            Section {
                Button("Color…") { onColor(node) }
                    .disabled(node.allSolidIndices.isEmpty)
            }
        }
        Section {
            Menu("Move Selected To") {
                Button("Parts") { state.movePartNodes(state.selectedPartNodeIDs, toParent: nil) }
                ForEach(folderDestinations) { folder in
                    Button(folder.name) { state.movePartNodes(state.selectedPartNodeIDs, toParent: folder.id) }
                }
            }
            .disabled(state.selectedPartNodeIDs.isEmpty)
            Button("New Folder…") { onNewFolder(node?.isGroup == true ? node?.id : nil) }
            if let node {
                Button("Rename") { onRename(node) }
                if node.isGroup {
                    Button(node.children?.isEmpty == true ? "Remove Folder" : "Ungroup") {
                        state.ungroupPartFolder(node.id)
                    }
                }
            }
            if node == nil {
                Button("Reset Hierarchy") { state.resetPartHierarchy() }
                    .disabled(state.mesh == nil)
                    .help("Restore the design’s default folders and part names")
            }
        }
    }

    private var exportSolidIndices: Set<Int> {
        if let node, node.allSolidIndices.isDisjoint(with: state.selectedPartSolids) {
            return node.allSolidIndices
        }
        return state.selectedPartSolids
    }

    private var folderDestinations: [PartFolderDestination] {
        func folders(in nodes: [PartNode], path: [String]) -> [PartFolderDestination] {
            nodes.flatMap { node -> [PartFolderDestination] in
                guard node.isGroup, !state.selectedPartNodeIDs.contains(node.id) else { return [] }
                let names = path + [node.name]
                return [PartFolderDestination(id: node.id, name: names.joined(separator: " / "))]
                    + folders(in: node.children ?? [], path: names)
            }
        }
        return folders(in: state.partTree, path: [])
    }
}

private struct PartFolderDestination: Identifiable {
    let id: String
    let name: String
}

private func receivePartDrop(_ providers: [NSItemProvider], state: AppState, parentID: String?) -> Bool {
    // Finder file URLs can also advertise a text representation. They belong
    // to file-drop handling, never to the internal part-ID reorder operation.
    guard !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
    provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let value = object as? String else { return }
        let ids = Set(value.split(separator: "\n").map(String.init))
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async { state.movePartNodes(ids, toParent: parentID) }
    }
    return true
}
