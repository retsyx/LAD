import XCTest
@testable import LAD

final class AppStateSidebarLayoutTests: XCTestCase {
    @MainActor
    func testDividerChangeAutosavesAndReopensWithoutARevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-sidebar-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.newProject()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        XCTAssertEqual(state.partsPaneFraction, 0.75)

        state.setPartsPaneFraction(0.61)
        for _ in 0..<100 {
            if !state.hasUnsavedChanges { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(state.hasUnsavedChanges)
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.partsPaneFraction, 0.61)
        XCTAssertTrue(saved.revisions.isEmpty)

        let reopened = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        reopened.loadProject(saved, from: url)
        XCTAssertEqual(reopened.partsPaneFraction, 0.61)
        reopened.newProject()
        XCTAssertEqual(reopened.partsPaneFraction, 0.75)
        await reopened.prepareToQuit()
    }

    @MainActor
    func testSidebarPreferenceIsIndependentOfHistoryAndRejectsInvalidInput() {
        let first = AppState(), second = AppState()
        first.setPartsPaneFraction(0.4)
        let revisions = [ProjectRevision(model: .bracket), ProjectRevision(model: .bracket)]
        first.revisions = revisions
        first.selectedRevisionID = revisions[0].id
        first.selectedRevisionID = revisions[1].id
        XCTAssertEqual(first.partsPaneFraction, 0.4)
        XCTAssertEqual(second.partsPaneFraction, 0.75)
        for invalid in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            first.setPartsPaneFraction(invalid)
            XCTAssertEqual(first.partsPaneFraction, 0.4)
        }
    }
}
