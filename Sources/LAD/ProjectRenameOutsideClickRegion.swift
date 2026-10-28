import AppKit
import SwiftUI

/// Observe clicks around the inline name field without taking input away
/// from the viewport, sidebar or the control the user clicked.
struct ProjectRenameOutsideClickRegion: NSViewRepresentable {
    var onCancel: @MainActor () -> Void

    func makeNSView(context: Context) -> ProjectRenameOutsideClickView {
        let view = ProjectRenameOutsideClickView(frame: .zero)
        view.configure(onCancel: onCancel)
        return view
    }

    func updateNSView(_ view: ProjectRenameOutsideClickView, context: Context) {
        view.configure(onCancel: onCancel)
    }

    static func dismantleNSView(_ view: ProjectRenameOutsideClickView, coordinator: ()) {
        view.disconnect()
    }
}

@MainActor
final class ProjectRenameOutsideClickView: NSView {
    var onCancel: (@MainActor () -> Void)?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var monitoredWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
        connectWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectWindow()
    }

    /// Return the original event so an outside click still performs its
    /// ordinary action, including clicks on non-focusable empty space.
    func handleMouseDown(_ event: NSEvent) -> NSEvent {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
        let field = convert(visibleRect.intersection(bounds), to: nil)
        if !field.contains(event.locationInWindow) { onCancel?() }
        return event
    }

    func disconnect() {
        onCancel = nil
        removeMonitoring()
    }

    private func removeMonitoring() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        mouseMonitor = nil
        resignObserver = nil
        monitoredWindow = nil
    }

    private func connectWindow() {
        guard let window else { removeMonitoring(); return }
        guard monitoredWindow !== window || mouseMonitor == nil else { return }
        removeMonitoring()
        monitoredWindow = window
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleMouseDown(event) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel?() }
        }
    }
}
