import Foundation
import XCTest
@testable import LAD

final class CodexVersionContextIntegrationTests: XCTestCase {
    @MainActor
    func testReopenedHistoryIsAvailableOnDemandThroughTheTaskBridgeWithExactLocalInputs() async throws {
        let harness = try VersionHarness(queries: [["name": "lad_versions", "arguments": [:]],
            ["name": "lad_version", "arguments": ["reference": "v3"]]])
        defer { harness.remove() }
        let revisions = historicalRevisions()
        let selected = revisions[0]
        let archive = try ProjectStore.encode(LADProject(messages: [], revisions: revisions, selectedRevisionID: selected.id))
        let reopened = try ProjectStore.decode(archive)
        let capture = VersionActivityCapture()
        let service = CodexService()
        let result = try await service.generate(prompt: "Explain how v3 differs from this version.", current: selected.model,
            history: [], executable: harness.codex.executable.path, model: "version-test", onProgress: { _ in },
            onActivity: { capture.append($0) }, python: harness.python.path,
            versions: ProjectVersionContext(revisions: reopened.revisions, selectedRevisionID: reopened.selectedRevisionID))

        XCTAssertEqual(result, .response("Historical version inspected."))
        let report = try harness.report()
        let responses = try objects(report["results"])
        let list = try XCTUnwrap(responses.first)
        XCTAssertEqual(list["total"] as? Int, 3)
        let items = try objects(list["items"])
        XCTAssertEqual(items.compactMap { $0["version"] as? String }, ["v1", "v2", "v3"])
        XCTAssertEqual(items.filter { $0["isCurrent"] as? Bool == true }.first?["versionID"] as? String, selected.id.uuidString)
        let version = try XCTUnwrap(responses.last)
        XCTAssertEqual(version["versionID"] as? String, revisions[2].id.uuidString)
        XCTAssertEqual(version["name"] as? String, "Rounded lettering")
        XCTAssertEqual(version["version"] as? String, "v3", "A custom label must not change the history-position reference.")
        XCTAssertEqual(try stagedData(version, key: "programPath", report: report), Data(revisions[2].model.script.utf8))
        let model = try JSONDecoder().decode(ModelSpec.self, from: stagedData(version, key: "modelPath", report: report))
        XCTAssertEqual(model.script, revisions[2].model.script)
        XCTAssertNil(model.sourceSTEP)
        XCTAssertNil(model.inputAssets)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: stagedData(version, key: "inputsManifestPath", report: report)) as? [String: Any])
        let inputs = try objects(manifest["inputAssets"])
        let external = try XCTUnwrap(inputs.first { $0["assetID"] as? String == "historical-reference" })
        XCTAssertEqual(try stagedData(external, key: "path", report: report), historicalAsset)
        let source = try XCTUnwrap(version["sourceSTEP"] as? [String: Any])
        XCTAssertEqual(try stagedData(source, key: "path", report: report), historicalSTEP)

        let request = try String(contentsOf: harness.codex.inputURL, encoding: .utf8)
        for marker in [revisions[2].model.script, "HISTORICAL_RECIPE_PRIVATE_MARKER", "HISTORICAL_INPUT_PRIVATE_MARKER",
                       historicalAsset.base64EncodedString(), historicalSTEP.base64EncodedString()] {
            XCTAssertFalse(request.contains(marker), "The initial prompt must contain references rather than historical source or bytes.")
        }
        XCTAssertTrue(request.contains("lad_versions"))
        XCTAssertTrue(request.contains("lad_version"))
        let completed = capture.events.filter { $0.category == "tool" && $0.status == "completed" }
        XCTAssertEqual(completed.map(\.title), ["lad_versions", "lad_version"])
        XCTAssertTrue(completed.last?.input?.contains("v3") == true)
        XCTAssertTrue(completed.last?.output?.contains(revisions[2].id.uuidString) == true)
        XCTAssertTrue(completed.allSatisfy { $0.durationSeconds != nil })
        XCTAssertFalse(completed.contains { $0.output?.contains("HISTORICAL_RECIPE_PRIVATE_MARKER") == true })
        XCTAssertNil(service.validatedPreview(for: selected.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.runtimeMarker.path), "A lookup must not launch the CAD worker.")
        try harness.codex.assertJobWasCleanedUp()
    }

    @MainActor
    func testLargeUnrequestedHistoryDoesNotGrowTheInitialPromptOrStageItsPrograms() async throws {
        let current = historicalRevisions()[0]
        let historicalProgram = "# LARGE_UNREQUESTED_HISTORY_PRIVATE_MARKER\n" + String(repeating: "# saved complete program\n", count: 6_000)
        let old = ModelSpec(title: "HISTORICAL_TITLE_PRIVATE_MARKER", summary: "A saved historical design.", units: "mm", script: historicalProgram)
        var lengths: [Int] = []
        for historyCount in [3, 203] {
            let revisions = [current] + (1..<historyCount).map { _ in ProjectRevision(model: old) }
            let harness = try VersionHarness(queries: [])
            defer { harness.remove() }
            _ = try await CodexService().generate(prompt: "What can you tell me about earlier versions?", current: current.model,
                history: [], executable: harness.codex.executable.path, model: "version-test", onProgress: { _ in },
                python: harness.python.path, versions: ProjectVersionContext(revisions: revisions, selectedRevisionID: current.id))
            let request = try String(contentsOf: harness.codex.inputURL, encoding: .utf8)
            lengths.append(request.utf8.count)
            XCTAssertLessThan(request.utf8.count, 100_000)
            XCTAssertFalse(request.contains("LARGE_UNREQUESTED_HISTORY_PRIVATE_MARKER"))
            XCTAssertFalse(request.contains("HISTORICAL_TITLE_PRIVATE_MARKER"))
            let staged = try XCTUnwrap(try harness.report()["initialFiles"] as? [String])
            XCTAssertFalse(staged.contains { $0.hasPrefix("context/versions/") }, "Unrequested historical programs must remain unstaged.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.runtimeMarker.path))
        }
        XCTAssertLessThan(abs(lengths[1] - lengths[0]), 256, "Initial request size must be independent of complete history size.")
    }

    @MainActor
    func testAppStateSnapshotsHistoryBeforeRenameAndAppendWithoutChangingTheCurrentDesign() async throws {
        let harness = try VersionHarness(queries: [["name": "lad_versions", "arguments": [:]],
            ["name": "lad_version", "arguments": ["reference": "v3"]]], waitsForResume: true)
        defer { harness.remove() }
        let preferences = VersionPreferences(codex: harness.codex.executable.path, python: harness.python.path)
        defer { preferences.restore() }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: harness.directory.appendingPathComponent("autosaves")))
        state.newProject()
        defer { state.cancel() }
        let revisions = historicalRevisions()
        state.revisions = revisions
        state.selectedRevisionID = revisions[0].id
        let preview = syntheticPreview(path: harness.directory.appendingPathComponent("unchanged-preview.step").path)
        state.mesh = preview
        state.hiddenSolids = [0]
        let originalProjectID = state.projectDocumentID
        state.prompt = "Look up v3 and explain its lettering."
        state.submit()
        try await waitUntil { FileManager.default.fileExists(atPath: harness.ready.path) }
        try state.renameRevision(id: revisions[2].id, to: "Renamed during the task")
        state.revisions[2].model.script = "# MODIFIED_AFTER_SUBMISSION\nresult = None\n"
        state.revisions.append(ProjectRevision(model: .bracket, name: "Created during the task"))
        let liveIDs = state.revisions.map(\.id)
        try harness.resumeTask()
        try await waitUntil { !state.isWorking }

        XCTAssertNil(state.error)
        let report = try harness.report()
        let results = try objects(report["results"])
        XCTAssertEqual(results.first?["total"] as? Int, 3, "The running task keeps its original history snapshot.")
        let lookup = try XCTUnwrap(results.last)
        XCTAssertEqual(lookup["name"] as? String, "Rounded lettering")
        XCTAssertEqual(try stagedData(lookup, key: "programPath", report: report), Data(revisions[2].model.script.utf8))
        XCTAssertEqual(state.revisions.map(\.id), liveIDs)
        XCTAssertEqual(state.revisions[2].name, "Renamed during the task")
        XCTAssertTrue(state.revisions[2].model.script.contains("MODIFIED_AFTER_SUBMISSION"))
        XCTAssertEqual(state.selectedRevisionID, revisions[0].id)
        XCTAssertEqual(state.current, revisions[0].model)
        XCTAssertEqual(state.mesh?.stepPath, preview.stepPath)
        XCTAssertEqual(state.mesh?.vertices, preview.vertices)
        XCTAssertEqual(state.hiddenSolids, [0])
        XCTAssertEqual(state.projectDocumentID, originalProjectID)
        XCTAssertEqual(state.messages.last?.phase, "response")
        let audit = try XCTUnwrap(state.taskAudits.last)
        XCTAssertEqual(audit.status, "completed")
        XCTAssertEqual(audit.events.filter { $0.category == "tool" && $0.status == "completed" }.map(\.title), ["lad_versions", "lad_version"])
        XCTAssertFalse(audit.events.contains { $0.category == "validation" || $0.title == "lad_build" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.runtimeMarker.path))
        await state.prepareToQuit()
    }

    @MainActor
    func testSameTurnSteeringCanReferenceAnUnselectedVersionFromTheOriginalTaskSnapshot() async throws {
        let harness = try VersionHarness(queries: [["name": "lad_version", "arguments": ["reference": "v3"]]], waitsForResume: true)
        defer { harness.remove() }
        let revisions = historicalRevisions()
        let service = CodexService()
        let task = Task {
            try await service.generate(prompt: "Explain the current design.", current: revisions[0].model, history: [],
                executable: harness.codex.executable.path, model: "version-test", onProgress: { _ in }, python: harness.python.path,
                versions: ProjectVersionContext(revisions: revisions, selectedRevisionID: revisions[0].id))
        }
        defer { service.cancel(); task.cancel() }
        try await waitUntil { service.canSteer && FileManager.default.fileExists(atPath: harness.ready.path) }
        let turn = try await service.steer(prompt: "Compare it with v3, the rounded-lettering version.")
        XCTAssertEqual(turn, "turn")
        try harness.resumeTask()
        let result = try await task.value
        XCTAssertEqual(result, .response("Historical version inspected."))
        let report = try harness.report()
        let lookup = try XCTUnwrap(try objects(report["results"]).first)
        XCTAssertEqual(lookup["versionID"] as? String, revisions[2].id.uuidString)
        XCTAssertEqual(try stagedData(lookup, key: "programPath", report: report), Data(revisions[2].model.script.utf8))
        let requests = try harness.codex.rpcRequests()
        XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
        let steer = try XCTUnwrap(requests.first { $0["method"] as? String == "turn/steer" }?["params"] as? [String: Any])
        let steeringText = String(decoding: try JSONSerialization.data(withJSONObject: steer), as: UTF8.self)
        XCTAssertTrue(steeringText.contains("Compare it with v3"))
        XCTAssertFalse(steeringText.contains("HISTORICAL_RECIPE_PRIVATE_MARKER"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.runtimeMarker.path))
        try harness.codex.assertJobWasCleanedUp()
    }

    private var historicalAsset: Data { Data("# HISTORICAL_INPUT_PRIVATE_MARKER\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8) }
    private var historicalSTEP: Data { Data("ISO-10303-21;\nHISTORICAL_STEP_PRIVATE_MARKER\nEND-ISO-10303-21;\n".utf8) }

    private func historicalRevisions() -> [ProjectRevision] {
        let current = ProjectRevision(model: ModelSpec(title: "Current design", summary: "Current complete recipe.", units: "mm", script: "result = cq.Solid.makeBox(2, 3, 4)\n"))
        let second = ProjectRevision(model: ModelSpec(title: "Intermediate design", summary: "An intermediate recipe.", units: "mm", script: "result = cq.Solid.makeBox(3, 4, 5)\n"))
        let third = ProjectRevision(model: ModelSpec(title: "Lettered design", summary: "Rounded lettering in the saved design.", units: "mm",
            script: "# HISTORICAL_RECIPE_PRIVATE_MARKER\nresult = imported_model.fuse(imported_assets['historical-reference'])\n",
            sourceSTEP: historicalSTEP, sourceName: "original-reference.step",
            inputAssets: [CADInputAsset(id: "historical-reference", name: "original-reference.obj", format: "obj", data: historicalAsset)]),
            name: "Rounded lettering")
        return [current, second, third]
    }

    private func objects(_ value: Any?) throws -> [[String: Any]] { try XCTUnwrap(value as? [[String: Any]]) }

    private func stagedData(_ record: [String: Any], key: String, report: [String: Any]) throws -> Data {
        let path = try XCTUnwrap(record[key] as? String)
        let files = try XCTUnwrap(report["files"] as? [String: String])
        return try XCTUnwrap(files[path].flatMap { Data(base64Encoded: $0) }, "Missing captured reference: \(path)")
    }

    private func syntheticPreview(path: String) -> PreviewMesh {
        PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2]], edges: [],
            bounds: [0, 0, 0, 1, 1, 1], volume: 1, area: 0.5, solids: 1, faces: 1, buildSeconds: 0, threads: 1,
            stepPath: path, triangleSolids: [0], edgeSolids: [])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LADError.message("The version integration fixture did not reach its expected state.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class VersionActivityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProjectActivityEvent] = []
    var events: [ProjectActivityEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ event: ProjectActivityEvent) { lock.lock(); storage.append(event); lock.unlock() }
}

private struct VersionPreferences {
    private let previousCodex = UserDefaults.standard.object(forKey: "codexPath")
    private let previousPython = UserDefaults.standard.object(forKey: "pythonPath")
    init(codex: String, python: String) {
        UserDefaults.standard.set(codex, forKey: "codexPath")
        UserDefaults.standard.set(python, forKey: "pythonPath")
    }
    func restore() {
        for (key, value) in [("codexPath", previousCodex), ("pythonPath", previousPython)] {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

/// The mock Codex process exercises LAD's real task bridge and reads only the
/// local paths it returns. Its report copies test data out before task cleanup.
private struct VersionHarness {
    let directory: URL
    let python: URL
    let runtimeMarker: URL
    let ready: URL
    let resume: URL
    let reportURL: URL
    let codex: FakeCodex

    init(queries: [[String: Any]], waitsForResume: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-version-integration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        python = directory.appendingPathComponent("python")
        runtimeMarker = directory.appendingPathComponent("runtime-launched")
        ready = directory.appendingPathComponent("ready")
        resume = directory.appendingPathComponent("resume")
        reportURL = directory.appendingPathComponent("report.json")
        let markerJSON = try JSONSerialization.data(withJSONObject: [runtimeMarker.path])
        let marker = String(decoding: markerJSON, as: UTF8.self)
        let pythonBody = "#!/usr/bin/env python3\nimport json,pathlib,sys\npathlib.Path(json.loads('\(marker)')[0]).write_text('unexpected CAD worker launch')\nsys.exit(70)\n"
        try pythonBody.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let configuration: [String: Any] = ["queries": queries, "wait": waitsForResume, "ready": ready.path,
            "resume": resume.path, "report": reportURL.path]
        let encoded = try JSONSerialization.data(withJSONObject: configuration).base64EncodedString()
        codex = try FakeCodex(body: """
        python3 - <<'VERSION_TEST_PYTHON'
        import base64,json,os,pathlib,time,uuid
        configuration=json.loads(base64.b64decode('\(encoded)'))
        root=pathlib.Path.cwd()
        initial=sorted(str(path.relative_to(root)) for path in root.rglob('*') if path.is_file())
        pathlib.Path(configuration['ready']).write_text('ready')
        deadline=time.monotonic()+10
        while configuration['wait'] and not pathlib.Path(configuration['resume']).exists():
            if time.monotonic()>deadline:raise RuntimeError('The version test was not resumed.')
            time.sleep(0.01)
        results=[]
        files={}
        def capture(value):
            if isinstance(value,dict):
                for entry in value.values():capture(entry)
            elif isinstance(value,list):
                for entry in value:capture(entry)
            elif isinstance(value,str) and value.startswith(str(root)+'/'):
                path=pathlib.Path(value)
                if value not in files and path.is_file():
                    data=path.read_bytes()
                    files[value]=base64.b64encode(data).decode()
                    if path.suffix=='.json':capture(json.loads(data))
        for query in configuration['queries']:
            identity=str(uuid.uuid4())
            request=dict(query,id=identity)
            pending=root/'.lad-tools'/'requests'/(identity+'.pending')
            pending.write_text(json.dumps(request))
            pending.rename(pending.with_suffix('.json'))
            response=root/'.lad-tools'/'responses'/(identity+'.json')
            deadline=time.monotonic()+10
            while not response.exists():
                if time.monotonic()>deadline:raise RuntimeError('The version tool did not return.')
                time.sleep(0.01)
            envelope=json.loads(response.read_text())
            if envelope.get('isError'):raise RuntimeError(str(envelope))
            value=json.loads(next(block['text'] for block in envelope['content'] if block['type']=='text'))
            results.append(value)
            capture(value)
        pathlib.Path(configuration['report']).write_text(json.dumps({'results':results,'files':files,'initialFiles':initial}))
        pathlib.Path(os.environ['output']).write_text(json.dumps({'status':'message','message':'Historical version inspected.','model':None,'assetIDs':[]}))
        VERSION_TEST_PYTHON
        """)
    }

    func report() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
    }
    func resumeTask() throws { try Data("resume".utf8).write(to: resume) }
    func remove() { codex.remove(); try? FileManager.default.removeItem(at: directory) }
}
