import XCTest
@testable import LAD

/// Parsed package sessions are bounded, least recently used first, follow
/// renames and are released when their design closes.
final class ProjectPackageSessionCacheTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        ProjectPackage.clearSessionCache()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-session-cache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        ProjectPackage.clearSessionCache()
    }

    private func project() -> LADProject {
        let revision = ProjectRevision(model: .bracket, parts: [PartNode(id: "body", name: "Body", solidIndices: [0])])
        return LADProject(messages: [ChatMessage(role: "user", content: "Create a bracket")], revisions: [revision],
                          selectedRevisionID: revision.id, projectID: UUID())
    }

    /// Writes the project again and reports whether its previous commit had to
    /// be parsed from disk.
    @discardableResult
    private func save(_ project: inout LADProject, to url: URL) throws -> Bool {
        project.partsPaneFraction = project.partsPaneFraction == 0.5 ? 0.6 : 0.5
        var reloaded = false
        _ = try ProjectPackage.write(project, to: url, didFinish: { reloaded = $0.reloadedPrevious })
        return reloaded
    }

    func testEvictsLeastRecentlyUsedDesignInsteadOfAlphabeticallyFirst() throws {
        let names = (0...ProjectPackage.maximumCachedSessions).map { String(UnicodeScalar(UInt8(65 + $0))) }
        var projects = names.map { _ in project() }
        let urls = names.map { folder.appendingPathComponent("\($0).lad", isDirectory: true) }
        for index in 0..<ProjectPackage.maximumCachedSessions { try save(&projects[index], to: urls[index]) }
        XCTAssertFalse(try save(&projects[0], to: urls[0]), "A cached design reuses its session")
        // One more design exceeds the bound. The least recently used design
        // is B, although A sorts first.
        try save(&projects[names.count - 1], to: urls[names.count - 1])
        XCTAssertFalse(try save(&projects[0], to: urls[0]), "The recently used design must stay cached")
        XCTAssertTrue(try save(&projects[1], to: urls[1]), "The least recently used design is evicted")
    }

    func testRenameKeepsSessionAndClosingReleasesIt() throws {
        var design = project()
        let original = folder.appendingPathComponent("Original.lad", isDirectory: true)
        let renamed = folder.appendingPathComponent("Renamed.lad", isDirectory: true)
        try save(&design, to: original)
        try ProjectStore.rename(original, to: renamed)
        XCTAssertFalse(try save(&design, to: renamed), "A renamed design keeps its parsed session")
        ProjectStore.releaseCache(for: renamed)
        XCTAssertTrue(try save(&design, to: renamed), "A released design reloads from disk")
        XCTAssertEqual(try ProjectStore.read(from: renamed).partsPaneFraction, design.partsPaneFraction)
    }

    func testIdentityAndComparisonReadsDoNotCacheOtherDesigns() throws {
        var design = project()
        let url = folder.appendingPathComponent("Other.lad", isDirectory: true)
        try save(&design, to: url)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.projectID(at: url), design.projectID)
        XCTAssertEqual(try ProjectStore.read(from: url, caching: false).projectID, design.projectID)
        XCTAssertTrue(try save(&design, to: url), "Identity checks and comparisons must not cache a session")
        _ = try ProjectStore.read(from: url)
        XCTAssertFalse(try save(&design, to: url), "Opening a design caches it for its next autosave")
    }
}
