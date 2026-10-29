import AppKit
import simd
import XCTest
@testable import LAD

final class ViewportOrientationCubeTests: XCTestCase {
    func testAllSixFacesProjectWithCorrectLabelsAndUnmirroredAxes() {
        for direction in ViewportCubeFace.allCases {
            let projection = projection(for: direction)
            XCTAssertEqual(projection.faces.map(\.direction), [direction])
            XCTAssertEqual(projection.face(at: NSPoint(x: 46, y: 46)), direction)
            XCTAssertEqual(projection.hitTarget(at: NSPoint(x: 46, y: 46)), .face(direction))
            XCTAssertNil(projection.hitTarget(at: .zero))
            let face = projection.faces[0]
            XCTAssertEqual(face.frame.width, 80, accuracy: 1e-8)
            XCTAssertEqual(face.horizontal.dx, 1, accuracy: 1e-8)
            XCTAssertEqual(face.horizontal.dy, 0, accuracy: 1e-8)
            XCTAssertEqual(face.vertical.dx, 0, accuracy: 1e-8)
            XCTAssertEqual(face.vertical.dy, 1, accuracy: 1e-8)
            for point in [NSPoint(x: 0, y: 0.9), NSPoint(x: 0, y: -0.9), NSPoint(x: 0.9, y: 0), NSPoint(x: -0.9, y: 0)] {
                XCTAssertEqual(projection.hitTarget(at: face.point(at: point)), .oppositeFace(direction))
            }
            // The inset panel has rounded corners: its bounding-box corner is still gray perimeter.
            XCTAssertEqual(projection.hitTarget(at: face.point(at: NSPoint(x: 0.73, y: 0.73))), .oppositeFace(direction))
            XCTAssertEqual(projection.projectedTargetCenters.keys.filter { if case .corner = $0 { return true }; return false }.count, 4)
            for (target, point) in projection.projectedTargetCenters { XCTAssertEqual(projection.hitTarget(at: point), target) }
        }
    }

    func testEightPhysicalCornersAreSharedAcrossAdjacentFaces() {
        XCTAssertEqual(ViewportCubeCorner.allCases.count, 8)
        for corner in ViewportCubeCorner.allCases {
            XCTAssertEqual(simd_length(corner.direction), 1, accuracy: 1e-8)
            XCTAssertEqual(ViewportCubeCorner(signs: corner.signs), corner)
            var matchingFaces = 0
            for direction in ViewportCubeFace.allCases where simd_dot(direction.normal, corner.signs) > 0 {
                let projection = projection(for: direction)
                let face = projection.faces[0]
                let projectedCorner = NSPoint(x: simd_dot(corner.signs - direction.normal, directionBasis(direction).right),
                                              y: simd_dot(corner.signs - direction.normal, directionBasis(direction).up))
                let interior = NSPoint(x: projectedCorner.x * 0.92, y: projectedCorner.y * 0.92)
                XCTAssertEqual(projection.hitTarget(at: face.point(at: interior)), .corner(corner))
                matchingFaces += 1
            }
            XCTAssertEqual(matchingFaces, 3, "Three face-local cutouts must identify one physical corner.")
        }
    }

    func testObliqueProjectionHasSevenVisiblePhysicalCornersAndAccurateTargetCenters() {
        for yaw in [-2.8, -1.9, -0.8, 0.3, 1.2, 2.4] {
            for elevation in [-1.1, -0.4, 0.4, 1.1] {
                let backward = SIMD3(cos(elevation) * cos(yaw), cos(elevation) * sin(yaw), sin(elevation))
                let right = SIMD3(-sin(yaw), cos(yaw), 0)
                let projection = ViewportCubeProjection(bounds: NSRect(x: 0, y: 0, width: 92, height: 92),
                    right: right, up: simd_cross(backward, right), backward: backward)
                XCTAssertEqual(projection.faces.count, 3)
                XCTAssertEqual(projection.projectedTargetCenters.keys.filter { if case .corner = $0 { return true }; return false }.count, 7)
                for face in projection.faces {
                    XCTAssertGreaterThan(simd_dot(face.direction.normal, backward), 0)
                    XCTAssertGreaterThan(face.horizontal.dx * face.vertical.dy - face.horizontal.dy * face.vertical.dx, 0)
                    XCTAssertTrue(face.points.allSatisfy { NSRect(x: 0, y: 0, width: 92, height: 92).contains($0) })
                }
                for (target, point) in projection.projectedTargetCenters { XCTAssertEqual(projection.hitTarget(at: point), target) }
            }
        }
    }

    @MainActor
    func testFacePerimeterAndCornerClicksDispatchAndMovementCancelsClick() throws {
        let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        cube.setOrientation(right: [1, 0, 0], up: [0, 0, 1], backward: [0, -1, 0])
        var faces: [ViewportCubeFace] = [], corners: [ViewportCubeCorner] = []
        cube.onSelectFace = { faces.append($0) }
        cube.onSelectCorner = { corners.append($0) }
        for target in [ViewportCubeTarget.face(.front), .oppositeFace(.front), .corner(.rightFrontTop)] {
            let point = try XCTUnwrap(cube.projectedTargetCenters[target])
            XCTAssertEqual(cube.hitTarget(at: point), target)
            cube.mouseDown(with: try event(.leftMouseDown, point: point))
            cube.mouseUp(with: try event(.leftMouseUp, point: point))
        }
        XCTAssertEqual(faces, [.front, .back])
        XCTAssertEqual(corners, [.rightFrontTop])
        let center = NSPoint(x: 46, y: 46)
        cube.mouseDown(with: try event(.leftMouseDown, point: center))
        let drag = try event(.leftMouseDragged, point: NSPoint(x: 49, y: 46))
        XCTAssertEqual(drag.deltaX, 0)
        XCTAssertEqual(drag.deltaY, 0)
        cube.mouseDragged(with: drag)
        cube.mouseDragged(with: try event(.leftMouseDragged, point: center))
        cube.mouseUp(with: try event(.leftMouseUp, point: center))
        XCTAssertEqual(faces, [.front, .back], "Returning to the starting point after movement must not trigger a click.")
        XCTAssertEqual(corners, [.rightFrontTop])
        cube.mouseDown(with: try event(.leftMouseDown, point: center))
        cube.setOrientation(right: [-1, 0, 0], up: [0, 0, 1], backward: [0, 1, 0])
        cube.mouseUp(with: try event(.leftMouseUp, point: center))
        XCTAssertEqual(faces, [.front, .back], "A changed camera must cancel a press captured with the previous cube pose.")
    }

    @MainActor
    func testDetachmentAndWindowDeactivationCancelPendingClicks() throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        defer { application.setActivationPolicy(previousPolicy) }
        let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        let window = NSWindow(contentRect: cube.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = cube
        var selectionCount = 0
        cube.onSelectFace = { _ in selectionCount += 1 }
        cube.onSelectCorner = { _ in selectionCount += 1 }
        cube.mouseDown(with: try event(.leftMouseDown, point: NSPoint(x: 46, y: 46)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        cube.mouseUp(with: try event(.leftMouseUp, point: NSPoint(x: 46, y: 46)))
        XCTAssertEqual(selectionCount, 0)
        cube.mouseDown(with: try event(.leftMouseDown, point: NSPoint(x: 46, y: 46)))
        cube.removeFromSuperview()
        cube.mouseUp(with: try event(.leftMouseUp, point: NSPoint(x: 46, y: 46)))
        XCTAssertEqual(selectionCount, 0)
        window.close()
    }

    @MainActor
    func testAccessibilityHasSixEnabledFacesAndEightUniqueEnabledCorners() throws {
        let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        cube.setOrientation(right: [1, 0, 0], up: [0, 0, 1], backward: [0, -1, 0])
        XCTAssertEqual(cube.accessibilityLabel(), "View orientation")
        let children = try XCTUnwrap(cube.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 14)
        var faces: [ViewportCubeFace] = [], corners: [ViewportCubeCorner] = []
        cube.onSelectFace = { faces.append($0) }
        cube.onSelectCorner = { corners.append($0) }
        for child in children {
            XCTAssertEqual(child.accessibilityRole(), .button)
            XCTAssertTrue(child.isAccessibilityEnabled())
            XCTAssertTrue(child.accessibilityPerformPress())
        }
        XCTAssertEqual(faces, ViewportCubeFace.allCases)
        XCTAssertEqual(corners, ViewportCubeCorner.allCases)
        XCTAssertEqual(Set(children.compactMap { $0.accessibilityIdentifier() }).count, 14)
    }

    @MainActor
    func testNativeBitmapHasLightPanelGrayPerimeterAndTransparentCutouts() throws {
        _ = NSApplication.shared
        let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        cube.setOrientation(right: [1, 0, 0], up: [0, 1, 0], backward: [0, 0, 1])
        let bitmap = try capture(cube)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 14, y: 14))
        let panel = try XCTUnwrap(bitmap.colorAt(x: 92, y: 62)?.usingColorSpace(.deviceRGB))
        let perimeter = try XCTUnwrap(bitmap.colorAt(x: 92, y: 14)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(corner.alphaComponent, 0.05)
        XCTAssertGreaterThan(panel.redComponent, perimeter.redComponent + 0.2)
        XCTAssertGreaterThan(perimeter.alphaComponent, 0.95)
        var labelInk: [NSPoint] = []
        for y in 64..<120 {
            for x in 64..<120 {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.alphaComponent > 0.95, color.redComponent < 0.3 {
                    labelInk.append(NSPoint(x: x, y: y))
                }
            }
        }
        XCTAssertGreaterThan(labelInk.count, 20, "The label must appear in the middle of the inset panel.")
        let inkTop = try XCTUnwrap(labelInk.map(\.y).min())
        let inkBottom = try XCTUnwrap(labelInk.map(\.y).max())
        XCTAssertEqual((inkTop + inkBottom) / 2, 92, accuracy: 8)
        let directory = URL(fileURLWithPath: "/private/tmp/lad-orientation-cube-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("top.png"))
        cube.setOrientation(right: [sqrt(0.5), sqrt(0.5), 0], up: [-1 / sqrt(6), 1 / sqrt(6), sqrt(2.0 / 3)],
                            backward: [1 / sqrt(3), -1 / sqrt(3), 1 / sqrt(3)])
        let isometric = try capture(cube)
        try XCTUnwrap(isometric.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("isometric.png"))
    }

    private func projection(for direction: ViewportCubeFace) -> ViewportCubeProjection {
        let basis = directionBasis(direction)
        return ViewportCubeProjection(bounds: NSRect(x: 0, y: 0, width: 92, height: 92),
            right: basis.right, up: basis.up, backward: direction.normal)
    }

    private func directionBasis(_ direction: ViewportCubeFace) -> (right: SIMD3<Double>, up: SIMD3<Double>) {
        switch direction {
        case .front: return ([1, 0, 0], [0, 0, 1])
        case .back: return ([-1, 0, 0], [0, 0, 1])
        case .left: return ([0, -1, 0], [0, 0, 1])
        case .right: return ([0, 1, 0], [0, 0, 1])
        case .top: return ([1, 0, 0], [0, 1, 0])
        case .bottom: return ([1, 0, 0], [0, -1, 0])
        }
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func capture(_ cube: ViewportOrientationCube) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 184, pixelsHigh: 184,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 184, height: 184))
        context.cgContext.scaleBy(x: 2, y: 2)
        cube.draw(cube.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
