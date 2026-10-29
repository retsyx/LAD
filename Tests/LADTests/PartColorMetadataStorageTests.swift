import Foundation
import XCTest
@testable import LAD

final class PartColorMetadataStorageTests: XCTestCase {
    func testZIPRoundtripRetainsCurrentPartColorsAndNodeMetadata() throws {
        let original = project()
        let data = try ProjectStore.encode(original)
        let restored = try ProjectStore.decode(data)
        XCTAssertEqual(restored.revisions[0].parts, original.revisions[0].parts)
        XCTAssertEqual(restored.revisions[0].partLayout, original.revisions[0].partLayout)
        XCTAssertEqual(restored.revisions[0].partColors, original.revisions[0].partColors)
        let body = try XCTUnwrap(restored.revisions[0].parts?.first?.children?.first)
        XCTAssertEqual(body.color, PartColor(red: 0.2, green: 0.4, blue: 0.6))
        XCTAssertEqual(restored.revisions[0].partColors?[body.id], PartColor(red: 0.7, green: 0.5, blue: 0.2))
        let manifest = try archive(data)
        let revisions = try XCTUnwrap(manifest["revisions"] as? [[String: Any]])
        let group = try XCTUnwrap((revisions[0]["parts"] as? [[String: Any]])?.first)
        XCTAssertNil(group["color"])
        let storedBody = try XCTUnwrap((group["children"] as? [[String: Any]])?.first)
        let color = try XCTUnwrap(storedBody["color"] as? [String: Double])
        XCTAssertEqual(color, ["red": 0.2, "green": 0.4, "blue": 0.6])
        XCTAssertNil(revisions[0]["preview"])
        XCTAssertNil(revisions[0]["stepData"])
    }

    func testColorMetadataIsOptionalAndCannotContainInvalidRGBComponents() throws {
        let node = PartNode(id: "body", name: "Body", solidIndices: [0])
        let restored = try JSONDecoder().decode(PartNode.self, from: Data("{\"id\":\"body\",\"name\":\"Body\",\"solidIndices\":[0]}".utf8))
        XCTAssertNil(restored.color)
        XCTAssertEqual(restored, node)
        XCTAssertNoThrow(try ProjectStore.validatePartHierarchy([node], solidCount: 1))
        for color in [PartColor(red: .nan, green: 0.2, blue: 0.3),
                      PartColor(red: 0.1, green: .infinity, blue: 0.3),
                      PartColor(red: -0.01, green: 0.2, blue: 0.3),
                      PartColor(red: 0.1, green: 0.2, blue: 1.01)] {
            var invalid = node
            invalid.color = color
            XCTAssertThrowsError(try ProjectStore.validatePartHierarchy([invalid], solidCount: 1))
            var value = project()
            value.revisions[0].parts = [invalid]
            value.revisions[0].partLayout = PartLayout(nodes: [invalid])
            value.revisions[0].partColors = nil
            XCTAssertThrowsError(try ProjectStore.encode(value))
        }
    }

    func testArchiveReaderRejectsCorruptedColorsInPartsAndUserLayout() throws {
        let valid = try archive(ProjectStore.encode(project()))
        for container in ["parts", "partLayout"] {
            var changed = valid
            var revisions = try XCTUnwrap(changed["revisions"] as? [[String: Any]])
            var layout = try XCTUnwrap(revisions[0]["partLayout"] as? [String: Any])
            var parts = try XCTUnwrap((container == "parts" ? revisions[0]["parts"] : layout["nodes"]) as? [[String: Any]])
            var children = try XCTUnwrap(parts[0]["children"] as? [[String: Any]])
            children[0]["color"] = ["red": 0.2, "green": 0.4, "blue": 2.0]
            parts[0]["children"] = children
            if container == "parts" {
                revisions[0]["parts"] = parts
            } else {
                layout["nodes"] = parts
                revisions[0]["partLayout"] = layout
            }
            changed["revisions"] = revisions
            let corrupt = try ProjectZIP.encode(JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try ProjectStore.decode(corrupt), "Invalid color in \(container) must be rejected")
        }
    }

    private func archive(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(data)) as? [String: Any])
    }

    private func project() -> LADProject {
        let group = PartNode(id: "assembly", name: "Assembly", solidIndices: [], children: [
            PartNode(id: "body", name: "Body", solidIndices: [0], color: PartColor(red: 0.2, green: 0.4, blue: 0.6)),
            PartNode(id: "cap", name: "Cap", solidIndices: [1], color: PartColor(red: 0.8, green: 0.1, blue: 0.3))
        ])
        var revision = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: [group]), parts: [group])
        revision.partColors = ["body": PartColor(red: 0.7, green: 0.5, blue: 0.2)]
        return LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id, projectID: UUID())
    }
}
