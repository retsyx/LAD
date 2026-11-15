import Foundation
import XCTest
@testable import LAD

final class CADValidatedInputCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-input-cache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func build() throws -> URL {
        let folder = root.appendingPathComponent("build-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return try EngineArtifact.canonicalDirectory(folder)
    }

    private func produce(_ name: String, bytes: Int, in folder: URL, header: String = "DBRep_DrawableShape\n") throws -> URL {
        let url = folder.appendingPathComponent(name)
        var data = Data(header.utf8)
        data.append(Data(repeating: 65, count: max(0, bytes - data.count)))
        try data.write(to: url)
        return url
    }

    private func key(_ text: String, runtime: String = "/runtime/python") -> CADValidatedInputCache.Key {
        .init(data: Data(text.utf8), format: "step", runtime: runtime)
    }

    func testKeptCopiesAreStagedForTheSameInputAndRuntimeOnly() throws {
        let cache = CADValidatedInputCache(root: root)
        let first = try build()
        let produced = try produce("input-000.validated.brep", bytes: 64, in: first)
        cache.store(key("part"), from: produced, in: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: produced.path), "The copy moves out of the build folder.")
        let second = try build()
        let staged = second.appendingPathComponent("input-000.validated.brep")
        XCTAssertTrue(cache.stage(key("part"), to: staged))
        XCTAssertEqual(try Data(contentsOf: staged).prefix(20), Data("DBRep_DrawableShape\n".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: staged.path)[.referenceCount] as? Int, 1)
        XCTAssertFalse(cache.stage(key("other"), to: second.appendingPathComponent("a.brep")))
        XCTAssertFalse(cache.stage(key("part", runtime: "/other/python"), to: second.appendingPathComponent("b.brep")))
        XCTAssertEqual(cache.stagedCopies, 1)
    }

    func testOnlyNativeCopiesAreKept() throws {
        let cache = CADValidatedInputCache(root: root)
        let folder = try build()
        cache.store(key("part"), from: try produce("input-000.validated.brep", bytes: 64, in: folder, header: "ISO-10303-21;\n"), in: folder)
        XCTAssertFalse(cache.stage(key("part"), to: folder.appendingPathComponent("staged.brep")))
    }

    func testLeastRecentlyUsedCopiesAreEvictedBeyondTheSizeLimit() throws {
        let cache = CADValidatedInputCache(root: root, maximumBytes: 250)
        let folder = try build()
        cache.store(key("a"), from: try produce("a.validated.brep", bytes: 100, in: folder), in: folder)
        cache.store(key("b"), from: try produce("b.validated.brep", bytes: 100, in: folder), in: folder)
        XCTAssertTrue(cache.stage(key("a"), to: folder.appendingPathComponent("a-staged.brep")))
        cache.store(key("c"), from: try produce("c.validated.brep", bytes: 100, in: folder), in: folder)
        XCTAssertTrue(cache.stage(key("a"), to: folder.appendingPathComponent("a-again.brep")))
        XCTAssertFalse(cache.stage(key("b"), to: folder.appendingPathComponent("b-staged.brep")))
        XCTAssertTrue(cache.stage(key("c"), to: folder.appendingPathComponent("c-staged.brep")))
    }
}
