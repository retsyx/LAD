import XCTest
import simd
@testable import LAD

final class CameraRigTests: XCTestCase {
    func testOrthographicProjectionHasNoDepthForeshortening() {
        var rig = CameraRig()
        rig.usesOrthographicProjection = true
        let near = rig.target + rig.backward * 25
        let far = rig.target - rig.backward * 25
        let nearLength = rig.project(near + rig.right * 20, width: 900, height: 700)
            - rig.project(near, width: 900, height: 700)
        let farLength = rig.project(far + rig.right * 20, width: 900, height: 700)
            - rig.project(far, width: 900, height: 700)
        XCTAssertEqual(nearLength.x, farLength.x, accuracy: 1e-9)
        XCTAssertEqual(nearLength.y, farLength.y, accuracy: 1e-9)

        rig.usesOrthographicProjection = false
        let nearPerspective = rig.project(near + rig.right * 20, width: 900, height: 700)
            - rig.project(near, width: 900, height: 700)
        let farPerspective = rig.project(far + rig.right * 20, width: 900, height: 700)
            - rig.project(far, width: 900, height: 700)
        XCTAssertGreaterThan(simd_length(nearPerspective), simd_length(farPerspective))
    }

    func testChangingProjectionPreservesScaleOnTargetPlane() {
        var rig = CameraRig()
        let point = rig.target + rig.right * 23 + rig.up * 17
        let before = rig.project(point, width: 900, height: 700)
        rig.usesOrthographicProjection = true
        let after = rig.project(point, width: 900, height: 700)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
    }

    func testOrthographicZoomPreservesSurfaceAnchorIncludingClamps() {
        var rig = CameraRig()
        rig.usesOrthographicProjection = true
        rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
        let anchor = SIMD3<Double>(165, -80, 7)
        let before = rig.project(anchor, width: 1200, height: 800)
        for factor in [0.37, 3, 1e10, 1e-15] {
            rig.zoom(factor: factor, anchor: anchor)
            let after = rig.project(anchor, width: 1200, height: 800)
            XCTAssertEqual(before.x, after.x, accuracy: 1e-5)
            XCTAssertEqual(before.y, after.y, accuracy: 1e-5)
        }
        XCTAssertEqual(rig.distance, rig.radius * 0.003)
    }

    func testOrthographicEmptySpaceZoomAndPanKeepCursorAnchor() {
        var rig = CameraRig()
        rig.usesOrthographicProjection = true
        let anchor = rig.planeAnchor(x: 125, y: 510, width: 900, height: 700)
        rig.zoom(factor: 0.4, anchor: anchor)
        let zoomed = rig.project(anchor, width: 900, height: 700)
        XCTAssertEqual(zoomed.x, 125, accuracy: 1e-9)
        XCTAssertEqual(zoomed.y, 510, accuracy: 1e-9)
        rig.pan(dx: 32, dy: -18, height: 700)
        let panned = rig.project(anchor, width: 900, height: 700)
        XCTAssertEqual(panned.x, zoomed.x + 32, accuracy: 1e-9)
        XCTAssertEqual(panned.y, zoomed.y + 18, accuracy: 1e-9)
    }

    func testOrthographicOrbitPreservesOffsetModelPivotAfterZoomAndPan() {
        var rig = CameraRig()
        rig.usesOrthographicProjection = true
        rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
        let center = rig.orbitCenter
        rig.pan(dx: 45, dy: -23, height: 800)
        rig.zoom(factor: 0.6, anchor: SIMD3(165, -80, 7))
        let before = rig.project(center, width: 1200, height: 800)
        rig.orbitAroundCenter(dx: 80, dy: 25)
        let after = rig.project(center, width: 1200, height: 800)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
        XCTAssertEqual(rig.orbitCenter, center)
    }

    func testZoomPreservesCursorProjectionOnSurface() {
        var rig = CameraRig()
        rig.fit(bounds: [-50, -20, 0, 50, 20, 35], width: 1200, height: 800)
        let anchor = SIMD3<Double>(23, -8, 12)
        let before = rig.project(anchor, width: 1200, height: 800)
        rig.zoom(factor: 0.37, anchor: anchor)
        let after = rig.project(anchor, width: 1200, height: 800)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
    }

    func testEmptySpaceAnchorAndInverseZoom() {
        var rig = CameraRig()
        let target = rig.target
        let distance = rig.distance
        let anchor = rig.planeAnchor(x: 100, y: 550, width: 900, height: 700)
        let projection = rig.project(anchor, width: 900, height: 700)
        XCTAssertEqual(projection.x, 100, accuracy: 1e-9)
        XCTAssertEqual(projection.y, 550, accuracy: 1e-9)
        rig.zoom(factor: 0.5, anchor: anchor)
        rig.zoom(factor: 2, anchor: anchor)
        XCTAssertEqual(simd_length(rig.target - target), 0, accuracy: 1e-9)
        XCTAssertEqual(rig.distance, distance, accuracy: 1e-9)
    }

    func testEmptySpaceAnchorStaysAtDesignDepthAfterSurfaceZoom() {
        for orthographic in [false, true] {
            var rig = CameraRig()
            rig.usesOrthographicProjection = orthographic
            rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
            rig.pan(dx: 35, dy: -20, height: 800)
            rig.orbitAroundCenter(dx: 40, dy: 15)
            let surface = rig.orbitCenter + rig.backward * (rig.radius * 0.6)
            rig.zoom(factor: 1e10, anchor: surface)
            XCTAssertGreaterThan(abs(simd_dot(rig.target - rig.orbitCenter, rig.backward)), rig.radius * 1000,
                                 "The surface zoom must exercise a target displaced from design depth.")
            let anchor = rig.planeAnchor(x: 530, y: 470, width: 1200, height: 800)
            XCTAssertEqual(simd_dot(anchor - rig.orbitCenter, rig.backward), 0, accuracy: 1e-7)
            let projected = rig.project(anchor, width: 1200, height: 800)
            XCTAssertEqual(projected.x, 530, accuracy: 1e-7)
            XCTAssertEqual(projected.y, 470, accuracy: 1e-7)
        }
    }

    func testZoomRecoversFromMaximumDistanceAfterSurfaceHitsBecomeEmptySpace() {
        for orthographic in [false, true] {
            var rig = CameraRig()
            rig.usesOrthographicProjection = orthographic
            rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
            rig.pan(dx: 35, dy: -20, height: 800)
            rig.orbitAroundCenter(dx: 40, dy: 15)
            let initialDistance = rig.distance
            let surface = rig.orbitCenter + rig.backward * (rig.radius * 0.6)
            let cursor = rig.project(surface, width: 1200, height: 800)
            rig.zoom(factor: 1e10, anchor: surface)
            XCTAssertEqual(rig.distance, rig.radius * 100_000)

            // At this scale the surface is subpixel, so subsequent input has
            // to fall back to an empty-space anchor instead of a surface hit.
            for _ in 0..<40 where rig.distance > initialDistance {
                let anchor = rig.planeAnchor(x: cursor.x, y: cursor.y, width: 1200, height: 800)
                rig.zoom(factor: 0.65, anchor: anchor)
                XCTAssertGreaterThan(simd_dot(rig.position - rig.orbitCenter, rig.backward), 0,
                                     "Zooming back must keep the design in front of the camera.")
            }
            XCTAssertLessThanOrEqual(rig.distance, initialDistance)
            let center = rig.project(rig.orbitCenter, width: 1200, height: 800)
            XCTAssertGreaterThan(center.x, 0)
            XCTAssertLessThan(center.x, 1200)
            XCTAssertGreaterThan(center.y, 0)
            XCTAssertLessThan(center.y, 800)
        }
    }

    func testEmptySpaceZoomCanBackOutAfterMovingPastDesignCenter() {
        for orthographic in [false, true] {
            var rig = CameraRig()
            rig.usesOrthographicProjection = orthographic
            rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
            let surface = rig.orbitCenter - rig.backward * (rig.radius * 0.6)
            rig.zoom(factor: 0.01, anchor: surface)
            XCTAssertLessThan(simd_dot(rig.position - rig.orbitCenter, rig.backward), 0,
                              "The close-up must put the camera beyond the design center.")
            for _ in 0..<10 {
                let anchor = rig.planeAnchor(x: 600, y: 400, width: 1200, height: 800)
                XCTAssertGreaterThan(simd_dot(rig.position - anchor, rig.backward), 0,
                                     "An empty-space anchor must stay in front of the camera.")
                let before = rig.position
                rig.zoom(factor: 2, anchor: anchor)
                XCTAssertGreaterThan(simd_dot(rig.position - before, rig.backward), 0,
                                     "Zooming out must back away even when viewing inside the design.")
            }
            XCTAssertGreaterThan(simd_dot(rig.position - rig.orbitCenter, rig.backward), 0)
        }
    }

    func testFitAccountsForNarrowViewport() {
        var wide = CameraRig()
        wide.fit(bounds: [-50, -20, 0, 50, 20, 35], width: 1200, height: 800)
        var narrow = CameraRig()
        narrow.fit(bounds: [-50, -20, 0, 50, 20, 35], width: 400, height: 800)
        XCTAssertGreaterThan(narrow.distance, wide.distance)
    }

    func testZoomClampsWithoutMovingAnchor() {
        var rig = CameraRig()
        let anchor = SIMD3<Double>(-13, 10, 8)
        let before = rig.project(anchor, width: 900, height: 700)
        rig.zoom(factor: 1e10, anchor: anchor)
        let after = rig.project(anchor, width: 900, height: 700)
        XCTAssertEqual(rig.distance, rig.radius * 100_000)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-6)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-6)
    }

    func testOrbitRotatesCameraAboutModelCenterAfterZoomAndPan() {
        var rig = CameraRig()
        let center = SIMD3<Double>(100, 35, 20)
        rig.fit(bounds: [50, 10, 0, 150, 60, 40], width: 1200, height: 800)
        rig.pan(dx: 64, dy: -18, height: 800)
        rig.zoom(factor: 0.65, anchor: SIMD3<Double>(105, 25, 30))
        let cameraRadius = simd_length(rig.position - center)
        let targetRadius = simd_length(rig.target - center)
        let before = rig.project(center, width: 1200, height: 800)
        rig.orbitAroundCenter(dx: 42, dy: 17)
        let after = rig.project(center, width: 1200, height: 800)
        XCTAssertEqual(simd_length(rig.position - center), cameraRadius, accuracy: 1e-9)
        XCTAssertEqual(simd_length(rig.target - center), targetRadius, accuracy: 1e-9)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
        XCTAssertEqual(rig.orbitCenter, center)
    }

    func testFitUsesGeometricBoundsMidpointForPivotAndFraming() {
        var rig = CameraRig()
        rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
        XCTAssertEqual(rig.orbitCenter, SIMD3(146, -91, 1))
        XCTAssertEqual(rig.target, SIMD3(146, -91, 1))
        rig.orbitAroundCenter(dx: 100, dy: -35)
        XCTAssertEqual(rig.target, rig.orbitCenter)
    }

    func testOffsetPCBRemainsAtSameScreenPositionDuringOrbit() {
        var rig = CameraRig()
        rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
        XCTAssertEqual(rig.orbitCenter, SIMD3(146, -91, 1))
        let centerScreen = rig.project(rig.orbitCenter, width: 1200, height: 800)
        rig.orbitAroundCenter(dx: 80, dy: 25)
        XCTAssertEqual(rig.target, rig.orbitCenter)
        let after = rig.project(rig.orbitCenter, width: 1200, height: 800)
        XCTAssertEqual(centerScreen.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(centerScreen.y, after.y, accuracy: 1e-9)
    }

    func testOrbitAtElevationLimitKeepsModelCenterFixed() {
        var rig = CameraRig()
        let center = SIMD3<Double>(146, -91, 1)
        rig.fit(bounds: [115, -107, -6, 177, -75, 8], width: 1200, height: 800)
        rig.pan(dx: 32, dy: 20, height: 800)
        let before = rig.project(center, width: 1200, height: 800)
        for dy in [10_000.0, 30, -10_000, -30] {
            rig.orbitAroundCenter(dx: 50, dy: dy)
            let after = rig.project(center, width: 1200, height: 800)
            XCTAssertEqual(before.x, after.x, accuracy: 1e-7)
            XCTAssertEqual(before.y, after.y, accuracy: 1e-7)
        }
    }
}
