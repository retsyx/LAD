import XCTest
@testable import LAD

/// Session previews are a bounded navigation cache, separate from saved history.
final class AppStatePreviewRetentionTests: XCTestCase {
    @MainActor
    func testOnlyRecentlyDisplayedRevisionsKeepPreviews() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-preview-retention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root))
        let count = AppState.retainedRevisionPreviews + 2
        let revisions = (0..<count).map { index in
            ProjectRevision(model: .bracket, preview: preview(path: "revision-\(index)"),
                            parts: [PartNode(id: "body", name: "Body", solidIndices: [0])])
        }
        state.revisions = revisions
        for revision in revisions { state.selectRevision(revision.id) }

        let retained = state.revisions.filter { $0.preview != nil }.map(\.id)
        XCTAssertEqual(retained, Array(revisions.suffix(AppState.retainedRevisionPreviews)).map(\.id))
        XCTAssertEqual(state.mesh?.stepPath, "revision-\(count - 1)")
        // Saved revision fields stay with every revision, previewed or not.
        XCTAssertEqual(state.revisions.map(\.model), revisions.map(\.model))
        XCTAssertEqual(state.revisions.map(\.parts), revisions.map(\.parts))

        // Revisiting a retained revision makes it the most recent again.
        state.selectRevision(revisions[count - AppState.retainedRevisionPreviews].id)
        XCTAssertEqual(state.mesh?.stepPath, "revision-\(count - AppState.retainedRevisionPreviews)")
        XCTAssertEqual(state.revisions.filter { $0.preview != nil }.count, AppState.retainedRevisionPreviews)
    }

    private func preview(path: String) -> PreviewMesh {
        PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2]], edges: [],
                    bounds: [0, 0, 0, 1, 1, 0], volume: 0, area: 0.5, solids: 1, faces: 1,
                    buildSeconds: 0, threads: 1, stepPath: path, triangleSolids: [0], edgeSolids: [],
                    parts: [PartNode(id: "body", name: "Body", solidIndices: [0])])
    }
}
