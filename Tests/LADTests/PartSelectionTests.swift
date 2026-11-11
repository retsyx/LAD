import XCTest
@testable import LAD

final class PartSelectionTests: XCTestCase {
    func testRangeUsesNearestOppositeSelectionInEitherDirection() {
        let cases: [(clicked: Int, selected: Set<Int>, expected: [Int])] = [
            (4, [0, 6], [4, 5, 6]),
            (3, [0, 1, 6], [1, 2, 3]),
            (3, [1, 2, 3, 4, 6], [3, 4, 5]),
            (3, [0, 2, 3, 4, 5, 6], [1, 2, 3]),
            (2, [0, 4], [0, 1, 2]),
            (2, [1, 2, 3], [0, 1, 2]),
            (2, [], [2]),
            (2, Set(0..<7), [2]),
            (0, [6], Array(0..<7)),
            (6, [0], Array(0..<7))
        ]
        for groups in [false, true] {
            let tree = (0..<7).map { groups ? folder("row-\($0)", [part("child-\($0)", $0)]) : part("row-\($0)", $0) }
            for item in cases {
                let range = PartSelection.range(toggling: "row-\(item.clicked)", in: tree,
                                                collapsedNodeIDs: [], selectedSolids: item.selected)
                XCTAssertEqual(range.map(\.id), item.expected.map { "row-\($0)" },
                               "folders=\(groups), clicked=\(item.clicked), selected=\(item.selected.sorted())")
            }
        }
    }

    func testRangeFollowsPaneOrderAndSkipsFolderHeadersAndCollapsedChildren() {
        let tree = [part("before", 0), folder("collapsed", [part("hidden", 1)]),
                    folder("expanded", [part("first", 3), folder("nested", [part("second", 2)])]),
                    part("after", 4)]
        func range(_ id: String, selected: Set<Int>) -> [String] {
            PartSelection.range(toggling: id, in: tree, collapsedNodeIDs: ["collapsed"],
                                selectedSolids: selected).map(\.id)
        }
        XCTAssertEqual(range("before", selected: [3]), ["before", "first"])
        XCTAssertEqual(range("after", selected: [0]), ["before", "first", "second", "after"])
        XCTAssertEqual(range("before", selected: [1]), ["before"], "A collapsed child cannot anchor the range.")
        XCTAssertEqual(range("expanded", selected: [0]), ["expanded"], "Part selection does not anchor a folder range.")
        XCTAssertEqual(range("expanded", selected: [1]), ["collapsed", "expanded"], "A collapsed folder can anchor a folder range.")
        XCTAssertEqual(range("nested", selected: [1]), ["collapsed", "expanded", "nested"])
        XCTAssertEqual(range("missing", selected: [0]), [])
    }

    func testFolderRangeUsesExplicitSelectionForEmptyFolders() {
        let tree = [folder("first", []), folder("middle", []), folder("last", [])]
        XCTAssertEqual(PartSelection.range(toggling: "last", in: tree, collapsedNodeIDs: [],
                                          selectedSolids: [], selectedNodeIDs: ["first"]).map(\.id),
                       ["first", "middle", "last"])
        XCTAssertEqual(PartSelection.range(toggling: "first", in: tree, collapsedNodeIDs: [],
                                          selectedSolids: [], selectedNodeIDs: ["first", "middle"]).map(\.id),
                       ["first", "middle", "last"])
    }

    func testPartWithOnlySomeSolidsSelectedIsAnUnselectedRangeBoundary() {
        let tree = [part("first", 0), PartNode(id: "compound", name: "Compound", solidIndices: [1, 2]),
                    part("third", 3), part("last", 4)]
        XCTAssertEqual(PartSelection.range(toggling: "third", in: tree, collapsedNodeIDs: [],
                                          selectedSolids: [0, 1, 3, 4]).map(\.id), ["compound", "third"])
        XCTAssertEqual(PartSelection.range(toggling: "compound", in: tree, collapsedNodeIDs: [],
                                          selectedSolids: [0, 1, 3, 4]).map(\.id), ["first", "compound"])
    }

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
