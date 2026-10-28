import Foundation
import XCTest
@testable import LAD

final class PartColorStorageTests: XCTestCase {
    func testZIPRoundtripRetainsRevisionColorsAndProjectRecentColorsWithoutDisplayData() throws {
        var original = project()
        original.revisions[0].partColors = ["case": PartColor.curated[0], "lid": PartColor.curated[3]]
        original.revisions[1].partColors = ["case": PartColor.curated[7], "lid": PartColor.curated[12]]
        original.recentPartColors = [PartColor.curated[12], PartColor.curated[7], PartColor.curated[0]]
        let data = try ProjectStore.encode(original)
        XCTAssertEqual(data.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))

        let restored = try ProjectStore.decode(data)
        XCTAssertEqual(restored.revisions.map(\.partColors), original.revisions.map(\.partColors))
        XCTAssertEqual(restored.recentPartColors, original.recentPartColors)
        XCTAssertEqual(restored.revisions.map(\.partLayout), original.revisions.map(\.partLayout))
        XCTAssertEqual(restored.selectedRevisionID, original.selectedRevisionID)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.showGrid, false)
        XCTAssertTrue(restored.revisions.allSatisfy { $0.preview == nil && $0.stepData == nil })

        let manifest = try archive(data)
        XCTAssertEqual((manifest["recentPartColors"] as? [[String: Any]])?.count, 3)
        let revisions = try XCTUnwrap(manifest["revisions"] as? [[String: Any]])
        XCTAssertTrue(revisions.allSatisfy { ($0["partColors"] as? [String: Any])?.count == 2 })
        XCTAssertTrue(revisions.allSatisfy { $0["preview"] == nil && $0["stepData"] == nil })
        let assets = try XCTUnwrap(manifest["assets"] as? [String: String])
        var uncolored = original
        for index in uncolored.revisions.indices { uncolored.revisions[index].partColors = nil }
        uncolored.recentPartColors = nil
        let uncoloredManifest = try archive(ProjectStore.encode(uncolored))
        let uncoloredAssets = try XCTUnwrap(uncoloredManifest["assets"] as? [String: String])
        XCTAssertEqual(assets.count, 1, "Both revisions share the same CAD program asset")
        XCTAssertEqual(assets, uncoloredAssets, "Colors are document metadata and must not add file assets")
    }

    func testColorsMustReferToExistingNodesWithTheirOwnGeometry() throws {
        let invalidIDs = ["missing-part", "custom-folder"]
        for id in invalidIDs {
            var value = project()
            value.revisions[0].partColors = [id: PartColor.curated[0]]
            XCTAssertThrowsError(try ProjectStore.encode(value), "Color for \(id) must not be saved")
        }
        var value = project()
        // The Case assembly itself owns solid 0 and must be colorable even
        // though the Lid is nested below it.
        value.revisions[0].partColors = ["case": PartColor.curated[1]]
        XCTAssertNoThrow(try ProjectStore.encode(value))
    }

    func testInvalidComponentsAndRecentListsCannotBeSaved() throws {
        let invalid = [
            PartColor(red: -.infinity, green: 0.5, blue: 0.5),
            PartColor(red: 0.5, green: .nan, blue: 0.5),
            PartColor(red: -0.01, green: 0.5, blue: 0.5),
            PartColor(red: 0.5, green: 0.5, blue: 1.01)
        ]
        for color in invalid {
            var value = project()
            value.revisions[0].partColors = ["lid": color]
            XCTAssertThrowsError(try ProjectStore.encode(value))
            value.revisions[0].partColors = nil
            value.recentPartColors = [color]
            XCTAssertThrowsError(try ProjectStore.encode(value))
        }
        var value = project()
        value.recentPartColors = [PartColor.curated[0], PartColor.curated[0]]
        XCTAssertThrowsError(try ProjectStore.encode(value))
        value.recentPartColors = Array(PartColor.curated.prefix(PartColor.maximumRecentCount + 1))
        XCTAssertThrowsError(try ProjectStore.encode(value))
    }

    func testReaderRejectsCorruptColorMetadata() throws {
        var value = project()
        value.revisions[0].partColors = ["lid": PartColor.curated[0]]
        let validManifest = try archive(ProjectStore.encode(value))
        for (id, color) in [("missing", ["red": 0.3, "green": 0.4, "blue": 0.5]),
                            ("lid", ["red": 2.0, "green": 0.4, "blue": 0.5])] {
            var changed = validManifest
            var revisions = try XCTUnwrap(changed["revisions"] as? [[String: Any]])
            revisions[0]["partColors"] = [id: color]
            changed["revisions"] = revisions
            XCTAssertThrowsError(try ProjectStore.decode(ProjectZIP.encode(JSONSerialization.data(withJSONObject: changed))))
        }
        var changed = validManifest
        changed["recentPartColors"] = [["red": 0.3, "green": 0.4, "blue": 0.5],
                                       ["red": 0.3, "green": 0.4, "blue": 0.5]]
        XCTAssertThrowsError(try ProjectStore.decode(ProjectZIP.encode(JSONSerialization.data(withJSONObject: changed))))
    }

    func testProjectsWithoutColorMetadataRemainUncoloredAndDoNotInheritRecents() throws {
        let untouched = project()
        let manifest = try archive(ProjectStore.encode(untouched))
        XCTAssertNil(manifest["recentPartColors"])
        XCTAssertTrue((manifest["revisions"] as? [[String: Any]])?.allSatisfy { $0["partColors"] == nil } == true)
        var colored = project()
        colored.recentPartColors = [PartColor.curated[4]]
        colored.revisions[1].partColors = ["lid": PartColor.curated[4]]
        XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(colored)).recentPartColors, colored.recentPartColors)
        let restored = try ProjectStore.decode(ProjectStore.encode(untouched))
        XCTAssertNil(restored.recentPartColors)
        XCTAssertTrue(restored.revisions.allSatisfy { $0.partColors == nil })
    }

    private func archive(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(data)) as? [String: Any])
    }

    private func project() -> LADProject {
        let assembly = PartNode(id: "case", name: "Case", solidIndices: [0], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [1])
        ])
        let custom = PartNode(id: "custom-folder", name: "My assembly", solidIndices: [], children: [assembly])
        let layout = PartLayout(nodes: [custom], movedNodeIDs: ["case"], userFolderIDs: ["custom-folder"],
                                collapsedNodeIDs: ["custom-folder"])
        let first = ProjectRevision(model: .bracket, partLayout: layout, parts: [assembly])
        let last = ProjectRevision(model: .bracket, partLayout: layout, parts: [assembly])
        return LADProject(messages: [ChatMessage(role: "user", content: "Create a case")],
                          revisions: [first, last], selectedRevisionID: last.id, projectID: UUID(), showGrid: false)
    }
}
