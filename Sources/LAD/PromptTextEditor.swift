import AppKit
import SwiftUI

struct PromptImagePayload: Sendable {
    var data: Data
    var name: String = "Pasted image"
}

enum PromptAttachmentInput: Sendable {
    case files([URL])
    case images([PromptImagePayload])

    func attachments() throws -> [SourceAttachment] {
        switch self {
        case .files(let urls): return try SourceImport.load(urls: urls)
        case .images(let images):
            guard images.count <= SourceImport.maximumImages else {
                throw LADError.message("Too many images were pasted at once.")
            }
            return try images.map { try SourceImport.imageAttachment(data: $0.data, name: $0.name) }
        }
    }
}

enum PromptAttachmentPasteboard {
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"), NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("com.microsoft.bmp")
    ]
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL] + imageTypes

    /// Drag hover examines representations only. Image bytes are read once
    /// when the drop or paste is accepted, never repeatedly during navigation.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        PromptFilePaths.urls(from: pasteboard) != nil ||
            (pasteboard.pasteboardItems?.contains { item in imageTypes.contains { item.types.contains($0) } } ?? false)
    }

    static func imageURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let urls = PromptFilePaths.urls(from: pasteboard), !urls.isEmpty,
              urls.allSatisfy({ SourceImport.isImageURL($0) }) else { return nil }
        return urls
    }

    static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
        if imageURLs(from: pasteboard) != nil { return true }
        guard PromptFilePaths.urls(from: pasteboard) == nil else { return false }
        return pasteboard.pasteboardItems?.contains { item in imageTypes.contains { item.types.contains($0) } } ?? false
    }

    static func images(from pasteboard: NSPasteboard) -> [PromptImagePayload]? {
        // Finder often provides a TIFF icon alongside its URL. Its actual
        // file wins over that decorative representation.
        guard PromptFilePaths.urls(from: pasteboard) == nil,
              let items = pasteboard.pasteboardItems else { return nil }
        var images: [PromptImagePayload] = []
        for item in items {
            guard let type = imageTypes.first(where: { item.types.contains($0) }),
                  let bytes = item.data(forType: type) else { continue }
            images.append(PromptImagePayload(data: bytes))
            // One extra item reports the over-limit batch without copying an
            // unbounded collection of pasteboard payloads into the process.
            if images.count > SourceImport.maximumImages { break }
        }
        return images.isEmpty ? nil : images
    }
}

/// A plain native text editor keeps normal text/undo behavior while routing
/// image paste through attachments instead of embedding rich text or RTFD.
struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var onFocus: @MainActor () -> Void
    var onBlur: @MainActor () -> Void
    var onAttachFiles: @MainActor ([URL]) -> Void
    var onAttachImages: @MainActor ([PromptImagePayload]) -> Void
    var onSubmit: (@MainActor () -> Void)? = nil
    var onDispatchNextQueuedRequest: (@MainActor () -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = PromptTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textColor = .labelColor
        editor.font = .systemFont(ofSize: 12)
        editor.textContainerInset = NSSize(width: 5, height: 0)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Design prompt")
        editor.setAccessibilityIdentifier("projectPromptEditor")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        context.coordinator.editor = editor
        configure(editor, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PromptTextView else { return }
        configure(editor, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? PromptTextView else { return }
        editor.onFocus = nil; editor.onBlur = nil
        editor.onAttachFiles = nil; editor.onAttachImages = nil
        editor.onSubmit = nil; editor.onDispatchNextQueuedRequest = nil
        editor.delegate = nil
        coordinator.editor = nil
    }

    private func configure(_ editor: PromptTextView, coordinator: Coordinator) {
        coordinator.writeText = { text = $0 }
        editor.onFocus = onFocus; editor.onBlur = onBlur
        editor.onAttachFiles = onAttachFiles; editor.onAttachImages = onAttachImages
        editor.onSubmit = onSubmit; editor.onDispatchNextQueuedRequest = onDispatchNextQueuedRequest
        if editor.string != text {
            let range = editor.selectedRange()
            editor.string = text
            let count = (text as NSString).length
            let location = min(range.location == NSNotFound ? count : range.location, count)
            editor.setSelectedRange(NSRange(location: location, length: min(range.length, count - location)))
            editor.undoManager?.removeAllActions()
        }
        coordinator.wantsFocus = isFocused
        coordinator.focusIfRequested()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var editor: PromptTextView?
        var writeText: ((String) -> Void)?
        var wantsFocus = false
        private var focusScheduled = false

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            writeText?(editor.string)
        }

        func focusIfRequested() {
            guard wantsFocus, !focusScheduled, editor?.window?.firstResponder !== editor else { return }
            focusScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.focusScheduled = false
                guard self.wantsFocus, let editor = self.editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
            }
        }
    }
}

@MainActor
final class PromptTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachImages: (([PromptImagePayload]) -> Void)?
    var onSubmit: (() -> Void)?
    var onDispatchNextQueuedRequest: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, !hasMarkedText(), isReturn(event),
           requestModifiers(event) == .command {
            onDispatchNextQueuedRequest?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Let the input method confirm composed text before interpreting a
        // Return as a request action.
        if !hasMarkedText(), isReturn(event) {
            switch requestModifiers(event) {
            case []:
                onSubmit?()
                return
            case .option:
                insertNewline(nil)
                return
            case .command:
                onDispatchNextQueuedRequest?()
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    private func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private func requestModifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        PromptAttachmentPasteboard.draggedTypes + super.readablePasteboardTypes.filter {
            !PromptAttachmentPasteboard.draggedTypes.contains($0)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onBlur?() }
        return result
    }

    override func paste(_ sender: Any?) {
        if attachImages(from: .general) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if attachImages(from: .general) { return }
        super.pasteAsPlainText(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)),
           (onAttachFiles != nil || onAttachImages != nil), PromptAttachmentPasteboard.containsImages(.general) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if attachImages(from: pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    @discardableResult
    func attachImages(from pasteboard: NSPasteboard) -> Bool {
        if let urls = PromptAttachmentPasteboard.imageURLs(from: pasteboard), let onAttachFiles {
            onAttachFiles(urls)
            return true
        }
        if let images = PromptAttachmentPasteboard.images(from: pasteboard), let onAttachImages {
            onAttachImages(images)
            return true
        }
        return false
    }
}
