import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportOrientationCubeIntegrationTests: XCTestCase {
    @MainActor
    func testAllFacesAndEightCornersRefitAfterPanAndZoomPreservingProjectionAndDrawingResources() async throws {
        for projection in ViewportProjectionMode.allCases {
            let (view, preview) = try await readyView(projection: projection, offset: SIMD3(146, -91, 1))
            let before = view.agentCaptureMetadata
            let target = try XCTUnwrap(before["cameraTarget"] as? [Double])
            let distance = try XCTUnwrap(before["cameraDistance"] as? Double)
            let scale = try XCTUnwrap(before["orthographicScale"] as? Double)
            XCTAssertEqual(target, [146, -91, 1])
            let solid = try geometry("solid:0", in: view)
            let edges = try geometry("edges:0", in: view)
            var selectionChanges = 0
            view.onSelectionChanged = { _ in selectionChanges += 1 }
            view.onFeatureSelectionChanged = { _ in selectionChanges += 1 }

            func navigateAwayFromFit() throws {
                view.otherMouseDown(with: try mouse(.otherMouseDown, at: NSPoint(x: 200, y: 150), in: view))
                view.otherMouseDragged(with: try mouse(.otherMouseDragged, at: NSPoint(x: 225, y: 163), in: view))
                view.otherMouseUp(with: try mouse(.otherMouseUp, at: NSPoint(x: 225, y: 163), in: view))
                let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                  wheel1: -60, wheel2: 0, wheel3: 0))
                scroll.location = CGPoint(x: 200, y: 150)
                view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
                XCTAssertNotEqual(view.agentCaptureMetadata["cameraTarget"] as? [Double], target)
                XCTAssertGreaterThan(try XCTUnwrap(view.agentCaptureMetadata["cameraDistance"] as? Double), distance)
            }

            func checkSnap(_ expected: SIMD3<Double>) throws {
                let orientation = view.cameraOrientation
                assertVectorEqual(orientation.backward, expected, accuracy: 0.00002)
                assertOrthonormal(orientation.right, orientation.up, orientation.backward)
                let after = view.agentCaptureMetadata
                XCTAssertEqual(after["cameraTarget"] as? [Double], target)
                XCTAssertEqual(try XCTUnwrap(after["cameraDistance"] as? Double), distance, accuracy: 1e-8)
                XCTAssertEqual(try XCTUnwrap(after["orthographicScale"] as? Double), scale, accuracy: 1e-8)
                XCTAssertEqual(view.pointOfView?.camera?.usesOrthographicProjection, projection == .isometric)
                XCTAssertTrue(try geometry("solid:0", in: view) === solid)
                XCTAssertTrue(try geometry("edges:0", in: view) === edges)
                XCTAssertFalse(view.isPreparingResources)
                let cameraNode = try XCTUnwrap(view.pointOfView)
                let camera = try XCTUnwrap(cameraNode.camera)
                // Read the current camera directly; SCNView.projectPoint can
                // retain its last rendered state while the viewport is idle.
                let projectionMatrix = simd_float4x4(camera.projectionTransform(withViewportSize: view.bounds.size))
                let transform = projectionMatrix * simd_inverse(cameraNode.simdWorldTransform)
                for vertex in preview.vertices {
                    let clip = transform * SIMD4(Float(vertex[0]), Float(vertex[1]), Float(vertex[2]), 1)
                    XCTAssertGreaterThan(clip.w, 0)
                    XCTAssertGreaterThan(clip.x / clip.w, -1, "A cube click must fit the complete design in the viewport.")
                    XCTAssertLessThan(clip.x / clip.w, 1)
                    XCTAssertGreaterThan(clip.y / clip.w, -1)
                    XCTAssertLessThan(clip.y / clip.w, 1)
                }
            }
            for face in ViewportCubeFace.allCases {
                try navigateAwayFromFit()
                view.selectOrientationCubeFace(face)
                try checkSnap(expectedBackward(face))
            }
            XCTAssertEqual(ViewportCubeCorner.allCases.count, 8)
            var octants = Set<String>()
            for corner in ViewportCubeCorner.allCases {
                try navigateAwayFromFit()
                view.selectOrientationCubeCorner(corner)
                try checkSnap(corner.direction)
                let direction = view.cameraOrientation.backward
                for coordinate in [direction.x, direction.y, direction.z] {
                    XCTAssertEqual(abs(coordinate), 1 / sqrt(3), accuracy: 1e-6,
                                   "A corner must select an isometric direction, including lower views.")
                }
                octants.insert([direction.x, direction.y, direction.z].map { $0 > 0 ? "+" : "-" }.joined())
            }
            XCTAssertEqual(octants.count, 8, "Every physical cube corner must select its own isometric octant.")
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
    func testCubeDraggingLeavesCameraSelectionAndDrawingResourcesUnchanged() async throws {
        for projection in ViewportProjectionMode.allCases {
            let (view, _) = try await readyView(projection: projection)
            let cube = ViewportOrientationCube(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
            bind(cube, to: view)
            let solid = try geometry("solid:0", in: view)
            let edges = try geometry("edges:0", in: view)
            let sources = edges.sources
            var selectionChanges = 0
            view.onSelectionChanged = { _ in selectionChanges += 1 }
            view.onFeatureSelectionChanged = { _ in selectionChanges += 1 }
            let before = try XCTUnwrap(view.pointOfView).simdTransform
            let start = try XCTUnwrap(cube.projectedTargetCenters.first { target, _ in
                if case .face = target { return true }
                return false
            }).value
            cube.mouseDown(with: try mouse(.leftMouseDown, at: start, in: cube))
            let drag = try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 20, y: start.y + 10), in: cube)
            XCTAssertEqual(drag.deltaX, 0)
            XCTAssertEqual(drag.deltaY, 0)
            cube.mouseDragged(with: drag)
            cube.mouseDragged(with: try mouse(.leftMouseDragged, at: start, in: cube))
            cube.mouseUp(with: try mouse(.leftMouseUp, at: start, in: cube))
            assertMatrixEqual(try XCTUnwrap(view.pointOfView).simdTransform, before)
            XCTAssertTrue(try geometry("solid:0", in: view) === solid)
            XCTAssertTrue(try geometry("edges:0", in: view) === edges)
            for (before, after) in zip(sources, edges.sources) { XCTAssertTrue(before === after) }
            XCTAssertEqual(selectionChanges, 0)
            XCTAssertFalse(view.isPreparingResources)
            XCTAssertFalse(view.rendersContinuously)
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
    func testLiveFaceFlipAndCornerClicksWakeAnIdleViewportWhileDraggingDoesNot() async throws {
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
        bind(cube, to: view)
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

        let beforeDrag = frames.count
        let initialCamera = try XCTUnwrap(view.pointOfView).simdTransform
        let start = try XCTUnwrap(cube.projectedTargetCenters.first { target, _ in
            if case .face = target { return true }
            return false
        }).value
        cube.mouseDown(with: try mouse(.leftMouseDown, at: start, in: cube))
        cube.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 20, y: start.y + 15), in: cube))
        cube.mouseUp(with: try mouse(.leftMouseUp, at: start, in: cube))
        try await Task.sleep(for: .milliseconds(300))
        assertMatrixEqual(try XCTUnwrap(view.pointOfView).simdTransform, initialCamera)
        XCTAssertEqual(frames.count, beforeDrag, "Dragging the cube must not wake viewport rendering.")
        XCTAssertFalse(view.rendersContinuously)

        let targetKinds: [(ViewportCubeTarget) -> Bool] = [
            { if case .face = $0 { return true }; return false },
            { if case .oppositeFace = $0 { return true }; return false },
            { if case .corner = $0 { return true }; return false }
        ]
        for matches in targetKinds {
            let (target, point) = try XCTUnwrap(cube.projectedTargetCenters.first { matches($0.key) })
            XCTAssertEqual(cube.hitTarget(at: point), target)
            let beforeSnap = frames.count
            let beforeCamera = try XCTUnwrap(view.pointOfView).simdTransform
            cube.mouseDown(with: try mouse(.leftMouseDown, at: point, in: cube))
            cube.mouseUp(with: try mouse(.leftMouseUp, at: point, in: cube))
            guard try await waitForFrame(frames, after: beforeSnap), try await waitForIdle(view, frames: frames) else { return }
            assertVectorEqual(view.cameraOrientation.backward, expectedBackward(target), accuracy: 0.00002)
            XCTAssertGreaterThan(matrixDifference(beforeCamera, try XCTUnwrap(view.pointOfView).simdTransform), 0.1)
            XCTAssertFalse(view.rendersContinuously, "Every cube target must retain bounded viewport redraw bursts.")
        }
    }

    @MainActor
    private func bind(_ cube: ViewportOrientationCube, to view: CADSceneView) {
        cube.onSelectFace = { [weak view] in view?.selectOrientationCubeFace($0) }
        cube.onSelectCorner = { [weak view] in view?.selectOrientationCubeCorner($0) }
        view.onCameraOrientationChanged = { [weak cube] in cube?.setOrientation(right: $0, up: $1, backward: $2) }
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
    private func readyView(projection: ViewportProjectionMode = .perspective,
                           offset: SIMD3<Double> = .zero) async throws -> (CADSceneView, PreviewMesh) {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        var preview = box()
        preview.vertices = preview.vertices.map { vertex in
            (0..<3).map { vertex[$0] + offset[$0] }
        }
        preview.edges = preview.edges.map { edge in
            edge.indices.map { edge[$0] + offset[$0 % 3] }
        }
        preview.bounds = preview.bounds.indices.map { preview.bounds[$0] + offset[$0 % 3] }
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

    private func expectedBackward(_ target: ViewportCubeTarget) -> SIMD3<Double> {
        switch target {
        case .face(let face): return expectedBackward(face)
        case .oppositeFace(let face): return -expectedBackward(face)
        case .corner(let corner): return corner.direction
        }
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
