import Darwin
import Foundation
import XCTest
@testable import LAD

final class ProjectFolderIconTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-folder-icon-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeFinderInfo(_ data: Data, to url: URL) throws {
        let result = data.withUnsafeBytes {
            setxattr(url.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func customFinderInfo() -> Data {
        var info = Data(repeating: 0, count: 32)
        info[8] = 0x04 // Finder's persistent hasCustomIcon flag.
        return info
    }

    func testConcurrentProjectsApplyMissingFolderIconOnceOnMainThread() async throws {
        let root = try folder()
        let recorder = await MainActor.run { Recorder() }
        let coordinator = await MainActor.run {
            ProjectFolderIconCoordinator { url in
                XCTAssertTrue(Thread.isMainThread)
                recorder.folders.append(url)
                do { try self.writeFinderInfo(self.customFinderInfo(), to: url); return true }
                catch { XCTFail("Could not persist test icon metadata: \(error)"); return false }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { await coordinator.apply(to: root) }
            }
        }
        await MainActor.run {
            XCTAssertEqual(recorder.folders, [root.standardizedFileURL])
        }
    }

    @MainActor
    func testPersistedCustomIconIsPreservedAcrossCoordinatorInstances() throws {
        let root = try folder()
        var existing = customFinderInfo()
        existing[9] = 0x10 // Preserve unrelated Finder flags as well.
        try writeFinderInfo(existing, to: root)
        var attempts = 0
        for _ in 0..<2 {
            let coordinator = ProjectFolderIconCoordinator { _ in attempts += 1; return true }
            coordinator.apply(to: root)
        }
        XCTAssertEqual(attempts, 0, "An existing custom icon must survive reopening LAD without being rewritten")
        var actual = Data(repeating: 0, count: 32)
        let count = actual.withUnsafeMutableBytes {
            getxattr(root.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        XCTAssertEqual(count, existing.count)
        XCTAssertEqual(actual, existing)
    }

    @MainActor
    func testMissingIconRetriesFailureAndBrandsReplacementFolder() throws {
        let root = try folder()
        let target = root.appendingPathComponent("LAD", isDirectory: true)
        let replacement = root.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        var attempts = 0
        let coordinator = ProjectFolderIconCoordinator { url in
            attempts += 1
            guard attempts > 1 else { return false }
            do { try self.writeFinderInfo(self.customFinderInfo(), to: url); return true }
            catch { XCTFail("Could not persist test icon metadata: \(error)"); return false }
        }
        coordinator.apply(to: target)
        coordinator.apply(to: target)
        coordinator.apply(to: target)
        XCTAssertEqual(attempts, 2, "Only missing icon metadata should trigger an update")

        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: replacement, to: target)
        coordinator.apply(to: target)
        coordinator.apply(to: target)
        XCTAssertEqual(attempts, 3, "A replacement folder without a custom icon must receive one")
    }

    @MainActor
    func testDocumentsAndSymlinksNeverReceiveIconMetadata() throws {
        let root = try folder()
        let document = root.appendingPathComponent("Project.lad")
        let link = root.appendingPathComponent("Linked", isDirectory: true)
        try Data("project".utf8).write(to: document)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        var attempts = 0
        let coordinator = ProjectFolderIconCoordinator { _ in attempts += 1; return true }
        coordinator.apply(to: document)
        coordinator.apply(to: link)
        coordinator.apply(to: root.appendingPathComponent("Missing", isDirectory: true))
        XCTAssertEqual(attempts, 0)
    }

    @MainActor
    private final class Recorder {
        var folders: [URL] = []
    }
}
