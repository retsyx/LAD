import AppKit
import SwiftUI

/// Marks the complete composer without replacing its native TextEditor.
struct PromptFilePathDropRegion: NSViewRepresentable {
    @Binding var text: String
    var onFocus: @MainActor () -> Void
    var onAttachFiles: (@MainActor ([URL]) -> Void)? = nil
    var onAttachImages: (@MainActor ([PromptImagePayload]) -> Void)? = nil

    func makeNSView(context: Context) -> PromptFilePathDropView {
        let view = PromptFilePathDropView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: PromptFilePathDropView, context: Context) { configure(view) }

    static func dismantleNSView(_ view: PromptFilePathDropView, coordinator: ()) { view.disconnect() }

    private func configure(_ view: PromptFilePathDropView) {
        view.readText = { text }
        view.writeText = { text = $0 }
        view.onFocus = onFocus
        view.onAttachFiles = onAttachFiles
        view.onAttachImages = onAttachImages
    }
}

enum PromptFilePaths {
    /// Only URL references are decoded. Files, directories, and their bytes
    /// remain untouched; file promises and ordinary text are not imported.
    static func urls(from pasteboard: NSPasteboard) -> [URL]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty,
              items.allSatisfy({ $0.types.contains(.fileURL) }),
              let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              objects.count == items.count else { return nil }
        let urls = objects.compactMap { $0 as? URL }
        guard urls.count == items.count, urls.allSatisfy(\.isFileURL) else { return nil }
        return urls
    }

    static func insertion(for urls: [URL], in text: String, replacing selectedRange: NSRange) -> (range: NSRange, text: String) {
        let source = text as NSString
        let location = selectedRange.location == NSNotFound ? source.length : min(selectedRange.location, source.length)
        let length = min(selectedRange.length, source.length - location)
        let range = NSRange(location: location, length: length)
        let before = source.substring(to: location)
        let after = source.substring(from: NSMaxRange(range))
        let prefix = before.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let suffix = after.first.map { $0.isWhitespace ? "" : " " } ?? ""
        return (range, prefix + urls.map(\.path).joined(separator: "\n") + suffix)
    }
}

@MainActor
final class PromptFilePathDropView: NSView {
    private static let regions = NSHashTable<PromptFilePathDropView>.weakObjects()
    var readText: (() -> String)?
    var writeText: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachImages: (([PromptImagePayload]) -> Void)?
    private var dragSequence: Int?
    private var performedDrop = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(PromptAttachmentPasteboard.draggedTypes)
        Self.regions.add(self)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func region(at location: NSPoint, in window: NSWindow?) -> PromptFilePathDropView? {
        guard let window else { return nil }
        return regions.allObjects.first { region in
            guard region.window === window, !region.isHiddenOrHasHiddenAncestor, region.writeText != nil else { return false }
            let visible = region.visibleRect.intersection(region.bounds)
            return !visible.isEmpty && region.convert(visible, to: nil).contains(location)
        }
    }

    func disconnect() {
        Self.regions.remove(self)
        unregisterDraggedTypes()
        readText = nil
        writeText = nil
        onFocus = nil
        onAttachFiles = nil
        onAttachImages = nil
        dragSequence = nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragSequence = sender.draggingSequenceNumber
        performedDrop = false
        return accepts(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if dragSequence != sender.draggingSequenceNumber { return draggingEntered(sender) }
        return accepts(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragSequence == sender.draggingSequenceNumber && !performedDrop && accepts(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender) else { return false }
        if let urls = PromptFilePaths.urls(from: sender.draggingPasteboard) {
            performedDrop = true
            let imageURLs = onAttachFiles == nil ? [] : urls.filter { SourceImport.isImageURL($0) }
            if !imageURLs.isEmpty { onAttachFiles?(imageURLs) }
            let paths = urls.filter { !imageURLs.contains($0) }
            if !paths.isEmpty { insert(paths) }
            else { focusEditor() }
            return true
        }
        guard let images = PromptAttachmentPasteboard.images(from: sender.draggingPasteboard), let onAttachImages else { return false }
        performedDrop = true
        onAttachImages(images)
        focusEditor()
        return true
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dragSequence = nil }
    override func draggingEnded(_ sender: any NSDraggingInfo) { dragSequence = nil }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy), writeText != nil else { return false }
        if PromptFilePaths.urls(from: sender.draggingPasteboard) != nil { return true }
        return onAttachImages != nil && PromptAttachmentPasteboard.canRead(sender.draggingPasteboard)
    }

    private func insert(_ urls: [URL]) {
        if let editor = promptEditor() {
            let insertion = PromptFilePaths.insertion(for: urls, in: editor.string, replacing: editor.selectedRange())
            if window?.isVisible == true { window?.makeKeyAndOrderFront(nil) }
            window?.makeFirstResponder(editor)
            editor.insertText(insertion.text, replacementRange: insertion.range)
            writeText?(editor.string)
        } else {
            let current = readText?() ?? ""
            let insertion = PromptFilePaths.insertion(for: urls, in: current,
                                                      replacing: NSRange(location: (current as NSString).length, length: 0))
            writeText?((current as NSString).replacingCharacters(in: insertion.range, with: insertion.text))
            if window?.isVisible == true { window?.makeKeyAndOrderFront(nil) }
        }
        onFocus?()
        if window?.isVisible == true { NSApp?.activate(ignoringOtherApps: true) }
    }

    private func focusEditor() {
        if let editor = promptEditor() { window?.makeFirstResponder(editor) }
        onFocus?()
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            NSApp?.activate(ignoringOtherApps: true)
        }
    }

    private func promptEditor() -> NSTextView? {
        let clippedBounds = visibleRect.intersection(bounds)
        guard let root = window?.contentView, !clippedBounds.isEmpty else { return nil }
        let region = convert(clippedBounds, to: nil)
        var best: NSTextView?
        var bestArea: CGFloat = 0
        func inspect(_ view: NSView) {
            if let editor = view as? NSTextView, editor.isEditable, !editor.isFieldEditor, !editor.isHiddenOrHasHiddenAncestor {
                let visible: NSView = editor.enclosingScrollView.map { $0 as NSView } ?? editor
                let clippedEditorBounds = visible.visibleRect.intersection(visible.bounds)
                let overlap = region.intersection(visible.convert(clippedEditorBounds, to: nil))
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > bestArea { best = editor; bestArea = area }
            }
            for child in view.subviews { inspect(child) }
        }
        inspect(root)
        return best
    }
}
