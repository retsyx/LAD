import XCTest
import simd
@testable import LAD

final class CADAgentCameraTests: XCTestCase {
    private let bounds = [-10.0, -6, -2, 10, 6, 2]

    func testPresetOnlyCameraPreservesExistingAutomaticFitInBothProjections() throws {
        let presets: [(String, Double, Double)] = [
            ("isometric", -.pi / 4, 0.6154797087), ("front", -.pi / 2, 0),
            ("back", .pi / 2, 0), ("left", .pi, 0), ("right", 0, 0),
            ("top", -.pi / 2, .pi / 2 - 0.00001),
            ("bottom", -.pi / 2, -.pi / 2 + 0.00001)
        ]
        for orthographic in [false, true] {
            for (name, yaw, elevation) in presets {
                var expected = CameraRig()
                expected.usesOrthographicProjection = orthographic
                expected.yaw = yaw; expected.elevation = elevation
                expected.fit(bounds: bounds, width: 800, height: 600)
                let actual = try resolve(CADAgentCamera(), view: name, orthographic: orthographic)
                XCTAssertEqual(actual.rig.yaw, expected.yaw)
                XCTAssertEqual(actual.rig.elevation, expected.elevation)
                XCTAssertEqual(actual.target, expected.target)
                XCTAssertEqual(actual.position, expected.position)
                XCTAssertEqual(actual.right, expected.right)
                XCTAssertEqual(actual.up, expected.up)
                XCTAssertEqual(actual.backward, expected.backward)
                XCTAssertEqual(actual.distance, expected.distance)
                XCTAssertEqual(actual.orthographicScale, expected.orthographicScale)
                try assertBasis(actual)
            }
        }
    }

    func testAngularOverridesUseWorldAxesAndPreserveUnspecifiedPresetAngle() throws {
        let horizontal = try resolve(CADAgentCamera(yawDegrees: 90), view: "right")
        XCTAssertEqual(horizontal.backward.x, 0, accuracy: 1e-12)
        XCTAssertEqual(horizontal.backward.y, 1, accuracy: 1e-12)
        XCTAssertEqual(horizontal.backward.z, 0, accuracy: 1e-12)
        let elevated = try resolve(CADAgentCamera(elevationDegrees: 30), view: "front")
        XCTAssertEqual(elevated.backward.x, 0, accuracy: 1e-12)
        XCTAssertEqual(elevated.backward.y, -cos(.pi / 6), accuracy: 1e-12)
        XCTAssertEqual(elevated.backward.z, 0.5, accuracy: 1e-12)
        let arbitrary = try resolve(CADAgentCamera(yawDegrees: 127.5, elevationDegrees: -23.4,
            target: [100, -20, 12], zoom: 2))
        XCTAssertEqual(arbitrary.target, SIMD3(100, -20, 12))
        XCTAssertEqual(arbitrary.distance, arbitrary.automaticDistance / 2)
        XCTAssertEqual(simd_length(arbitrary.position - arbitrary.target), arbitrary.distance, accuracy: 1e-10)
        try assertBasis(arbitrary)
    }

    func testExplicitPositionAndRelativePerspectiveZoomKeepTargetFixed() throws {
        let eye = SIMD3<Double>(37, -28, 19)
        let target = SIMD3<Double>(7, 2, 4)
        for zoom in [0.5, 1.0, 2, 7] {
            let actual = try resolve(CADAgentCamera(position: [eye.x, eye.y, eye.z],
                target: [target.x, target.y, target.z], zoom: zoom))
            let expected = target + (eye - target) / zoom
            XCTAssertEqual(actual.target, target)
            XCTAssertEqual(simd_length(actual.position - expected), 0, accuracy: 1e-12)
            XCTAssertEqual(actual.distance, simd_length(eye - target) / zoom, accuracy: 1e-12)
            XCTAssertEqual(simd_dot(actual.backward, simd_normalize(eye - target)), 1, accuracy: 1e-12)
            try assertBasis(actual)
        }
    }

    func testOrthographicZoomChangesMagnificationWithoutMovingEyeIntoGeometry() throws {
        let fitted = try resolve(CADAgentCamera(), orthographic: true)
        let magnified = try resolve(CADAgentCamera(zoom: 20), orthographic: true)
        XCTAssertEqual(magnified.position, fitted.position)
        XCTAssertEqual(magnified.distance, fitted.distance)
        XCTAssertEqual(magnified.orthographicScale, fitted.orthographicScale / 20, accuracy: 1e-12)
        let positioned = try resolve(CADAgentCamera(position: [30, -20, 10], target: [0, 0, 0], zoom: 4), orthographic: true)
        XCTAssertEqual(simd_length(positioned.position - SIMD3(30, -20, 10)), 0, accuracy: 1e-12)
        XCTAssertEqual(positioned.orthographicScale, simd_length(SIMD3<Double>(30, -20, 10)) * CameraRig().tangent / 4, accuracy: 1e-12)
    }

    func testPositiveRollTurnsImageCounterclockwiseWithoutChangingViewDirectionOrFraming() throws {
        let baseline = try resolve(CADAgentCamera(yawDegrees: 34, elevationDegrees: 27))
        let rolled = try resolve(CADAgentCamera(yawDegrees: 34, elevationDegrees: 27, rollDegrees: 90))
        XCTAssertEqual(simd_length(rolled.right + baseline.up), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_length(rolled.up - baseline.right), 0, accuracy: 1e-12)
        XCTAssertEqual(rolled.position, baseline.position)
        XCTAssertEqual(rolled.backward, baseline.backward)
        XCTAssertEqual(rolled.orthographicScale, baseline.orthographicScale)
        // A point originally to the right appears above the target after +90°.
        XCTAssertEqual(simd_dot(baseline.right, rolled.right), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(baseline.right, rolled.up), 1, accuracy: 1e-12)
        try assertBasis(rolled)
    }

    func testExactPoleViewsAndHugeFiniteAnglesHaveStableOrthonormalFrames() throws {
        for elevation in [-90.0, 90] {
            for yaw in [0.0, 42.3, 180] {
                let pose = try resolve(CADAgentCamera(yawDegrees: yaw, elevationDegrees: elevation, rollDegrees: 43))
                XCTAssertEqual(pose.backward.z, elevation < 0 ? -1 : 1, accuracy: 1e-12)
                try assertBasis(pose)
            }
            let positioned = try resolve(CADAgentCamera(position: [0, 0, elevation], target: [0, 0, 0]))
            try assertBasis(positioned)
        }
        try assertBasis(resolve(CADAgentCamera(yawDegrees: 1e300, rollDegrees: -1e300)))
    }

    func testInvalidAnglesZoomCoordinatesAndConflictingModesFailExplicitly() throws {
        let invalid = [
            CADAgentCamera(yawDegrees: .nan), CADAgentCamera(yawDegrees: .infinity),
            CADAgentCamera(elevationDegrees: -90.1), CADAgentCamera(elevationDegrees: 90.1),
            CADAgentCamera(rollDegrees: .infinity), CADAgentCamera(zoom: 0),
            CADAgentCamera(zoom: -1), CADAgentCamera(zoom: .nan), CADAgentCamera(zoom: .infinity),
            CADAgentCamera(zoom: 0.0000001), CADAgentCamera(zoom: 10_000_000),
            CADAgentCamera(position: []), CADAgentCamera(position: [0, 1]),
            CADAgentCamera(position: [0, 1, .nan]), CADAgentCamera(target: [0, .infinity, 1]),
            CADAgentCamera(target: [0, 1_000_001, 0]),
            CADAgentCamera(yawDegrees: 0, position: [10, 10, 10]),
            CADAgentCamera(elevationDegrees: 0, position: [10, 10, 10]),
            CADAgentCamera(position: [1, 2, 3], target: [1, 2, 3])
        ]
        for camera in invalid { XCTAssertThrowsError(try camera.validate()) }
        XCTAssertThrowsError(try resolve(CADAgentCamera(), view: "unknown"))
        XCTAssertThrowsError(try CADAgentCamera().resolved(view: "front", bounds: [], width: 800, height: 600, orthographic: false))
        XCTAssertThrowsError(try CADAgentCamera().resolved(view: "front", bounds: bounds, width: 0, height: 600, orthographic: false))
    }

    func testDefaultTargetAndRenderingPrecisionCannotProduceDegenerateCamera() throws {
        XCTAssertThrowsError(try resolve(CADAgentCamera(position: [0, 0, 0])))
        XCTAssertThrowsError(try resolve(CADAgentCamera(position: [1_000_000, 0, 0], target: [999_999.99, 0, 0])))
        XCTAssertThrowsError(try resolve(CADAgentCamera(position: [1_000_000, 0, 0], target: [999_999, 0, 0], zoom: 1_000_000)))
        let target = try resolve(CADAgentCamera(position: [30, 20, 10]))
        XCTAssertEqual(target.target, SIMD3(0, 0, 0))
    }

    private func resolve(_ camera: CADAgentCamera, view: String = "isometric", orthographic: Bool = false) throws -> CADAgentCameraPose {
        try camera.resolved(view: view, bounds: bounds, width: 800, height: 600, orthographic: orthographic)
    }

    private func assertBasis(_ pose: CADAgentCameraPose, file: StaticString = #filePath, line: UInt = #line) throws {
        for vector in [pose.right, pose.up, pose.backward] {
            XCTAssertTrue(vector.x.isFinite && vector.y.isFinite && vector.z.isFinite, file: file, line: line)
            XCTAssertEqual(simd_length(vector), 1, accuracy: 1e-12, file: file, line: line)
        }
        XCTAssertEqual(simd_dot(pose.right, pose.up), 0, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(simd_dot(pose.right, pose.backward), 0, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(simd_dot(pose.up, pose.backward), 0, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(simd_dot(simd_cross(pose.right, pose.up), pose.backward), 1, accuracy: 1e-12, file: file, line: line)
    }
}
