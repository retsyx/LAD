import AppKit
import SwiftUI

/// Title bar behavior for the design header, which replaces the hidden system
/// title bar: empty header space drags the window, and the standard window
/// buttons stay vertically centered in the header.
struct WindowHeaderChrome: NSViewRepresentable {
    static let height: CGFloat = 52
    /// The leading header width the standard window buttons occupy.
    static let windowButtonsWidth: CGFloat = 80

    func makeNSView(context: Context) -> WindowHeaderChromeView { WindowHeaderChromeView(frame: .zero) }
    func updateNSView(_ view: WindowHeaderChromeView, context: Context) {}
    static func dismantleNSView(_ view: WindowHeaderChromeView, coordinator: ()) { view.detach() }
}

@MainActor
final class WindowHeaderChromeView: NSView {
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var nativeButtonSpacing: CGFloat?
    private var isLayingOutControls = false
    private var isLayoutCheckPending = false
    private var commitObserver: CFRunLoopObserver?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let commitObserver { CFRunLoopObserverInvalidate(commitObserver) }
    }

    override var acceptsFirstResponder: Bool { false }
    // Like a title bar, the header drags an inactive window without first activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // AppKit's own title bar region is shorter than the header, so this view drags the window itself.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 { Self.performDoubleClickAction(in: window) }
        else { window.performDrag(with: event) }
    }

    /// The title bar double-click action chosen in System Settings.
    static func performDoubleClickAction(in window: NSWindow) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"): window.performMiniaturize(nil)
        default: window.performZoom(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach(to: window)
    }

    func detach() { attach(to: nil) }

    private func attach(to window: NSWindow?) {
        guard observedWindow !== window else {
            layOutWindowControls()
            return
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let commitObserver { CFRunLoopObserverInvalidate(commitObserver) }
        commitObserver = nil
        observedWindow = window
        nativeButtonSpacing = nil
        isLayoutCheckPending = false
        guard let window, let controls = WindowControls(window) else { return }
        nativeButtonSpacing = controls.miniaturize.frame.minX - controls.close.frame.minX
        // AppKit lays its title bar out again at its own height after resizing,
        // full screen, title and edited-state changes. Restore the header
        // layout as soon as the container or a button moves, before the frame
        // is drawn.
        let center = NotificationCenter.default
        for view in [controls.container, controls.close, controls.miniaturize, controls.zoom] {
            view.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowControlsDidMove() }
            })
        }
        // Resizing has finished its title bar layout when this is posted.
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.layOutWindowControls() }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowControlsDidMove() }
        })
        // AppKit can lay the title bar out during its display pass. Finish any
        // pending check after that pass, just before Core Animation commits.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                          Self.beforeCommitOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.finishPendingLayoutCheck() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        commitObserver = observer
        layOutWindowControls()
    }

    /// Core Animation commits at order 2,000,000 before the run loop waits.
    private static let beforeCommitOrder = 1_999_999

    private func windowControlsDidMove() {
        layOutWindowControls()
        // AppKit reports frame changes while its title bar layout is still in
        // progress, and a button moved from within its own notification is
        // moved back. Check again once that layout returns.
        guard !isLayoutCheckPending else { return }
        isLayoutCheckPending = true
        // Wake the run loop when the move happened after this turn's check.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.finishPendingLayoutCheck() }
        }
    }

    private func finishPendingLayoutCheck() {
        guard isLayoutCheckPending else { return }
        isLayoutCheckPending = false
        layOutWindowControls()
    }

    private func layOutWindowControls() {
        guard !isLayingOutControls, let window = observedWindow, let spacing = nativeButtonSpacing,
              let controls = WindowControls(window),
              // In full screen the title bar moves to the menu bar reveal window.
              let frameView = window.contentView?.superview, controls.container.superview === frameView else { return }
        isLayingOutControls = true
        defer { isLayingOutControls = false }
        let height = WindowHeaderChrome.height
        let container = NSRect(x: controls.container.frame.minX, y: frameView.bounds.maxY - height,
                               width: controls.container.frame.width, height: height)
        if controls.container.frame != container { controls.container.frame = container }
        // Equal top and leading margins, as in a native toolbar window.
        let margin = ((height - controls.close.frame.height) / 2).rounded(.down)
        let leftToRight = window.windowTitlebarLayoutDirection == .leftToRight
        for (index, button) in [controls.close, controls.miniaturize, controls.zoom].enumerated() {
            let origin = NSPoint(x: leftToRight ? margin + CGFloat(index) * spacing : button.frame.minX, y: margin)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

@MainActor
private struct WindowControls {
    let close: NSButton
    let miniaturize: NSButton
    let zoom: NSButton
    let container: NSView

    init?(_ window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return nil }
        self.close = close
        self.miniaturize = miniaturize
        self.zoom = zoom
        self.container = container
    }
}
