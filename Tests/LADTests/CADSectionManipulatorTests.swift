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
    func testHandlesStayAnchoredAndRotationBarsKeepTheirSizeAcrossCameraChanges() throws {
        _ = NSApplication.shared
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
        XCTAssertEqual(initialLengths[1], 37, accuracy: 0.01)
        XCTAssertEqual(initialLengths[2], 37, accuracy: 0.01)

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
            for (current, initial) in zip(currentHandles.lengths.dropFirst(), initialLengths.dropFirst()) {
                XCTAssertEqual(current, initial, accuracy: 0.01)
            }
            for tip in currentHandles.tips where tip != center {
                let point = tip + 13.5 * simd_normalize(tip - center)
                XCTAssertTrue(manipulator.hitTest(NSPoint(x: point.x, y: point.y)) === manipulator)
            }
        }
    }

    @MainActor
    func testOffsetArrowFollowsTheProjectedNormalOnEitherSideOfAHeadOnView() throws {
        _ = NSApplication.shared
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 480)
        let plane = try XCTUnwrap(CADSectionPlane(point: .zero, normal: SIMD3(1, 0, 0), cameraRight: SIMD3(0, 1, 0)))
        let manipulator = CADSectionManipulator(onBegin: {}, onChange: { _ in })
        manipulator.frame = viewport

        for orthographic in [false, true] {
            var rig = CameraRig()
            rig.elevation = 0
            rig.roll = 0.24
            rig.usesOrthographicProjection = orthographic
            for yaw in [-0.64, -0.24, -0.04, 0, 0.04, 0.24, 0.64] {
                rig.yaw = yaw
                let projection = rig.projection(width: viewport.width, height: viewport.height)
                manipulator.update(plane: plane, projection: projection)
                let currentHandles = try handles(in: manipulator)
                let arrow = currentHandles.arrow - currentHandles.hub
                let gain = abs(sin(yaw))
                if gain < 0.12 {
                    XCTAssertEqual(simd_length(arrow), 0, accuracy: 0.01)
                    let hub = currentHandles.hub
                    XCTAssertTrue(manipulator.hitTest(NSPoint(x: hub.x, y: hub.y)) === manipulator)
                } else {
                    let forward = projection.project(plane.origin + plane.normal).screen
                    let expected = forward - projection.project(plane.origin).screen
                    XCTAssertEqual(simd_dot(simd_normalize(arrow), simd_normalize(expected)), 1, accuracy: 1e-8)
                    XCTAssertEqual(simd_length(arrow), 50 * min(1, gain / 0.48), accuracy: 0.01)
                }
            }
        }
    }

    @MainActor
    func testPerspectiveArrowUsesTheSightlineAtTheOffCenterAnchor() throws {
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 480)
        let plane = try XCTUnwrap(CADSectionPlane(point: .zero, normal: SIMD3(1, 0, 0), cameraRight: SIMD3(0, 1, 0)))
        let manipulator = CADSectionManipulator(onBegin: {}, onChange: { _ in })
        manipulator.frame = viewport
        var rig = CameraRig()
        rig.target = SIMD3(0, 52, -21)
        rig.yaw = 0
        rig.elevation = 0

        let projection = rig.projection(width: viewport.width, height: viewport.height)
        manipulator.update(plane: plane, projection: projection)
        let perspective = try handles(in: manipulator)
        let arrow = perspective.arrow - perspective.hub
        let offset = projection.project(plane.origin + plane.normal).screen - projection.project(plane.origin).screen
        XCTAssertGreaterThan(simd_length(arrow), 0)
        XCTAssertEqual(simd_dot(simd_normalize(arrow), simd_normalize(offset)), 1, accuracy: 1e-8)

        rig.usesOrthographicProjection = true
        manipulator.update(plane: plane, projection: rig.projection(width: viewport.width, height: viewport.height))
        let orthographic = try handles(in: manipulator)
        XCTAssertEqual(simd_distance(orthographic.arrow, orthographic.hub), 0, accuracy: 0.01)
    }

    @MainActor
    func testDraggingDepthMarkerUpMovesTheSectionAlongItsNormal() throws {
        _ = NSApplication.shared
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = FocusableViewport(frame: viewport)
        window.contentView = content
        var rig = CameraRig()
        rig.yaw = 0
        rig.elevation = 0
        rig.usesOrthographicProjection = true
        let projection = rig.projection(width: viewport.width, height: viewport.height)
        var plane = try XCTUnwrap(CADSectionPlane(point: .zero, normal: rig.backward, cameraRight: rig.right))
        weak var overlay: CADSectionManipulator?
        let manipulator = CADSectionManipulator(onBegin: {}, onChange: { next in
            plane = next
            overlay?.update(plane: next, projection: projection)
        })
        overlay = manipulator
        manipulator.frame = viewport
        content.addSubview(manipulator)

        let dragPoints = 20.0
        let expectedOffset = dragPoints * 2 * projection.orthographicScale / projection.height
        for normal in [rig.backward, -rig.backward] {
            plane = try XCTUnwrap(CADSectionPlane(point: .zero, normal: normal, cameraRight: rig.right))
            manipulator.update(plane: plane, projection: projection)
            let currentHandles = try handles(in: manipulator)
            XCTAssertEqual(simd_distance(currentHandles.arrow, currentHandles.hub), 0, accuracy: 0.01)
            let point = CGPoint(x: currentHandles.hub.x, y: currentHandles.hub.y)
            let end = CGPoint(x: point.x, y: point.y + dragPoints)
            manipulator.mouseMoved(with: try mouse(.mouseMoved, at: point, in: window))
            XCTAssertEqual(manipulator.hoveredHandle, .offset)
            manipulator.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window))
            manipulator.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: window))
            XCTAssertEqual(plane.value(for: .offset), expectedOffset, accuracy: 1e-8)
            XCTAssertEqual(simd_distance(plane.origin, expectedOffset * normal), 0, accuracy: 1e-8)
            manipulator.mouseUp(with: try mouse(.leftMouseUp, at: end, in: window))
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
    func testHoverAndClickFollowVisibleGeometryWhenTheArrowOverlapsAnAngleBar() throws {
        _ = NSApplication.shared
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = FocusableViewport(frame: viewport)
        window.contentView = content
        let manipulator = CADSectionManipulator(onBegin: {}, onChange: { _ in
            XCTFail("A click without a drag must not move the section plane")
        })
        manipulator.frame = viewport
        content.addSubview(manipulator)

        func checkTarget(_ expected: CADSectionHandle, at position: SIMD2<Double>) throws {
            let point = manipulator.convert(CGPoint(x: position.x, y: position.y), to: nil)
            let index = try XCTUnwrap(CADSectionHandle.allCases.firstIndex(of: expected))
            let control = try XCTUnwrap(manipulator.accessibilityChildren()?[index] as? NSAccessibilityElement)
            manipulator.mouseMoved(with: try mouse(.mouseMoved, at: point, in: window))
            XCTAssertEqual(manipulator.hoveredHandle, expected)
            manipulator.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window))
            let field = try XCTUnwrap(manipulator.accessibilityChildren()?.last as? NSTextField)
            XCTAssertEqual(try XCTUnwrap(field.accessibilityLabel()), try XCTUnwrap(control.accessibilityLabel()))
            manipulator.mouseUp(with: try mouse(.leftMouseUp, at: point, in: window))
            manipulator.cancelInteraction()
        }

        var rig = CameraRig()
        rig.yaw = 0
        rig.elevation = 0
        for orthographic in [false, true] {
            rig.usesOrthographicProjection = orthographic
            let projection = rig.projection(width: viewport.width, height: viewport.height)
            for depth in [1.0, 0.0, -1.0] {
                let plane = try XCTUnwrap(CADSectionPlane(point: .zero, normal: depth * rig.backward - rig.right, cameraRight: rig.right))
                manipulator.update(plane: plane, projection: projection)
                let grip = try handles(in: manipulator).horizontal
                try checkTarget(depth > 0 ? .offset : .horizontal, at: grip)
                try checkTarget(.offset, at: grip + SIMD2(0, 7.5))
                try checkTarget(.horizontal, at: grip + SIMD2(5, 4))
            }

            // The arrow shaft here is visible beside the vertical grip but
            // inside the grip's padded hit area.
            let diagonal = 0.25 * rig.right + rig.up - 0.6 * rig.backward
            let plane = try XCTUnwrap(CADSectionPlane(point: .zero, normal: diagonal, cameraRight: rig.right))
            manipulator.update(plane: plane, projection: projection)
            let hub = try handles(in: manipulator).hub
            try checkTarget(.offset, at: hub + SIMD2(7.5, 30))
        }
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
            manipulator.mouseMoved(with: try mouse(.mouseMoved, at: point, in: window))
            XCTAssertEqual(manipulator.hoveredHandle, handle)
            XCTAssertEqual(manipulator.accessibilityChildren()?.count, CADSectionHandle.allCases.count)
            XCTAssertEqual(plane, before)
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

        let tip = try handles(in: manipulator).horizontal
        let point = manipulator.convert(CGPoint(x: tip.x, y: tip.y), to: nil)
        let emptyPoint = CGPoint(x: 12, y: 12)
        manipulator.mouseEntered(with: try mouse(.mouseEntered, at: point, in: window))
        XCTAssertEqual(manipulator.hoveredHandle, .horizontal)
        manipulator.mouseMoved(with: try mouse(.mouseMoved, at: emptyPoint, in: window))
        XCTAssertNil(manipulator.hoveredHandle)
        manipulator.mouseMoved(with: try mouse(.mouseMoved, at: point, in: window))
        XCTAssertEqual(manipulator.hoveredHandle, .horizontal)
        manipulator.mouseExited(with: try mouse(.mouseExited, at: emptyPoint, in: window))
        XCTAssertNil(manipulator.hoveredHandle)
        manipulator.mouseMoved(with: try mouse(.mouseMoved, at: point, in: window))
        XCTAssertEqual(manipulator.hoveredHandle, .horizontal)
        manipulator.cancelInteraction()
        XCTAssertNil(manipulator.hoveredHandle)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
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
