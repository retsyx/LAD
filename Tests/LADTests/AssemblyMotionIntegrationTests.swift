import Foundation
import XCTest
@testable import LAD

final class AssemblyMotionIntegrationTests: XCTestCase {
    private let parts = [PartNode(id: "base", name: "Base", solidIndices: [0]),
                         PartNode(id: "arm", name: "Arm", solidIndices: [1])]

    private var model: ModelSpec {
        ModelSpec(title: "Moving arm", summary: "A hinged arm", units: "mm", script: """
        result = cq.Assembly(name='Mechanism')
        result.add(cq.Solid.makeBox(2,2,2).translate((-10,0,0)), name='Base', metadata={'lad_id':'base'})
        result.add(cq.Solid.makeBox(2,4,6).translate((10,0,0)), name='Arm', metadata={'lad_id':'arm'})
        result.metadata['lad_motion'] = {'grounded':['base'], 'connectors':[
            {'id':'a','part':'base','origin':[0,0,0]}, {'id':'b','part':'arm','origin':[0,0,0]}],
            'joints':[{'id':'hinge','name':'Arm angle','type':'revolute','parent':'a','child':'b','limits':[-120,120]}]}
        """)
    }

    private var motion: AssemblyMotion {
        AssemblyMotion(grounded: ["base"], connectors: [
            AssemblyConnector(id: "a", part: "base", origin: [0, 0, 0]),
            AssemblyConnector(id: "b", part: "arm", origin: [0, 0, 0])], joints: [
                AssemblyJoint(id: "hinge", name: "Arm angle", type: .revolute, parent: "a", child: "b", limits: [-120, 120])])
    }

    func testPoseRoundtripsAndChangesOnlyThePartsSection() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root); ProjectPackage.clearSessionCache() }
        let url = root.appendingPathComponent("Moving arm.lad")
        let revision = ProjectRevision(model: model, parts: parts, jointPositions: ["hinge": 25])
        var project = LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id, projectID: UUID())
        try ProjectStore.write(project, to: url)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
        var immutable: [URL: (Data, NSNumber?, Date?)] = [:]
        for case let file as URL in enumerator where file.path.contains("/assets/") || file.lastPathComponent.hasPrefix("recipe-") {
            guard !file.hasDirectoryPath else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            if attrs[.type] as? FileAttributeType == .typeRegular {
                immutable[file] = (try Data(contentsOf: file), attrs[.systemFileNumber] as? NSNumber, attrs[.modificationDate] as? Date)
            }
        }
        project.revisions[0].jointPositions = ["hinge": 90]
        var metrics = ProjectPackage.WriteMetrics()
        try ProjectPackage.write(project, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.encodedRevisionRecipes, 0)
        XCTAssertEqual(metrics.encodedRevisionParts, 1)
        for (file, old) in immutable {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(try Data(contentsOf: file), old.0)
            XCTAssertEqual(attrs[.systemFileNumber] as? NSNumber, old.1)
            XCTAssertEqual(attrs[.modificationDate] as? Date, old.2)
        }
        ProjectPackage.clearSessionCache()
        let loaded = try ProjectStore.read(from: url)
        XCTAssertEqual(loaded.revisions[0].jointPositions, ["hinge": 90])
        XCTAssertNil(loaded.revisions[0].preview)
        XCTAssertEqual(loaded.revisions[0].model.script, model.script)
        let fresh = try SaveNewProject.snapshot(from: loaded)
        XCTAssertEqual(fresh.revisions[0].jointPositions, ["hinge": 90])
        let zipped = try ProjectStore.decode(ProjectStore.encode(project))
        XCTAssertEqual(zipped.revisions[0].jointPositions, ["hinge": 90])
    }

    @MainActor
    func testLatestPoseWinsAndCannotLeakAcrossRevisionsOrNewDesigns() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root))
        state.newProjectWithSubmittedRequest()
        var preview = PreviewMesh(vertices: [[0,0,0]], triangles: [[0,0,0]], edges: [], bounds: [-10,0,0,12,4,6],
                                  volume: 56, area: 112, solids: 2, faces: 12, buildSeconds: 0, threads: 1, stepPath: "motion-fixture")
        preview.parts = parts; preview.assemblyMotion = motion
        preview.assemblyPose = try motion.solve(parts: parts)
        let revision = ProjectRevision(model: model, preview: preview, parts: parts)
        state.revisions = [revision]; state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        state.setJointPosition("hinge", to: 30)
        state.setJointPosition("hinge", to: 90)
        try await waitForPose(state)
        XCTAssertEqual(try XCTUnwrap(state.assemblyPose?.positions["hinge"]), 90, accuracy: 1e-9)
        XCTAssertEqual(state.revisions[0].jointPositions, ["hinge": 90])
        let original = state.assemblyPose
        state.setJointPosition("hinge", to: 180)
        try await waitForPose(state)
        XCTAssertEqual(state.assemblyPose, original)
        XCTAssertNotNil(state.assemblyMotionError)
        state.resetAssemblyMotion()
        try await waitForPose(state)
        XCTAssertEqual(state.assemblyPose?.positions, ["hinge": 0])
        // An in-flight solve cannot install into the replacement window state.
        state.setJointPosition("hinge", to: 45)
        state.newProject()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(state.assemblyPose)
        XCTAssertNil(state.mesh)
        XCTAssertTrue(state.revisions.isEmpty)
        await state.prepareToQuit()
    }

    @MainActor
    func testNativePoseMeasurementsAndExportsAgreeAndDoNotMutateTheBuild() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for native assembly integration.")
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineService(temporaryDirectory: root)
        let python = EngineService.defaultPython
        var preview = try await engine.buildPreview(model, python: python, threads: 1)
        let native = URL(fileURLWithPath: try XCTUnwrap(preview.brepPath))
        let originalBytes = try Data(contentsOf: native)
        let motion = try XCTUnwrap(preview.assemblyMotion)
        preview.assemblyPose = try motion.solve(parts: try XCTUnwrap(preview.parts), positions: ["hinge": 90], driving: "hinge")
        let arm = try XCTUnwrap(preview.parts?.flatMap(\.flattened).first { $0.id == "arm" }?.solidIndices.first)
        let report = try await engine.measure(preview, features: [], solids: [arm], python: python, threads: 1)
        let centroid = try XCTUnwrap(report.metrics.first { $0.id == "parts:centroid" }?.values)
        for (actual, expected) in zip(centroid, [-2.0,11,3]) { XCTAssertEqual(actual, expected, accuracy: 1e-9) }
        let bounds = try XCTUnwrap(report.metrics.first { $0.id == "parts:minimum" }?.values)
        for (actual, expected) in zip(bounds, [-4.0,10,0]) { XCTAssertEqual(actual, expected, accuracy: 1e-6) }
        let step = try await engine.exportSTEP(preview, solidIndices: [arm], python: python, threads: 1)
        let restored = try await engine.previewSTEP(step, parts: nil, python: python, threads: 1)
        for (actual, expected) in zip(restored.bounds, [-4.0,10,0,0,12,6]) { XCTAssertEqual(actual, expected, accuracy: 1e-6) }
        preview.assemblyPose = try motion.solve(parts: preview.parts!, positions: ["hinge": 0])
        let rest = try await engine.exportSTEP(preview, solidIndices: [arm], python: python, threads: 1)
        XCTAssertNotEqual(step, rest, "STEP cache must include the pose")
        let restPreview = try await engine.previewSTEP(rest, parts: nil, python: python, threads: 1)
        for (actual, expected) in zip(restPreview.bounds, [10.0,0,0,12,4,6]) { XCTAssertEqual(actual, expected, accuracy: 1e-6) }
        XCTAssertEqual(try Data(contentsOf: native), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.stepPath), "Motion never exports over the validated build")
    }

    func testCapturedSelectionKeepsWorldAnchorsAndJointCoordinates() throws {
        var preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1], volume: 1,
                                  area: 6, solids: 2, faces: 12, buildSeconds: 0, threads: 1, stepPath: "fixture")
        let vertex = CADFeatureID(kind: .vertex, solidIndex: 1, localIndex: 0)
        preview.topology = CADTopology(vertices: [CADVertex(id: vertex, position: [10,0,0])], edges: [], faces: [],
            parts: [CADPart(solidIndex: 1, area: 88, volume: 48, bounds: [10,0,0,12,4,6], centroid: [11,2,3])])
        let pose = try motion.solve(parts: parts, positions: ["hinge": 90])
        let context = try XCTUnwrap(ProjectSelectionContext.capture(revisionID: UUID(), preview: preview, nodes: parts,
            selectedSolids: [1], selectedNodeIDs: [], selectedFeatures: [vertex], assemblyPose: pose))
        XCTAssertEqual(context.jointPositions, ["hinge": 90])
        let position = try XCTUnwrap(context.features.first?.anchor?.position)
        XCTAssertEqual(position[0], 0, accuracy: 1e-9); XCTAssertEqual(position[1], 10, accuracy: 1e-9)
        XCTAssertNil(context.parts.first?.anchor?.bounds, "A rotated AABB is not an exact CAD bound")
        XCTAssertNoThrow(try context.validate())
    }

    @MainActor
    func testReopenedProgramRestoresItsPoseAndQuitFlushesTheLatestMovement() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for native assembly integration.")
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Saved mechanism.lad")
        let revision = ProjectRevision(model: model, parts: parts, jointPositions: ["hinge": 90])
        try ProjectStore.write(LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id,
                                         projectID: UUID(), projectName: "Saved mechanism"), to: url)
        ProjectPackage.clearSessionCache()
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root), python: EngineService.defaultPython)
        state.loadProject(try ProjectStore.read(from: url), from: url)
        let deadline = ContinuousClock.now + .seconds(45)
        while (state.isWorking || state.isSolvingAssembly), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(state.isWorking); XCTAssertFalse(state.isSolvingAssembly)
        XCTAssertNil(state.error); XCTAssertNil(state.assemblyMotionError)
        XCTAssertEqual(state.assemblyPose?.positions, ["hinge": 90])
        XCTAssertFalse(try XCTUnwrap(state.assemblyPose).solidTransforms.isEmpty)
        let coordinator = ProjectWindowCoordinator()
        let windowID = UUID()
        coordinator.register(state, id: windowID, sourceURL: url)
        state.setJointPosition("hinge", to: 35)
        coordinator.windowClosed(windowID)
        let quit = await coordinator.prepareToQuit()
        XCTAssertTrue(quit)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).revisions[0].jointPositions, ["hinge": 35])
    }

    @MainActor
    private func waitForPose(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while state.isSolvingAssembly, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isSolvingAssembly)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-assembly-integration-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
