import AppKit
import XCTest
@testable import LAD

final class PromptTextEditorKeyboardTests: XCTestCase {
    @MainActor
    func testReturnSubmitsOnceWithoutInsertingOrReplacingText() throws {
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Keep this draft"
        let selection = (fixture.editor.string as NSString).range(of: "this")
        fixture.editor.setSelectedRange(selection)
        var submissions = 0, dispatches = 0
        fixture.editor.onSubmit = { submissions += 1 }
        fixture.editor.onDispatchNextQueuedRequest = { dispatches += 1 }

        fixture.editor.keyDown(with: try key(in: fixture.window))

        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(fixture.editor.string, "Keep this draft")
        XCTAssertEqual(fixture.editor.selectedRange(), selection)
    }

    @MainActor
    func testOptionReturnInsertsNewlineAtCaretAndSupportsNativeUndo() throws {
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Keep 🔩 the draft"
        let caret = (fixture.editor.string as NSString).range(of: "the").location
        fixture.editor.setSelectedRange(NSRange(location: caret, length: 0))
        let undo = try XCTUnwrap(fixture.editor.undoManager)
        undo.removeAllActions()
        var submissions = 0, dispatches = 0
        fixture.editor.onSubmit = { submissions += 1 }
        fixture.editor.onDispatchNextQueuedRequest = { dispatches += 1 }

        fixture.editor.keyDown(with: try key(modifiers: .option, in: fixture.window))

        XCTAssertEqual(fixture.editor.string, "Keep 🔩 \nthe draft")
        XCTAssertEqual(fixture.editor.selectedRange(), NSRange(location: caret + 1, length: 0))
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(dispatches, 0)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(fixture.editor.string, "Keep 🔩 the draft")
    }

    @MainActor
    func testCommandReturnKeyEquivalentDispatchesOnceAndPreservesDraftSelection() throws {
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Unsent 🔩 draft"
        let selection = (fixture.editor.string as NSString).range(of: "🔩")
        fixture.editor.setSelectedRange(selection)
        var submissions = 0, dispatches = 0
        fixture.editor.onSubmit = { submissions += 1 }
        fixture.editor.onDispatchNextQueuedRequest = { dispatches += 1 }
        let event = try key(modifiers: .command, in: fixture.window)

        // AppKit offers command events as key equivalents before keyDown.
        // A handled event must stop there instead of also submitting the draft.
        let handled = fixture.editor.performKeyEquivalent(with: event)
        if !handled { fixture.editor.keyDown(with: event) }

        XCTAssertTrue(handled)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(fixture.editor.string, "Unsent 🔩 draft")
        XCTAssertEqual(fixture.editor.selectedRange(), selection)
    }

    @MainActor
    func testCommandReturnKeyDownUsesQueueDispatchInsteadOfSubmission() throws {
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Unsent request"
        var submissions = 0, dispatches = 0
        fixture.editor.onSubmit = { submissions += 1 }
        fixture.editor.onDispatchNextQueuedRequest = { dispatches += 1 }

        fixture.editor.keyDown(with: try key(modifiers: .command, in: fixture.window))

        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(fixture.editor.string, "Unsent request")
    }

    @MainActor
    func testUnavailableQueueDispatchConsumesCommandReturnWithoutEditingTheDraft() throws {
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Keep unsent request"
        let selection = NSRange(location: 4, length: 0)
        fixture.editor.setSelectedRange(selection)
        var submissions = 0
        fixture.editor.onSubmit = { submissions += 1 }

        XCTAssertTrue(fixture.editor.performKeyEquivalent(with: try key(modifiers: .command, in: fixture.window)))

        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(fixture.editor.string, "Keep unsent request")
        XCTAssertEqual(fixture.editor.selectedRange(), selection)
    }

    @MainActor
    func testKeypadEnterSubmitsInsteadOfInsertingNewline() throws {
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.string = "Send from keypad"
        var submissions = 0
        fixture.editor.onSubmit = { submissions += 1 }

        fixture.editor.keyDown(with: try key(modifiers: .numericPad, keypad: true, in: fixture.window))

        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(fixture.editor.string, "Send from keypad")
    }

    @MainActor
    func testReturnWithMarkedTextDoesNotSubmitTheComposition() throws {
        let fixture = NativeEditorFixture()
        defer { fixture.close() }
        fixture.editor.setMarkedText("設計", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(fixture.editor.hasMarkedText())
        var submissions = 0, dispatches = 0
        fixture.editor.onSubmit = { submissions += 1 }
        fixture.editor.onDispatchNextQueuedRequest = { dispatches += 1 }

        fixture.editor.keyDown(with: try key(in: fixture.window))

        XCTAssertEqual(submissions, 0, "Return must remain available to confirm native input-method composition.")
        XCTAssertEqual(dispatches, 0)
    }

    @MainActor
    private func key(modifiers: NSEvent.ModifierFlags = [], keypad: Bool = false, in window: NSWindow) throws -> NSEvent {
        let characters = keypad ? "\u{3}" : "\r"
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keypad ? 76 : 36))
    }

    @MainActor
    private final class NativeEditorFixture {
        let window: NSWindow
        let editor: PromptTextView

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            editor = PromptTextView(frame: NSRect(x: 15, y: 65, width: 360, height: 90))
            editor.isRichText = false
            editor.importsGraphics = false
            editor.allowsUndo = true
            editor.font = .systemFont(ofSize: 12)
            window.contentView?.addSubview(editor)
            window.makeFirstResponder(editor)
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}
