import Foundation
import XCTest
@testable import LAD

final class CADAgentPartMaterialTests: XCTestCase {
    private let abs = PartMaterial(name: "ABS", density: 1.05)
    private let aluminum = PartMaterial(name: "Aluminum 6061", density: 2.70)
    private let resin = PartMaterial(name: "Tough resin", density: 1.18)
    private let oldABS = PartMaterial(name: "ABS", density: 1.04)

    @MainActor
    func testAgentsReadAssignmentsDesignMaterialsAndTheLibraryWithoutAPreview() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let custom = PartMaterial(name: "Carbon fiber", density: 1.6)
        let tools = try fixture.tools(includePreview: false, materials: CADPartMaterialContext(
            assignments: ["lid": oldABS], design: [resin], library: PartMaterial.standard + [custom]))
        let page = try await materials(tools)
        XCTAssertEqual(page["total"] as? Int, 4)
        XCTAssertEqual(page["densityUnit"] as? String, "g/cm³")
        XCTAssertTrue(try item("case", in: page)["material"] == nil, "A structural folder has no material of its own")
        XCTAssertTrue(try item("base", in: page)["material"] is NSNull)
        XCTAssertEqual(try material("lid", in: page), oldABS)
        let design = try decoded(page["designMaterials"])
        XCTAssertEqual(design, [resin, oldABS], "Assigned materials missing from the library belong to the design")
        let library = try decoded(page["libraryMaterials"])
        XCTAssertTrue(library.contains(custom))
        XCTAssertTrue(library.contains(abs))
        XCTAssertEqual(tools.partMaterialPatch(for: nil), CADPartMaterialPatch())
    }

    @MainActor
    func testAssignmentsResolveDesignBeforeLibraryAndBatchesStayAtomic() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tools = try fixture.tools(includePreview: false, materials: CADPartMaterialContext(assignments: ["other": oldABS]))
        _ = try await set(tools, ["changes": [["partID": "case", "material": "aluminum 6061"]]])
        _ = try await set(tools, ["changes": [["partID": "base", "material": "abs"]]])
        var page = try await materials(tools)
        XCTAssertEqual(try material("base", in: page), oldABS, "The design's own ABS takes precedence over the library's")
        XCTAssertEqual(try material("lid", in: page), aluminum)
        _ = try await set(tools, ["changes": [["partID": "other", "material": NSNull()]]])
        page = try await materials(tools)
        XCTAssertTrue(try item("other", in: page)["material"] is NSNull)
        let staged = tools.partMaterialPatch(for: nil)
        XCTAssertEqual(staged.changes, [CADPartMaterialChange(partID: "base", material: oldABS),
                                        CADPartMaterialChange(partID: "lid", material: aluminum),
                                        CADPartMaterialChange(partID: "other", material: nil)])
        XCTAssertTrue(staged.definitions.isEmpty)

        let invalid: [[String: Any]] = [
            [:], ["changes": []], ["changes": [["partID": "base"]]],
            ["changes": [["partID": "base", "material": "Unobtainium"]]],
            ["changes": [["partID": "base", "material": 7.85]]],
            ["changes": [["partID": "missing", "material": "ABS"]]],
            ["changes": [["partID": "case", "material": "ABS"], ["partID": "base", "material": "PLA"]]],
            ["changes": [["partID": "base", "material": "PLA"]], "unexpected": true],
            ["materials": [["name": "Glass", "density": 2.5]], "changes": [["partID": "missing", "material": "Glass"]]]
        ]
        for arguments in invalid {
            do { _ = try await set(tools, arguments); XCTFail("Invalid material change accepted: \(arguments)") } catch {}
            XCTAssertEqual(tools.partMaterialPatch(for: nil), staged, "\(arguments)")
        }
    }

    @MainActor
    func testDefinedMaterialsStayWithTheDesignAndRejectConflictingNames() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tools = try fixture.tools(includePreview: false, materials: CADPartMaterialContext(design: [resin]))
        let glass = PartMaterial(name: "Glass-filled nylon", density: 1.36)
        let result = try await set(tools, ["materials": [["name": " Glass-filled nylon ", "density": 1.36]],
                                           "changes": [["partID": "lid", "material": "GLASS-FILLED NYLON"]]])
        XCTAssertEqual(result["definedMaterialCount"] as? Int, 1)
        XCTAssertEqual(try material("lid", in: result), glass)
        XCTAssertEqual(try decoded(result["designMaterials"]).first, glass)

        // Definitions alone need no artifact and do not change assignments.
        let wood = PartMaterial(name: "Oak", density: 0.75)
        _ = try await set(tools, ["artifactID": "unknown", "materials": [["name": "Oak", "density": 0.75],
                                                                         ["name": "Tough resin", "density": 1.18]]])
        let patch = tools.partMaterialPatch(for: nil)
        XCTAssertEqual(patch.definitions, [glass, wood])
        XCTAssertEqual(patch.changes, [CADPartMaterialChange(partID: "lid", material: glass)])

        for definition: [String: Any] in [["name": "ABS", "density": 1.2], ["name": "tough resin", "density": 2],
                                          ["name": "Glass-filled nylon", "density": 1.4], ["name": "Air", "density": 0],
                                          ["name": "Osmium+", "density": 1_000], ["name": "Flag", "density": true],
                                          ["name": "Glass", "density": 2.5, "color": "green"]] {
            do { _ = try await set(tools, ["materials": [definition]]); XCTFail("Accepted \(definition)") } catch {}
        }
        XCTAssertEqual(tools.partMaterialPatch(for: nil), patch)
        tools.cancel()
        XCTAssertEqual(tools.partMaterialPatch(for: nil), CADPartMaterialPatch(), "Cancellation discards staged materials")
    }

    @MainActor
    func testInspectAndMeasureReportPartMass() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tools = try fixture.tools(materials: CADPartMaterialContext(assignments: ["base": aluminum]))
        let inspected = try content(try await tools.handle(name: "lad_inspect", arguments: ["kind": "parts"]))
        let parts = try XCTUnwrap(inspected["items"] as? [[String: Any]])
        let base = try XCTUnwrap(parts.first { $0["partID"] as? String == "base" })
        XCTAssertEqual(try XCTUnwrap(base["mass"] as? Double), 2.7, accuracy: 1e-9)
        XCTAssertEqual(try JSONDecoder().decode(PartMaterial.self, from: JSONSerialization.data(withJSONObject: base["material"]!)), aluminum)
        let lid = try XCTUnwrap(parts.first { $0["partID"] as? String == "lid" })
        XCTAssertEqual(lid["mass"] as? Double, 0)
        XCTAssertTrue(lid["material"] is NSNull)

        let measured = try content(try await tools.handle(name: "lad_measure", arguments: ["solidIndices": [0]]))
        let metrics = try XCTUnwrap(measured["metrics"] as? [[String: Any]])
        let mass = try XCTUnwrap((metrics.first { $0["id"] as? String == "parts:mass" }?["values"] as? [Double])?.first)
        XCTAssertEqual(mass, 2.7, accuracy: 1e-9)
    }

    @MainActor
    private func set(_ tools: CADAgentTools, _ arguments: [String: Any]) async throws -> [String: Any] {
        try content(try await tools.handle(name: "lad_set_part_materials", arguments: arguments))
    }

    @MainActor
    private func materials(_ tools: CADAgentTools, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try content(try await tools.handle(name: "lad_get_part_materials", arguments: arguments))
    }

    private func content(_ result: CADAgentToolResult) throws -> [String: Any] { result.metadata }

    private func item(_ id: String, in page: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((page["items"] as? [[String: Any]])?.first { $0["partID"] as? String == id })
    }

    private func material(_ id: String, in page: [String: Any]) throws -> PartMaterial {
        let value = try XCTUnwrap(try item(id, in: page)["material"] as? [String: Any])
        return try JSONDecoder().decode(PartMaterial.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func decoded(_ value: Any?) throws -> [PartMaterial] {
        try JSONDecoder().decode([PartMaterial].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(value)))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let model: ModelSpec
        let preview: PreviewMesh
        let parts: [PartNode]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-agent-materials-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
                PartNode(id: "base", name: "Base", solidIndices: [0]),
                PartNode(id: "lid", name: "Lid", solidIndices: [1])]),
                PartNode(id: "other", name: "Other", solidIndices: [2])]
            model = ModelSpec(title: "Materials", summary: "Material fixture", units: "mm", script: "result=cq.Workplane('XY').box(2,2,1)")
            let native = root.appendingPathComponent("model.brep")
            try Data("DBRep_DrawableShape\n".utf8).write(to: native)
            preview = PreviewMesh(vertices: [[-1,-1,0],[1,-1,0],[1,1,0],[-1,1,0]], triangles: [[0,1,2],[0,2,3]],
                edges: [], bounds: [-1,-1,0,1,1,1], volume: 3_000, area: 18, solids: 3, faces: 3, buildSeconds: 0, threads: 1,
                stepPath: root.appendingPathComponent("unused.step").path, triangleSolids: [0,0], parts: parts, brepPath: native.path,
                topology: CADTopology(vertices: [], edges: [], faces: [], parts: (0..<3).map {
                    CADPart(solidIndex: $0, area: 600, volume: 1_000, bounds: [0,0,0,10,10,10], centroid: [5,5,5])
                }))
        }

        func tools(includePreview: Bool = true, materials: CADPartMaterialContext = CADPartMaterialContext()) throws -> CADAgentTools {
            try CADAgentTools(directory: root, python: "/missing/python", threads: 1, current: model,
                currentPreview: includePreview ? preview : nil, engine: EngineService(),
                partLayout: PartLayout(nodes: parts), materials: materials)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
