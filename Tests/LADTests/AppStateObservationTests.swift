import Observation
import XCTest
@testable import LAD

/// Views re-render only for the properties they read. Typing must not notify
/// the state shown by the viewer, conversation or window chrome.
final class AppStateObservationTests: XCTestCase {
    @MainActor
    func testTypingNotifiesOnlyTheComposer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-observation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root))
        state.newProjectWithSubmittedRequest()
        state.prompt = "First keystroke"
        XCTAssertTrue(state.hasUnsavedChanges)

        var otherStateChanged = false, promptChanged = false
        withObservationTracking {
            _ = (state.mesh?.stepPath, state.selectedSolids, state.hiddenSolids, state.selectedFeatures,
                 state.displayMode, state.projectionMode, state.showGrid, state.viewportCommand?.id,
                 state.solidColors, state.messages, state.isWorking, state.activityStatus, state.error,
                 state.hasUnsavedChanges, state.saveStatus, state.projectDisplayName, state.projectURL,
                 state.canExport, state.canSaveNew, state.partTree)
        } onChange: { otherStateChanged = true }
        withObservationTracking { _ = state.prompt } onChange: { promptChanged = true }

        state.prompt = "Second keystroke"
        XCTAssertTrue(promptChanged)
        XCTAssertFalse(otherStateChanged, "A keystroke must not invalidate panes that do not show the prompt")
        state.cancel()
    }
}
