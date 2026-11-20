import XCTest
@testable import LAD

final class AppStateMaterialTests: XCTestCase {
    private let aluminum = PartMaterial(name: "Aluminum 6061", density: 2.70)
    private let abs = PartMaterial(name: "ABS", density: 1.05)
    private let resin = PartMaterial(name: "Tough resin", density: 1.18)

    @MainActor
    func testContextMaterialUsesSelectedPartsFoldersAndUnassignment() {
        let state = state()
        XCTAssertEqual(state.partMaterial(for: "base"), .unassigned)
        state.setPartMaterial(aluminum, for: "base")
        state.selectPartNodes(["base", "board"])
        XCTAssertEqual(state.partMaterial(for: "board"), .mixed)
        state.setPartMaterial(abs, for: "board")
        XCTAssertEqual(state.partMaterials, ["base": abs, "board": abs])
        XCTAssertEqual(state.partMaterial(for: "base"), .material(abs))

        state.clearSelections()
        state.setPartMaterial(aluminum, for: "case")
        XCTAssertEqual(state.partMaterials, ["case": aluminum, "base": aluminum, "lid": aluminum, "board": abs],
                       "A folder assigns its own geometry and descendants")
        state.setPartMaterial(nil, for: "lid")
        XCTAssertEqual(state.partMaterials, ["case": aluminum, "base": aluminum, "board": abs])
        XCTAssertEqual(state.partMaterial(for: "lid"), .unassigned)
        state.renamePartNode("base", to: "Printed base")
        state.movePartNodes(["base"], toParent: nil)
        XCTAssertEqual(state.partMaterial(for: "base"), .material(aluminum), "Organization keeps stable assignments")

        let before = state.partMaterials
        state.setPartMaterial(PartMaterial(name: "Air", density: 0), for: "lid")
        state.setPartMaterial(abs, for: "missing")
        XCTAssertEqual(state.partMaterials, before)
    }

    @MainActor
    func testDesignMaterialsIncludeDefinitionsAndAssignmentsMissingFromTheLibrary() {
        let state = state()
        state.setPartMaterial(abs, for: "base")
        state.addProjectMaterials([resin, PartMaterial(name: "tough RESIN", density: 9)])
        XCTAssertEqual(state.projectMaterials, [resin])
        XCTAssertEqual(state.designMaterials, [resin, abs])
        XCTAssertEqual(state.agentMaterialContext.assignments, ["base": abs])
        XCTAssertEqual(state.agentMaterialContext.design, [resin])
    }

    @MainActor
    func testPartMeasurementsShowMassForCurrentMaterials() throws {
        let state = state()
        let topology = CADTopology(vertices: [], edges: [], faces: [], parts: (0..<4).map {
            CADPart(solidIndex: $0, area: 6, volume: Double(($0 + 1) * 1_000), bounds: [0, 0, 0, 10, 10, 10], centroid: [5, 5, 5])
        })
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 10, 10, 10], volume: 10_000,
                                  area: 24, solids: 4, faces: 0, buildSeconds: 0, threads: 1,
                                  stepPath: "/session/materials-\(UUID().uuidString).step",
                                  parts: state.partTree, topology: topology)
        state.mesh = preview
        state.selectPartNodes(["base", "lid"])
        func mass() throws -> Double {
            try XCTUnwrap(state.measurementReport?.metrics.first { $0.id == "parts:mass" }?.values.first)
        }
        XCTAssertEqual(try mass(), 0, "Unassigned parts report zero mass")
        state.setPartMaterial(aluminum, for: "lid")
        XCTAssertEqual(try mass(), 2.7 * (1 + 2), accuracy: 1e-9, "A selected row assigns every selected part")
        state.setPartMaterial(abs, for: "board")
        XCTAssertEqual(try mass(), 2.7 * (1 + 2), accuracy: 1e-9)
        state.setPartMaterial(abs, for: "case")
        XCTAssertEqual(try mass(), 1.05 * (1 + 2), accuracy: 1e-9)
    }

    @MainActor
    func testAgentChangesApplyToTheirSourceVersionAndKeepNewerEdits() throws {
        let state = state()
        let source = try XCTUnwrap(state.revisions.first)
        state.setPartMaterial(abs, for: "base")
        let started = state.partMaterials
        state.setPartMaterial(aluminum, for: "base")
        let other = ProjectRevision(model: .bracket, partLayout: source.partLayout, parts: source.parts)
        state.revisions.append(other)
        state.selectedRevisionID = other.id
        try state.applyAgentPartMaterialChanges([CADPartMaterialChange(partID: "base", material: resin),
                                                 CADPartMaterialChange(partID: "lid", material: resin)],
                                                to: source.id, matching: source.model, startedWith: started)
        XCTAssertEqual(state.revisions[0].partMaterials, ["base": aluminum, "lid": resin])
        XCTAssertNil(state.revisions[1].partMaterials)
        var changed = ModelSpec.bracket
        changed.script += "\n# changed"
        XCTAssertThrowsError(try state.applyAgentPartMaterialChanges([CADPartMaterialChange(partID: "lid", material: abs)],
                                                                     to: source.id, matching: changed, startedWith: [:]))
    }

    @MainActor
    func testSuccessfulMaterialTurnCommitsDesignMaterialsWithoutChangingTheLibrary() async throws {
        let fixture = try AgentMaterialTurnFixture(delay: 0.3)
        defer { fixture.remove() }
        let oldCodex = UserDefaults.standard.object(forKey: "codexPath")
        UserDefaults.standard.set(fixture.codex.executable.path, forKey: "codexPath")
        defer {
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
        }
        let library = PartMaterialLibrary.shared.customMaterials
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: fixture.directory.appendingPathComponent("autosaves")))
        state.newProject()
        let source = ProjectRevision(model: .bracket, partLayout: fixture.layout, parts: fixture.layout.nodes)
        state.revisions = [source]
        state.selectedRevisionID = source.id
        state.prompt = "Make the base from glass-filled nylon and the lid from ABS."
        state.submit()
        try await fixture.waitForStaging()
        XCTAssertNil(state.revisions[0].partMaterials, "Staged assignments wait for a successful response")
        XCTAssertTrue(state.projectMaterials.isEmpty)
        let deadline = ContinuousClock.now + .seconds(10)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isWorking)
        if state.isWorking { state.cancel() }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.revisions.count, 1)
        XCTAssertEqual(state.revisions[0].partMaterials, ["base": fixture.material, "lid": abs])
        XCTAssertEqual(state.projectMaterials, [fixture.material])
        XCTAssertEqual(PartMaterialLibrary.shared.customMaterials, library, "Agent materials stay with the design")
        XCTAssertEqual(state.messages.last?.phase, "response")
        await state.prepareToQuit()
    }

    @MainActor
    private func state() -> AppState {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [3], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]),
            PartNode(id: "lid", name: "Lid", solidIndices: [1])]),
            PartNode(id: "board", name: "Board", solidIndices: [2])]
        let revision = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: parts), parts: parts)
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        return state
    }
}

private struct AgentMaterialTurnFixture {
    let directory: URL
    let codex: FakeCodex
    let marker: URL
    let material = PartMaterial(name: "Glass-filled nylon", density: 1.36)
    var layout: PartLayout {
        PartLayout(nodes: [PartNode(id: "base", name: "Base", solidIndices: [0]),
                           PartNode(id: "lid", name: "Lid", solidIndices: [1])])
    }

    init(delay: Double) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-AgentMaterialTurn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        marker = directory.appendingPathComponent("staged")
        let arguments: [String: Any] = [
            "materials": [["name": material.name, "density": material.density]],
            "changes": [["partID": "base", "material": "glass-filled NYLON"], ["partID": "lid", "material": "abs"]]]
        let configuration: [String: Any] = ["marker": marker.path, "delay": delay, "arguments": arguments]
        let encoded = try JSONSerialization.data(withJSONObject: configuration).base64EncodedString()
        codex = try FakeCodex(body: """
        python3 - <<'PY'
        import base64, json, pathlib, time, uuid
        config=json.loads(base64.b64decode('\(encoded)'))
        identity=str(uuid.uuid4())
        control=pathlib.Path('.lad-tools')
        request={'id':identity,'name':'lad_set_part_materials','arguments':config['arguments']}
        (control/'requests'/f'{identity}.json').write_text(json.dumps(request))
        response=control/'responses'/f'{identity}.json'
        deadline=time.monotonic()+5
        while not response.exists() and time.monotonic()<deadline: time.sleep(0.01)
        assert response.exists(), 'No material tool response'
        value=json.loads(response.read_text())
        assert not value.get('isError'), value
        pathlib.Path(config['marker']).write_text('staged')
        time.sleep(config['delay'])
        pathlib.Path('model.json').write_text(json.dumps({'status':'message','message':'Materials assigned.','model':None,'assetIDs':[]}))
        PY
        """)
    }

    @MainActor
    func waitForStaging() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: marker.path) else { throw LADError.message("The fake agent did not stage materials.") }
    }

    func remove() {
        codex.remove()
        try? FileManager.default.removeItem(at: directory)
    }
}
