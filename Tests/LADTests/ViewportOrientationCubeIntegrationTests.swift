import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportOrientationCubeIntegrationTests: XCTestCase {
    @MainActor
    func testAllSixFacesSnapWithoutChangingPanZoomProjectionOrDrawingResources() async throws {
        for projection in ViewportProjectionMode.allCases {
            let (view, preview) = try await readyView(projection: projection)
            view.otherMouseDown(with: try mouse(.otherMouseDown, at: NSPoint(x: 200, y: 150), in: view))
            view.otherMouseDragged(with: try mouse(.otherMouseDragged, at: NSPoint(x: 225, y: 163), in: view))
            view.otherMouseUp(with: try mouse(.otherMouseUp, at: NSPoint(x: 225, y: 163), in: view))
            let before = view.agentCaptureMetadata
            let target = try XCTUnwrap(before["cameraTarget"] as? [Double])
            let distance = try XCTUnwrap(before["cameraDistance"] as? Double)
            let scale = try XCTUnwrap(before["orthographicScale"] as? Double)
            let solid = try geometry("solid:0", in: view)
            let edges = try geometry("edges:0", in: view)
            var selectionChanges = 0
            view.onSelectionChanged = { _ in selectionChanges += 1 }
            view.onFeatureSelectionChanged = { _ in selectionChanges += 1 }

            for face in ViewportCubeFace.allCases {
                view.selectOrientationCubeFace(face)
                let orientation = view.cameraOrientation
                assertVectorEqual(orientation.backward, expectedBackward(face), accuracy: 0.00002)
                assertOrthonormal(orientation.right, orientation.up, orientation.backward)
                let after = view.agentCaptureMetadata
                XCTAssertEqual(after["cameraTarget"] as? [Double], target)
                XCTAssertEqual(try XCTUnwrap(after["cameraDistance"] as? Double), distance, accuracy: 1e-8)
                XCTAssertEqual(try XCTUnwrap(after["orthographicScale"] as? Double), scale, accuracy: 1e-8)
                XCTAssertEqual(view.pointOfView?.camera?.usesOrthographicProjection, projection == .isometric)
                XCTAssertTrue(try geometry("solid:0", in: view) === solid)
                XCTAssertTrue(try geometry("edges:0", in: view) === edges)
                XCTAssertFalse(view.isPreparingResources)
            }
            XCTAssertEqual(selectionChanges, 0)
            // A later ordinary update must retain the cube's camera instead
            // of replaying an unrelated old toolbar command or fitting again.
            let snapped = try XCTUnwrap(view.pointOfView).simdTransform
            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: projection)
            assertMatrixEqual(try XCTUnwrap(view.pointOfView).simdTransform, snapped)
        }
    }

    @MainActor
    func testCubeOrbitMatchesViewportPointerNavigationWithoutSelectingOrRebuilding() async throws {
        for projection in ViewportProjectionMode.allCases {
            let (cubeView, _) = try await readyView(projection: projection)
            let (viewportView, _) = try await readyView(projection: projection)
            let solid = try geometry("solid:0", in: cubeView)
            let edges = try geometry("edges:0", in: cubeView)
            let sources = edges.sources
            let distance = try XCTUnwrap(cubeView.agentCaptureMetadata["cameraDistance"] as? Double)
            var selectionChanges = 0
            cubeView.onSelectionChanged = { _ in selectionChanges += 1 }
            cubeView.onFeatureSelectionChanged = { _ in selectionChanges += 1 }
            let before = try XCTUnwrap(cubeView.pointOfView).simdTransform

            cubeView.orbitFromOrientationCube(dx: 20, dy: 10)
            cubeView.orbitFromOrientationCube(dx: 25, dy: 5)
            viewportView.rightMouseDown(with: try mouse(.rightMouseDown, at: NSPoint(x: 200, y: 150), in: viewportView))
            viewportView.rightMouseDragged(with: try mouse(.rightMouseDragged, at: NSPoint(x: 220, y: 160), in: viewportView))
            viewportView.rightMouseDragged(with: try mouse(.rightMouseDragged, at: NSPoint(x: 245, y: 165), in: viewportView))
            viewportView.rightMouseUp(with: try mouse(.rightMouseUp, at: NSPoint(x: 245, y: 165), in: viewportView))
            let after = try XCTUnwrap(cubeView.pointOfView).simdTransform
            assertMatrixEqual(after, try XCTUnwrap(viewportView.pointOfView).simdTransform)
            XCTAssertGreaterThan(matrixDifference(before, after), 0.1)
            XCTAssertEqual(try XCTUnwrap(cubeView.agentCaptureMetadata["cameraDistance"] as? Double), distance, accuracy: 1e-8)
            XCTAssertTrue(try geometry("solid:0", in: cubeView) === solid)
            XCTAssertTrue(try geometry("edges:0", in: cubeView) === edges)
            for (before, after) in zip(sources, edges.sources) { XCTAssertTrue(before === after) }
            XCTAssertEqual(selectionChanges, 0)
            XCTAssertFalse(cubeView.isPreparingResources)
        }
    }

    @MainActor
    func testOrientationObservationStartsCurrentAndTracksEveryNavigationPath() async throws {
        let (view, preview) = try await readyView()
        var updates = [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]()
        view.onCameraOrientationChanged = { updates.append(($0, $1, $2)) }
        XCTAssertEqual(updates.count, 1, "Connecting the cube must immediately supply the existing view orientation.")
        try assertLastUpdate(updates, matches: view)

        var previous = updates.count
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.back),
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertGreaterThan(updates.count, previous)
        try assertLastUpdate(updates, matches: view)
        assertVectorEqual(view.cameraOrientation.backward, SIMD3(0, 1, 0))

        previous = updates.count
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        view.keyDown(with: key)
        XCTAssertGreaterThan(updates.count, previous)
        try assertLastUpdate(updates, matches: view)
        assertVectorEqual(view.cameraOrientation.backward, SIMD3(0, 0, 1), accuracy: 0.00002)

        previous = updates.count
        view.rightMouseDown(with: try mouse(.rightMouseDown, at: NSPoint(x: 200, y: 150), in: view))
        view.rightMouseDragged(with: try mouse(.rightMouseDragged, at: NSPoint(x: 220, y: 170), in: view))
        view.rightMouseUp(with: try mouse(.rightMouseUp, at: NSPoint(x: 220, y: 170), in: view))
        XCTAssertGreaterThan(updates.count, previous)
        try assertLastUpdate(updates, matches: view)

        previous = updates.count
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        XCTAssertGreaterThan(updates.count, previous)
        try assertLastUpdate(updates, matches: view)
        XCTAssertEqual(view.pointOfView?.camera?.usesOrthographicProjection, true)
    }

    @MainActor
    func testLiveCubeDragAndFaceClickWakeAnIdleViewportAndThenPause() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for live viewport drawing.") }
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        defer { _ = application.setActivationPolicy(previousPolicy) }
        application.finishLaunching()
        let (view, _) = try await readyView()
        let frames = CubeViewportRenderCounter()
        view.delegate = frames
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        let cube = ViewportOrientationCube(frame: NSRect(x: 380, y: 258, width: 92, height: 92))
        container.addSubview(cube)
        cube.onOrbit = { [weak view] in view?.orbitFromOrientationCube(dx: $0, dy: $1) }
        cube.onSelectFace = { [weak view] in view?.selectOrientationCubeFace($0) }
        view.onCameraOrientationChanged = { [weak cube] in cube?.setOrientation(right: $0, up: $1, backward: $2) }
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD orientation cube test"
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer {
            view.delegate = nil
            view.onCameraOrientationChanged = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        guard try await waitForFrame(frames, after: 0), try await waitForIdle(view, frames: frames) else { return }

        let probe = SCNVector3(3, 2, 1)
        let beforeOrbit = view.projectPoint(probe)
        let beforeDrag = frames.count
        let start = NSPoint(x: 46, y: 46)
        cube.mouseDown(with: try mouse(.leftMouseDown, at: start, in: cube))
        let drag = try mouse(.leftMouseDragged, at: NSPoint(x: 66, y: 61), in: cube)
        XCTAssertEqual(drag.deltaX, 0)
        XCTAssertEqual(drag.deltaY, 0)
        cube.mouseDragged(with: drag)
        cube.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 66, y: 61), in: cube))
        guard try await waitForFrame(frames, after: beforeDrag), try await waitForIdle(view, frames: frames) else { return }
        let afterOrbit = view.projectPoint(probe)
        XCTAssertGreaterThan(hypot(Double(afterOrbit.x - beforeOrbit.x), Double(afterOrbit.y - beforeOrbit.y)), 5,
                             "Dragging the cube must change the live viewport's rendered camera.")

        let face = try XCTUnwrap(cube.projectedFaces.last)
        XCTAssertEqual(cube.face(at: face.center), face.direction)
        let beforeSnap = frames.count
        cube.mouseDown(with: try mouse(.leftMouseDown, at: face.center, in: cube))
        cube.mouseUp(with: try mouse(.leftMouseUp, at: face.center, in: cube))
        guard try await waitForFrame(frames, after: beforeSnap), try await waitForIdle(view, frames: frames) else { return }
        assertVectorEqual(view.cameraOrientation.backward, expectedBackward(face.direction), accuracy: 0.00002)
        XCTAssertEqual(cube.projectedFaces.last?.direction, face.direction,
                       "The displayed cube must follow the snapped viewport camera.")
        XCTAssertFalse(view.rendersContinuously, "The orientation cube must retain bounded viewport redraw bursts.")
    }

    @MainActor
    private func waitForFrame(_ frames: CubeViewportRenderCounter, after previous: Int) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while frames.count <= previous, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard frames.count > previous else {
            XCTFail("An orientation cube interaction must produce a fresh frame in the live viewport.")
            return false
        }
        return true
    }

    @MainActor
    private func waitForIdle(_ view: CADSceneView, frames: CubeViewportRenderCounter) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        var previous = frames.count
        var lastChange = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            let current = frames.count
            if current != previous { previous = current; lastChange = ContinuousClock.now }
            if !view.rendersContinuously, ContinuousClock.now - lastChange >= .milliseconds(250) { return true }
        }
        XCTFail("A completed orientation cube redraw must become idle.")
        return false
    }

    @MainActor
    private func readyView(projection: ViewportProjectionMode = .perspective) async throws -> (CADSceneView, PreviewMesh) {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let preview = box()
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: projection)
        view.layout()
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        return (view, preview)
    }

    @MainActor
    private func assertLastUpdate(_ updates: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)], matches view: CADSceneView,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let update = try XCTUnwrap(updates.last, file: file, line: line)
        let orientation = view.cameraOrientation
        assertVectorEqual(update.0, orientation.right, file: file, line: line)
        assertVectorEqual(update.1, orientation.up, file: file, line: line)
        assertVectorEqual(update.2, orientation.backward, file: file, line: line)
        let transform = try XCTUnwrap(view.pointOfView, file: file, line: line).simdTransform
        assertVectorEqual(update.0, SIMD3<Double>(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)), accuracy: 1e-6, file: file, line: line)
        assertVectorEqual(update.1, SIMD3<Double>(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)), accuracy: 1e-6, file: file, line: line)
        assertVectorEqual(update.2, SIMD3<Double>(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)), accuracy: 1e-6, file: file, line: line)
    }

    @MainActor
    private func geometry(_ name: String, in view: CADSceneView) throws -> SCNGeometry {
        try XCTUnwrap(view.scene?.rootNode.childNode(withName: name, recursively: true)?.geometry)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    private func expectedBackward(_ face: ViewportCubeFace) -> SIMD3<Double> {
        switch face {
        case .front: return SIMD3(0, -1, 0)
        case .back: return SIMD3(0, 1, 0)
        case .left: return SIMD3(-1, 0, 0)
        case .right: return SIMD3(1, 0, 0)
        case .top: return SIMD3(0, 0, 1)
        case .bottom: return SIMD3(0, 0, -1)
        }
    }

    private func assertVectorEqual(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>, accuracy: Double = 1e-7,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<3 { XCTAssertEqual(actual[index], expected[index], accuracy: accuracy, file: file, line: line) }
    }

    private func assertOrthonormal(_ right: SIMD3<Double>, _ up: SIMD3<Double>, _ backward: SIMD3<Double>,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for vector in [right, up, backward] {
            XCTAssertTrue(vector.x.isFinite && vector.y.isFinite && vector.z.isFinite, file: file, line: line)
            XCTAssertEqual(simd_length(vector), 1, accuracy: 1e-6, file: file, line: line)
        }
        XCTAssertEqual(simd_dot(right, up), 0, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(simd_dot(right, backward), 0, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(simd_dot(up, backward), 0, accuracy: 1e-6, file: file, line: line)
        assertVectorEqual(simd_cross(right, up), backward, accuracy: 1e-6, file: file, line: line)
    }

    private func assertMatrixEqual(_ actual: simd_float4x4, _ expected: simd_float4x4,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            for row in 0..<4 { XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 1e-5, file: file, line: line) }
        }
    }

    private func matrixDifference(_ first: simd_float4x4, _ second: simd_float4x4) -> Float {
        (0..<4).reduce(0) { $0 + simd_length(first[$1] - second[$1]) }
    }

    private func box() -> PreviewMesh {
        PreviewMesh(vertices: [[-3,-2,-1],[3,-2,-1],[3,2,-1],[-3,2,-1],[-3,-2,1],[3,-2,1],[3,2,1],[-3,2,1]],
            triangles: [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
                        [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]],
            edges: [[-3,-2,-1,3,-2,-1],[3,-2,-1,3,2,-1],[3,2,-1,-3,2,-1],[-3,2,-1,-3,-2,-1],
                    [-3,-2,1,3,-2,1],[3,-2,1,3,2,1],[3,2,1,-3,2,1],[-3,2,1,-3,-2,1]],
            bounds: [-3,-2,-1,3,2,1], volume: 48, area: 88, solids: 1, faces: 6,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/orientation-cube-camera-test",
            triangleSolids: Array(repeating: 0, count: 12), edgeSolids: Array(repeating: 0, count: 8))
    }
}

private final class CubeViewportRenderCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
