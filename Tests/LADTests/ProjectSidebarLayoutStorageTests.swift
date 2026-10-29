import Foundation
import XCTest
@testable import LAD

final class ProjectSidebarLayoutStorageTests: XCTestCase {
    func testNewAndUnspecifiedProjectsUseIndependentThreeQuarterPartsPreference() throws {
        let empty = LADProject(messages: [], revisions: [], selectedRevisionID: nil)
        XCTAssertEqual(empty.partsPaneFraction, 0.75)
        var other = empty
        other.partsPaneFraction = 0.4
        XCTAssertEqual(empty.partsPaneFraction, 0.75)
        XCTAssertEqual(LADProject(messages: [], revisions: [], selectedRevisionID: nil).partsPaneFraction, 0.75)
        var manifest = try archive(ProjectStore.encode(empty))
        XCTAssertEqual(manifest["partsPaneFraction"] as? Double, 0.75)
        manifest.removeValue(forKey: "partsPaneFraction")
        let restored = try ProjectStore.decode(compressed(manifest))
        XCTAssertEqual(restored.partsPaneFraction, 0.75)
        XCTAssertTrue(restored.revisions.isEmpty)
        XCTAssertTrue(restored.messages.isEmpty)
        manifest["partsPaneFraction"] = NSNull()
        XCTAssertEqual(try ProjectStore.decode(compressed(manifest)).partsPaneFraction, 0.75)
    }

    func testZIPAndSaveNewRetainPreferredPartsFractionWithoutChangingHistory() throws {
        var original = project()
        original.partsPaneFraction = 0.62
        let data = try ProjectStore.encode(original)
        XCTAssertEqual(data.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        XCTAssertEqual(try archive(data)["partsPaneFraction"] as? Double, 0.62)
        let fullCopy = try ProjectStore.decode(data)
        XCTAssertEqual(fullCopy.partsPaneFraction, 0.62)
        XCTAssertEqual(fullCopy.revisions.map(\.id), original.revisions.map(\.id))
        XCTAssertEqual(fullCopy.selectedRevisionID, original.selectedRevisionID)
        let newCopy = try SaveNewProject.snapshot(from: original)
        let savedNew = try ProjectStore.decode(ProjectStore.encode(newCopy))
        XCTAssertEqual(savedNew.partsPaneFraction, 0.62)
        XCTAssertEqual(savedNew.revisions.map(\.id), [original.revisions.last!.id])
        XCTAssertNotEqual(savedNew.projectID, original.projectID)
        XCTAssertEqual(original.revisions.count, 2)
    }

    func testSeparateSavedFilesAndCopiesKeepTheirOwnSidebarFraction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-sidebar-layout-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = project(), second = project()
        first.partsPaneFraction = 0.35
        second.partsPaneFraction = 0.85
        let firstURL = directory.appendingPathComponent("First.lad")
        let secondURL = directory.appendingPathComponent("Second.lad")
        let copyURL = directory.appendingPathComponent("Copy.lad")
        try ProjectStore.write(first, to: firstURL)
        try ProjectStore.write(second, to: secondURL)
        try ProjectStore.write(ProjectStore.read(from: firstURL), to: copyURL)
        XCTAssertEqual(try ProjectStore.read(from: firstURL).partsPaneFraction, 0.35)
        XCTAssertEqual(try ProjectStore.read(from: secondURL).partsPaneFraction, 0.85)
        XCTAssertEqual(try ProjectStore.read(from: copyURL).partsPaneFraction, 0.35)
    }

    func testInvalidSidebarFractionsAreRejectedBeforeSavingAndWhenReadingArchives() throws {
        for fraction in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            var value = project()
            value.partsPaneFraction = fraction
            XCTAssertThrowsError(try ProjectStore.encode(value))
        }
        let manifest = try archive(ProjectStore.encode(project()))
        let invalidValues: [Any] = [-0.01, 1.01, "0.75", true, [0.75], ["fraction": 0.75]]
        for invalid in invalidValues {
            var changed = manifest
            changed["partsPaneFraction"] = invalid
            XCTAssertThrowsError(try ProjectStore.decode(compressed(changed)))
        }
        for fraction in [0.0, 0.1, 0.75, 0.9, 1.0] {
            var value = project()
            value.partsPaneFraction = fraction
            XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(value)).partsPaneFraction, fraction)
        }
    }

    private func archive(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(data)) as? [String: Any])
    }

    private func compressed(_ manifest: [String: Any]) throws -> Data {
        try ProjectZIP.encode(JSONSerialization.data(withJSONObject: manifest))
    }

    private func project() -> LADProject {
        let revisions = [ProjectRevision(model: .bracket), ProjectRevision(model: .bracket)]
        return LADProject(messages: [], revisions: revisions, selectedRevisionID: revisions[0].id, projectID: UUID())
    }
}
