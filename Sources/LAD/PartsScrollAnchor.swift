import AppKit
import SwiftUI

/// Preserve the requested top of the Parts list across split-pane layout.
/// Inserting Measurements can briefly enlarge the native clip view before it
/// reaches its final size. That temporary clamp must not become a new scroll.
struct PartsScrollAnchor: NSViewRepresentable {
    private let content: PartsScrollContentIdentity

    @MainActor
    init(state: AppState) {
        let nodes = state.partTree
        content = PartsScrollContentIdentity(projectID: state.projectEditingID,
            revisionID: state.selectedRevisionID, nodes: nodes,
            collapsedFolders: Set(nodes.flatMap(\.flattened).filter {
                $0.isGroup && !state.isPartFolderExpanded($0.id)
            }.map(\.id)))
    }

    func makeNSView(context: Context) -> PartsScrollAnchorView { PartsScrollAnchorView() }
    func updateNSView(_ view: PartsScrollAnchorView, context: Context) {
        view.connect()
        view.updateContent(content)
    }
    static func dismantleNSView(_ view: PartsScrollAnchorView, coordinator: ()) { view.disconnect() }
}

fileprivate struct PartsScrollContentIdentity: Equatable {
    var projectID: UUID
    var revisionID: UUID?
    var nodes: [PartNode]
    var collapsedFolders: Set<String>
}

final class PartsScrollAnchorView: NSView {
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var requestedOrigin = NSPoint.zero
    private var displayedOrigin = NSPoint.zero
    private var viewportSize = NSSize.zero
    private var applyingOrigin = false
    private var content: PartsScrollContentIdentity?

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { disconnect() } else { connect() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        connect()
    }

    func connect() {
        guard let scroll = enclosingScrollView else { disconnect(); return }
        guard scroll !== scrollView else { return }
        disconnect()
        scrollView = scroll
        let clip = scroll.contentView
        requestedOrigin = clip.bounds.origin
        displayedOrigin = requestedOrigin
        viewportSize = clip.bounds.size
        clip.postsFrameChangedNotifications = true
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        })
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        })
    }

    func disconnect() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        scrollView = nil
    }

    fileprivate func updateContent(_ next: PartsScrollContentIdentity) {
        guard content != next else { return }
        content = next
        // A different design, revision, hierarchy or expansion state starts
        // from its actual position, including any legitimate content clamp.
        if let clip = scrollView?.contentView {
            requestedOrigin = clip.bounds.origin
            displayedOrigin = requestedOrigin
            viewportSize = clip.bounds.size
        }
    }

    private func viewportChanged() {
        guard let scroll = scrollView, !applyingOrigin else { return }
        let clip = scroll.contentView
        viewportSize = clip.bounds.size
        var requestedBounds = clip.bounds
        requestedBounds.origin = requestedOrigin
        displayedOrigin = clip.constrainBoundsRect(requestedBounds).origin
        guard clip.bounds.origin != displayedOrigin else { return }
        applyingOrigin = true
        defer { applyingOrigin = false }
        clip.scroll(to: displayedOrigin)
        scroll.reflectScrolledClipView(clip)
        displayedOrigin = clip.bounds.origin
    }

    private func boundsChanged() {
        guard let clip = scrollView?.contentView, !applyingOrigin else { return }
        if clip.bounds.size != viewportSize {
            viewportChanged()
        } else if clip.bounds.origin != displayedOrigin {
            // Wheel, scroller, keyboard and explicit scroll requests replace
            // the anchor. Geometry's constrained position does not.
            requestedOrigin = clip.bounds.origin
            displayedOrigin = requestedOrigin
        }
    }
}
