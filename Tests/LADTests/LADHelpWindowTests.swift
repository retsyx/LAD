import AppKit
import XCTest
@testable import LAD

final class LADHelpWindowTests: XCTestCase {
    @MainActor
    func testHelpWindowIsLazyAndRepeatedOpeningReusesOneNonmodalWindow() throws {
        try requireWindowServer()
        let controller = LADHelpWindowController()
        XCTAssertNil(controller.window, "Help must create a window only when requested.")
        defer { controller.close() }

        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.isWindowLoaded)
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(window.contentView)
        XCTAssertNil(window.parent, "App help must not be attached to a design window.")
        XCTAssertNil(NSApplication.shared.modalWindow)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.isRestorable, "Opening Help must not restore it automatically on the next launch.")
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .resizable, .miniaturizable]))

        for _ in 0..<3 {
            controller.showWindow(nil)
            XCTAssertTrue(controller.window === window, "Repeated Help commands must focus the existing window.")
            XCTAssertTrue(window.isVisible)
        }
    }

    @MainActor
    func testClosingAndReopeningHelpPreservesTheProjectWindow() throws {
        try requireWindowServer()
        let owner = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 520),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        owner.makeKeyAndOrderFront(nil)
        let ownerFrame = owner.frame
        let controller = LADHelpWindowController()
        defer { controller.close(); owner.close() }

        controller.showWindow(nil)
        let help = try XCTUnwrap(controller.window)
        XCTAssertTrue((owner.childWindows ?? []).isEmpty)
        help.setFrameOrigin(NSPoint(x: help.frame.minX + 24, y: help.frame.minY + 18))
        XCTAssertEqual(owner.frame, ownerFrame, "Moving Help must not move the open design.")

        help.performClose(nil)
        XCTAssertFalse(help.isVisible)
        XCTAssertTrue(owner.isVisible, "Closing Help must leave the open design available.")
        XCTAssertEqual(owner.frame, ownerFrame)

        controller.showWindow(nil)
        XCTAssertTrue(controller.window === help, "A closed Help window must remain reusable.")
        XCTAssertTrue(help.isVisible)
        XCTAssertTrue(owner.isVisible)
        XCTAssertEqual(owner.frame, ownerFrame)
    }

    @MainActor
    func testHelpCommandRestoresItsMinimizedWindow() async throws {
        try requireWindowServer()
        let controller = LADHelpWindowController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)

        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized }
        controller.showWindow(nil)
        try await waitUntil { !window.isMiniaturized && window.isVisible }
        XCTAssertTrue(controller.window === window,
                      "Requesting Help while it is minimized must restore that window rather than create another one.")
        XCTAssertNil(NSApplication.shared.modalWindow)
    }

    @MainActor
    private func requireWindowServer() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("A window server is required to verify Help window lifecycle.")
        }
    }

    @MainActor
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(condition(), "Expected the native window transition to finish.", file: file, line: line)
    }
}
