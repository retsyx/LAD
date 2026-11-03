import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Installs a drag destination above both the workspace and native title bar.
/// The SwiftUI anchor itself always passes ordinary input through.
struct ProjectFileDropTarget: NSViewRepresentable {
    var onDrop: @MainActor (URL) -> Void

    func makeNSView(context: Context) -> ProjectFileDropAnchor {
        ProjectFileDropAnchor(onDrop: onDrop)
    }

    func updateNSView(_ view: ProjectFileDropAnchor, context: Context) {
        view.configure(onDrop: onDrop)
    }

    static func dismantleNSView(_ view: ProjectFileDropAnchor, coordinator: ()) {
        view.disconnect()
    }
}

@MainActor
final class ProjectFileDropAnchor: NSView {
    private var onDrop: @MainActor (URL) -> Void
    private(set) var dropSurface: ProjectFileDropView?
    private(set) var contentDropSurface: ProjectFileDropView?
    private weak var installedContainer: NSView?
    private weak var installedContent: NSView?
    private weak var installedWindow: NSWindow?
    private weak var closedWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(onDrop: @escaping @MainActor (URL) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(onDrop: @escaping @MainActor (URL) -> Void) {
        self.onDrop = onDrop
        connectWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectWindow()
    }

    func disconnect() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        dropSurface?.unregisterDraggedTypes()
        dropSurface?.onDrop = nil
        dropSurface?.removeFromSuperview()
        dropSurface = nil
        contentDropSurface?.unregisterDraggedTypes()
        contentDropSurface?.onDrop = nil
        contentDropSurface?.removeFromSuperview()
        contentDropSurface = nil
        installedContainer = nil
        installedContent = nil
        installedWindow = nil
    }

    private func connectWindow() {
        guard let window, window !== closedWindow, let content = window.contentView, let container = content.superview else {
            disconnect()
            return
        }
        if installedWindow === window, installedContainer === container, installedContent === content,
           let dropSurface, let contentDropSurface {
            dropSurface.onDrop = onDrop
            dropSurface.frame = container.bounds
            container.addSubview(dropSurface, positioned: .above, relativeTo: nil)
            contentDropSurface.onDrop = onDrop
            contentDropSurface.frame = content.bounds
            content.addSubview(contentDropSurface, positioned: .above, relativeTo: nil)
            return
        }
        disconnect()
        closedWindow = nil
        let surface = ProjectFileDropView(onDrop: onDrop)
        surface.frame = container.bounds
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface, positioned: .above, relativeTo: nil)
        // Keep a destination in the content subtree as well as the frame. A
        // native content drag lookup need not inspect title-bar siblings.
        let contentSurface = ProjectFileDropView(onDrop: onDrop)
        contentSurface.frame = content.bounds
        contentSurface.autoresizingMask = [.width, .height]
        content.addSubview(contentSurface, positioned: .above, relativeTo: nil)
        dropSurface = surface
        contentDropSurface = contentSurface
        installedContainer = container
        installedContent = content
        installedWindow = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.closedWindow = window
                self?.disconnect()
            }
        }
    }
}

enum ProjectFileDrop {
    static let textTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.text.identifier), .string, .rtf, .rtfd, .html, .tabularText
    ]

    /// Finder URLs and image representations keep their existing routes even
    /// when the pasteboard also contains a textual label or path.
    static func isTextOnly(_ pasteboard: NSPasteboard) -> Bool {
        guard !PromptAttachmentPasteboard.canRead(pasteboard) else { return false }
        return pasteboard.pasteboardItems?.contains { item in
            item.types.contains { type in
                textTypes.contains(type) || UTType(type.rawValue)?.conforms(to: .text) == true
            }
        } ?? false
    }

    /// Read URL references and filesystem metadata only, never file contents.
    /// Reject the whole drag rather than silently selecting one of many items.
    static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let items = pasteboard.pasteboardItems, items.count == 1,
              items[0].types.contains(.fileURL),
              let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              objects.count == 1, let url = objects[0] as? URL,
              url.isFileURL, url.pathExtension.lowercased() == "lad",
              let metadata = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              metadata.isDirectory == true, metadata.isSymbolicLink != true else { return nil }
        return url
    }
}

@MainActor
final class ProjectFileDropView: NSView {
    var onDrop: (@MainActor (URL) -> Void)?
    private weak var forwardedDestination: NSView?
    private weak var promptDestination: PromptFilePathDropView?
    private var dragSequence: Int?
    private var performedDrop = false
    private var handlesProject = false

    init(onDrop: @escaping @MainActor (URL) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes(PromptAttachmentPasteboard.draggedTypes + ProjectFileDrop.textTypes)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    // Mouse hit testing and native drag registration are separate mechanisms.
    // In particular, an external drag need not use NSPasteboard(name: .drag),
    // and its mouse-button state must not decide whether it is accepted.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        resetDrag()
        dragSequence = sender.draggingSequenceNumber
        return updateDestination(sender, entering: true)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dragSequence == sender.draggingSequenceNumber else { return draggingEntered(sender) }
        return updateDestination(sender, entering: false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard dragSequence == sender.draggingSequenceNumber, !performedDrop else { return false }
        if let promptDestination { return promptDestination.prepareForDragOperation(sender) }
        if handlesProject { return acceptedURL(sender) != nil }
        return validForwardedDestination(sender)?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard dragSequence == sender.draggingSequenceNumber, !performedDrop else { return false }
        if let promptDestination {
            performedDrop = promptDestination.performDragOperation(sender)
            return performedDrop
        }
        if handlesProject {
            guard let url = acceptedURL(sender), let onDrop else { return false }
            performedDrop = true
            onDrop(url)
            return true
        }
        performedDrop = validForwardedDestination(sender)?.performDragOperation(sender) ?? false
        return performedDrop
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        promptDestination?.concludeDragOperation(sender)
        forwardedDestination?.concludeDragOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        promptDestination?.draggingExited(sender)
        forwardedDestination?.draggingExited(sender)
        resetDrag()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        promptDestination?.draggingEnded(sender)
        forwardedDestination?.draggingEnded(sender)
        resetDrag()
    }

    private func updateDestination(_ sender: any NSDraggingInfo, entering: Bool) -> NSDragOperation {
        // Images become composer attachments; all other files, including LAD
        // documents, remain path references rather than replacing the design.
        let prompt = !PromptAttachmentPasteboard.canRead(sender.draggingPasteboard) ? nil :
            PromptFilePathDropView.region(at: sender.draggingLocation, in: sender.draggingDestinationWindow ?? window)
        if let prompt {
            handlesProject = false
            forwardedDestination?.draggingExited(sender)
            forwardedDestination = nil
            if promptDestination !== prompt {
                promptDestination?.draggingExited(sender)
                promptDestination = prompt
                return prompt.draggingEntered(sender)
            }
            return prompt.draggingUpdated(sender)
        }
        promptDestination?.draggingExited(sender)
        promptDestination = nil
        handlesProject = ProjectFileDrop.fileURL(from: sender.draggingPasteboard) != nil
        if handlesProject {
            forwardedDestination?.draggingExited(sender)
            forwardedDestination = nil
            return acceptedURL(sender) == nil ? [] : .copy
        }
        let destination = underlyingDestination(sender)
        if destination !== forwardedDestination {
            forwardedDestination?.draggingExited(sender)
            forwardedDestination = destination
            return destination?.draggingEntered(sender) ?? []
        }
        if entering { return destination?.draggingEntered(sender) ?? [] }
        return destination?.draggingUpdated(sender) ?? []
    }

    /// Non-design file drops still reach their existing native/SwiftUI handler.
    /// Ordinary hit testing skips this passive surface and locates that target.
    private func underlyingDestination(_ sender: any NSDraggingInfo) -> NSView? {
        guard let targetWindow = sender.draggingDestinationWindow ?? window,
              let root = targetWindow.contentView?.superview else { return nil }
        var candidate = root.hitTest(root.convert(sender.draggingLocation, from: nil))
        let textOnly = ProjectFileDrop.isTextOnly(sender.draggingPasteboard)
        while let view = candidate {
            if textOnly {
                // Native text inputs retain their own insertion, selection,
                // and undo behavior. Text over other controls is not a command.
                if let editor = view as? NSTextView, editor.isEditable { return editor }
                if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
                candidate = view.superview
                continue
            }
            if view !== self, !view.registeredDraggedTypes.isEmpty,
               sender.draggingPasteboard.availableType(from: view.registeredDraggedTypes) != nil { return view }
            candidate = view.superview
        }
        return nil
    }

    private func validForwardedDestination(_ sender: any NSDraggingInfo) -> NSView? {
        guard let forwardedDestination else { return nil }
        if ProjectFileDrop.isTextOnly(sender.draggingPasteboard),
           underlyingDestination(sender) !== forwardedDestination { return nil }
        return forwardedDestination
    }

    private func resetDrag() {
        forwardedDestination = nil
        promptDestination = nil
        dragSequence = nil
        performedDrop = false
        handlesProject = false
    }

    private func acceptedURL(_ sender: any NSDraggingInfo) -> URL? {
        guard sender.draggingSourceOperationMask.contains(.copy), onDrop != nil else { return nil }
        return ProjectFileDrop.fileURL(from: sender.draggingPasteboard)
    }
}
