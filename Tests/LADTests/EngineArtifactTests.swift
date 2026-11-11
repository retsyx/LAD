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
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("DBRep_DrawableShape\n".utf8))
            let boundary = try EngineArtifact.boundaries(file, in: folder, headerBytes: Data("DBRep_DrawableShape\n".utf8).count, footerBytes: 4)
            XCTAssertEqual(boundary.size, 512_000_000)
            XCTAssertEqual(boundary.header, Data("DBRep_DrawableShape\n".utf8))
            XCTAssertEqual(boundary.footer, Data("END\n".utf8))
            XCTAssertEqual(try EngineArtifact.tail(file, in: folder, maximumBytes: 4), Data("END\n".utf8))
            try handle.truncate(atOffset: 512_000_001)
            XCTAssertThrowsError(try EngineArtifact.tail(file, in: folder, maximumBytes: 4))
            XCTAssertThrowsError(try EngineArtifact.read(file, in: folder, maximumBytes: 512_000_001))
            XCTAssertThrowsError(try EngineArtifact.boundaries(file, in: folder, headerBytes: 19))
        }
    }

    func testMarkerReadsHandleShortFilesAndRejectEmptyFiles() throws {
        try withFolder { _, folder in
            let file = folder.appendingPathComponent("model.step")
            let data = Data("ISO-10303-21;\nEND-ISO-10303-21;\n".utf8)
            try data.write(to: file)
            let boundary = try EngineArtifact.boundaries(file, in: folder, headerBytes: 512, footerBytes: 512)
            XCTAssertEqual(boundary.size, data.count)
            XCTAssertEqual(boundary.header, data)
            XCTAssertEqual(boundary.footer, data)
            let headerOnly = try EngineArtifact.boundaries(file, in: folder, headerBytes: Data("ISO-10303-21;".utf8).count)
            XCTAssertEqual(headerOnly.header, Data("ISO-10303-21;".utf8))
            XCTAssertTrue(headerOnly.footer.isEmpty)
            try Data().write(to: file)
            XCTAssertThrowsError(try EngineArtifact.boundaries(file, in: folder, headerBytes: 512, footerBytes: 512))
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
            XCTAssertThrowsError(try EngineArtifact.boundaries(symlink, in: folder, headerBytes: 19))
            let hardlink = folder.appendingPathComponent("model.step")
            try FileManager.default.linkItem(at: outside, to: hardlink)
            XCTAssertThrowsError(try EngineArtifact.read(hardlink, in: folder, maximumBytes: 100))
            XCTAssertThrowsError(try EngineArtifact.boundaries(hardlink, in: folder, headerBytes: 512, footerBytes: 512))
            let pipe = folder.appendingPathComponent("stderr.log")
            XCTAssertEqual(Darwin.mkfifo(pipe.path, 0o600), 0)
            XCTAssertThrowsError(try EngineArtifact.tail(pipe, in: folder, maximumBytes: 100))
            XCTAssertThrowsError(try EngineArtifact.boundaries(pipe, in: folder, headerBytes: 19))
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
            XCTAssertThrowsError(try EngineArtifact.boundaries(folder.appendingPathComponent("result.json"), in: folder, headerBytes: 19))
        }
    }
}
