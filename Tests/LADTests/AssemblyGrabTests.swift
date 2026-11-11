import XCTest
@testable import LAD

final class AssemblyGrabTests: XCTestCase {
    func testHingeGrabTracksTheProjectedBuiltPointAndCannotMoveTheGround() throws {
        let motion = hinge(), parts = pair
        XCTAssertFalse(motion.canGrab(solidIndex: 0, parts: parts))
        XCTAssertFalse(motion.canGrab(solidIndex: 99, parts: parts))
        XCTAssertTrue(motion.canGrab(solidIndex: 1, parts: parts))
        let context = try XCTUnwrap(motion.prepareGrab(parts: parts, solidIndex: 1, point: [10, 0, 0], projection: orthographic))
        let goal = try screen([5, sqrt(75), 0], using: orthographic)
        let pose = try context.solve(screenPoint: goal)
        XCTAssertEqual(pose.positions["hinge"]!, 60, accuracy: 0.1)
        assertScreen(point: [10, 0, 0], solid: 1, pose: pose, goal: goal, projection: orthographic)
        XCTAssertNil(pose.solidTransforms[0])
    }

    func testReorientedSliderMatchesReachableScreenComponentAndClampsSmoothlyAtLimits() throws {
        let motion = slider(limits: [0, 4])
        let context = try XCTUnwrap(motion.prepareGrab(parts: pair, solidIndex: 1, point: [1, 0, 0], projection: orthographic))
        let limited = try context.solve(screenPoint: screen([100, 0, 0], using: orthographic))
        XCTAssertEqual(limited.positions["slide"]!, 4, accuracy: 1e-8)
        let repeated = try context.solve(positions: limited.positions, screenPoint: screen([200, 0, 0], using: orthographic))
        XCTAssertEqual(repeated, limited)
        let returned = try context.solve(positions: limited.positions, screenPoint: screen([3, 9, 0], using: orthographic))
        XCTAssertEqual(returned.positions["slide"]!, 2, accuracy: 1e-5)
        assertPoint(transform([1, 0, 0], solid: 1, pose: returned), [3, 0, 0], accuracy: 1e-6)
    }

    func testOffsetHingeAndPerspectiveDepthUseFrozenProjection() throws {
        let projection = perspective
        let motion = AssemblyMotion(grounded: ["base"], connectors: [
            .init(id: "a", part: "base", origin: [5, 2, 0], xAxis: [1, 0, 0], zAxis: [0, 1, 0]),
            .init(id: "b", part: "arm", origin: [5, 2, 0], xAxis: [1, 0, 0], zAxis: [0, 1, 0])
        ], joints: [.init(id: "hinge", type: .revolute, parent: "a", child: "b", limits: [-80, 80])])
        let context = try XCTUnwrap(motion.prepareGrab(parts: pair, solidIndex: 1, point: [15, 2, 0], projection: projection))
        let goal = try screen([5 + sqrt(75), 2, -5], using: projection)
        let pose = try context.solve(screenPoint: goal)
        XCTAssertEqual(pose.positions["hinge"]!, 30, accuracy: 0.1)
        assertScreen(point: [15, 2, 0], solid: 1, pose: pose, goal: goal, projection: projection)
    }

    func testLongSliderCanReachALargeCursorMoveInOneSolve() throws {
        let motion = slider(limits: [0, 100])
        let context = try XCTUnwrap(motion.prepareGrab(parts: pair, solidIndex: 1, point: [1, 0, 0], projection: orthographic))
        let goal = try screen([51, 0, 0], using: orthographic)
        let pose = try context.solve(screenPoint: goal)
        XCTAssertEqual(pose.positions["slide"]!, 50, accuracy: 0.01)
        assertScreen(point: [1, 0, 0], solid: 1, pose: pose, goal: goal, projection: orthographic)
    }

    func testMultiJointChainMovesItsFixedDescendantAndPreservesUnrelatedBranch() throws {
        var motion = hinge(), parts = pair
        parts += [.init(id: "forearm", name: "Forearm", solidIndices: [2]),
                  .init(id: "bolt", name: "Bolt", solidIndices: [3]),
                  .init(id: "other", name: "Other", solidIndices: [4])]
        motion.connectors += [
            .init(id: "elbow-a", part: "arm", origin: [10, 0, 0]),
            .init(id: "elbow-b", part: "forearm", origin: [10, 0, 0]),
            .init(id: "mount-a", part: "forearm", origin: [19, 0, 0]),
            .init(id: "mount-b", part: "bolt", origin: [19, 0, 0]),
            .init(id: "other", part: "other", origin: [0, 0, 0])]
        motion.joints += [
            .init(id: "elbow", type: .revolute, parent: "elbow-a", child: "elbow-b", limits: [-150, 150]),
            .init(id: "mount", type: .fixed, parent: "mount-a", child: "mount-b"),
            .init(id: "other", type: .revolute, parent: "a", child: "other", position: 23)]
        let context = try XCTUnwrap(motion.prepareGrab(parts: parts, solidIndex: 3, point: [20, 0, 0], projection: orthographic))
        let goal = try screen([10, 10, 0], using: orthographic)
        let pose = try context.solve(screenPoint: goal)
        assertScreen(point: [20, 0, 0], solid: 3, pose: pose, goal: goal, projection: orthographic)
        XCTAssertEqual(pose.positions["other"], 23)
        XCTAssertEqual(pose.positions["mount"], 0)
        assertPoint(transform([1, 0, 0], solid: 4, pose: pose), [cos(23 * .pi / 180), sin(23 * .pi / 180), 0])
    }

    func testClosedFourBarGrabClosesBothEndsAndKeepsTheContinuousBranch() throws {
        let (motion, parts) = fourBar()
        let initial = try motion.solve(parts: parts, positions: ["a": 20], driving: "a")
        let context = try XCTUnwrap(motion.prepareGrab(parts: parts, positions: initial.positions,
            solidIndex: 2, point: [20, 10, 0], projection: orthographic))
        let goal = try screen([15, sqrt(75), 0], using: orthographic)
        let pose = try context.solve(positions: initial.positions, screenPoint: goal)
        assertScreen(point: [20, 10, 0], solid: 2, pose: pose, goal: goal, projection: orthographic)
        XCTAssertEqual(pose.positions["a"]!, 30, accuracy: 0.1)
        assertPoint(transform([0, 10, 0], solid: 1, pose: pose), transform([0, 10, 0], solid: 2, pose: pose), accuracy: 1e-6)
        assertPoint(transform([40, 10, 0], solid: 2, pose: pose), transform([40, 10, 0], solid: 3, pose: pose), accuracy: 1e-6)
        XCTAssertEqual(try motion.solve(parts: parts, positions: pose.positions), pose)
    }

    func testClosedGrabStopsAtItsJointLimitWithAnExactPose() throws {
        var (motion, parts) = fourBar()
        motion.joints[0].limits = [-20, 20]
        let context = try XCTUnwrap(motion.prepareGrab(parts: parts, solidIndex: 1, point: [0, 10, 0], projection: orthographic))
        let goal = try screen([-10 * sin(70 * .pi / 180), 10 * cos(70 * .pi / 180), 0], using: orthographic)
        let pose = try context.solve(screenPoint: goal)
        XCTAssertEqual(pose.positions["a"]!, 20, accuracy: 0.1)
        assertPoint(transform([40, 10, 0], solid: 2, pose: pose), transform([40, 10, 0], solid: 3, pose: pose), accuracy: 1e-6)
        XCTAssertNoThrow(try motion.solve(parts: parts, positions: pose.positions))
    }

    func testSingularAndEndOnGrabsRemainStableWithoutFreeFloatingGeometry() throws {
        let motion = hinge()
        let context = try XCTUnwrap(motion.prepareGrab(parts: pair, positions: ["hinge": 30], solidIndex: 1,
            point: [0, 0, 0], projection: orthographic))
        let pose = try context.solve(screenPoint: [700, 500])
        XCTAssertEqual(pose.positions["hinge"], 30)
        var endOn = motion
        endOn.joints[0] = .init(id: "hinge", type: .slider, parent: "a", child: "b", limits: [-20, 20])
        let slider = try XCTUnwrap(endOn.prepareGrab(parts: pair, solidIndex: 1, point: [1, 0, 0], projection: orthographic))
        XCTAssertEqual(try slider.solve(screenPoint: [700, 500]).positions["hinge"], 0)
        var fixed = motion; fixed.joints[0].type = .fixed; fixed.joints[0].limits = nil
        XCTAssertFalse(fixed.canGrab(solidIndex: 1, parts: pair))
    }

    func testProjectedTurningPointCanStillMoveTowardAReachableTarget() throws {
        var motion = hinge(); motion.joints[0].limits = [-180, 180]
        let context = try XCTUnwrap(motion.prepareGrab(parts: pair, solidIndex: 1, point: [10, 0, 0], projection: orthographic))
        let goal = try screen([-10, 0, 0], using: orthographic)
        let pose = try context.solve(screenPoint: goal)
        assertScreen(point: [10, 0, 0], solid: 1, pose: pose, goal: goal, projection: orthographic)
        XCTAssertEqual(abs(pose.positions["hinge"]!), 180, accuracy: 0.1)
    }

    func testMalformedProjectionPointAndScreenTargetsAreRejected() throws {
        let motion = hinge()
        var invalid = orthographic; invalid.worldToClip = [1]
        XCTAssertThrowsError(try motion.prepareGrab(parts: pair, solidIndex: 1, point: [1, 0, 0], projection: invalid))
        invalid = orthographic; invalid.viewportSize = [0, 600]
        XCTAssertThrowsError(try motion.prepareGrab(parts: pair, solidIndex: 1, point: [1, 0, 0], projection: invalid))
        XCTAssertThrowsError(try motion.prepareGrab(parts: pair, solidIndex: 1, point: [.nan, 0, 0], projection: orthographic))
        let context = try XCTUnwrap(motion.prepareGrab(parts: pair, solidIndex: 1, point: [10, 0, 0], projection: orthographic))
        XCTAssertThrowsError(try context.solve(screenPoint: [.infinity, 0]))
        XCTAssertThrowsError(try context.solve(positions: ["missing": 0], screenPoint: [100, 100]))
        XCTAssertNil(try motion.prepareGrab(parts: pair, solidIndex: 1, point: [0, 0, 30], projection: perspective))
    }

    func testSavedPoseStartsWithoutSlippingAndUnequalMateFramesUseTheBuiltPoint() throws {
        var motion = hinge()
        motion.connectors[1].origin = [100, 0, 0]
        let initial = try motion.solve(parts: pair, positions: ["hinge": 60])
        let context = try XCTUnwrap(motion.prepareGrab(parts: pair, positions: initial.positions,
            solidIndex: 1, point: [110, 0, 0], projection: orthographic))
        let goal = try screen([5, sqrt(75), 0], using: orthographic)
        let pose = try context.solve(positions: initial.positions, screenPoint: goal)
        XCTAssertEqual(pose, initial)
        let next = try context.solve(positions: pose.positions, screenPoint: screen([sqrt(75), 5, 0], using: orthographic))
        XCTAssertEqual(next.positions["hinge"]!, 30, accuracy: 0.1)
    }

    func testLargeAssemblyGrabLeavesTwoHundredUnrelatedJointCoordinatesUntouched() throws {
        var motion = hinge(), parts = pair
        for index in 0..<200 {
            let identity = "other-\(index)"
            parts.append(.init(id: identity, name: identity, solidIndices: [index + 2]))
            motion.connectors.append(.init(id: identity, part: identity, origin: [0, 0, 0]))
            motion.joints.append(.init(id: identity, type: .revolute, parent: "a", child: identity, position: 23))
        }
        let context = try XCTUnwrap(motion.prepareGrab(parts: parts, solidIndex: 1, point: [10, 0, 0], projection: orthographic))
        let pose = try context.solve(screenPoint: screen([5, sqrt(75), 0], using: orthographic))
        XCTAssertEqual(pose.positions["hinge"]!, 60, accuracy: 0.1)
        for index in 0..<200 { XCTAssertEqual(pose.positions["other-\(index)"], 23) }
    }

    func testPerspectiveMotionDoesNotDependOnBackingScale() throws {
        let motion = hinge()
        let projection = perspective
        var doubled = projection; doubled.viewportSize = projection.viewportSize.map { $0 * 2 }
        let point = [10.0, 0, 0], goal = [5.0, sqrt(75), 0]
        let standard = try motion.solveGrab(parts: pair, solidIndex: 1, point: point,
            screenPoint: screen(goal, using: projection), projection: projection)
        let retina = try motion.solveGrab(parts: pair, solidIndex: 1, point: point,
            screenPoint: screen(goal, using: doubled), projection: doubled)
        XCTAssertEqual(standard.positions["hinge"]!, retina.positions["hinge"]!, accuracy: 0.01)
    }

    func testCancelledGrabNeverPublishesAReplacementPose() async throws {
        let context = try XCTUnwrap(hinge().prepareGrab(parts: pair, solidIndex: 1, point: [10, 0, 0], projection: orthographic))
        let calculation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try context.solve(screenPoint: [400, 450])
        }
        do {
            _ = try await calculation.value
            XCTFail("A cancelled grab must not publish a pose")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    private var pair: [PartNode] {
        [.init(id: "base", name: "Base", solidIndices: [0]), .init(id: "arm", name: "Arm", solidIndices: [1])]
    }

    private func hinge() -> AssemblyMotion {
        AssemblyMotion(grounded: ["base"], connectors: [
            .init(id: "a", part: "base", origin: [0, 0, 0]), .init(id: "b", part: "arm", origin: [0, 0, 0])
        ], joints: [.init(id: "hinge", type: .revolute, parent: "a", child: "b", limits: [-150, 150])])
    }

    private func slider(limits: [Double]) -> AssemblyMotion {
        AssemblyMotion(grounded: ["base"], connectors: [
            .init(id: "a", part: "base", origin: [0, 0, 0], xAxis: [0, 1, 0], zAxis: [1, 0, 0]),
            .init(id: "b", part: "arm", origin: [0, 0, 0], xAxis: [0, 1, 0], zAxis: [1, 0, 0])
        ], joints: [.init(id: "slide", type: .slider, parent: "a", child: "b", limits: limits)])
    }

    private func fourBar() -> (AssemblyMotion, [PartNode]) {
        let names = ["ground", "crank", "coupler", "follower"]
        let parts = names.enumerated().map { PartNode(id: $0.element, name: $0.element, solidIndices: [$0.offset]) }
        let connectors: [AssemblyConnector] = [
            .init(id: "a0", part: "ground", origin: [0, 0, 0]), .init(id: "a1", part: "crank", origin: [0, 0, 0]),
            .init(id: "b1", part: "crank", origin: [0, 10, 0]), .init(id: "b2", part: "coupler", origin: [0, 10, 0]),
            .init(id: "c2", part: "coupler", origin: [40, 10, 0]), .init(id: "c3", part: "follower", origin: [40, 10, 0]),
            .init(id: "d0", part: "ground", origin: [40, 0, 0]), .init(id: "d3", part: "follower", origin: [40, 0, 0])]
        let joints: [AssemblyJoint] = [
            .init(id: "a", type: .revolute, parent: "a0", child: "a1", limits: [-80, 80]),
            .init(id: "b", type: .revolute, parent: "b1", child: "b2", limits: [-90, 90]),
            .init(id: "c", type: .revolute, parent: "c2", child: "c3", limits: [-90, 90]),
            .init(id: "d", type: .revolute, parent: "d0", child: "d3", limits: [-90, 90])]
        return (AssemblyMotion(grounded: ["ground"], connectors: connectors, joints: joints), parts)
    }

    private var orthographic: AssemblyGrabProjection {
        .init(worldToClip: [0.05, 0, 0, 0, 0, 0.05, 0, 0, 0, 0, -0.05, 0, 0, 0, 0, 1], viewportSize: [800, 600])
    }

    private var perspective: AssemblyGrabProjection {
        .init(worldToClip: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -1, 19, 0, 0, -1, 20], viewportSize: [800, 600])
    }

    private func screen(_ point: [Double], using projection: AssemblyGrabProjection) throws -> [Double] {
        try XCTUnwrap(projection.project(point))
    }

    private func transform(_ point: [Double], solid: Int, pose: AssemblyPose) -> [Double] {
        let matrix = pose.solidTransforms[solid] ?? AssemblyPose.identityTransform
        return (0..<3).map { matrix[$0 * 4] * point[0] + matrix[$0 * 4 + 1] * point[1] + matrix[$0 * 4 + 2] * point[2] + matrix[$0 * 4 + 3] }
    }

    private func assertScreen(point: [Double], solid: Int, pose: AssemblyPose, goal: [Double], projection: AssemblyGrabProjection,
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = projection.project(transform(point, solid: solid, pose: pose)) ?? [.infinity, .infinity]
        for (actual, goal) in zip(actual, goal) { XCTAssertEqual(actual, goal, accuracy: 0.2, file: file, line: line) }
    }

    private func assertPoint(_ actual: [Double], _ expected: [Double], accuracy: Double = 1e-8,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (actual, expected) in zip(actual, expected) { XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line) }
    }
}
