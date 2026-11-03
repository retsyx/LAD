import CryptoKit
import Foundation
import XCTest
@testable import LAD

/// Opt-in measurements of real saved history on disposable package copies.
/// Timing is diagnostic; unchanged dependencies and persisted state are asserted.
final class ProjectAutosaveProfileTests: XCTestCase {
    @MainActor
    func testProfileStateOnlyAutosave() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["LAD_AUTOSAVE_PROFILE_SOURCE"] else {
            throw XCTSkip("Set LAD_AUTOSAVE_PROFILE_SOURCE to an existing .lad package to profile autosave.")
        }
        let sourceURL = URL(fileURLWithPath: source, isDirectory: true).resolvingSymlinksInPath()
        let sourceBefore = try fingerprints(sourceURL, includingRoot: true)
        let target = environment["LAD_AUTOSAVE_PROFILE_TARGET_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let temporary = target.appendingPathComponent("LAD-autosave-profile-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary); ProjectPackage.clearSessionCache() }
        let packageURL = temporary.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: sourceURL, to: packageURL)
        var project = try ProjectAutosaveStore.readProject(from: packageURL)
        XCTAssertFalse(project.revisions.isEmpty, "Profile a saved design with real revision history")
        let projectID = try XCTUnwrap(project.projectID)
        let samples = min(9, max(3, Int(environment["LAD_AUTOSAVE_PROFILE_SAMPLES"] ?? "5") ?? 5))
        let dependencies = try fingerprints(packageURL)
        var changes = [[String]]()

        func verify(grid: Bool, fraction: Double) throws {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: packageURL.appendingPathComponent("project.json"))) as? [String: Any])
            XCTAssertEqual(root["showGrid"] as? Bool, grid)
            XCTAssertEqual(try XCTUnwrap(root["partsPaneFraction"] as? Double), fraction, accuracy: 0.000_001)
            let observed = try fingerprints(packageURL)
            let changed = Set(dependencies.keys).union(observed.keys).filter { dependencies[$0] != observed[$0] }.sorted()
            changes.append(changed)
            XCTAssertTrue(changed.isEmpty, "State-only autosave changed dependency bytes, inode, size or modification time: \(changed)")
        }

        var direct = [Double]()
        for _ in 0..<samples {
            project.showGrid = !(project.showGrid ?? true)
            let start = ProcessInfo.processInfo.systemUptime
            try ProjectStore.write(project, to: packageURL, thumbnail: project.thumbnailData)
            direct.append(ProcessInfo.processInfo.systemUptime - start)
            try verify(grid: project.showGrid!, fraction: project.partsPaneFraction)
        }

        // A fresh coordinated read gives the actor an exact ownership baseline.
        project = try ProjectAutosaveStore.readProject(from: packageURL)
        // Treat the copy as an opened external design so an unnamed design's
        // derived title cannot rename our fixture during autosave.
        let managedDirectory = temporary.appendingPathComponent("Managed", isDirectory: true)
        let actor = ProjectAutosaveStore(rootDirectory: managedDirectory)
        var actorTimes = [Double]()
        for sequence in 1...samples {
            project.showGrid = !(project.showGrid ?? true)
            let start = ProcessInfo.processInfo.systemUptime
            let savedURL = try await actor.write(project: project, projectID: projectID,
                title: project.projectName ?? "Profile", sequence: sequence, preferredURL: packageURL)
            actorTimes.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(savedURL.resolvingSymlinksInPath().path, packageURL.resolvingSymlinksInPath().path)
            try verify(grid: project.showGrid!, fraction: project.partsPaneFraction)
        }

        let appActor = ProjectAutosaveStore(rootDirectory: managedDirectory)
        let state = AppState(autosaveStore: appActor)
        state.loadProject(try ProjectAutosaveStore.readProject(from: packageURL), from: packageURL)
        // Cancel synchronously before the deferred CAD replay task can run.
        // Saved recipes, chat and audit history remain intact for the save path.
        state.cancel()
        try await waitForSave(state)
        await state.prepareToQuit()
        try await waitForSave(state)
        XCTAssertFalse(state.isWorking)
        let settledDependencies = try fingerprints(packageURL)
        XCTAssertEqual(dependencies, settledDependencies)

        var grid = [Double](), gridSynchronous = [Double](), sidebar = [Double]()
        for _ in 0..<samples {
            let start = ProcessInfo.processInfo.systemUptime
            state.showGrid.toggle()
            gridSynchronous.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertTrue(state.hasUnsavedChanges)
            try await waitForSave(state)
            grid.append(ProcessInfo.processInfo.systemUptime - start)
            try verify(grid: state.showGrid, fraction: state.partsPaneFraction)
        }
        for index in 0..<samples {
            let start = ProcessInfo.processInfo.systemUptime
            state.setPartsPaneFraction(0.55 + Double(index) * 0.01)
            XCTAssertTrue(state.hasUnsavedChanges)
            try await waitForSave(state)
            sidebar.append(ProcessInfo.processInfo.systemUptime - start)
            try verify(grid: state.showGrid, fraction: state.partsPaneFraction)
        }
        await state.prepareToQuit()
        let sourceAfter = try fingerprints(sourceURL, includingRoot: true)
        XCTAssertEqual(sourceBefore, sourceAfter, "Profiling must never change the source package")
        let final = try ProjectStore.read(from: packageURL)
        XCTAssertEqual(final.showGrid, state.showGrid)
        XCTAssertEqual(final.partsPaneFraction, state.partsPaneFraction)
        XCTAssertEqual(final.revisions.map(\.model), project.revisions.map(\.model))
        XCTAssertEqual(final.messages, project.messages)
        XCTAssertEqual(final.taskAudits, project.taskAudits)

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let report: [String: Any] = [
            "project": sourceURL.lastPathComponent,
            "sourceRootSHA256": try XCTUnwrap(sourceBefore["project.json"]).digest,
            "sourceUnchanged": sourceBefore == sourceAfter,
            "targetDirectory": target.path,
            "architecture": "arm64",
            "samples": samples,
            "revisions": project.revisions.count,
            "messages": project.messages.count,
            "tasks": project.taskAudits?.count ?? 0,
            "rootManifestBytes": try XCTUnwrap(sourceBefore["project.json"]).bytes,
            "dependencyCount": dependencies.count,
            "dependencyBytes": dependencies.values.reduce(UInt64(0)) { $0 + $1.bytes },
            "directPackageSeconds": direct,
            "directPackageMedianSeconds": median(direct),
            "coordinatedActorSeconds": actorTimes,
            "coordinatedActorMedianSeconds": median(actorTimes),
            "gridAutosaveSeconds": grid,
            "gridAutosaveMedianSeconds": median(grid),
            "gridSynchronousSeconds": gridSynchronous,
            "sidebarAutosaveSeconds": sidebar,
            "sidebarAutosaveMedianSeconds": median(sidebar),
            "sidebarDebounceSeconds": 0.650,
            "changedDependenciesPerSample": changes,
            "measurement": "Grid/sidebar change through AppState snapshot, coordinated actor write, and hasUnsavedChanges/saveStatus clearing; no CAD replay or timing thresholds. Dependency verification is outside timing. Actor includes ownership/receipt and NSFileCoordinator; direct write excludes coordination."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = URL(fileURLWithPath: environment["LAD_AUTOSAVE_PROFILE_REPORT"] ?? "/tmp/lad-autosave-profile.json")
        try data.write(to: reportURL, options: .atomic)
        print("LAD_AUTOSAVE_PROFILE \(String(decoding: data, as: UTF8.self))")
        print("LAD_AUTOSAVE_PROFILE_REPORT \(reportURL.path)")
    }

    @MainActor
    private func waitForSave(_ state: AppState) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while state.hasUnsavedChanges || state.saveStatus != nil {
            if let conflict = state.saveConflict { throw conflict }
            if let status = state.saveStatus, status != "Saving…" {
                XCTFail("Autosave failed: \(status)")
                throw CocoaError(.fileWriteUnknown)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for actual autosave completion")
                throw CocoaError(.fileWriteUnknown)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct Fingerprint: Equatable {
        var digest: String
        var inode: UInt64
        var bytes: UInt64
        var modified: Date
    }

    private func fingerprints(_ package: URL, includingRoot: Bool = false) throws -> [String: Fingerprint] {
        let resolved = package.resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey]))
        var result = [String: Fingerprint]()
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(resolved.path.count + 1))
            guard includingRoot || relative != "project.json" else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            result[relative] = Fingerprint(digest: digest,
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value,
                bytes: try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value,
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date))
        }
        return result
    }
}
