import Foundation
import XCTest
@testable import LAD

final class AppStateViewOptionsTests: XCTestCase {
    @MainActor
    func testLiveViewChoicesSaveAndReloadWithoutLeakingBetweenProjects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        first.newProjectWithSubmittedRequest()
        first.projectionMode = .isometric
        first.displayMode = .translucent
        first.showGrid = false
        await first.prepareToQuit()
        let firstURL = try XCTUnwrap(first.projectURL)

        let second = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        second.newProjectWithSubmittedRequest()
        second.displayMode = .wireframe
        await second.prepareToQuit()
        let secondURL = try XCTUnwrap(second.projectURL)
        XCTAssertNotEqual(firstURL, secondURL)
        let firstSaved = try ProjectStore.read(from: firstURL)
        let secondSaved = try ProjectStore.read(from: secondURL)
        XCTAssertEqual(firstSaved.projectionMode, .isometric)
        XCTAssertEqual(firstSaved.displayMode, .translucent)
        XCTAssertEqual(firstSaved.showGrid, false)
        XCTAssertEqual(secondSaved.projectionMode, .perspective)
        XCTAssertEqual(secondSaved.displayMode, .wireframe)
        XCTAssertEqual(secondSaved.showGrid, true)

        let reopened = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        reopened.displayMode = .shaded
        XCTAssertNil(reopened.projectURL)
        XCTAssertNil(reopened.saveStatus)
        reopened.loadProject(firstSaved, from: firstURL)
        XCTAssertEqual(reopened.projectionMode, .isometric)
        XCTAssertEqual(reopened.displayMode, .translucent)
        XCTAssertFalse(reopened.showGrid)
        await reopened.prepareToQuit()
        XCTAssertEqual(reopened.projectURL, firstURL)
        XCTAssertEqual(try ProjectStore.read(from: firstURL).displayMode, .translucent)
        XCTAssertEqual(try ProjectStore.read(from: secondURL).displayMode, .wireframe)
    }

    @MainActor
    func testNewProjectResetsViewChoicesAndPreservesThePreviousFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.newProjectWithSubmittedRequest()
        state.projectionMode = .isometric
        state.displayMode = .translucent
        state.showGrid = false
        await state.prepareToQuit()
        let previousURL = try XCTUnwrap(state.projectURL)

        state.newProject()
        await state.prepareToQuit()
        XCTAssertEqual(state.projectionMode, .perspective)
        XCTAssertEqual(state.displayMode, .edges)
        XCTAssertTrue(state.showGrid)
        XCTAssertNil(state.projectURL)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(try ProjectStore.read(from: previousURL).projectionMode, .isometric)
        XCTAssertEqual(try ProjectStore.read(from: previousURL).displayMode, .translucent)
    }

    @MainActor
    func testMissingViewChoicesRestoreDefaultsInsteadOfInheritingCurrentChoices() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: UUID())
        let url = directory.appendingPathComponent("Plain design.lad")
        try ProjectStore.write(project, to: url)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.projectionMode = .isometric
        state.displayMode = .translucent
        state.loadProject(try ProjectStore.read(from: url), from: url)
        XCTAssertEqual(state.projectionMode, .perspective)
        XCTAssertEqual(state.displayMode, .edges)
        await state.prepareToQuit()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-view-state-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
