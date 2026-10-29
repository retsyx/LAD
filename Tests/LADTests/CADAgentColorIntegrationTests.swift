import AppKit
import Metal
import XCTest
@testable import LAD

final class CADAgentColorIntegrationTests: XCTestCase {
    @MainActor
    func testNativeColorsToolsRenderingPortableSaveAndReorderedRefinement() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for native color integration.")
        }
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-native-colors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = script(reversed: false)
        let model = ModelSpec(title: "Colored parts", summary: "Two colored solids", units: "mm", script: program)
        try Data(program.utf8).write(to: root.appendingPathComponent("program.py"))
        let engine = EngineService()
        let tools = try CADAgentTools(directory: root, python: EngineService.defaultPython, threads: 2,
            current: nil, currentPreview: nil, engine: engine)
        defer { tools.cancel() }
        let built = try content(try await tools.handle(name: "lad_build", arguments: ["programPath": "program.py"]))
        let id = try XCTUnwrap(built["artifactID"] as? String)
        let preview = try XCTUnwrap(tools.validatedPreview(for: model))
        let parts = try XCTUnwrap(preview.parts)
        let redPart = try XCTUnwrap(parts.flatMap(\.flattened).first { $0.id == "red" })
        XCTAssertEqual(try XCTUnwrap(redPart.color).red, 0.9, accuracy: 1e-6)
        let initial = try content(try await tools.handle(name: "lad_get_part_colors", arguments: ["artifactID": id]))
        let initialItems = try XCTUnwrap(initial["items"] as? [[String: Any]])
        let initialRed = try XCTUnwrap(initialItems.first { $0["partID"] as? String == "red" })
        let initialColor = try JSONDecoder().decode(PartColor.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(initialRed["color"])))
        XCTAssertEqual(initialColor.red, 0.9, accuracy: 1e-6)
        XCTAssertNil(initialRed["colorSource"])
        let blue = PartColor(red: 0.08, green: 0.08, blue: 0.9)
        _ = try await tools.handle(name: "lad_set_part_colors", arguments: ["artifactID": id, "changes": [
            ["partID": "red", "color": ["red": blue.red, "green": blue.green, "blue": blue.blue]]
        ]])
        let patch = tools.partColorChanges(for: model)
        XCTAssertEqual(patch, [CADPartColorChange(partID: "red", color: blue)])
        let captured = try content(try await tools.handle(name: "lad_render", arguments: [
            "artifactID": id, "view": "top", "display": "shaded", "width": 320, "height": 256]))
        let png = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(captured["path"] as? String)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        var bluePixels = 0, greenPixels = 0, redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                if c.blueComponent > 0.2 && c.blueComponent > c.redComponent * 1.6 && c.blueComponent > c.greenComponent * 1.6 { bluePixels += 1 }
                if c.greenComponent > 0.2 && c.greenComponent > c.redComponent * 1.6 && c.greenComponent > c.blueComponent * 1.6 { greenPixels += 1 }
                if c.redComponent > 0.2 && c.redComponent > c.greenComponent * 1.6 && c.redComponent > c.blueComponent * 1.6 { redPixels += 1 }
            }
        }
        XCTAssertGreaterThan(bluePixels, 100)
        XCTAssertGreaterThan(greenPixels, 100)
        XCTAssertEqual(redPixels, 0)
        var revision = ProjectRevision(model: model, preview: preview, partLayout: PartLayout(nodes: parts), parts: parts)
        revision.partColors = try PartColorState.applyingPhysical(changes: patch,
            to: PartColorState.resolved(in: parts, overrides: [:]), in: parts)
        let restored = try ProjectStore.decode(ProjectStore.encode(LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id)))
        XCTAssertEqual(restored.revisions[0].partColors?["red"], blue)
        XCTAssertEqual(restored.revisions[0].partColors?["green"], parts.flatMap(\.flattened).first { $0.id == "green" }?.color)
        XCTAssertEqual(restored.revisions[0].parts, parts)
        XCTAssertNil(restored.revisions[0].preview)
        let rebuilt = try await engine.buildPreview(restored.revisions[0].model, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(rebuilt.parts, parts)

        let nextRoot = root.appendingPathComponent("refinement")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        let nextProgram = script(reversed: true)
        try Data(nextProgram.utf8).write(to: nextRoot.appendingPathComponent("program.py"))
        let nextTools = try CADAgentTools(directory: nextRoot, python: EngineService.defaultPython, threads: 2,
            current: model, currentPreview: rebuilt, engine: engine,
            partLayout: PartLayout(nodes: parts), partColors: ["red": blue])
        defer { nextTools.cancel() }
        let next = try content(try await nextTools.handle(name: "lad_build", arguments: ["programPath": "program.py"]))
        let nextColors = try content(try await nextTools.handle(name: "lad_get_part_colors", arguments: ["artifactID": XCTUnwrap(next["artifactID"] as? String)]))
        let items = try XCTUnwrap(nextColors["items"] as? [[String: Any]])
        let nextRed = try XCTUnwrap(items.first { $0["partID"] as? String == "red" })
        XCTAssertNotEqual(nextRed["solidIndices"] as? [Int], redPart.solidIndices)
        let effective = try JSONDecoder().decode(PartColor.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(nextRed["color"])))
        XCTAssertEqual(effective, blue, "Reordering solids must retain colors by stable part identity.")
    }

    private func script(reversed: Bool) -> String {
        let red = "result.add(cq.Workplane('XY').box(2,2,1).translate((-3,0,0)), name='Red', color=cq.Color(0.9,0.08,0.08), metadata={'lad_id':'red'})"
        let green = "result.add(cq.Workplane('XY').box(2,2,1).translate((3,0,0)), name='Green', color=cq.Color(0.08,0.9,0.08), metadata={'lad_id':'green'})"
        return "result=cq.Assembly(name='Parts', metadata={'lad_id':'parts'})\n" + (reversed ? [green, red] : [red, green]).joined(separator: "\n") + "\n"
    }

    private func content(_ result: [String: Any]) throws -> [String: Any] {
        let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first { $0["type"] as? String == "text" }?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
