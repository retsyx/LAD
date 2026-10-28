import Foundation
import XCTest
@testable import LAD

final class ProjectViewOptionsTests: XCTestCase {
    func testEveryProjectionAndDisplayCombinationRoundtripsInsideTheZIPProject() throws {
        for projection in ViewportProjectionMode.allCases {
            for display in ViewportDisplayMode.allCases {
                var original = project()
                original.projectionMode = projection
                original.displayMode = display
                let bytes = try ProjectStore.encode(original)
                XCTAssertEqual(bytes.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
                let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
                XCTAssertEqual(manifest["projectionMode"] as? String, projection.rawValue)
                XCTAssertEqual(manifest["displayMode"] as? String, display.rawValue)

                let restored = try ProjectStore.decode(bytes)
                XCTAssertEqual(restored.projectionMode, projection)
                XCTAssertEqual(restored.displayMode, display)
                XCTAssertEqual(restored.showGrid, original.showGrid)
                XCTAssertEqual(restored.projectID, original.projectID)
                XCTAssertEqual(restored.messages, original.messages)
                XCTAssertEqual(restored.selectedRevisionID, original.selectedRevisionID)
                XCTAssertEqual(restored.revisions.map(\.id), original.revisions.map(\.id))
                XCTAssertEqual(restored.revisions.map(\.model), original.revisions.map(\.model))
            }
        }
    }

    func testEmptyProjectRetainsViewOptionsWithoutCreatingGeometryOrHistory() throws {
        let original = LADProject(messages: [], revisions: [], selectedRevisionID: nil,
                                  showGrid: false, projectionMode: .isometric, displayMode: .translucent)
        let bytes = try ProjectStore.encode(original)
        let restored = try ProjectStore.decode(bytes)
        XCTAssertEqual(restored.projectionMode, .isometric)
        XCTAssertEqual(restored.displayMode, .translucent)
        XCTAssertEqual(restored.showGrid, false)
        XCTAssertTrue(restored.messages.isEmpty)
        XCTAssertTrue(restored.revisions.isEmpty)
        XCTAssertNil(restored.selectedRevisionID)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
        XCTAssertEqual((manifest["assets"] as? [String: Any])?.count, 0)
    }

    func testAutosaveRestoreAndPortableCopyKeepDifferentProjectsViewOptionsSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-view-options-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectAutosaveStore(rootDirectory: root.appendingPathComponent("LAD", isDirectory: true))
        var first = project(), second = project()
        first.projectName = "First design"
        first.projectionMode = .isometric
        first.displayMode = .translucent
        second.projectName = "Second design"
        second.projectionMode = .perspective
        second.displayMode = .wireframe
        let firstID = try XCTUnwrap(first.projectID), secondID = try XCTUnwrap(second.projectID)
        let firstURL = try await store.write(project: first, projectID: firstID, title: "First", sequence: 1)
        let secondURL = try await store.write(project: second, projectID: secondID, title: "Second", sequence: 1)

        let restoredFirst = try await store.restoreRecent(preferredURL: firstURL, projectID: firstID)
        let restoredSecond = try await store.restoreRecent(preferredURL: secondURL, projectID: secondID)
        XCTAssertEqual(restoredFirst?.project.projectionMode, .isometric)
        XCTAssertEqual(restoredFirst?.project.displayMode, .translucent)
        XCTAssertEqual(restoredSecond?.project.projectionMode, .perspective)
        XCTAssertEqual(restoredSecond?.project.displayMode, .wireframe)

        let copyURL = root.appendingPathComponent("Portable.lad")
        try await store.writeCopy(first, to: copyURL)
        let copy = try ProjectStore.read(from: copyURL)
        XCTAssertEqual(copy.projectionMode, .isometric)
        XCTAssertEqual(copy.displayMode, .translucent)
        let unchangedSecond = try ProjectStore.read(from: secondURL)
        XCTAssertEqual(unchangedSecond.projectionMode, .perspective)
        XCTAssertEqual(unchangedSecond.displayMode, .wireframe)
    }

    func testUnspecifiedViewOptionsRemainUnspecifiedAcrossIndependentFiles() throws {
        let unspecified = try ProjectStore.encode(project())
        var other = project()
        other.projectionMode = .isometric
        other.displayMode = .translucent
        let explicit = try ProjectStore.decode(ProjectStore.encode(other))
        XCTAssertEqual(explicit.projectionMode, .isometric)
        XCTAssertEqual(explicit.displayMode, .translucent)
        let restored = try ProjectStore.decode(unspecified)
        XCTAssertNil(restored.projectionMode)
        XCTAssertNil(restored.displayMode)
    }

    func testMalformedProjectionAndDisplayValuesAreRejected() throws {
        let bytes = try ProjectStore.encode(project())
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
        let invalidValues: [Any] = ["unknown-option", 1, false, ["isometric"]]
        for key in ["projectionMode", "displayMode"] {
            for value in invalidValues {
                var malformed = manifest
                malformed[key] = value
                let invalid = try ProjectZIP.encode(JSONSerialization.data(withJSONObject: malformed))
                XCTAssertThrowsError(try ProjectStore.decode(invalid), "\(key): \(value)")
            }
        }
    }

    private func project() -> LADProject {
        let first = ProjectRevision(model: .bracket)
        var updated = ModelSpec.bracket
        updated.title = "Updated design"
        let last = ProjectRevision(model: updated)
        return LADProject(messages: [ChatMessage(role: "user", content: "Create a design"),
                                     ChatMessage(role: "assistant", content: "Design ready.", phase: "final_answer")],
                          revisions: [first, last], selectedRevisionID: first.id, projectID: UUID(), showGrid: false)
    }
}
