import CryptoKit
import Foundation
import XCTest
@testable import LAD

/// Opt-in end-to-end measurements on disposable copies. No machine-specific
/// timing threshold: the regression assertion is unchanged dependency files.
final class ProjectPackageProfileTests: XCTestCase {
    func testProfileIncrementalSave() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["LAD_PACKAGE_PROFILE_SOURCE"] else {
            throw XCTSkip("Set LAD_PACKAGE_PROFILE_SOURCE to a development archive to profile incremental package saves.")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let sourceData = try Data(contentsOf: sourceURL)
        let sourceDigest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let original = try ProjectStore.decode(sourceData)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-save-profile-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary); ProjectPackage.clearSessionCache() }
        let legacyURL = temporary.appendingPathComponent("Archive.lad")
        let packageURL = temporary.appendingPathComponent("Package.lad", isDirectory: true)
        let count = min(9, max(3, Int(environment["LAD_PACKAGE_PROFILE_SAMPLES"] ?? "5") ?? 5))
        var legacy = original
        var legacySeconds = [Double]()
        for index in 0..<count {
            legacy.showGrid = !(legacy.showGrid ?? true)
            legacy.partsPaneFraction = 0.55 + Double(index) * 0.01
            let start = ProcessInfo.processInfo.systemUptime
            let data = try ProjectStore.encode(legacy)
            try coordinatedWrite(to: legacyURL) { try data.write(to: $0, options: .atomic) }
            legacySeconds.append(ProcessInfo.processInfo.systemUptime - start)
        }

        var incremental = original
        let initialStart = ProcessInfo.processInfo.systemUptime
        try coordinatedWrite(to: packageURL) { try ProjectStore.write(incremental, to: $0) }
        let initialSeconds = ProcessInfo.processInfo.systemUptime - initialStart
        let dependencies = try dependencyFingerprints(packageURL)
        var incrementalSeconds = [Double](), changes = [[String]]()
        for index in 0..<count {
            incremental.showGrid = !(incremental.showGrid ?? true)
            incremental.partsPaneFraction = 0.55 + Double(index) * 0.01
            let start = ProcessInfo.processInfo.systemUptime
            try coordinatedWrite(to: packageURL) { try ProjectStore.write(incremental, to: $0) }
            incrementalSeconds.append(ProcessInfo.processInfo.systemUptime - start)
            let observed = try dependencyFingerprints(packageURL)
            let changed = Set(dependencies.keys).union(observed.keys).filter { dependencies[$0] != observed[$0] }.sorted()
            changes.append(changed)
            XCTAssertTrue(changed.isEmpty, "A state-only save changed dependency content, inode or modification time: \(changed)")
        }
        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: packageURL)
        XCTAssertEqual(restored.messages, incremental.messages)
        XCTAssertEqual(restored.taskAudits, incremental.taskAudits)
        XCTAssertEqual(restored.revisions.map(\.model), incremental.revisions.map(\.model))
        XCTAssertEqual(restored.showGrid, incremental.showGrid)
        XCTAssertEqual(restored.partsPaneFraction, incremental.partsPaneFraction)
        let sourceAfter = SHA256.hash(data: try Data(contentsOf: sourceURL)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sourceAfter, sourceDigest, "The profile must never modify its source archive")
        func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
        let legacyMedian = median(legacySeconds), incrementalMedian = median(incrementalSeconds)
        let report: [String: Any] = [
            "project": sourceURL.lastPathComponent,
            "sourceArchiveSHA256": sourceDigest,
            "sourceUnchanged": sourceAfter == sourceDigest,
            "samples": count,
            "architecture": "arm64",
            "coordination": "Both save paths coordinate the document URL through NSFileCoordinator.",
            "legacyOperation": "Complete ProjectStore.encode validation, hashing, JSON/base64, ZIP compression and atomic archive write.",
            "incrementalOperation": "Warm grid/sidebar update, immutable dependency reuse, durable atomic project.json publication.",
            "verificationOutsideTimedSamples": "Every dependency SHA-256, inode, byte count and modification time compared after each incremental save.",
            "legacySeconds": legacySeconds,
            "incrementalSeconds": incrementalSeconds,
            "legacyMedianSeconds": legacyMedian,
            "incrementalMedianSeconds": incrementalMedian,
            "medianSpeedup": legacyMedian / incrementalMedian,
            "initialPackageCreationSeconds": initialSeconds,
            "legacyArchiveBytes": try fileSize(legacyURL),
            "rootManifestBytes": try fileSize(packageURL.appendingPathComponent("project.json")),
            "dependencyCount": dependencies.count,
            "storedDependencyBytes": dependencies.values.reduce(UInt64(0)) { $0 + $1.bytes },
            "changedDependenciesPerSample": changes,
            "revisions": original.revisions.count,
            "messages": original.messages.count,
            "tasks": original.taskAudits?.count ?? 0
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = URL(fileURLWithPath: environment["LAD_PACKAGE_PROFILE_REPORT"] ?? "/tmp/lad-incremental-save-profile.json")
        try data.write(to: reportURL, options: .atomic)
        print("LAD_PACKAGE_SAVE_PROFILE \(String(decoding: data, as: UTF8.self))")
        print("LAD_PACKAGE_SAVE_PROFILE_REPORT \(reportURL.path)")
    }

    func testDiagnoseExactMetadataRoundtrip() throws {
        guard let source = ProcessInfo.processInfo.environment["LAD_PACKAGE_ROUNDTRIP_SOURCE"] else {
            throw XCTSkip("Set LAD_PACKAGE_ROUNDTRIP_SOURCE to inspect an exact archive/package metadata roundtrip.")
        }
        let project = try ProjectStore.decode(Data(contentsOf: URL(fileURLWithPath: source)))
        let expected = try ProjectArchive.split(project)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-roundtrip-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let package = temporary.appendingPathComponent("Copy.lad", isDirectory: true)
        try ProjectStore.write(project, to: package)
        ProjectPackage.clearSessionCache()
        let actual = try ProjectArchive.split(ProjectStore.read(from: package))
        try expected.metadata.write(to: URL(fileURLWithPath: "/tmp/lad-roundtrip-expected.json"), options: .atomic)
        try actual.metadata.write(to: URL(fileURLWithPath: "/tmp/lad-roundtrip-actual.json"), options: .atomic)
        XCTAssertEqual(expected.assets, actual.assets)
        XCTAssertEqual(expected.metadata, actual.metadata, "Inspect /tmp/lad-roundtrip-{expected,actual}.json for precise differences")
    }

    private struct Fingerprint: Equatable {
        var digest: String
        var inode: UInt64
        var bytes: UInt64
        var modified: Date
    }

    private func dependencyFingerprints(_ package: URL) throws -> [String: Fingerprint] {
        let resolved = package.resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey]))
        var result = [String: Fingerprint]()
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(resolved.path.count + 1))
            guard relative != "project.json" else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            result[relative] = Fingerprint(digest: digest,
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value,
                bytes: try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value,
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date))
        }
        return result
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).uint64Value
    }

    private func coordinatedWrite(to url: URL, operation: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?, result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &error) { writable in
            result = Result { try operation(writable) }
        }
        guard let result else { throw error ?? CocoaError(.fileWriteUnknown) }
        try result.get()
    }
}
