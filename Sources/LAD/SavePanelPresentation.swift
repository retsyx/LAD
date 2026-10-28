import AppKit

/// Give expanded native save panels room for their sidebar and file browser.
/// Size after AppKit restores the panel, and again when its disclosure opens.
/// Compact panels and subsequent manual resizing retain native behavior.
@MainActor
final class SavePanelPresentation: NSObject, NSOpenSavePanelDelegate {
    private weak var panel: NSSavePanel?
    private var needsExpandedLayout = true
    private var wasExpanded = false
    private var updateScheduled = false

    static func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        let presentation = SavePanelPresentation(panel: panel)
        panel.delegate = presentation
        let notifications = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
            notifications.addObserver(presentation, selector: #selector(presentation.windowChanged(_:)), name: name, object: panel)
        }
        defer {
            notifications.removeObserver(presentation)
            panel.delegate = nil
        }
        presentation.scheduleLayout()
        return panel.runModal()
    }

    private init(panel: NSSavePanel) {
        self.panel = panel
        super.init()
    }

    func panel(_ sender: Any, willExpand expanding: Bool) {
        needsExpandedLayout = expanding
        if expanding { wasExpanded = false }
        scheduleLayout()
    }

    @objc private func windowChanged(_ notification: Notification) { scheduleLayout() }

    private func scheduleLayout() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.layoutExpandedPanel()
        }
    }

    private func layoutExpandedPanel() {
        guard let panel, panel.isVisible else { return }
        let expanded = panel.isExpanded
        defer { wasExpanded = expanded }
        guard expanded else { needsExpandedLayout = true; return }
        if !wasExpanded { needsExpandedLayout = true }
        guard needsExpandedLayout, !panel.inLiveResize,
              let screen = panel.screen ?? NSScreen.main else { return }
        needsExpandedLayout = false

        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        guard available.width > 0, available.height > 0 else { return }
        let current = panel.frame
        let width = min(max(current.width, 960), available.width)
        let height = min(max(current.height, 640), available.height)
        let frame = NSRect(
            x: min(max(current.midX - width / 2, available.minX), available.maxX - width),
            y: min(max(current.maxY - height, available.minY), available.maxY - height),
            width: width, height: height)
        guard abs(frame.width - current.width) > 0.5 || abs(frame.height - current.height) > 0.5 ||
              abs(frame.minX - current.minX) > 0.5 || abs(frame.minY - current.minY) > 0.5 else { return }
        panel.setFrame(frame, display: true)
    }
}
