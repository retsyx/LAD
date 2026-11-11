import Foundation
import XCTest
@testable import LAD

final class AppStateFeatureSelectionTests: XCTestCase {
    @MainActor
    func testPartRangeTreatsFeatureOnlySelectionAsUnselectedAndPreservesFeatures() throws {
        let state = try fixture()
        defer { state.clearSelections() }
        let features = [feature(.vertex, 1, 0)]
        state.selectFeatures(features)
        state.selectPartNodes(["base"])
        state.togglePartNode("board", extendingRange: true)
        XCTAssertEqual(state.selectedSolids, [0, 1, 2], "A feature-selected lid must not stop the range before base.")
        XCTAssertEqual(state.selectedFeatures, features)

        state.togglePartNode("lid")
        state.togglePartNode("base", extendingRange: true)
        XCTAssertEqual(state.selectedSolids, [2], "The feature-selected lid is an unselected boundary.")
        XCTAssertEqual(state.selectedFeatures, features)
    }

    @MainActor
    func testOrderedFeatureUpdatesDeduplicateAndRejectHiddenOrMissingTopology() throws {
        let state = try fixture()
        state.hiddenSolids = [1]
        let first = feature(.vertex, 0, 0), second = feature(.vertex, 0, 1)
        state.selectFeatures([second, first, second, feature(.face, 1, 0), feature(.vertex, 0, 99), feature(.vertex, 99, 0)])
        XCTAssertEqual(state.selectedFeatures, [second, first])
        XCTAssertEqual(state.featureSelectedSolids, [0])
        XCTAssertEqual(try values(state, "pair:delta"), [-3, -4, 0])

        // The viewport supplies its ordered result after each toggle. Removing
        // and later re-adding an item must retain that new order for angles.
        state.selectFeatures([first])
        XCTAssertEqual(state.selectedFeatures, [first])
        state.selectFeatures([first, second])
        XCTAssertEqual(state.selectedFeatures, [first, second])
        XCTAssertEqual(try values(state, "pair:delta"), [3, 4, 0])
        XCTAssertFalse(state.isMeasuring, "Two exact vertex coordinates need no worker")
        XCTAssertNil(state.measurementError)
        state.clearSelections()
    }

    @MainActor
    func testTreeAndWholePartSelectionPreserveOrderedFeaturesAndCanonicalTreeSelection() throws {
        let state = try fixture()
        defer { state.clearSelections() }
        let features = [feature(.face, 2, 0), feature(.vertex, 0, 0), feature(.edge, 1, 0)]
        state.selectFeatures(features)
        state.selectPartNodes(["case"])
        XCTAssertEqual(state.selectedFeatures, features)
        XCTAssertEqual(state.selectedSolids, [0, 1])
        XCTAssertEqual(state.selectedPartNodeIDs, ["case"])

        state.selectParts([2])
        XCTAssertEqual(state.selectedFeatures, features)
        XCTAssertEqual(state.selectedSolids, [2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["board"])
        XCTAssertEqual(state.measurementReport?.features, features)
        XCTAssertEqual(state.measurementReport?.solidIndices, [2])
        XCTAssertEqual(try values(state, "parts:count"), [1])
        XCTAssertEqual(try values(state, "vertex:0:0:position"), [0, 0, 0])

        state.selectParts([1], extending: true)
        XCTAssertEqual(state.selectedSolids, [1, 2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["lid", "board"])
        XCTAssertEqual(state.selectedFeatures, features)
        state.selectParts([2], extending: true)
        XCTAssertEqual(state.selectedSolids, [1])
        XCTAssertEqual(state.selectedPartNodeIDs, ["lid"])
        XCTAssertEqual(state.selectedFeatures, features)

        state.selectPartNodes(["case"], extending: true)
        XCTAssertEqual(state.selectedSolids, [0, 1])
        XCTAssertEqual(state.selectedPartNodeIDs, ["case"])
        XCTAssertEqual(state.selectedFeatures, features)
        state.selectPartNodes(["case"], extending: true)
        XCTAssertTrue(state.selectedSolids.isEmpty)
        XCTAssertTrue(state.selectedPartNodeIDs.isEmpty)
        XCTAssertEqual(state.selectedFeatures, features, "Deselecting a folder must retain its selected features.")

        state.selectParts([])
        XCTAssertEqual(state.selectedFeatures, features, "Clearing whole-part selection must retain feature selection.")
        XCTAssertEqual(state.measurementReport?.features, features)
    }

    @MainActor
    func testFeatureTogglesPreserveWholePartsAndSelectedFolderIdentity() throws {
        let state = try fixture()
        defer { state.clearSelections() }
        state.selectPartNodes(["case"])
        let face = feature(.face, 2, 0), vertex = feature(.vertex, 0, 0), edge = feature(.edge, 1, 0)
        let ordered = [face, vertex, edge]
        state.selectFeatures(ordered + [face])
        XCTAssertEqual(state.selectedFeatures, ordered)
        XCTAssertEqual(state.selectedSolids, [0, 1])
        XCTAssertEqual(state.selectedPartNodeIDs, ["case"])
        XCTAssertEqual(state.selectedPartSolids, [0, 1, 2])
        XCTAssertEqual(state.measurementReport?.features, ordered)
        XCTAssertEqual(state.measurementReport?.solidIndices, [0, 1])
        XCTAssertEqual(try values(state, "parts:count"), [2])

        // The viewport supplies the ordered result after each toggle.
        state.selectFeatures([face, edge])
        state.selectFeatures([face, edge, vertex])
        XCTAssertEqual(state.selectedFeatures, [face, edge, vertex])
        XCTAssertEqual(state.selectedSolids, [0, 1])
        XCTAssertEqual(state.selectedPartNodeIDs, ["case"])
        state.selectFeatures([])
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertEqual(state.selectedSolids, [0, 1], "Deselecting all features must retain whole-part selection.")
        XCTAssertEqual(state.selectedPartNodeIDs, ["case"])
        XCTAssertEqual(state.measurementReport?.solidIndices, [0, 1])

        state.selectFeatures(ordered)
        state.clearSelections()
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertTrue(state.selectedSolids.isEmpty)
        XCTAssertTrue(state.selectedPartNodeIDs.isEmpty)
        XCTAssertNil(state.measurementReport)
    }

    @MainActor
    func testFeatureSelectionIsPartialButItsOwnerCanBeExportedAndColored() throws {
        let state = try fixture()
        state.selectFeatures([feature(.vertex, 0, 0)])
        XCTAssertTrue(state.selectedSolids.isEmpty, "A vertex must not highlight its entire owner")
        XCTAssertTrue(state.selectedPartNodeIDs.isEmpty, "A feature selection must not look like a whole tree row selection")
        XCTAssertEqual(state.selectedPartSolids, [0])
        XCTAssertTrue(state.canExportSelectedParts)

        let color = PartColor(red: 0.2, green: 0.5, blue: 0.8)
        state.setPartColor(color, for: "base")
        XCTAssertEqual(state.solidColors, [0: color])
        XCTAssertEqual(state.selectedFeatures, [feature(.vertex, 0, 0)], "Color changes retain the exact selected feature")
        state.clearSelections()
        XCTAssertFalse(state.canExportSelectedParts)
    }

    @MainActor
    func testHideSelectedUsesTheUnionOfWholePartsAndFeatureOwnersAndClearsFeedback() throws {
        let state = try fixture()
        state.selectFeatures([feature(.vertex, 0, 0), feature(.vertex, 0, 1)])
        state.selectParts([2])
        XCTAssertEqual(state.selectedPartSolids, [0, 2])
        state.hideSelectedParts()
        XCTAssertEqual(state.hiddenSolids, [0, 2])
        XCTAssertEqual(state.revisions.first?.hiddenSolids, [0, 2])
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertTrue(state.selectedSolids.isEmpty)
        XCTAssertTrue(state.selectedPartNodeIDs.isEmpty)
        XCTAssertFalse(state.hasMeasurementSelection)
        XCTAssertNil(state.measurementReport)
        XCTAssertNil(state.measurementError)
        XCTAssertFalse(state.isMeasuring)
        state.showAllParts()
        XCTAssertTrue(state.hiddenSolids.isEmpty)
        XCTAssertEqual(state.revisions.first?.hiddenSolids, [])
    }

    @MainActor
    func testVisibilityToggleRemovesOnlyFeaturesOwnedByTheHiddenParts() throws {
        let state = try fixture()
        let a = feature(.vertex, 0, 0), b = feature(.vertex, 1, 0), c = feature(.vertex, 2, 0)
        state.selectFeatures([c, b, a])
        state.togglePartVisibility([1])
        XCTAssertEqual(state.selectedFeatures, [c, a])
        XCTAssertEqual(state.featureSelectedSolids, [0, 2])
        XCTAssertEqual(state.hiddenSolids, [1])
        XCTAssertNil(state.measurementError)
        XCTAssertFalse(state.isMeasuring)
        state.togglePartVisibility([1])
        XCTAssertEqual(state.selectedFeatures, [c, a], "Showing a part must not reselect a discarded feature")
        state.clearSelections()
    }

    @MainActor
    func testInvalidFeatureUpdatePreservesWholePartSelectionAndMissingMetadataIsIgnored() throws {
        let state = try fixture()
        state.selectParts([2])
        state.selectFeatures([feature(.face, 0, 99)])
        XCTAssertEqual(state.selectedSolids, [2])
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        var replacement = try XCTUnwrap(state.mesh)
        replacement.stepPath = "without-topology"
        replacement.topology = nil
        replacement.triangleFaces = nil
        replacement.edgeFeatures = nil
        state.mesh = replacement
        state.clearSelections()
        state.selectFeatures([feature(.vertex, 0, 0)])
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertNil(state.measurementReport)
    }

    @MainActor
    func testMeshReplacementAndHistoryNavigationDiscardSessionFeatureSelection() throws {
        let state = try fixture()
        state.selectFeatures([feature(.vertex, 0, 0)])
        var replacement = try XCTUnwrap(state.mesh)
        replacement.brepPath = "/session/replacement/model.brep"
        state.mesh = replacement
        XCTAssertTrue(state.selectedFeatures.isEmpty, "A reused STEP path must not carry feature IDs into different native topology")
        XCTAssertNil(state.measurementReport)
        state.selectFeatures([feature(.vertex, 0, 0)])
        replacement.stepPath = "replacement-preview"
        state.mesh = replacement
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertNil(state.measurementReport)

        let first = try XCTUnwrap(state.revisions.first)
        let second = ProjectRevision(model: .bracket, preview: preview(path: "history-second"), parts: parts())
        state.revisions.append(second)
        state.selectFeatures([feature(.vertex, 1, 0)])
        state.selectRevision(second.id)
        XCTAssertEqual(state.mesh?.stepPath, "history-second")
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertNil(state.measurementReport)
        state.selectFeatures([feature(.vertex, 2, 0)])
        state.selectRevision(first.id)
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertNil(state.measurementReport)
    }

    @MainActor
    func testMetadataFeedbackIsImmediateAndSupersededNativeRequestsCannotOverwriteIt() async throws {
        let state = try fixture()
        state.selectFeatures([feature(.face, 0, 0), feature(.edge, 1, 0)])
        XCTAssertTrue(state.isMeasuring)
        XCTAssertNotNil(state.measurementReport, "Known exact properties are available while native distance is pending")
        state.selectFeatures([feature(.vertex, 0, 1)])
        XCTAssertFalse(state.isMeasuring)
        XCTAssertEqual(try values(state, "vertex:0:1:position"), [3, 4, 0])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(state.measurementError)
        XCTAssertEqual(state.selectedFeatures, [feature(.vertex, 0, 1)])
        XCTAssertEqual(try values(state, "vertex:0:1:position"), [3, 4, 0])
        state.clearSelections()
        XCTAssertNil(state.measurementReport)
    }

    @MainActor
    func testNewAndLoadedProjectsClearFeaturesAndCancelPreviousMeasurements() async throws {
        let state = try fixture()
        state.selectFeatures([feature(.face, 0, 0), feature(.edge, 1, 0)])
        XCTAssertTrue(state.isMeasuring)
        state.newProject()
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertNil(state.measurementReport)
        XCTAssertFalse(state.isMeasuring)
        await state.prepareToQuit()
        XCTAssertNil(state.projectURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-feature-reset-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let incomingRevision = ProjectRevision(model: .bracket, preview: preview(path: "loaded-preview"), parts: parts())
        let incoming = LADProject(messages: [], revisions: [incomingRevision], selectedRevisionID: incomingRevision.id,
                                  projectID: UUID(), projectName: "Incoming")
        let incomingURL = directory.appendingPathComponent("Incoming.lad")
        try ProjectStore.write(incoming, to: incomingURL)
        state.loadProject(incoming, from: incomingURL)
        state.selectFeatures([feature(.vertex, 0, 0)])
        XCTAssertNotNil(state.measurementReport)
        let empty = LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: UUID(), projectName: "Empty")
        let emptyURL = directory.appendingPathComponent("Empty.lad")
        try ProjectStore.write(empty, to: emptyURL)
        state.loadProject(empty, from: emptyURL)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertNil(state.measurementReport)
        XCTAssertNil(state.measurementError)
        XCTAssertFalse(state.isMeasuring)
        await state.prepareToQuit()
    }

    private func feature(_ kind: CADFeatureKind, _ owner: Int, _ local: Int) -> CADFeatureID {
        CADFeatureID(kind: kind, solidIndex: owner, localIndex: local)
    }

    @MainActor
    private func values(_ state: AppState, _ identity: String) throws -> [Double] {
        try XCTUnwrap(state.measurementReport?.metrics.first { $0.id == identity }, identity).values
    }

    @MainActor
    private func fixture() throws -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-feature-state-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root))
        let revision = ProjectRevision(model: .bracket, preview: preview(path: "initial-preview"), parts: parts())
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        return state
    }

    private func parts() -> [PartNode] {
        [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]), PartNode(id: "lid", name: "Lid", solidIndices: [1])]),
         PartNode(id: "board", name: "Board", solidIndices: [2])]
    }

    private func preview(path: String) -> PreviewMesh {
        let vertices = [CADVertex(id: feature(.vertex, 0, 0), position: [0, 0, 0]),
                        CADVertex(id: feature(.vertex, 0, 1), position: [3, 4, 0]),
                        CADVertex(id: feature(.vertex, 1, 0), position: [5, 0, 0]),
                        CADVertex(id: feature(.vertex, 2, 0), position: [0, 5, 0])]
        let edges = (0..<3).map { owner in
            CADEdge(id: feature(.edge, owner, 0), type: "LINE", length: 1,
                    polyline: [[Double(owner * 5), 0, 0], [Double(owner * 5 + 1), 0, 0]])
        }
        let faces = (0..<3).map { owner in
            CADFace(id: feature(.face, owner, 0), type: "PLANE", area: 1, center: [Double(owner * 5) + 0.5, 0.5, 0], normal: [0, 0, 1], perimeter: 4)
        }
        let owners = (0..<3).map { owner in
            CADPart(solidIndex: owner, area: 6, volume: 1,
                    bounds: [Double(owner * 5), 0, 0, Double(owner * 5 + 1), 1, 1], centroid: [Double(owner * 5) + 0.5, 0.5, 0.5])
        }
        return PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2], [0, 1, 2], [0, 1, 2]], edges: [],
                           bounds: [0, 0, 0, 11, 5, 1], volume: 3, area: 18, solids: 3, faces: 3,
                           buildSeconds: 0, threads: 1, stepPath: path, triangleSolids: [0, 1, 2], edgeSolids: [], parts: parts(),
                           topology: CADTopology(vertices: vertices, edges: edges, faces: faces, parts: owners), triangleFaces: [0, 1, 2], edgeFeatures: [])
    }
}
