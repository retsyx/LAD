import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class ConversationSearchTests: XCTestCase {
    func testMatchesIgnoreCaseAndDiacriticsInConversationOrder() {
        let first = ChatMessage(role: "user", content: "Add a Bracket, then a second bracket.")
        let second = ChatMessage(role: "assistant", content: "No matching text here.")
        let third = ChatMessage(role: "assistant", content: "The brácket now has two holes.")
        let matches = ConversationSearch.matches(in: [first, second, third], for: "bracket")
        XCTAssertEqual(matches.map(\.messageID), [first.id, first.id, third.id])
        XCTAssertEqual(matches.map { String(messageContent(matches, $0, [first, third])) }, ["Bracket", "bracket", "brácket"])
    }

    func testRepeatedTextYieldsNonOverlappingMatches() {
        let message = ChatMessage(role: "assistant", content: "aaaa")
        XCTAssertEqual(ConversationSearch.matches(in: [message], for: "aa").count, 2)
    }

    func testBlankQueriesDoNotSearch() {
        let message = ChatMessage(role: "assistant", content: "Two words")
        for query in ["", " ", "\n\t"] {
            XCTAssertFalse(ConversationSearch.isActive(query))
            XCTAssertTrue(ConversationSearch.matches(in: [message], for: query).isEmpty)
        }
        XCTAssertEqual(ConversationSearch.matches(in: [message], for: " w").count, 1,
                       "Surrounding spaces remain part of a nonblank query.")
    }

    func testSteppingWrapsAtBothEnds() {
        XCTAssertEqual(ConversationSearch.step(from: 0, count: 3, forward: true), 1)
        XCTAssertEqual(ConversationSearch.step(from: 2, count: 3, forward: true), 0)
        XCTAssertEqual(ConversationSearch.step(from: 0, count: 3, forward: false), 2)
        XCTAssertEqual(ConversationSearch.step(from: -1, count: 3, forward: true), 0)
        XCTAssertEqual(ConversationSearch.step(from: 0, count: 0, forward: true), 0)
    }

    func testVerticalFractionFollowsWrappedLinesRatherThanCharacterOffsets() {
        // A long wrapped paragraph followed by many short lines puts the
        // first short line well past half the characters but near the
        // middle of the text's height.
        let paragraph = String(repeating: "wrapped prose ", count: 120)
        let lines = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let content = paragraph + "\nmarker\n" + lines + "\nfinal"
        let font = NSFont.systemFont(ofSize: 12)
        func fraction(_ text: String) -> CGFloat {
            let range = content.range(of: text)!
            return ConversationSearch.verticalFraction(of: range, in: content, width: 300, font: font, lineSpacing: 5)
        }
        let start = fraction("wrapped"), marker = fraction("marker"), end = fraction("final")
        XCTAssertLessThan(start, 0.05)
        XCTAssertGreaterThan(end, 0.95)
        let characterFraction = CGFloat(content.distance(from: content.startIndex, to: content.range(of: "marker")!.lowerBound)) /
            CGFloat(content.count)
        XCTAssertLessThan(marker, characterFraction - 0.15, "Short lines occupy more height than their characters suggest.")
        XCTAssertGreaterThan(marker, start)
        XCTAssertLessThan(marker, end)
        XCTAssertEqual(ConversationSearch.verticalFraction(of: content.range(of: "final")!, in: content, width: 0,
                                                           font: font, lineSpacing: 5), 0)
    }

    @MainActor
    func testSearchFieldRevealsAndStepsThroughMatchesWithoutFollowingNewMessages() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let scroll = try await conversationScroll(in: fixture.host)
        let field = try await searchField(in: fixture.host)
        try await scrollToBottom(scroll, host: fixture.host)
        let bottom = distanceFromTop(scroll)
        XCTAssertGreaterThan(bottom, 1_000, "The fixture conversation must be taller than its pane.")

        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("bracket", replacementRange: editor.selectedRange())
        try await waitForScroll(scroll, host: fixture.host, description: "the first match near the top") { $0 < 300 }
        try capture(fixture.host, to: "/tmp/lad-conversation-search.png")

        // Shift-Return wraps back to the last match, at the end of a long
        // final message.
        try press(.return, shift: true, in: fixture.window)
        try await waitForScroll(scroll, host: fixture.host, description: "the final match") { $0 > bottom - 200 }
        let final = try XCTUnwrap(scroll.documentView)
        let visible = scroll.documentVisibleRect
        XCTAssertLessThan(final.isFlipped ? final.bounds.maxY - visible.maxY : visible.minY - final.bounds.minY, 200,
                          "Revealing a match at the end of a tall message must show the message's last lines.")

        // Return wraps forward to the first match, then reaches the middle one.
        try press(.return, in: fixture.window)
        try await waitForScroll(scroll, host: fixture.host, description: "the wrapped first match") { $0 < 300 }
        try press(.return, in: fixture.window)
        try await waitForScroll(scroll, host: fixture.host, description: "the middle match") { $0 > 300 && $0 < bottom - 1_000 }
        try press(.return, shift: true, in: fixture.window)
        try await waitForScroll(scroll, host: fixture.host, description: "the previous first match") { $0 < 300 }
        XCTAssertTrue(fixture.window.firstResponder === field.currentEditor(), "Stepping must keep the search field focused.")

        // A found match stays in place while the conversation continues.
        fixture.state.messages.append(ChatMessage(role: "assistant", content: "A new update arrives."))
        await settle(fixture.host, for: .milliseconds(600))
        XCTAssertLessThan(distanceFromTop(scroll), 300)

        try press(.escape, in: fixture.window)
        let clearDeadline = ContinuousClock.now + .seconds(3)
        while field.stringValue != "", ContinuousClock.now < clearDeadline { await settle(fixture.host) }
        XCTAssertEqual(field.stringValue, "", "Escape clears the search.")
        XCTAssertLessThan(distanceFromTop(scroll), 300, "Clearing the search keeps the reader's place.")
        fixture.state.messages.append(ChatMessage(role: "assistant", content: "Another update arrives."))
        try await waitForScroll(scroll, host: fixture.host, description: "the latest message") { $0 > bottom - 50 }
        XCTAssertEqual(fixture.state.prompt, fixture.draft, "Searching must not change the composer draft.")
    }

    private func messageContent(_ matches: [ConversationSearchMatch], _ match: ConversationSearchMatch,
                                _ messages: [ChatMessage]) -> Substring {
        messages.first { $0.id == match.messageID }!.content[match.range]
    }

    private enum Key {
        case `return`, escape
    }

    /// Dequeues a real key event so it is the application's current event,
    /// as during an ordinary key press, and sends it to the focused field.
    @MainActor
    private func press(_ key: Key, shift: Bool = false, in window: NSWindow) throws {
        let (characters, code): (String, UInt16) = key == .return ? ("\r", 36) : ("\u{1b}", 53)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true))
        XCTAssertEqual(dequeued.keyCode, code)
        window.sendEvent(dequeued)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func settle(_ host: NSView, for duration: Duration = .milliseconds(30)) async {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        try? await Task.sleep(for: duration)
    }

    @MainActor
    private func searchField(in host: NSView) async throws -> NSTextField {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let field = descendants(host).compactMap({ $0 as? NSTextField })
                .first(where: { $0.placeholderString == "Search conversation" }) { return field }
            await settle(host)
        }
        throw XCTSkip("The conversation search field is not exposed as a native text field.")
    }

    /// The conversation is the tall scroll area in the right-hand column.
    @MainActor
    private func conversationScroll(in host: NSView) async throws -> NSScrollView {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
                let frame = host.convert($0.bounds, from: $0)
                return !$0.isHiddenOrHasHiddenAncestor && frame.minX > host.bounds.width - 560 && frame.height > 250 &&
                    ($0.documentView?.bounds.height ?? 0) > frame.height
            }) { return scroll }
            await settle(host)
        }
        XCTFail("The conversation has no scroll area.")
        throw XCTSkip("No conversation scroll area.")
    }

    @MainActor
    private func distanceFromTop(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        let visible = scroll.documentVisibleRect
        return document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
    }

    @MainActor
    private func scrollToBottom(_ scroll: NSScrollView, host: NSView) async throws {
        let document = try XCTUnwrap(scroll.documentView)
        let y = document.isFlipped ? document.bounds.maxY - scroll.contentSize.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(host)
    }

    @MainActor
    private func waitForScroll(_ scroll: NSScrollView, host: NSView, description: String,
                               _ condition: (CGFloat) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(distanceFromTop(scroll)), ContinuousClock.now < deadline { await settle(host) }
        XCTAssertTrue(condition(distanceFromTop(scroll)),
                      "Expected the conversation to show \(description); offset \(distanceFromTop(scroll)).")
    }

    @MainActor
    private func capture(_ host: NSView, to path: String) throws {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private struct Fixture {
        let state: AppState
        let host: NSHostingView<WorkspaceView>
        let window: NSWindow
        let directory: URL
        let oldCodex: Any?
        let previousPolicy: NSApplication.ActivationPolicy
        let draft = "An unsent draft stays put."

        init() throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for the conversation UI.") }
            let application = NSApplication.shared
            previousPolicy = application.activationPolicy()
            _ = application.setActivationPolicy(.regular)
            application.finishLaunching()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LAD-conversation-search-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
            let filler = String(repeating: "The enclosure keeps its wall thickness and fillet radius. ", count: 6)
            var messages = [ChatMessage(role: "user", content: "Design a mounting bracket with two holes.")]
            // Three matches: first, middle and last, so previous and next
            // differ from every match.
            for index in 1...14 {
                let note = index == 7 ? "The bracket holes stay aligned. " : ""
                messages.append(ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant",
                                            content: "Step \(index). \(note)\(filler)"))
            }
            let tail = (1...60).map { "Detail \($0): \(filler)" }.joined(separator: "\n")
            messages.append(ChatMessage(role: "assistant", content: tail + "\nThe bracket is complete.", phase: "final_answer"))
            var project = LADProject(messages: messages, revisions: [], selectedRevisionID: nil,
                                     projectID: UUID(), projectName: "Conversation search check")
            project.draftPrompt = draft
            let source = directory.appendingPathComponent("Conversation search check.lad")
            try ProjectStore.write(project, to: source)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.loadProject(project, from: source)
            host = NSHostingView(rootView: WorkspaceView(state: state))
            host.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            host.appearance = NSAppearance(named: .darkAqua)
            window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "LAD conversation search check"
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
