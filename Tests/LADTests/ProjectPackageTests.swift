import AppKit
import CryptoKit
import XCTest
@testable import LAD

final class ProjectPackageTests: XCTestCase {
    private func temporaryPackage() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-package-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent); ProjectPackage.clearSessionCache() }
        return parent.appendingPathComponent("Design.lad", isDirectory: true)
    }

    private func project() -> LADProject {
        let message = ChatMessage(role: "user", content: "Create a bracket")
        let revision = ProjectRevision(model: .bracket, parts: [PartNode(id: "body", name: "Body", solidIndices: [0])])
        return LADProject(messages: [message], revisions: [revision], selectedRevisionID: revision.id, projectID: UUID())
    }

    private func root(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectStore.readArchive(from: url)) as? [String: Any])
    }

    private func reference(_ root: [String: Any], _ field: String) throws -> [String: Any] {
        try XCTUnwrap(root[field] as? [String: Any])
    }

    private func snapshot(_ url: URL) throws -> [String: Data] {
        let resolved = url.resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey]))
        var result = [String: Data]()
        for case let file as URL in enumerator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            result[String(file.resolvingSymlinksInPath().path.dropFirst(resolved.path.count + 1))] = try Data(contentsOf: file)
        }
        return result
    }

    private func thumbnailPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testPackageRoundtripStoresOnlyRecipesAndExactSharedInputs() throws {
        let url = try temporaryPackage()
        var value = project()
        let bytes = Data("ISO-10303-21;\n\(String(repeating: " ", count: 20_000))\nEND-ISO-10303-21;\n".utf8)
        value.revisions[0].model.sourceSTEP = bytes
        value.revisions.append(ProjectRevision(model: value.revisions[0].model, parts: value.revisions[0].parts))
        let text = String(decoding: bytes, as: UTF8.self)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        value.messages[0].attachments = [SourceAttachment(name: "board.step", path: "/missing/board.step", content: text, sha256: hash)]
        try ProjectStore.write(value, to: url)
        let json = try root(url)
        XCTAssertEqual(json["formatVersion"] as? Int, 5)
        XCTAssertNil(json["messages"])
        XCTAssertNil(json["taskAudits"])
        XCTAssertNil(json["state"])
        let assets = try XCTUnwrap(json["assets"] as? [String: [String: Any]])
        XCTAssertEqual(assets.count, 2, "The original input is shared by attachments and revisions")
        XCTAssertEqual(assets[hash]?["codec"] as? String, "zlib")
        XCTAssertLessThan(try XCTUnwrap(assets[hash]?["storedByteCount"] as? Int), bytes.count / 10)
        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: url)
        XCTAssertEqual(restored.messages, value.messages)
        XCTAssertEqual(restored.revisions.map(\.model), value.revisions.map(\.model))
        XCTAssertTrue(restored.revisions.allSatisfy { $0.preview == nil && $0.stepData == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("recovery").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("cache").path))
    }

    func testRootOnlyChangeLeavesEveryDependencyUntouched() throws {
        let url = try temporaryPackage()
        var value = project()
        try ProjectStore.write(value, to: url)
        let first = try snapshot(url)
        let before = try root(url)
        value.showGrid = false
        value.partsPaneFraction = 0.62
        try ProjectStore.write(value, to: url)
        let second = try snapshot(url)
        XCTAssertEqual(Set(first.keys), Set(second.keys))
        XCTAssertNotEqual(first["project.json"], second["project.json"])
        for path in first.keys where path != "project.json" { XCTAssertEqual(first[path], second[path], path) }
        XCTAssertEqual(try reference(before, "revisions")["path"] as? String,
                       try reference(root(url), "revisions")["path"] as? String)
        XCTAssertFalse(try ProjectStore.read(from: url).showGrid ?? true)
        let unchanged = try ProjectStore.readArchive(from: url)
        try ProjectStore.write(value, to: url)
        XCTAssertEqual(unchanged, try ProjectStore.readArchive(from: url), "A no-op save does not create another commit")
    }

    func testStateEditsSkipHistorySerializationAndRemainCurrentForTheNextHistoryEdit() throws {
        let url = try temporaryPackage()
        var value = project()
        let bytes = Data("# Exact shared source\n".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attachment = SourceAttachment(name: "source.py", path: "/missing/source.py", content: String(decoding: bytes, as: UTF8.self), sha256: hash)
        value.messages[0].attachments = [attachment]
        value.draftAttachments = [attachment]
        value.queuedRequests = [ProjectQueuedRequest(content: "Refine the bracket", attachments: [attachment])]
        value.taskAudits = [ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events: [
            ProjectActivityEvent(id: "event-1", category: "tool", title: "Inspect", status: "completed", output: "Original output")
        ])]
        try ProjectStore.write(value, to: url)
        let files = try snapshot(url)
        let dependencyAttributes = try Dictionary(uniqueKeysWithValues: files.keys.filter { $0 != "project.json" }.map { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)
            return (path, (inode: attributes[.systemFileNumber] as? NSNumber, modified: attributes[.modificationDate] as? Date))
        })

        value.showGrid = false
        value.partsPaneFraction = 0.61
        value.projectName = "Shared source bracket"
        value.codexSettings = CodexProjectSettings(model: "test-model", reasoningEffort: "high", reasoningByModel: ["test-model": "high"])
        value.displayMode = .shaded
        value.projectionMode = .isometric
        value.draftPrompt = "Continue after the queued refinements"
        value.queuePaused = true
        value.queuedRequests![0].content = "Refine the same bracket again"
        value.queuedRequests!.append(ProjectQueuedRequest(content: "An attachment-free follow-up", attachments: []))
        value.queuedRequests!.reverse()
        var metrics = ProjectPackage.WriteMetrics()
        let committed = try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.historySnapshots, 0)
        XCTAssertEqual(metrics.rootEncodings, 1)
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
        let after = try snapshot(url)
        XCTAssertEqual(Set(files.keys), Set(after.keys))
        for path in dependencyAttributes.keys {
            XCTAssertEqual(files[path], after[path], path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)
            XCTAssertEqual(dependencyAttributes[path]?.inode, attributes[.systemFileNumber] as? NSNumber, path)
            XCTAssertEqual(dependencyAttributes[path]?.modified, attributes[.modificationDate] as? Date, path)
        }

        let noOp = try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(noOp, committed)
        XCTAssertEqual(metrics.historySnapshots, 0)
        XCTAssertEqual(metrics.rootEncodings, 0)

        value.messages.append(ChatMessage(role: "assistant", content: "Refined"))
        value.revisions[0].name = "Refined bracket"
        value.taskAudits![0].events[0].output = "Updated output"
        try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.historySnapshots, 1)
        XCTAssertEqual(metrics.rootEncodings, 1)
        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: url)
        let expected = try ProjectArchive.split(value), actual = try ProjectArchive.split(restored)
        XCTAssertEqual(actual.metadata, expected.metadata)
        XCTAssertEqual(actual.assets, expected.assets)
    }

    func testStateOnlySaveStillValidatesInlineFields() throws {
        let url = try temporaryPackage()
        var value = project()
        try ProjectStore.write(value, to: url)
        let committed = try ProjectStore.readArchive(from: url)
        value.partsPaneFraction = .nan
        XCTAssertThrowsError(try ProjectStore.write(value, to: url))
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
        value.partsPaneFraction = 0.75
        value.queuedRequests = [ProjectQueuedRequest(content: "")]
        XCTAssertThrowsError(try ProjectStore.write(value, to: url))
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
    }

    func testIndexesAlternateAndSupersededRecordsAreRemovedAfterPublication() throws {
        let url = try temporaryPackage()
        var value = project()
        try ProjectStore.write(value, to: url)
        XCTAssertEqual(try reference(root(url), "revisions")["path"] as? String, "revisions/index-1.json")
        let before = try snapshot(url)
        value.revisions[0].partColors = ["body": PartColor(red: 1, green: 0, blue: 0)]
        try ProjectStore.write(value, to: url)
        XCTAssertEqual(try reference(root(url), "revisions")["path"] as? String, "revisions/index-2.json")
        let removed = Set(before.keys).subtracting(try snapshot(url).keys)
        XCTAssertEqual(removed.filter { $0.contains("/parts-") }.count, 1)
        value.revisions[0].name = "Named version"
        try ProjectStore.write(value, to: url)
        XCTAssertEqual(try reference(root(url), "revisions")["path"] as? String, "revisions/index-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("revisions/index-2.json").path))
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).revisions[0].name, "Named version")
    }

    func testInterruptedSaveKeepsCommittedRootAndDependenciesReadable() throws {
        struct Interrupted: Error {}
        let url = try temporaryPackage()
        var value = project()
        try ProjectStore.write(value, to: url)
        let committed = try ProjectStore.readArchive(from: url)
        value.revisions[0].model.script += "\n# New candidate\n"
        value.messages.append(ChatMessage(role: "assistant", content: "Updated candidate", phase: "commentary"))
        XCTAssertThrowsError(try ProjectPackage.write(value, to: url, beforePublication: { throw Interrupted() }))
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).messages.count, 1)
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).messages.count, 2)
        XCTAssertEqual(try ProjectStore.read(from: url).revisions[0].model.script, value.revisions[0].model.script)
    }

    func testDamagedUncommittedHashFileIsNotAdopted() throws {
        struct Interrupted: Error {}
        let url = try temporaryPackage()
        var value = project()
        try ProjectStore.write(value, to: url)
        let committed = try ProjectStore.readArchive(from: url)
        let oldFiles = Set(try snapshot(url).keys)
        value.revisions[0].model.script += "\n# New candidate\n"
        XCTAssertThrowsError(try ProjectPackage.write(value, to: url, beforePublication: { throw Interrupted() }))
        let newFiles = Set(try snapshot(url).keys).subtracting(oldFiles)
        let orphan = try XCTUnwrap(newFiles.first { $0.contains("recipe-") })
        try Data("damaged".utf8).write(to: url.appendingPathComponent(orphan))
        XCTAssertThrowsError(try ProjectStore.write(value, to: url))
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
    }

    func testActivityUpdatesRetainEventsAndChunkLargeHistories() throws {
        let url = try temporaryPackage()
        var value = project()
        let events = (0..<260).map { index in
            ProjectActivityEvent(id: "event-\(index)", category: "tool", title: "Inspect \(index)", status: "completed", input: "input-\(index)", output: "output-\(index)")
        }
        value.taskAudits = [ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events: events)]
        try ProjectStore.write(value, to: url)
        let files = try snapshot(url)
        XCTAssertEqual(files.keys.filter { $0.contains("/events-") }.count, 3)
        value.taskAudits![0].events[259].output = "Updated output"
        value.taskAudits![0].events.append(ProjectActivityEvent(id: "event-260", category: "tool", title: "Inspect", status: "completed", output: "Last event"))
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).taskAudits, value.taskAudits)
        let newFiles = try snapshot(url)
        let oldChunks = files.keys.filter { $0.contains("/events-") }
        XCTAssertEqual(oldChunks.filter { newFiles[$0] == files[$0] }.count, 2)
    }

    func testRejectsOldFilesCorruptReferencesAndSymlinkAssets() throws {
        let url = try temporaryPackage()
        let value = project()
        let old = url.deletingLastPathComponent().appendingPathComponent("Old.lad")
        try ProjectStore.encode(value).write(to: old)
        XCTAssertThrowsError(try ProjectStore.read(from: old))
        try ProjectStore.write(value, to: url)
        let manifest = try root(url)
        let assets = try XCTUnwrap(manifest["assets"] as? [String: [String: Any]])
        let descriptor = try XCTUnwrap(assets.values.first)
        let path = try XCTUnwrap(descriptor["path"] as? String)
        let original = try Data(contentsOf: url.appendingPathComponent(path))
        try Data("corrupt".utf8).write(to: url.appendingPathComponent(path))
        ProjectPackage.clearSessionCache()
        XCTAssertThrowsError(try ProjectStore.read(from: url))
        try FileManager.default.removeItem(at: url.appendingPathComponent(path))
        let external = url.deletingLastPathComponent().appendingPathComponent("outside")
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent(path), withDestinationURL: external)
        XCTAssertThrowsError(try ProjectStore.read(from: url))
    }

    func testThumbnailsAreOptionalAndCopiesCanRetainValidImage() throws {
        let url = try temporaryPackage()
        let value = project()
        let png = try thumbnailPNG()
        try ProjectStore.write(value, to: url, thumbnail: png)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).thumbnailData, png)
        let thumbnail = try reference(root(url), "thumbnail")
        let path = try XCTUnwrap(thumbnail["path"] as? String)
        try FileManager.default.removeItem(at: url.appendingPathComponent(path))
        ProjectPackage.clearSessionCache()
        XCTAssertNil(try ProjectStore.read(from: url).thumbnailData)
        var changed = value; changed.showGrid = false
        XCTAssertNoThrow(try ProjectStore.write(changed, to: url, thumbnail: Data("invalid".utf8)))
        XCTAssertNil(try root(url)["thumbnail"])
    }

    func testStateSavesReuseValidatedThumbnailAndDropItWhenPresentationChanges() throws {
        let url = try temporaryPackage()
        var value = project()
        var alternate = value.revisions[0]
        alternate.id = UUID()
        value.revisions.append(alternate)
        let png = try thumbnailPNG()
        var metrics = ProjectPackage.WriteMetrics()
        try ProjectPackage.write(value, to: url, thumbnail: png, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.thumbnailValidations, 1)
        let original = try root(url)
        value.showGrid = false
        try ProjectPackage.write(value, to: url, thumbnail: png, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.historySnapshots, 0)
        XCTAssertEqual(metrics.thumbnailValidations, 0)
        XCTAssertEqual(try reference(root(url), "thumbnail")["sha256"] as? String, try reference(original, "thumbnail")["sha256"] as? String)
        value.draftPrompt = "A saved draft"
        try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.thumbnailValidations, 0)
        ProjectPackage.clearSessionCache()
        value = try ProjectStore.read(from: url)
        XCTAssertEqual(value.thumbnailData, png)

        value.projectionMode = .isometric
        try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.historySnapshots, 0)
        XCTAssertNil(try root(url)["thumbnail"])
        try ProjectPackage.write(value, to: url, thumbnail: png)
        value.selectedRevisionID = alternate.id
        try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.historySnapshots, 0)
        XCTAssertNil(try root(url)["thumbnail"])
        try ProjectPackage.write(value, to: url, thumbnail: png)
        value.revisions[1].partColors = ["body": PartColor(red: 1, green: 0, blue: 0)]
        try ProjectPackage.write(value, to: url)
        XCTAssertNil(try root(url)["thumbnail"])
        ProjectPackage.clearSessionCache()
        XCTAssertNil(try ProjectStore.read(from: url).thumbnailData)
    }

    func testSignedZeroSelectionAnchorsSurviveWarmAndColdJSONRecordsExactly() throws {
        let url = try temporaryPackage()
        var value = project()
        value.messages[0].content = "Retain literal text -0 and exponent 1e-0"
        value.messages[0].selection = ProjectSelectionContext(revisionID: value.revisions[0].id, parts: [], features: [
            ProjectSelectedFeature(id: CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0), partID: "body", partName: "Body", partPath: ["Body"],
                                   anchor: ProjectSelectionAnchor(geometryType: "plane", normal: [-0.0, -0.0, -1]))
        ])
        let expected = try ProjectArchive.split(value)
        try ProjectStore.write(value, to: url)
        value.showGrid = false
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: url)
        let normal = try XCTUnwrap(restored.messages[0].selection?.features[0].anchor?.normal)
        XCTAssertEqual(normal[0].sign, .minus)
        XCTAssertEqual(normal[1].sign, .minus)
        XCTAssertEqual(restored.messages[0].content, value.messages[0].content)
        var withoutStateChange = restored
        withoutStateChange.showGrid = nil
        XCTAssertEqual(try ProjectArchive.split(withoutStateChange).metadata, expected.metadata)
    }

    func testRootOnlyValidationRejectsMissingSelectedRevision() throws {
        let url = try temporaryPackage()
        var value = project()
        try ProjectStore.write(value, to: url)
        let committed = try ProjectStore.readArchive(from: url)
        value.selectedRevisionID = UUID()
        XCTAssertThrowsError(try ProjectStore.write(value, to: url))
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
    }

    func testRejectsMalformedPreviewSolidCountsBeforeCreatingPartArrays() throws {
        let url = try temporaryPackage()
        var value = project()
        value.revisions[0].parts = nil
        value.revisions[0].preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [], volume: 0, area: 0,
                                               solids: -1, faces: 0, buildSeconds: 0, threads: 1, stepPath: "")
        XCTAssertThrowsError(try ProjectStore.write(value, to: url))
    }
}
