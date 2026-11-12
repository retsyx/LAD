import XCTest
@testable import LAD

final class AssemblyMotionControlsTests: XCTestCase {
    private let wheel = AssemblyJoint(id: "wheel", type: .revolute, parent: "a", child: "b")

    func testContinuousRevoluteSliderSpansOneTurnAroundTheCurrentTurn() {
        XCTAssertEqual(range(wheel, 0), -180...180)
        XCTAssertEqual(range(wheel, 6589.78), 6300...6660)
        XCTAssertEqual(range(wheel, -1000), -1260 ... -900)
        XCTAssertEqual(range(wheel, 179), -180...180)
    }

    func testHeldTurnKeepsTheWindowDuringADragUnlessThePositionLeavesIt() {
        // Crossing a half turn mid-drag does not recenter the slider.
        XCTAssertEqual(range(wheel, 180, held: 0), -180...180)
        XCTAssertEqual(range(wheel, -175, held: 0), -180...180)
        // A position moved elsewhere by other means falls back to its own turn.
        XCTAssertEqual(range(wheel, 700, held: 0), 540...900)
    }

    func testLimitedJointsKeepTheirLimits() {
        let knob = AssemblyJoint(id: "knob", type: .revolute, parent: "a", child: "b", limits: [0, 3600])
        XCTAssertEqual(range(knob, 2000, held: 1800), 0...3600)
        let slide = AssemblyJoint(id: "slide", type: .slider, parent: "a", child: "b", limits: [-5, 5])
        XCTAssertEqual(range(slide, 2), -5...5)
    }

    func testUnlimitedSliderStillExtendsToItsCurrentPosition() {
        let slide = AssemblyJoint(id: "slide", type: .slider, parent: "a", child: "b")
        XCTAssertEqual(range(slide, 20), -100...100)
        XCTAssertEqual(range(slide, 250), -100...250)
    }

    private func range(_ joint: AssemblyJoint, _ current: Double, held: Double? = nil) -> ClosedRange<Double> {
        AssemblyMotionControls.sliderRange(joint, current: current, heldTurn: held)
    }
}
