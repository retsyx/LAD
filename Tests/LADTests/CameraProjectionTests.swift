import AppKit
import SceneKit
import simd
import XCTest
@testable import LAD

final class CameraProjectionTests: XCTestCase {
    @MainActor
    func testProjectionSwitchMatchesSceneKitScaleAndRestoresPerspective() throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        view.update(mesh: nil, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        let cameraNode = try XCTUnwrap(view.pointOfView)
        let camera = try XCTUnwrap(cameraNode.camera)
        XCTAssertTrue(camera.usesOrthographicProjection)
        let expectedHalfHeight = Double(simd_length(cameraNode.simdPosition)) * tan(Double(camera.fieldOfView) * .pi / 360)
        XCTAssertEqual(camera.orthographicScale, expectedHalfHeight, accuracy: 1e-5)
        let matrix = camera.projectionTransform(withViewportSize: CGSize(width: 960, height: 640))
        XCTAssertEqual(Double(matrix.m22), 1 / expectedHalfHeight, accuracy: 1e-6,
                       "The cursor math must use the same vertical extent as SceneKit.")
        XCTAssertEqual(Double(matrix.m11), 1 / (expectedHalfHeight * 1.5), accuracy: 1e-6)
        let direction = cameraNode.simdWorldFront
        XCTAssertEqual(abs(direction.x), abs(direction.y), accuracy: 1e-6)
        XCTAssertEqual(abs(direction.y), abs(direction.z), accuracy: 1e-6)

        view.update(mesh: nil, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .perspective)
        XCTAssertFalse(camera.usesOrthographicProjection)
        XCTAssertEqual(cameraNode.simdWorldFront, direction, "Changing projection preserves the current orientation.")
    }

    @MainActor
    func testProjectionRoundTripPreservesNavigatedPoseAndTargetPlaneFraming() throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        view.update(mesh: nil, mode: .edges, grid: false, command: ViewportCommand(.front),
                    selectedSolids: [], hiddenSolids: [], projection: .perspective)
        let cameraNode = try XCTUnwrap(view.pointOfView)
        let camera = try XCTUnwrap(cameraNode.camera)
        let initialDistance = try XCTUnwrap(view.agentCaptureMetadata["cameraDistance"] as? Double)

        view.rightMouseDown(with: try event(.rightMouseDown, at: NSPoint(x: 240, y: 200)))
        view.rightMouseDragged(with: try event(.rightMouseDragged, at: NSPoint(x: 297, y: 231)))
        view.rightMouseUp(with: try event(.rightMouseUp, at: NSPoint(x: 297, y: 231)))
        view.otherMouseDown(with: try event(.otherMouseDown, at: NSPoint(x: 300, y: 260)))
        view.otherMouseDragged(with: try event(.otherMouseDragged, at: NSPoint(x: 346, y: 282)))
        view.otherMouseUp(with: try event(.otherMouseUp, at: NSPoint(x: 346, y: 282)))
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: 60, wheel2: 0, wheel3: 0))
        scroll.location = CGPoint(x: 350, y: 290)
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))

        let pose = cameraNode.simdTransform
        let target = try XCTUnwrap(view.agentCaptureMetadata["cameraTarget"] as? [Double])
        let distance = try XCTUnwrap(view.agentCaptureMetadata["cameraDistance"] as? Double)
        XCTAssertLessThan(distance, initialDistance, "The regression must exercise a zoomed camera.")
        XCTAssertGreaterThan(simd_length(SIMD3(target[0], target[1], target[2])), 1,
                             "The regression must exercise a panned camera.")
        let center = SIMD3<Float>(Float(target[0]), Float(target[1]), Float(target[2]))
        let right = SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z)
        let up = SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        let points = [center, center + right * 15, center + up * 15, center + right * 12 + up * 9]
        let framing = points.map { project($0, in: view, cameraNode: cameraNode, camera: camera) }

        for projection in [ViewportProjectionMode.isometric, .perspective] {
            view.update(mesh: nil, mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: projection)
            XCTAssertEqual(camera.usesOrthographicProjection, projection == .isometric)
            for column in 0..<4 {
                for row in 0..<4 {
                    XCTAssertEqual(cameraNode.simdTransform[column][row], pose[column][row], accuracy: 1e-6,
                                   "Switching projection must preserve the full camera pose.")
                }
            }
            XCTAssertEqual(view.agentCaptureMetadata["cameraTarget"] as? [Double], target)
            XCTAssertEqual(view.agentCaptureMetadata["cameraDistance"] as? Double, distance)
            XCTAssertEqual(camera.orthographicScale, distance * tan(Double(camera.fieldOfView) * .pi / 360), accuracy: 1e-9)
            for (point, expected) in zip(points, framing) {
                let actual = project(point, in: view, cameraNode: cameraNode, camera: camera)
                XCTAssertEqual(actual.x, expected.x, accuracy: 0.001, "Target-plane horizontal framing must stay fixed.")
                XCTAssertEqual(actual.y, expected.y, accuracy: 0.001, "Target-plane vertical framing must stay fixed.")
            }
        }
    }

    @MainActor
    func testInitialMeshAppliesSavedOrthographicProjection() throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let preview = PreviewMesh(vertices: [[0, 0, 0], [20, 0, 0], [0, 10, 0]], triangles: [[0, 1, 2]], edges: [],
            bounds: [0, 0, 0, 20, 10, 5], volume: 1, area: 1, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/initial-orthographic-projection")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric)
        let camera = try XCTUnwrap(view.pointOfView?.camera)
        XCTAssertTrue(camera.usesOrthographicProjection)
        let distance = try XCTUnwrap(view.agentCaptureMetadata["cameraDistance"] as? Double)
        XCTAssertEqual(camera.orthographicScale, distance * tan(Double(camera.fieldOfView) * .pi / 360), accuracy: 1e-9)
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func project(_ point: SIMD3<Float>, in view: CADSceneView, cameraNode: SCNNode, camera: SCNCamera) -> SIMD2<Double> {
        // Project with the SceneKit camera itself, independently of the
        // view's own projection.
        let projection = simd_float4x4(camera.projectionTransform(withViewportSize: view.bounds.size))
        let clip = projection * simd_inverse(cameraNode.simdWorldTransform) * SIMD4(point, 1)
        return SIMD2((Double(clip.x / clip.w) * 0.5 + 0.5) * Double(view.bounds.width),
                     (Double(clip.y / clip.w) * 0.5 + 0.5) * Double(view.bounds.height))
    }
}
