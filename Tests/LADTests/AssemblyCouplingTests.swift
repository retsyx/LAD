import XCTest
@testable import LAD

final class AssemblyCouplingTests: XCTestCase {
    func testLinearCouplingTurnsTheFollowerAboutItsOwnAxisAndIgnoresStaleCoordinates() throws {
        let motion = gears(.linear(id: "mesh", driver: "a", follower: "b", ratio: -0.5))
        let pose = try motion.solve(parts: parts, positions: ["a": 40, "b": 999], driving: "a")
        XCTAssertEqual(pose.positions["a"], 40)
        XCTAssertEqual(pose.positions["b"]!, -20, accuracy: 1e-12)
        assertPoint(transform([15, 0, 0], pose.solidTransforms[2]), [10 + 5 * cos(-.pi / 9), 5 * sin(-.pi / 9), 0])
        let replay = try motion.solve(parts: parts, positions: pose.positions)
        XCTAssertEqual(replay, pose)
    }

    func testPeriodicTableDwellsIndexesAndAccumulatesAcrossTurns() throws {
        for samples in [[[0.0, 0], [120, 0], [240, -60]], [[0.0, 0], [120, 0], [240, -60], [360, -60]]] {
            let motion = gears(.table(id: "index", driver: "a", follower: "b", samples: samples, period: 360, advance: -60))
            for (driver, expected) in [(0.0, 0.0), (60, 0), (180, -30), (240, -60), (360, -60), (540, -90),
                                       (720, -120), (-180, 30), (-360, 60)] {
                let pose = try motion.solve(parts: parts, positions: ["a": driver], driving: "a")
                XCTAssertEqual(pose.positions["b"]!, expected, accuracy: 1e-9, "driver \(driver)")
            }
        }
    }

    func testNonperiodicTableInterpolatesWithinItsDriverLimits() throws {
        var motion = gears(.table(id: "cam", driver: "a", follower: "b", samples: [[-90, 0], [0, 10], [90, 0]]))
        motion.joints[0].limits = [-90, 90]
        let pose = try motion.solve(parts: parts, positions: ["a": 45], driving: "a")
        XCTAssertEqual(pose.positions["b"]!, 5, accuracy: 1e-12)
        XCTAssertThrowsError(try motion.solve(parts: parts, positions: ["a": 91], driving: "a"))
    }

    func testFollowerCannotBeDrivenDirectlyOrLeaveItsLimits() {
        var motion = gears(.linear(id: "mesh", driver: "a", follower: "b", ratio: -0.5))
        XCTAssertThrowsError(try motion.solve(parts: parts, positions: ["b": 10], driving: "b")) { error in
            XCTAssertTrue(error.localizedDescription.contains("follows Driver"))
        }
        XCTAssertThrowsError(try motion.requireIndependent("b"))
        XCTAssertNoThrow(try motion.requireIndependent("a"))
        XCTAssertEqual(motion.driver(of: "b")?.id, "a")
        XCTAssertNil(motion.driver(of: "a"))
        motion.joints[1].limits = [-15, 15]
        XCTAssertNoThrow(try motion.solve(parts: parts, positions: ["a": 30], driving: "a"))
        XCTAssertThrowsError(try motion.solve(parts: parts, positions: ["a": 40], driving: "a"))
    }

    func testChainedCouplingsResolveInDependencyOrder() throws {
        var motion = gears(.linear(id: "second", driver: "b", follower: "c", ratio: 3))
        motion.couplings.append(.linear(id: "first", driver: "a", follower: "b", ratio: -0.5, offset: 1))
        let pose = try motion.solve(parts: parts, positions: ["a": 10], driving: "a")
        XCTAssertEqual(pose.positions["b"]!, -4, accuracy: 1e-12)
        XCTAssertEqual(pose.positions["c"]!, -12, accuracy: 1e-12)
    }

    func testInvalidCouplingsAreRejected() {
        let linear = AssemblyCoupling.linear(id: "mesh", driver: "a", follower: "b", ratio: 1)
        var candidates = [AssemblyMotion]()
        func add(_ coupling: AssemblyCoupling, _ change: (inout AssemblyMotion) -> Void = { _ in }) {
            var motion = gears(coupling); change(&motion); candidates.append(motion)
        }
        add(.linear(id: "mesh", driver: "missing", follower: "b", ratio: 1))
        add(.linear(id: "mesh", driver: "a", follower: "a", ratio: 1))
        add(.linear(id: "mesh", driver: "a", follower: "b", ratio: 0))
        add(.linear(id: "mesh", driver: "a", follower: "b", ratio: .nan))
        add(AssemblyCoupling(id: "mesh", type: .linear, driver: "a", follower: "b", ratio: 1, samples: [[0, 0], [1, 1]]))
        add(linear) { $0.couplings.append(.linear(id: "mesh", driver: "a", follower: "c", ratio: 1)) }
        add(linear) { $0.couplings.append(.linear(id: "again", driver: "c", follower: "b", ratio: 1)) }
        add(linear) { $0.couplings.append(.linear(id: "back", driver: "b", follower: "a", ratio: 1)) }
        add(linear) { $0.joints[1].type = .fixed }
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0]], period: 360))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [0, 1]], period: 360))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [1]], period: 360))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [360, 1]], period: 360))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [361, 1]], period: 360))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [1, 1]], period: 0))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [1, 1]], advance: 1))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [90, 1]]))
        add(.table(id: "index", driver: "a", follower: "b", samples: [[0, 0], [90, 1]])) { $0.joints[0].limits = [-10, 90] }
        for (index, candidate) in candidates.enumerated() {
            XCTAssertThrowsError(try candidate.solve(parts: parts), "candidate \(index)")
        }
    }

    func testFollowerInAClosedLoopIsDrivenThroughItsIndependentRoot() throws {
        var (motion, parts) = fourBar()
        parts.append(.init(id: "motor", name: "Motor", solidIndices: [4]))
        motion.connectors += [.init(id: "m0", part: "ground", origin: [0, -5, 0]), .init(id: "m1", part: "motor", origin: [0, -5, 0])]
        motion.joints.append(.init(id: "motor", type: .revolute, parent: "m0", child: "m1", limits: [-120, 120]))
        motion.couplings = [.linear(id: "reduction", driver: "motor", follower: "a", ratio: 0.5)]
        let pose = try motion.solve(parts: parts, positions: ["motor": 60], driving: "motor")
        XCTAssertEqual(pose.positions["motor"]!, 60, accuracy: 1e-12)
        XCTAssertEqual(pose.positions["a"]!, 30, accuracy: 1e-9)
        XCTAssertEqual(pose.positions["b"]!, -30, accuracy: 1e-5)
        XCTAssertEqual(pose.positions["d"]!, 30, accuracy: 1e-5)
        let coupled = transform([4, 1, 0], pose.solidTransforms[2]), follower = transform([4, 1, 0], pose.solidTransforms[3])
        assertPoint(coupled, follower, accuracy: 1e-6)
    }

    func testDraggingAFollowerPartMovesItsDriver() throws {
        let motion = gears(.linear(id: "mesh", driver: "a", follower: "b", ratio: -0.5))
        XCTAssertTrue(motion.canGrab(solidIndex: 2, parts: parts))
        let context = try XCTUnwrap(motion.prepareGrab(parts: parts, solidIndex: 2, point: [15, 0, 0], projection: orthographic))
        let goal = try XCTUnwrap(orthographic.project([10 + 5 * cos(-.pi / 6), 5 * sin(-.pi / 6), 0]))
        let pose = try context.solve(screenPoint: goal)
        XCTAssertEqual(pose.positions["b"]!, -30, accuracy: 0.2)
        XCTAssertEqual(pose.positions["a"]!, -2 * pose.positions["b"]!, accuracy: 1e-9)
    }

    func testDwellLocksAnIndexedFollowerAgainstDragging() throws {
        let motion = gears(.table(id: "index", driver: "a", follower: "b",
                                  samples: [[0, 0], [120, 0], [240, -60]], period: 360, advance: -60))
        let context = try XCTUnwrap(motion.prepareGrab(parts: parts, solidIndex: 2, point: [15, 0, 0], projection: orthographic))
        let goal = try XCTUnwrap(orthographic.project([10 + 5 * cos(-.pi / 6), 5 * sin(-.pi / 6), 0]))
        let pose = try context.solve(screenPoint: goal)
        XCTAssertEqual(pose.positions["b"]!, 0, accuracy: 1e-12)
        XCTAssertNil(pose.solidTransforms[2])
    }

    func testCouplingsDecodeRoundTripAndDefaultToNone() throws {
        let data = Data("""
        {"grounded":["base"],"connectors":[{"id":"x","part":"base","origin":[0,0,0]},{"id":"y","part":"driver","origin":[0,0,0]},
          {"id":"z","part":"base","origin":[10,0,0]},{"id":"w","part":"follower","origin":[10,0,0]}],
         "joints":[{"id":"a","type":"revolute","parent":"x","child":"y"},{"id":"b","type":"revolute","parent":"z","child":"w"}],
         "couplings":[{"id":"index","type":"table","driver":"a","follower":"b","samples":[[0,0],[120,0],[240,-60]],
                       "period":360,"advance":-60}]}
        """.utf8)
        let motion = try JSONDecoder().decode(AssemblyMotion.self, from: data)
        XCTAssertEqual(motion.couplings, [.table(id: "index", driver: "a", follower: "b",
                                                 samples: [[0, 0], [120, 0], [240, -60]], period: 360, advance: -60)])
        XCTAssertEqual(try JSONDecoder().decode(AssemblyMotion.self, from: JSONEncoder().encode(motion)), motion)
        XCTAssertEqual(try motion.solve(parts: Array(parts.prefix(3)), positions: ["a": 180], driving: "a").positions["b"]!,
                       -30, accuracy: 1e-12)
        let plain = try JSONDecoder().decode(AssemblyMotion.self, from: Data("""
        {"grounded":[],"connectors":[],"joints":[]}
        """.utf8))
        XCTAssertEqual(plain.couplings, [])
    }

    @MainActor
    func testDesignPaneIgnoresDirectFollowerPositionsAndMovesItWithItsDriver() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-coupling-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root))
        state.newProjectWithSubmittedRequest()
        let motion = gears(.linear(id: "mesh", driver: "a", follower: "b", ratio: -0.5))
        var preview = PreviewMesh(vertices: [[0,0,0]], triangles: [[0,0,0]], edges: [], bounds: [-1,-1,-1,20,1,1],
                                  volume: 1, area: 1, solids: 4, faces: 4, buildSeconds: 0, threads: 1, stepPath: "coupling-fixture")
        preview.parts = parts; preview.assemblyMotion = motion
        preview.assemblyPose = try motion.solve(parts: parts)
        let revision = ProjectRevision(model: ModelSpec(title: "Gears", summary: "Coupled", units: "mm", script: "result=None"),
                                       preview: preview, parts: parts)
        state.revisions = [revision]; state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        state.setJointPosition("b", to: 10)
        XCTAssertFalse(state.isSolvingAssembly)
        state.setJointPosition("a", to: 40)
        let deadline = ContinuousClock.now + .seconds(5)
        while state.isSolvingAssembly, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try XCTUnwrap(state.assemblyPose?.positions["b"]), -20, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(state.revisions[0].jointPositions?["b"]), -20, accuracy: 1e-12)
        await state.prepareToQuit()
    }

    // Base, driver wheel at the origin, follower wheel at x = 10, and a third
    // wheel at x = 20 for chained couplings.
    private var parts: [PartNode] {
        [.init(id: "base", name: "Base", solidIndices: [0]), .init(id: "driver", name: "Driver", solidIndices: [1]),
         .init(id: "follower", name: "Follower", solidIndices: [2]), .init(id: "third", name: "Third", solidIndices: [3])]
    }

    private func gears(_ coupling: AssemblyCoupling) -> AssemblyMotion {
        AssemblyMotion(grounded: ["base"], connectors: [
            .init(id: "x", part: "base", origin: [0, 0, 0]), .init(id: "y", part: "driver", origin: [0, 0, 0]),
            .init(id: "z", part: "base", origin: [10, 0, 0]), .init(id: "w", part: "follower", origin: [10, 0, 0]),
            .init(id: "u", part: "base", origin: [20, 0, 0]), .init(id: "v", part: "third", origin: [20, 0, 0])
        ], joints: [
            .init(id: "a", name: "Driver", type: .revolute, parent: "x", child: "y"),
            .init(id: "b", name: "Follower", type: .revolute, parent: "z", child: "w"),
            .init(id: "c", name: "Third", type: .revolute, parent: "u", child: "v")
        ], couplings: [coupling])
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

    private var orthographic: AssemblyGrabProjection {
        .init(worldToClip: [0.05, 0, 0, 0, 0, 0.05, 0, 0, 0, 0, -0.05, 0, 0, 0, 0, 1], viewportSize: [800, 600])
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
