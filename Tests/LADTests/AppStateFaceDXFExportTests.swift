import Foundation
import XCTest
@testable import LAD

final class AppStateFaceDXFExportTests: XCTestCase {
    func testDefaultNameJoinsTheDesignAndTheFacesOwningPart() {
        let tree = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [1]),
            PartNode(id: "base", name: "Base", solidIndices: [0])
        ])]
        XCTAssertEqual(FaceDXFExport.partName(for: 1, in: tree), "Lid")
        XCTAssertEqual(FaceDXFExport.partName(for: 0, in: tree), "Base")
        XCTAssertEqual(FaceDXFExport.partName(for: 4, in: tree), "Part 5")
        XCTAssertEqual(FaceDXFExport.fileName(design: "Tentacle PCB Case", part: "Lid"), "Tentacle PCB Case - Lid.dxf")
        XCTAssertEqual(FaceDXFExport.fileName(design: "Étagère", part: "Shelf (left)"), "Étagère - Shelf (left).dxf")
        XCTAssertEqual(FaceDXFExport.fileName(design: ".Rack", part: "Rail 2/3: top"), "Rack - Rail 2 3  top.dxf",
                       "Path separators and hidden-file prefixes never reach the save dialog.")
    }

    func testDXFValidationRequiresACompleteDrawing() throws {
        let drawing = Data("  0\nSECTION\n  2\nHEADER\n  0\nENDSEC\n  0\nEOF\n".utf8)
        XCTAssertNoThrow(try EngineService.validateDXF(drawing))
        XCTAssertNoThrow(try EngineService.validateDXF(Data("  0\r\nSECTION\r\n  0\r\nEOF\r\n".utf8)))
        XCTAssertThrowsError(try EngineService.validateDXF(Data()))
        XCTAssertThrowsError(try EngineService.validateDXF(drawing.dropLast(4)), "A truncated drawing has no EOF marker.")
        XCTAssertThrowsError(try EngineService.validateDXF(Data("ISO-10303-21;\nEND-ISO-10303-21;\n".utf8)))
    }

    @MainActor
    func testExportsTheSelectedFlatFaceFromTheDisplayedGeometry() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the native DXF export regression test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-face-DXF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldThreads = UserDefaults.standard.object(forKey: "workerThreads")
        UserDefaults.standard.set(2, forKey: "workerThreads")
        let model = ModelSpec(title: "Face DXF fixture", summary: "A box and a pin.", units: "mm", script: """
        result=cq.Assembly(name='Parts', metadata={'lad_id':'parts'})
        result.add(cq.Solid.makeCylinder(1,2), name='Pin', metadata={'lad_id':'pin'})
        result.add(cq.Solid.makeBox(5,2,3), name='Lid', loc=cq.Location((20,7,9)), metadata={'lad_id':'lid'})
        """)
        let engine = EngineService()
        let preview = try await engine.buildPreview(model, python: EngineService.defaultPython, threads: 2)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("autosaves")))
        defer {
            state.cancel()
            engine.cancel()
            if let oldThreads { UserDefaults.standard.set(oldThreads, forKey: "workerThreads") }
            else { UserDefaults.standard.removeObject(forKey: "workerThreads") }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: preview.stepPath).deletingLastPathComponent())
            try? FileManager.default.removeItem(at: directory)
        }
        let parts = try XCTUnwrap(preview.parts)
        let revision = ProjectRevision(model: model, preview: preview, partLayout: PartLayout(nodes: parts), parts: parts)
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        let topology = try XCTUnwrap(state.mesh?.topology)
        let lid = try XCTUnwrap(parts.flatMap(\.flattened).first { $0.name == "Lid" }?.solidIndices.first)
        let top = try XCTUnwrap(topology.faces.first { $0.id.solidIndex == lid && $0.normal == [0, 0, 1] }).id
        let curved = try XCTUnwrap(topology.faces.first { $0.type == "CYLINDER" }).id
        XCTAssertEqual(FaceDXFExport.partName(for: top.solidIndex, in: state.partTree), "Lid")

        let rejected = directory.appendingPathComponent("curved.dxf")
        XCTAssertFalse(state.canExportFaceDXF(curved))
        state.exportFaceDXF(curved, to: rejected)
        XCTAssertFalse(state.isWorking)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))

        let url = directory.appendingPathComponent("Face DXF fixture - Lid.dxf")
        XCTAssertTrue(state.canExportFaceDXF(top))
        state.exportFaceDXF(top, to: url)
        XCTAssertTrue(state.isWorking)
        let deadline = ContinuousClock.now + .seconds(30)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isWorking, "The native DXF export must finish.")
        XCTAssertNil(state.error)
        XCTAssertEqual(state.notice, "DXF exported · Face DXF fixture - Lid.dxf")
        let drawing = try Data(contentsOf: url)
        XCTAssertNoThrow(try EngineService.validateDXF(drawing))
        // The lid's 5 x 2 top face is centered on its centroid, with world X and Y as the drawing's axes.
        let points = entityPoints(in: String(decoding: drawing, as: UTF8.self))
        XCTAssertEqual(points.count, 8, "Four lines, each with a start and an end.")
        XCTAssertEqual(points.map(\.x).min() ?? .nan, -2.5, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.x).max() ?? .nan, 2.5, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.y).min() ?? .nan, -1, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.y).max() ?? .nan, 1, accuracy: 1e-9)
        XCTAssertEqual(state.revisions.map(\.id), [revision.id])
    }

    /// Entity start/end coordinates (group codes 10/20 and 11/21).
    private func entityPoints(in drawing: String) -> [(x: Double, y: Double)] {
        let lines = drawing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var pairs = stride(from: 0, to: lines.count - 1, by: 2).map { (lines[$0], lines[$0 + 1]) }
        guard let start = pairs.firstIndex(where: { $0 == ("2", "ENTITIES") }) else { return [] }
        pairs = Array(pairs[(start + 1)...].prefix { $0 != ("0", "ENDSEC") })
        var points = [(x: Double, y: Double)](), x: Double?
        for (code, value) in pairs {
            if code == "10" || code == "11" { x = Double(value) }
            if code == "20" || code == "21", let pending = x, let y = Double(value) { points.append((pending, y)); x = nil }
        }
        return points
    }
}
