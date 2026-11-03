import Foundation
import XCTest
@testable import LAD

final class ProjectSaveLocationTests: XCTestCase {
    func testDefaultUsesDocumentsUntilICloudDriveExistsAndHonorsCustomFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-save-location-\(UUID())")
        let suite = "LAD-save-location-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        XCTAssertEqual(ProjectSaveLocation.directory(defaults: defaults, home: home), home.appendingPathComponent("Documents/LAD", isDirectory: true))
        let cloud = ProjectSaveLocation.cloudDirectory(home: home)
        try FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(ProjectSaveLocation.directory(defaults: defaults, home: home), cloud)
        XCTAssertEqual(ProjectSaveLocation.displayName(for: URL(fileURLWithPath: cloud.path), home: home), "iCloud Drive")
        XCTAssertEqual(ProjectSaveLocation.displayName(for: ProjectSaveLocation.documentsDirectory(home: home), home: home), "Documents/LAD")
        let chosen = home.appendingPathComponent("My Special Folder", isDirectory: true)
        defaults.set(chosen.path, forKey: ProjectSaveLocation.preferenceKey)
        XCTAssertEqual(ProjectSaveLocation.directory(defaults: defaults, home: home), chosen)
        defaults.removeObject(forKey: ProjectSaveLocation.preferenceKey)
        XCTAssertEqual(ProjectSaveLocation.directory(defaults: defaults, home: home), cloud)
    }

    @MainActor
    func testExternalProjectAutosavesInPlaceWithItsIdentityAndRenamesWithinItsFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-in-place-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Project.lad")
        let identity = UUID()
        let project = LADProject(messages: [ChatMessage(role: "user", content: "Original request")], revisions: [],
                                 selectedRevisionID: nil, projectID: identity)
        try ProjectStore.write(project, to: source)
        let original = try ProjectAutosaveStore.readProject(from: source)
        let unavailableDefault = directory.appendingPathComponent("missing-parent/LAD")
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: unavailableDefault))
        state.loadProject(original, from: source)
        state.prompt = "An unsent draft kept in the opened file"
        await state.prepareToQuit()
        XCTAssertFalse(state.hasUnsavedChanges, state.saveStatus ?? "")
        XCTAssertEqual(state.projectURL, source)
        XCTAssertEqual(state.projectDocumentID, identity)
        XCTAssertEqual(try ProjectStore.read(from: source).draftPrompt, state.prompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailableDefault.path))

        try state.renameProject(to: "Renamed here")
        await state.prepareToQuit()
        let renamed = directory.appendingPathComponent("Renamed here.lad", isDirectory: false)
        XCTAssertEqual(state.projectURL, renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try ProjectStore.read(from: renamed).projectID, identity)

        let reopened = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("another-default")))
        reopened.loadProject(try ProjectAutosaveStore.readProject(from: renamed), from: renamed)
        reopened.prompt = "Later edits after reopening"
        await reopened.prepareToQuit()
        XCTAssertEqual(reopened.projectURL, renamed)
        XCTAssertEqual(try ProjectStore.read(from: renamed).draftPrompt, reopened.prompt)
        XCTAssertEqual(reopened.projectDocumentID, identity)
    }

    func testExternalProjectConflictPreservesOtherWritersChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-external-conflict-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Project.lad")
        let id = UUID()
        let original = LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: id)
        try ProjectStore.write(original, to: source)
        var opened = try ProjectAutosaveStore.readProject(from: source)
        var remote = original
        remote.draftPrompt = "Other writer"
        try ProjectStore.write(remote, to: source)
        let remoteBytes = try ProjectStore.readArchive(from: source)
        opened.draftPrompt = "My edits"
        let store = ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("unused"))
        do {
            _ = try await store.write(project: opened, projectID: id, title: "Different title", sequence: 1, preferredURL: source)
            XCTFail("An external file needs the same conflict protection as a default-folder file")
        } catch { XCTAssertTrue(error is ProjectSaveConflict) }
        XCTAssertEqual(try ProjectStore.readArchive(from: source), remoteBytes)
    }

    func testRestorationFindsRenamedExternalIdentityBeforeConsultingUnavailableDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-external-restore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Original.lad")
        let renamed = directory.appendingPathComponent("Renamed.lad")
        let id = UUID()
        try ProjectStore.write(LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: id), to: renamed)
        try ProjectStore.write(LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: UUID()), to: source)
        let store = ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("missing-parent/LAD"))
        let restored = try await store.restoreRecent(preferredURL: source, projectID: id)
        XCTAssertEqual(restored.map { ProjectFileOrigin.canonicalURL($0.url) }, ProjectFileOrigin.canonicalURL(renamed))
        XCTAssertEqual(restored?.project.projectID, id)
    }
}
