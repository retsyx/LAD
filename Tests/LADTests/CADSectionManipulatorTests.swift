import AppKit
import XCTest
@testable import LAD

final class CADSectionManipulatorTests: XCTestCase {
    @MainActor
    func testEachHandleUpdatesSelectedReadoutAndAcceptsTypingDuringDrag() throws {
        _ = NSApplication.shared
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = FocusableViewport(frame: viewport)
        window.contentView = content
        let meshBounds: [Double] = [-30, -15, -10, 30, 15, 10]
        var rig = CameraRig()
        rig.fit(bounds: meshBounds, width: viewport.width, height: viewport.height)
        let projection = rig.projection(width: viewport.width, height: viewport.height)
        var plane = try XCTUnwrap(CADSectionPlane(bounds: meshBounds, toward: rig.backward))
        weak var overlay: CADSectionManipulator?
        let manipulator = CADSectionManipulator(onBegin: {}, onChange: { next in
            plane = next
            overlay?.update(plane: next, projection: projection, bounds: meshBounds)
        })
        overlay = manipulator
        manipulator.frame = viewport
        content.addSubview(manipulator)
        manipulator.update(plane: plane, projection: projection, bounds: meshBounds)

        func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        func type(_ text: String, code: UInt16) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        }

        XCTAssertNil(manipulator.hitTest(CGPoint(x: 12, y: 12)))
        for (index, handle) in CADSectionHandle.allCases.enumerated() {
            let targets = try XCTUnwrap(manipulator.accessibilityChildren())
            let target = try XCTUnwrap(targets[index] as? NSAccessibilityElement)
            let frame = window.convertFromScreen(target.accessibilityFrame())
            let point = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertTrue(manipulator.hitTest(point) === manipulator)
            let before = plane
            manipulator.mouseDown(with: try mouse(.leftMouseDown, at: point))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))

            let moved = CGPoint(x: point.x + 12, y: point.y + 12)
            manipulator.mouseDragged(with: try mouse(.leftMouseDragged, at: moved))
            XCTAssertNotEqual(plane.value(for: handle), before.value(for: handle))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))

            let dragged = plane
            let value = String(index + 1)
            try type(value, code: UInt16(18 + index))
            XCTAssertEqual(editor.string, value)
            XCTAssertEqual(plane, dragged)
            try type("\r", code: 36)
            XCTAssertEqual(plane.value(for: handle), Double(index + 1))
            XCTAssertTrue(window.firstResponder === content)
            XCTAssertEqual(manipulator.accessibilityChildren()?.count, CADSectionHandle.allCases.count)
            manipulator.mouseUp(with: try mouse(.leftMouseUp, at: moved))
            XCTAssertEqual(plane.value(for: handle), Double(index + 1))
        }
    }
}

private final class FocusableViewport: NSView {
    override var acceptsFirstResponder: Bool { true }
}
