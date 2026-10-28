import Foundation
import XCTest
@testable import LAD

final class AppStateRecentProjectTests: XCTestCase {
    @MainActor
    func testClearedRecentListStaysEmptyThroughAutosavesAndCloseFlushUntilExplicitOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recent = RecentProjects(defaults: fixture.defaults)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: fixture.directory))
        state.onRecentProjectChanged = { recent.record($0, replacing: $1) }
        state.newProject()
        await state.prepareToQuit()
        let savedURL = try XCTUnwrap(state.projectURL)
        XCTAssertEqual(recent.urls, [savedURL])

        recent.clear()
        state.displayMode = .translucent
        state.saveProject()
        await state.prepareToQuit()
        XCTAssertTrue(recent.urls.isEmpty)
        XCTAssertTrue(RecentProjects(defaults: fixture.defaults, initialURL: savedURL).urls.isEmpty)

        state.noteProjectOpened()
        XCTAssertEqual(recent.urls, [savedURL])
    }

    @MainActor
    func testRenameUpdatesRecentReferenceWithoutRetainingTheFormerFilename() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recent = RecentProjects(defaults: fixture.defaults)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: fixture.directory))
        state.onRecentProjectChanged = { recent.record($0, replacing: $1) }
        state.newProject()
        await state.prepareToQuit()
        let originalURL = try XCTUnwrap(state.projectURL)
        let otherURL = fixture.directory.appendingPathComponent("Other.lad")
        recent.record(otherURL)

        try state.renameProject(to: "Renamed design")
        await state.prepareToQuit()
        let renamedURL = try XCTUnwrap(state.projectURL)
        XCTAssertNotEqual(renamedURL, originalURL)
        XCTAssertEqual(renamedURL.lastPathComponent, "Renamed design.lad")
        XCTAssertEqual(recent.urls, [renamedURL, otherURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
    }

    @MainActor
    func testNewAndLoadedProjectsRetainTheOtherRecentEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recent = RecentProjects(defaults: fixture.defaults)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: fixture.directory))
        state.onRecentProjectChanged = { recent.record($0, replacing: $1) }
        state.newProject()
        await state.prepareToQuit()
        let firstURL = try XCTUnwrap(state.projectURL)
        state.newProject()
        await state.prepareToQuit()
        let secondURL = try XCTUnwrap(state.projectURL)
        XCTAssertEqual(recent.urls, [secondURL, firstURL])

        let loadedURL = fixture.directory.appendingPathComponent("Loaded design.lad")
        let project = LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: UUID(), projectName: "Loaded design")
        try ProjectStore.write(project, to: loadedURL)
        state.loadProject(try ProjectStore.read(from: loadedURL), from: loadedURL)
        await state.prepareToQuit()
        XCTAssertEqual(recent.urls, [loadedURL, secondURL, firstURL])
    }

    private struct Fixture {
        let directory: URL
        let domain: String
        let defaults: UserDefaults

        init() throws {
            domain = "LAD-recent-state-\(UUID())"
            defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
