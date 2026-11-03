import Foundation
import XCTest
@testable import LAD

final class ProjectAutosaveStoreTests: XCTestCase {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-autosave-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeProject() -> LADProject {
        let revision = ProjectRevision(model: .bracket)
        return LADProject(messages: [ChatMessage(role: "user", content: "Design a bracket")], revisions: [revision], selectedRevisionID: revision.id)
    }

    func testTitleChangesRenameOneProjectWithoutLosingHistory() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        var project = makeProject()
        let first = try await store.write(project: project, projectID: id, title: "Bracket / with: slots", sequence: 1)
        XCTAssertEqual(first.lastPathComponent, "Bracket with slots.lad")
        XCTAssertEqual(try first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        XCTAssertEqual(try ProjectStore.read(from: first).projectID, id)

        project.messages.append(ChatMessage(role: "assistant", content: "I’ll add the slots and check their spacing.", phase: "commentary"))
        project.messages.append(ChatMessage(role: "assistant", content: "Model ready. Added slots.", phase: "final_answer"))
        let parts = [PartNode(id: "bracket", name: "Bracket", solidIndices: [], children: [
            PartNode(id: "body", name: "Body", solidIndices: [0])])]
        var layout = PartLayout(nodes: parts)
        try layout.setExpanded(false, for: "bracket")
        let revision = ProjectRevision(model: .bracket, partLayout: layout, hiddenSolids: [0], parts: parts)
        project.revisions.append(revision)
        project.selectedRevisionID = revision.id
        let renamed = try await store.write(project: project, projectID: id, title: "Slotted bracket", sequence: 2, preferredURL: first)
        XCTAssertEqual(renamed.lastPathComponent, "Slotted bracket.lad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try renamed.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        let restored = try ProjectStore.read(from: renamed)
        XCTAssertEqual(restored.messages, project.messages)
        XCTAssertEqual(restored.revisions.map(\.id), project.revisions.map(\.id))
        XCTAssertEqual(restored.selectedRevisionID, revision.id)
        XCTAssertEqual(restored.revisions.last?.partLayout, layout)
        XCTAssertEqual(restored.revisions.last?.hiddenSolids, [0])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Slotted bracket.lad"])
    }

    func testSameTitlesAndForeignPreferredFilesNeverOverwriteAnotherProject() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let firstID = UUID(), secondID = UUID()
        let first = try await store.write(project: makeProject(), projectID: firstID, title: "Case", sequence: 1)
        let firstBytes = try ProjectStore.readArchive(from: first)
        let second = try await store.write(project: makeProject(), projectID: secondID, title: "Case", sequence: 2, preferredURL: first)
        XCTAssertEqual(second.lastPathComponent, "Case (2).lad")
        XCTAssertEqual(try ProjectStore.readArchive(from: first), firstBytes)
        XCTAssertEqual(try ProjectStore.read(from: second).projectID, secondID)
        let freshStore = ProjectAutosaveStore(rootDirectory: root)
        let updated = try await freshStore.write(project: try ProjectStore.read(from: second), projectID: secondID, title: "Case", sequence: 3, preferredURL: second)
        XCTAssertEqual(updated, second)
        XCTAssertEqual(try ProjectStore.readArchive(from: first), firstBytes)
    }

    func testUnknownFilesAndOutsidePreferredLocationsArePreserved() async throws {
        let parent = try folder()
        let root = parent.appendingPathComponent("LAD", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let foreign = root.appendingPathComponent("Case.lad")
        let outside = parent.appendingPathComponent("Existing.lad")
        let sentinel = Data("not a LAD project; do not overwrite".utf8)
        try sentinel.write(to: foreign)
        try sentinel.write(to: outside)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let result = try await store.write(project: makeProject(), projectID: UUID(), title: "Case", sequence: 1, preferredURL: outside)
        XCTAssertEqual(result.lastPathComponent, "Case (2).lad")
        XCTAssertEqual(try Data(contentsOf: foreign), sentinel)
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    func testStaleAutosaveCannotRenameOrReplaceNewerProject() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        let older = makeProject()
        var newer = older
        newer.messages.append(ChatMessage(role: "user", content: "Make it wider"))
        let saved = try await store.write(project: newer, projectID: id, title: "Wide bracket", sequence: 10)
        let bytes = try ProjectStore.readArchive(from: saved)
        let stale = try await store.write(project: older, projectID: id, title: "Old title", sequence: 9)
        XCTAssertEqual(stale, saved)
        XCTAssertEqual(try ProjectStore.readArchive(from: saved), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Old title.lad").path))
    }

    func testUnicodeTitlesFitActualFilesystemFilenameByteLimit() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let title = String(repeating: "机械设计", count: 40)
        let first = try await store.write(project: makeProject(), projectID: UUID(), title: title, sequence: 1)
        let second = try await store.write(project: makeProject(), projectID: UUID(), title: title, sequence: 1)
        XCTAssertLessThanOrEqual(first.lastPathComponent.utf8.count, 255)
        XCTAssertLessThanOrEqual(second.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(title.hasPrefix(first.deletingPathExtension().lastPathComponent))
        XCTAssertTrue(second.deletingPathExtension().lastPathComponent.hasSuffix(" (2)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testMissingCloudParentAndInvalidDirectoryFailWithoutCreatingFakeCloudDrive() async throws {
        let parent = try folder()
        let missing = parent.appendingPathComponent("Missing CloudDocs/LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: missing)
        do {
            _ = try await store.write(project: makeProject(), projectID: UUID(), title: "Case", sequence: 1)
            XCTFail("A missing cloud parent must not be created as an ordinary local directory")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        let invalidRoot = parent.appendingPathComponent("LAD")
        let original = Data("existing user file".utf8)
        try original.write(to: invalidRoot)
        let invalidStore = ProjectAutosaveStore(rootDirectory: invalidRoot)
        do {
            _ = try await invalidStore.write(project: makeProject(), projectID: UUID(), title: "Case", sequence: 1)
            XCTFail("A regular file must not become the project directory")
        } catch { XCTAssertTrue(error.localizedDescription.contains("directory")) }
        XCTAssertEqual(try Data(contentsOf: invalidRoot), original)
    }

    func testExternalChangesToSameProjectAreNotSilentlyOverwritten() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        let initial = makeProject()
        let url = try await store.write(project: initial, projectID: id, title: "Case", sequence: 1)
        var remote = try ProjectStore.read(from: url)
        remote.messages.append(ChatMessage(role: "user", content: "A change from another Mac"))
        try ProjectStore.write(remote, to: url)
        let remoteBytes = try ProjectStore.readArchive(from: url)
        do {
            _ = try await store.write(project: initial, projectID: id, title: "Case", sequence: 2)
            XCTFail("An unmerged remote edit must not be overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed outside LAD")) }
        XCTAssertEqual(try ProjectStore.readArchive(from: url), remoteBytes)
    }

    func testRestoreFindsRenamedProjectByIdentityAndDoesNotSelectAnotherProject() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        let original = try await store.write(project: makeProject(), projectID: id, title: "Case", sequence: 1)
        let moved = root.appendingPathComponent("Renamed elsewhere.lad")
        try FileManager.default.moveItem(at: original, to: moved)
        _ = try await store.write(project: makeProject(), projectID: UUID(), title: "Other design", sequence: 2)
        let reopened = ProjectAutosaveStore(rootDirectory: root)
        let restored = try await reopened.restoreRecent(preferredURL: original, projectID: id)
        XCTAssertEqual(restored.map { ProjectFileOrigin.canonicalURL($0.url) }, ProjectFileOrigin.canonicalURL(moved))
        XCTAssertEqual(restored?.project.projectID, id)
        do {
            _ = try await reopened.restoreRecent(preferredURL: nil, projectID: UUID())
            XCTFail("A missing identity must not silently restore another project")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be found")) }
    }

    func testNewestCloudProjectCanBeRestoredWithoutLocalMetadata() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let older = try await store.write(project: makeProject(), projectID: UUID(), title: "Older", sequence: 1)
        let latestID = UUID()
        let latest = try await store.write(project: makeProject(), projectID: latestID, title: "Latest", sequence: 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: older.path)
        let fresh = ProjectAutosaveStore(rootDirectory: root)
        let restored = try await fresh.restoreRecent(preferredURL: nil, projectID: nil)
        XCTAssertEqual(restored.map { ProjectFileOrigin.canonicalURL($0.url) }, ProjectFileOrigin.canonicalURL(latest))
        XCTAssertEqual(restored?.project.projectID, latestID)
        XCTAssertEqual(try ProjectAutosaveStore.readProject(from: latest).projectID, latestID)
    }

    func testExplicitCopyUsesSameWriterAndLeavesAutosaveAbleToContinue() async throws {
        let parent = try folder()
        let store = ProjectAutosaveStore(rootDirectory: parent.appendingPathComponent("LAD", isDirectory: true))
        let id = UUID()
        let url = try await store.write(project: makeProject(), projectID: id, title: "Case", sequence: 1)
        var project = try ProjectStore.read(from: url)
        project.messages.append(ChatMessage(role: "user", content: "Add a cable opening"))
        try await store.writeCopy(project, to: url)
        let saved = try await store.write(project: project, projectID: id, title: "Case", sequence: 2, preferredURL: url)
        XCTAssertEqual(saved, url)
        let copy = parent.appendingPathComponent("Portable copy.lad")
        try await store.writeCopy(project, to: copy)
        XCTAssertEqual(copy.pathExtension, "lad")
        XCTAssertEqual(try copy.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        XCTAssertEqual(try ProjectStore.read(from: copy).messages, project.messages)
        XCTAssertEqual(try ProjectStore.read(from: url).messages, project.messages)
    }

    func testUserRenamePreservesExactFilenameAndCompleteProjectAcrossLaterGeneratedTitles() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        var project = makeProject()
        project.codexSettings = CodexProjectSettings(model: "design-model", reasoningEffort: "ultra", reasoningByModel: ["design-model": "ultra"])
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [PartNode(id: "shell", name: "Shell", solidIndices: [0])])]
        project.revisions[0].parts = parts
        project.revisions[0].partLayout = PartLayout(nodes: parts, collapsedNodeIDs: ["case"])
        project.revisions[0].hiddenSolids = [0]
        let original = try await store.write(project: project, projectID: id, title: "Generated title", sequence: 1)
        project.projectName = try ProjectNaming.userName("PCB case — v2.1 [USB-C].lad")
        let renamed = try await store.write(project: project, projectID: id, title: "Generated title", sequence: 2, preferredURL: original)
        XCTAssertEqual(renamed.lastPathComponent, "PCB case — v2.1 [USB-C].lad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let reopened = try ProjectStore.read(from: renamed)
        XCTAssertEqual(reopened.projectID, id)
        XCTAssertEqual(reopened.projectName, project.projectName)
        XCTAssertEqual(reopened.messages, project.messages)
        XCTAssertEqual(reopened.revisions.map(\.id), project.revisions.map(\.id))
        XCTAssertEqual(reopened.revisions.map(\.model), project.revisions.map(\.model))
        XCTAssertEqual(reopened.revisions.map(\.partLayout), project.revisions.map(\.partLayout))
        XCTAssertEqual(reopened.revisions.map(\.hiddenSolids), project.revisions.map(\.hiddenSolids))
        XCTAssertEqual(reopened.codexSettings, project.codexSettings)
        XCTAssertEqual(try renamed.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)

        let freshStore = ProjectAutosaveStore(rootDirectory: root)
        let restored = try await freshStore.restoreRecent(preferredURL: original, projectID: id)
        XCTAssertEqual(restored.map { ProjectFileOrigin.canonicalURL($0.url) }, ProjectFileOrigin.canonicalURL(renamed))
        var refined = try XCTUnwrap(restored?.project)
        var newModel = ModelSpec.bracket
        newModel.title = "A later Codex design title"
        let newRevision = ProjectRevision(model: newModel)
        refined.revisions.append(newRevision)
        refined.selectedRevisionID = newRevision.id
        let next = try await freshStore.write(project: refined, projectID: id, title: newModel.title, sequence: 3, preferredURL: renamed)
        XCTAssertEqual(ProjectFileOrigin.canonicalURL(next), ProjectFileOrigin.canonicalURL(renamed), "A later generated title must not undo a manual project name")
        XCTAssertEqual(try ProjectStore.read(from: next).revisions.count, 2)
    }

    func testUserRenameCollisionKeepsOtherProjectAndStableSuffix() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        var first = makeProject()
        first.projectName = "Case v2.1"
        let firstURL = try await store.write(project: first, projectID: UUID(), title: "ignored", sequence: 1)
        let firstBytes = try ProjectStore.readArchive(from: firstURL)
        let id = UUID()
        var second = makeProject()
        let old = try await store.write(project: second, projectID: id, title: "Other project", sequence: 1)
        second.projectName = first.projectName
        let renamed = try await store.write(project: second, projectID: id, title: "ignored", sequence: 2, preferredURL: old)
        XCTAssertEqual(renamed.lastPathComponent, "Case v2.1 (2).lad")
        XCTAssertEqual(try ProjectStore.readArchive(from: firstURL), firstBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        try FileManager.default.removeItem(at: firstURL)
        let next = try await store.write(project: second, projectID: id, title: "ignored", sequence: 3, preferredURL: renamed)
        XCTAssertEqual(next, renamed, "Removing another project must not change this file's collision suffix")
    }

    func testUserCanChangeOnlyFilenameCaseWithoutCreatingDuplicateProject() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        var project = makeProject()
        project.projectName = "Enclosure"
        let original = try await store.write(project: project, projectID: id, title: "ignored", sequence: 1)
        project.projectName = "ENCLOSURE"
        let renamed = try await store.write(project: project, projectID: id, title: "ignored", sequence: 2, preferredURL: original)
        XCTAssertEqual(renamed.lastPathComponent, "ENCLOSURE.lad")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["ENCLOSURE.lad"])
        XCTAssertEqual(try ProjectStore.read(from: renamed).projectName, "ENCLOSURE")
        XCTAssertEqual(try ProjectStore.read(from: renamed).projectID, id)
        XCTAssertEqual(try ProjectStore.read(from: renamed).messages, project.messages)
    }

    func testCaseOnlyRenameRetainsAnExistingCollisionSuffix() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let first = try await store.write(project: makeProject(), projectID: UUID(), title: "Case", sequence: 1)
        let id = UUID()
        var project = makeProject()
        let original = try await store.write(project: project, projectID: id, title: "Case", sequence: 1)
        XCTAssertEqual(original.lastPathComponent, "Case (2).lad")
        try FileManager.default.removeItem(at: first)
        project.projectName = "case"
        let renamed = try await store.write(project: project, projectID: id, title: "ignored", sequence: 2, preferredURL: original)
        XCTAssertEqual(renamed.lastPathComponent, "case (2).lad")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["case (2).lad"])
    }

    func testStaleAutosaveDoesNotUndoExplicitRenameOrRestoreOldFilename() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        let older = makeProject()
        let original = try await store.write(project: older, projectID: id, title: "Automatic name", sequence: 1)
        var renamedProject = older
        renamedProject.projectName = "Chosen name"
        let renamed = try await store.write(project: renamedProject, projectID: id, title: "ignored", sequence: 3, preferredURL: original)
        let renamedBytes = try ProjectStore.readArchive(from: renamed)
        let stale = try await store.write(project: older, projectID: id, title: "Automatic name", sequence: 2, preferredURL: original)
        XCTAssertEqual(stale, renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try ProjectStore.readArchive(from: renamed), renamedBytes)
    }

    func testExplicitRenameCanReclaimFreeBaseWhileOrdinaryAutosaveRetainsSuffix() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let occupied = try await store.write(project: makeProject(), projectID: UUID(), title: "Case", sequence: 1)
        let occupiedBytes = try ProjectStore.readArchive(from: occupied)
        let id = UUID()
        var project = makeProject()
        project.projectName = "Case"
        let suffixed = try await store.write(project: project, projectID: id, title: "ignored", sequence: 1)
        XCTAssertEqual(suffixed.lastPathComponent, "Case (2).lad")
        let blocked = try await store.write(project: project, projectID: id, title: "ignored", sequence: 2,
                                            preferredURL: suffixed, preferExactName: true)
        XCTAssertEqual(blocked, suffixed)
        XCTAssertEqual(try ProjectStore.readArchive(from: occupied), occupiedBytes, "Explicit rename must not overwrite an occupied exact name")

        try FileManager.default.removeItem(at: occupied)
        let autosaved = try await store.write(project: project, projectID: id, title: "ignored", sequence: 3, preferredURL: suffixed)
        XCTAssertEqual(autosaved, suffixed)
        let renamed = try await store.write(project: project, projectID: id, title: "ignored", sequence: 4,
                                            preferredURL: suffixed, preferExactName: true)
        XCTAssertEqual(renamed.lastPathComponent, "Case.lad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: suffixed.path))
        XCTAssertEqual(try ProjectStore.read(from: renamed).projectID, id)
        XCTAssertEqual(try ProjectStore.read(from: renamed).projectName, "Case")
        XCTAssertEqual(try ProjectStore.read(from: renamed).messages, project.messages)
    }

    func testUnpublishedPackageFilesDoNotChangeTheAutosaveBaseline() async throws {
        let root = try folder().appendingPathComponent("LAD", isDirectory: true)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let id = UUID()
        var project = makeProject()
        let url = try await store.write(project: project, projectID: id, title: "Case", sequence: 1)
        let manifest = try ProjectStore.readArchive(from: url)
        // A failed preparation can leave files without publishing a new root.
        // That must not masquerade as another writer's committed design.
        try Data("uncommitted".utf8).write(to: url.appendingPathComponent("unpublished.tmp"))
        XCTAssertEqual(try ProjectStore.readArchive(from: url), manifest)
        project.draftPrompt = "A local edit after an unpublished file appeared"

        let saved = try await store.write(project: project, projectID: id, title: "Case", sequence: 2)
        XCTAssertEqual(saved, url)
        XCTAssertEqual(try ProjectStore.read(from: url).draftPrompt, project.draftPrompt)
    }

    func testExplicitCopyReplacesADifferentPackageAsOneCompleteDesign() async throws {
        let root = try folder()
        let store = ProjectAutosaveStore(rootDirectory: root)
        var first = makeProject()
        first.projectID = UUID()
        first.draftPrompt = "Old destination state"
        let destination = root.appendingPathComponent("Copy.lad")
        try ProjectStore.write(first, to: destination)
        var replacement = makeProject()
        replacement.projectID = UUID()
        replacement.messages.append(ChatMessage(role: "user", content: "Replacement history"))

        let origin = try await store.writeCopy(replacement, to: destination)
        let restored = try ProjectStore.read(from: destination)
        XCTAssertEqual(restored.projectID, replacement.projectID)
        XCTAssertEqual(restored.messages, replacement.messages)
        XCTAssertNil(restored.draftPrompt)
        XCTAssertEqual(origin.sha256, ProjectFileOrigin(url: destination, data: try ProjectStore.readArchive(from: destination)).sha256)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Copy.lad"])
    }

    func testDeletedManifestCannotBeSilentlyRecreatedByAnExistingWriter() async throws {
        let root = try folder()
        let store = ProjectAutosaveStore(rootDirectory: root)
        let project = makeProject(), id = UUID()
        let url = try await store.write(project: project, projectID: id, title: "Case", sequence: 1)
        try FileManager.default.removeItem(at: url.appendingPathComponent("project.json"))

        do {
            _ = try await store.write(project: project, projectID: id, title: "Case", sequence: 2)
            XCTFail("A missing authoritative manifest must require reopening or an explicit copy")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed outside LAD")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path))
    }

    func testPackageDirectoryURLsKeepOneStableDocumentIdentity() async throws {
        let root = try folder()
        let id = UUID()
        let store = ProjectAutosaveStore(rootDirectory: root)
        let url = try await store.write(project: makeProject(), projectID: id, title: "Case", sequence: 1)
        XCTAssertFalse(url.hasDirectoryPath)
        let directoryForm = URL(fileURLWithPath: url.path, isDirectory: true)
        XCTAssertTrue(directoryForm.hasDirectoryPath)
        var loaded = try ProjectAutosaveStore.readProject(from: directoryForm)
        XCTAssertFalse(try XCTUnwrap(loaded.fileOrigin).url.hasDirectoryPath)
        XCTAssertTrue(try XCTUnwrap(loaded.fileOrigin).matches(url))
        XCTAssertTrue(try XCTUnwrap(loaded.fileOrigin).matches(directoryForm))
        loaded.draftPrompt = "Opened through a directory URL"

        let saved = try await store.write(project: loaded, projectID: id, title: "Case", sequence: 2,
                                          preferredURL: directoryForm)
        XCTAssertEqual(saved, url)
        XCTAssertFalse(saved.hasDirectoryPath)
        let reopened = ProjectAutosaveStore(rootDirectory: root)
        let restored = try await reopened.restoreRecent(preferredURL: directoryForm, projectID: id)
        XCTAssertEqual(restored?.url, url)
        let discovered = try await ProjectAutosaveStore(rootDirectory: root).restoreRecent(preferredURL: nil, projectID: id)
        XCTAssertEqual(discovered?.url, url)
    }
}
