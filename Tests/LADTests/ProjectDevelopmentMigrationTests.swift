import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LAD

/// Explicit development tooling only. The application never detects or opens
/// legacy archives through its package reader.
final class ProjectDevelopmentMigrationTests: XCTestCase {
    @MainActor
    func testDevelopmentMigration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["LAD_MIGRATION_MODE"] else {
            throw XCTSkip("Run Scripts/migrate-projects.sh for the one-time development conversion.")
        }
        let source = try directory(environment["LAD_MIGRATION_SOURCE_DIRECTORY"], name: "source")
        let staging = try directory(environment["LAD_MIGRATION_STAGING_DIRECTORY"], name: "staging")
        guard source != staging else { throw failure("Source and staging directories must differ.") }
        switch mode {
        case "stage":
            try await stage(source: source, staging: staging,
                            thumbnails: environment["LAD_MIGRATION_THUMBNAILS"] == "1")
        case "publish":
            let backup = try directory(environment["LAD_MIGRATION_BACKUP_DIRECTORY"], name: "backup")
            guard backup != source, backup != staging else { throw failure("The backup directory must be separate.") }
            try publish(source: source, staging: staging, backup: backup)
        default:
            throw failure("Unknown migration mode: \(mode).")
        }
    }

    func testAtomicReplacementSupportsLegacyFilesPackagesAndRollback() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("LAD-migration-replacement-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let original = root.appendingPathComponent("Original.lad")
        let package = root.appendingPathComponent("Staged.lad", isDirectory: true)
        let rollback = root.appendingPathComponent("Rollback.lad.zip")
        let bytes = Data("original archive bytes".utf8)
        try bytes.write(to: original)
        try bytes.write(to: rollback)
        try manager.createDirectory(at: package, withIntermediateDirectories: false)
        try Data("manifest".utf8).write(to: package.appendingPathComponent("project.json"))

        _ = try manager.replaceItemAt(original, withItemAt: package, options: .usingNewMetadataOnly)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("project.json")), Data("manifest".utf8))
        _ = try manager.replaceItemAt(original, withItemAt: rollback, options: .usingNewMetadataOnly)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: root.path), ["Original.lad"])
    }

    private struct MigrationReport: Codable {
        var formatVersion = 1
        var sourceDirectory: String
        var stagingDirectory: String
        var createdAt = Date()
        var thumbnailsRequested: Bool
        var results: [MigrationItem]
    }

    private struct MigrationItem: Codable {
        var name: String
        var sourcePath: String
        var stagedPath: String
        var status: String
        var sourceSHA256: String?
        var sourceBytes: Int?
        var metadataSHA256: String?
        var projectID: UUID?
        var revisions: Int?
        var messages: Int?
        var tasks: Int?
        var events: Int?
        var assets: Int?
        var assetBytes: Int?
        var thumbnailBytes: Int?
        var thumbnailError: String?
        var error: String?
        var durationSeconds: Double
    }

    private struct PublishReport: Codable {
        var sourceDirectory: String
        var stagingDirectory: String
        var backupDirectory: String
        var thumbnailWarnings: Int
        var createdAt = Date()
        var results: [PublishItem]
    }

    private struct PublishItem: Codable {
        var name: String
        var sourceSHA256: String
        var backupPath: String
        var status: String
        var error: String?
        var durationSeconds: Double
    }

    @MainActor
    private func stage(source: URL, staging: URL, thumbnails: Bool) async throws {
        let manager = FileManager.default
        try requireDirectory(source)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let reportURL = staging.appendingPathComponent("migration-report.json")
        var previousItems: [String: MigrationItem] = [:]
        if manager.fileExists(atPath: reportURL.path) {
            let previous = try JSONDecoder().decode(MigrationReport.self, from: Data(contentsOf: reportURL))
            guard previous.formatVersion == 1, previous.sourceDirectory == source.path,
                  previous.stagingDirectory == staging.path,
                  Set(previous.results.map(\.name)).count == previous.results.count else {
                throw failure("The existing staging report does not match these directories.")
            }
            previousItems = Dictionary(uniqueKeysWithValues: previous.results.map { ($0.name, $0) })
        }
        let candidates = try manager.contentsOfDirectory(at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).filter { $0.pathExtension.lowercased() == "lad" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !candidates.isEmpty else { throw failure("No .lad designs were found in the source directory.") }
        var report = MigrationReport(sourceDirectory: source.path, stagingDirectory: staging.path,
                                     thumbnailsRequested: thumbnails, results: [])
        let engine = EngineService()
        for (index, input) in candidates.enumerated() {
            let start = ProcessInfo.processInfo.systemUptime
            let output = staging.appendingPathComponent(input.lastPathComponent, isDirectory: true)
            var item = MigrationItem(name: input.lastPathComponent, sourcePath: input.path,
                                     stagedPath: output.path, status: "failed", durationSeconds: 0)
            progress("Staging \(index + 1)/\(candidates.count): \(input.lastPathComponent)")
            var createdOutput = false
            do {
                let info = try input.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw failure("Symbolic-link source designs are not supported.") }
                if info.isDirectory == true {
                    _ = try ProjectStore.read(from: input)
                    item.status = "already-package"
                } else {
                    guard info.isRegularFile == true else { throw failure("The source is not a regular archive file.") }
                    let bytes = try coordinatedArchiveRead(input)
                    item.sourceSHA256 = digest(bytes)
                    item.sourceBytes = bytes.count
                    var project = try ProjectStore.decode(bytes)
                    let previous = previousItems[input.lastPathComponent]
                    if project.projectID == nil {
                        project.projectID = previous?.sourceSHA256 == item.sourceSHA256 ? previous?.projectID ?? UUID() : UUID()
                    }
                    let expected = try ProjectArchive.split(project)
                    item.metadataSHA256 = digest(expected.metadata)
                    item.projectID = project.projectID
                    item.revisions = project.revisions.count
                    item.messages = project.messages.count
                    item.tasks = project.taskAudits?.count ?? 0
                    item.events = project.taskAudits?.reduce(0) { $0 + $1.events.count } ?? 0
                    item.assets = expected.assets.count
                    item.assetBytes = expected.assets.values.reduce(0) { $0 + $1.count }
                    let existingOutput = manager.fileExists(atPath: output.path)
                    if existingOutput {
                        guard previous?.sourceSHA256 == item.sourceSHA256,
                              previous?.metadataSHA256 == item.metadataSHA256 else {
                            throw failure("The staged destination does not match this unchanged source; choose a fresh staging directory.")
                        }
                        try verify(expected: expected, at: output)
                        project.thumbnailData = try ProjectStore.read(from: output).thumbnailData
                        item.thumbnailBytes = project.thumbnailData?.count
                        progress("Verified existing conversion: \(input.lastPathComponent)")
                    }
                    if thumbnails, project.thumbnailData == nil,
                       let selected = project.revisions.first(where: { $0.id == project.selectedRevisionID }) {
                        do {
                            progress("Rendering thumbnail: \(input.lastPathComponent)")
                            let python = try await CADRuntimeManager.resolvePython(EngineService.defaultPython)
                            let preview = try await engine.buildPreview(selected.model, python: python, threads: 8,
                                                                        validatedHash: selected.validatedHash)
                            project.thumbnailData = try await ProjectThumbnail.render(project: project, preview: preview)
                            item.thumbnailBytes = project.thumbnailData?.count
                        } catch {
                            item.thumbnailError = error.localizedDescription
                            progress("Thumbnail warning: \(input.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    createdOutput = !existingOutput
                    try ProjectStore.write(project, to: output, thumbnail: project.thumbnailData)
                    try verify(expected: expected, at: output)
                    guard digest(try coordinatedArchiveRead(input)) == item.sourceSHA256 else {
                        throw failure("The source changed while staging; the original was left untouched.")
                    }
                    item.status = "staged"
                }
            } catch {
                item.error = error.localizedDescription
                if createdOutput { try? manager.removeItem(at: output) }
                progress("Conversion failed: \(input.lastPathComponent): \(error.localizedDescription)")
            }
            item.durationSeconds = ProcessInfo.processInfo.systemUptime - start
            report.results.append(item)
            // Keep unvisited resume entries in the checkpoint if interrupted
            // midway through a retry; the final checkpoint contains this batch.
            var checkpoint = report
            let visited = Set(report.results.map(\.name))
            checkpoint.results += candidates.compactMap { candidate in
                visited.contains(candidate.lastPathComponent) ? nil : previousItems[candidate.lastPathComponent]
            }
            try write(checkpoint, to: reportURL)
        }
        let failures = report.results.filter { $0.status == "failed" }
        let thumbnailWarnings = report.results.filter { $0.thumbnailError != nil }
        progress("Staging finished: \(report.results.filter { $0.status == "staged" }.count) converted, \(failures.count) conversion failures, \(thumbnailWarnings.count) thumbnail warnings.")
        XCTAssertTrue(failures.isEmpty, "Review migration-report.json for conversion failures.")
    }

    @MainActor
    private func publish(source: URL, staging: URL, backup: URL) throws {
        try requireLADStopped()
        let manager = FileManager.default
        let report = try JSONDecoder().decode(MigrationReport.self,
            from: Data(contentsOf: staging.appendingPathComponent("migration-report.json")))
        guard report.formatVersion == 1, report.sourceDirectory == source.path,
              report.stagingDirectory == staging.path, !report.results.isEmpty,
              report.results.allSatisfy({ $0.status == "staged" || $0.status == "already-package" }) else {
            throw failure("The staging report is incomplete or does not match these directories.")
        }
        try requireDirectory(source)
        try requireDirectory(staging)
        let stagedNames = Set(report.results.map(\.name))
        let currentNames = Set(try manager.contentsOfDirectory(at: source,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "lad" }.map(\.lastPathComponent))
        guard stagedNames.count == report.results.count, stagedNames == currentNames else {
            throw failure("The staging report does not cover the complete current source folder. Finish staging before publishing.")
        }
        try manager.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var prepared: [(MigrationItem, ProjectArchive.Snapshot, Bool)] = []
        // Preflight the entire batch before replacing any source design.
        for item in report.results where item.status == "staged" {
            let input = source.appendingPathComponent(item.name)
            let staged = staging.appendingPathComponent(item.name, isDirectory: true)
            guard !item.name.contains("/"), !item.name.isEmpty,
                  input.pathExtension.lowercased() == "lad",
                  input.path == item.sourcePath, staged.path == item.stagedPath,
                  let expectedSHA = item.sourceSHA256 else { throw failure("Invalid staged source references.") }
            let stagedProject = try ProjectStore.read(from: staged)
            let expected = try ProjectArchive.split(stagedProject)
            guard digest(expected.metadata) == item.metadataSHA256 else { throw failure("Staged metadata changed for \(item.name).") }
            let info = try input.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw failure("A source design became a symbolic link.") }
            let backupURL = backup.appendingPathComponent(item.name + ".zip")
            if info.isDirectory == true {
                try verifyBackup(backupURL, sha256: expectedSHA)
                try verify(expected: expected, at: input)
                prepared.append((item, expected, true))
            } else {
                guard info.isRegularFile == true, digest(try coordinatedArchiveRead(input)) == expectedSHA else {
                    throw failure("The source changed after staging: \(item.name).")
                }
                if manager.fileExists(atPath: backupURL.path) {
                    try verifyBackup(backupURL, sha256: expectedSHA)
                }
                prepared.append((item, expected, false))
            }
        }
        var published = PublishReport(sourceDirectory: source.path, stagingDirectory: staging.path,
                                      backupDirectory: backup.path,
                                      thumbnailWarnings: report.results.filter { $0.thumbnailError != nil }.count,
                                      results: [])
        for (item, expected, alreadyPublished) in prepared {
            let start = ProcessInfo.processInfo.systemUptime
            let input = source.appendingPathComponent(item.name)
            let staged = staging.appendingPathComponent(item.name, isDirectory: true)
            let backupURL = backup.appendingPathComponent(item.name + ".zip")
            let sourceSHA = try XCTUnwrap(item.sourceSHA256)
            var result = PublishItem(name: item.name, sourceSHA256: sourceSHA, backupPath: backupURL.path,
                                     status: alreadyPublished ? "already-published" : "failed", durationSeconds: 0)
            if !alreadyPublished {
                progress("Publishing: \(item.name)")
                do {
                    try coordinatedWrite(input) { writable in
                        let values = try writable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true,
                              ProjectFileOrigin.canonicalURL(writable).path == ProjectFileOrigin.canonicalURL(input).path else {
                            throw failure("The source location changed before publication.")
                        }
                        let bytes = try Data(contentsOf: writable)
                        guard digest(bytes) == sourceSHA else { throw failure("The source changed before publication.") }
                        if !manager.fileExists(atPath: backupURL.path) {
                            try bytes.write(to: backupURL, options: .atomic)
                        }
                        try verifyBackup(backupURL, sha256: sourceSHA)
                        let localStaging = writable.deletingLastPathComponent()
                            .appendingPathComponent(".LAD-migration-\(UUID().uuidString).lad", isDirectory: true)
                        defer { try? manager.removeItem(at: localStaging) }
                        try manager.copyItem(at: staged, to: localStaging)
                        try verify(expected: expected, at: localStaging)
                        _ = try manager.replaceItemAt(writable, withItemAt: localStaging, options: .usingNewMetadataOnly)
                        do {
                            try verify(expected: expected, at: writable)
                        } catch {
                            let rollback = writable.deletingLastPathComponent()
                                .appendingPathComponent(".LAD-rollback-\(UUID().uuidString).zip")
                            defer { try? manager.removeItem(at: rollback) }
                            try manager.copyItem(at: backupURL, to: rollback)
                            _ = try manager.replaceItemAt(writable, withItemAt: rollback, options: .usingNewMetadataOnly)
                            throw failure("Converted package failed verification and the original archive was restored: \(error.localizedDescription)")
                        }
                    }
                    result.status = "published"
                } catch {
                    result.error = error.localizedDescription
                    progress("Publication failed: \(item.name): \(error.localizedDescription)")
                }
            }
            result.durationSeconds = ProcessInfo.processInfo.systemUptime - start
            published.results.append(result)
            try write(published, to: staging.appendingPathComponent("publish-report.json"))
            try write(published, to: backup.appendingPathComponent("publish-report.json"))
        }
        try write(report, to: backup.appendingPathComponent("migration-report.json"))
        XCTAssertTrue(published.results.allSatisfy { $0.status == "published" || $0.status == "already-published" },
                      "Review publish-report.json for failures; original archive backups are preserved.")
        progress("Publication finished: \(published.results.filter { $0.status == "published" }.count) converted designs published, \(published.thumbnailWarnings) thumbnail warnings.")
    }

    private func verifyBackup(_ url: URL, sha256: String) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              digest(try Data(contentsOf: url)) == sha256 else {
            throw failure("The preserved archive backup is missing, unrelated or changed: \(url.lastPathComponent).")
        }
    }

    @MainActor
    private func requireLADStopped() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "studio.lad.cad").isEmpty else {
            throw failure("Quit LAD before publishing the converted designs.")
        }
        // A development executable can run without a registered app bundle.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "LAD"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 1 else {
            throw failure(process.terminationStatus == 0
                ? "Quit every running LAD process before publishing the converted designs."
                : "Could not confirm that LAD is stopped; publication was canceled.")
        }
    }

    private func verify(expected: ProjectArchive.Snapshot, at url: URL) throws {
        let restored = try ProjectArchive.split(ProjectStore.read(from: url))
        guard restored.metadata == expected.metadata else { throw failure("Converted design metadata differs from the source.") }
        guard restored.assets.count == expected.assets.count else { throw failure("Converted design asset count differs from the source.") }
        for (hash, bytes) in expected.assets {
            guard restored.assets[hash] == bytes else { throw failure("Converted asset bytes differ for \(hash).") }
        }
    }

    private func directory(_ path: String?, name: String) throws -> URL {
        guard let path, path.hasPrefix("/") else { throw failure("Provide an absolute \(name) directory.") }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure("Expected an ordinary directory: \(url.path).") }
    }

    private func coordinatedArchiveRead(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            outcome = Result { try Data(contentsOf: readable) }
        }
        guard let outcome else { throw coordinationError ?? failure("Could not coordinate the source archive read.") }
        return try outcome.get()
    }

    private func coordinatedWrite(_ url: URL, _ body: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writable in
            outcome = Result { try body(writable) }
        }
        guard let outcome else { throw coordinationError ?? failure("Could not coordinate design publication.") }
        try outcome.get()
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func failure(_ description: String) -> NSError {
        NSError(domain: "LAD.DevelopmentMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func progress(_ message: String) {
        print("LAD_MIGRATION \(message)")
        fflush(stdout)
    }
}
