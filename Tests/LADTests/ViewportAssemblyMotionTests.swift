import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportAssemblyMotionTests: XCTestCase {
    private let vertex = CADFeatureID(kind: .vertex, solidIndex: 1, localIndex: 0)
    private let edge = CADFeatureID(kind: .edge, solidIndex: 1, localIndex: 0)
    private let face = CADFeatureID(kind: .face, solidIndex: 1, localIndex: 0)
    private let moved: [Double] = [0, -1, 0, 3, 1, 0, 0, -2, 0, 0, 1, 0, 0, 0, 0, 1]

    func testRigidBoundaryRejectsScaleReflectionAndNonfiniteMatrices() throws {
        let matrix = try XCTUnwrap(ViewportRigidTransform.matrix(moved))
        XCTAssertEqual(matrix * SIMD4(2, -4, 0, 1), SIMD4(7, 0, 0, 1))
        XCTAssertEqual(ViewportRigidTransform.bounds([2, -4, 0, 10, 4, 0], matrix: matrix), [-1, 0, 0, 7, 8, 0])
        let quarterTurn = [0.0, -1, 0, 3, 1, 0, 0, -2, 0, 0, 1, 1, 0, 0, 0, 1]
        XCTAssertEqual(ViewportRigidTransform.bounds([2, -4, 0, 10, 4, 0],
            matrix: try XCTUnwrap(ViewportRigidTransform.matrix(quarterTurn))), [-1, 0, 1, 7, 8, 1])
        for (index, value) in [(0, 2.0), (0, -1.0), (3, Double.nan), (12, 1.0), (15, 0.0)] {
            var invalid = moved
            invalid[index] = value
            XCTAssertNil(ViewportRigidTransform.matrix(invalid))
        }
        XCTAssertNil(ViewportRigidTransform.matrix(Array(moved.dropLast())))
    }

    @MainActor
    func testMotionPreservesPreparedBuffersCameraAndAllHighlightPoses() async throws {
        let view = try makeView()
        let preview = mesh()
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [1], hiddenSolids: [], selectedFeatures: [face, edge, vertex])
        try await ready(view)
        let surface = try node("solid:1", in: view)
        let ordinaryEdges = try node("edges:1", in: view)
        let featureFace = try node("feature:face:1:0", in: view)
        let featureEdge = try node("feature:edge:1:0", in: view)
        let featureVertex = try node("feature:vertex:1:0", in: view)
        let geometry = try XCTUnwrap(surface.geometry)
        let material = try XCTUnwrap(geometry.firstMaterial)
        let edgeGeometry = ordinaryEdges.geometry
        let camera = try XCTUnwrap(view.pointOfView).simdTransform
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [1], hiddenSolids: [], selectedFeatures: [face, edge, vertex], solidTransforms: [1: moved])
        XCTAssertFalse(view.isPreparingResources, "Moving rigid parts must reuse their uploaded drawing resources.")
        XCTAssertTrue(surface.geometry === geometry)
        XCTAssertTrue(surface.geometry?.firstMaterial === material)
        XCTAssertTrue(ordinaryEdges.geometry === edgeGeometry)
        XCTAssertEqual(try XCTUnwrap(view.pointOfView).simdTransform, camera)
        for node in [surface, ordinaryEdges, featureFace, featureEdge, featureVertex] {
            XCTAssertEqual(node.simdTransform.columns.3, SIMD4(3, -2, 0, 1))
        }
        for index in 0..<2 {
            XCTAssertEqual(try node(CADHighlightTechnique.silhouetteNodeName(index), in: view).simdTransform.columns.3,
                           SIMD4(3, -2, 0, 1), "Part and face DRAW_NODE masks must use the body's current pose.")
        }
        XCTAssertEqual(try node("solid:0", in: view).simdTransform, matrix_identity_float4x4)
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [1], hiddenSolids: [], selectedFeatures: [face, edge, vertex])
        XCTAssertEqual(surface.simdTransform, matrix_identity_float4x4, "Clearing a pose restores the built geometry.")
        XCTAssertTrue(surface.geometry === geometry)
    }

    @MainActor
    func testPickingAndIndependentCaptureFollowMotionInBothProjections() async throws {
        for projection in ViewportProjectionMode.allCases {
            let view = try makeView()
            let preview = mesh()
            view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                        selectedSolids: [], hiddenSolids: [], projection: projection)
            try await ready(view)
            let oldVertex = projected([2, -4, 0], in: view)
            XCTAssertEqual(view.feature(at: oldVertex), vertex)
            let before = try await CADAgentRenderer.capturePNG(view: view)
            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: projection, solidTransforms: [1: moved])
            XCTAssertNotEqual(view.feature(at: oldVertex), vertex)
            XCTAssertEqual(view.feature(at: projected([7, 0, 0], in: view)), vertex)
            XCTAssertEqual(view.feature(at: projected([7, 4, 0], in: view)), edge)
            XCTAssertEqual(view.feature(at: projected([3, 4, 0], in: view)), face)
            let captured = try await CADAgentRenderer.captureWithMetadata(view: view)
            XCTAssertNotEqual(captured.png, before, "A detached capture must clone the current body poses.")
            let poses = try XCTUnwrap(captured.metadata["solidTransforms"] as? [[String: Any]])
            XCTAssertEqual(poses.count, 1)
            XCTAssertEqual(poses[0]["solid"] as? Int, 1)
            XCTAssertEqual(poses[0]["matrix"] as? [Double], moved)
            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [1], projection: projection, solidTransforms: [1: moved])
            XCTAssertNil(view.feature(at: projected([7, 0, 0], in: view)))
        }
    }

    @MainActor
    func testIndependentPosedRenderFitsTheVisiblePart() async throws {
        var preview = mesh()
        preview.assemblyPose = AssemblyPose(positions: [:], solidTransforms: [1: moved])
        let captured = try await CADAgentRenderer.renderWithMetadata(preview: preview, view: "top",
            projection: .isometric, hiddenSolids: [0], width: 320, height: 240)
        let target = try XCTUnwrap(captured.metadata["cameraTarget"] as? [Double])
        XCTAssertEqual(target, [3, 4, 0], "Independent images should fit the visible posed body, excluding hidden bodies.")
    }

    @MainActor
    func testMotionAfterIdleProducesFreshLiveFramesAndReturnsToIdle() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for live assembly motion.") }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        _ = app.setActivationPolicy(.regular)
        defer { _ = app.setActivationPolicy(policy) }
        app.finishLaunching()
        let view = try makeView()
        let frames = AssemblyMotionFrameCounter()
        view.delegate = frames
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD assembly motion test"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.delegate = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let preview = mesh()
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [])
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        try await ready(view)
        try await waitUntil { frames.count > 0 }
        try await idle(view, frames: frames)
        let previous = frames.count
        let camera = try XCTUnwrap(view.pointOfView).simdTransform
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidTransforms: [1: moved])
        try await waitUntil { frames.count > previous }
        try await idle(view, frames: frames)
        XCTAssertEqual(try XCTUnwrap(view.pointOfView).simdTransform, camera)
        XCTAssertFalse(view.rendersContinuously)
        let idleCount = frames.count
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidTransforms: [1: moved])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(view.isPlaying, "An unchanged pose must not wake SceneKit again.")
        XCTAssertEqual(frames.count, idleCount)
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CADSceneView(frame: NSRect(x: 50, y: 50, width: 640, height: 480), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
    }

    @MainActor
    private func ready(_ view: CADSceneView) async throws {
        try await waitUntil { !view.isPreparingCaptureResources }
    }

    @MainActor
    private func idle(_ view: CADSceneView, frames: AssemblyMotionFrameCounter) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var previous = frames.count
        var lastChange = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            let current = frames.count
            if current != previous { previous = current; lastChange = ContinuousClock.now }
            if !view.isPlaying, ContinuousClock.now - lastChange >= .milliseconds(250) { return }
        }
        XCTFail("The moving assembly viewport should become idle after rendering its latest pose.")
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    @MainActor
    private func projected(_ point: [Double], in view: CADSceneView) -> NSPoint {
        let value = view.projectPoint(SCNVector3(point[0], point[1], point[2]))
        return NSPoint(x: CGFloat(value.x), y: CGFloat(value.y))
    }

    @MainActor
    private func node(_ name: String, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene?.rootNode.childNode(withName: name, recursively: true))
    }

    private func mesh() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-10, -4, 0], [-2, -4, 0], [-2, 4, 0], [-10, 4, 0],
                                           [2, -4, 0], [10, -4, 0], [10, 4, 0], [2, 4, 0]],
            triangles: [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]],
            edges: [[-10, -4, 0, -2, -4, 0], [2, -4, 0, 10, -4, 0]],
            bounds: [-10, -4, 0, 10, 4, 0], volume: 1, area: 128, solids: 2, faces: 2,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-assembly-motion", triangleSolids: [0, 0, 1, 1], edgeSolids: [0, 1])
        preview.topology = CADTopology(vertices: [CADVertex(id: vertex, position: [2, -4, 0])],
            edges: [CADEdge(id: edge, type: "LINE", length: 8, polyline: [[2, -4, 0], [10, -4, 0]])],
            faces: [CADFace(id: .init(kind: .face, solidIndex: 0, localIndex: 0), type: "PLANE", area: 64, center: [-6, 0, 0], normal: [0, 0, 1]),
                    CADFace(id: face, type: "PLANE", area: 64, center: [6, 0, 0], normal: [0, 0, 1])], parts: [])
        preview.triangleFaces = [0, 0, 1, 1]
        preview.edgeFeatures = [0, 0]
        return preview
    }
}

private final class AssemblyMotionFrameCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); value += 1; lock.unlock()
    }
}
