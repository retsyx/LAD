import XCTest
@testable import LAD

final class AssemblyMotionControlsTests: XCTestCase {
    private let wheel = AssemblyJoint(id: "wheel", type: .revolute, parent: "a", child: "b")

    func testContinuousRevoluteSliderStartsWithinTheNearestTurn() {
        XCTAssertEqual(range(wheel, 0), -180...180)
        XCTAssertEqual(range(wheel, 6589.78), 6300...6660)
        XCTAssertEqual(range(wheel, -1000), -1260 ... -900)
        XCTAssertEqual(range(wheel, 179), -180...180)
    }

    func testWindowHoldsUntilReleasedAtEitherEnd() {
        // The window holds during a drag and after a release between its ends.
        XCTAssertEqual(range(wheel, 180, center: 0), -180...180)
        XCTAssertEqual(range(wheel, -175, center: 0), -180...180)
        XCTAssertEqual(AssemblyMotionControls.revolutionCenter(current: 90, held: 0, released: true), 0)
        // Releasing at either end recenters on the position, including
        // fractional windows whose end differs from the position by rounding.
        XCTAssertEqual(AssemblyMotionControls.revolutionCenter(current: 180, held: 0, released: true), 180)
        XCTAssertEqual(AssemblyMotionControls.revolutionCenter(current: -180, held: 0, released: true), -180)
        XCTAssertEqual(AssemblyMotionControls.revolutionCenter(current: 6409.78, held: 6589.78, released: true), 6409.78)
        XCTAssertEqual(AssemblyMotionControls.revolutionCenter(current: 180, held: 0), 0, "An end recenters only on release.")
    }

    func testPositionLeavingTheWindowShowsWithinItsNearestTurn() {
        XCTAssertEqual(range(wheel, 700, center: 0), 540...900)
        XCTAssertEqual(AssemblyMotionControls.revolutionCenter(current: 700, held: 0, released: true), 720)
    }

    func testLimitedJointsKeepTheirLimits() {
        let knob = AssemblyJoint(id: "knob", type: .revolute, parent: "a", child: "b", limits: [0, 3600])
        XCTAssertEqual(range(knob, 2000, center: 1800), 0...3600)
        let slide = AssemblyJoint(id: "slide", type: .slider, parent: "a", child: "b", limits: [-5, 5])
        XCTAssertEqual(range(slide, 2), -5...5)
    }

    func testUnlimitedSliderStillExtendsToItsCurrentPosition() {
        let slide = AssemblyJoint(id: "slide", type: .slider, parent: "a", child: "b")
        XCTAssertEqual(range(slide, 20), -100...100)
        XCTAssertEqual(range(slide, 250), -100...250)
    }

    private func range(_ joint: AssemblyJoint, _ current: Double, center: Double? = nil) -> ClosedRange<Double> {
        AssemblyMotionControls.sliderRange(joint, current: current, center: center)
    }
}
