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

        @MainActor
        func matches(_ state: AppState) -> Bool {
            projectSessionID == state.projectEditingID && revisionID == state.selectedRevisionID
        }
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
}

enum PartDropTarget: Hashable {
    case root
    case folder(String)
}

/// Drop feedback and folder geometry for one Parts pane.
@MainActor @Observable
final class PartDropState {
    nonisolated static let contentSpace = "lad-parts-drop-content"

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
        return folderFrames.lazy.filter { folders.contains($0.key) && $0.value.contains(point) }
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
        guard view.state !== state || view.drop !== drop else { return }
        view.finish()
        view.state = state
        view.drop = drop
    }
    static func dismantleNSView(_ view: PartDropDestinationView, coordinator: ()) { view.finish() }
}

@MainActor
final class PartDropDestinationView: NSView {
    var state: AppState
    var drop: PartDropState
    private var drag: Drag?
    private var proposal: Proposal?
    private var folderHover: (id: String, deadline: ContinuousClock.Instant)?
    private var trackingTimer: Timer?

    private struct Drag {
        let sequence: Int
        let session: PartTreeDrag.Session
        let location: NSPoint
    }

    private struct Proposal {
        var tree: [PartNode]
        var collapsedFolders: Set<String>
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if window !== newWindow { finish() }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        finish()
        return update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { finish() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { finish() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        finish()
        guard let (session, _) = acceptedDrag(sender) else { return false }
        return !destination(at: sender.draggingLocation, for: session).nodeIDs.isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Use the release location and current hierarchy, independent of hover feedback.
        finish()
        guard let (session, _) = acceptedDrag(sender) else { return false }
        let move = destination(at: sender.draggingLocation, for: session)
        guard !move.nodeIDs.isEmpty else { return false }
        state.movePartNodes(move.nodeIDs, toParent: move.parentID)
        return true
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let (session, operation) = acceptedDrag(sender) else {
            finish()
            return []
        }
        if drag?.sequence != sender.draggingSequenceNumber || drag?.session != session { finish() }
        drag = Drag(sequence: sender.draggingSequenceNumber, session: session, location: sender.draggingLocation)
        trackDrag(scrolling: false)
        return drop.target == nil ? [] : operation
    }

    private func acceptedDrag(_ sender: any NSDraggingInfo) -> (PartTreeDrag.Session, NSDragOperation)? {
        // AppKit reports a source only for drags that start in this application.
        guard sender.draggingDestinationWindow === window, containsDragPoint(sender.draggingLocation),
              sender.draggingSource != nil,
              sender.draggingPasteboard.availableType(from: [PartTreeDrag.pasteboardType]) != nil,
              let session = PartTreeDrag.session, session.matches(state),
              let operation = [NSDragOperation.move, .generic, .private, .copy].first(where: sender.draggingSourceOperationMask.contains)
        else { return nil }
        return (session, operation)
    }

    private func trackDrag(scrolling: Bool) {
        guard let drag, drag.session == PartTreeDrag.session, drag.session.matches(state),
              containsDragPoint(drag.location) else {
            finish()
            return
        }
        let scrollStep = nextScrollStep(at: drag.location)
        if scrolling, let (scroll, origin) = scrollStep {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let move = destination(at: drag.location, for: drag.session)
        proposal = move
        drop.show(move.nodeIDs.isEmpty ? nil : (move.parentID.map(PartDropTarget.folder) ?? .root))
        updateFolderHover(move)
        setTrackingTimer(active: scrollStep != nil || folderHover != nil)
    }

    private func containsDragPoint(_ location: NSPoint) -> Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && visibleRect.contains(convert(location, from: nil))
    }

    private func destination(at location: NSPoint, for session: PartTreeDrag.Session) -> Proposal {
        let tree = state.partTree
        let collapsed = state.collapsedPartFolderIDs
        let current = proposal.flatMap { $0.tree == tree && $0.collapsedFolders == collapsed ? $0 : nil }
        let folders = current?.visibleFolders ?? visibleFolderIDs(in: tree, collapsed: collapsed)
        let parentID = drop.folderID(at: location, among: folders)
        // Validation indexes the whole tree; repeat it only when the pointer
        // reaches a different destination or the hierarchy changes.
        if let current, current.parentID == parentID { return current }
        return Proposal(tree: tree, collapsedFolders: collapsed, visibleFolders: folders, parentID: parentID,
                        nodeIDs: state.partNodeIDsChangingParent(session.nodeIDs, toParent: parentID))
    }

    private func updateFolderHover(_ move: Proposal) {
        guard let id = move.parentID, !move.nodeIDs.isEmpty, move.collapsedFolders.contains(id) else {
            folderHover = nil
            return
        }
        let now = ContinuousClock.now
        if let hover = folderHover, hover.id == id {
            guard now >= hover.deadline else { return }
            folderHover = nil
            state.setPartFolderExpanded(id, isExpanded: true)
        } else {
            folderHover = (id, now + .milliseconds(650))
        }
    }

    private func nextScrollStep(at location: NSPoint) -> (NSScrollView, NSPoint)? {
        guard let scroll = drop.contentAnchor?.enclosingScrollView else { return nil }
        let clip = scroll.contentView
        let viewport = clip.visibleRect.intersection(clip.bounds)
        let point = clip.convert(location, from: nil)
        guard viewport.contains(point) else { return nil }
        let band = min(28, viewport.height / 3)
        let fromMinY = point.y - viewport.minY
        let fromMaxY = viewport.maxY - point.y
        let proximity = band - min(fromMinY, fromMaxY)
        guard proximity > 0 else { return nil }
        let distance = 2 + 12 * proximity / band
        var nextBounds = clip.bounds
        nextBounds.origin.y += fromMinY < fromMaxY ? -distance : distance
        let origin = clip.constrainBoundsRect(nextBounds).origin
        return origin == clip.bounds.origin ? nil : (scroll, origin)
    }

    private func setTrackingTimer(active: Bool) {
        guard active else {
            trackingTimer?.invalidate()
            trackingTimer = nil
            return
        }
        guard trackingTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.trackDrag(scrolling: true)
            }
        }
        trackingTimer = timer
        // Keep tracking while AppKit runs the drag session's event loop.
        RunLoop.main.add(timer, forMode: .common)
    }

    fileprivate func finish() {
        drag = nil
        proposal = nil
        folderHover = nil
        setTrackingTimer(active: false)
        drop.show(nil)
    }

    /// Folders inside collapsed folders keep no rendered area.
    private func visibleFolderIDs(in tree: [PartNode], collapsed: Set<String>) -> Set<String> {
        var result = Set<String>()
        func visit(_ nodes: [PartNode]) {
            for node in nodes where node.isGroup {
                result.insert(node.id)
                if !collapsed.contains(node.id) { visit(node.children ?? []) }
            }
        }
        visit(tree)
        return result
    }
}
