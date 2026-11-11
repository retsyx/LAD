import Foundation
import XCTest
@testable import LAD

final class AppStateAssemblyGrabTests: XCTestCase {
    @MainActor
    func testGrabCoalescesTargetsAndClosingThenQuittingWaitsForReleasedFinalPose() async throws {
        let gate = GrabSolveGate()
        let fixture = try Fixture(gate: gate)
        defer { fixture.cleanUp() }
        let state = fixture.state, owner = UUID()
        XCTAssertTrue(fixture.begin(owner))
        state.moveAssemblyGrab(ownerID: owner, screenPoint: [230, 200])
        try await waitForCalls(gate, 1)
        for x in stride(from: 240.0, through: 270, by: 5) {
            state.moveAssemblyGrab(ownerID: owner, screenPoint: [x, 200])
        }
        state.endAssemblyGrab(ownerID: owner)
        XCTAssertFalse(state.isGrabbingAssembly)
        XCTAssertTrue(state.isSolvingAssembly)
        XCTAssertFalse(fixture.begin(UUID()), "A released final pose must drain before starting another grab.")
        let coordinator = coordinator()
        let windowID = UUID()
        coordinator.register(state, id: windowID, sourceURL: nil)
        coordinator.windowClosed(windowID)
        var quitFinished = false
        let quitting = Task { let result = await coordinator.prepareToQuit(); quitFinished = true; return result }
        await Task.yield()
        XCTAssertFalse(quitFinished)
        await gate.release(0)
        try await waitForCalls(gate, 2)
        XCTAssertFalse(quitFinished, "Quit must drain the final target queued behind the first solve.")
        await gate.release(1)
        let shouldQuit = await quitting.value
        XCTAssertTrue(shouldQuit, state.saveStatus ?? "")

        let calls = await gate.calls()
        XCTAssertEqual(calls.map(\.point), [[230, 200], [270, 200]])
        XCTAssertEqual(calls[1].positions["slide"], 1, "The next target starts from the last valid pose.")
        XCTAssertEqual(state.assemblyPose?.positions["slide"], 3)
        XCTAssertEqual(state.revisions[0].jointPositions, ["slide": 3])
        XCTAssertFalse(state.isSolvingAssembly)
        XCTAssertNil(state.assemblyMotionError)
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL, state.saveStatus ?? ""))
        XCTAssertEqual(saved.revisions[0].jointPositions, ["slide": 3])
        XCTAssertEqual(saved.revisions[0].model.script, fixture.model.script)
        XCTAssertNil(saved.revisions[0].preview)
    }

    @MainActor
    func testRecoverySaveWaitsForReleasedPoseWithoutPriorQuitPreparation() async throws {
        let gate = GrabSolveGate()
        let fixture = try Fixture(gate: gate)
        defer { fixture.cleanUp() }
        let state = fixture.state, owner = UUID()
        XCTAssertTrue(fixture.begin(owner))
        state.moveAssemblyGrab(ownerID: owner, screenPoint: [250, 200])
        try await waitForCalls(gate, 1)
        state.endAssemblyGrab(ownerID: owner)
        let target = fixture.directory.appendingPathComponent("Recovery copy.lad")
        var saveFinished = false
        let saving = Task { try await state.saveProjectForQuit(to: target); saveFinished = true }
        await Task.yield()
        XCTAssertFalse(saveFinished)
        await gate.release(0)
        try await saving.value
        XCTAssertEqual(try ProjectStore.read(from: target).revisions[0].jointPositions, ["slide": 2])
        await state.prepareToQuit()
    }

    @MainActor
    func testActualGrabChangesOnlyPoseAndRetainsSelectionsAndView() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state, owner = UUID()
        let feature = CADFeatureID(kind: .vertex, solidIndex: 1, localIndex: 0)
        state.selectFeatures([feature])
        state.selectedSolids = [0]
        state.selectedPartNodeIDs = ["base"]
        state.viewportCommand = ViewportCommand(.top)
        let command = state.viewportCommand
        let vertices = state.mesh?.vertices, triangles = state.mesh?.triangles, edges = state.mesh?.edges
        let meshPath = state.mesh?.stepPath
        let originalRevisionID = state.selectedRevisionID
        let originalModel = state.current

        XCTAssertTrue(fixture.begin(owner))
        state.moveAssemblyGrab(ownerID: owner, screenPoint: [250, 200])
        state.endAssemblyGrab(ownerID: owner)
        try await waitForIdle(state)
        // The grab solver's subpixel target tolerance permits this much joint
        // displacement at the fixture's 20 screen points per millimeter.
        XCTAssertEqual(try XCTUnwrap(state.assemblyPose?.positions["slide"]), 2, accuracy: 0.001)
        XCTAssertEqual(state.mesh?.vertices, vertices)
        XCTAssertEqual(state.mesh?.triangles, triangles)
        XCTAssertEqual(state.mesh?.edges, edges)
        XCTAssertEqual(state.mesh?.stepPath, meshPath)
        XCTAssertEqual(state.current, originalModel)
        XCTAssertEqual(state.selectedRevisionID, originalRevisionID)
        XCTAssertEqual(state.revisions.count, 1)
        XCTAssertEqual(state.selectedFeatures, [feature])
        XCTAssertEqual(state.selectedSolids, [0])
        XCTAssertEqual(state.selectedPartNodeIDs, ["base"])
        XCTAssertEqual(state.viewportCommand, command, "A grab must not request camera movement.")
        XCTAssertEqual(state.projectionMode, .perspective)
        state.clearSelections()
        await state.prepareToQuit()
    }

    @MainActor
    func testBusyHiddenGroundedAndUnconnectedPartsCannotStartAGrab() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        XCTAssertTrue(state.canManipulateAssembly)
        XCTAssertFalse(fixture.begin(UUID(), solid: 0), "Grounded parts remain fixed.")
        XCTAssertFalse(fixture.begin(UUID(), solid: 2), "Unconnected geometry is not free-moving.")
        XCTAssertFalse(fixture.begin(UUID(), solid: -1))
        state.hiddenSolids = [1]
        XCTAssertFalse(fixture.begin(UUID()))
        state.hiddenSolids = []
        state.isWorking = true
        XCTAssertFalse(state.canManipulateAssembly)
        XCTAssertFalse(fixture.begin(UUID()))
        state.isWorking = false
        let owner = UUID()
        XCTAssertTrue(fixture.begin(owner))
        XCTAssertFalse(fixture.begin(UUID()), "Another window cannot steal an active grab.")
        state.cancelAssemblyGrab(ownerID: owner)
        XCTAssertFalse(state.isGrabbingAssembly)
        XCTAssertFalse(state.isSolvingAssembly)
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 0])
        await state.prepareToQuit()
    }

    @MainActor
    func testCancellationAndGeometryReplacementRejectNoncooperativeLateSolves() async throws {
        let gate = GrabSolveGate()
        let fixture = try Fixture(gate: gate)
        defer { fixture.cleanUp() }
        let state = fixture.state, owner = UUID()
        XCTAssertTrue(fixture.begin(owner))
        state.moveAssemblyGrab(ownerID: owner, screenPoint: [250, 200])
        try await waitForCalls(gate, 1)
        // A replacement can reuse every external artifact path. It still owns
        // a new topology and must invalidate work prepared for the old one.
        let replacement = try XCTUnwrap(state.mesh)
        state.mesh = replacement
        XCTAssertFalse(state.isGrabbingAssembly)
        await gate.release(0)
        try await waitForIdle(state)
        await Task.yield()
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 0])
        XCTAssertNil(state.revisions[0].jointPositions)

        let secondOwner = UUID()
        XCTAssertTrue(fixture.begin(secondOwner))
        state.moveAssemblyGrab(ownerID: secondOwner, screenPoint: [270, 200])
        try await waitForCalls(gate, 2)
        state.newProject()
        await gate.release(1)
        await Task.yield()
        XCTAssertNil(state.mesh)
        XCTAssertNil(state.assemblyPose)
        XCTAssertTrue(state.revisions.isEmpty)
        XCTAssertFalse(state.isSolvingAssembly)
        await state.prepareToQuit()
    }

    @MainActor
    func testRevisionChangesAndBusyBuildsInvalidatePendingGrabs() async throws {
        let gate = GrabSolveGate()
        let fixture = try Fixture(gate: gate)
        defer { fixture.cleanUp() }
        let state = fixture.state, owner = UUID()
        let firstRevision = try XCTUnwrap(state.revisions.first)
        let second = ProjectRevision(model: fixture.model, preview: fixture.preview, parts: fixture.parts)
        state.revisions.append(second)
        XCTAssertTrue(fixture.begin(owner))
        state.moveAssemblyGrab(ownerID: owner, screenPoint: [250, 200])
        try await waitForCalls(gate, 1)
        state.selectRevision(second.id)
        await gate.release(0)
        await Task.yield()
        XCTAssertEqual(state.selectedRevisionID, second.id)
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 0])
        XCTAssertNil(state.revisions.first { $0.id == firstRevision.id }?.jointPositions)

        let nextOwner = UUID()
        XCTAssertTrue(fixture.begin(nextOwner))
        state.moveAssemblyGrab(ownerID: nextOwner, screenPoint: [270, 200])
        try await waitForCalls(gate, 2)
        state.isWorking = true
        await gate.release(1)
        await Task.yield()
        XCTAssertFalse(state.isGrabbingAssembly)
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 0])
        XCTAssertNil(state.revisions.first { $0.id == second.id }?.jointPositions)
        state.isWorking = false

        let hiddenOwner = UUID()
        XCTAssertTrue(fixture.begin(hiddenOwner))
        state.moveAssemblyGrab(ownerID: hiddenOwner, screenPoint: [290, 200])
        try await waitForCalls(gate, 3)
        state.hiddenSolids = [1]
        await gate.release(2)
        await Task.yield()
        XCTAssertFalse(state.isGrabbingAssembly)
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 0])
        state.hiddenSolids = []
        await state.prepareToQuit()
    }

    @MainActor
    func testStaleOwnerEventsCannotCancelAnotherWindowsNewGrab() async throws {
        let gate = GrabSolveGate()
        let fixture = try Fixture(gate: gate)
        defer { fixture.cleanUp() }
        let state = fixture.state, first = UUID(), second = UUID()
        XCTAssertTrue(fixture.begin(first))
        state.moveAssemblyGrab(ownerID: first, screenPoint: [230, 200])
        try await waitForCalls(gate, 1)
        state.cancelAssemblyGrab(ownerID: first)
        XCTAssertTrue(fixture.begin(second))
        state.moveAssemblyGrab(ownerID: second, screenPoint: [270, 200])
        try await waitForCalls(gate, 2)
        state.moveAssemblyGrab(ownerID: first, screenPoint: [290, 200])
        state.endAssemblyGrab(ownerID: first)
        state.cancelAssemblyGrab(ownerID: first)
        XCTAssertTrue(state.isGrabbingAssembly)
        await gate.release(0)
        await Task.yield()
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 0])
        state.endAssemblyGrab(ownerID: second)
        await gate.release(1)
        try await waitForIdle(state)
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 3])
        let calls = await gate.calls()
        XCTAssertEqual(calls.count, 2)
        await state.prepareToQuit()
    }

    @MainActor
    func testClosingAnActiveGrabCancelsPendingTargetAndKeepsLastAcceptedPose() async throws {
        let gate = GrabSolveGate()
        let fixture = try Fixture(gate: gate)
        defer { fixture.cleanUp() }
        let state = fixture.state, owner = UUID()
        XCTAssertTrue(fixture.begin(owner))
        state.moveAssemblyGrab(ownerID: owner, screenPoint: [230, 200])
        try await waitForCalls(gate, 1)
        await gate.release(0)
        try await waitForIdle(state)
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 1])
        state.moveAssemblyGrab(ownerID: owner, screenPoint: [250, 200])
        try await waitForCalls(gate, 2)
        let coordinator = coordinator()
        let windowID = UUID()
        coordinator.register(state, id: windowID, sourceURL: nil)
        coordinator.windowClosed(windowID)
        XCTAssertFalse(state.isGrabbingAssembly)
        XCTAssertFalse(state.isSolvingAssembly)
        let shouldQuit = await coordinator.prepareToQuit()
        XCTAssertTrue(shouldQuit, state.saveStatus ?? "")
        await gate.release(1)
        await Task.yield()
        XCTAssertEqual(state.assemblyPose?.positions, ["slide": 1])
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL, state.saveStatus ?? ""))
        XCTAssertEqual(saved.revisions[0].jointPositions, ["slide": 1])
    }

    @MainActor
    private func coordinator() -> ProjectWindowCoordinator {
        ProjectWindowCoordinator(saveUnsavedProject: { state in
            XCTFail("Grab fixture could not autosave: \(state.saveStatus ?? "unknown failure")")
            return false
        })
    }

    @MainActor
    private func waitForCalls(_ gate: GrabSolveGate, _ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.calls().count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard await gate.calls().count >= count else { throw TestFailure.timedOut }
    }

    @MainActor
    private func waitForIdle(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while state.isSolvingAssembly, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard !state.isSolvingAssembly else { throw TestFailure.timedOut }
    }

    private enum TestFailure: Error { case timedOut }

    /// The analytic test mechanism has a single X slider. Holding these exact
    /// valid poses makes queue ordering deterministic, including late replies
    /// from a solver that deliberately ignores task cancellation.
    private actor GrabSolveGate {
        struct Call: Sendable {
            var point: [Double]
            var positions: [String: Double]
        }
        private var received: [Call] = []
        private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

        func solve(_ context: AssemblyGrabContext, positions: [String: Double], screenPoint: [Double]) async -> AssemblyPose {
            let index = received.count
            received.append(Call(point: screenPoint, positions: positions))
            await withCheckedContinuation { pending[index] = $0 }
            let position = (screenPoint[0] - 210) / 20
            return AssemblyPose(positions: ["slide": position], solidTransforms: [1: [
                1, 0, 0, position, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]])
        }

        func calls() -> [Call] { received }
        func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
        func releaseAll() {
            let waiting = Array(pending.values)
            pending.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let state: AppState
        let gate: GrabSolveGate?
        let parts = [PartNode(id: "base", name: "Base", solidIndices: [0]),
                     PartNode(id: "arm", name: "Arm", solidIndices: [1]),
                     PartNode(id: "loose", name: "Loose", solidIndices: [2])]
        let model = ModelSpec(title: "Sliding assembly", summary: "A constrained slider", units: "mm", script: """
        result=cq.Assembly(name='Sliding assembly')
        result.add(cq.Solid.makeBox(.2,.2,.2).translate((-.6,0,0)),name='Base',metadata={'lad_id':'base'})
        result.add(cq.Solid.makeBox(.2,.2,.2).translate((.4,0,0)),name='Arm',metadata={'lad_id':'arm'})
        result.add(cq.Solid.makeBox(.2,.2,.2).translate((0,.6,0)),name='Loose',metadata={'lad_id':'loose'})
        result.metadata['lad_motion']={'grounded':['base'],'connectors':[
          {'id':'a','part':'base','origin':[0,0,0],'xAxis':[0,1,0],'zAxis':[1,0,0]},
          {'id':'b','part':'arm','origin':[0,0,0],'xAxis':[0,1,0],'zAxis':[1,0,0]}],
          'joints':[{'id':'slide','name':'Travel','type':'slider','parent':'a','child':'b','limits':[-5,5]}]}
        """)
        let projection = AssemblyGrabProjection(worldToClip: [
            0.1, 0, 0, 0, 0, 0.1, 0, 0, 0, 0, 0.1, 0, 0, 0, 0, 1], viewportSize: [400, 400])
        let preview: PreviewMesh

        init(gate: GrabSolveGate? = nil) throws {
            self.gate = gate
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-AppState-grab-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let store = ProjectAutosaveStore(rootDirectory: directory)
            if let gate {
                state = AppState(autosaveStore: store, python: "/missing/python", thumbnailRenderer: { _, _ in throw CancellationError() },
                    assemblyGrabSolver: { context, positions, point in await gate.solve(context, positions: positions, screenPoint: point) })
            } else {
                state = AppState(autosaveStore: store, python: "/missing/python", thumbnailRenderer: { _, _ in throw CancellationError() })
            }
            let motion = AssemblyMotion(grounded: ["base"], connectors: [
                .init(id: "a", part: "base", origin: [0, 0, 0], xAxis: [0, 1, 0], zAxis: [1, 0, 0]),
                .init(id: "b", part: "arm", origin: [0, 0, 0], xAxis: [0, 1, 0], zAxis: [1, 0, 0])], joints: [
                    .init(id: "slide", name: "Travel", type: .slider, parent: "a", child: "b", limits: [-5, 5])])
            let vertex = CADVertex(id: .init(kind: .vertex, solidIndex: 1, localIndex: 0), position: [0.5, 0, 0])
            let partFacts = (0..<3).map { index in CADPart(solidIndex: index, area: 0.24, volume: 0.008,
                bounds: [0,0,0,0.2,0.2,0.2], centroid: [0.1,0.1,0.1]) }
            var mesh = PreviewMesh(vertices: [[0,0,0],[0.2,0,0],[0,0.2,0]], triangles: [[0,1,2],[0,1,2],[0,1,2]],
                edges: [], bounds: [-0.6,0,0,0.6,0.8,0.2], volume: 0.024, area: 0.72, solids: 3, faces: 3,
                buildSeconds: 0, threads: 1, stepPath: directory.appendingPathComponent("model.step").path,
                triangleSolids: [0,1,2], edgeSolids: [], parts: parts,
                topology: CADTopology(vertices: [vertex], edges: [], faces: [], parts: partFacts))
            mesh.assemblyMotion = motion
            mesh.assemblyPose = try motion.solve(parts: parts)
            preview = mesh
            state.newProjectWithSubmittedRequest()
            let revision = ProjectRevision(model: model, preview: mesh, parts: parts)
            state.revisions = [revision]
            state.selectedRevisionID = revision.id
            XCTAssertTrue(state.loadStoredRevision())
        }

        func begin(_ owner: UUID, solid: Int = 1) -> Bool {
            state.beginAssemblyGrab(ownerID: owner, solidIndex: solid, point: [0.5, 0, 0], projection: projection)
        }

        func cleanUp() {
            state.cancel()
            if let gate { Task { await gate.releaseAll() } }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
