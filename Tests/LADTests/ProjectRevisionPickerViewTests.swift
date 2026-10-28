import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class ProjectRevisionPickerViewTests: XCTestCase {
    @MainActor
    func testClickingAVersionRowSelectsOnlyTheRequestedRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let third = fixture.state.revisions[2].id
        try fixture.state.renameRevision(id: third, to: "Rounded edges")
        var selections: [UUID] = []
        let window = makeWindow(state: fixture.state, onSelect: {
            selections.append($0)
            // This fixture has no native geometry. Observe the picker action
            // without launching the CAD worker used by real history navigation.
            fixture.state.selectedRevisionID = $0
        })
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        let rows = try await rowFrames(in: host)
        try snapshot(host, to: "/tmp/lad-version-picker-rows.png")
        let first = fixture.state.revisions[0].id
        try click(rows[0].name, in: host)
        try await wait(in: host) { fixture.state.selectedRevisionID == first }
        XCTAssertEqual(selections, [first], "Only the name button should navigate to this version.")
        XCTAssertFalse(fixture.state.isWorking)
    }

    @MainActor
    func testReturnRenamesInactiveAndActiveRowsWithoutNavigating() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.state.revisions[0].id
        let active = try XCTUnwrap(fixture.state.selectedRevisionID)
        let activeProgram = fixture.state.current?.script
        var selections: [UUID] = []
        var dismissals = 0
        let window = makeWindow(state: fixture.state, onSelect: { selections.append($0) }, onDismiss: { dismissals += 1 })
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        try click(try await rowFrames(in: host)[0].rename, in: host)
        let field = try await nameField(in: host)
        try replaceName(in: field, with: "Initial shell", window: window)
        try snapshot(host, to: "/tmp/lad-version-picker-edit.png")
        try key(.returnKey, in: window)
        _ = try await rowFrames(in: host)
        try await wait(in: host) { fixture.state.revisionName(for: first) == "Initial shell" }
        XCTAssertEqual(fixture.state.selectedRevisionID, active,
                       "Naming an inactive version must leave the displayed geometry selected.")
        XCTAssertEqual(fixture.state.current?.script, activeProgram)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertEqual(dismissals, 0, "An inline rename should leave the version list open.")
        try snapshot(host, to: "/tmp/lad-version-picker-named.png")

        try await rename(row: 1, to: "Ready to print", in: window)
        try await wait(in: host) { fixture.state.revisionName(for: active) == "Ready to print" }
        try snapshot(host, to: "/tmp/lad-version-picker-active.png")
        XCTAssertEqual(fixture.state.selectedRevisionID, active)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertFalse(fixture.state.isWorking, "Changing a version name must not prepare or rebuild geometry.")
    }

    @MainActor
    func testEscapeDiscardsAnInlineNameAndDoesNotNavigate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.state.revisions[0].id
        try fixture.state.renameRevision(id: first, to: "Initial design")
        let selected = fixture.state.selectedRevisionID
        var selections: [UUID] = []
        var dismissals = 0
        let window = makeWindow(state: fixture.state, onSelect: { selections.append($0) }, onDismiss: { dismissals += 1 })
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        try click(try await rowFrames(in: host)[0].rename, in: host)
        let field = try await nameField(in: host)
        try replaceName(in: field, with: "Discard this name", window: window)
        try key(.escape, in: window)
        _ = try await rowFrames(in: host)
        XCTAssertEqual(fixture.state.revisionName(for: first), "Initial design")
        XCTAssertEqual(fixture.state.selectedRevisionID, selected)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertEqual(dismissals, 0, "Escape inside the name field cancels only its inline edit.")

        try click(try await rowFrames(in: host)[0].rename, in: host)
        let reopened = try await nameField(in: host)
        XCTAssertEqual(reopened.stringValue, "Initial design", "A canceled draft must not survive the next edit.")
        try key(.escape, in: window)
        _ = try await rowFrames(in: host)
    }

    @MainActor
    func testVersionNamingRemainsAvailableWhileHistoryNavigationIsBlocked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.state.isWorking = true
        let first = fixture.state.revisions[0].id
        let selected = fixture.state.selectedRevisionID
        var selections: [UUID] = []
        let window = makeWindow(state: fixture.state, onSelect: { selections.append($0) })
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let rows = try await rowFrames(in: host)
        try click(rows[0].name, in: host)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(selections.isEmpty, "History navigation must stay blocked during the request.")

        try await rename(row: 0, to: "Named during a request", in: window)
        try await wait(in: host) { fixture.state.revisionName(for: first) == "Named during a request" }
        XCTAssertEqual(fixture.state.selectedRevisionID, selected)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(fixture.state.isWorking, "Metadata editing must leave the existing task alone.")
    }

    @MainActor
    private func rename(row: Int, to name: String, in window: NSWindow) async throws {
        let host = try XCTUnwrap(window.contentView)
        try click(try await rowFrames(in: host)[row].rename, in: host)
        let field = try await nameField(in: host)
        try replaceName(in: field, with: name, window: window)
        try key(.returnKey, in: window)
        _ = try await rowFrames(in: host)
    }

    @MainActor
    private func replaceName(in field: NSTextField, with name: String, window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(name, replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, name)
    }

    private enum Key: Equatable {
        case returnKey, escape
        var characters: String { self == .returnKey ? "\r" : "\u{1b}" }
        var code: UInt16 { self == .returnKey ? 36 : 53 }
    }

    @MainActor
    private func key(_ key: Key, in window: NSWindow) throws {
        window.makeKey()
        if key == .escape {
            print("Version rename Escape: ownerIsKey=\(window.isKeyWindow), appKeyIsOwner=\(NSApplication.shared.keyWindow === window), firstResponder=\(String(describing: window.firstResponder))")
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code))
        NSApplication.shared.sendEvent(event)
    }

    @MainActor
    private func rowFrames(in host: NSView) async throws -> [RowFrames] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let document = descendants(host).compactMap({ $0 as? NSScrollView }).first?.documentView {
                // AppKit supplies native views for the rendered button bounds.
                // Decorative focus views may share those bounds, so deduplicate
                // rectangles before locating the two controls in each row.
                let frames = leafFrames(in: document, relativeTo: host)
                var grouped: [[NSRect]] = []
                for frame in frames.sorted(by: { host.isFlipped ? $0.midY < $1.midY : $0.midY > $1.midY }) {
                    if let index = grouped.firstIndex(where: { abs($0[0].midY - frame.midY) < 1 }) {
                        grouped[index].append(frame)
                    } else { grouped.append([frame]) }
                }
                let rows = grouped.compactMap { group -> RowFrames? in
                    let controls = group.sorted { $0.midX < $1.midX }
                    guard controls.count == 2, controls[0].width > controls[1].width * 2 else { return nil }
                    return RowFrames(name: controls[0], rename: controls[1])
                }
                if rows.count == 3 { return rows }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try? snapshot(host, to: "/tmp/lad-version-picker-initial.png")
        let native = descendants(host).map {
            "\(String(describing: type(of: $0))) frame=\($0.frame) focusable=\($0.acceptsFirstResponder)"
        }
        let diagnostic = "Version rows did not expose three name/pencil control pairs:\n" + native.joined(separator: "\n")
        try? diagnostic.write(toFile: "/tmp/lad-version-picker-native.txt", atomically: true, encoding: .utf8)
        print(diagnostic)
        throw LADError.message("The native version list did not finish displaying its three rows.")
    }

    private struct RowFrames {
        let name: NSRect
        let rename: NSRect
    }

    @MainActor
    private func leafFrames(in view: NSView, relativeTo host: NSView) -> [NSRect] {
        var result: [NSRect] = []
        for leaf in descendants(view) where leaf.subviews.isEmpty && !leaf.isHiddenOrHasHiddenAncestor {
            let frame = host.convert(leaf.bounds, from: leaf)
            guard frame.width > 5, frame.height > 5, host.bounds.intersects(frame),
                  !result.contains(where: { abs($0.minX - frame.minX) < 1 && abs($0.minY - frame.minY) < 1
                      && abs($0.width - frame.width) < 1 && abs($0.height - frame.height) < 1 }) else { continue }
            result.append(frame)
        }
        return result
    }

    @MainActor
    private func click(_ frame: NSRect, in host: NSView) throws {
        let window = try XCTUnwrap(host.window)
        let location = host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        XCTAssertNotNil(host.hitTest(host.convert(location, from: nil)), "The rendered control must have a native hit target.")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    @MainActor
    private func nameField(in host: NSView) async throws -> NSTextField {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let field = descendants(host).compactMap({ $0 as? NSTextField }).first(where: {
                $0.isEditable && !$0.isHiddenOrHasHiddenAncestor
            }) {
                // The production field schedules its SwiftUI focus after
                // mounting. Let that task finish before sending a command.
                try await Task.sleep(for: .milliseconds(20))
                return field
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Renaming must present a native inline text field.")
        return try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    @MainActor
    private func wait(in host: NSView, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "The inline name change did not reach the displayed project state.")
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func makeWindow(state: AppState, onSelect: @escaping (UUID) -> Void,
                            onDismiss: @escaping () -> Void = {}) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 340, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "LAD version naming check"
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: VStack(alignment: .trailing, spacing: 16) {
            ProjectRevisionPicker(state: state)
            ProjectRevisionPickerList(state: state, onSelect: onSelect, onDismiss: onDismiss)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing))
        host.sizingOptions = []
        window.contentView = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }

    @MainActor
    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    @MainActor
    private func snapshot(_ view: NSView, to path: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let state: AppState

        init() throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required to check native version naming.") }
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-version-picker-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.revisions = (1...3).map { index in
                ProjectRevision(model: ModelSpec(title: "Enclosure generation \(index)", summary: "Version naming fixture",
                    units: "mm", script: "result = cq.Workplane('XY').box(\(index), 4, 5)\n"))
            }
            state.selectedRevisionID = state.revisions[1].id
        }

        func cleanUp() {
            state.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
