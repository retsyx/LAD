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

    private struct StoredFile: Equatable {
        var bytes: Data
        var inode: UInt64
        var modified: Date
    }

    private func storedFiles(_ url: URL) throws -> [String: StoredFile] {
        try Dictionary(uniqueKeysWithValues: snapshot(url).map { path, bytes in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)
            return (path, StoredFile(bytes: bytes,
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value,
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date)))
        })
    }

    private func assertColdRoundtrip(_ value: LADProject, at url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        ProjectPackage.clearSessionCache()
        let expected = try ProjectArchive.split(value), actual = try ProjectArchive.split(ProjectStore.read(from: url))
        XCTAssertEqual(actual.metadata, expected.metadata, file: file, line: line)
        XCTAssertEqual(actual.assets, expected.assets, file: file, line: line)
    }

    private func thumbnailPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private final class ConcurrentPackageResults: @unchecked Sendable {
        private let lock = NSLock()
        private var errors = [String]()
        private var project: LADProject?
        private var manifest: Data?

        func perform(_ name: String, _ action: () throws -> Void) {
            do { try action() }
            catch {
                lock.lock(); defer { lock.unlock() }
                errors.append("\(name): \(error)")
            }
        }

        func record(project: LADProject) {
            lock.lock(); defer { lock.unlock() }
            self.project = project
        }

        func record(manifest: Data) {
            lock.lock(); defer { lock.unlock() }
            self.manifest = manifest
        }

        func values() -> (errors: [String], project: LADProject?, manifest: Data?) {
            lock.lock(); defer { lock.unlock() }
            return (errors, project, manifest)
        }
    }

    func testBusyPackageDoesNotBlockOtherDesignsAndSamePackageOperationsWait() throws {
        let firstURL = try temporaryPackage(), secondURL = try temporaryPackage()
        let first = project(), second = project()
        try ProjectStore.write(first, to: firstURL)
        try ProjectStore.write(second, to: secondURL)
        let aliasParent = firstURL.deletingLastPathComponent().appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: firstURL.deletingLastPathComponent())
        let aliasURL = aliasParent.appendingPathComponent(firstURL.lastPathComponent, isDirectory: true)
        let caseAliasURL = firstURL.deletingLastPathComponent().appendingPathComponent(firstURL.lastPathComponent.lowercased(), isDirectory: true)
        let rootReadURL = FileManager.default.fileExists(atPath: caseAliasURL.path) ? caseAliasURL : firstURL
        var changedFirst = first, changedSecond = second
        changedFirst.showGrid = false
        changedSecond.showGrid = false
        var laterFirst = changedFirst
        laterFirst.partsPaneFraction = 0.63
        let firstWrite = changedFirst, secondWrite = changedSecond, subsequentWrite = laterFirst
        let enteredFirst = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
        let readStarted = DispatchSemaphore(value: 0), readFinished = DispatchSemaphore(value: 0)
        let rootStarted = DispatchSemaphore(value: 0), rootFinished = DispatchSemaphore(value: 0)
        let writeStarted = DispatchSemaphore(value: 0), writeFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0), cacheCleared = DispatchSemaphore(value: 0)
        let group = DispatchGroup(), results = ConcurrentPackageResults()
        func launch(_ action: @escaping @Sendable () -> Void) {
            group.enter()
            DispatchQueue.global().async { action(); group.leave() }
        }
        defer { releaseFirst.signal(); _ = group.wait(timeout: .now() + 10) }
        launch {
            results.perform("first write") {
                try ProjectPackage.write(firstWrite, to: firstURL, beforePublication: {
                    enteredFirst.signal()
                    guard releaseFirst.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
                })
            }
        }
        guard enteredFirst.wait(timeout: .now() + 10) == .success else { return XCTFail("The first save did not reach publication") }
        launch {
            readStarted.signal()
            results.perform("same package read through alias") { results.record(project: try ProjectPackage.read(from: aliasURL)) }
            readFinished.signal()
        }
        launch {
            rootStarted.signal()
            results.perform("same package manifest read through case alias") { results.record(manifest: try ProjectPackage.rootData(from: rootReadURL)) }
            rootFinished.signal()
        }
        launch {
            writeStarted.signal()
            results.perform("same package next write") { try ProjectPackage.write(subsequentWrite, to: aliasURL) }
            writeFinished.signal()
        }
        launch {
            results.perform("independent design write") { try ProjectPackage.write(secondWrite, to: secondURL) }
            secondFinished.signal()
        }
        launch { ProjectPackage.clearSessionCache(); cacheCleared.signal() }
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 5), .success, "An unrelated design must save while the first publication is blocked")
        XCTAssertEqual(cacheCleared.wait(timeout: .now() + 5), .success, "Clearing derived caches must not wait for file work")
        XCTAssertEqual(readStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(rootStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(readFinished.wait(timeout: .now() + .milliseconds(100)), .timedOut)
        XCTAssertEqual(rootFinished.wait(timeout: .now() + .milliseconds(100)), .timedOut)
        XCTAssertEqual(writeFinished.wait(timeout: .now() + .milliseconds(100)), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let captured = results.values()
        XCTAssertEqual(captured.errors, [])
        XCTAssertEqual(captured.project?.showGrid, false)
        let manifest = try XCTUnwrap(captured.manifest)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertEqual(root["showGrid"] as? Bool, false)
        try assertColdRoundtrip(subsequentWrite, at: firstURL)
        try assertColdRoundtrip(secondWrite, at: secondURL)
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
        XCTAssertTrue(restored.revisions.allSatisfy { $0.preview == nil })
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

        let text = "# A retained input\n"
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let attachment = SourceAttachment(name: "input.py", path: "/missing/input.py", content: text, sha256: hash)
        value.queuedRequests = [ProjectQueuedRequest(content: "Refine this input", attachments: [attachment])]
        value.draftAttachments = [attachment]
        try ProjectStore.write(value, to: url)
        let inlineCommitted = try ProjectStore.readArchive(from: url)
        var changed = value
        changed.queuedRequests![0].content = ""
        changed.queuedRequests![0].attachments = nil
        XCTAssertThrowsError(try ProjectStore.write(changed, to: url), "A cached request ID cannot authorize changed invalid contents")
        changed = value
        changed.draftAttachments![0].content += "changed bytes"
        XCTAssertThrowsError(try ProjectStore.write(changed, to: url), "Changed draft bytes must still match their digest")
        XCTAssertEqual(inlineCommitted, try ProjectStore.readArchive(from: url))
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
        value.taskAudits = [ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events: [
            ProjectActivityEvent(id: "event", category: "tool", title: "Inspect", status: "completed", output: "Original output")
        ])]
        try ProjectStore.write(value, to: url)
        let original = value
        let committed = try ProjectStore.readArchive(from: url)
        value.revisions[0].model.script += "\n# New candidate\n"
        value.messages.append(ChatMessage(role: "assistant", content: "Updated candidate", phase: "commentary"))
        value.taskAudits![0].events[0].output = "Unpublished output"
        XCTAssertThrowsError(try ProjectPackage.write(value, to: url, beforePublication: { throw Interrupted() }))
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
        var metrics = ProjectPackage.WriteMetrics()
        try ProjectPackage.write(original, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.rootEncodings, 0, "The failed save must not change any committed in-memory cache")
        XCTAssertEqual(committed, try ProjectStore.readArchive(from: url))
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).messages.count, 1)
        XCTAssertEqual(try ProjectStore.read(from: url).taskAudits?[0].events[0].output, "Original output")
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).messages.count, 2)
        XCTAssertEqual(try ProjectStore.read(from: url).revisions[0].model.script, value.revisions[0].model.script)
        XCTAssertEqual(try ProjectStore.read(from: url).taskAudits, value.taskAudits)
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

    func testTranscriptEditsEncodeOnlyChangedMessageAndConversationTail() throws {
        let url = try temporaryPackage()
        var value = project()
        value.messages += (0..<259).map { ChatMessage(role: "assistant", content: "Saved response \($0)") }
        value.taskAudits = [ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events:
            (0..<260).map { ProjectActivityEvent(id: "event-\($0)", category: "tool", title: "Inspect", status: "completed", output: "History \($0)") })]
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        value = try ProjectStore.read(from: url)
        for append in [true, false] {
            let before = try storedFiles(url)
            if append { value.messages.append(ChatMessage(role: "assistant", content: "New response")) }
            else { value.messages[value.messages.count - 1].content += " and more text" }
            var metrics = ProjectPackage.WriteMetrics()
            try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
            XCTAssertEqual(metrics.encodedHistoryRecords, 1)
            XCTAssertEqual(metrics.encodedChunks, 1)
            XCTAssertEqual(metrics.encodedSectionIndexes, 1)
            XCTAssertEqual(metrics.encodedRevisionRecipes, 0)
            XCTAssertEqual(metrics.encodedRevisionParts, 0)
            XCTAssertEqual(metrics.encodedTaskRecords, 0)
            XCTAssertEqual(metrics.compressedAssets, 0)
            let after = try storedFiles(url)
            for (path, stored) in before where path != "project.json" && !path.hasPrefix("conversation/") {
                XCTAssertEqual(after[path], stored, path)
            }
            let oldChunks = before.keys.filter { $0.hasPrefix("conversation/messages-") }
            XCTAssertEqual(oldChunks.filter { after[$0] == before[$0] }.count, 2, "Complete old chunks remain untouched")
            try assertColdRoundtrip(value, at: url)
        }
    }

    func testTranscriptSizeChangesReflowChunkBoundariesThenSurviveColdReorderAndRemoval() throws {
        let url = try temporaryPackage()
        var value = project()
        value.messages += (0..<4).map { ChatMessage(role: "assistant", content: String(repeating: "\($0)", count: 240_000)) }
        try ProjectStore.write(value, to: url)
        XCTAssertEqual(try snapshot(url).keys.filter { $0.hasPrefix("conversation/messages-") }.count, 2)
        ProjectPackage.clearSessionCache()
        value = try ProjectStore.read(from: url)
        value.messages[1].content += String(repeating: "X", count: 40_000)
        var metrics = ProjectPackage.WriteMetrics()
        try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.encodedHistoryRecords, 1)
        XCTAssertEqual(metrics.encodedChunks, 3, "Only a size change may move the following greedy chunk boundaries")
        XCTAssertEqual(try snapshot(url).keys.filter { $0.hasPrefix("conversation/messages-") }.count, 3)
        try assertColdRoundtrip(value, at: url)
        value.messages.swapAt(1, 4)
        value.messages.remove(at: 2)
        try ProjectStore.write(value, to: url)
        try assertColdRoundtrip(value, at: url)
    }

    func testActivityAppendReusesOtherTasksSectionsAndCompleteChunks() throws {
        let url = try temporaryPackage()
        var value = project()
        func events(_ prefix: String, _ count: Int) -> [ProjectActivityEvent] {
            (0..<count).map { ProjectActivityEvent(id: "\(prefix)-\($0)", category: "tool", title: "Inspect", status: "completed", output: "\(prefix) output \($0)") }
        }
        value.taskAudits = [
            ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events: events("first", 260)),
            ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events: events("second", 130))
        ]
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        value = try ProjectStore.read(from: url)
        let firstID = value.taskAudits![0].id.uuidString, secondID = value.taskAudits![1].id.uuidString
        let before = try storedFiles(url)
        value.taskAudits![0].events[259].output = "Extended first output"
        value.taskAudits![0].events.append(ProjectActivityEvent(id: "first-260", category: "tool", title: "Inspect", status: "completed", output: "New output"))
        var metrics = ProjectPackage.WriteMetrics()
        try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
        XCTAssertEqual(metrics.encodedHistoryRecords, 2)
        XCTAssertEqual(metrics.encodedChunks, 1)
        XCTAssertEqual(metrics.encodedSectionIndexes, 1)
        XCTAssertEqual(metrics.encodedTaskRecords, 1)
        XCTAssertEqual(metrics.encodedRevisionRecipes, 0)
        let after = try storedFiles(url)
        for (path, stored) in before where path.hasPrefix("revisions/") || path.hasPrefix("conversation/") || path.hasPrefix("activity/\(secondID)/") {
            XCTAssertEqual(after[path], stored, path)
        }
        for path in before.keys where path.hasPrefix("assets/") && after[path] != nil { XCTAssertEqual(after[path], before[path], path) }
        let oldChunks = before.keys.filter { $0.hasPrefix("activity/\(firstID)/events-") }
        XCTAssertEqual(oldChunks.filter { after[$0] == before[$0] }.count, 2)
        try assertColdRoundtrip(value, at: url)
    }

    func testVersionNameAndPartsChangesReuseRecipeAndAssets() throws {
        let url = try temporaryPackage()
        var value = project()
        value.revisions[0].model.sourceSTEP = Data("ISO-10303-21;\n\(String(repeating: " ", count: 24_000))\nEND-ISO-10303-21;\n".utf8)
        try ProjectStore.write(value, to: url)
        for rename in [true, false] {
            let before = try storedFiles(url)
            if rename { value.revisions[0].name = "Named version" }
            else { value.revisions[0].partColors = ["body": PartColor(red: 1, green: 0, blue: 0)] }
            var metrics = ProjectPackage.WriteMetrics()
            try ProjectPackage.write(value, to: url, didFinish: { metrics = $0 })
            XCTAssertEqual(metrics.encodedChunks, 0)
            XCTAssertEqual(metrics.encodedSectionIndexes, 1)
            XCTAssertEqual(metrics.encodedRevisionRecipes, 0)
            XCTAssertEqual(metrics.encodedRevisionParts, rename ? 0 : 1)
            XCTAssertEqual(metrics.compressedAssets, 0)
            let after = try storedFiles(url)
            for (path, stored) in before where path.contains("/recipe-") || path.hasPrefix("assets/") || path.hasPrefix("conversation/") || path.hasPrefix("activity/") {
                XCTAssertEqual(after[path], stored, path)
            }
            try assertColdRoundtrip(value, at: url)
        }
    }

    func testHistoryReorderingAndRemovalPruneOnlyLastSharedAssetReference() throws {
        let url = try temporaryPackage()
        var value = project()
        let source = "# Shared original\n"
        let bytes = Data(source.utf8), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attachment = SourceAttachment(name: "source.py", path: "/missing/source.py", content: source, sha256: hash)
        value.messages += [ChatMessage(role: "assistant", content: "First"), ChatMessage(role: "assistant", content: "Second")]
        value.messages[0].attachments = [attachment]
        value.revisions.append(ProjectRevision(model: value.revisions[0].model, parts: value.revisions[0].parts))
        value.taskAudits = [ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events: [
            ProjectActivityEvent(id: "a", category: "tool", title: "Inspect", status: "completed", output: source),
            ProjectActivityEvent(id: "b", category: "tool", title: "Inspect", status: "completed", output: "Other")
        ]), ProjectTaskAudit(userMessageID: value.messages[0].id, model: "test", reasoningEffort: "high", events: [])]
        try ProjectStore.write(value, to: url)
        value.messages.swapAt(1, 2)
        value.revisions.reverse()
        value.taskAudits!.reverse()
        value.taskAudits![1].events.reverse()
        try ProjectStore.write(value, to: url)
        try assertColdRoundtrip(value, at: url)
        value.messages[0].attachments = nil
        value.messages.removeLast()
        value.revisions.removeLast()
        value.selectedRevisionID = value.revisions[0].id
        value.taskAudits!.removeFirst()
        value.taskAudits![0].events.removeFirst()
        try ProjectStore.write(value, to: url)
        XCTAssertNotNil((try root(url)["assets"] as? [String: Any])?[hash], "Activity still refers to the shared source")
        try assertColdRoundtrip(value, at: url)
        value.taskAudits![0].events.removeAll()
        try ProjectStore.write(value, to: url)
        XCTAssertNil((try root(url)["assets"] as? [String: Any])?[hash], "Last reference removal prunes the payload")
        try assertColdRoundtrip(value, at: url)
        value.taskAudits = nil
        try ProjectStore.write(value, to: url)
        try assertColdRoundtrip(value, at: url)
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

    func testLoadingDropsValidThumbnailWhosePresentationIdentityIsStale() throws {
        let url = try temporaryPackage()
        let value = project(), png = try thumbnailPNG()
        try ProjectPackage.write(value, to: url, thumbnail: png)
        let originalRoot = try root(url)
        for change in [["displayMode": "shaded"], ["projectionMode": "isometric"]] {
            var changed = originalRoot
            for (key, value) in change { changed[key] = value }
            try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]).write(to: url.appendingPathComponent("project.json"), options: .atomic)
            ProjectPackage.clearSessionCache()
            let restored = try ProjectStore.read(from: url)
            XCTAssertNil(restored.thumbnailData, "A decoded PNG must still match the current saved presentation")
            XCTAssertEqual(restored.revisions.map(\.model), value.revisions.map(\.model))
        }
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
