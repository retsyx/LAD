import AppKit
import Foundation
import Metal
import XCTest
@testable import LAD

final class CADAgentPartColorTests: XCTestCase {
    private let red = PartColor(red: 0.9, green: 0.1, blue: 0.1)
    private let blue = PartColor(red: 0.1, green: 0.2, blue: 0.8)
    private let green = PartColor(red: 0.1, green: 0.8, blue: 0.2)

    @MainActor
    func testCurrentColorsUseSavedLayoutWithoutBuildingAnUnavailablePreview() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tools = try fixture.tools(includePreview: false, partColors: ["lid": green])
        let page = try await colors(tools)
        XCTAssertEqual(page["total"] as? Int, 4)
        let items = try XCTUnwrap(page["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["partID"] as? String, "case")
        XCTAssertEqual(items[0]["isGroup"] as? Bool, true)
        XCTAssertNil(items[0]["color"], "A structural folder's supplied color must not cascade.")
        XCTAssertEqual(try color("base", in: page), blue)
        XCTAssertEqual(try color("lid", in: page), green)
        XCTAssertEqual(try color("other", in: page), PartColorState.defaultFinish)
        for value in items {
            XCTAssertNil(value["colorSource"])
            XCTAssertNil(value["authoredColor"])
            XCTAssertNil(value["overrideColor"])
        }
        let second = try await colors(tools, arguments: ["offset": 1, "limit": 1])
        XCTAssertEqual((second["items"] as? [[String: Any]])?.first?["partID"] as? String, "base")
        XCTAssertEqual(second["hasMore"] as? Bool, true)
        XCTAssertTrue(tools.partColorChanges(for: nil).isEmpty)
    }

    @MainActor
    func testGroupAssignmentsResetAndInvalidBatchesRemainSpeculativeAndAtomic() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tools = try fixture.tools(includePreview: false)
        _ = try await set(tools, changes: [assignment("case", red)])
        var page = try await colors(tools)
        XCTAssertEqual(try color("base", in: page), red)
        XCTAssertEqual(try color("lid", in: page), red)
        XCTAssertEqual(tools.partColorChanges(for: nil).map(\.partID), ["base", "lid"])
        _ = try await set(tools, changes: [assignment("base", nil)])
        page = try await colors(tools)
        XCTAssertEqual(try color("base", in: page), PartColorState.defaultFinish,
                       "Null selects the neutral finish regardless of the part's earlier supplied color.")
        let before = tools.partColorChanges(for: nil)
        for batch in [[assignment("other", green), assignment("missing", red)],
                      [assignment("case", red), assignment("base", blue)]] {
            do { _ = try await set(tools, changes: batch); XCTFail("An invalid batch must not be partially applied.") }
            catch {}
            XCTAssertEqual(tools.partColorChanges(for: nil), before)
        }
        let currentColors = try await colors(tools)
        XCTAssertEqual(try color("other", in: currentColors), PartColorState.defaultFinish)
        XCTAssertNil(fixture.preview.parts?.first?.children?.last?.color, "Tools must not mutate the supplied preview.")
    }

    @MainActor
    func testSequentialGroupAndChildColorsKeepAnOwningAssemblyBodySeparate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let nodes = [PartNode(id: "case", name: "Case with body", solidIndices: [0], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [1])])]
        let tools = try CADAgentTools(directory: fixture.root, python: "/missing/python", threads: 1,
            current: fixture.model, currentPreview: nil, engine: EngineService(), partLayout: PartLayout(nodes: nodes))
        _ = try await set(tools, changes: [assignment("case", red)])
        _ = try await set(tools, changes: [assignment("lid", blue)])
        let page = try await colors(tools)
        XCTAssertEqual(try color("case", in: page), red)
        XCTAssertEqual(try color("lid", in: page), blue)
        let patch = tools.partColorChanges(for: nil)
        XCTAssertEqual(patch, [CADPartColorChange(partID: "case", color: red), CADPartColorChange(partID: "lid", color: blue)])
        let committed = try PartColorState.applyingPhysical(changes: patch, to: [:], in: nodes)
        XCTAssertEqual(committed, ["case": red, "lid": blue],
                       "An expanded physical patch must not expand the assembly body into its children again.")
    }

    @MainActor
    func testStrictColorArgumentsRejectMissingFieldsBooleansNonfiniteAndUnknownIDs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tools = try fixture.tools(includePreview: false)
        let invalid: [[String: Any]] = [
            ["changes": []], ["changes": [["partID": "base"]]],
            ["changes": [["partID": "base", "color": ["red": true, "green": 0, "blue": 0]]]],
            ["changes": [["partID": "base", "color": ["red": Double.infinity, "green": 0, "blue": 0]]]],
            ["changes": [["partID": "base", "color": ["red": -0.1, "green": 0, "blue": 0]]]],
            ["changes": [["partID": "base", "color": ["red": 0, "green": 0, "blue": 0, "alpha": 1]]]],
            ["changes": [assignment("base", red), assignment("base", red)]],
            ["changes": [assignment("missing", red)]], ["changes": [assignment("base", red)], "unexpected": true]
        ]
        for arguments in invalid {
            do { _ = try await tools.handle(name: "lad_set_part_colors", arguments: arguments); XCTFail("Invalid colors accepted: \(arguments)") }
            catch {}
        }
        XCTAssertTrue(tools.partColorChanges(for: nil).isEmpty)
        for arguments in [["offset": -1], ["limit": 501], ["limit": true]] as [[String: Any]] {
            do { _ = try await colors(tools, arguments: arguments); XCTFail("Invalid pagination accepted.") }
            catch {}
        }
        _ = try await set(tools, changes: [assignment("base", red)])
        XCTAssertFalse(tools.partColorChanges(for: nil).isEmpty)
        tools.cancel()
        XCTAssertTrue(tools.partColorChanges(for: nil).isEmpty)
        XCTAssertTrue(tools.partColorChanges(for: fixture.model).isEmpty)
        do { _ = try await colors(tools); XCTFail("Canceled tools must not return colors.") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testCandidateInheritsCurrentPatchByStableIDAndOnlyMatchingArtifactIsHandedOff() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tools = try fixture.tools()
        _ = try await set(tools, changes: [assignment("base", red)])
        let built = try content(try await tools.handle(name: "lad_build", arguments: ["programPath": "program.py"]))
        let id = try XCTUnwrap(built["artifactID"] as? String)
        let candidateColors = try await colors(tools, arguments: ["artifactID": id])
        XCTAssertEqual(try color("base", in: candidateColors), red)
        _ = try await set(tools, artifactID: id, changes: [assignment("other", green)])
        let currentColors = try await colors(tools)
        XCTAssertEqual(try color("other", in: currentColors), PartColorState.defaultFinish)
        XCTAssertEqual(tools.partColorChanges(for: nil), [CADPartColorChange(partID: "base", color: red)])
        XCTAssertEqual(tools.partColorChanges(for: fixture.model).map(\.partID), ["base", "other"])
        var unrelated = fixture.model; unrelated.script += "\n# Unrelated construction"
        XCTAssertTrue(tools.partColorChanges(for: unrelated).isEmpty)
        let inspected = try content(try await tools.handle(name: "lad_inspect", arguments: ["artifactID": id, "kind": "parts"]))
        XCTAssertEqual(try color("base", in: inspected), red)
        XCTAssertNil(try item("base", in: inspected)["colorSource"])
    }

    @MainActor
    func testHistoricalReplayUsesSavedCurrentColorsAndRequiresMatchingFinalConstruction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let revision = ProjectRevision(model: fixture.model, partLayout: PartLayout(nodes: fixture.parts),
                                       parts: fixture.parts, partColors: ["lid": green])
        let versions = ProjectVersionContext(revisions: [revision], selectedRevisionID: nil)
        let tools = try fixture.tools(partColors: ["base": red, "lid": red], versions: versions)
        let built = try content(try await tools.handle(name: "lad_build", arguments: ["programPath": "program.py", "versionID": revision.id.uuidString]))
        let id = try XCTUnwrap(built["artifactID"] as? String)
        let historicalColors = try await colors(tools, arguments: ["artifactID": id])
        let currentColors = try await colors(tools)
        XCTAssertEqual(try color("lid", in: historicalColors), green)
        XCTAssertEqual(try color("lid", in: currentColors), red)
        XCTAssertEqual(tools.partColorChanges(for: fixture.model), [CADPartColorChange(partID: "base", color: blue),
            CADPartColorChange(partID: "lid", color: green)], "The final replay must match the saved current RGB values.")
        _ = try await set(tools, artifactID: id, changes: [assignment("other", blue)])
        XCTAssertTrue(tools.partColorChanges(for: nil).isEmpty)
        XCTAssertEqual(tools.partColorChanges(for: fixture.model), [CADPartColorChange(partID: "base", color: blue),
            CADPartColorChange(partID: "lid", color: green), CADPartColorChange(partID: "other", color: blue)])
    }

    @MainActor
    func testCurrentColorsSurviveMatchingPartIDsAndCandidateChangesStayIsolated() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var preview = fixture.preview
        var nodes = fixture.parts
        nodes[0].children?[0].color = nil
        preview.parts = nodes
        let tools = try CADAgentTools(directory: fixture.root, python: "/missing/python", threads: 1,
            current: fixture.model, currentPreview: preview, engine: EngineService(), solidColors: [0: red],
            partLayout: PartLayout(nodes: nodes))
        let currentColors = try await colors(tools)
        XCTAssertEqual(try color("base", in: currentColors), red)
        let current = try content(try await tools.handle(name: "lad_render", arguments: ["view": "top", "display": "shaded", "width": 256, "height": 256]))
        let built = try content(try await tools.handle(name: "lad_build", arguments: ["programPath": "program.py"]))
        let candidate = try content(try await tools.handle(name: "lad_render", arguments: ["artifactID": try XCTUnwrap(built["artifactID"]), "view": "top", "display": "shaded", "width": 256, "height": 256]))
        XCTAssertGreaterThan(try redPixels(current), 100, "The committed preview must retain its legacy red finish.")
        XCTAssertGreaterThan(try redPixels(candidate), 100, "A retained stable part ID must retain its current red color.")
        let id = try XCTUnwrap(built["artifactID"] as? String)
        _ = try await set(tools, artifactID: id, changes: [assignment("base", green)])
        let candidateColors = try await colors(tools, arguments: ["artifactID": id])
        XCTAssertEqual(try color("base", in: candidateColors), green)
        let unchangedCurrent = try await colors(tools)
        XCTAssertEqual(try color("base", in: unchangedCurrent), red)
        _ = try await set(tools, changes: [assignment("base", nil)])
        let resetColors = try await colors(tools)
        XCTAssertEqual(try color("base", in: resetColors), PartColorState.defaultFinish)
    }

    private func redPixels(_ result: [String: Any]) throws -> Int {
        let path = try XCTUnwrap(result["path"] as? String)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.5, color.redComponent > 0.15,
                   color.redComponent > color.greenComponent * 1.6, color.redComponent > color.blueComponent * 1.6 { count += 1 }
            }
        }
        return count
    }

    private func assignment(_ id: String, _ color: PartColor?) -> [String: Any] {
        ["partID": id, "color": color.map { ["red": $0.red, "green": $0.green, "blue": $0.blue] } as Any? ?? NSNull()]
    }

    @MainActor
    private func set(_ tools: CADAgentTools, artifactID: String = "current", changes: [[String: Any]]) async throws -> [String: Any] {
        try content(try await tools.handle(name: "lad_set_part_colors", arguments: ["artifactID": artifactID, "changes": changes]))
    }

    @MainActor
    private func colors(_ tools: CADAgentTools, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try content(try await tools.handle(name: "lad_get_part_colors", arguments: arguments))
    }

    private func content(_ result: CADAgentToolResult) throws -> [String: Any] {
        result.metadata
    }

    private func item(_ id: String, in page: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((page["items"] as? [[String: Any]])?.first { $0["partID"] as? String == id })
    }

    private func color(_ id: String, in page: [String: Any]) throws -> PartColor {
        let value = try XCTUnwrap(try item(id, in: page)["color"] as? [String: Any])
        return try JSONDecoder().decode(PartColor.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let model: ModelSpec
        let preview: PreviewMesh
        let parts: [PartNode]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-agent-colors-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
                PartNode(id: "base", name: "Base", solidIndices: [0], color: PartColor(red: 0.1, green: 0.2, blue: 0.8)),
                PartNode(id: "lid", name: "Lid", solidIndices: [1])], color: PartColor(red: 1, green: 0, blue: 0)),
                PartNode(id: "other", name: "Other", solidIndices: [2])]
            model = ModelSpec(title: "Colors", summary: "Color fixture", units: "mm", script: "result=cq.Workplane('XY').box(2,2,1)")
            try Data(model.script.utf8).write(to: root.appendingPathComponent("program.py"))
            let native = root.appendingPathComponent("model.brep")
            try Data("DBRep_DrawableShape\n".utf8).write(to: native)
            preview = PreviewMesh(vertices: [[-1,-1,0],[1,-1,0],[1,1,0],[-1,1,0]], triangles: [[0,1,2],[0,2,3]],
                edges: [], bounds: [-1,-1,0,1,1,1], volume: 3, area: 18, solids: 3, faces: 3, buildSeconds: 0, threads: 1,
                stepPath: root.appendingPathComponent("unused.step").path, triangleSolids: [0,0], parts: parts, brepPath: native.path,
                topology: CADTopology(vertices: [], edges: [], faces: [], parts: (0..<3).map {
                    CADPart(solidIndex: $0, area: 6, volume: 1, bounds: [0,0,0,1,1,1], centroid: [0.5,0.5,0.5])
                }))
        }

        func tools(includePreview: Bool = true, partColors: [String: PartColor] = [:],
                   versions: ProjectVersionContext = .empty, legacyColors: [Int: PartColor] = [:]) throws -> CADAgentTools {
            try CADAgentTools(directory: root, python: "/missing/python", threads: 1, current: model,
                currentPreview: includePreview ? preview : nil, engine: EngineService(), solidColors: legacyColors,
                versions: versions, partLayout: PartLayout(nodes: parts), partColors: partColors)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
