import XCTest
@testable import LAD

final class PartLayoutTests: XCTestCase {
    func testNestedFolderExpansionIsIndependentAndSurvivesMovesAndRenames() throws {
        var layout = PartLayout(nodes: [group("case", [group("inner", [part("base", 0)])]), group("pcb", [part("board", 1)])])
        try layout.setExpanded(false, for: "inner")
        try layout.setExpanded(false, for: "case")
        try layout.setExpanded(false, for: "case")
        XCTAssertEqual(layout.collapsedNodeIDs, ["case", "inner"], "Repeated collapse must not add duplicate IDs.")

        try layout.setExpanded(true, for: "case")
        XCTAssertEqual(layout.collapsedNodeIDs, ["inner"], "Opening a parent must preserve its child's own disclosure state.")
        try layout.move(["inner"], toParent: "pcb")
        try layout.rename("inner", to: "Internal assembly")
        XCTAssertEqual(layout.collapsedNodeIDs, ["inner"])
        XCTAssertEqual(find("pcb", in: layout)?.children?.map(\.id), ["board", "inner"])
        XCTAssertEqual(find("inner", in: layout)?.name, "Internal assembly")

        let folder = try layout.createFolder(named: "New folder")
        XCTAssertFalse(layout.collapsedNodeIDs.contains(folder), "New folders start expanded.")
        let original = layout
        XCTAssertThrowsError(try layout.setExpanded(false, for: "base")) { XCTAssertEqual($0 as? PartLayoutError, .invalidGroup("base")) }
        XCTAssertThrowsError(try layout.setExpanded(false, for: "missing")) { XCTAssertEqual($0 as? PartLayoutError, .unknownNode("missing")) }
        XCTAssertEqual(layout, original)
    }

    func testReconcileKeepsSurvivingFolderDisclosuresAndDropsRemovedOrConvertedGroups() throws {
        var layout = PartLayout(nodes: [group("case", [group("inner", [part("base", 0)])]),
                                        group("removed", [part("old", 1)]),
                                        group("converted", [part("former-child", 2)])])
        let userFolder = try layout.createFolder(named: "Manufacturing")
        try layout.move(["inner"], toParent: userFolder)
        for id in ["case", "inner", "removed", "converted", userFolder] { try layout.setExpanded(false, for: id) }
        let defaults = [group("case", [group("inner", [part("base", 0)]), part("new", 1)]),
                        part("converted", 2), group("new-group", [part("extra", 3)])]

        let updated = layout.reconciled(with: defaults)
        XCTAssertEqual(Set(updated.collapsedNodeIDs), ["case", "inner", userFolder])
        XCTAssertEqual(find(userFolder, in: updated)?.children?.map(\.id), ["inner"])
        XCTAssertFalse(updated.collapsedNodeIDs.contains("new-group"))
        XCTAssertFalse(find("converted", in: updated)?.isGroup ?? true)
    }

    func testUngroupRemovesOnlyItsOwnDisclosureState() throws {
        var layout = PartLayout(nodes: [group("case", [group("inner", [part("base", 0)])])])
        try layout.setExpanded(false, for: "case")
        try layout.setExpanded(false, for: "inner")
        try layout.ungroup("case")
        XCTAssertEqual(layout.collapsedNodeIDs, ["inner"])
        try layout.ungroup("inner")
        XCTAssertTrue(layout.collapsedNodeIDs.isEmpty)
    }

    func testMoveSkipsSelectedDescendantsAndPreservesTreeOrder() throws {
        var layout = PartLayout(nodes: [group("case", [part("base", 0), part("lid", 1)]), group("pcb", [part("board", 2)]), group("folder", [])])
        try layout.move(["case", "lid", "pcb"], toParent: "folder")
        XCTAssertEqual(layout.nodes.map(\.id), ["folder"])
        XCTAssertEqual(find("folder", in: layout)?.children?.map(\.id), ["case", "pcb"])
        XCTAssertEqual(find("case", in: layout)?.children?.map(\.id), ["base", "lid"])
        XCTAssertEqual(layout.movedNodeIDs, ["case", "pcb"])
        XCTAssertEqual(solids(layout), [0, 1, 2])
    }

    func testMoveRejectsCyclesUnknownNodesAndNonFolderTargets() throws {
        var layout = PartLayout(nodes: [group("case", [group("inner", [part("base", 0)])])])
        let original = layout
        XCTAssertThrowsError(try layout.move(["case"], toParent: "inner")) { XCTAssertEqual($0 as? PartLayoutError, .recursiveMove) }
        XCTAssertThrowsError(try layout.move(["inner"], toParent: "inner")) { XCTAssertEqual($0 as? PartLayoutError, .recursiveMove) }
        XCTAssertThrowsError(try layout.move(["inner"], toParent: "base")) { XCTAssertEqual($0 as? PartLayoutError, .invalidParent("base")) }
        XCTAssertThrowsError(try layout.move(["missing"], toParent: nil))
        XCTAssertEqual(layout, original, "Rejected moves must leave the full layout untouched.")
    }

    func testReconcilePreservesUserPlacementAndNamesButUsesLatestGeometry() throws {
        let original = [group("case", [part("base", 0), part("lid", 1)]), group("pcb", [part("board", 2)])]
        var layout = PartLayout(nodes: original)
        let folder = try layout.createFolder(named: "Manufacturing")
        try layout.move(["base"], toParent: folder)
        try layout.rename("base", to: "Printed base")
        let defaults = [group("case", [part("lid", 10), part("base", 11), part("port", 12)]),
                        group("pcb", [part("board", 13), part("component", 14)])]
        let updated = layout.reconciled(with: defaults)
        XCTAssertEqual(find(folder, in: updated)?.children?.map(\.id), ["base"])
        XCTAssertEqual(find("base", in: updated)?.solidIndices, [11])
        XCTAssertEqual(find("base", in: updated)?.name, "Printed base")
        XCTAssertEqual(find("case", in: updated)?.children?.map(\.id), ["lid", "port"])
        XCTAssertEqual(find("pcb", in: updated)?.children?.map(\.id), ["board", "component"])
        XCTAssertEqual(updated.movedNodeIDs, ["base"])
        XCTAssertEqual(solids(updated), [10, 11, 12, 13, 14])
    }

    func testReconcileRestoresRemovedTargetFolderAncestryWithoutOldSolidIndices() throws {
        var layout = PartLayout(nodes: [group("assembly", [group("case", [part("base", 0)])])])
        try layout.move(["base"], toParent: "case")
        let updated = layout.reconciled(with: [group("new-group", [part("base", 8), part("new-part", 9)])])
        XCTAssertEqual(find("case", in: updated)?.children?.map(\.id), ["base"])
        XCTAssertEqual(find("assembly", in: updated)?.children?.map(\.id), ["case"])
        XCTAssertEqual(find("new-group", in: updated)?.children?.map(\.id), ["new-part"])
        XCTAssertEqual(solids(updated), [8, 9])
        XCTAssertTrue(find("case", in: updated)?.solidIndices.isEmpty == true)
    }

    func testDeletedPartsDropButEmptyUserFoldersPersist() throws {
        var layout = PartLayout(nodes: [group("case", [part("base", 0)])])
        let folder = try layout.createFolder(named: "Spare parts")
        try layout.move(["base"], toParent: folder)
        try layout.rename("base", to: "Old base")
        let updated = layout.reconciled(with: [group("case", [part("lid", 1)])])
        XCTAssertNil(find("base", in: updated))
        XCTAssertEqual(find(folder, in: updated)?.children, [])
        XCTAssertEqual(updated.userFolderIDs, [folder])
        XCTAssertTrue(updated.movedNodeIDs.isEmpty)
        XCTAssertTrue(updated.renamedNodes.isEmpty)
        XCTAssertEqual(solids(updated), [1])
    }

    func testExplicitPlacementOverrideClearsOnlyTheAllowedLocks() throws {
        var layout = PartLayout(nodes: [group("case", [part("base", 0), part("lid", 1)])])
        let folder = try layout.createFolder(named: "Printed parts")
        try layout.move(["base", "lid"], toParent: folder)
        let updated = layout.reconciled(with: [group("case", [part("base", 2), part("lid", 3)])], allowingPlacementChanges: ["base"])
        XCTAssertEqual(find("case", in: updated)?.children?.map(\.id), ["base"])
        XCTAssertEqual(find(folder, in: updated)?.children?.map(\.id), ["lid"])
        XCTAssertEqual(updated.movedNodeIDs, ["lid"])
    }

    func testReconcileBreaksDefaultCycleWithoutUndoingUserMove() throws {
        var layout = PartLayout(nodes: [group("a", [part("x", 0)]), group("b", [part("y", 1)])])
        try layout.move(["a"], toParent: "b")
        let updated = layout.reconciled(with: [group("a", [part("x", 2), group("b", [part("y", 3)])])])
        XCTAssertEqual(updated.nodes.map(\.id), ["b"])
        XCTAssertEqual(find("b", in: updated)?.children?.map(\.id), ["y", "a"])
        XCTAssertEqual(solids(updated), [2, 3])
    }

    func testUngroupPromotesChildrenAndDoesNotRecreateAnEmptyDefaultGroup() throws {
        let defaults = [part("other", 0), group("case", [part("base", 1), part("lid", 2)])]
        var layout = PartLayout(nodes: defaults)
        try layout.ungroup("case")
        XCTAssertEqual(layout.nodes.map(\.id), ["other", "base", "lid"])
        XCTAssertEqual(layout.movedNodeIDs, ["base", "lid"])
        let updated = layout.reconciled(with: defaults)
        XCTAssertEqual(updated.nodes.map(\.id), ["other", "base", "lid"])
        XCTAssertNil(find("case", in: updated))
        XCTAssertEqual(solids(updated), [0, 1, 2])
    }

    func testUngroupKeepsFolderOwnedGeometryAsALeaf() throws {
        let defaults = [PartNode(id: "case", name: "case", solidIndices: [0], children: [part("lid", 1)])]
        var layout = PartLayout(nodes: defaults)
        try layout.ungroup("case")
        XCTAssertEqual(layout.nodes.map(\.id), ["case", "lid"])
        XCTAssertFalse(try XCTUnwrap(find("case", in: layout)).isGroup)
        let updated = layout.reconciled(with: defaults)
        XCTAssertEqual(updated.nodes.map(\.id), ["case", "lid"])
        XCTAssertFalse(try XCTUnwrap(find("case", in: updated)).isGroup)
        XCTAssertEqual(solids(updated), [0, 1])
    }

    func testUngroupRemovesAnEmptyUserFolderAndItsMetadata() throws {
        var layout = PartLayout(nodes: [part("base", 0)])
        let folder = try layout.createFolder(named: "Empty")
        try layout.rename(folder, to: "Temporary")
        try layout.move([folder], toParent: nil)
        try layout.setExpanded(false, for: folder)
        try layout.ungroup(folder)
        XCTAssertEqual(layout.nodes.map(\.id), ["base"])
        XCTAssertTrue(layout.userFolderIDs.isEmpty)
        XCTAssertTrue(layout.movedNodeIDs.isEmpty)
        XCTAssertTrue(layout.renamedNodes.isEmpty)
        XCTAssertTrue(layout.collapsedNodeIDs.isEmpty)
    }

    func testCodableRoundTripAndDefaultsForOptionalEditingMetadata() throws {
        var layout = PartLayout(nodes: [part("base", 0)])
        let folder = try layout.createFolder(named: "  Printed parts  ")
        try layout.move(["base"], toParent: folder)
        try layout.rename("base", to: "  Bottom  ")
        try layout.setExpanded(false, for: folder)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(PartLayout.self, from: data), layout)
        let older = Data("{\"nodes\":[{\"id\":\"base\",\"name\":\"Base\",\"solidIndices\":[0]}]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(PartLayout.self, from: older).movedNodeIDs, [])
        XCTAssertEqual(try JSONDecoder().decode(PartLayout.self, from: older).collapsedNodeIDs, [])
        XCTAssertEqual(find(folder, in: layout)?.name, "Printed parts")
        XCTAssertEqual(find("base", in: layout)?.name, "Bottom")
        XCTAssertThrowsError(try layout.rename("base", to: " \n"))
    }

    func testReusedUserFolderKeepsCurrentGeometryOwnership() throws {
        var layout = PartLayout(nodes: [])
        let folder = try layout.createFolder(named: "Case")
        let defaults = [PartNode(id: folder, name: "Generated case", solidIndices: [0], children: nil)]
        let updated = layout.reconciled(with: defaults)
        let reused = try XCTUnwrap(find(folder, in: updated))
        XCTAssertEqual(reused.solidIndices, [0])
        XCTAssertEqual(reused.children, [])
        XCTAssertTrue(reused.isGroup)
        XCTAssertEqual(reused.name, "Case")
        XCTAssertEqual(updated.userFolderIDs, [folder])
        XCTAssertEqual(updated.nodes.flatMap { Array($0.allSolidIndices) }, [0])
        let repeated = updated.reconciled(with: defaults)
        XCTAssertEqual(repeated, updated, "Body ownership must not erase the persistent folder on a later rebuild.")
    }

    func testGenericPartRemappingKeepsMovedPlacementAndRenameOnSameProgramRebuild() throws {
        var layout = PartLayout(nodes: [part("solid/0", 0), part("solid/1", 1)])
        let folder = try layout.createFolder(named: "Printing")
        try layout.move(["solid/0"], toParent: folder)
        try layout.rename("solid/0", to: "Printed base")
        try layout.setExpanded(false, for: folder)
        let defaults = [group("case", [part("case/base", 0), part("case/lid", 1)])]
        let migrated = layout.remappingGenericParts(to: defaults)
        XCTAssertNil(find("solid/0", in: migrated))
        XCTAssertEqual(migrated.movedNodeIDs, ["case/base"])
        XCTAssertEqual(migrated.renamedNodes, ["case/base": "Printed base"])
        XCTAssertEqual(migrated.userFolderIDs, [folder])
        XCTAssertEqual(migrated.collapsedNodeIDs, [folder])
        let updated = migrated.reconciled(with: defaults)
        XCTAssertEqual(find(folder, in: updated)?.children?.map(\.id), ["case/base"])
        XCTAssertEqual(find("case/base", in: updated)?.name, "Printed base")
        XCTAssertEqual(find("case", in: updated)?.children?.map(\.id), ["case/lid"])
        XCTAssertEqual(solids(updated), [0, 1])
        XCTAssertEqual(updated.collapsedNodeIDs, [folder])
    }

    func testGenericRemappingNeverMatchesNamedPartsByIndexAlone() throws {
        var layout = PartLayout(nodes: [part("old/base", 0)])
        try layout.rename("old/base", to: "Named base")
        XCTAssertEqual(layout.remappingGenericParts(to: [part("different/part", 0)]), layout)
    }

    private func part(_ id: String, _ solid: Int) -> PartNode {
        PartNode(id: id, name: id, solidIndices: [solid], children: nil)
    }

    private func group(_ id: String, _ children: [PartNode]) -> PartNode {
        PartNode(id: id, name: id, solidIndices: [], children: children)
    }

    private func find(_ id: String, in layout: PartLayout) -> PartNode? {
        layout.nodes.flatMap(\.flattened).first { $0.id == id }
    }

    private func solids(_ layout: PartLayout) -> Set<Int> {
        Set(layout.nodes.flatMap { $0.allSolidIndices })
    }
}
