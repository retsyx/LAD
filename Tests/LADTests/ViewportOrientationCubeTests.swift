import AppKit
import simd
import XCTest
@testable import LAD

final class ViewportOrientationCubeTests: XCTestCase {
    func testAllSixFacesProjectWithCorrectLabelsAndUnmirroredAxes() {
        for direction in ViewportCubeFace.allCases {
            let backward = direction.normal
            let right: SIMD3<Double>
            let up: SIMD3<Double>
            switch direction {
            case .front: right = [1, 0, 0]; up = [0, 0, 1]
            case .back: right = [-1, 0, 0]; up = [0, 0, 1]
            case .left: right = [0, -1, 0]; up = [0, 0, 1]
            case .right: right = [0, 1, 0]; up = [0, 0, 1]
            case .top: right = [1, 0, 0]; up = [0, 1, 0]
            case .bottom: right = [1, 0, 0]; up = [0, -1, 0]
            }
            let projection = ViewportCubeProjection(bounds: NSRect(x: 0, y: 0, width: 92, height: 92),
                                                      right: right, up: up, backward: backward)
            XCTAssertEqual(projection.faces.map(\.direction), [direction])
            XCTAssertEqual(projection.face(at: NSPoint(x: 46, y: 46)), direction)
            XCTAssertNil(projection.face(at: .zero))
            let face = projection.faces[0]
            XCTAssertEqual(face.horizontal.dx, 1, accuracy: 1e-8)
            XCTAssertEqual(face.horizontal.dy, 0, accuracy: 1e-8)
            XCTAssertEqual(face.vertical.dx, 0, accuracy: 1e-8)
            XCTAssertEqual(face.vertical.dy, 1, accuracy: 1e-8)
        }
    }

    func testObliqueProjectionOnlyHitsVisibleFacesAtTheirActualProjectedCenters() {
        for yaw in stride(from: -Double.pi, through: Double.pi, by: .pi / 8) {
            for elevation in [-1.1, -0.4, 0.4, 1.1] {
                let backward = SIMD3(cos(elevation) * cos(yaw), cos(elevation) * sin(yaw), sin(elevation))
                let right = SIMD3(-sin(yaw), cos(yaw), 0)
                let projection = ViewportCubeProjection(bounds: NSRect(x: 0, y: 0, width: 92, height: 92),
                    right: right, up: simd_cross(backward, right), backward: backward)
                XCTAssertLessThanOrEqual(projection.faces.count, 3)
                for face in projection.faces {
                    XCTAssertGreaterThan(simd_dot(face.direction.normal, backward), 0)
                    XCTAssertEqual(projection.face(at: face.center), face.direction)
                    XCTAssertGreaterThan(face.horizontal.dx * face.vertical.dy - face.horizontal.dy * face.vertical.dx, 0)
                    XCTAssertTrue(face.points.allSatisfy { NSRect(x: 0, y: 0, width: 92, height: 92).contains($0) })
                }
            }
        }
    }

    @MainActor
    func testFaceClickSelectsButConsecutiveZeroDeltaDragDoesNotSnapOnRelease() throws {
        let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        cube.setOrientation(right: [1, 0, 0], up: [0, 0, 1], backward: [0, -1, 0])
        var selected: [ViewportCubeFace] = []
        var deltas: [SIMD2<Double>] = []
        cube.onSelectFace = { selected.append($0) }
        cube.onOrbit = { deltas.append(SIMD2($0, $1)) }

        cube.mouseDown(with: try event(.leftMouseDown, point: [46, 46]))
        cube.mouseDragged(with: try event(.leftMouseDragged, point: [47, 47]))
        XCTAssertTrue(deltas.isEmpty)
        cube.mouseUp(with: try event(.leftMouseUp, point: [47, 47]))
        XCTAssertEqual(selected, [.front])

        cube.mouseDown(with: try event(.leftMouseDown, point: [46, 46]))
        let drag = try event(.leftMouseDragged, point: [51, 48])
        XCTAssertEqual(drag.deltaX, 0)
        XCTAssertEqual(drag.deltaY, 0)
        cube.mouseDragged(with: drag)
        cube.mouseDragged(with: try event(.leftMouseDragged, point: [54, 47]))
        cube.mouseDragged(with: try event(.leftMouseDragged, point: [54, 47]))
        cube.mouseUp(with: try event(.leftMouseUp, point: [46, 46]))
        XCTAssertEqual(deltas, [SIMD2(5, 2), SIMD2(3, -1)])
        XCTAssertEqual(selected, [.front], "Returning to a face after dragging must not snap the camera.")
        cube.mouseDragged(with: try event(.leftMouseDragged, point: [60, 46]))
        XCTAssertEqual(deltas.count, 2)
    }

    @MainActor
    func testDetachmentAndWindowDeactivationCancelPendingGestures() throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        defer { application.setActivationPolicy(previousPolicy) }
        let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        let window = NSWindow(contentRect: cube.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = cube
        var orbitCount = 0
        var selectionCount = 0
        cube.onOrbit = { _, _ in orbitCount += 1 }
        cube.onSelectFace = { _ in selectionCount += 1 }

        cube.mouseDown(with: try event(.leftMouseDown, point: [46, 46]))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        cube.mouseDragged(with: try event(.leftMouseDragged, point: [56, 46]))
        cube.mouseUp(with: try event(.leftMouseUp, point: [46, 46]))
        XCTAssertEqual(orbitCount, 0)
        XCTAssertEqual(selectionCount, 0)

        cube.mouseDown(with: try event(.leftMouseDown, point: [46, 46]))
        cube.removeFromSuperview()
        cube.mouseDragged(with: try event(.leftMouseDragged, point: [56, 46]))
        cube.mouseUp(with: try event(.leftMouseUp, point: [46, 46]))
        XCTAssertEqual(orbitCount, 0)
        XCTAssertEqual(selectionCount, 0)
        window.close()
    }

    @MainActor
    func testAccessibilityCanChooseEveryDirectionIncludingHiddenFaces() throws {
        let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        cube.setOrientation(right: [1, 0, 0], up: [0, 0, 1], backward: [0, -1, 0])
        XCTAssertEqual(cube.accessibilityLabel(), "View orientation")
        let children = try XCTUnwrap(cube.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 6)
        var selected: [ViewportCubeFace] = []
        cube.onSelectFace = { selected.append($0) }
        for (child, direction) in zip(children, ViewportCubeFace.allCases) {
            XCTAssertEqual(child.accessibilityRole(), .button)
            XCTAssertEqual(child.accessibilityLabel(), "\(direction.title) view")
            XCTAssertTrue(child.isAccessibilityEnabled())
            XCTAssertTrue(child.accessibilityPerformPress())
        }
        XCTAssertEqual(selected, ViewportCubeFace.allCases)
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, point: SIMD2<Double>) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: point.y), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }
}
