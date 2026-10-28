import AppKit
import CryptoKit
import Quartz
import SwiftUI
import XCTest
@testable import LAD

final class PromptImageAttachmentTests: XCTestCase {
    @MainActor
    func testNativeImagePasteKeepsDraftCaretAndAcceptsMultipleImages() throws {
        let red = try png(.systemRed), blue = try png(.systemBlue)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let items = [red, blue].map { data in
            let item = NSPasteboardItem(); item.setData(data, forType: .png); return item
        }
        XCTAssertTrue(board.writeObjects(items))
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Keep this text"
        let range = (fixture.editor.string as NSString).range(of: "this")
        fixture.editor.setSelectedRange(range)
        var received: [PromptImagePayload] = []
        fixture.editor.onAttachImages = { received += $0 }

        XCTAssertTrue(fixture.editor.readablePasteboardTypes.contains(.png))
        XCTAssertTrue(fixture.editor.readSelection(from: board, type: .png))
        XCTAssertEqual(received.map(\.data), [red, blue])
        XCTAssertEqual(fixture.editor.string, "Keep this text")
        XCTAssertEqual(fixture.editor.selectedRange(), range,
                       "Attaching image data must leave the native text selection and caret untouched.")
    }

    @MainActor
    func testOrdinaryTextPasteRetainsNativeReplacementAndUndoBehavior() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("changed", forType: .string)
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Keep this text"
        fixture.editor.setSelectedRange((fixture.editor.string as NSString).range(of: "this"))
        fixture.editor.allowsUndo = true
        fixture.window.makeFirstResponder(fixture.editor)
        var received = 0
        fixture.editor.onAttachImages = { received += $0.count }
        XCTAssertFalse(PromptAttachmentPasteboard.containsImages(board))
        XCTAssertTrue(fixture.editor.readSelection(from: board, type: .string))
        XCTAssertEqual(fixture.editor.string, "Keep changed text")
        XCTAssertEqual(received, 0)
    }

    @MainActor
    func testFinderImageURLWinsOverItsDecorativeTIFFRepresentation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Case view.png")
        let data = try png(.systemRed)
        try data.write(to: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(Data("Finder thumbnail is not the image".utf8), forType: .tiff)
        XCTAssertTrue(board.writeObjects([item]))
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        var urls: [URL] = [], rawCount = 0
        fixture.editor.onAttachFiles = { urls += $0 }
        fixture.editor.onAttachImages = { rawCount += $0.count }
        XCTAssertTrue(fixture.editor.attachImages(from: board))
        XCTAssertEqual(urls, [url])
        XCTAssertEqual(rawCount, 0)
        XCTAssertNil(PromptAttachmentPasteboard.images(from: board))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor
    func testMixedDropAttachesImagesAndInsertsOtherFileAndFolderPaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("reference.png")
        let project = directory.appendingPathComponent("Other design.lad")
        let folder = directory.appendingPathComponent("Photos.png", isDirectory: true)
        try png(.systemBlue).write(to: image)
        try Data("DO-NOT-INLINE-THE-FILE".utf8).write(to: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([image, project, folder].map { $0 as NSURL }))
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Use this input"
        fixture.editor.setSelectedRange((fixture.editor.string as NSString).range(of: "this"))
        var bound = fixture.editor.string, attached: [URL] = []
        fixture.region.readText = { bound }
        fixture.region.writeText = { bound = $0 }
        fixture.region.onAttachFiles = { attached += $0 }
        let drag = PromptImageDraggingInfo(pasteboard: board, window: fixture.window)
        XCTAssertEqual(fixture.region.draggingEntered(drag), .copy)
        XCTAssertTrue(fixture.region.performDragOperation(drag))
        XCTAssertFalse(fixture.region.performDragOperation(drag), "An accepted drag session must be consumed only once.")
        XCTAssertEqual(attached, [image])
        XCTAssertEqual(bound, "Use \(project.path)\n\(folder.path) input")
        XCTAssertFalse(bound.contains("DO-NOT-INLINE"))
        XCTAssertFalse(bound.contains(image.path))
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
    }

    @MainActor
    func testRawImageDropAddsImagesWithoutChangingTextSelection() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bytes = [try png(.systemRed), try png(.systemBlue)]
        XCTAssertTrue(board.writeObjects(bytes.map { data in
            let item = NSPasteboardItem(); item.setData(data, forType: .png); return item
        }))
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Keep 🔩 the draft"
        let range = (fixture.editor.string as NSString).range(of: "the")
        fixture.editor.setSelectedRange(range)
        fixture.region.readText = { fixture.editor.string }
        fixture.region.writeText = { fixture.editor.string = $0 }
        var received: [PromptImagePayload] = []
        fixture.region.onAttachImages = { received += $0 }
        let drag = PromptImageDraggingInfo(pasteboard: board, window: fixture.window)
        XCTAssertEqual(fixture.region.draggingEntered(drag), .copy)
        XCTAssertTrue(fixture.region.performDragOperation(drag))
        XCTAssertEqual(received.map(\.data), bytes)
        XCTAssertEqual(fixture.editor.string, "Keep 🔩 the draft")
        XCTAssertEqual(fixture.editor.selectedRange(), range)
    }

    @MainActor
    func testReplacingTheComposerScopeCannotAttachLateImageReadsToAnotherDesign() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.newProject()
        let old = state.projectDocumentID
        state.attachPromptImages([PromptImagePayload(data: try png(.systemRed))])
        XCTAssertTrue(state.isReadingPromptAttachments)
        state.newProject()
        XCTAssertNotEqual(state.projectDocumentID, old)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(state.pendingAttachments.isEmpty)
        XCTAssertFalse(state.isReadingPromptAttachments)
        await state.prepareToQuit()
    }

    @MainActor
    func testPreviewExtractionUsesArchiveBytesAndCleansItsPrivateFile() throws {
        let image = try SourceImport.imageAttachment(data: png(.systemBlue), name: "Reference", path: "/no-longer-existing/reference.png")
        var preview: PromptImagePreviewFile? = try PromptImagePreviewFile(attachment: image)
        let url = try XCTUnwrap(preview?.url)
        XCTAssertEqual(try Data(contentsOf: url), image.imageData)
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, image.sha256)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        preview = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @MainActor
    func testArchivedImageReachesActualQuickLookPreviewAndCleansUpWhenClosed() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("Original reference.png")
        let bytes = try png(.systemBlue)
        try bytes.write(to: originalURL)
        let attachment = try XCTUnwrap(SourceImport.load(urls: [originalURL]).first)
        let message = ChatMessage(role: "user", content: "Review this reference image.", attachments: [attachment])
        let project = LADProject(messages: [message], revisions: [], selectedRevisionID: nil, projectID: UUID())
        let archive = try ProjectStore.encode(project)
        try FileManager.default.removeItem(at: originalURL)
        let restored = try ProjectStore.decode(archive)
        let image = try XCTUnwrap(restored.messages.first?.attachments?.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 680, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(PromptImagePreview(attachment: image)))
        host.sizingOptions = []
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let deadline = ContinuousClock.now + .seconds(5)
        var preview: QLPreviewView?
        var extractedURL: URL?
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let candidate = descendants(host).compactMap({ $0 as? QLPreviewView }).first,
               let url = candidate.previewItem?.previewItemURL {
                preview = candidate
                extractedURL = url
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let actualPreview = try XCTUnwrap(preview, "The production image preview must mount a native Quick Look view.")
        let actualURL = try XCTUnwrap(extractedURL, "Quick Look must receive a real local image reference.")
        XCTAssertTrue(actualURL.isFileURL)
        XCTAssertNotEqual(actualURL.standardizedFileURL, originalURL.standardizedFileURL)
        XCTAssertEqual(actualURL.deletingPathExtension().lastPathComponent, image.sha256)
        XCTAssertEqual(try Data(contentsOf: actualURL), bytes,
                       "Quick Look must read the exact image recovered from the ZIP archive, independently of its former path.")
        XCTAssertGreaterThan(actualPreview.frame.width, 100)
        XCTAssertGreaterThan(actualPreview.frame.height, 100)

        // Replacing the presented production view runs its real SwiftUI
        // disappearance and representable teardown, rather than manually
        // deleting the file or calling Quick Look's close method in the test.
        host.rootView = AnyView(Color.clear)
        let closeDeadline = ContinuousClock.now + .seconds(5)
        while (actualPreview.previewItem != nil || FileManager.default.fileExists(atPath: actualURL.path)),
              ContinuousClock.now < closeDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(actualPreview.previewItem, "Production teardown must release Quick Look's preview item.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: actualURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: actualURL.deletingLastPathComponent().path))
    }

    @MainActor
    func testMultipleImageCardsRenderAndTheirRemoveButtonsTargetOnlyOneImage() async throws {
        _ = NSApplication.shared
        let red = try SourceImport.imageAttachment(data: png(.systemRed), name: "Red view")
        let blue = try SourceImport.imageAttachment(data: png(.systemBlue), name: "Blue view")
        let state = CardFixture(images: [red, blue])
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CardStrip(state: state))
        host.sizingOptions = []
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let imageDeadline = ContinuousClock.now + .seconds(2)
        var rendered = try bitmap(host)
        while !tileCentersAreColored(rendered, host: host), ContinuousClock.now < imageDeadline {
            try await Task.sleep(for: .milliseconds(20))
            rendered = try bitmap(host)
        }
        XCTAssertTrue(tileCentersAreColored(rendered, host: host),
                      "Both decoded image tiles must show their red/blue pixels, not transparent data or a loading placeholder.")
        try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/lad-prompt-image-thumbnails.png"))
        let buttons = leafFrames(in: host).filter { abs($0.width - 19) < 1 && abs($0.height - 19) < 1 }.sorted { $0.midX < $1.midX }
        XCTAssertEqual(buttons.count, 2)
        try click(try XCTUnwrap(buttons.last), in: host)
        let deadline = ContinuousClock.now + .seconds(2)
        while state.images.count != 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.images.map(\.id), [red.id])
        XCTAssertEqual(state.removed, [blue.id])
    }

    @MainActor
    func testEmptyHostedPromptKeepsItsEntireHeightEditable() async throws {
        _ = NSApplication.shared
        let state = EditorFixtureState()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 130),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: EditorFixtureView(state: state))
        host.sizingOptions = []
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? PromptTextView }.first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scroll.contentView.bounds.height, 78, accuracy: 1)
        XCTAssertGreaterThanOrEqual(editor.frame.height, scroll.contentView.bounds.height - 1,
                                   "An empty prompt's editable document must fill its visible text area.")
        XCTAssertGreaterThanOrEqual(editor.minSize.height, scroll.contentView.bounds.height - 1)
        window.makeFirstResponder(nil)
        state.focused = false
        let lowerPoint = scroll.contentView.isFlipped
            ? NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.maxY - 8)
            : NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.minY + 8)
        let pointInHost = host.convert(lowerPoint, from: scroll.contentView)
        let pointInEditor = editor.convert(lowerPoint, from: scroll.contentView)
        XCTAssertTrue(editor.bounds.contains(pointInEditor))
        let scrollParent = try XCTUnwrap(scroll.superview)
        let hit = scroll.hitTest(scrollParent.convert(pointInHost, from: host))
        XCTAssertTrue(hit === editor || hit?.isDescendant(of: editor) == true,
                      "The lower empty area must route to the native editor, rather than only the scroll container.")
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(state.focused)
        // XCTest's background application sometimes cannot become key even
        // after makeKeyAndOrderFront. Check real mouse focus when it can; the
        // native hit target and focus callback above remain verified otherwise.
        if window.isKeyWindow {
            window.makeFirstResponder(nil)
            state.focused = false
            try click(NSRect(x: pointInHost.x - 1, y: pointInHost.y - 1, width: 2, height: 2), in: host)
            let deadline = ContinuousClock.now + .seconds(2)
            while window.firstResponder !== editor, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(window.firstResponder === editor,
                          "Clicking low in the active empty field must focus its native request editor.")
            XCTAssertTrue(state.focused)
        }
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    private func png(_ color: NSColor) throws -> Data {
        try ImageAttachmentTestImage.png(color)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-prompt-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @MainActor
    private func leafFrames(in root: NSView) -> [NSRect] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var frames: [NSRect] = []
        for view in descendants(root) where view.subviews.isEmpty && !view.isHiddenOrHasHiddenAncestor {
            let frame = root.convert(view.bounds, from: view)
            guard !frames.contains(frame) else { continue }
            frames.append(frame)
        }
        return frames
    }

    @MainActor
    private func click(_ rect: NSRect, in host: NSView) throws {
        let window = try XCTUnwrap(host.window)
        window.makeKey()
        let point = host.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        // NSTextView can track a mouse-down synchronously. Queue its mouse-up
        // first so that native tracking never waits for an event the test has
        // not delivered yet. SwiftUI buttons may leave it queued instead.
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApplication.shared.postEvent(up, atStart: false)
        NSApplication.shared.sendEvent(down)
        if let release = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(release)
        }
    }

    @MainActor
    private func snapshot(_ view: NSView, to path: String) throws {
        let bitmap = try bitmap(view)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func tileCentersAreColored(_ bitmap: NSBitmapImageRep, host: NSView) -> Bool {
        // This owned strip has 12 pt outer padding, 112 pt images with 6 pt
        // card padding and 4 pt spacing. Sample inside both visible tiles.
        let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        guard let image = bitmap.cgImage else { return false }
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }
        let row = Int(host.bounds.midY * scaleY)
        let red = (row * width + Int(74 * scaleX)) * 4
        let blue = (row * width + Int(202 * scaleX)) * 4
        return pixels[red + 3] > 240 && pixels[blue + 3] > 240 &&
            pixels[red] > 170 && Int(pixels[red]) > Int(pixels[red + 2]) + 75 &&
            pixels[blue + 2] > 170 && Int(pixels[blue + 2]) > Int(pixels[blue]) + 75
    }

    @MainActor
    private final class CardFixture: ObservableObject {
        @Published var images: [SourceAttachment]
        var removed: [UUID] = []
        init(images: [SourceAttachment]) { self.images = images }
        func remove(_ id: UUID) { removed.append(id); images.removeAll { $0.id == id } }
    }

    private struct CardStrip: View {
        @ObservedObject var state: CardFixture
        var body: some View {
            HStack(spacing: 4) {
                ForEach(state.images) { image in PromptImageAttachmentView(attachment: image, onRemove: { state.remove(image.id) }) }
                Spacer(minLength: 0)
            }.padding(12).background(Palette.background)
        }
    }

    @MainActor
    private final class EditorFixtureState: ObservableObject {
        @Published var text = ""
        @Published var focused = false
    }

    private struct EditorFixtureView: View {
        @ObservedObject var state: EditorFixtureState
        var body: some View {
            PromptTextEditor(text: $state.text, isFocused: state.focused,
                onFocus: { state.focused = true }, onBlur: { state.focused = false },
                onAttachFiles: { _ in }, onAttachImages: { _ in })
                .frame(width: 360, height: 78)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @MainActor
    private final class NativeEditorFixture {
        let window: NSWindow
        let editor: PromptTextView
        let region: PromptFilePathDropView
        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            editor = PromptTextView(frame: NSRect(x: 15, y: 65, width: 360, height: 90))
            editor.isRichText = false; editor.importsGraphics = false; editor.font = .systemFont(ofSize: 12)
            region = PromptFilePathDropView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            window.contentView?.addSubview(editor)
            window.contentView?.addSubview(region)
        }
        func close() { region.disconnect(); window.contentView = nil; window.close() }
    }
}

@MainActor
private final class PromptImageDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint(x: 60, y: 60)
    var draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any? = nil
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(pasteboard: NSPasteboard, window: NSWindow) { draggingPasteboard = pasteboard; draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
