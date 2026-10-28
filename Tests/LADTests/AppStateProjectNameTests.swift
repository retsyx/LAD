import XCTest
@testable import LAD

final class AppStateProjectNameTests: XCTestCase {
    @MainActor
    func testProjectHeaderUsesLatestProjectNameAcrossHistorySelection() {
        let first = ProjectRevision(model: .bracket)
        var changed = ModelSpec.bracket
        changed.title = "Latest enclosure design"
        let last = ProjectRevision(model: changed)
        let state = AppState()
        state.revisions = [first, last]
        state.selectedRevisionID = first.id
        XCTAssertEqual(state.current?.title, first.model.title)
        XCTAssertEqual(state.title, last.model.title)
        XCTAssertEqual(state.projectDisplayName, last.model.title)
        state.selectedRevisionID = last.id
        XCTAssertEqual(state.projectDisplayName, last.model.title)
    }

    @MainActor
    func testHeaderKeepsActualCollisionFilenameThroughoutOrdinaryAutosavesAndFailures() {
        let state = AppState()
        state.revisions = [ProjectRevision(model: .bracket)]
        state.projectURL = URL(fileURLWithPath: "/tmp/Workshop bracket (2).lad")
        XCTAssertEqual(state.projectDisplayName, "Workshop bracket (2)")
        state.saveStatus = "Saving…"
        XCTAssertEqual(state.projectDisplayName, "Workshop bracket (2)")
        state.saveStatus = "Not saved: iCloud Drive is unavailable."
        XCTAssertEqual(state.projectDisplayName, "Workshop bracket (2)")
        state.saveStatus = nil
        XCTAssertEqual(state.projectDisplayName, "Workshop bracket (2)")
    }

    @MainActor
    func testInitialPlaceholderCannotBeRenamedOrSaved() {
        let state = AppState()
        XCTAssertFalse(state.canRenameProject)
        XCTAssertThrowsError(try state.renameProject(to: "Should not be saved"))
        XCTAssertNil(state.projectName)
        XCTAssertNil(state.projectURL)
        XCTAssertNil(state.saveStatus)
    }

    @MainActor
    func testAutosaveURLAndHistoryChangesDoNotChangeInlineEditingIdentity() {
        let state = AppState()
        let identity = state.projectEditingID
        state.projectURL = URL(fileURLWithPath: "/tmp/Before.lad")
        state.projectURL = URL(fileURLWithPath: "/tmp/After.lad")
        let revision = ProjectRevision(model: .bracket)
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertEqual(state.projectEditingID, identity)
    }
}
