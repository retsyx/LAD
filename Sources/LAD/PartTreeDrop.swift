import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Parts drags carry a private, empty type. Destinations accept it only from
/// drags that start in this application, so text, files and other
/// applications' drags never reorganize the tree.
enum PartTreeDrag {
    static let type = UTType(exportedAs: "studio.lad.part-nodes")
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)

    struct Session: Equatable {
        var projectSessionID: UUID
        var revisionID: UUID?
        var nodeIDs: Set<String>
    }

    /// Drop targets are validated while hovering, before the provider's data
    /// can be read. Only one drag runs at a time, so a part drop always
    /// belongs to the most recently started part drag.
    @MainActor private(set) static var session: Session?

    @MainActor
    static func provider(for session: Session) -> NSItemProvider {
        self.session = session
        let provider = NSItemProvider()
        // The native destination reads the drag pasteboard, and the source
        // check, not visibility, keeps other applications out.
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    /// The dragged parts and folders that a drop into `parentID` (the top
    /// level when nil) would relocate. Items already there keep their place.
    @MainActor
    static func movableNodeIDs(in state: AppState, toParent parentID: String?) -> Set<String> {
        guard let session, session.projectSessionID == state.projectEditingID,
              session.revisionID == state.selectedRevisionID else { return [] }
        return state.partNodeIDsChangingParent(session.nodeIDs, toParent: parentID)
    }
}

enum PartDropTarget: Hashable {
    case root
    case folder(String)
}

/// Drop feedback and folder geometry for one Parts pane.
@MainActor @Observable
final class PartDropState {
    static let contentSpace = "lad-parts-drop-content"

    /// The destination of a valid drop at the pointer.
    private(set) var target: PartDropTarget?
    /// Each rendered folder's area, including its expanded contents, in the
    /// list content's coordinates. These do not change while scrolling.
    @ObservationIgnored var folderFrames: [String: CGRect] = [:]
    @ObservationIgnored weak var contentAnchor: NSView?

    func show(_ target: PartDropTarget?) {
        if self.target != target { self.target = target }
    }

    /// The innermost visible folder under a window location, or nil for the
    /// top level, including the header and empty space below the list.
    func folderID(at windowLocation: NSPoint, among folders: Set<String>) -> String? {
        guard let anchor = contentAnchor, anchor.window != nil else { return nil }
        let point = anchor.convert(windowLocation, from: nil)
        guard anchor.visibleRect.contains(point) else { return nil }
        return folderFrames.filter { folders.contains($0.key) && $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?.key
    }
}

struct PartDropHighlightView: View {
    let drop: PartDropState
    let target: PartDropTarget

    var body: some View {
        if drop.target == target {
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.accent.opacity(0.08))
                .strokeBorder(Palette.accent.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// Converts drag locations into the scrolling list content's coordinates.
struct PartDropContentAnchor: NSViewRepresentable {
    let drop: PartDropState

    func makeNSView(context: Context) -> PartDropContentAnchorView { PartDropContentAnchorView() }
    func updateNSView(_ view: PartDropContentAnchorView, context: Context) { drop.contentAnchor = view }
}

final class PartDropContentAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One native destination covers the whole pane and accepts only the private
/// Parts drag type, never text, files or generic data.
struct PartDropDestination: NSViewRepresentable {
    let state: AppState
    let drop: PartDropState

    func makeNSView(context: Context) -> PartDropDestinationView { PartDropDestinationView(state: state, drop: drop) }
    func updateNSView(_ view: PartDropDestinationView, context: Context) {
        view.state = state
        view.drop = drop
    }
    static func dismantleNSView(_ view: PartDropDestinationView, coordinator: ()) { view.drop.show(nil) }
}

@MainActor
final class PartDropDestinationView: NSView {
    var state: AppState
    var drop: PartDropState
    private var proposal: Proposal?

    private struct Proposal {
        var sequence: Int
        var visibleFolders: Set<String>
        var parentID: String?
        var nodeIDs: Set<String>
    }

    init(state: AppState, drop: PartDropState) {
        self.state = state
        self.drop = drop
        super.init(frame: .zero)
        registerForDraggedTypes([PartTreeDrag.pasteboardType])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        proposal = nil
        return update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { finish() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { finish() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !update(sender).isEmpty }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Revalidate against the current design rather than the hover state.
        proposal = nil
        let operation = update(sender)
        let move = proposal
        finish()
        guard !operation.isEmpty, let move else { return false }
        state.movePartNodes(move.nodeIDs, toParent: move.parentID)
        return true
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // AppKit reports a source only for drags that start in this application.
        guard sender.draggingSource != nil,
              sender.draggingPasteboard.availableType(from: [PartTreeDrag.pasteboardType]) != nil,
              let operation = [NSDragOperation.move, .generic, .private, .copy].first(where: sender.draggingSourceOperationMask.contains)
        else {
            finish()
            return []
        }
        let sequence = sender.draggingSequenceNumber
        let current = proposal.flatMap { $0.sequence == sequence ? $0 : nil }
        let folders = current?.visibleFolders ?? visibleFolderIDs()
        let parentID = drop.folderID(at: sender.draggingLocation, among: folders)
        // Validation indexes the whole tree; repeat it only when the pointer
        // reaches a different destination.
        if current == nil || current?.parentID != parentID {
            proposal = Proposal(sequence: sequence, visibleFolders: folders, parentID: parentID,
                                nodeIDs: PartTreeDrag.movableNodeIDs(in: state, toParent: parentID))
        }
        guard let proposal, !proposal.nodeIDs.isEmpty else {
            drop.show(nil)
            return []
        }
        drop.show(parentID.map(PartDropTarget.folder) ?? .root)
        return operation
    }

    private func finish() {
        proposal = nil
        drop.show(nil)
    }

    /// Folders inside collapsed folders keep no rendered area.
    private func visibleFolderIDs() -> Set<String> {
        let collapsed = state.collapsedPartFolderIDs
        var result = Set<String>()
        func visit(_ nodes: [PartNode]) {
            for node in nodes where node.isGroup {
                result.insert(node.id)
                if !collapsed.contains(node.id) { visit(node.children ?? []) }
            }
        }
        visit(state.partTree)
        return result
    }
}
