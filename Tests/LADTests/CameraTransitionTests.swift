import simd
import XCTest
@testable import LAD

final class CameraTransitionTests: XCTestCase {
    func testEndpointsRemainExactAndRetargetingStartsAtCurrentPose() {
        var from = CameraRig()
        from.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
        from.pan(dx: 45, dy: -23, height: 800)
        from.zoom(factor: 8, anchor: SIMD3(165, -80, 7))
        var to = from
        to.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
        to.yaw = .pi
        to.elevation = 0
        let transition = CameraTransition(from: from, to: to)
        assertEqual(transition.rig(at: 0), from)
        assertEqual(transition.rig(at: -1), from)
        assertEqual(transition.rig(at: 1), to)
        assertEqual(transition.rig(at: 2), to)

        let current = transition.rig(at: 0.4)
        var replacement = to
        replacement.yaw = -.pi / 2
        replacement.elevation = .pi / 2 - 0.00001
        let retargeted = CameraTransition(from: current, to: replacement)
        assertEqual(retargeted.rig(at: 0), current)
        assertEqual(retargeted.rig(at: 1), replacement)
    }

    func testYawUsesShortRouteAcrossWrapEvenAfterManyOrbits() {
        var from = CameraRig()
        from.yaw = 400 * .pi + 179 * .pi / 180
        var to = from
        to.yaw = -179 * .pi / 180
        let transition = CameraTransition(from: from, to: to)
        let middle = transition.rig(at: 0.5)
        XCTAssertEqual(middle.yaw - from.yaw, .pi / 180, accuracy: 1e-11)
        XCTAssertLessThan(middle.backward.x, 0)
        XCTAssertEqual(middle.backward.y, 0, accuracy: 1e-11)
    }

    func testMoveEasesAtBothEndsAndScalesDistanceProportionally() {
        var from = CameraRig()
        from.yaw = 0
        from.elevation = 0
        from.distance = 1_000_000
        var to = from
        to.yaw = 1
        to.distance = 10
        let transition = CameraTransition(from: from, to: to)
        XCTAssertLessThan(transition.rig(at: 0.1).yaw, 0.1)
        XCTAssertGreaterThan(transition.rig(at: 0.9).yaw, 0.9)
        XCTAssertEqual(transition.rig(at: 0.5).distance, sqrt(from.distance * to.distance), accuracy: 1e-9)
        XCTAssertGreaterThan(transition.rig(at: 0.001).distance, from.distance * 0.999)
        XCTAssertLessThan(transition.rig(at: 0.999).distance, to.distance * 1.001)
    }

    func testExtremeZoomAndPanRefitKeepsCenterOnItsScreenPathInBothProjections() {
        for orthographic in [false, true] {
            var from = CameraRig()
            from.usesOrthographicProjection = orthographic
            from.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
            from.pan(dx: 45, dy: -23, height: 800)
            let surface = from.orbitCenter + from.backward * (from.radius * 0.6) + from.right * (from.radius * 0.2)
            from.zoom(factor: 1e10, anchor: surface)
            from.orbitAroundCenter(dx: 430, dy: 35)
            var to = from
            to.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
            to.yaw = -.pi / 2
            to.elevation = -.pi / 2 + 0.00001
            let transition = CameraTransition(from: from, to: to)
            let before = from.project(from.orbitCenter, width: 1200, height: 800)
            let after = to.project(to.orbitCenter, width: 1200, height: 800)
            for step in 0...100 {
                let rig = transition.rig(at: Double(step) / 100)
                let center = rig.project(rig.orbitCenter, width: 1200, height: 800)
                XCTAssertGreaterThan(rig.distance, 0)
                XCTAssertTrue(rig.position.x.isFinite && rig.position.y.isFinite && rig.position.z.isFinite)
                XCTAssertGreaterThan(simd_dot(rig.position - rig.orbitCenter, rig.backward), 0)
                for axis in 0..<2 {
                    XCTAssertTrue(center[axis].isFinite)
                    XCTAssertGreaterThanOrEqual(center[axis], min(before[axis], after[axis]) - 1e-7)
                    XCTAssertLessThanOrEqual(center[axis], max(before[axis], after[axis]) + 1e-7)
                }
                XCTAssertEqual(rig.usesOrthographicProjection, orthographic)
            }
        }
    }

    func testOppositeFacesAndTopToBottomKeepAValidUprightBasis() {
        var front = CameraRig()
        front.yaw = -.pi / 2
        front.elevation = 0
        var back = front
        back.yaw = .pi / 2
        var top = front
        top.elevation = .pi / 2 - 0.00001
        var bottom = front
        bottom.elevation = -.pi / 2 + 0.00001
        for (from, to) in [(front, back), (top, bottom)] {
            let transition = CameraTransition(from: from, to: to)
            for step in 0...100 {
                let rig = transition.rig(at: Double(step) / 100)
                XCTAssertEqual(simd_length(rig.backward), 1, accuracy: 1e-12)
                XCTAssertEqual(simd_length(rig.right), 1, accuracy: 1e-12)
                XCTAssertEqual(simd_length(rig.up), 1, accuracy: 1e-12)
                XCTAssertEqual(simd_dot(rig.backward, rig.right), 0, accuracy: 1e-12)
                XCTAssertEqual(simd_dot(rig.backward, rig.up), 0, accuracy: 1e-12)
                XCTAssertEqual(simd_dot(rig.right, rig.up), 0, accuracy: 1e-12)
                XCTAssertGreaterThanOrEqual(rig.up.z, 0)
            }
        }
    }

    private func assertEqual(_ actual: CameraRig, _ expected: CameraRig,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.target, expected.target, file: file, line: line)
        XCTAssertEqual(actual.orbitCenter, expected.orbitCenter, file: file, line: line)
        XCTAssertEqual(actual.distance, expected.distance, file: file, line: line)
        XCTAssertEqual(actual.radius, expected.radius, file: file, line: line)
        XCTAssertEqual(actual.yaw, expected.yaw, file: file, line: line)
        XCTAssertEqual(actual.elevation, expected.elevation, file: file, line: line)
        XCTAssertEqual(actual.usesOrthographicProjection, expected.usesOrthographicProjection, file: file, line: line)
    }
}
