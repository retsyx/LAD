import Foundation
import XCTest
@testable import LAD

final class AppStateAgentColorTests: XCTestCase {
    private let red = PartColor(red: 0.8, green: 0.2, blue: 0.1)
    private let blue = PartColor(red: 0.2, green: 0.4, blue: 0.8)
    private let green = PartColor(red: 0.2, green: 0.7, blue: 0.3)

    @MainActor
    func testPickerUsesTheSameNeutralRGBRegardlessOfHowItWasAssigned() {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]),
            PartNode(id: "lid", name: "Lid", solidIndices: [1])])]
        let revision = ProjectRevision(model: .bracket, parts: parts,
                                       partColors: ["lid": PartColorState.defaultFinish])
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertEqual(state.partColor(for: "base"), PartColorState.defaultFinish)
        XCTAssertEqual(state.partColor(for: "lid"), PartColorState.defaultFinish)
        XCTAssertEqual(state.partColor(for: "case"), PartColorState.defaultFinish)
        state.setPartColor(blue, for: "lid")
        XCTAssertNil(state.partColor(for: "case"), "Only different current RGB values should produce a mixed selection.")
    }

    @MainActor
    func testBuildColorsAppearInViewportAndPickerAndResetUsesNeutralFinish() {
        var base = PartNode(id: "base", name: "Base", solidIndices: [0])
        base.color = blue
        let revision = ProjectRevision(model: .bracket, parts: [base])
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertEqual(state.solidColors, [0: blue])
        XCTAssertEqual(state.partColor(for: "base"), blue)
        state.setPartColor(red, for: "base")
        XCTAssertEqual(state.solidColors, [0: red])
        XCTAssertEqual(state.partColor(for: "base"), red)
        state.setPartColor(nil, for: "base")
        XCTAssertEqual(state.revisions[0].partColors, ["base": PartColorState.defaultFinish])
        XCTAssertEqual(state.solidColors, [0: PartColorState.defaultFinish])
        XCTAssertEqual(state.partColor(for: "base"), PartColorState.defaultFinish)
    }

    @MainActor
    func testDisplayOnlyChangesRemainScopedToCapturedRevisionAfterHistoryNavigation() throws {
        let parts = [PartNode(id: "base", name: "Base", solidIndices: [0])]
        let source = ProjectRevision(model: .bracket, parts: parts, partColors: ["base": blue])
        let other = ProjectRevision(model: .bracket, parts: parts, partColors: ["base": green])
        let state = AppState()
        state.revisions = [source, other]
        state.selectedRevisionID = other.id
        try state.applyAgentPartColorChanges([CADPartColorChange(partID: "base", color: red)],
            to: source.id, matching: source.model, startedWith: ["base": blue])
        XCTAssertEqual(state.revisions.map(\.id), [source.id, other.id])
        XCTAssertEqual(state.revisions[0].partColors, ["base": red])
        XCTAssertEqual(state.revisions[1].partColors, ["base": green])
        XCTAssertEqual(state.selectedRevisionID, other.id)
        XCTAssertEqual(state.solidColors, [0: green])
        XCTAssertEqual(state.revisions[0].model, source.model)
        XCTAssertEqual(state.revisions[0].date, source.date)
    }

    @MainActor
    func testUnknownTargetAndStaleSourceRejectCompleteBatchWithoutChangingColors() throws {
        let parts = [PartNode(id: "base", name: "Base", solidIndices: [0])]
        let source = ProjectRevision(model: .bracket, parts: parts, partColors: ["base": blue])
        let state = AppState()
        state.revisions = [source]
        state.selectedRevisionID = source.id
        let changes = [CADPartColorChange(partID: "base", color: red), CADPartColorChange(partID: "missing", color: green)]
        XCTAssertThrowsError(try state.applyAgentPartColorChanges(changes, to: source.id,
            matching: source.model, startedWith: ["base": blue]))
        XCTAssertEqual(state.revisions[0].partColors, ["base": blue])
        var changed = source.model
        changed.script += "\n# A different saved recipe"
        state.revisions[0].model = changed
        XCTAssertThrowsError(try state.applyAgentPartColorChanges([changes[0]], to: source.id,
            matching: source.model, startedWith: ["base": blue]))
        XCTAssertThrowsError(try state.applyAgentPartColorChanges([changes[0]], to: UUID(),
            matching: source.model, startedWith: ["base": blue]))
        XCTAssertEqual(state.revisions[0].partColors, ["base": blue])
    }

    @MainActor
    func testNewerColorChangesAndResetsRemainCurrentWhileOtherStagedEditsCommit() throws {
        let nodes = [PartNode(id: "group", name: "Group", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]),
            PartNode(id: "lid", name: "Lid", solidIndices: [1]),
            PartNode(id: "board", name: "Board", solidIndices: [2])])]
        let snapshot = ["base": blue, "lid": blue, "board": blue]
        let live = ["base": green, "lid": PartColorState.defaultFinish, "board": blue]
        let changes = try PartColorState.normalized(changes: [CADPartColorChange(partID: "group", color: red)], in: nodes)
        let colors = try AppState.partColors(applying: changes,
                                            in: nodes, current: live, startedWith: snapshot)
        XCTAssertEqual(colors, ["base": green, "lid": PartColorState.defaultFinish, "board": red],
                       "A newer reset must remain neutral when the turn finishes.")
        XCTAssertThrowsError(try AppState.partColors(applying: [CADPartColorChange(partID: "missing", color: red)],
                                                     in: nodes, current: live, startedWith: snapshot))
    }

    @MainActor
    func testPhysicalPatchCanColorFolderOwnedSolidDifferentlyFromItsChild() throws {
        let nodes = [PartNode(id: "assembly", name: "Assembly", solidIndices: [0], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [1])])]
        let colors = try AppState.partColors(applying: [CADPartColorChange(partID: "assembly", color: red),
                                                       CADPartColorChange(partID: "lid", color: blue)],
            in: nodes, current: [:], startedWith: [:])
        XCTAssertEqual(colors, ["assembly": red, "lid": blue])
        XCTAssertEqual(PartColorState.solidColors(in: nodes, overrides: colors), [0: red, 1: blue])
    }

    @MainActor
    func testReplacementUsesBuildColorsForNewPartsAndPreservesCurrentColors() throws {
        var oldBase = PartNode(id: "base", name: "Base", solidIndices: [0])
        oldBase.color = blue
        var newBase = oldBase
        newBase.color = green
        var newLid = PartNode(id: "lid", name: "Lid", solidIndices: [1])
        newLid.color = blue
        let layout = PartLayout(nodes: [oldBase]).reconciled(with: [newBase, newLid])
        let colors = try AppState.partColors(applying: [CADPartColorChange(partID: "lid", color: red)],
            in: layout.nodes, current: ["base": blue, "removed": red], startedWith: ["base": blue, "removed": red])
        XCTAssertEqual(colors, ["base": blue, "lid": red])
        XCTAssertEqual(PartColorState.solidColors(in: layout.nodes, overrides: colors), [0: blue, 1: red])
        let unmodified = try AppState.partColors(applying: [], in: layout.nodes,
            current: ["base": PartColorState.defaultFinish], startedWith: ["base": PartColorState.defaultFinish])
        XCTAssertEqual(unmodified, ["base": PartColorState.defaultFinish, "lid": blue],
                       "Existing neutral parts stay neutral; new parts receive their build-supplied finish.")
    }

    @MainActor
    func testSuccessfulColorOnlyTurnCommitsWithoutBuildingAndKeepsNewerEdits() async throws {
        let fixture = try AgentColorTurnFixture(status: "message", delay: 0.3)
        defer { fixture.remove() }
        let oldCodex = UserDefaults.standard.object(forKey: "codexPath")
        UserDefaults.standard.set(fixture.codex.executable.path, forKey: "codexPath")
        defer {
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
        }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: fixture.directory.appendingPathComponent("autosaves")))
        state.newProject()
        let source = ProjectRevision(model: .bracket, partLayout: fixture.layout, parts: fixture.layout.nodes,
                                     partColors: ["base": blue])
        let other = ProjectRevision(model: .bracket, partLayout: fixture.layout, parts: fixture.layout.nodes,
                                    partColors: ["base": red])
        state.revisions = [source, other]
        state.selectedRevisionID = source.id
        state.prompt = "Color the base and lid red."
        state.submit()
        try await fixture.waitForStaging()
        state.setPartColor(green, for: "base")
        state.selectedRevisionID = other.id
        let deadline = ContinuousClock.now + .seconds(10)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isWorking)
        if state.isWorking { state.cancel() }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.revisions.map(\.id), [source.id, other.id])
        XCTAssertEqual(state.revisions[0].partColors, ["base": green, "lid": fixture.color])
        XCTAssertEqual(state.revisions[1].partColors, ["base": red])
        XCTAssertEqual(state.selectedRevisionID, other.id)
        XCTAssertNil(state.mesh)
        XCTAssertEqual(state.messages.last?.phase, "response")
        XCTAssertFalse(state.taskAudits.flatMap(\.events).contains { $0.category == "validation" })
        await state.prepareToQuit()
    }
}

final class CodexPartColorTests: XCTestCase {
    @MainActor
    func testOnlySuccessfulMessageHandsOffStagedCurrentColors() async throws {
        for status in ["message", "unsupported", "failed"] {
            let fixture = try AgentColorTurnFixture(status: status)
            defer { fixture.remove() }
            let service = CodexService()
            do {
                let result = try await service.generate(prompt: "Color the parts", current: .bracket, history: [],
                    partLayout: fixture.layout, executable: fixture.codex.executable.path, model: "",
                    onProgress: { _ in }, python: EngineService.defaultPython)
                XCTAssertNotEqual(status, "failed")
                XCTAssertEqual(result, .response("Part colors updated."))
            } catch { XCTAssertEqual(status, "failed", error.localizedDescription) }
            XCTAssertEqual(service.partColorChanges, status == "message" ? fixture.changes : [])
            service.cancel()
            XCTAssertTrue(service.partColorChanges.isEmpty)
        }
    }

    @MainActor
    func testCancellationDiscardsStagedColorsBeforeTheyCanCommit() async throws {
        let fixture = try AgentColorTurnFixture(status: "message", delay: 30)
        defer { fixture.remove() }
        let service = CodexService()
        let task = Task {
            try await service.generate(prompt: "Color the parts", current: .bracket, history: [],
                partLayout: fixture.layout, executable: fixture.codex.executable.path, model: "",
                onProgress: { _ in }, python: EngineService.defaultPython)
        }
        try await fixture.waitForStaging()
        XCTAssertTrue(service.partColorChanges.isEmpty, "Speculative tool edits must not be handed off before success.")
        service.cancel()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertTrue(service.partColorChanges.isEmpty)
    }
}

private struct AgentColorTurnFixture {
    let directory: URL
    let codex: FakeCodex
    let marker: URL
    let color = PartColor(red: 0.8, green: 0.2, blue: 0.1)
    var layout: PartLayout {
        PartLayout(nodes: [PartNode(id: "base", name: "Base", solidIndices: [0]),
                           PartNode(id: "lid", name: "Lid", solidIndices: [1])])
    }
    var changes: [CADPartColorChange] {
        [CADPartColorChange(partID: "base", color: color), CADPartColorChange(partID: "lid", color: color)]
    }

    init(status: String, delay: Double = 0) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-AgentColorTurn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        marker = directory.appendingPathComponent("staged")
        let configuration: [String: Any] = ["marker": marker.path, "delay": delay, "status": status,
            "changes": ["base", "lid"].map { ["partID": $0, "color": ["red": 0.8, "green": 0.2, "blue": 0.1]] }]
        let encoded = try JSONSerialization.data(withJSONObject: configuration).base64EncodedString()
        codex = try FakeCodex(body: """
        python3 - <<'PY'
        import base64, json, pathlib, sys, time, uuid
        config=json.loads(base64.b64decode('\(encoded)'))
        identity=str(uuid.uuid4())
        control=pathlib.Path('.lad-tools')
        request={'id':identity,'name':'lad_set_part_colors','arguments':{'changes':config['changes']}}
        target=control/'requests'/f'{identity}.json'
        target.write_text(json.dumps(request))
        response=control/'responses'/f'{identity}.json'
        deadline=time.monotonic()+5
        while not response.exists() and time.monotonic()<deadline: time.sleep(0.01)
        assert response.exists(), 'No color tool response'
        value=json.loads(response.read_text())
        assert not value.get('isError'), value
        pathlib.Path(config['marker']).write_text('staged')
        time.sleep(config['delay'])
        if config['status']=='failed':
            print('Color fixture failed after staging',file=sys.stderr)
            sys.exit(1)
        pathlib.Path('model.json').write_text(json.dumps({'status':config['status'],'message':'Part colors updated.','model':None,'assetIDs':[]}))
        PY
        """)
    }

    @MainActor
    func waitForStaging() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The fixture must successfully stage its tool changes.")
        if !FileManager.default.fileExists(atPath: marker.path) { throw LADError.message("The color fixture did not stage changes.") }
    }

    func remove() {
        codex.remove()
        try? FileManager.default.removeItem(at: directory)
    }
}
