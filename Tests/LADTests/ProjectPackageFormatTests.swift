import XCTest
@testable import LAD

/// Every package section is a typed record encoded once by one sorted-key
/// encoder. Earlier format versions open with their complete history and are
/// rewritten in the current encoding by their next save.
final class ProjectPackageFormatTests: XCTestCase {
    /// Written by the format 6 code, before sections became typed records.
    private static let formatSixFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/Format 6.lad", isDirectory: true)

    private var folder: URL!

    override func setUpWithError() throws {
        ProjectPackage.clearSessionCache()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-format-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        ProjectPackage.clearSessionCache()
    }

    private struct StoredFile: Equatable {
        var bytes: Data
        var inode: UInt64
        var modified: Date
    }

    private func files(_ url: URL) throws -> [String: StoredFile] {
        let resolved = url.resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey]))
        var result = [String: StoredFile]()
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            result[String(file.resolvingSymlinksInPath().path.dropFirst(resolved.path.count + 1))] = StoredFile(
                bytes: try Data(contentsOf: file),
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value,
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date))
        }
        return result
    }

    private func manifest(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectStore.readArchive(from: url)) as? [String: Any])
    }

    /// Content-addressed dependencies by path, and each section's committed
    /// index. The inactive index slot is left out.
    private func committedFiles(_ url: URL) throws -> [String: Data] {
        var result = try files(url).filter { path, _ in
            path != "project.json" && !path.hasSuffix("/index-1.json") && !path.hasSuffix("/index-2.json")
        }.mapValues(\.bytes)
        let root = try manifest(url)
        for section in ["revisions", "conversation", "activity", "catalog"] {
            let reference = try XCTUnwrap(root[section] as? [String: Any], section)
            result["\(section)/index"] = try Data(contentsOf: url.appendingPathComponent(try XCTUnwrap(reference["path"] as? String)))
        }
        return result
    }

    private func assertSameHistory(_ actual: LADProject, _ expected: LADProject, file: StaticString = #filePath, line: UInt = #line) throws {
        let actualArchive = try ProjectArchive.split(actual), expectedArchive = try ProjectArchive.split(expected)
        XCTAssertEqual(String(decoding: actualArchive.metadata, as: UTF8.self), String(decoding: expectedArchive.metadata, as: UTF8.self),
                       file: file, line: line)
        XCTAssertEqual(actualArchive.assets, expectedArchive.assets, file: file, line: line)
    }

    /// A disposable copy of the format 6 fixture, or the same records in the
    /// format 5 layout, whose manifest lists the asset catalog inline.
    private func legacyPackage(version: Int) throws -> URL {
        let url = folder.appendingPathComponent("Format \(version).lad", isDirectory: true)
        try FileManager.default.copyItem(at: Self.formatSixFixture, to: url)
        guard version == 5 else { return url }
        let catalog = try XCTUnwrap(manifest(url)["catalog"] as? [String: Any])
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent(
            XCTUnwrap(catalog["path"] as? String)))) as? [String: Any])
        var assets = [String: Any]()
        for case let bucket as [String: Any] in (index["buckets"] as? [String: Any] ?? [:]).values {
            let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent(XCTUnwrap(bucket["path"] as? String))))
            assets.merge(try XCTUnwrap(entries as? [String: Any])) { $1 }
        }
        // Edit the manifest text so its other values keep their exact legacy bytes.
        var text = String(decoding: try ProjectStore.readArchive(from: url), as: UTF8.self)
        let reference = try XCTUnwrap(text.range(of: #""catalog":\{[^}]*\},"#, options: .regularExpression))
        text.removeSubrange(reference)
        text = text.replacingOccurrences(of: "\"formatVersion\":6", with: "\"formatVersion\":5")
        let inline = String(decoding: try JSONSerialization.data(withJSONObject: assets, options: [.sortedKeys]), as: UTF8.self)
        text.insert(contentsOf: "\"assets\":\(inline),", at: text.index(after: text.startIndex))
        try Data(text.utf8).write(to: url.appendingPathComponent("project.json"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("catalog"))
        return url
    }

    func testEarlierFormatsOpenWithFullHistoryAndTheNextSaveRewritesEveryRecord() throws {
        for version in [6, 5] {
            let url = try legacyPackage(version: version)
            XCTAssertEqual(try manifest(url)["formatVersion"] as? Int, version)
            let expected = ProjectPackageFixture.project()
            let original = try files(url)
            XCTAssertEqual(try ProjectStore.projectID(at: url), expected.projectID)
            let opened = try ProjectStore.read(from: url)
            try assertSameHistory(opened, expected)
            let normal = try XCTUnwrap(opened.messages[3].selection?.features[0].anchor?.normal)
            XCTAssertEqual(normal.map(\.sign), [.minus, .minus, .minus])
            XCTAssertEqual(opened.revisions[1].jointPositions?["hinge"]?.sign, .minus)
            XCTAssertEqual(opened.thumbnailData, ProjectPackageFixture.png, "The saved thumbnail still matches its presentation")
            XCTAssertEqual(try files(url), original, "Opening never writes")

            var edited = opened
            edited.showGrid = true
            struct Interrupted: Error {}
            XCTAssertThrowsError(try ProjectPackage.write(edited, to: url, beforePublication: { throw Interrupted() }))
            ProjectPackage.clearSessionCache()
            XCTAssertEqual(try manifest(url)["formatVersion"] as? Int, version)
            try assertSameHistory(try ProjectStore.read(from: url), expected)

            // The thumbnail's presentation is unchanged, so the save keeps it.
            try ProjectPackage.write(edited, to: url)
            XCTAssertEqual(try manifest(url)["formatVersion"] as? Int, ProjectPackage.formatVersion)
            XCTAssertNil(try manifest(url)["assets"])
            let upgraded = try files(url)
            for (path, file) in original where path.hasPrefix("assets/") {
                XCTAssertEqual(upgraded[path], file, "Payload files are kept as they are: \(path)")
            }
            ProjectPackage.clearSessionCache()
            let reopened = try ProjectStore.read(from: url)
            try assertSameHistory(reopened, edited)
            XCTAssertEqual(reopened.showGrid, true)
            XCTAssertEqual(reopened.thumbnailData, ProjectPackageFixture.png)

            // The upgraded package holds exactly the files a new package of the
            // same design would: no record keeps its earlier encoding.
            let fresh = folder.appendingPathComponent("Fresh \(version).lad", isDirectory: true)
            try ProjectPackage.write(reopened, to: fresh, thumbnail: reopened.thumbnailData)
            XCTAssertEqual(try committedFiles(url), try committedFiles(fresh))

            var moved = reopened
            moved.partsPaneFraction = 0.5
            var metrics = ProjectPackage.WriteMetrics()
            try ProjectPackage.write(moved, to: url, thumbnail: reopened.thumbnailData, didFinish: { metrics = $0 })
            XCTAssertEqual(metrics.historySnapshots, 0)
            let after = try files(url)
            XCTAssertEqual(Set(after.keys), Set(upgraded.keys))
            for (path, file) in upgraded where path != "project.json" { XCTAssertEqual(after[path], file, path) }
        }
    }

    func testEverySectionRoundTripsThroughTypedRecordsWithStableBytes() throws {
        let project = ProjectPackageFixture.project()
        let first = folder.appendingPathComponent("First.lad", isDirectory: true)
        try ProjectPackage.write(project, to: first, thumbnail: ProjectPackageFixture.png)
        let root = try manifest(first)
        XCTAssertNotNil(root["queuedRequests"])
        XCTAssertNotNil(root["draftAttachments"])
        XCTAssertNotNil(root["thumbnail"])
        let stored = try files(first)
        XCTAssertEqual(stored.keys.filter { $0.contains("/recipe-") }.count, 2)
        XCTAssertEqual(stored.keys.filter { $0.contains("/parts-") }.count, 2)
        XCTAssertEqual(stored.keys.filter { $0.hasPrefix("conversation/messages-") }.count, 1)
        XCTAssertEqual(stored.keys.filter { $0.contains("/task-") }.count, 2)
        XCTAssertEqual(stored.keys.filter { $0.contains("/events-") }.count, 2)
        XCTAssertFalse(stored.keys.filter { $0.hasPrefix("catalog/assets-") }.isEmpty)

        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: first)
        try assertSameHistory(restored, project)
        XCTAssertEqual(restored.thumbnailData, ProjectPackageFixture.png)

        // Decoding and encoding again reproduces every file byte for byte.
        let second = folder.appendingPathComponent("Second.lad", isDirectory: true)
        try ProjectPackage.write(restored, to: second, thumbnail: restored.thumbnailData)
        let copy = try files(second)
        XCTAssertEqual(Set(copy.keys), Set(stored.keys))
        for (path, file) in stored where path != "project.json" { XCTAssertEqual(copy[path]?.bytes, file.bytes, path) }
        let commit = try XCTUnwrap(root["commitID"] as? String)
        let copiedCommit = try XCTUnwrap(try manifest(second)["commitID"] as? String)
        XCTAssertEqual(String(decoding: try XCTUnwrap(stored["project.json"]).bytes, as: UTF8.self)
                        .replacingOccurrences(of: commit, with: copiedCommit),
                       String(decoding: try XCTUnwrap(copy["project.json"]).bytes, as: UTF8.self))
    }

    func testSignedZeroAndExtremeNumbersRoundTripExactly() throws {
        var project = ProjectPackageFixture.project()
        let tiny = Double.leastNonzeroMagnitude, huge = Double.greatestFiniteMagnitude
        project.partsPaneFraction = -0.0
        project.messages[3].selection?.features[0].anchor = ProjectSelectionAnchor(
            geometryType: "plane", center: [-0.0, tiny, -1e-300], normal: [0.1, -0.0, 1_000_000.1],
            radius: -0.0, area: huge, volume: tiny)
        project.revisions[1].jointPositions = ["hinge": -0.0, "slider": -1e9, "rail": -tiny]
        project.revisions[1].partColors = ["base": PartColor(red: -0.0, green: tiny, blue: 0.1)]
        project.taskAudits![0].events[0].durationSeconds = tiny
        project.taskAudits![0].events[1].durationSeconds = huge
        project.queuedRequests![0].selection?.jointPositions = ["hinge": -0.0, "rail": 1e-308]
        let url = folder.appendingPathComponent("Numbers.lad", isDirectory: true)
        try ProjectPackage.write(project, to: url)
        XCTAssertTrue(String(decoding: try ProjectStore.readArchive(from: url), as: UTF8.self).contains("\"partsPaneFraction\":-0"))
        // A warm state-only save, then a cold read.
        project.showGrid = true
        try ProjectPackage.write(project, to: url)
        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: url)
        try assertSameHistory(restored, project)
        XCTAssertEqual(restored.partsPaneFraction.sign, .minus)
        let anchor = try XCTUnwrap(restored.messages[3].selection?.features[0].anchor)
        XCTAssertEqual(anchor.center?.map(\.bitPattern), [(-0.0).bitPattern, tiny.bitPattern, (-1e-300).bitPattern])
        XCTAssertEqual(anchor.normal?.map(\.bitPattern), [(0.1).bitPattern, (-0.0).bitPattern, (1_000_000.1).bitPattern])
        XCTAssertEqual(anchor.radius?.bitPattern, (-0.0).bitPattern)
        XCTAssertEqual(anchor.area, huge)
        XCTAssertEqual(anchor.volume, tiny)
        XCTAssertEqual(restored.revisions[1].jointPositions?.mapValues(\.bitPattern),
                       ["hinge": (-0.0).bitPattern, "slider": (-1e9).bitPattern, "rail": (-tiny).bitPattern])
        XCTAssertEqual(restored.revisions[1].partColors?["base"]?.red.sign, .minus)
        XCTAssertEqual(restored.taskAudits?[0].events[0].durationSeconds, tiny)
        XCTAssertEqual(restored.taskAudits?[0].events[1].durationSeconds, huge)
        XCTAssertEqual(restored.queuedRequests?[0].selection?.jointPositions?["hinge"]?.sign, .minus)
        XCTAssertEqual(restored.queuedRequests?[0].selection?.jointPositions?["rail"], 1e-308)
    }
}
