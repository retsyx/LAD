import AppKit
import ImageIO
import SwiftUI

/// Auxiliary panes need their owning window before CAD geometry is available.
/// The background anchor never takes focus, pointer input, or layout space.
struct ProjectActivityWindowAnchor: NSViewRepresentable {
    var onWindowChanged: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProjectActivityWindowAnchorView {
        let view = ProjectActivityWindowAnchorView()
        view.onWindowChanged = onWindowChanged
        return view
    }

    func updateNSView(_ view: ProjectActivityWindowAnchorView, context: Context) {
        view.onWindowChanged = onWindowChanged
        onWindowChanged(view.window)
    }
}

final class ProjectActivityWindowAnchorView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

/// Activity stays outside the document layout. It is created only after an
/// explicit toggle, belongs to one workspace window, and never restores visible.
@MainActor
final class ProjectActivityPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private(set) var panel: NSPanel?
    private weak var owner: NSWindow?

    var hasPanel: Bool { panel != nil }

    func toggle(state: AppState, owner window: NSWindow?) {
        if isVisible { hide(); return }
        if panel == nil {
            let panel = ProjectActivityPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                             styleMask: [.titled, .closable, .resizable],
                                             backing: .buffered, defer: false)
            panel.title = "Tool Activity"
            panel.contentMinSize = NSSize(width: 480, height: 320)
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.isMovable = true
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior.insert(.fullScreenAuxiliary)
            panel.isRestorable = false
            panel.delegate = self
            self.panel = panel
        }
        guard let panel else { return }
        let host = NSHostingView(rootView: ProjectActivityView(state: state) { [weak self] in self?.hide() }
            .preferredColorScheme(.dark))
        // AppKit owns this user-resizable panel's frame. Intrinsic SwiftUI
        // sizing must not renegotiate its bounds during title-bar dragging or
        // when long logs and asynchronously decoded images change layout.
        host.sizingOptions = []
        let container = NSView(frame: panel.contentView?.bounds ?? NSRect(origin: .zero, size: panel.contentLayoutRect.size))
        container.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        // A hosting view used directly as a window's contentView resets native
        // limits even with empty sizingOptions. Keep that bridge one level down.
        container.addSubview(host)
        panel.contentView = container
        panel.contentMinSize = NSSize(width: 480, height: 320)
        detachOwner()
        owner = window
        if let window {
            // A floating utility pane needs logical document ownership, not
            // native child-window geometry tracking. Let the window server
            // move it independently during title-bar drags.
            NotificationCenter.default.addObserver(self, selector: #selector(ownerClosed),
                                                   name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(ownerMiniaturizing),
                                                   name: NSWindow.willMiniaturizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(ownerRestored),
                                                   name: NSWindow.didDeminiaturizeNotification, object: window)
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            var origin = NSPoint(x: window.frame.maxX - panel.frame.width - 20,
                                 y: window.frame.maxY - panel.frame.height - 70)
            if let visible {
                origin.x = max(visible.minX, min(origin.x, visible.maxX - panel.frame.width))
                origin.y = max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))
            }
            panel.setFrameOrigin(origin)
        } else { panel.center() }
        isVisible = true
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        detachOwner()
        isVisible = false
    }

    func close() {
        hide()
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === panel else { return }
        detachOwner()
        isVisible = false
        closed.contentView = nil
        panel = nil
    }

    @objc private func ownerClosed() { close() }

    @objc private func ownerMiniaturizing() { panel?.orderOut(nil) }

    @objc private func ownerRestored() {
        guard isVisible, owner?.isMiniaturized == false else { return }
        panel?.orderFront(nil)
    }

    private func detachOwner() {
        if let owner {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: owner)
            NotificationCenter.default.removeObserver(self, name: NSWindow.willMiniaturizeNotification, object: owner)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: owner)
        }
        owner = nil
    }
}

private final class ProjectActivityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ProjectActivityView: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void
    @State private var expandedTasks = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tool Activity").font(.headline)
                    Text(state.projectDisplayName).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer()
                CopyButton(label: "Copy tool activity") { ProjectActivityTranscript.text(for: state.taskAudits) }
                    .disabled(state.taskAudits.isEmpty)
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Close tool activity")
                    .accessibilityLabel("Close tool activity")
            }.padding(16)
            Divider()
            if state.taskAudits.isEmpty {
                ContentUnavailableView("No tool activity yet", systemImage: "terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(state.taskAudits.reversed()) { task in taskView(task) }
                    }.padding(16)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Palette.background)
        .onAppear { if let latest = state.taskAudits.last { expandedTasks.insert(latest.id) } }
        .onChange(of: state.taskAudits.last?.id) { _, id in if let id { expandedTasks.insert(id) } }
        .accessibilityLabel("Tool Activity")
    }

    private func taskView(_ task: ProjectTaskAudit) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedTasks.contains(task.id) }, set: {
            if $0 { expandedTasks.insert(task.id) } else { expandedTasks.remove(task.id) }
        })) {
            VStack(alignment: .leading, spacing: 12) {
                if let prompt = task.request ?? state.messages.first(where: { $0.id == task.userMessageID })?.content {
                    Text(prompt).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .textSelection(.enabled).padding(.top, 4)
                }
                ForEach(task.events.reversed()) { event in
                    ProjectActivityEventView(event: event, taskID: task.id, images: state.activityImages)
                }
            }.padding(.leading, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: statusSymbol(task.status)).foregroundStyle(statusColor(task.status))
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.actorDescription)
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(task.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(task.events.count) events")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text(task.status.capitalized).font(.system(size: 10)).foregroundStyle(statusColor(task.status))
                CopyButton(label: "Copy task activity") { ProjectActivityTranscript.text(for: [task]) }
            }
        }
        .tint(Palette.muted)
        .padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusSymbol(_ status: String) -> String { ProjectActivityAppearance.symbol(status) }
    private func statusColor(_ status: String) -> Color { ProjectActivityAppearance.color(status) }
}

/// A tool image belongs to its exact task and call, rather than the latest
/// render. Collapsed entries do not create an image decoder or drawing view.
struct ProjectActivityEventView: View {
    var event: ProjectActivityEvent
    var taskID: UUID
    @ObservedObject var images: ProjectActivityImages
    @State private var isExpanded: Bool

    init(event: ProjectActivityEvent, taskID: UUID, images: ProjectActivityImages, initiallyExpanded: Bool = false) {
        self.event = event
        self.taskID = taskID
        self.images = images
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var imageKey: ProjectActivityImageKey { ProjectActivityImageKey(taskID: taskID, eventID: event.id) }
    private var hasImageResult: Bool {
        ["lad_render", "lad_screenshot"].contains(event.title) && event.status == "completed" &&
            event.output?.contains("image_path") == true
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded { result }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ProjectActivityAppearance.symbol(event.status))
                    .foregroundStyle(ProjectActivityAppearance.color(event.status))
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.system(size: 11, weight: .medium)).lineLimit(3)
                    HStack(spacing: 6) {
                        Text(event.category.capitalized)
                        Text(event.date, style: .time)
                        if let seconds = event.durationSeconds { Text("\(seconds.formatted(.number.precision(.fractionLength(0...2)))) s") }
                        Text(event.status.capitalized)
                    }.font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                CopyButton(label: "Copy activity item") { ProjectActivityTranscript.text(for: event) }
            }
        }
        .tint(Palette.muted)
        .accessibilityIdentifier("projectActivityEvent-\(taskID.uuidString)-\(event.id)")
    }

    private var result: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let input = event.input, !input.isEmpty { detail("Input", text: input) }
                if let reference = images.images[imageKey] {
                    ProjectActivityImagePreview(reference: reference)
                } else if hasImageResult {
                    Text("Preview unavailable").font(.caption).foregroundStyle(Palette.muted)
                }
                if let output = event.output, !output.isEmpty { detail("Output", text: output) }
                ForEach(Array((event.files ?? []).enumerated()), id: \.offset) { _, file in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(file.path).font(.system(size: 9)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            ProjectActivityText(text: String(decoding: file.data, as: UTF8.self)).frame(height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }.padding(.top, 6)
                    } label: {
                        HStack {
                            Label(file.name, systemImage: "doc.text").font(.system(size: 10))
                            Spacer()
                            CopyButton(label: "Copy \(file.name)") { String(decoding: file.data, as: UTF8.self) }
                        }
                    }
                }
                if event.input?.isEmpty != false && event.output?.isEmpty != false && event.files?.isEmpty != false {
                    Text(event.status.capitalized).font(.caption).foregroundStyle(Palette.muted)
                }
            }.padding(.top, 8)
    }

    private func detail(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                CopyButton(text: text, label: "Copy \(label.lowercased())")
            }
            ProjectActivityText(text: text).frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

}

private enum ProjectActivityAppearance {
    static func symbol(_ status: String) -> String {
        switch status {
        case "running", "started", "in_progress": return "clock"
        case "completed", "succeeded", "success": return "checkmark.circle"
        case "failed", "error": return "exclamationmark.circle"
        case "canceled", "cancelled": return "stop.circle"
        default: return "circle"
        }
    }

    static func color(_ status: String) -> Color {
        ["failed", "error", "running", "started", "in_progress"].contains(status) ? Palette.accent : Palette.muted
    }
}

/// Only the image shown inside an expanded tool result is decoded, off the
/// main actor. These are exact tool PNGs, never another render or screenshot.
private struct ProjectActivityImagePreview: View {
    var reference: ProjectActivityImageReference
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .accessibilityLabel("Rendered screenshot")
            } else if failed {
                Text("Preview unavailable").font(.caption).foregroundStyle(Palette.muted)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 160)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: reference.id) {
            image = nil; failed = false
            let png = reference.png
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded { image = NSImage(cgImage: decoded, size: .zero) }
            else { failed = true }
        }
    }
}

/// A native read-only text view keeps long command outputs selectable and
/// searchable without laying out the entire log as SwiftUI view fragments.
private struct ProjectActivityText: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindPanel = true
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.minSize = NSSize(width: 0, height: 160)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.sizeToFit()
    }
}

enum ProjectActivityTranscript {
    static func text(for tasks: [ProjectTaskAudit]) -> String {
        tasks.map { task in
            let actor = task.externalClient != nil ? task.actorDescription :
                "\(task.model.flatMap { $0.isEmpty ? nil : $0 } ?? "Default model") · \(task.reasoningEffort.flatMap { $0.isEmpty ? nil : $0 } ?? "Default")"
            let heading = "\(task.startedAt.formatted(date: .abbreviated, time: .standard)) · \(actor) · \(task.status)"
            var sections = [heading]
            if let client = task.externalClient {
                sections.append("Client: \(client.name)\(client.version.map { " (\($0))" } ?? "")\nClient ID: \(client.clientID)")
            }
            if let request = task.request { sections.append("Request:\n\(request)") }
            return (sections + task.events.map { text(for: $0) }).joined(separator: "\n\n")
        }.joined(separator: "\n\n────────────────────\n\n")
    }

    static func text(for event: ProjectActivityEvent) -> String {
        var lines = ["\(event.date.formatted(date: .abbreviated, time: .standard)) · \(event.category) · \(event.title) · \(event.status)"]
        if let duration = event.durationSeconds { lines.append("Duration: \(duration) s") }
        if let input = event.input, !input.isEmpty { lines.append("Input:\n\(input)") }
        if let output = event.output, !output.isEmpty { lines.append("Output:\n\(output)") }
        for file in event.files ?? [] {
            lines.append("File: \(file.name)\nPath: \(file.path)\n\(String(decoding: file.data, as: UTF8.self))")
        }
        return lines.joined(separator: "\n")
    }
}
