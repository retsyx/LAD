import Foundation
import XCTest
@testable import LAD

final class STEPExportCacheTests: XCTestCase {
    func testCacheIsBoundedByTotalBytesAndEntriesInLeastRecentlyUsedOrder() {
        let cache = STEPExportCache(maximumBytes: 100, maximumEntries: 3)
        let owner = URL(fileURLWithPath: "/tmp/LAD-build-owner", isDirectory: true)
        cache.store([Data(count: 40)], for: "a", owner: owner)
        cache.store([Data(count: 20), Data(count: 20)], for: "b", owner: owner)
        XCTAssertEqual(cache.byteCount, 80)
        XCTAssertNotNil(cache.data(for: "a"), "Reading refreshes recency.")
        cache.store([Data(count: 30)], for: "c", owner: owner)
        XCTAssertNil(cache.data(for: "b"), "The least recently used entry makes room within the byte bound.")
        XCTAssertEqual(cache.byteCount, 70)
        cache.store([Data(count: 10)], for: "d", owner: owner)
        cache.store([Data(count: 10)], for: "e", owner: owner)
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.data(for: "a"))
        XCTAssertEqual(cache.data(for: "e")?.first?.count, 10)

        cache.store([Data(count: 101)], for: "oversized", owner: owner)
        XCTAssertNil(cache.data(for: "oversized"), "A single export larger than the bound is never retained.")
        XCTAssertEqual(cache.count, 3, "An uncacheable export must not evict others.")
        cache.store([Data(count: 15)], for: "e", owner: owner)
        XCTAssertEqual(cache.data(for: "e")?.first?.count, 15, "Replacing a key keeps one accounted entry.")
        XCTAssertEqual(cache.byteCount, 30 + 10 + 15)
    }

    func testReleasingBuildArtifactsDropsTheirExportsFromTheSharedCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-step-cache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let released = "released-\(UUID())", retained = "retained-\(UUID())"
        var first: EngineBuildArtifacts? = try EngineBuildArtifacts.create(in: root, token: UUID(), containsSTEP: false)
        let second = try EngineBuildArtifacts.create(in: root, token: UUID(), containsSTEP: false)
        STEPExportCache.shared.store([Data("ISO-10303-21;".utf8)], for: released, owner: try XCTUnwrap(first).folder)
        STEPExportCache.shared.store([Data("ISO-10303-21;".utf8)], for: retained, owner: second.folder)
        defer { STEPExportCache.shared.removeAll(ownedBy: second.folder) }
        XCTAssertNotNil(STEPExportCache.shared.data(for: released))
        first = nil
        XCTAssertNil(STEPExportCache.shared.data(for: released), "Released geometry must not keep its STEP bytes.")
        XCTAssertNotNil(STEPExportCache.shared.data(for: retained))
        XCTAssertLessThanOrEqual(STEPExportCache.shared.byteCount, ProjectStore.maximumSTEPBytes)
    }
}
