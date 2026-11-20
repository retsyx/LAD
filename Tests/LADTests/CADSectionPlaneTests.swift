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
}
