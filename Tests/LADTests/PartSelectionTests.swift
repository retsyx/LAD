import XCTest
@testable import LAD

final class PartSelectionTests: XCTestCase {
    func testPartialFolderSelectionUsesRemainingPartInsteadOfFolder() {
        let tree = [folder("case", [part("base", 0), part("lid", 1)])]
        XCTAssertEqual(PartSelection.nodeIDs(for: [0], keeping: ["case"], in: tree), ["base"])
    }

    func testCompletePreferredFoldersSuppressTheirSelectedDescendants() {
        let tree = [folder("case", [part("base", 0), part("lid", 1)]),
                    folder("pcb", [part("board", 2), part("connector", 3)])]
        XCTAssertEqual(PartSelection.nodeIDs(for: [0, 1, 2, 3], keeping: ["case", "base", "pcb", "connector"], in: tree),
                       ["case", "pcb"])
    }

    func testRemovedFolderSelectionUsesPromotedParts() {
        let tree = [part("base", 0), part("lid", 1)]
        XCTAssertEqual(PartSelection.nodeIDs(for: [0, 1], keeping: ["case"], in: tree), ["base", "lid"])
    }

    func testEmptyPreferredUserFolderRemainsSelected() {
        let tree = [folder("user-folder", []), part("base", 0)]
        XCTAssertEqual(PartSelection.nodeIDs(for: [0], keeping: ["user-folder"], in: tree), ["user-folder", "base"])
        XCTAssertEqual(PartSelection.nodeIDs(for: [], keeping: ["user-folder"], in: tree), ["user-folder"])
    }

    func testPreferredAncestorSuppressesNestedEmptyFolders() {
        let tree = [folder("case", [folder("empty", []), part("base", 0)])]
        XCTAssertEqual(PartSelection.nodeIDs(for: [0], keeping: ["case", "empty", "base"], in: tree), ["case"])
    }

    func testDirectlyOwnedAssemblyBodyUsesFolderAndRemovesRedundantChild() {
        let assembly = PartNode(id: "assembly", name: "Assembly", solidIndices: [0], children: [part("lid", 1)])
        XCTAssertEqual(PartSelection.nodeIDs(for: [0, 1], keeping: [], in: [assembly]), ["assembly"])
        let bodyOnly = PartNode(id: "body-folder", name: "Body", solidIndices: [2], children: [])
        XCTAssertEqual(PartSelection.nodeIDs(for: [2], keeping: [], in: [bodyOnly]), ["body-folder"])
    }

    func testDoesNotReturnFolderThatWouldSelectAnUnselectedChild() {
        let assembly = PartNode(id: "assembly", name: "Assembly", solidIndices: [0], children: [part("lid", 1)])
        XCTAssertEqual(PartSelection.nodeIDs(for: [0], keeping: ["assembly"], in: [assembly]), [])
        XCTAssertEqual(PartSelection.nodeIDs(for: [1], keeping: ["assembly"], in: [assembly]), ["lid"])
    }

    func testUnknownPreferredNodesAndSolidsAreIgnored() {
        let tree = [part("base", 0)]
        XCTAssertEqual(PartSelection.nodeIDs(for: [0, 99], keeping: ["removed"], in: tree), ["base"])
        XCTAssertEqual(PartSelection.nodeIDs(for: [], keeping: ["base", "removed"], in: tree), [])
    }

    private func part(_ id: String, _ solid: Int) -> PartNode {
        PartNode(id: id, name: id, solidIndices: [solid], children: nil)
    }

    private func folder(_ id: String, _ children: [PartNode]) -> PartNode {
        PartNode(id: id, name: id, solidIndices: [], children: children)
    }
}
