import Foundation
import XCTest
@testable import LAD

final class AppStateSTEPColorExportTests: XCTestCase {
    private let red = PartColor(red: 0.85, green: 0.12, blue: 0.08)
    private let blue = PartColor(red: 0.08, green: 0.2, blue: 0.85)
    private let green = PartColor(red: 0.12, green: 0.75, blue: 0.25)

    @MainActor
    func testFullRecolorResetAndSubsetExportsUseCurrentRGBInsteadOfStaleRevisionSTEP() async throws {
        try requireRuntime()
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let parts = try XCTUnwrap(fixture.preview.parts)
        let revision = ProjectRevision(model: fixture.model, preview: fixture.preview, stepData: fixture.staleSTEP,
            partLayout: PartLayout(nodes: parts), parts: parts, partColors: ["first": red, "second": green])
        fixture.state.revisions = [revision]
        fixture.state.selectedRevisionID = revision.id
        XCTAssertTrue(fixture.state.loadStoredRevision())
        XCTAssertTrue(fixture.state.canExport)

        let full = fixture.directory.appendingPathComponent("current.step")
        try await export(fixture.state, to: full)
        XCTAssertNotEqual(try Data(contentsOf: full), fixture.staleSTEP,
                          "A valid but stale session STEP must not bypass current RGB export.")
        var exported = try await readParts(full)
        XCTAssertEqual(exported.count, 2)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4], color: red, in: exported)
        try assertPart(at: [22.5, 8, 10.5], volume: 30, bounds: [20, 7, 9, 25, 9, 12], color: green, in: exported)
        XCTAssertEqual(fixture.state.mesh?.brepPath, fixture.preview.brepPath,
                       "A retained host-owned preview can be exported by another engine without replaying its program.")

        fixture.state.setPartColor(blue, for: "first")
        let recolored = fixture.directory.appendingPathComponent("recolored.step")
        try await export(fixture.state, to: recolored)
        exported = try await readParts(recolored)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4], color: blue, in: exported)
        try assertPart(at: [22.5, 8, 10.5], volume: 30, bounds: [20, 7, 9, 25, 9, 12], color: green, in: exported)

        fixture.state.setPartColor(nil, for: "first")
        let neutral = fixture.directory.appendingPathComponent("neutral.step")
        try await export(fixture.state, to: neutral)
        exported = try await readParts(neutral)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4],
                       color: PartColorState.defaultFinish, in: exported)
        XCTAssertEqual(fixture.state.partColor(for: "first"), PartColorState.defaultFinish)

        let second = try XCTUnwrap(fixture.state.partTree.flatMap(\.flattened).first { $0.id == "second" })
        let subset = fixture.directory.appendingPathComponent("selected.step")
        try await export(fixture.state, to: subset, solidIndices: Set(second.solidIndices))
        exported = try await readParts(subset)
        XCTAssertEqual(exported.count, 1)
        try assertPart(at: [22.5, 8, 10.5], volume: 30, bounds: [20, 7, 9, 25, 9, 12], color: green, in: exported)
        XCTAssertEqual(fixture.state.revisions.map(\.id), [revision.id])
    }

    @MainActor
    func testSubsetReplayRemapsCapturedColorsByStableIDAndKeepsNewerLiveRGB() async throws {
        try requireRuntime()
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let generated = try XCTUnwrap(fixture.preview.parts)
        let count = fixture.preview.solids
        XCTAssertEqual(count, 2)
        func permuted(_ nodes: [PartNode]) -> [PartNode] {
            nodes.map { node in
                var value = node
                value.solidIndices = node.solidIndices.map { count - 1 - $0 }
                if let children = node.children { value.children = permuted(children) }
                return value
            }
        }
        let savedParts = permuted(generated)
        let oldSecond = try XCTUnwrap(savedParts.flatMap(\.flattened).first { $0.id == "second" })
        let freshSecond = try XCTUnwrap(generated.flatMap(\.flattened).first { $0.id == "second" })
        XCTAssertNotEqual(oldSecond.solidIndices, freshSecond.solidIndices)
        let cachedPreview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: fixture.preview.bounds,
            volume: fixture.preview.volume, area: fixture.preview.area, solids: count, faces: fixture.preview.faces,
            buildSeconds: 0, threads: 2, stepPath: fixture.directory.appendingPathComponent("unregistered.step").path,
            parts: savedParts)
        let revision = ProjectRevision(model: fixture.model, preview: cachedPreview, stepData: fixture.staleSTEP,
            partLayout: PartLayout(nodes: savedParts),
            parts: savedParts, partColors: ["first": red, "second": blue])
        fixture.state.revisions = [revision]
        fixture.state.selectedRevisionID = revision.id
        XCTAssertTrue(fixture.state.loadStoredRevision())
        XCTAssertTrue(fixture.state.canExport)

        let subset = fixture.directory.appendingPathComponent("remapped-snapshot.step")
        fixture.state.exportSTEP(to: subset, solidIndices: Set(oldSecond.solidIndices), revealInFinder: false)
        XCTAssertTrue(fixture.state.isWorking)
        // Export owns its captured RGB. A later edit remains live, while the
        // replay must still map the requested body and captured color by ID.
        fixture.state.setPartColor(green, for: "second")
        try await finish(fixture.state, expecting: subset)
        var exported = try await readParts(subset)
        XCTAssertEqual(exported.count, 1)
        try assertPart(at: [22.5, 8, 10.5], volume: 30, bounds: [20, 7, 9, 25, 9, 12], color: blue, in: exported)
        let remapped = try XCTUnwrap(fixture.state.partTree.flatMap(\.flattened).first { $0.id == "second" })
        XCTAssertEqual(remapped.solidIndices, freshSecond.solidIndices)
        XCTAssertEqual(fixture.state.revisions[0].partColors?["second"], green)

        let current = fixture.directory.appendingPathComponent("remapped-current.step")
        try await export(fixture.state, to: current, solidIndices: Set(remapped.solidIndices))
        exported = try await readParts(current)
        XCTAssertEqual(exported.count, 1)
        try assertPart(at: [22.5, 8, 10.5], volume: 30, bounds: [20, 7, 9, 25, 9, 12], color: green, in: exported)
        XCTAssertEqual(fixture.state.revisions.map(\.id), [revision.id])
    }

    @MainActor
    func testAgentExportsColdCurrentOwnershipStagedColorsAndIndependentCandidateSubset() async throws {
        try requireRuntime()
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let generated = try XCTUnwrap(fixture.preview.parts)
        func reversedOwnership(_ nodes: [PartNode]) -> [PartNode] {
            nodes.map { node in
                var value = node
                value.solidIndices = node.solidIndices.map { fixture.preview.solids - 1 - $0 }
                if let children = node.children { value.children = reversedOwnership(children) }
                return value
            }
        }
        let tools = try CADAgentTools(directory: fixture.directory, python: EngineService.defaultPython, threads: 2,
            current: fixture.model, currentPreview: nil, engine: fixture.engine,
            partLayout: PartLayout(nodes: reversedOwnership(generated)), partColors: ["first": red, "second": blue])
        defer { tools.cancel() }
        func exported(_ artifactID: String, path: String, indices: [Int]? = nil) async throws -> URL {
            var arguments: [String: Any] = ["artifactID": artifactID, "path": path]
            if let indices { arguments["solidIndices"] = indices }
            let info = try toolContent(try await tools.handle(name: "lad_export_step", arguments: arguments))
            return URL(fileURLWithPath: try XCTUnwrap(info["path"] as? String))
        }

        // No current preview is supplied: export must reconcile old saved
        // ownership against the recipe's freshly generated native order.
        let oldFirst = try XCTUnwrap(reversedOwnership(generated).flatMap(\.flattened).first { $0.id == "first" })
        let coldSubset = try await exported("current", path: "exports/agent-cold-subset.step", indices: oldFirst.solidIndices)
        let coldParts = try await readParts(coldSubset)
        XCTAssertEqual(coldParts.count, 1)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4], color: red, in: coldParts)
        let whole = try await exported("current", path: "exports/agent-current.step")
        var parts = try await readParts(whole)
        XCTAssertEqual(parts.count, 2)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4], color: red, in: parts)
        try assertPart(at: [22.5, 8, 10.5], volume: 30, bounds: [20, 7, 9, 25, 9, 12], color: blue, in: parts)
        let currentInfo = try toolContent(try await tools.handle(name: "lad_get_part_colors", arguments: [:]))
        let currentFirst = try partItem("first", in: currentInfo)
        let currentIndices = try XCTUnwrap(currentFirst["solidIndices"] as? [Int])
        let expectedIndices = try XCTUnwrap(generated.flatMap(\.flattened).first { $0.id == "first" })
        XCTAssertEqual(currentIndices, expectedIndices.solidIndices)

        _ = try await tools.handle(name: "lad_set_part_colors", arguments: ["changes": [
            ["partID": "first", "color": ["red": green.red, "green": green.green, "blue": green.blue]]
        ]])
        let staged = try await exported("current", path: "exports/agent-green.step", indices: currentIndices)
        parts = try await readParts(staged)
        XCTAssertEqual(parts.count, 1)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4], color: green, in: parts)
        _ = try await tools.handle(name: "lad_set_part_colors", arguments: ["changes": [
            ["partID": "first", "color": NSNull()]
        ]])
        let neutral = try await exported("current", path: "exports/agent-neutral.step", indices: currentIndices)
        parts = try await readParts(neutral)
        XCTAssertEqual(parts.count, 1)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4],
                       color: PartColorState.defaultFinish, in: parts)

        let candidate = """
        result=cq.Assembly(name='Parts', metadata={'lad_id':'parts'})
        result.add(cq.Solid.makeBox(5,2,3), name='Second', loc=cq.Location((20,7,9)), metadata={'lad_id':'second'})
        result.add(cq.Solid.makeBox(2,3,4), name='First', color=cq.Color(0.15,0.25,0.7), metadata={'lad_id':'first'})
        """
        try Data(candidate.utf8).write(to: fixture.directory.appendingPathComponent("candidate.py"))
        let built = try toolContent(try await tools.handle(name: "lad_build", arguments: ["programPath": "candidate.py"]))
        let artifactID = try XCTUnwrap(built["artifactID"] as? String)
        let candidateInfo = try toolContent(try await tools.handle(name: "lad_get_part_colors", arguments: ["artifactID": artifactID]))
        let candidateFirst = try partItem("first", in: candidateInfo)
        let candidateIndices = try XCTUnwrap(candidateFirst["solidIndices"] as? [Int])
        XCTAssertEqual(candidateIndices, [1], "The subset regression must target a higher original native index.")
        _ = try await tools.handle(name: "lad_set_part_colors", arguments: ["artifactID": artifactID, "changes": [
            ["partID": "first", "color": ["red": red.red, "green": red.green, "blue": red.blue]]
        ]])
        let selected = try await exported(artifactID, path: "exports/agent-candidate.step", indices: candidateIndices)
        parts = try await readParts(selected)
        XCTAssertEqual(parts.count, 1)
        try assertPart(at: [1, 1.5, 2], volume: 24, bounds: [0, 0, 0, 2, 3, 4], color: red, in: parts)
        let unchangedCurrent = try toolContent(try await tools.handle(name: "lad_get_part_colors", arguments: [:]))
        let currentColor = try XCTUnwrap(try partItem("first", in: unchangedCurrent)["color"])
        XCTAssertEqual(try JSONDecoder().decode(PartColor.self, from: JSONSerialization.data(withJSONObject: currentColor)),
                       PartColorState.defaultFinish, "A candidate's export color must not mutate current artifact colors.")
    }

    @MainActor
    private func export(_ state: AppState, to url: URL, solidIndices: Set<Int>? = nil) async throws {
        state.exportSTEP(to: url, solidIndices: solidIndices, revealInFinder: false)
        XCTAssertTrue(state.isWorking)
        try await finish(state, expecting: url)
    }

    @MainActor
    private func finish(_ state: AppState, expecting url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isWorking, "The native STEP export must finish.")
        if state.isWorking { state.cancel() }
        XCTAssertNil(state.error)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LADError.message("No STEP was exported: \(state.error ?? state.activity)")
        }
    }

    private struct ExportedPart: Decodable, Sendable {
        var center: [Double]
        var bounds: [Double]
        var volume: Double
        var color: [Double]?
    }

    private func toolContent(_ result: [String: Any]) throws -> [String: Any] {
        let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first { $0["type"] as? String == "text" }?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func partItem(_ id: String, in info: [String: Any]) throws -> [String: Any] {
        let items = try XCTUnwrap(info["items"] as? [[String: Any]])
        return try XCTUnwrap(items.first { $0["partID"] as? String == id })
    }

    private func assertPart(at center: [Double], volume: Double, bounds: [Double], color: PartColor,
                            in parts: [ExportedPart], file: StaticString = #filePath, line: UInt = #line) throws {
        let part = try XCTUnwrap(parts.min { abs($0.center[0] - center[0]) < abs($1.center[0] - center[0]) }, file: file, line: line)
        for (actual, expected) in zip(part.center, center) { XCTAssertEqual(actual, expected, accuracy: 1e-6, file: file, line: line) }
        for (actual, expected) in zip(part.bounds, bounds) { XCTAssertEqual(actual, expected, accuracy: 1e-6, file: file, line: line) }
        XCTAssertEqual(part.volume, volume, accuracy: 1e-6, file: file, line: line)
        let rgb = try XCTUnwrap(part.color, "The exported placed body must have an XDE color.", file: file, line: line)
        XCTAssertEqual(rgb.count, 3, file: file, line: line)
        for (actual, expected) in zip(rgb, [color.red, color.green, color.blue]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6, file: file, line: line)
        }
    }

    @MainActor
    private func readParts(_ url: URL) async throws -> [ExportedPart] {
        let python = EngineService.defaultPython
        let helpers = ResourcePaths.root.appendingPathComponent("Engine/tests").path
        return try await Task.detached {
            let script = """
            import json,sys
            sys.path.insert(0,sys.argv[1])
            from test_step_colors import read_xde_parts
            result=[]
            for item in read_xde_parts(sys.argv[2]):
                shape=item['shape']; box=shape.BoundingBox()
                result.append({'center':list(shape.Center().toTuple()),'volume':shape.Volume(),
                    'bounds':[getattr(box,key) for key in ('xmin','ymin','zmin','xmax','ymax','zmax')],
                    'color':item['color']})
            print('LAD_APP_STEP_PARTS='+json.dumps(result))
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", script, helpers, url.path]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw LADError.message("Placed STEP color verification failed: " + String(decoding: diagnostic, as: UTF8.self))
            }
            let line = try XCTUnwrap(String(decoding: data, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix("LAD_APP_STEP_PARTS=") })
            return try JSONDecoder().decode([ExportedPart].self, from: Data(line.dropFirst("LAD_APP_STEP_PARTS=".count).utf8))
        }.value
    }

    private func requireRuntime() throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for AppState STEP color and replay regression tests.")
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let model: ModelSpec
        let preview: PreviewMesh
        let staleSTEP: Data
        let state: AppState
        let engine: EngineService
        let oldPython: Any?
        let oldThreads: Any?

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-AppState-STEP-colors-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = ModelSpec(title: "STEP color export fixture", summary: "Two exact bodies with current colors.", units: "mm", script: """
            result=cq.Assembly(name='Parts', metadata={'lad_id':'parts'})
            result.add(cq.Solid.makeBox(2,3,4), name='First', color=cq.Color(0.15,0.25,0.7), metadata={'lad_id':'first'})
            result.add(cq.Solid.makeBox(5,2,3), name='Second', loc=cq.Location((20,7,9)), metadata={'lad_id':'second'})
            """)
            engine = EngineService()
            preview = try await engine.buildPreview(model, python: EngineService.defaultPython, threads: 2)
            let stale = PartColor(red: 0.8, green: 0.1, blue: 0.8)
            staleSTEP = try await engine.exportSTEP(preview, solidColors: [0: stale, 1: stale],
                                                    python: EngineService.defaultPython, threads: 2)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("autosaves")))
            oldPython = UserDefaults.standard.object(forKey: "pythonPath")
            oldThreads = UserDefaults.standard.object(forKey: "workerThreads")
            UserDefaults.standard.set(EngineService.defaultPython, forKey: "pythonPath")
            UserDefaults.standard.set(2, forKey: "workerThreads")
        }

        func cleanUp() {
            state.cancel()
            engine.cancel()
            if let oldPython { UserDefaults.standard.set(oldPython, forKey: "pythonPath") }
            else { UserDefaults.standard.removeObject(forKey: "pythonPath") }
            if let oldThreads { UserDefaults.standard.set(oldThreads, forKey: "workerThreads") }
            else { UserDefaults.standard.removeObject(forKey: "workerThreads") }
            let paths = Set([preview.stepPath, state.mesh?.stepPath].compactMap { $0 })
            for path in paths where !path.hasPrefix(directory.path) {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
