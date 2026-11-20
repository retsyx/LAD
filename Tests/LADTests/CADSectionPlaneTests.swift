import simd
import XCTest
@testable import LAD

final class CADSectionPlaneTests: XCTestCase {
    func testInitialCutKeepsTheHalfAwayFromTheCamera() throws {
        let bounds: [Double] = [10, -3, -8, 30, 7, 4]
        let near = try XCTUnwrap(CADSectionPlane(bounds: bounds, toward: SIMD3(1, 1, 1)))
        let far = try XCTUnwrap(CADSectionPlane(bounds: bounds, toward: SIMD3(-1, 1, 1)))
        XCTAssertEqual(near.center, SIMD3(20, 2, -2))
        XCTAssertTrue(near.contains(SIMD3(19, 2, -2)))
        XCTAssertFalse(near.contains(SIMD3(21, 2, -2)))
        XCTAssertTrue(far.contains(SIMD3(21, 2, -2)))
        XCTAssertFalse(far.contains(SIMD3(19, 2, -2)))
    }

    func testTypedAnglesAndOffsetAgreeWithTheRenderPlane() throws {
        let initial = try XCTUnwrap(CADSectionPlane(bounds: [10, -3, -8, 30, 7, 4], toward: SIMD3(1, 1, 1)))
        let swung = try XCTUnwrap(initial.setting(90, for: .horizontal))
        let tilted = try XCTUnwrap(swung.setting(30, for: .vertical))
        let section = try XCTUnwrap(tilted.setting(12, for: .offset))
        let normal = SIMD3<Double>(0, sqrt(3) / 2, 0.5)
        XCTAssertEqual(section.value(for: .horizontal), 90)
        XCTAssertEqual(section.value(for: .vertical), 30)
        XCTAssertEqual(section.value(for: .offset), 12)
        XCTAssertEqual(simd_length(section.normal - normal), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_length(section.origin - section.center - normal * 12), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(section.vertical, section.normal), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(section.horizontal, section.normal), 0, accuracy: 1e-12)
        let point = section.origin + section.normal * 3
        XCTAssertEqual(section.signedDistance(to: point), 3, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(section.equation, SIMD4(SIMD3<Float>(point), 1)), 3, accuracy: 1e-5)
        XCTAssertNil(section.setting(.infinity, for: .offset))
        XCTAssertNil(section.setting(Double.greatestFiniteMagnitude, for: .offset))
    }

    func testClippingRetainsTheCorrectPortionOfAFeatureInEitherDirection() throws {
        let section = try XCTUnwrap(CADSectionPlane(bounds: [-5, -5, -5, 5, 5, 5], toward: SIMD3(1, 0, 0)))
        let retained = SIMD3<Double>(-2, 1, 0)
        let removed = SIMD3<Double>(6, 5, 4)
        let crossing = SIMD3<Double>(0, 2, 1)
        let forward = try XCTUnwrap(section.clippedSegment(from: retained, to: removed))
        let reverse = try XCTUnwrap(section.clippedSegment(from: removed, to: retained))
        XCTAssertEqual(forward.from, retained)
        XCTAssertEqual(forward.to, crossing)
        XCTAssertEqual(reverse.from, crossing)
        XCTAssertEqual(reverse.to, retained)
        XCTAssertNil(section.clippedSegment(from: removed, to: SIMD3(3, 7, 1)))
    }

    func testRotatingAnOffsetSectionPreservesItsPivot() throws {
        let initial = try XCTUnwrap(CADSectionPlane(bounds: [-20, -10, -5, 20, 10, 5],
                                                   toward: SIMD3(1, -1, 1), cameraRight: SIMD3(1, 1, 0)))
        let placed = try XCTUnwrap(initial.setting(8, for: .offset))
        let swung = try XCTUnwrap(placed.setting(65, for: .horizontal))
        let tilted = try XCTUnwrap(swung.setting(25, for: .vertical))
        XCTAssertEqual(tilted.origin, placed.origin)
        XCTAssertEqual(tilted.value(for: .offset), -tilted.signedDistance(to: tilted.center), accuracy: 1e-12)

        let moved = try XCTUnwrap(tilted.setting(tilted.value(for: .offset) + 3, for: .offset))
        XCTAssertEqual(simd_length(moved.origin - tilted.origin - 3 * tilted.normal), 0, accuracy: 1e-12)
        let centered = try XCTUnwrap(moved.setting(0, for: .offset))
        XCTAssertEqual(centered.signedDistance(to: centered.center), 0, accuracy: 1e-12)
    }

    func testSectionFromFaceUsesTheExactPlaneAndRelativeHandleAngles() throws {
        let point = SIMD3<Double>(7, -11, 13)
        let outwardNormal = SIMD3<Double>(1, 2, 2)
        let cameraRight = SIMD3<Double>(2, -1, 0)
        let initial = try XCTUnwrap(CADSectionPlane(point: point, normal: outwardNormal, cameraRight: cameraRight))
        XCTAssertEqual(initial.origin, point)
        XCTAssertEqual(initial.normal, outwardNormal / 3)
        XCTAssertTrue(initial.contains(point - outwardNormal))
        XCTAssertFalse(initial.contains(point + outwardNormal))
        XCTAssertEqual(initial.signedDistance(to: point + 2 * cameraRight), 0, accuracy: 1e-12)
        for handle in CADSectionHandle.allCases { XCTAssertEqual(initial.value(for: handle), 0) }

        let swung = try XCTUnwrap(initial.setting(90, for: .horizontal))
        let tilted = try XCTUnwrap(swung.setting(30, for: .vertical))
        XCTAssertEqual(tilted.origin, point)
        let expectedNormal = sqrt(3) / 2 * initial.horizontal + 0.5 * initial.vertical
        XCTAssertEqual(simd_distance(tilted.normal, expectedNormal), 0, accuracy: 1e-12)
        let moved = try XCTUnwrap(tilted.setting(-3, for: .offset))
        XCTAssertEqual(simd_distance(moved.origin, point - 3 * expectedNormal), 0, accuracy: 1e-12)
    }

    func testFaceAlignedSectionHandlesAnEdgeOnCameraAndRejectsInvalidGeometry() throws {
        let normal = SIMD3<Double>(0, 0, -1)
        let plane = try XCTUnwrap(CADSectionPlane(point: .zero, normal: normal, cameraRight: normal))
        XCTAssertEqual(plane.normal, normal)
        XCTAssertEqual(simd_length(plane.horizontal), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_length(plane.vertical), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(plane.horizontal, plane.vertical), 0, accuracy: 1e-12)
        XCTAssertNil(CADSectionPlane(point: .zero, normal: .zero, cameraRight: normal))
        XCTAssertNil(CADSectionPlane(point: SIMD3(.infinity, 0, 0), normal: normal, cameraRight: normal))
    }
}
