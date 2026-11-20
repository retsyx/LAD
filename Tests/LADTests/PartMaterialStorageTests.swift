import Foundation
import XCTest
@testable import LAD

final class PartMaterialStorageTests: XCTestCase {
    private let steel = PartMaterial(name: "Steel, Mild", density: 7.85)
    private let resin = PartMaterial(name: "Tough resin", density: 1.18)

    override func setUp() { ProjectPackage.clearSessionCache() }
    override func tearDown() { ProjectPackage.clearSessionCache() }

    func testZIPRoundtripRetainsAssignmentsAndDesignMaterials() throws {
        var original = project()
        original.revisions[0].partMaterials = ["case": steel]
        original.revisions[1].partMaterials = ["case": steel, "lid": resin]
        original.projectMaterials = [resin]
        let restored = try ProjectStore.decode(ProjectStore.encode(original))
        XCTAssertEqual(restored.revisions.map(\.partMaterials), original.revisions.map(\.partMaterials))
        XCTAssertEqual(restored.projectMaterials, [resin])

        let untouched = try ProjectStore.decode(ProjectStore.encode(project()))
        XCTAssertTrue(untouched.revisions.allSatisfy { $0.partMaterials == nil })
        XCTAssertNil(untouched.projectMaterials)
    }

    func testPackageSavesCompleteDefinitionsWithEachVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-materials-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Materials.lad", isDirectory: true)
        var original = project()
        original.revisions[1].partMaterials = ["case": steel, "lid": resin]
        original.projectMaterials = [resin]
        try ProjectPackage.write(original, to: url)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual((root["projectMaterials"] as? [[String: Any]])?.first?["density"] as? Double, 1.18)
        let partsFiles = try FileManager.default.subpathsOfDirectory(atPath: url.path).filter { $0.contains("/parts-") }
        let stored = try partsFiles.map { String(decoding: try Data(contentsOf: url.appendingPathComponent($0)), as: UTF8.self) }
        XCTAssertTrue(stored.contains { $0.contains("\"partMaterials\"") && $0.contains("Steel, Mild") && $0.contains("7.85") })

        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: url)
        XCTAssertEqual(restored.revisions.map(\.partMaterials), original.revisions.map(\.partMaterials))
        XCTAssertEqual(restored.projectMaterials, [resin])

        // A material-only change rewrites the changed version's parts record.
        var edited = restored
        edited.revisions[1].partMaterials = ["lid": steel]
        try ProjectPackage.write(edited, to: url)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).revisions[1].partMaterials, ["lid": steel])
    }

    func testInvalidAssignmentsAndDesignMaterialsCannotBeSaved() throws {
        for materials in [["missing": steel], ["custom-folder": steel], ["lid": PartMaterial(name: "Air", density: 0)],
                          ["lid": PartMaterial(name: "Line\nbreak", density: 1)]] {
            var value = project()
            value.revisions[0].partMaterials = materials
            XCTAssertThrowsError(try ProjectStore.encode(value), "\(materials)")
        }
        var value = project()
        value.revisions[0].partMaterials = ["case": steel]
        XCTAssertNoThrow(try ProjectStore.encode(value), "An assembly that owns geometry can have its own material")
        value.projectMaterials = [resin, PartMaterial(name: "TOUGH RESIN", density: 2)]
        XCTAssertThrowsError(try ProjectStore.encode(value))
        value.projectMaterials = [PartMaterial(name: "Dense", density: 1_000)]
        XCTAssertThrowsError(try ProjectStore.encode(value))
    }

    func testSaveNewRetainsAssignmentsAndDesignMaterials() throws {
        var original = project()
        original.revisions[1].partMaterials = ["lid": resin]
        original.projectMaterials = [resin]
        let copy = try ProjectStore.decode(ProjectStore.encode(SaveNewProject.snapshot(from: original)))
        XCTAssertEqual(copy.revisions.count, 1)
        XCTAssertEqual(copy.revisions[0].partMaterials, ["lid": resin])
        XCTAssertEqual(copy.projectMaterials, [resin])
    }

    private func project() -> LADProject {
        let assembly = PartNode(id: "case", name: "Case", solidIndices: [0], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [1])
        ])
        let custom = PartNode(id: "custom-folder", name: "My assembly", solidIndices: [], children: [assembly])
        let layout = PartLayout(nodes: [custom], movedNodeIDs: ["case"], userFolderIDs: ["custom-folder"])
        let first = ProjectRevision(model: .bracket, partLayout: layout, parts: [assembly])
        let last = ProjectRevision(model: .bracket, partLayout: layout, parts: [assembly])
        return LADProject(messages: [ChatMessage(role: "user", content: "Create a case")],
                          revisions: [first, last], selectedRevisionID: last.id, projectID: UUID())
    }
}
