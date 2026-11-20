import AppKit
import simd
import XCTest
@testable import LAD

final class CADSectionManipulatorTests: XCTestCase {
    private struct ScreenHandles {
        let arrow: SIMD2<Double>
        let vertical: SIMD2<Double>
        let horizontal: SIMD2<Double>

        var hub: SIMD2<Double> { SIMD2(vertical.x, horizontal.y) }
        var tips: [SIMD2<Double>] { [arrow, vertical, horizontal] }
        var lengths: [Double] { tips.map { simd_distance(hub, $0) } }
    }

    @MainActor
    func testHandlesStayAnchoredAndKeepTheirScreenSizeAcrossCameraChanges() throws {
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 480)
        let meshBounds: [Double] = [-30, -15, -10, 30, 15, 10]
        var rig = CameraRig()
        rig.fit(bounds: meshBounds, width: viewport.width, height: viewport.height)
        let plane = try XCTUnwrap(CADSectionPlane(bounds: meshBounds, toward: rig.backward, cameraRight: rig.right))
        XCTAssertNotEqual(plane.origin, plane.center)
        let manipulator = CADSectionManipulator(onBegin: {}, onChange: { _ in })
        manipulator.frame = viewport
        let initialProjection = rig.projection(width: viewport.width, height: viewport.height)
        manipulator.update(plane: plane, projection: initialProjection)
        let initialHandles = try handles(in: manipulator)
        XCTAssertEqual(simd_distance(initialHandles.hub, initialProjection.project(plane.origin).screen), 0, accuracy: 0.01)
        let initialLengths = initialHandles.lengths
        XCTAssertEqual(initialLengths[0], 50, accuracy: 0.01)
        XCTAssertEqual(initialLengths[1], 27, accuracy: 0.01)
        XCTAssertEqual(initialLengths[2], 27, accuracy: 0.01)

        for orthographic in [false, true] {
            rig.usesOrthographicProjection = orthographic
            rig.orbitAroundCenter(dx: 92, dy: -32)
            rig.roll += 0.21
            rig.zoom(factor: 0.88, anchor: rig.target)
            let projection = rig.projection(width: viewport.width, height: viewport.height)
            manipulator.update(plane: plane, projection: projection)
            let currentHandles = try handles(in: manipulator)
            let center = currentHandles.hub
            XCTAssertEqual(simd_distance(center, projection.project(plane.origin).screen), 0, accuracy: 0.01)
            for (current, initial) in zip(currentHandles.lengths, initialLengths) {
                XCTAssertEqual(current, initial, accuracy: 0.01)
            }
            for tip in currentHandles.tips {
                let point = tip + 13.5 * simd_normalize(tip - center)
                XCTAssertTrue(manipulator.hitTest(NSPoint(x: point.x, y: point.y)) === manipulator)
            }
        }
    }

    @MainActor
    func testArrowDragUsesTheNormalOfTheRotatedSection() throws {
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
        var plane = try XCTUnwrap(CADSectionPlane(bounds: meshBounds, toward: rig.backward, cameraRight: rig.right))
        weak var overlay: CADSectionManipulator?
        let manipulator = CADSectionManipulator(onBegin: {}, onChange: { next in
            plane = next
            overlay?.update(plane: next, projection: projection)
        })
        overlay = manipulator
        manipulator.frame = viewport
        content.addSubview(manipulator)
        manipulator.update(plane: plane, projection: projection)

        let swung = try XCTUnwrap(plane.setting(72, for: .horizontal))
        let rotated = try XCTUnwrap(swung.setting(28, for: .vertical))
        XCTAssertEqual(rotated.origin, plane.origin)
        plane = rotated
        manipulator.update(plane: rotated, projection: projection)
        let currentHandles = try handles(in: manipulator)
        let arrow = currentHandles.arrow
        let distance = 7.0
        let worldDelta = distance * rotated.normal
        let screenDelta = projection.project(rotated.origin + worldDelta).screen - projection.project(rotated.origin).screen
        XCTAssertEqual(simd_dot(simd_normalize(arrow - currentHandles.hub), simd_normalize(screenDelta)), 1, accuracy: 1e-8)
        manipulator.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: arrow.x, y: arrow.y), in: window))
        let end = arrow + screenDelta
        manipulator.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: end.x, y: end.y), in: window))
        XCTAssertEqual(plane.value(for: .offset), rotated.value(for: .offset) + distance, accuracy: 1e-8)
        XCTAssertEqual(simd_distance(plane.origin - rotated.origin, worldDelta), 0, accuracy: 1e-8)
        XCTAssertEqual(plane.normal, rotated.normal)
        let movedHub = try handles(in: manipulator).hub
        XCTAssertEqual(simd_distance(movedHub, projection.project(plane.origin).screen), 0, accuracy: 0.01)
    }

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
            overlay?.update(plane: next, projection: projection)
        })
        overlay = manipulator
        manipulator.frame = viewport
        content.addSubview(manipulator)
        manipulator.update(plane: plane, projection: projection)

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
            manipulator.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))

            let moved = CGPoint(x: point.x + 12, y: point.y + 12)
            manipulator.mouseDragged(with: try mouse(.leftMouseDragged, at: moved, in: window))
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
            manipulator.mouseUp(with: try mouse(.leftMouseUp, at: moved, in: window))
            XCTAssertEqual(plane.value(for: handle), Double(index + 1))
        }
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func handles(in manipulator: CADSectionManipulator) throws -> ScreenHandles {
        let elements = try XCTUnwrap(manipulator.accessibilityChildren())
        func tip(_ handle: CADSectionHandle) throws -> SIMD2<Double> {
            let index = try XCTUnwrap(CADSectionHandle.allCases.firstIndex(of: handle))
            let element = try XCTUnwrap(elements[index] as? NSAccessibilityElement)
            let rect = element.accessibilityFrame()
            XCTAssertFalse(rect.isEmpty)
            let windowRect = manipulator.window?.convertFromScreen(rect) ?? rect
            let center = manipulator.convert(NSPoint(x: windowRect.midX, y: windowRect.midY), from: nil)
            return SIMD2(center.x, center.y)
        }
        return try ScreenHandles(arrow: tip(.offset), vertical: tip(.vertical), horizontal: tip(.horizontal))
    }
}

private final class FocusableViewport: NSView {
    override var acceptsFirstResponder: Bool { true }
}
