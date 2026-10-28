import AppKit
import SceneKit
import XCTest
@testable import LAD

final class CameraProjectionTests: XCTestCase {
    @MainActor
    func testProjectionSwitchMatchesSceneKitScaleAndRestoresPerspective() throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
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
}
