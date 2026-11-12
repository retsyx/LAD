import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportNavigationTests: XCTestCase {
    @MainActor
    func testZeroDeltaRightDragOrbitsUsingPointerLocationsWithoutRebuildingDrawingResources() async throws {
        let view = try await readyView()
        let camera = try XCTUnwrap(view.pointOfView)
        let before = camera.simdTransform
        let distance = simd_length(camera.simdPosition)
        let solid = try geometry("solid:0", in: view)
        let edges = try geometry("edges:0", in: view)
        let edgeSources = edges.sources
        var selectionChanges = 0
        view.onSelectionChanged = { _ in selectionChanges += 1 }
        view.onFeatureSelectionChanged = { _ in selectionChanges += 1 }

        view.rightMouseDown(with: try event(.rightMouseDown, x: 200, y: 200))
        let drag = try event(.rightMouseDragged, x: 240, y: 220)
        XCTAssertEqual(drag.deltaX, 0, "This event reproduces input sources that provide positions without relative deltas.")
        XCTAssertEqual(drag.deltaY, 0)
        view.rightMouseDragged(with: drag)
        XCTAssertGreaterThan(matrixDifference(before, camera.simdTransform), 0.1)
        XCTAssertEqual(simd_length(camera.simdPosition), distance, accuracy: 1e-4, "Orbit must not change viewing distance.")
        XCTAssertLessThan(camera.simdPosition.z, before.columns.3.z, "Upward pointer motion must use the established inverted drag-Y convention.")
        let origin = try projectedOrigin(in: view)
        XCTAssertEqual(origin.x, 320, accuracy: 0.01)
        XCTAssertEqual(origin.y, 240, accuracy: 0.01)
        XCTAssertTrue(try geometry("solid:0", in: view) === solid)
        XCTAssertTrue(try geometry("edges:0", in: view) === edges)
        for (before, after) in zip(edgeSources, edges.sources) { XCTAssertTrue(before === after) }
        XCTAssertFalse(view.isPreparingResources)
        XCTAssertEqual(selectionChanges, 0)
        view.rightMouseUp(with: try event(.rightMouseUp, x: 240, y: 220))
    }

    @MainActor
    func testRightDragKeepsClickThresholdWithoutAccidentalOrbit() async throws {
        let view = try await readyView()
        let camera = try XCTUnwrap(view.pointOfView)
        let before = camera.simdTransform
        view.rightMouseDown(with: try event(.rightMouseDown, x: 200, y: 200))
        view.rightMouseDragged(with: try event(.rightMouseDragged, x: 201, y: 201))
        view.rightMouseDragged(with: try event(.rightMouseDragged, x: 202, y: 201))
        assertMatrixEqual(camera.simdTransform, before)
        view.rightMouseDragged(with: try event(.rightMouseDragged, x: 205, y: 201))
        XCTAssertGreaterThan(matrixDifference(before, camera.simdTransform), 0.001)
        view.rightMouseUp(with: try event(.rightMouseUp, x: 205, y: 201))
    }

    @MainActor
    func testRightDragUsesConsecutiveLocationsInsteadOfRepeatedDistanceFromMouseDown() async throws {
        let stepped = try await readyView()
        let single = try await readyView()
        stepped.rightMouseDown(with: try event(.rightMouseDown, x: 200, y: 200))
        stepped.rightMouseDragged(with: try event(.rightMouseDragged, x: 220, y: 200))
        stepped.rightMouseDragged(with: try event(.rightMouseDragged, x: 240, y: 200))
        single.rightMouseDown(with: try event(.rightMouseDown, x: 200, y: 200))
        single.rightMouseDragged(with: try event(.rightMouseDragged, x: 240, y: 200))
        assertMatrixEqual(try XCTUnwrap(stepped.pointOfView).simdTransform,
                          try XCTUnwrap(single.pointOfView).simdTransform)
        let beforeRepeatedEvent = try XCTUnwrap(stepped.pointOfView).simdTransform
        stepped.rightMouseDragged(with: try event(.rightMouseDragged, x: 240, y: 200))
        assertMatrixEqual(try XCTUnwrap(stepped.pointOfView).simdTransform, beforeRepeatedEvent)
        stepped.rightMouseUp(with: try event(.rightMouseUp, x: 240, y: 200))
        single.rightMouseUp(with: try event(.rightMouseUp, x: 240, y: 200))
    }

    @MainActor
    func testShiftRightDragPansWithPointerWithoutChangingCameraOrientation() async throws {
        let view = try await readyView()
        let before = try XCTUnwrap(view.pointOfView).simdTransform
        let projected = try projectedOrigin(in: view)
        view.rightMouseDown(with: try event(.rightMouseDown, x: 200, y: 200, modifiers: [.shift]))
        view.rightMouseDragged(with: try event(.rightMouseDragged, x: 240, y: 220, modifiers: [.shift]))
        let after = try XCTUnwrap(view.pointOfView).simdTransform
        assertCameraBasisEqual(after, before)
        XCTAssertGreaterThan(simd_length(after.columns.3 - before.columns.3), 0.1)
        let moved = try projectedOrigin(in: view)
        XCTAssertEqual(moved.x - projected.x, 40, accuracy: 0.02)
        XCTAssertEqual(moved.y - projected.y, 20, accuracy: 0.02)
        view.rightMouseUp(with: try event(.rightMouseUp, x: 240, y: 220, modifiers: [.shift]))
    }

    @MainActor
    func testZeroDeltaMiddleDragPansWithConsecutivePointerPositions() async throws {
        let view = try await readyView()
        let before = try XCTUnwrap(view.pointOfView).simdTransform
        let projected = try projectedOrigin(in: view)
        view.otherMouseDown(with: try event(.otherMouseDown, x: 200, y: 200))
        let drag = try event(.otherMouseDragged, x: 220, y: 210)
        XCTAssertEqual(drag.deltaX, 0)
        XCTAssertEqual(drag.deltaY, 0)
        view.otherMouseDragged(with: drag)
        view.otherMouseDragged(with: try event(.otherMouseDragged, x: 240, y: 220))
        let after = try XCTUnwrap(view.pointOfView).simdTransform
        assertCameraBasisEqual(after, before)
        XCTAssertGreaterThan(simd_length(after.columns.3 - before.columns.3), 0.1)
        let moved = try projectedOrigin(in: view)
        XCTAssertEqual(moved.x - projected.x, 40, accuracy: 0.02)
        XCTAssertEqual(moved.y - projected.y, 20, accuracy: 0.02)
        view.otherMouseUp(with: try event(.otherMouseUp, x: 240, y: 220))
    }

    @MainActor
    func testButtonReleaseEndsNavigationAndNextGestureStartsAtItsOwnLocation() async throws {
        let view = try await readyView()
        view.rightMouseDown(with: try event(.rightMouseDown, x: 200, y: 200))
        view.rightMouseDragged(with: try event(.rightMouseDragged, x: 220, y: 200))
        view.rightMouseUp(with: try event(.rightMouseUp, x: 220, y: 200))
        let released = try XCTUnwrap(view.pointOfView).simdTransform
        view.rightMouseDragged(with: try event(.rightMouseDragged, x: 400, y: 400))
        assertMatrixEqual(try XCTUnwrap(view.pointOfView).simdTransform, released)

        view.rightMouseDown(with: try event(.rightMouseDown, x: 500, y: 300))
        view.rightMouseDragged(with: try event(.rightMouseDragged, x: 501, y: 301))
        assertMatrixEqual(try XCTUnwrap(view.pointOfView).simdTransform, released,
                          "A new mouse-down must discard the previous gesture's last location.")
        view.otherMouseDown(with: try event(.otherMouseDown, x: 200, y: 200))
        view.otherMouseDragged(with: try event(.otherMouseDragged, x: 220, y: 200))
        view.otherMouseUp(with: try event(.otherMouseUp, x: 220, y: 200))
        let middleReleased = try XCTUnwrap(view.pointOfView).simdTransform
        view.otherMouseDragged(with: try event(.otherMouseDragged, x: 400, y: 400))
        assertMatrixEqual(try XCTUnwrap(view.pointOfView).simdTransform, middleReleased)
    }

    @MainActor
    private func readyView() async throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let preview = PreviewMesh(vertices: [[-10, -10, 0], [10, -10, 0], [10, 10, 0], [-10, 10, 0]],
            triangles: [[0, 1, 2], [0, 2, 3]], edges: [[-10, -10, 0, 10, -10, 0]],
            bounds: [-10, -10, 0, 10, 10, 0], volume: 1, area: 400, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-navigation-test",
            triangleSolids: [0, 0], edgeSolids: [0])
        view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        view.layout()
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        return view
    }

    @MainActor
    private func geometry(_ name: String, in view: CADSceneView) throws -> SCNGeometry {
        try XCTUnwrap(view.scene.rootNode.childNode(withName: name, recursively: true)?.geometry)
    }

    @MainActor
    private func projectedOrigin(in view: CADSceneView) throws -> SIMD2<Double> {
        let node = try XCTUnwrap(view.pointOfView)
        let camera = try XCTUnwrap(node.camera)
        // Project from the actual SceneKit camera state and its
        // viewport-specific projection to verify input synchronously.
        let projection = simd_float4x4(camera.projectionTransform(withViewportSize: view.bounds.size))
        let clip = projection * simd_inverse(node.simdWorldTransform) * SIMD4<Float>(0, 0, 0, 1)
        XCTAssertGreaterThan(abs(clip.w), 1e-6)
        return SIMD2((Double(clip.x / clip.w) * 0.5 + 0.5) * Double(view.bounds.width),
                     (Double(clip.y / clip.w) * 0.5 + 0.5) * Double(view.bounds.height))
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    private func matrixDifference(_ first: simd_float4x4, _ second: simd_float4x4) -> Float {
        (0..<4).reduce(0) { total, column in total + simd_length(first[column] - second[column]) }
    }

    private func assertCameraBasisEqual(_ actual: simd_float4x4, _ expected: simd_float4x4,
                                        file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<3 {
            for row in 0..<4 { XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 1e-5, file: file, line: line) }
        }
    }

    private func assertMatrixEqual(_ actual: simd_float4x4, _ expected: simd_float4x4, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            for row in 0..<4 { XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 1e-4, message, file: file, line: line) }
        }
    }
}
