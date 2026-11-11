import XCTest
@testable import LAD

final class AssemblyMotionTests: XCTestCase {
    func testOffsetMateFramesAlignAndRotateAroundTheirOwnOrigins() throws {
        let motion = AssemblyMotion(grounded: ["base"], connectors: [
            .init(id: "base-axis", part: "base", origin: [1, 2, 3]),
            .init(id: "arm-axis", part: "arm", origin: [10, 0, 0])
        ], joints: [.init(id: "hinge", name: "Hinge", type: .revolute, parent: "base-axis", child: "arm-axis")])
        let pose = try motion.solve(parts: pair, positions: ["hinge": 90], driving: "hinge")
        XCTAssertNil(pose.solidTransforms[0])
        assertPoint(transform([10, 0, 0], pose.solidTransforms[1]), [1, 2, 3])
        assertPoint(transform([11, 0, 0], pose.solidTransforms[1]), [1, 3, 3])
        XCTAssertEqual(pose.positions["hinge"], 90)
    }

    func testSliderUsesConnectorAxisRatherThanWorldZ() throws {
        let motion = AssemblyMotion(grounded: ["base"], connectors: [
            .init(id: "base-axis", part: "base", origin: [0, 0, 0], xAxis: [0, 1, 0], zAxis: [1, 0, 0]),
            .init(id: "arm-axis", part: "arm", origin: [0, 0, 0], xAxis: [0, 1, 0], zAxis: [1, 0, 0])
        ], joints: [.init(id: "slide", type: .slider, parent: "base-axis", child: "arm-axis", limits: [-20, 20])])
        let pose = try motion.solve(parts: pair, positions: ["slide": 12.5], driving: "slide")
        assertPoint(transform([1, 2, 3], pose.solidTransforms[1]), [13.5, 2, 3])
    }

    func testGroundingChildTraversesJointInReverse() throws {
        var motion = hinge()
        motion.grounded = ["arm"]
        let pose = try motion.solve(parts: pair, positions: ["hinge": 90], driving: "hinge")
        XCTAssertNil(pose.solidTransforms[1])
        assertPoint(transform([1, 0, 0], pose.solidTransforms[0]), [0, -1, 0])
    }

    func testFixedJointCarriesAChildThroughAChainWithoutMovingAnUnrelatedPart() throws {
        let parts = pair + [.init(id: "tool", name: "Tool", solidIndices: [2]),
                            .init(id: "other", name: "Other", solidIndices: [3])]
        var motion = hinge()
        motion.connectors += [.init(id: "arm-tip", part: "arm", origin: [2, 0, 0]),
                              .init(id: "tool-mount", part: "tool", origin: [2, 0, 0])]
        motion.joints += [.init(id: "mount", type: .fixed, parent: "arm-tip", child: "tool-mount")]
        let pose = try motion.solve(parts: parts, positions: ["hinge": 90], driving: "hinge")
        assertPoint(transform([3, 0, 0], pose.solidTransforms[2]), [0, 3, 0])
        XCTAssertNil(pose.solidTransforms[3])
        XCTAssertEqual(pose.positions["mount"], 0)
    }

    func testIdentityPoseOmitsNativeTransformWorkAndDefaultsRoundTrip() throws {
        let data = Data("""
        {"grounded":["base"],"connectors":[{"id":"base-axis","part":"base","origin":[0,0,0]},
                       {"id":"arm-axis","part":"arm","origin":[0,0,0]}],
         "joints":[{"id":"hinge","type":"revolute","parent":"base-axis","child":"arm-axis"}]}
        """.utf8)
        let motion = try JSONDecoder().decode(AssemblyMotion.self, from: data)
        XCTAssertEqual(motion.joints[0].position, 0)
        XCTAssertEqual(motion.joints[0].name, "hinge")
        XCTAssertEqual(try motion.solve(parts: pair).solidTransforms, [:])
        XCTAssertEqual(try JSONDecoder().decode(AssemblyMotion.self, from: JSONEncoder().encode(motion)), motion)
    }

    func testInvalidReferencesAxesLimitsAndAmbiguousPartOwnershipAreRejected() {
        var candidates = [AssemblyMotion]()
        var value = hinge(); value.connectors[1].part = "missing"; candidates.append(value)
        value = hinge(); value.connectors[1].xAxis = [0, 0, 2]; candidates.append(value)
        value = hinge(); value.connectors[1].xAxis = [2, 0, 0]; candidates.append(value)
        value = hinge(); value.connectors[1].origin = [.nan, 0, 0]; candidates.append(value)
        value = hinge(); value.connectors[1].id = value.connectors[0].id; candidates.append(value)
        value = hinge(); value.joints[0].child = "missing"; candidates.append(value)
        value = hinge(); value.joints[0].limits = [10, -10]; candidates.append(value)
        value = hinge(); value.joints[0].limits = [10, 20]; candidates.append(value)
        value = hinge(); value.joints[0].type = .fixed; value.joints[0].position = 1; candidates.append(value)
        value = hinge(); value.grounded = ["base", "base"]; candidates.append(value)
        for candidate in candidates { XCTAssertThrowsError(try candidate.solve(parts: pair)) }
        XCTAssertThrowsError(try hinge().solve(parts: [pair[0], .init(id: "arm", name: "Arm", solidIndices: [0])]))
        XCTAssertThrowsError(try hinge().solve(parts: [pair[0], .init(id: "arm", name: "Arm", solidIndices: [], children: [pair[1]])]))
        XCTAssertThrowsError(try hinge().solve(parts: pair, positions: ["missing": 0]))
        XCTAssertThrowsError(try hinge().solve(parts: pair, positions: ["hinge": .infinity]))
    }

    func testRequestedPositionOutsideLimitsIsRejectedWithoutClamping() {
        var motion = hinge()
        motion.joints[0].limits = [-45, 45]
        XCTAssertThrowsError(try motion.solve(parts: pair, positions: ["hinge": 46], driving: "hinge"))
        XCTAssertNoThrow(try motion.solve(parts: pair, positions: ["hinge": -45], driving: "hinge"))
    }

    func testClosedFourBarUpdatesPassiveJointsAndPreservesBranchContinuity() throws {
        let (motion, parts) = fourBar()
        let pose = try motion.solve(parts: parts, positions: ["a": 30], driving: "a")
        XCTAssertEqual(pose.positions["a"]!, 30, accuracy: 1e-8)
        XCTAssertEqual(pose.positions["b"]!, -30, accuracy: 1e-5)
        XCTAssertEqual(pose.positions["c"]!, 30, accuracy: 1e-5)
        XCTAssertEqual(pose.positions["d"]!, 30, accuracy: 1e-5)
        let dx = -0.5, dy = sqrt(3) / 2 - 1
        assertPoint(transform([0, 1, 0], pose.solidTransforms[2]), [dx, 1 + dy, 0], accuracy: 1e-6)
        assertPoint(transform([4, 1, 0], pose.solidTransforms[2]), [4 + dx, 1 + dy, 0], accuracy: 1e-6)
        let replay = try motion.solve(parts: parts, positions: pose.positions)
        for solid in pose.solidTransforms.keys {
            assertPoint(transform([1, 2, 3], replay.solidTransforms[solid]), transform([1, 2, 3], pose.solidTransforms[solid]), accuracy: 1e-6)
        }
        var nextPositions = pose.positions; nextPositions["a"] = 35
        let next = try motion.solve(parts: parts, positions: nextPositions, driving: "a")
        XCTAssertEqual(next.positions["b"]!, -35, accuracy: 1e-5)
        XCTAssertEqual(next.positions["d"]!, 35, accuracy: 1e-5)
    }

    func testClosedMechanismCannotViolatePassiveJointLimit() {
        var (motion, parts) = fourBar()
        motion.joints[1].limits = [-20, 20]
        XCTAssertThrowsError(try motion.solve(parts: parts, positions: ["a": 30], driving: "a"))
    }

    func testLargeClosedMechanismKeepsPhysicalClosureTolerance() throws {
        var (motion, parts) = fourBar()
        for index in motion.connectors.indices { motion.connectors[index].origin = motion.connectors[index].origin.map { $0 * 100_000 } }
        let pose = try motion.solve(parts: parts, positions: ["a": 30], driving: "a")
        let coupled = transform([400_000, 100_000, 0], pose.solidTransforms[2])
        let follower = transform([400_000, 100_000, 0], pose.solidTransforms[3])
        assertPoint(coupled, follower, accuracy: 1e-6)
    }

    func testClosedLoopLeavesManyUnrelatedOpenJointsAndLockedCoordinatesUnchanged() throws {
        var (motion, parts) = fourBar()
        for index in 0..<200 {
            let identity = "open-\(index)"
            parts.append(.init(id: identity, name: identity, solidIndices: [index + 4]))
            motion.connectors.append(.init(id: identity, part: identity, origin: [0, 0, 0]))
            motion.joints.append(.init(id: identity, type: .revolute, parent: "a0", child: identity,
                                       position: 20, limits: index == 199 ? [20, 20] : [-45, 45]))
        }
        let pose = try motion.solve(parts: parts, positions: ["a": 30], driving: "a")
        XCTAssertEqual(pose.positions["b"]!, -30, accuracy: 1e-5)
        for index in 0..<200 {
            XCTAssertEqual(pose.positions["open-\(index)"], 20)
            assertPoint(transform([1, 0, 0], pose.solidTransforms[index + 4]), [cos(.pi / 9), sin(.pi / 9), 0])
        }
    }

    func testCommonUpstreamJointMovesAClosedMechanismAsOneRigidAssembly() throws {
        var (motion, parts) = fourBar()
        parts.append(.init(id: "mount", name: "Mount", solidIndices: [4]))
        motion.grounded = ["mount"]
        motion.connectors.append(.init(id: "mount", part: "mount", origin: [0, 0, 0]))
        motion.joints.append(.init(id: "mount", type: .revolute, parent: "mount", child: "a0", position: 17))
        let pose = try motion.solve(parts: parts, positions: ["a": 30], driving: "a")
        XCTAssertEqual(pose.positions["mount"], 17)
        XCTAssertEqual(pose.positions["b"]!, -30, accuracy: 1e-5)
        let x = -0.5, y = sqrt(3) / 2, angle = 17 * Double.pi / 180
        assertPoint(transform([0, 1, 0], pose.solidTransforms[2]),
                    [x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle), 0], accuracy: 1e-6)
    }

    func testCancelledTaskDoesNotPublishEvenAnImmediatelySolvableTreePose() async {
        let motion = hinge(), parts = pair
        let calculation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try motion.solve(parts: parts)
        }
        do {
            _ = try await calculation.value
            XCTFail("A cancelled solve must throw before publishing its pose")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation result: \(error)")
        }
    }

    func testInconsistentFixedLoopAndConflictingGroundsFail() {
        var motion = hinge()
        motion.joints[0].type = .fixed
        motion.connectors += [.init(id: "other-base", part: "base", origin: [1, 0, 0]),
                              .init(id: "other-arm", part: "arm", origin: [0, 0, 0])]
        motion.joints += [.init(id: "other", type: .fixed, parent: "other-base", child: "other-arm")]
        XCTAssertThrowsError(try motion.solve(parts: pair))
        motion = hinge(); motion.grounded = ["base", "arm"]
        XCTAssertThrowsError(try motion.solve(parts: pair, positions: ["hinge": 30], driving: "hinge"))
    }

    func testConnectedAssembliesRequireExplicitGroundAndUnusedPartsStayStationary() throws {
        var motion = hinge(); motion.grounded = []
        XCTAssertThrowsError(try motion.solve(parts: pair, positions: ["hinge": 90], driving: "hinge"))
        motion.joints = []
        let pose = try motion.solve(parts: pair)
        XCTAssertNil(pose.solidTransforms[0])
        XCTAssertNil(pose.solidTransforms[1])
    }

    private var pair: [PartNode] {
        [.init(id: "base", name: "Base", solidIndices: [0]), .init(id: "arm", name: "Arm", solidIndices: [1])]
    }

    private func hinge() -> AssemblyMotion {
        AssemblyMotion(grounded: ["base"], connectors: [
            .init(id: "base-axis", part: "base", origin: [0, 0, 0]),
            .init(id: "arm-axis", part: "arm", origin: [0, 0, 0])
        ], joints: [.init(id: "hinge", name: "Hinge", type: .revolute, parent: "base-axis", child: "arm-axis")])
    }

    private func fourBar() -> (AssemblyMotion, [PartNode]) {
        let names = ["ground", "crank", "coupler", "follower"]
        let parts = names.enumerated().map { PartNode(id: $0.element, name: $0.element, solidIndices: [$0.offset]) }
        let connectors: [AssemblyConnector] = [
            .init(id: "a0", part: "ground", origin: [0, 0, 0]), .init(id: "a1", part: "crank", origin: [0, 0, 0]),
            .init(id: "b1", part: "crank", origin: [0, 1, 0]), .init(id: "b2", part: "coupler", origin: [0, 1, 0]),
            .init(id: "c2", part: "coupler", origin: [4, 1, 0]), .init(id: "c3", part: "follower", origin: [4, 1, 0]),
            .init(id: "d0", part: "ground", origin: [4, 0, 0]), .init(id: "d3", part: "follower", origin: [4, 0, 0])
        ]
        let joints: [AssemblyJoint] = [
            .init(id: "a", type: .revolute, parent: "a0", child: "a1", limits: [-60, 60]),
            .init(id: "b", type: .revolute, parent: "b1", child: "b2", limits: [-90, 90]),
            .init(id: "c", type: .revolute, parent: "c2", child: "c3", limits: [-90, 90]),
            .init(id: "d", type: .revolute, parent: "d0", child: "d3", limits: [-90, 90])
        ]
        return (AssemblyMotion(grounded: ["ground"], connectors: connectors, joints: joints), parts)
    }

    private func transform(_ point: [Double], _ matrix: [Double]?) -> [Double] {
        let matrix = matrix ?? AssemblyPose.identityTransform
        return (0..<3).map { matrix[$0 * 4] * point[0] + matrix[$0 * 4 + 1] * point[1] + matrix[$0 * 4 + 2] * point[2] + matrix[$0 * 4 + 3] }
    }

    private func assertPoint(_ actual: [Double], _ expected: [Double], accuracy: Double = 1e-8,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) { XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line) }
    }
}
