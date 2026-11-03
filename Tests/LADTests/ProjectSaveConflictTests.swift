import Foundation
import XCTest
@testable import LAD

final class ProjectSaveConflictTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-save-conflict-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func project() -> LADProject {
        let parts = [PartNode(id: "assembly", name: "Assembly", solidIndices: [], children: [
            PartNode(id: "body", name: "Body", solidIndices: [0])])]
        let revision = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: parts), parts: parts)
        return LADProject(messages: [ChatMessage(role: "user", content: "Make a bracket")],
                          revisions: [revision], selectedRevisionID: revision.id, projectID: UUID(), projectName: "Case")
    }

    private enum ExpectedConflict: Error { case missing }

    private func conflict(file: StaticString = #filePath, line: UInt = #line,
                          _ write: () async throws -> URL) async throws -> ProjectSaveConflict {
        do { _ = try await write() }
        catch let conflict as ProjectSaveConflict { return conflict }
        XCTFail("A changed package must require an explicit conflict decision", file: file, line: line)
        throw ExpectedConflict.missing
    }

    func testExternalMetadataEditsAreDetectedWithoutChangingRemoteBytes() async throws {
        let changes: [(String, (inout LADProject) throws -> Void)] = [
            ("queued requests", { $0.queuedRequests = [ProjectQueuedRequest(content: "Make the wall taller")] }),
            ("draft", { $0.draftPrompt = "An unsent request from another Mac" }),
            ("version name", { $0.revisions[0].name = "Reviewed on another Mac" }),
            ("part colors", { $0.revisions[0].partColors = ["body": PartColor(red: 0.2, green: 0.6, blue: 0.8)] }),
            ("part layout", { try $0.revisions[0].partLayout?.rename("body", to: "Renamed remotely") }),
            ("folder expansion", { try $0.revisions[0].partLayout?.setExpanded(false, for: "assembly") }),
            ("part visibility", { $0.revisions[0].hiddenSolids = [0] }),
            ("design name", { $0.projectName = "Remote name" }),
            ("projection", { $0.projectionMode = .isometric }),
            ("rendering", { $0.displayMode = .translucent }),
            ("grid", { $0.showGrid = false }),
            ("sidebar split", { $0.partsPaneFraction = 0.5 }),
            ("model settings", { $0.codexSettings = CodexProjectSettings(model: "remote-model", reasoningEffort: "high") })
        ]
        for (name, change) in changes {
            let root = try folder()
            let store = ProjectAutosaveStore(rootDirectory: root)
            let local = project(), id = try XCTUnwrap(local.projectID)
            let url = try await store.write(project: local, projectID: id, title: "Case", sequence: 1)
            var remote = try ProjectStore.read(from: url)
            try change(&remote)
            try ProjectStore.write(remote, to: url)
            let remoteBytes = try ProjectStore.readArchive(from: url)

            let detected = try await conflict {
                try await store.write(project: local, projectID: id, title: "Case", sequence: 2)
            }
            XCTAssertTrue(detected.file.matches(url), name)
            XCTAssertEqual(detected.file.sha256, ProjectFileOrigin(url: url, data: remoteBytes).sha256, name)
            XCTAssertEqual(try ProjectStore.readArchive(from: url), remoteBytes, name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Case.lad"], name)
        }
    }

    func testLocalMetadataEditsAndRepeatedAutosavesUseTheLastSuccessfulBaseline() async throws {
        let root = try folder()
        let store = ProjectAutosaveStore(rootDirectory: root)
        let original = project(), id = try XCTUnwrap(original.projectID)
        let firstURL = try await store.write(project: original, projectID: id, title: "Case", sequence: 1)
        var local = try ProjectAutosaveStore.readProject(from: firstURL)
        local.draftPrompt = "Locally edited draft"
        local.queuedRequests = [ProjectQueuedRequest(content: "Locally queued request")]
        local.revisions[0].name = "Locally named version"
        local.revisions[0].partColors = ["body": PartColor(red: 0.7, green: 0.3, blue: 0.2)]
        try local.revisions[0].partLayout?.rename("body", to: "Local body name")
        local.showGrid = false
        local.projectionMode = .isometric
        let secondURL = try await store.write(project: local, projectID: id, title: "Case", sequence: 2, preferredURL: firstURL)
        XCTAssertEqual(secondURL, firstURL)

        local.projectName = "Chosen locally"
        let renamedURL = try await store.write(project: local, projectID: id, title: "Case", sequence: 3, preferredURL: secondURL, preferExactName: true)
        XCTAssertEqual(renamedURL.lastPathComponent, "Chosen locally.lad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        local.draftPrompt = "Another local change after the filename changed"
        let finalURL = try await store.write(project: local, projectID: id, title: "Case", sequence: 4, preferredURL: renamedURL)
        XCTAssertEqual(finalURL, renamedURL)
        XCTAssertEqual(try ProjectArchive.encode(ProjectStore.read(from: finalURL)), try ProjectArchive.encode(local))
    }

    func testStaticReadBaselineProtectsTheFirstSaveFromAnInterveningRemoteEdit() async throws {
        let root = try folder(), original = project()
        let id = try XCTUnwrap(original.projectID)
        let url = root.appendingPathComponent("Case.lad")
        try ProjectStore.write(original, to: url)
        var local = try ProjectAutosaveStore.readProject(from: url)
        XCTAssertNotNil(local.fileOrigin)
        local.draftPrompt = "A local change made after opening"
        var remote = original
        remote.queuedRequests = [ProjectQueuedRequest(content: "Remote request after our opening read")]
        try ProjectStore.write(remote, to: url)
        let remoteBytes = try ProjectStore.readArchive(from: url)
        let store = ProjectAutosaveStore(rootDirectory: root)

        _ = try await conflict {
            try await store.write(project: local, projectID: id, title: "Case", sequence: 1, preferredURL: url)
        }
        XCTAssertEqual(try ProjectStore.readArchive(from: url), remoteBytes)
    }

    func testRewritingUnchangedManifestBytesDoesNotCauseAConflict() async throws {
        let root = try folder(), original = project()
        let id = try XCTUnwrap(original.projectID)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let url = try await store.write(project: original, projectID: id, title: "Case", sequence: 1)
        let bytes = try ProjectStore.readArchive(from: url)
        try bytes.write(to: url.appendingPathComponent("project.json"), options: .atomic)
        var local = original
        local.draftPrompt = "Still safe to save after an unchanged-byte rewrite"

        let saved = try await store.write(project: local, projectID: id, title: "Case", sequence: 2, preferredURL: url)
        XCTAssertEqual(saved, url)
        XCTAssertEqual(try ProjectStore.read(from: saved).draftPrompt, local.draftPrompt)
    }

    func testExplicitOverwriteReplacesOnlyTheObservedConflictAndAllowsLaterAutosaves() async throws {
        let root = try folder(), original = project()
        let id = try XCTUnwrap(original.projectID)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let url = try await store.write(project: original, projectID: id, title: "Case", sequence: 1)
        var remote = original
        remote.draftPrompt = "Remote draft"
        try ProjectStore.write(remote, to: url)
        var local = original
        local.draftPrompt = "Keep this local draft after choosing Overwrite"
        let detected = try await conflict {
            try await store.write(project: local, projectID: id, title: "Case", sequence: 2, preferredURL: url)
        }

        let overwritten = try await store.write(project: local, projectID: id, title: "Case", sequence: 3,
                                                preferredURL: url, resolving: detected)
        XCTAssertEqual(overwritten, url)
        XCTAssertEqual(try ProjectArchive.encode(ProjectStore.read(from: url)), try ProjectArchive.encode(local))
        local.draftPrompt = "A later ordinary autosave"
        _ = try await store.write(project: local, projectID: id, title: "Case", sequence: 4, preferredURL: url)
        XCTAssertEqual(try ProjectStore.read(from: url).draftPrompt, local.draftPrompt)
    }

    func testASecondExternalEditInvalidatesTheExplicitOverwriteToken() async throws {
        let root = try folder(), original = project()
        let id = try XCTUnwrap(original.projectID)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let url = try await store.write(project: original, projectID: id, title: "Case", sequence: 1)
        var remote = original
        remote.draftPrompt = "First remote edit"
        try ProjectStore.write(remote, to: url)
        let first = try await conflict {
            try await store.write(project: original, projectID: id, title: "Case", sequence: 2, preferredURL: url)
        }
        remote.draftPrompt = "Second remote edit while the overwrite decision was pending"
        remote.queuedRequests = [ProjectQueuedRequest(content: "Another remote request")]
        try ProjectStore.write(remote, to: url)
        let latestBytes = try ProjectStore.readArchive(from: url)

        let second = try await conflict {
            try await store.write(project: original, projectID: id, title: "Case", sequence: 3,
                                  preferredURL: url, resolving: first)
        }
        XCTAssertNotEqual(second.file.sha256, first.file.sha256)
        XCTAssertEqual(second.file.sha256, ProjectFileOrigin(url: url, data: latestBytes).sha256)
        XCTAssertEqual(try ProjectStore.readArchive(from: url), latestBytes)
        _ = try await store.write(project: original, projectID: id, title: "Case", sequence: 4,
                                  preferredURL: url, resolving: second)
        XCTAssertEqual(try ProjectArchive.encode(ProjectStore.read(from: url)), try ProjectArchive.encode(original))
    }

    func testReopeningUsesTheNewReadBaselineAndRejectsAnOlderAutosave() async throws {
        let root = try folder(), original = project()
        let id = try XCTUnwrap(original.projectID)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let url = try await store.write(project: original, projectID: id, title: "Case", sequence: 1)
        var firstSession = try ProjectAutosaveStore.readProject(from: url)
        firstSession.draftPrompt = "Saved before reopening"
        _ = try await store.write(project: firstSession, projectID: id, title: "Case", sequence: 2, preferredURL: url)
        var remote = try ProjectStore.read(from: url)
        remote.queuedRequests = [ProjectQueuedRequest(content: "Remote request to retain after reopening")]
        try ProjectStore.write(remote, to: url)
        var reopened = try ProjectAutosaveStore.readProject(from: url)
        XCTAssertNotEqual(reopened.fileOrigin?.readID, firstSession.fileOrigin?.readID)
        reopened.draftPrompt = "A local change based on the reopened file"

        _ = try await store.write(project: reopened, projectID: id, title: "Case", sequence: 3, preferredURL: url)
        reopened.revisions[0].name = "A second edit after reopening"
        _ = try await store.write(project: reopened, projectID: id, title: "Case", sequence: 4, preferredURL: url)
        let latestBytes = try ProjectStore.readArchive(from: url)
        _ = try await store.write(project: firstSession, projectID: id, title: "Old name", sequence: 2, preferredURL: url)
        XCTAssertEqual(try ProjectStore.readArchive(from: url), latestBytes)
        XCTAssertEqual(try ProjectStore.read(from: url).queuedRequests, remote.queuedRequests)
        XCTAssertEqual(try ProjectStore.read(from: url).revisions[0].name, reopened.revisions[0].name)
    }

    func testOpeningAnotherCopyWithTheSameIdentitySavesOnlyThatFile() async throws {
        let root = try folder(), original = project()
        let id = try XCTUnwrap(original.projectID)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let originalURL = try await store.write(project: original, projectID: id, title: "Case", sequence: 1)
        let originalBytes = try ProjectStore.readArchive(from: originalURL)
        var copy = original
        copy.projectName = "Portable copy"
        let copyURL = root.appendingPathComponent("Portable copy.lad")
        let copiedOrigin = try await store.writeCopy(copy, to: copyURL)
        XCTAssertTrue(copiedOrigin.matches(copyURL))
        XCTAssertEqual(copiedOrigin.sha256, ProjectFileOrigin(url: copyURL, data: try ProjectStore.readArchive(from: copyURL)).sha256)
        var reopened = try ProjectAutosaveStore.readProject(from: copyURL)
        reopened.draftPrompt = "Edit only the newly opened copy"

        let saved = try await store.write(project: reopened, projectID: id, title: "Portable copy", sequence: 2, preferredURL: copyURL)
        XCTAssertEqual(saved, copyURL)
        XCTAssertEqual(try ProjectStore.readArchive(from: originalURL), originalBytes)
        XCTAssertEqual(try ProjectStore.read(from: copyURL).draftPrompt, reopened.draftPrompt)
    }

    func testExplicitCopyToTheCurrentFileUpdatesItsBaseline() async throws {
        let root = try folder(), original = project()
        let id = try XCTUnwrap(original.projectID)
        let store = ProjectAutosaveStore(rootDirectory: root)
        let url = try await store.write(project: original, projectID: id, title: "Case", sequence: 1)
        var local = original
        local.draftPrompt = "Explicitly saved local edits"
        let origin = try await store.writeCopy(local, to: url)
        XCTAssertTrue(origin.matches(url))
        local.fileOrigin = origin
        local.draftPrompt = "An ordinary edit after the explicit save"

        _ = try await store.write(project: local, projectID: id, title: "Case", sequence: 2, preferredURL: url)
        XCTAssertEqual(try ProjectStore.read(from: url).draftPrompt, local.draftPrompt)
    }

    func testFileOriginsStayOutOfPortableArchivesAndRuntimeJSON() throws {
        let root = try folder(), original = project()
        let url = root.appendingPathComponent("Case.lad")
        try ProjectStore.write(original, to: url)
        let loaded = try ProjectAutosaveStore.readProject(from: url)
        XCTAssertNotNil(loaded.fileOrigin)
        XCTAssertNil(try ProjectStore.decode(ProjectStore.encode(loaded)).fileOrigin)
        let json = try JSONEncoder().encode(loaded)
        XCTAssertNil(try JSONDecoder().decode(LADProject.self, from: json).fileOrigin)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNil(fields["fileOrigin"])
    }
}
