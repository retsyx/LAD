import AppKit
import XCTest
@testable import LAD

final class ProjectFileDropTests: XCTestCase {
    @MainActor
    func testTextDropsAreRejectedOverNonTextSurfacesAndNeverForwardedAsCommands() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let nonText = FileDropDestinationProbe(frame: NSRect(x: 20, y: 30, width: 200, height: 120))
        nonText.registerForDraggedTypes([.string, .rtf])
        content.addSubview(nonText)
        var opened: [URL] = []
        let anchor = ProjectFileDropAnchor(onDrop: { opened.append($0) })
        content.addSubview(anchor)
        defer { anchor.disconnect() }
        let surface = try XCTUnwrap(anchor.contentDropSurface)
        XCTAssertTrue(surface.registeredDraggedTypes.contains(.string))
        XCTAssertTrue(surface.registeredDraggedTypes.contains(.rtf))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let sender = FileDropDraggingInfo(pasteboard: board)
        sender.draggingDestinationWindow = window
        for type in [NSPasteboard.PasteboardType.string, .rtf] {
            board.clearContents()
            XCTAssertTrue(board.setData(Data("body".utf8), forType: type))
            for mask: NSDragOperation in [.copy, .move, []] {
                sender.draggingSourceOperationMask = mask
                for point in [NSPoint(x: 100, y: 80), NSPoint(x: 350, y: 220)] {
                    sender.draggingSequenceNumber += 1
                    sender.draggingLocation = point
                    XCTAssertEqual(surface.draggingEntered(sender), [])
                    XCTAssertEqual(surface.draggingUpdated(sender), [])
                    XCTAssertFalse(surface.prepareForDragOperation(sender))
                    XCTAssertFalse(surface.performDragOperation(sender))
                    surface.draggingEnded(sender)
                }
            }
        }
        XCTAssertTrue(nonText.events.isEmpty, "Text must never reach a non-text control's drop handler.")
        XCTAssertTrue(opened.isEmpty)
    }

    @MainActor
    func testNativeEditableTextViewsAndRenameFieldEditorsKeepTextDropInsertion() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let rename = NSTextField(string: "Design name")
        rename.frame = NSRect(x: 20, y: 330, width: 250, height: 24)
        content.addSubview(rename)
        let notes = NSTextView(frame: NSRect(x: 20, y: 120, width: 250, height: 150))
        notes.isRichText = false
        notes.string = "Notes"
        content.addSubview(notes)
        let chat = NSTextView(frame: NSRect(x: 310, y: 120, width: 250, height: 150))
        chat.isRichText = false
        chat.string = "Prompt"
        content.addSubview(chat)
        let region = PromptFilePathDropView(frame: NSRect(x: 300, y: 100, width: 280, height: 190))
        region.readText = { chat.string }
        region.writeText = { chat.string = $0 }
        content.addSubview(region)
        defer { region.disconnect() }
        var opened: [URL] = []
        let anchor = ProjectFileDropAnchor(onDrop: { opened.append($0) })
        content.addSubview(anchor)
        defer { anchor.disconnect() }
        let surface = try XCTUnwrap(anchor.contentDropSurface)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([" dropped text " as NSString]))
        let sender = FileDropDraggingInfo(pasteboard: board)
        sender.draggingDestinationWindow = window
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(rename))
        let renameEditor = try XCTUnwrap(rename.currentEditor() as? NSTextView)

        for editor in [renameEditor, notes, chat] {
            sender.draggingSequenceNumber += 1
            sender.draggingLocation = editor.convert(NSPoint(x: 10, y: 10), to: nil)
            XCTAssertFalse(surface.draggingEntered(sender).isEmpty)
            XCTAssertFalse(surface.draggingUpdated(sender).isEmpty)
            XCTAssertTrue(surface.prepareForDragOperation(sender))
            XCTAssertTrue(surface.performDragOperation(sender))
            surface.draggingEnded(sender)
            XCTAssertTrue(editor.string.contains("dropped text"), "Native text insertion must remain available in rename, notes, and chat inputs.")
        }
        XCTAssertTrue(opened.isEmpty)

        sender.draggingSequenceNumber += 1
        sender.draggingLocation = notes.convert(NSPoint(x: 10, y: 10), to: nil)
        XCTAssertFalse(surface.draggingEntered(sender).isEmpty)
        // Prepare/perform can arrive without a final location-update callback.
        // Leaving an editor must not retain its earlier accepted destination.
        sender.draggingLocation = NSPoint(x: 450, y: 30)
        XCTAssertFalse(surface.prepareForDragOperation(sender))
        XCTAssertFalse(surface.performDragOperation(sender))
        surface.draggingEnded(sender)
    }

    @MainActor
    func testWindowDropSurfaceForwardsRawImageToComposerOnceWithoutOpeningADesign() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let region = PromptFilePathDropView(frame: NSRect(x: 280, y: 20, width: 300, height: 150))
        var text = "Keep this draft"
        var images: [PromptImagePayload] = []
        region.readText = { text }
        region.writeText = { text = $0 }
        region.onAttachImages = { images.append(contentsOf: $0) }
        content.addSubview(region)
        defer { region.disconnect() }
        var opened: [URL] = []
        let anchor = ProjectFileDropAnchor(onDrop: { opened.append($0) })
        content.addSubview(anchor)
        let surface = try XCTUnwrap(anchor.contentDropSurface)
        XCTAssertTrue(surface.registeredDraggedTypes.contains(.png))
        let data = try ImageAttachmentTestImage.png(.systemBlue, width: 4, height: 3)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setData(data, forType: .png))
        let sender = FileDropDraggingInfo(pasteboard: board)
        sender.draggingDestinationWindow = window
        sender.draggingLocation = NSPoint(x: 320, y: 70)
        XCTAssertEqual(surface.draggingEntered(sender), .copy)
        XCTAssertTrue(surface.prepareForDragOperation(sender))
        XCTAssertTrue(surface.performDragOperation(sender))
        XCTAssertFalse(surface.performDragOperation(sender), "A native drop callback must not duplicate the attached image.")
        surface.draggingEnded(sender)
        XCTAssertEqual(images.map(\.data), [data])
        XCTAssertEqual(text, "Keep this draft")
        XCTAssertTrue(opened.isEmpty)
    }

    func testAcceptsOneExistingProjectReferenceWithSpacesUnicodeAndUppercaseSuffix() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("PCB enclosure – מסך.LAD")
        // An empty directory is intentional: drag validation inspects metadata,
        // leaving package validation to opening rather than reading its files.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let pasteboard = makePasteboard([url])
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(ProjectFileDrop.fileURL(from: pasteboard), url)
    }

    func testRejectsRegularFilesMissingPackagesNonProjectsAndRemoteURLs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let regularFile = root.appendingPathComponent("Archive.lad")
        XCTAssertTrue(FileManager.default.createFile(atPath: regularFile.path, contents: nil))
        let other = root.appendingPathComponent("board.kicad_pcb")
        XCTAssertTrue(FileManager.default.createFile(atPath: other.path, contents: nil))
        for url in [regularFile, root.appendingPathComponent("Missing.lad"), other,
                    try XCTUnwrap(URL(string: "https://example.com/Design.lad"))] {
            let pasteboard = makePasteboard([url])
            XCTAssertNil(ProjectFileDrop.fileURL(from: pasteboard), url.absoluteString)
            pasteboard.releaseGlobally()
        }
    }

    func testRejectsMultipleOrMixedFilesInsteadOfOpeningTheFirst() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.lad")
        let second = root.appendingPathComponent("Second.lad")
        let other = root.appendingPathComponent("PCB.kicad_pcb")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: other.path, contents: nil))
        for urls in [[first, second], [first, other]] {
            let pasteboard = makePasteboard(urls)
            XCTAssertNil(ProjectFileDrop.fileURL(from: pasteboard))
            pasteboard.releaseGlobally()
        }
    }

    func testIgnoresPartHierarchyTextAndPlainTextFilePaths() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for text in ["part:case\npart:lid", "/tmp/Enclosure.lad", "file:///tmp/Enclosure.lad"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            XCTAssertNil(ProjectFileDrop.fileURL(from: pasteboard))
        }
    }

    @MainActor
    func testNativeDragSequenceUsesOnlyTheExternalSendersPasteboardAndOpensOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Design.lad")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let pasteboard = makePasteboard([url])
        defer { pasteboard.releaseGlobally() }
        XCTAssertNotEqual(pasteboard.name, NSPasteboard.Name.drag,
                          "Cross-process sessions need not use the standard drag pasteboard")
        let sender = FileDropDraggingInfo(pasteboard: pasteboard)
        var opened: [URL] = []
        let view = ProjectFileDropView(onDrop: { opened.append($0) })
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let point = NSPoint(x: 200, y: 150)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertNil(view.hitTest(point))
        XCTAssertEqual(view.draggingEntered(sender), .copy)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        XCTAssertTrue(view.prepareForDragOperation(sender))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertFalse(view.performDragOperation(sender))
        XCTAssertEqual(opened, [url])
        view.concludeDragOperation(sender)
        view.draggingEnded(sender)
        XCTAssertNil(view.hitTest(point), "A completed file drag must never block a later click or orbit")
        XCTAssertFalse(view.prepareForDragOperation(sender))
        XCTAssertFalse(view.performDragOperation(sender))
        XCTAssertNil(view.hitTest(NSPoint(x: 500, y: 150)))
    }

    @MainActor
    func testNativeDragRejectsMoveOnlySourcesAndCanceledOrInvalidSessions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Design.lad")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let pasteboard = makePasteboard([url])
        defer { pasteboard.releaseGlobally() }
        let sender = FileDropDraggingInfo(pasteboard: pasteboard)
        let view = ProjectFileDropView(onDrop: { _ in XCTFail("A rejected or canceled drag must not open a design") })
        sender.draggingSourceOperationMask = .move
        XCTAssertEqual(view.draggingEntered(sender), [])
        XCTAssertEqual(view.draggingUpdated(sender), [])
        XCTAssertFalse(view.prepareForDragOperation(sender))
        XCTAssertFalse(view.performDragOperation(sender))

        sender.draggingSourceOperationMask = .copy
        XCTAssertEqual(view.draggingEntered(sender), .copy)
        view.draggingExited(sender)
        XCTAssertFalse(view.performDragOperation(sender))
        pasteboard.clearContents()
        pasteboard.setString("part:case\npart:lid", forType: .string)
        XCTAssertEqual(view.draggingEntered(sender), [])
        XCTAssertEqual(view.draggingUpdated(sender), [])
        XCTAssertFalse(view.prepareForDragOperation(sender))
        XCTAssertFalse(view.performDragOperation(sender))
        XCTAssertNil(view.hitTest(.zero), "Rejected text drags must not intercept ordinary mouse input")
    }

    @MainActor
    func testWholeWindowInputPassesThroughAndOtherFileDragsReachTheirExistingDestination() throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = root.appendingPathComponent("PCB.kicad_pcb")
        let project = root.appendingPathComponent("Design.lad")
        XCTAssertTrue(FileManager.default.createFile(atPath: attachment.path, contents: nil))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let child = FileDropDestinationProbe(frame: content.bounds)
        child.registerForDraggedTypes([.fileURL])
        content.addSubview(child)
        var opened: [URL] = []
        let anchor = ProjectFileDropAnchor(onDrop: { opened.append($0) })
        content.addSubview(anchor)
        let surface = try XCTUnwrap(anchor.contentDropSurface)
        let frame = try XCTUnwrap(content.superview)
        let location = NSPoint(x: 200, y: 150)
        XCTAssertTrue(frame.hitTest(frame.convert(location, from: nil)) === child,
                      "The complete native window must still route ordinary mouse input to its controls")

        let pasteboard = makePasteboard([attachment])
        defer { pasteboard.releaseGlobally() }
        let sender = FileDropDraggingInfo(pasteboard: pasteboard)
        sender.draggingDestinationWindow = window
        sender.draggingLocation = location
        XCTAssertEqual(surface.draggingEntered(sender), .copy)
        XCTAssertEqual(surface.draggingUpdated(sender), .copy)
        XCTAssertTrue(surface.prepareForDragOperation(sender))
        XCTAssertTrue(surface.performDragOperation(sender))
        surface.concludeDragOperation(sender)
        surface.draggingEnded(sender)
        XCTAssertEqual(child.events, ["entered", "updated", "prepare", "perform", "conclude", "ended"])
        XCTAssertTrue(opened.isEmpty)

        child.events = []
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([project as NSURL]))
        sender.draggingSequenceNumber += 1
        XCTAssertEqual(surface.draggingEntered(sender), .copy)
        XCTAssertEqual(surface.draggingUpdated(sender), .copy)
        XCTAssertTrue(surface.prepareForDragOperation(sender))
        XCTAssertTrue(surface.performDragOperation(sender))
        XCTAssertEqual(opened, [project])
        XCTAssertTrue(child.events.isEmpty, "LAD designs take precedence over child file-drop handlers")
        surface.draggingEnded(sender)
        XCTAssertTrue(frame.hitTest(frame.convert(location, from: nil)) === child)
    }

    func testPromptFileReferencesIncludeMultipleBinaryProjectAndDirectoryPathsWithoutContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Enclosure with spaces.LAD")
        let binary = root.appendingPathComponent("部品.bin")
        let directory = root.appendingPathComponent("CAD assets", isDirectory: true)
        let secret = "FILE-CONTENTS-MUST-NEVER-BECOME-THE-PROMPT"
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data(secret.utf8).write(to: project.appendingPathComponent("project.json"))
        try Data([0xff, 0x00, 0xfe]).write(to: binary)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let urls = [project, binary, directory]
        let pasteboard = makePasteboard(urls)
        defer { pasteboard.releaseGlobally() }
        let references = try XCTUnwrap(PromptFilePaths.urls(from: pasteboard))
        XCTAssertEqual(references.map(\.path), urls.map(\.path))
        let insertion = PromptFilePaths.insertion(for: references, in: "", replacing: NSRange(location: 0, length: 0))
        XCTAssertEqual(insertion.text, urls.map(\.path).joined(separator: "\n"))
        XCTAssertFalse(insertion.text.contains(secret))
        XCTAssertFalse(insertion.text.contains("file://"))

        pasteboard.clearContents()
        pasteboard.setString("ordinary dragged text", forType: .string)
        XCTAssertNil(PromptFilePaths.urls(from: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("promised.lad", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        XCTAssertNil(PromptFilePaths.urls(from: pasteboard), "File promises must never be opened to extract contents")
    }

    func testPromptPathInsertionPreservesUnicodeTextSelectionAndSeparatesReferences() {
        let text = "Use 🔩 this part"
        let url = URL(fileURLWithPath: "/tmp/Case with spaces.lad")
        let selection = (text as NSString).range(of: "this")
        let insertion = PromptFilePaths.insertion(for: [url], in: text, replacing: selection)
        XCTAssertEqual((text as NSString).replacingCharacters(in: insertion.range, with: insertion.text),
                       "Use 🔩 /tmp/Case with spaces.lad part")
        let caret = NSRange(location: ("Use 🔩" as NSString).length, length: 0)
        let atCaret = PromptFilePaths.insertion(for: [url], in: text, replacing: caret)
        XCTAssertEqual((text as NSString).replacingCharacters(in: atCaret.range, with: atCaret.text),
                       "Use 🔩 /tmp/Case with spaces.lad this part")
    }

    @MainActor
    func testComposerFileDropsReplaceNativeSelectionAndNeverOpenProjectsAcrossTheWholeInputBox() throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Design.lad")
        let binary = root.appendingPathComponent("board.bin")
        let directory = root.appendingPathComponent("Parts", isDirectory: true)
        let secret = "NOT-INLINE-SOURCE-CONTENTS"
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data(secret.utf8).write(to: project.appendingPathComponent("project.json"))
        try Data([0xff, 0x00]).write(to: binary)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let editor = NSTextView(frame: NSRect(x: 300, y: 70, width: 280, height: 90))
        editor.string = "Keep this draft"
        editor.setSelectedRange((editor.string as NSString).range(of: "this"))
        content.addSubview(editor)
        let region = PromptFilePathDropView(frame: NSRect(x: 290, y: 20, width: 300, height: 150))
        var boundText = editor.string
        var focusCount = 0
        region.readText = { boundText }
        region.writeText = { boundText = $0 }
        region.onFocus = { focusCount += 1 }
        content.addSubview(region)
        defer { region.disconnect() }
        var opened: [URL] = []
        let anchor = ProjectFileDropAnchor(onDrop: { opened.append($0) })
        content.addSubview(anchor)
        let surface = try XCTUnwrap(anchor.contentDropSurface)
        let pasteboard = makePasteboard([project])
        defer { pasteboard.releaseGlobally() }
        let sender = FileDropDraggingInfo(pasteboard: pasteboard)
        sender.draggingDestinationWindow = window
        // This is below the native editor, where the composer controls live.
        sender.draggingLocation = NSPoint(x: 310, y: 35)
        XCTAssertEqual(surface.draggingEntered(sender), .copy)
        XCTAssertEqual(surface.draggingUpdated(sender), .copy)
        XCTAssertTrue(surface.prepareForDragOperation(sender))
        XCTAssertTrue(surface.performDragOperation(sender))
        surface.draggingEnded(sender)
        XCTAssertEqual(editor.string, "Keep \(project.path) draft")
        XCTAssertEqual(boundText, editor.string)
        XCTAssertFalse(boundText.contains(secret))
        XCTAssertTrue(opened.isEmpty, "A .lad dropped anywhere in the composer must not replace the design")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(focusCount, 1)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([binary as NSURL, directory as NSURL]))
        sender.draggingSequenceNumber += 1
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        sender.draggingLocation = NSPoint(x: 350, y: 100)
        XCTAssertEqual(surface.draggingEntered(sender), .copy)
        XCTAssertTrue(surface.performDragOperation(sender))
        surface.draggingEnded(sender)
        XCTAssertEqual(boundText, "Keep \(project.path) draft \(binary.path)\n\(directory.path)")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(focusCount, 2)

        // Outside the input box, an ordinary .lad drop still opens a design.
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([project as NSURL]))
        sender.draggingSequenceNumber += 1
        sender.draggingLocation = NSPoint(x: 100, y: 300)
        XCTAssertEqual(surface.draggingEntered(sender), .copy)
        XCTAssertTrue(surface.performDragOperation(sender))
        surface.draggingEnded(sender)
        XCTAssertEqual(opened, [project])
        XCTAssertEqual(focusCount, 2)
    }

    @MainActor
    func testComposerFallbackAppendsReferencesAndLeavesNonFileTextAlone() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let region = PromptFilePathDropView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        var prompt = "Use the supplied files:"
        region.readText = { prompt }
        region.writeText = { prompt = $0 }
        try XCTUnwrap(window.contentView).addSubview(region)
        defer { region.disconnect() }
        let missingReference = URL(fileURLWithPath: "/tmp/Does not need to be read.bin")
        let pasteboard = makePasteboard([missingReference])
        defer { pasteboard.releaseGlobally() }
        let sender = FileDropDraggingInfo(pasteboard: pasteboard)
        sender.draggingDestinationWindow = window
        XCTAssertEqual(region.draggingEntered(sender), .copy)
        XCTAssertTrue(region.performDragOperation(sender))
        region.draggingEnded(sender)
        XCTAssertEqual(prompt, "Use the supplied files: \(missingReference.path)")
        XCTAssertFalse(window.isVisible, "A programmatic regression fixture must stay hidden")

        let previous = prompt
        pasteboard.clearContents()
        pasteboard.setString("A normal text drag", forType: .string)
        sender.draggingSequenceNumber += 1
        XCTAssertEqual(region.draggingEntered(sender), [])
        XCTAssertFalse(region.performDragOperation(sender))
        XCTAssertEqual(prompt, previous)
        XCTAssertNil(region.hitTest(.zero))
    }

    @MainActor
    func testWindowAnchorCoversTitleBarAndCleansUpWhenMovedOrClosed() throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let anchor = ProjectFileDropAnchor(onDrop: { _ in })
        let firstContent = try XCTUnwrap(first.contentView)
        firstContent.addSubview(anchor)
        let firstFrame = try XCTUnwrap(firstContent.superview)
        let initialSurface = try XCTUnwrap(anchor.dropSurface)
        let initialContentSurface = try XCTUnwrap(anchor.contentDropSurface)
        XCTAssertTrue(initialSurface.superview === firstFrame)
        XCTAssertEqual(initialSurface.frame, firstFrame.bounds)
        XCTAssertTrue(firstFrame.subviews.last === initialSurface)
        XCTAssertTrue(initialSurface.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(initialContentSurface.superview === firstContent)
        XCTAssertEqual(initialContentSurface.frame, firstContent.bounds)
        XCTAssertTrue(firstContent.subviews.last === initialContentSurface)
        XCTAssertTrue(initialContentSurface.registeredDraggedTypes.contains(.fileURL))
        XCTAssertNil(initialContentSurface.hitTest(.zero))
        XCTAssertNil(anchor.hitTest(.zero))

        var received: URL?
        anchor.configure(onDrop: { received = $0 })
        let reference = URL(fileURLWithPath: "/tmp/Callback.lad")
        initialSurface.onDrop?(reference)
        XCTAssertEqual(received, reference)
        received = nil
        initialContentSurface.onDrop?(reference)
        XCTAssertEqual(received, reference)
        XCTAssertTrue(anchor.dropSurface === initialSurface, "Updates should reuse the window surface")
        XCTAssertTrue(anchor.contentDropSurface === initialContentSurface, "Updates should reuse the content surface")

        let secondContent = try XCTUnwrap(second.contentView)
        anchor.removeFromSuperview()
        XCTAssertNil(initialSurface.superview)
        XCTAssertNil(initialSurface.onDrop)
        XCTAssertTrue(initialSurface.registeredDraggedTypes.isEmpty)
        XCTAssertNil(initialContentSurface.superview)
        XCTAssertNil(initialContentSurface.onDrop)
        XCTAssertTrue(initialContentSurface.registeredDraggedTypes.isEmpty)
        secondContent.addSubview(anchor)
        let movedSurface = try XCTUnwrap(anchor.dropSurface)
        let movedContentSurface = try XCTUnwrap(anchor.contentDropSurface)
        XCTAssertFalse(movedSurface === initialSurface)
        XCTAssertFalse(movedContentSurface === initialContentSurface)
        XCTAssertTrue(movedSurface.superview === secondContent.superview)
        XCTAssertTrue(movedContentSurface.superview === secondContent)
        second.setContentSize(NSSize(width: 700, height: 500))
        XCTAssertEqual(movedSurface.frame, try XCTUnwrap(secondContent.superview).bounds)
        XCTAssertEqual(movedContentSurface.frame, secondContent.bounds)

        second.close()
        XCTAssertNil(anchor.dropSurface)
        XCTAssertNil(anchor.contentDropSurface)
        XCTAssertNil(movedSurface.superview)
        XCTAssertNil(movedSurface.onDrop)
        XCTAssertTrue(movedSurface.registeredDraggedTypes.isEmpty)
        XCTAssertNil(movedContentSurface.superview)
        XCTAssertNil(movedContentSurface.onDrop)
        XCTAssertTrue(movedContentSurface.registeredDraggedTypes.isEmpty)
        anchor.configure(onDrop: { _ in XCTFail("A closed window must not reinstall its drop surface") })
        XCTAssertNil(anchor.dropSurface)
        XCTAssertNil(anchor.contentDropSurface)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-file-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePasteboard(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard
    }
}

@MainActor
private final class FileDropDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any? = nil
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        for (index, object) in objects.enumerated() {
            guard let writer = object as? any NSPasteboardWriting else { continue }
            var stop: ObjCBool = false
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
}

@MainActor
private final class FileDropDestinationProbe: NSView {
    var events: [String] = []
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { events.append("entered"); return .copy }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { events.append("updated"); return .copy }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { events.append("prepare"); return true }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { events.append("perform"); return true }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { events.append("conclude") }
    override func draggingEnded(_ sender: any NSDraggingInfo) { events.append("ended") }
}
