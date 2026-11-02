import XCTest
import Darwin
@testable import LAD

final class EngineArtifactTests: XCTestCase {
    private func withFolder(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-artifact-test-\(UUID())")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(EngineArtifact.canonicalDirectory(root), EngineArtifact.canonicalDirectory(output))
    }

    func testRegularAssetsAreBoundedAndLogsReadOnlyTheirTail() throws {
        try withFolder { _, folder in
            let file = folder.appendingPathComponent("result.json")
            try Data("0123456789".utf8).write(to: file)
            XCTAssertEqual(try EngineArtifact.read(file, in: folder, maximumBytes: 10), Data("0123456789".utf8))
            XCTAssertThrowsError(try EngineArtifact.read(file, in: folder, maximumBytes: 9))
            XCTAssertEqual(try EngineArtifact.tail(file, in: folder, maximumBytes: 4), Data("6789".utf8))
            try Data().write(to: file)
            XCTAssertEqual(try EngineArtifact.tail(file, in: folder, maximumBytes: 4), Data())
        }
    }

    func testGeometryArtifactsSupport512MBAndRejectLargerFilesBeforeReading() throws {
        try withFolder { _, folder in
            let file = folder.appendingPathComponent("model.brep")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            // Sparse files exercise the actual file-size boundary without
            // allocating or reading a full native geometry payload.
            try handle.truncate(atOffset: 512_000_000)
            try handle.seek(toOffset: 512_000_000 - 4)
            try handle.write(contentsOf: Data("END\n".utf8))
            XCTAssertEqual(try EngineArtifact.tail(file, in: folder, maximumBytes: 4), Data("END\n".utf8))
            try handle.truncate(atOffset: 512_000_001)
            XCTAssertThrowsError(try EngineArtifact.tail(file, in: folder, maximumBytes: 4))
            XCTAssertThrowsError(try EngineArtifact.read(file, in: folder, maximumBytes: 512_000_001))
        }
    }

    func testSymbolicLinksHardLinksAndPipesAreRejectedWithoutFollowingThem() throws {
        try withFolder { root, folder in
            let outside = root.appendingPathComponent("private.txt")
            try Data("private fixture".utf8).write(to: outside)
            let symlink = folder.appendingPathComponent("result.json")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
            XCTAssertThrowsError(try EngineArtifact.read(symlink, in: folder, maximumBytes: 100))
            XCTAssertThrowsError(try EngineArtifact.tail(symlink, in: folder, maximumBytes: 100))
            let hardlink = folder.appendingPathComponent("model.step")
            try FileManager.default.linkItem(at: outside, to: hardlink)
            XCTAssertThrowsError(try EngineArtifact.read(hardlink, in: folder, maximumBytes: 100))
            let pipe = folder.appendingPathComponent("stderr.log")
            XCTAssertEqual(Darwin.mkfifo(pipe.path, 0o600), 0)
            XCTAssertThrowsError(try EngineArtifact.tail(pipe, in: folder, maximumBytes: 100))
        }
    }

    func testReplacingTheOutputFolderWithASymlinkCannotReadAnOutsideAsset() throws {
        try withFolder { root, folder in
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("private fixture".utf8).write(to: outside.appendingPathComponent("result.json"))
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
            XCTAssertThrowsError(try EngineArtifact.read(folder.appendingPathComponent("result.json"), in: folder, maximumBytes: 100))
        }
    }
}
