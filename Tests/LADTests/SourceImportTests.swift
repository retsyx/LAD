import CryptoKit
import Darwin
import XCTest
@testable import LAD

final class SourceImportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-source-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testExtractsFileURLsTildeAndDeduplicatesWithoutReading() {
        let prompt = "Import file:///tmp/My%20Part.fs and /tmp/My Part.fs; also ~/Designs/case.fs."
        let urls = SourceImport.referencedURLs(in: prompt)
        XCTAssertEqual(urls.map(\.path), ["/tmp/My Part.fs", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Designs/case.fs").path])
        XCTAssertTrue(SourceImport.referencedURLs(in: "https://example.com/design.fs onshape/std/common.fs /tmp/design.fsx").isEmpty)
        XCTAssertTrue(SourceImport.referencedURLs(in: "https://example.com/-/part.fs").isEmpty)
    }

    func testLoadsExactUTF8TextAndStableHashAndCodableSnapshot() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("Part ünicode.fs")
        let content = "FeatureScript 2500;\n// café and dimensions\nconst radius = 12.5 * millimeter;\n"
        try Data(content.utf8).write(to: source)
        let result = try SourceImport.load(urls: [source, source])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Part ünicode.fs")
        XCTAssertEqual(result[0].path, source.resolvingSymlinksInPath().path)
        XCTAssertEqual(result[0].content, content)
        XCTAssertEqual(result[0].fileExtension, "fs")
        XCTAssertEqual(result[0].sha256, SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try JSONDecoder().decode([SourceAttachment].self, from: JSONEncoder().encode(result)), result)
        // Source snapshot remains useful after the original file disappears.
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(result[0].content, content)
    }

    func testMissingInvalidEmptyAndUnsupportedFilesFailWithPaths() throws {
        let directory = try temporaryDirectory()
        let missing = directory.appendingPathComponent("missing.fs")
        XCTAssertThrowsError(try SourceImport.load(urls: [missing])) { XCTAssertTrue($0.localizedDescription.contains(missing.path)) }
        for (name, bytes) in [("empty.fs", Data(" \n\t".utf8)), ("invalid.fs", Data([0xff, 0xfe, 0xff])), ("binary.fs", Data([65, 0, 66])), ("part.pdf", Data("source".utf8))] {
            let file = directory.appendingPathComponent(name)
            try bytes.write(to: file)
            XCTAssertThrowsError(try SourceImport.load(urls: [file]), name)
        }
        XCTAssertThrowsError(try SourceImport.load(urls: [URL(string: "https://example.com/part.fs")!]))
        XCTAssertThrowsError(try SourceImport.load(urls: [URL(string: "file://other-computer/tmp/part.fs")!]))
    }

    func testRejectsDirectoriesPipesAndOversizeSourcesWithoutBlocking() throws {
        let directory = try temporaryDirectory()
        let folder = directory.appendingPathComponent("folder.fs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SourceImport.load(urls: [folder]))
        let fifo = directory.appendingPathComponent("pipe.fs")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let start = Date()
        XCTAssertThrowsError(try SourceImport.load(urls: [fifo]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let large = directory.appendingPathComponent("large.fs")
        try Data(repeating: 65, count: SourceImport.maximumFileBytes + 1).write(to: large)
        XCTAssertThrowsError(try SourceImport.load(urls: [large]))
    }

    func testEnforcesTotalAndAttachmentCountLimits() throws {
        let directory = try temporaryDirectory()
        var urls: [URL] = []
        for index in 0..<5 {
            let file = directory.appendingPathComponent("part-\(index).fs")
            try Data(repeating: 65, count: index < 3 ? 750_000 : 1).write(to: file)
            urls.append(file)
        }
        XCTAssertThrowsError(try SourceImport.load(urls: Array(urls.prefix(3))))
        XCTAssertThrowsError(try SourceImport.load(urls: urls))
        XCTAssertEqual(try SourceImport.load(urls: Array(urls.prefix(2))).count, 2)
    }

    func testImportsKiCadBoardWithoutTruncatingItsContents() throws {
        let directory = try temporaryDirectory()
        let board = directory.appendingPathComponent("Main board.kicad_pcb")
        let contents = "(kicad_pcb\n  (version 20241229)\n; " + String(repeating: "x", count: 948_780) + "\n)\n"
        try Data(contents.utf8).write(to: board)
        let urls = SourceImport.referencedURLs(in: "Use \"\(board.path)\".")
        XCTAssertEqual(urls, [board])
        let attachment = try XCTUnwrap(SourceImport.load(urls: urls).first)
        XCTAssertEqual(attachment.fileExtension, "kicad_pcb")
        XCTAssertEqual(attachment.content, contents)
    }
}
