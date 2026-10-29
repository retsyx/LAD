import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class ProjectResponseViewTests: XCTestCase {
    @MainActor
    func testAssistantQuestionUsesAndFocusesTheExistingComposerWithoutLosingItsDraft() async throws {
        let fixture = try Fixture(queued: true)
        defer { fixture.close() }
        let editor = try await composer(in: fixture.host, showing: fixture.draft)
        let question = "What lettering style would you like: rounded, handwritten, or angular?"
        fixture.state.messages.append(ChatMessage(role: "assistant", content: question, phase: "response"))
        await Task.yield()
        let replyEditor = try await composer(in: fixture.host, showing: fixture.draft)
        XCTAssertTrue(replyEditor === editor,
            "A Codex question must reuse the bottom composer rather than adding a response text box.")
        XCTAssertEqual(fixture.state.prompt, fixture.draft)
        XCTAssertNil(fixture.state.error, "An assistant question must remain normal conversation.")
        if fixture.window.isKeyWindow {
            let focusDeadline = ContinuousClock.now + .seconds(3)
            while fixture.window.firstResponder !== editor, ContinuousClock.now < focusDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(fixture.window.firstResponder === editor,
                "A conversational response should focus the existing reply editor.")
        }
        XCTAssertEqual(fixture.state.queuedRequests.count, 1)
        XCTAssertTrue(fixture.state.queuePaused)

        fixture.state.prompt = ""
        let clearedEditor = try await composer(in: fixture.host, showing: "")
        XCTAssertTrue(clearedEditor === editor)
        try capture(fixture.host, to: "/tmp/lad-conversation-reply-ui.png")
        editor.insertText("Rounded lettering, please.", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(fixture.state.prompt, "Rounded lettering, please.",
            "Typing a reply must update the ordinary composer binding.")

    }

    @MainActor
    func testActualErrorsKeepTheExistingComposerEditable() async throws {
        let fixture = try Fixture(queued: false)
        defer { fixture.close() }
        fixture.state.error = "The CAD runtime could not be started."
        await Task.yield()
        let editor = try await composer(in: fixture.host, showing: fixture.draft)
        XCTAssertTrue(editor.isEditable)
        try capture(fixture.host, to: "/tmp/lad-conversation-error-ui.png")
        editor.setSelectedRange(NSRange(location: (fixture.draft as NSString).length, length: 0))
        editor.insertText(" I can retry with a simpler request.", replacementRange: editor.selectedRange())
        XCTAssertEqual(fixture.state.prompt, fixture.draft + " I can retry with a simpler request.")

    }

    @MainActor
    private func capture(_ host: NSView, to path: String) throws {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private func composer(in host: NSView, showing text: String) async throws -> NSTextView {
        func editors(in view: NSView) -> [NSTextView] {
            let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
            return own + view.subviews.flatMap { editors(in: $0) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            let candidates = editors(in: host)
            if candidates.count == 1, candidates[0].string == text { return candidates[0] }
            try await Task.sleep(for: .milliseconds(10))
        }
        let candidates = editors(in: host)
        XCTAssertEqual(candidates.count, 1, "Conversation and error states must retain exactly one bottom composer.")
        let result = try XCTUnwrap(candidates.first)
        XCTAssertEqual(result.string, text)
        return result
    }

    @MainActor
    private struct Fixture {
        let state: AppState
        let host: NSHostingView<WorkspaceView>
        let window: NSWindow
        let directory: URL
        let oldCodex: Any?
        let previousPolicy: NSApplication.ActivationPolicy
        let draft = "Keep this unsent draft while Codex asks a question."

        init(queued: Bool) throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for the conversation UI.") }
            let application = NSApplication.shared
            previousPolicy = application.activationPolicy()
            _ = application.setActivationPolicy(.regular)
            application.finishLaunching()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-response-ui-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
            var project = LADProject(messages: [ChatMessage(role: "user", content: "Can you change the lettering?")],
                revisions: [], selectedRevisionID: nil, projectID: UUID(), projectName: "Reply composer check")
            project.draftPrompt = draft
            if queued {
                project.queuedRequests = [ProjectQueuedRequest(content: "Add mounting holes afterward.")]
                project.queuePaused = true
            }
            let source = directory.appendingPathComponent("Reply composer check.lad")
            try ProjectStore.write(project, to: source)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.loadProject(project, from: source)
            host = NSHostingView(rootView: WorkspaceView(state: state))
            host.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            host.appearance = NSAppearance(named: .darkAqua)
            window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "LAD response composer integration check"
            window.isReleasedWhenClosed = false
            window.contentView = host
            application.unhide(nil)
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeKey()
            window.displayIfNeeded()
        }

        func close() {
            state.cancel()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            _ = NSApplication.shared.setActivationPolicy(previousPolicy)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
