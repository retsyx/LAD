import AppKit
import XCTest
@testable import LAD

final class ProjectRenameOutsideClickTests: XCTestCase {
    @MainActor
    func testClicksInsideTheNameFieldKeepEditingAndPassThroughUnchanged() throws {
        let window = makeWindow()
        defer { window.close() }
        let region = ProjectRenameOutsideClickView(frame: NSRect(x: 90, y: 260, width: 280, height: 30))
        var canceled = 0
        region.onCancel = { canceled += 1 }
        try XCTUnwrap(window.contentView).addSubview(region)
        defer { region.disconnect() }
        XCTAssertFalse(region.acceptsFirstResponder)
        XCTAssertNil(region.hitTest(NSPoint(x: 5, y: 5)), "The cancellation region must never intercept name editing.")

        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let event = try mouse(type, at: NSPoint(x: 180, y: 275), in: window)
            XCTAssertTrue(region.handleMouseDown(event) === event,
                          "Inside clicks, including the native text context menu, must retain their original event.")
        }
        XCTAssertEqual(canceled, 0)
    }

    @MainActor
    func testClickingBlankWorkspaceCancelsAndStillDeliversTheOriginalClick() throws {
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let window = makeWindow()
            defer { window.close() }
            let region = ProjectRenameOutsideClickView(frame: NSRect(x: 90, y: 260, width: 280, height: 30))
            var canceled = 0
            region.onCancel = { canceled += 1 }
            try XCTUnwrap(window.contentView).addSubview(region)
            defer { region.disconnect() }
            // This is deliberately ordinary, nonfocusable NSView space.
            let event = try mouse(type, at: NSPoint(x: 500, y: 60), in: window)
            XCTAssertTrue(region.handleMouseDown(event) === event,
                          "Canceling rename must preserve the clicked control or viewport gesture.")
            XCTAssertEqual(canceled, 1, "An outside click must cancel even when it does not move keyboard focus.")
        }
    }

    @MainActor
    func testOtherWindowEventsCannotCancelThisFieldsEdit() throws {
        let owner = makeWindow(), other = makeWindow()
        defer { owner.close(); other.close() }
        let region = ProjectRenameOutsideClickView(frame: NSRect(x: 90, y: 260, width: 280, height: 30))
        var canceled = 0
        region.onCancel = { canceled += 1 }
        try XCTUnwrap(owner.contentView).addSubview(region)
        defer { region.disconnect() }
        let event = try mouse(.leftMouseDown, at: NSPoint(x: 500, y: 60), in: other)
        XCTAssertTrue(region.handleMouseDown(event) === event)
        XCTAssertEqual(canceled, 0, "Per-window handlers must not compare another window's coordinates against this name field.")
    }

    @MainActor
    func testLeavingTheOwningWindowCancelsButDisconnectRemovesStaleCallbacks() throws {
        let owner = makeWindow(), other = makeWindow()
        defer { owner.close(); other.close() }
        let region = ProjectRenameOutsideClickView(frame: NSRect(x: 90, y: 260, width: 280, height: 30))
        var canceled = 0
        region.onCancel = { canceled += 1 }
        try XCTUnwrap(owner.contentView).addSubview(region)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        XCTAssertEqual(canceled, 0)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner)
        XCTAssertEqual(canceled, 1, "Switching windows or applications must cancel the inline rename.")
        region.disconnect()
        let event = try mouse(.leftMouseDown, at: NSPoint(x: 500, y: 60), in: owner)
        XCTAssertTrue(region.handleMouseDown(event) === event)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner)
        XCTAssertEqual(canceled, 1, "A dismantled editor must not retain event or window-notification callbacks.")
    }

    @MainActor
    func testDetachedRegionCannotCancelAWindowItNoLongerBelongsTo() throws {
        let window = makeWindow()
        defer { window.close() }
        let region = ProjectRenameOutsideClickView(frame: NSRect(x: 90, y: 260, width: 280, height: 30))
        var canceled = 0
        region.onCancel = { canceled += 1 }
        try XCTUnwrap(window.contentView).addSubview(region)
        region.removeFromSuperview()
        defer { region.disconnect() }
        let event = try mouse(.leftMouseDown, at: NSPoint(x: 500, y: 60), in: window)
        XCTAssertTrue(region.handleMouseDown(event) === event)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(canceled, 0)
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
