import Foundation
import XCTest
@testable import LAD

final class AppStateSelectionContextTests: XCTestCase {
    @MainActor
    func testPartSelectionWhilePreviewLoadsIsCapturedWithoutStartingAnotherBuild() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let revision = try installGeometry(in: state)
        state.mesh = nil
        state.isWorking = true
        state.selectPartNodes(["case"])
        state.prompt = "Change these selected parts once loading finishes"
        state.submit()
        let captured = try XCTUnwrap(state.queuedRequests.first?.selection)
        XCTAssertEqual(captured.revisionID, revision.id)
        XCTAssertEqual(captured.parts.map(\.partID), ["base", "lid"])
        XCTAssertEqual(captured.parts.map(\.path), [["Case", "Base"], ["Case", "Lid"]])
        XCTAssertTrue(captured.parts.allSatisfy { $0.anchor == nil })
        XCTAssertTrue(captured.features.isEmpty)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)
        state.cancel()
        await state.prepareToQuit()
    }

    @MainActor
    func testImmediateRequestCapturesWholeFolderPartsBeforeLiveSelectionChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let revision = try installGeometry(in: state)
        state.selectPartNodes(["case"])
        state.prompt = "Round the selected enclosure parts"
        state.submit()
        let message = try XCTUnwrap(state.messages.first(where: { $0.role == "user" }))
        let captured = try XCTUnwrap(message.selection)
        XCTAssertEqual(captured.revisionID, revision.id)
        XCTAssertEqual(captured.parts.map(\.partID), ["base", "lid"])
        XCTAssertEqual(captured.parts.map(\.solidIndex), [0, 1])
        XCTAssertEqual(captured.parts.map(\.path), [["Case", "Base"], ["Case", "Lid"]])
        XCTAssertTrue(captured.features.isEmpty)
        XCTAssertEqual(captured.parts[0].anchor?.volume, 16)
        XCTAssertEqual(captured.parts[1].anchor?.bounds, [10, 0, 0, 14, 4, 1])

        state.clearSelections()
        state.selectPartNodes(["lid"])
        XCTAssertEqual(state.messages.first(where: { $0.id == message.id })?.selection, captured,
                       "A submitted request must retain its original selection rather than the live tree selection.")
        state.cancel() // Cancel before yielding: neither Codex nor a CAD worker starts.
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.messages.first(where: { $0.id == message.id })?.selection, captured)
    }

    @MainActor
    func testImmediateFeatureRequestKeepsOrderedTopologyIdentitiesAndExactAnchors() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let revision = try installGeometry(in: state)
        let features = [id(.face, solid: 1), id(.edge, solid: 0), id(.vertex, solid: 0)]
        state.selectFeatures(features)
        XCTAssertTrue(state.selectedSolids.isEmpty, "Feature owners are partially selected, not whole-part selections.")
        state.prompt = "Modify these selected features"
        state.submit()
        let captured = try XCTUnwrap(state.messages.first(where: { $0.role == "user" })?.selection)
        XCTAssertEqual(captured.revisionID, revision.id)
        XCTAssertTrue(captured.parts.isEmpty, "Owning parts must not be silently promoted to whole-part requests.")
        XCTAssertEqual(captured.features.map(\.id), features)
        XCTAssertEqual(captured.features.map(\.partID), ["lid", "base", "base"])
        XCTAssertEqual(captured.features.map(\.partPath), [["Case", "Lid"], ["Case", "Base"], ["Case", "Base"]])
        XCTAssertEqual(captured.features[0].anchor?.area, 8)
        XCTAssertEqual(captured.features[0].anchor?.normal, [0, 0, 1])
        XCTAssertEqual(captured.features[1].anchor?.length, 4)
        XCTAssertEqual(captured.features[2].anchor?.position, [0, 0, 0])

        var replacement = try XCTUnwrap(state.mesh)
        replacement.topology?.vertices[0].position = [99, 99, 99]
        state.mesh = replacement
        state.clearSelections()
        XCTAssertEqual(state.messages.first(where: { $0.role == "user" })?.selection, captured,
                       "Replacing or clearing viewport topology must not alter captured feature anchors.")
        state.cancel()
        await state.prepareToQuit()
    }

    @MainActor
    func testQueuedSelectionSurvivesEditingReorderingArchiveReopenAndDispatch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let revision = try installGeometry(in: state)
        state.isWorking = true
        state.selectPartNodes(["case"])
        state.prompt = "Round these selected parts"
        state.submit()
        let first = try XCTUnwrap(state.queuedRequests.first)
        let firstSelection = try XCTUnwrap(first.selection)
        XCTAssertEqual(firstSelection.revisionID, revision.id)
        XCTAssertEqual(firstSelection.parts.map(\.partID), ["base", "lid"])

        let featureIDs = [id(.vertex, solid: 1), id(.vertex, solid: 0)]
        state.selectFeatures(featureIDs)
        state.prompt = "Use these selected parts and vertices"
        state.submit()
        let second = try XCTUnwrap(state.queuedRequests.last)
        let secondSelection = try XCTUnwrap(second.selection)
        XCTAssertEqual(secondSelection.features.map(\.id), featureIDs)
        XCTAssertEqual(secondSelection.parts.map(\.partID), ["base", "lid"],
                       "Selecting features must retain explicitly selected parts in the request snapshot.")

        state.clearSelections()
        state.selectPartNodes(["lid"])
        state.prompt = "Keep this unsent draft"
        state.beginEditingQueuedRequest(id: first.id)
        state.prompt = "Round these selected parts with a 2 mm radius"
        XCTAssertTrue(state.commitEditingQueuedRequest())
        XCTAssertEqual(state.prompt, "Keep this unsent draft")
        XCTAssertEqual(state.queuedRequests.first?.selection, firstSelection,
                       "Editing text in the composer must not recapture a different live selection.")
        state.beginEditingQueuedRequest(id: second.id)
        state.prompt = "Discard this text edit"
        state.selectFeatures([id(.face, solid: 0)])
        state.cancelEditingQueuedRequest()
        XCTAssertEqual(state.queuedRequests.last?.selection, secondSelection)
        state.moveQueuedRequest(id: second.id, beforeID: first.id)
        XCTAssertEqual(state.queuedRequests.map(\.id), [second.id, first.id])
        state.clearSelections()
        let expected = state.queuedRequests
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)

        state.cancel()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.queuedRequests, expected)
        let reopened = fixture.state("Reopened")
        reopened.loadProject(saved, from: url)
        reopened.cancel() // Stop revision replay before yielding to a worker.
        XCTAssertEqual(reopened.queuedRequests, expected)
        XCTAssertTrue(reopened.queuePaused)
        XCTAssertTrue(reopened.selectedFeatures.isEmpty)
        XCTAssertTrue(reopened.selectedSolids.isEmpty)
        reopened.resumeQueue()
        let dispatched = try XCTUnwrap(reopened.messages.first(where: { $0.role == "user" }))
        XCTAssertEqual(dispatched.content, second.content)
        XCTAssertEqual(dispatched.selection, secondSelection,
                       "Dispatch must use the saved request snapshot even though no live topology is loaded.")
        XCTAssertEqual(reopened.queuedRequests.map(\.id), [first.id])
        XCTAssertEqual(reopened.queuedRequests.first?.selection, firstSelection)
        reopened.cancel()
        await reopened.prepareToQuit()
    }

    @MainActor
    func testSelectionSnapshotsRemainIndependentAcrossOpenProjects() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.state("First"), second = fixture.state("Second")
        let firstRevision = try installGeometry(in: first)
        let secondRevision = try installGeometry(in: second)
        first.isWorking = true; second.isWorking = true
        first.selectPartNodes(["base"])
        second.selectFeatures([id(.face, solid: 1)])
        first.prompt = "Change the base in the first design"; first.submit()
        second.prompt = "Change the face in the second design"; second.submit()
        let firstSelection = try XCTUnwrap(first.queuedRequests.first?.selection)
        let secondSelection = try XCTUnwrap(second.queuedRequests.first?.selection)
        XCTAssertEqual(firstSelection.revisionID, firstRevision.id)
        XCTAssertEqual(secondSelection.revisionID, secondRevision.id)
        XCTAssertNotEqual(firstSelection.revisionID, secondSelection.revisionID)
        XCTAssertEqual(firstSelection.parts.map(\.partID), ["base"])
        XCTAssertTrue(firstSelection.features.isEmpty)
        XCTAssertEqual(secondSelection.features.map(\.partID), ["lid"])
        XCTAssertTrue(secondSelection.parts.isEmpty)
        first.clearSelections()
        first.newProject()
        XCTAssertTrue(first.queuedRequests.isEmpty)
        XCTAssertEqual(second.queuedRequests.first?.selection, secondSelection)
        second.cancel()
        await first.prepareToQuit(); await second.prepareToQuit()
        let secondSaved = try ProjectStore.read(from: XCTUnwrap(second.projectURL))
        XCTAssertEqual(secondSaved.queuedRequests?.first?.selection, secondSelection)
    }

    @MainActor
    func testNoSelectionDoesNotInventRequestContext() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        _ = try installGeometry(in: state)
        state.isWorking = true
        state.prompt = "Add a new unrelated part"
        state.submit()
        XCTAssertNil(state.queuedRequests.first?.selection)
        state.cancel()
        await state.prepareToQuit()
    }

    @MainActor
    private func installGeometry(in state: AppState) throws -> ProjectRevision {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]),
            PartNode(id: "lid", name: "Lid", solidIndices: [1])
        ])]
        let vertices = [[0.0, 0, 0], [4, 0, 0], [0, 4, 0], [10, 0, 0], [14, 0, 0], [10, 4, 0]]
        let topology = CADTopology(
            vertices: [CADVertex(id: id(.vertex, solid: 0), position: [0, 0, 0]),
                       CADVertex(id: id(.vertex, solid: 1), position: [10, 0, 0])],
            edges: [CADEdge(id: id(.edge, solid: 0), type: "LINE", length: 4,
                            polyline: [[0, 0, 0], [4, 0, 0]], direction: [1, 0, 0],
                            startPoint: [0, 0, 0], endPoint: [4, 0, 0]),
                    CADEdge(id: id(.edge, solid: 1), type: "LINE", length: 4,
                            polyline: [[10, 0, 0], [14, 0, 0]], direction: [1, 0, 0],
                            startPoint: [10, 0, 0], endPoint: [14, 0, 0])],
            faces: [CADFace(id: id(.face, solid: 0), type: "PLANE", area: 8,
                            center: [4.0 / 3, 4.0 / 3, 0], normal: [0, 0, 1]),
                    CADFace(id: id(.face, solid: 1), type: "PLANE", area: 8,
                            center: [10 + 4.0 / 3, 4.0 / 3, 0], normal: [0, 0, 1])],
            parts: [CADPart(solidIndex: 0, area: 48, volume: 16, bounds: [0, 0, 0, 4, 4, 1], centroid: [2, 2, 0.5]),
                    CADPart(solidIndex: 1, area: 48, volume: 16, bounds: [10, 0, 0, 14, 4, 1], centroid: [12, 2, 0.5])])
        let preview = PreviewMesh(vertices: vertices, triangles: [[0, 1, 2], [3, 4, 5]],
            edges: [[0, 0, 0, 4, 0, 0], [10, 0, 0, 14, 0, 0]], bounds: [0, 0, 0, 14, 4, 1],
            volume: 32, area: 96, solids: 2, faces: 2, buildSeconds: 0, threads: 1,
            stepPath: "/session/selection-\(UUID().uuidString).step", triangleSolids: [0, 1], edgeSolids: [0, 1],
            parts: parts, topology: topology, triangleFaces: [0, 1], edgeFeatures: [0, 1])
        try CADMeasurements.validateTopology(preview)
        let revision = ProjectRevision(model: .bracket, preview: preview, parts: parts)
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        state.mesh = preview
        return revision
    }

    private func id(_ kind: CADFeatureKind, solid: Int) -> CADFeatureID {
        CADFeatureID(kind: kind, solidIndex: solid, localIndex: 0)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        private let originalCodex: Any?

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-selection-state-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            originalCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
        }

        func state(_ name: String = "Original") -> AppState {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent(name)))
            state.newProject()
            return state
        }

        func cleanUp() {
            if let originalCodex { UserDefaults.standard.set(originalCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
