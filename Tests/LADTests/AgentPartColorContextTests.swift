import Foundation
import XCTest
@testable import LAD

final class AgentPartColorContextTests: XCTestCase {
    private let blue = PartColor(red: 0.1, green: 0.2, blue: 0.8)
    private let red = PartColor(red: 0.9, green: 0.1, blue: 0.1)

    func testCurrentColorMetadataCopyKeepsHierarchyAndOriginalValuesUnchanged() {
        let original = parts()
        let copied = PartColorState.nodesWithCurrentColors(original, stored: ["body": red])
        XCTAssertNil(copied[0].color, "A structural folder has no physical color of its own.")
        XCTAssertEqual(copied[0].children?[0].color, red)
        XCTAssertEqual(copied[0].children?[1].color, PartColorState.defaultFinish)
        XCTAssertEqual(copied[0].children?.map(\.id), original[0].children?.map(\.id))
        XCTAssertEqual(copied[0].name, original[0].name)
        XCTAssertEqual(copied[0].children?.map(\.solidIndices), original[0].children?.map(\.solidIndices))
        XCTAssertEqual(original[0].color, blue)
        XCTAssertEqual(original[0].children?[0].color, blue)
        XCTAssertNil(original[0].children?[1].color)
    }

    @MainActor
    func testCodexCurrentLayoutFileContainsCurrentRGBWithoutChangingSuppliedLayout() async throws {
        let codex = try FakeCodex(responseJSON: #"{"status":"message","message":"Current colors inspected.","model":null,"assetIDs":[]}"#)
        defer { codex.remove() }
        let layout = PartLayout(nodes: parts(), movedNodeIDs: ["body"], collapsedNodeIDs: ["folder"])
        let service = CodexService()
        let response = try await service.generate(prompt: "Inspect current colors", current: .bracket, history: [],
            partLayout: layout, partColors: ["body": red], executable: codex.executable.path,
            model: "", onProgress: { _ in }, python: EngineService.defaultPython)
        XCTAssertEqual(response, .response("Current colors inspected."))
        let workspace = try String(contentsOf: codex.workingDirectoryURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedPath = URL(fileURLWithPath: workspace).appendingPathComponent("context/parts-layout.json").path
        let staged = try JSONDecoder().decode(PartLayout.self, from: codex.capturedData(at: stagedPath))
        XCTAssertEqual(staged.nodes[0].children?[0].color, red)
        XCTAssertEqual(staged.nodes[0].children?[1].color, PartColorState.defaultFinish)
        XCTAssertNil(staged.nodes[0].color)
        XCTAssertEqual(staged.movedNodeIDs, layout.movedNodeIDs)
        XCTAssertEqual(staged.collapsedNodeIDs, layout.collapsedNodeIDs)
        XCTAssertEqual(layout.nodes[0].children?[0].color, blue)
        XCTAssertTrue(service.partColorChanges.isEmpty)
    }

    func testHistoricalPartAndLayoutReferencesContainThatVersionsCurrentRGB() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let revision = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: parts()),
                                       parts: parts(), partColors: ["body": red])
        let version = try XCTUnwrap(ProjectVersionContext(revisions: [revision], selectedRevisionID: nil).versions.first)
        let prepared = try CADAgentVersionFiles.prepare(version, workspace: CADAgentWorkspace(directory: directory))
        let layoutFile = try XCTUnwrap(prepared.files.first { $0.path.hasSuffix("/parts-layout.json") })
        let partsFile = try XCTUnwrap(prepared.files.first { $0.path.hasSuffix("/parts.json") })
        let layout = try JSONDecoder().decode(PartLayout.self, from: layoutFile.data)
        let stagedParts = try JSONDecoder().decode([PartNode].self, from: partsFile.data)
        XCTAssertEqual(layout.nodes, stagedParts)
        XCTAssertEqual(stagedParts[0].children?[0].color, red)
        XCTAssertEqual(stagedParts[0].children?[1].color, PartColorState.defaultFinish)
        XCTAssertNil(stagedParts[0].color)
        XCTAssertEqual(version.parts?[0].children?[0].color, blue)
        XCTAssertEqual(revision.partLayout?.nodes[0].color, blue)
    }

    private func parts() -> [PartNode] {
        [PartNode(id: "folder", name: "My folder", solidIndices: [], children: [
            PartNode(id: "body", name: "My body", solidIndices: [0], color: blue),
            PartNode(id: "plain", name: "Plain body", solidIndices: [1])], color: blue)]
    }

    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-color-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
