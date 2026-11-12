import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class CodexFileContextTests: XCTestCase {
    private func attachment(_ name: String, path: String? = nil, content: String) -> SourceAttachment {
        let digest = SHA256.hexDigest(Data(content.utf8))
        return SourceAttachment(name: name, path: path ?? "/no-longer-present/\(name)", content: content, sha256: digest)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-file-context-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testLargePCBIsAvailableLocallyButNeverEmbeddedInReferenceManifest() throws {
        try withDirectory { directory in
            let content = "PCB_FULL_SOURCE_BEGIN\n" + String(repeating: "(property \"quoted\" \"text\")\n", count: 35_000) + "PCB_FULL_SOURCE_END"
            let source = attachment("hdmi.kicad_pcb", content: content)
            let context = try CodexFileContext.prepare(current: nil, history: [], attachments: [source], directory: directory)
            let reference = try XCTUnwrap(context.sources.first)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try String(contentsOfFile: reference.readPath, encoding: .utf8), content)
            XCTAssertEqual(reference.name, source.name)
            XCTAssertEqual(reference.path, source.path)
            XCTAssertEqual(reference.sha256, source.sha256)
            XCTAssertEqual(reference.byteCount, content.utf8.count)
            let manifest = String(decoding: try JSONEncoder().encode(context.sources), as: UTF8.self)
            XCTAssertLessThan(manifest.utf8.count, 1_000)
            XCTAssertFalse(manifest.contains("PCB_FULL_SOURCE_BEGIN"))
            XCTAssertFalse(manifest.contains("PCB_FULL_SOURCE_END"))
            XCTAssertFalse(manifest.contains("property"))
            XCTAssertEqual(try permissions(URL(fileURLWithPath: reference.readPath)), 0o600)
            XCTAssertEqual(try permissions(URL(fileURLWithPath: reference.readPath).deletingLastPathComponent()), 0o700)
        }
    }

    func testCurrentProgramsAreLocalAndBinarySTEPIsExcluded() throws {
        var program = ModelSpec.bracket
        program.script = "# PROGRAM_CONTENT_STAYS_LOCAL\nresult = imported_model"
        for original in [ModelSpec.bracket, program] {
            try withDirectory { directory in
                var model = original
                model.sourceSTEP = Data("PRIVATE_STEP_BINARY_SENTINEL".utf8)
                let context = try CodexFileContext.prepare(current: model, history: [], attachments: [], directory: directory)
                let path = try XCTUnwrap(context.currentModelPath)
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let staged = try JSONDecoder().decode(ModelSpec.self, from: data)
                XCTAssertNil(staged.sourceSTEP)
                XCTAssertEqual(staged.script, model.script)
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_STEP_BINARY_SENTINEL"))
                XCTAssertFalse(path.contains("PROGRAM_CONTENT_STAYS_LOCAL"))
                XCTAssertEqual(try permissions(URL(fileURLWithPath: path)), 0o600)
                XCTAssertEqual(try permissions(URL(fileURLWithPath: path).deletingLastPathComponent()), 0o700)
            }
        }
    }

    func testCurrentSnapshotsWinAndLatestHistoricalVersionsStayInOrder() throws {
        try withDirectory { directory in
            let current = attachment("board.kicad_pcb", content: "CURRENT_VERSION")
            let oldCurrent = attachment("board.kicad_pcb", content: "OBSOLETE_VERSION")
            let oldest = attachment("case.fs", content: "OLDEST_CASE")
            let latest = attachment("case.fs", content: "LATEST_CASE")
            let history = [ChatMessage(role: "user", content: "First", attachments: [oldCurrent, oldest]),
                           ChatMessage(role: "user", content: "Last", attachments: [latest])]
            let context = try CodexFileContext.prepare(current: nil, history: history, attachments: [current], directory: directory)
            XCTAssertEqual(context.sources.map(\.name), ["board.kicad_pcb", "case.fs"])
            XCTAssertEqual(try context.sources.map { try String(contentsOfFile: $0.readPath, encoding: .utf8) }, ["CURRENT_VERSION", "LATEST_CASE"])
        }
    }

    func testSkippedNewerVersionNeverResurrectsAnOlderSnapshot() throws {
        try withDirectory { directory in
            let current = (0..<2).map { attachment("current-\($0).fs", content: String(repeating: "x", count: 740_000)) }
            let old = attachment("case.fs", content: "STALE_VERSION")
            let latest = attachment("case.fs", content: String(repeating: "y", count: 740_000))
            let history = [ChatMessage(role: "user", content: "old", attachments: [old]),
                           ChatMessage(role: "user", content: "new", attachments: [latest])]
            let context = try CodexFileContext.prepare(current: nil, history: history, attachments: current, directory: directory)
            XCTAssertEqual(context.sources.map(\.name), ["current-0.fs", "current-1.fs"])
        }
    }

    func testSameBasenamesAndMaliciousNamesCannotEscapeStagingDirectory() throws {
        try withDirectory { directory in
            let inputs = [attachment("board.fs", path: "/a/board.fs", content: "FIRST"),
                          attachment("board.fs", path: "/b/board.fs", content: "SECOND"),
                          attachment("../../outside\n\u{0}.fs", path: "/c/source", content: "THIRD"),
                          attachment("../../directory.bad/extension", path: "/d/source", content: "FOURTH"),
                          attachment("fifth.fs", content: "EXCLUDED")]
            let context = try CodexFileContext.prepare(current: nil, history: [], attachments: inputs, directory: directory)
            XCTAssertEqual(context.sources.count, 4)
            XCTAssertEqual(Set(context.sources.map(\.readPath)).count, 4)
            let expectedParent = directory.appendingPathComponent("context/sources").standardizedFileURL
            for (index, reference) in context.sources.enumerated() {
                let url = URL(fileURLWithPath: reference.readPath)
                XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, expectedParent)
                XCTAssertFalse(url.lastPathComponent.contains("\n"))
                XCTAssertFalse(url.lastPathComponent.contains("\u{0}"))
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), inputs[index].content)
            }
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
