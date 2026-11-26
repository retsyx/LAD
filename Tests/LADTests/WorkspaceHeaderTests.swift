import AppKit
import SwiftUI
import XCTest
@testable import LAD

/// The design header replaces the hidden system title bar.
final class WorkspaceHeaderTests: XCTestCase {
    @MainActor
    func testWindowButtonsStayCenteredInHeaderAcrossResizeAndTitleChanges() async throws {
        let fixture = try Fixture(name: "Header controls check")
        defer { fixture.close() }
        try await fixture.assertWindowButtonsCentered()
        fixture.window.setContentSize(NSSize(width: 1400, height: 860))
        try await fixture.assertWindowButtonsCentered()
        fixture.window.title = "Renamed header controls check"
        fixture.window.isDocumentEdited = true
        try await fixture.assertWindowButtonsCentered()
    }

    @MainActor
    func testFullScreenLeavesTitleBarToAppKitAndRestoresHeader() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for the design header.") }
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        _ = application.setActivationPolicy(.regular)
        application.finishLaunching()
        // Only the header chrome, whose title bar layout full screen exercises.
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: WindowHeaderChrome.height).background(WindowHeaderChrome())
            Spacer(minLength: 0)
        })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            _ = application.setActivationPolicy(previousPolicy)
        }
        try await Self.assertWindowButtonsCentered(in: window)
        // AppKit tiles the title bar for full screen while it is still in the
        // window, before moving it to the menu bar reveal window.
        await toggleFullScreen(window)
        XCTAssertTrue(window.styleMask.contains(.fullScreen))
        await toggleFullScreen(window)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        try await Self.assertWindowButtonsCentered(in: window)
    }

    /// Enters or leaves full screen and waits for the transition to finish.
    @MainActor
    private func toggleFullScreen(_ window: NSWindow) async {
        let finished = expectation(forNotification: window.styleMask.contains(.fullScreen)
            ? NSWindow.didExitFullScreenNotification : NSWindow.didEnterFullScreenNotification, object: window)
        window.toggleFullScreen(nil)
        await fulfillment(of: [finished], timeout: 10)
    }

    @MainActor
    private static func assertWindowButtonsCentered(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) async throws {
        // SwiftUI creates the header's AppKit view on its first update.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            if buttons.count == 3, buttons.allSatisfy({
                abs(window.frame.height - $0.convert($0.bounds, to: nil).midY - WindowHeaderChrome.height / 2) < 0.5
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind), file: file, line: line)
            let frame = button.convert(button.bounds, to: nil)
            XCTAssertEqual(window.frame.height - frame.midY, WindowHeaderChrome.height / 2, accuracy: 0.5,
                           "Window buttons are vertically centered in the header: \(kind.rawValue) \(frame) container \(button.superview?.superview?.frame ?? .zero) window \(window.frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, WindowHeaderChrome.windowButtonsWidth, file: file, line: line)
            if kind == .closeButton {
                XCTAssertEqual(frame.minX, window.frame.height - frame.maxY, accuracy: 0.5,
                               "Window buttons have equal top and leading margins.", file: file, line: line)
            }
            let hit = try XCTUnwrap(window.contentView?.superview?.hitTest(
                button.superview!.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: window.contentView?.superview)),
                file: file, line: line)
            XCTAssertTrue(hit === button || hit.isDescendant(of: button), "Window buttons remain clickable.", file: file, line: line)
        }
    }

    @MainActor
    func testLongDesignNameStaysCenteredClearOfActionsAndWhileRenaming() async throws {
        let name = "Enclosure " + String(repeating: "with a very long descriptive design name ", count: 5)
            .trimmingCharacters(in: .whitespaces)
        let fixture = try Fixture(name: name)
        defer { fixture.close() }
        let host = fixture.host
        XCTAssertTrue(fixture.state.canRenameProject)
        try await fixture.assertWindowButtonsCentered()
        let saveNew = try await fixture.saveNewFrame()
        XCTAssertEqual(saveNew.height, 30, accuracy: 0.5)

        // The centered name sits under the window's center inside AppKit's
        // own title bar band, and clicking it begins renaming in place.
        try fixture.click(NSPoint(x: host.bounds.midX, y: fixture.headerMidY))
        let field = try await fixture.renameField()
        XCTAssertEqual(field.stringValue, name)
        XCTAssertEqual(field.alignment, .center)
        let fieldFrame = host.convert(field.bounds, from: field)
        XCTAssertEqual(fieldFrame.midX, host.bounds.midX, accuracy: 1, "The name stays centered while it is edited.")
        // A long name fills the space between the window buttons and the
        // actions, with equal room on both sides, and is clipped there.
        XCTAssertLessThanOrEqual(fieldFrame.maxX, saveNew.minX - 14)
        XCTAssertGreaterThanOrEqual(fieldFrame.minX, WindowHeaderChrome.windowButtonsWidth)
        XCTAssertGreaterThan(fieldFrame.width, host.bounds.width - 2 * (host.bounds.maxX - saveNew.minX) - 2 * 14 - 30)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let state: AppState
        let host: NSHostingView<WorkspaceView>
        let window: NSWindow
        private let previousPolicy: NSApplication.ActivationPolicy
        private let oldCodex: Any?

        init(name: String) throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for the design header.") }
            let application = NSApplication.shared
            previousPolicy = application.activationPolicy()
            _ = application.setActivationPolicy(.regular)
            application.finishLaunching()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LAD-header-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
            let project = LADProject(messages: [ChatMessage(role: "user", content: "Design an enclosure.")], revisions: [],
                                     selectedRevisionID: nil, projectID: UUID(), projectName: name)
            let source = directory.appendingPathComponent("\(name).lad")
            try ProjectStore.write(project, to: source)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.loadProject(project, from: source)
            host = NSHostingView(rootView: WorkspaceView(state: state))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: .darkAqua)
            // The window style that `.windowStyle(.hiddenTitleBar)` produces.
            window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = name
            window.isReleasedWhenClosed = false
            window.contentView = host
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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

        func assertWindowButtonsCentered(file: StaticString = #filePath, line: UInt = #line) async throws {
            try await WorkspaceHeaderTests.assertWindowButtonsCentered(in: window, file: file, line: line)
        }

        /// The vertical center of the header in the host's coordinates.
        var headerMidY: CGFloat {
            host.isFlipped ? WindowHeaderChrome.height / 2 : host.bounds.maxY - WindowHeaderChrome.height / 2
        }

        func isInHeader(_ frame: NSRect) -> Bool { abs(frame.midY - headerMidY) < WindowHeaderChrome.height / 2 }

        func saveNewFrame() async throws -> NSRect {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                // Save New is the AppKit-backed button among the trailing actions.
                if let frame = Self.descendants(host).compactMap({ $0 as? NSButton }).map({ host.convert($0.bounds, from: $0) })
                    .filter({ isInHeader($0) && $0.minX > host.bounds.midX }).min(by: { $0.minX < $1.minX }) {
                    return frame
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LADError.message("The header did not show Save New.")
        }

        func renameField() async throws -> NSTextField {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if let field = Self.descendants(host).compactMap({ $0 as? NSTextField }).first(where: {
                    $0.isEditable && isInHeader(host.convert($0.bounds, from: $0))
                }) { return field }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LADError.message("Clicking the design name did not begin renaming.")
        }

        func click(_ point: NSPoint) throws {
            let location = host.convert(point, to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            }
            let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
            // These events stay inside this test application's native event loop.
            NSApplication.shared.postEvent(up, atStart: true)
            NSApplication.shared.sendEvent(down)
            if let release = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(release)
            }
        }

        private static func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
    }
}
