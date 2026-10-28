import Foundation
import XCTest
@testable import LAD

final class ProjectSelectionContextTests: XCTestCase {
    func testMixedFeatureSelectionPreservesOrderAndExactOwnersWithoutSelectingWholeParts() throws {
        let mesh = preview()
        let ordered = [feature(.face, solid: 1), feature(.vertex), feature(.edge)]
        let selection = try XCTUnwrap(ProjectSelectionContext.capture(revisionID: UUID(), preview: mesh,
            nodes: hierarchy(), selectedSolids: [], selectedNodeIDs: [], selectedFeatures: ordered + [ordered[0]]))
        XCTAssertTrue(selection.parts.isEmpty, "Partially selected owning parts must not be sent as whole-part selections.")
        XCTAssertEqual(selection.features.map(\.id), ordered)
        XCTAssertEqual(selection.features.map(\.partID), ["lid", "base", "base"])
        XCTAssertEqual(selection.features[0].partPath, ["Case", "Lid"])
        XCTAssertEqual(selection.features[0].anchor?.geometryType, "plane")
        XCTAssertEqual(selection.features[0].anchor?.area, 12)
        XCTAssertEqual(selection.features[0].anchor?.normal, [0, 0, 1])
        XCTAssertEqual(selection.features[1].anchor?.position, [1, 2, 3])
        XCTAssertEqual(selection.features[2].anchor?.radius, 2)
        XCTAssertEqual(selection.features[2].anchor?.length, 4 * .pi)
        XCTAssertNoThrow(try selection.validate())
    }

    func testSelectedFoldersExpandToNamedPartsInDeterministicSolidOrder() throws {
        let selection = try XCTUnwrap(ProjectSelectionContext.capture(revisionID: UUID(), preview: preview(),
            nodes: hierarchy(), selectedSolids: [1], selectedNodeIDs: ["case"], selectedFeatures: []))
        XCTAssertEqual(selection.parts.map(\.solidIndex), [0, 1])
        XCTAssertEqual(selection.parts.map(\.partID), ["base", "lid"])
        XCTAssertEqual(selection.parts.map(\.path), [["Case", "Base"], ["Case", "Lid"]])
        XCTAssertEqual(selection.parts[0].anchor?.bounds, [0, 0, 0, 4, 4, 4])
        XCTAssertEqual(selection.parts[1].anchor?.volume, 24)
        XCTAssertTrue(selection.features.isEmpty)
        XCTAssertNil(ProjectSelectionContext.capture(revisionID: UUID(), preview: preview(), nodes: hierarchy(),
            selectedSolids: [], selectedNodeIDs: [], selectedFeatures: [feature(.vertex, local: 99)]))
    }

    func testCaptureIsIndependentOfSubsequentGeometryAndHierarchyChanges() throws {
        var mesh = preview()
        var nodes = hierarchy()
        let selection = try XCTUnwrap(ProjectSelectionContext.capture(revisionID: UUID(), preview: mesh,
            nodes: nodes, selectedSolids: [0], selectedNodeIDs: [], selectedFeatures: [feature(.vertex)]))
        mesh.topology?.vertices[0].position = [100, 100, 100]
        mesh.topology?.parts[0].bounds = [100, 100, 100, 200, 200, 200]
        nodes[0].name = "Changed folder"
        nodes[0].children?[0].name = "Changed part"
        XCTAssertEqual(selection.parts[0].name, "Base")
        XCTAssertEqual(selection.parts[0].path, ["Case", "Base"])
        XCTAssertEqual(selection.parts[0].anchor?.bounds, [0, 0, 0, 4, 4, 4])
        XCTAssertEqual(selection.features[0].anchor?.position, [1, 2, 3])
    }

    func testNamedPartSelectionSurvivesWhileNativeGeometryIsStillLoading() throws {
        let selection = try XCTUnwrap(ProjectSelectionContext.capture(revisionID: UUID(), preview: nil,
            nodes: hierarchy(), selectedSolids: [], selectedNodeIDs: ["case"], selectedFeatures: [feature(.vertex)]))
        XCTAssertEqual(selection.parts.map(\.solidIndex), [0, 1])
        XCTAssertEqual(selection.parts.map(\.partID), ["base", "lid"])
        XCTAssertEqual(selection.parts.map(\.path), [["Case", "Base"], ["Case", "Lid"]])
        XCTAssertTrue(selection.parts.allSatisfy { $0.anchor == nil }, "An unloaded preview must not introduce guessed geometry anchors.")
        XCTAssertTrue(selection.features.isEmpty, "Stale feature IDs cannot be captured without their native topology.")
        XCTAssertNoThrow(try selection.validate())
    }

    func testChatAndQueuedSelectionsRoundTripAsIntentWithoutDerivedGeometryAssets() throws {
        let captured = try XCTUnwrap(ProjectSelectionContext.capture(revisionID: UUID(), preview: preview(),
            nodes: hierarchy(), selectedSolids: [1], selectedNodeIDs: [], selectedFeatures: [feature(.vertex), feature(.edge)]))
        let user = ChatMessage(role: "user", content: "Round this selected edge", selection: captured)
        let queue = ProjectQueuedRequest(content: "Move the selected lid", selection: captured)
        let project = LADProject(messages: [user], revisions: [], selectedRevisionID: nil, queuedRequests: [queue])
        let bytes = try ProjectStore.encode(project)
        let restored = try ProjectStore.decode(bytes)
        XCTAssertEqual(restored.messages, [user])
        XCTAssertEqual(restored.queuedRequests, [queue])
        XCTAssertEqual(restored.messages[0].selection?.revisionID, captured.revisionID,
                       "Save New may preserve a prompt whose originating revision is outside the copied history.")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(manifest["assets"] as? [String: String]).isEmpty,
                      "Selection intent must not introduce programs, STEP, images, meshes or topology caches.")
        let json = String(decoding: try ProjectZIP.decode(bytes), as: UTF8.self)
        for forbidden in ["polyline", "triangles", "topology", "preview", "stepPath", "brepPath"] {
            XCTAssertFalse(json.contains("\"\(forbidden)\""), "The saved selected-target anchors must stay compact.")
        }
    }

    func testInvalidSelectionsCannotEnterAProjectArchive() throws {
        let original = try XCTUnwrap(ProjectSelectionContext.capture(revisionID: UUID(), preview: preview(),
            nodes: hierarchy(), selectedSolids: [0], selectedNodeIDs: [], selectedFeatures: [feature(.vertex)]))
        var invalid = original
        invalid.parts[0].solidIndex = -1
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.features.append(invalid.features[0])
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.features[0].anchor?.position = [Double.nan, 1, 2]
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.parts[0].path = ["folder\nname"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = original
        invalid.parts[0].anchor?.bounds = [4, 0, 0, 0, 1, 1]
        XCTAssertThrowsError(try invalid.validate())
        let message = ChatMessage(role: "assistant", content: "Done", selection: original)
        XCTAssertThrowsError(try ProjectStore.encode(LADProject(messages: [message], revisions: [], selectedRevisionID: nil)))
        let queue = ProjectQueuedRequest(content: "Apply the change", selection: invalid)
        XCTAssertThrowsError(try ProjectStore.encode(LADProject(messages: [], revisions: [], selectedRevisionID: nil, queuedRequests: [queue])))
    }

    private func feature(_ kind: CADFeatureKind, solid: Int = 0, local: Int = 0) -> CADFeatureID {
        CADFeatureID(kind: kind, solidIndex: solid, localIndex: local)
    }

    private func hierarchy() -> [PartNode] {
        [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [1]),
            PartNode(id: "base", name: "Base", solidIndices: [0])
        ])]
    }

    private func preview() -> PreviewMesh {
        var mesh = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 4, 4, 6], volume: 88,
            area: 152, solids: 2, faces: 12, buildSeconds: 0, threads: 1, stepPath: "/temporary/preview.json")
        mesh.topology = CADTopology(vertices: [CADVertex(id: feature(.vertex), position: [1, 2, 3])], edges: [
            CADEdge(id: feature(.edge), type: "circle", length: 4 * .pi, polyline: [[0, 0, 0], [1, 1, 0]],
                    radius: 2, center: [2, 2, 0], axis: [0, 0, 1], startPoint: [4, 2, 0], endPoint: [4, 2, 0])
        ], faces: [CADFace(id: feature(.face, solid: 1), type: "plane", area: 12, center: [2, 2, 6], normal: [0, 0, 1])], parts: [
            CADPart(solidIndex: 0, area: 96, volume: 64, bounds: [0, 0, 0, 4, 4, 4], centroid: [2, 2, 2]),
            CADPart(solidIndex: 1, area: 56, volume: 24, bounds: [0, 0, 4, 4, 4, 6], centroid: [2, 2, 5])
        ])
        return mesh
    }
}
