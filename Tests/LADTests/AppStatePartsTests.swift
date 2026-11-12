import XCTest
@testable import LAD

final class AppStatePartsTests: XCTestCase {
    @MainActor
    func testFolderExpansionUsesEachRevisionsSavedStateBeforePreviewLoads() {
        let folders = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "body", name: "Body", solidIndices: [0])])]
        let closed = ProjectRevision(model: .bracket,
                                    partLayout: PartLayout(nodes: folders, collapsedNodeIDs: ["case"]), parts: folders)
        let open = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: folders), parts: folders)
        let state = AppState()
        state.revisions = [closed, open]
        state.selectedRevisionID = closed.id
        XCTAssertNil(state.mesh)
        XCTAssertFalse(state.isPartFolderExpanded("case"))
        state.selectedRevisionID = open.id
        XCTAssertTrue(state.isPartFolderExpanded("case"))
        state.selectedRevisionID = closed.id
        XCTAssertFalse(state.isPartFolderExpanded("case"))
    }

    @MainActor
    private func state() -> AppState {
        let parts = [
            PartNode(id: "case", name: "Case", solidIndices: [], children: [
                PartNode(id: "base", name: "Base", solidIndices: [0]),
                PartNode(id: "lid", name: "Lid", solidIndices: [1])]),
            PartNode(id: "pcb", name: "PCB", solidIndices: [], children: [
                PartNode(id: "board", name: "Board", solidIndices: [2])])]
        let revision = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: parts))
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        state.mesh = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                                 volume: 1, area: 1, solids: 3, faces: 3, buildSeconds: 0, threads: 1, stepPath: "selection-fixture")
        return state
    }

    @MainActor
    func testModifierClickCanRemoveOnePartFromSelectedFolder() {
        let state = state()
        state.selectPartNodes(["case"])
        XCTAssertEqual(state.selectedSolids, [0, 1])
        XCTAssertEqual(state.selectedPartNodeIDs, ["case"])
        state.selectPartNodes(["lid"], extending: true)
        XCTAssertEqual(state.selectedSolids, [0])
        XCTAssertEqual(state.selectedPartNodeIDs, ["base"])
    }

    @MainActor
    func testModifierSelectionKeepsUnrelatedGroupsAndDoesNotReselectRemovedChild() {
        let state = state()
        state.selectPartNodes(["case"])
        state.selectPartNodes(["pcb"], extending: true)
        XCTAssertEqual(state.selectedSolids, [0, 1, 2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["case", "pcb"])
        state.selectPartNodes(["base"], extending: true)
        XCTAssertEqual(state.selectedSolids, [1, 2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["lid", "pcb"])
    }

    @MainActor
    func testPartClickTogglesOnlyItsGeometryAndRetainsUnrelatedFolderSelection() {
        let state = state()
        state.selectPartNodes(["pcb"])
        state.togglePartNode("base")
        XCTAssertEqual(state.selectedSolids, [0, 2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["base", "pcb"])
        state.togglePartNode("base")
        XCTAssertEqual(state.selectedSolids, [2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["pcb"])
        state.togglePartNode("case")
        XCTAssertEqual(state.selectedSolids, [0, 1, 2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["case", "pcb"])
    }

    @MainActor
    func testShiftClickUsesCurrentPaneOrderAndPreservesSelectionOutsideRange() {
        let state = state()
        let parts = (0..<7).map { PartNode(id: "part-\($0)", name: "Part \($0)", solidIndices: [$0]) }
        state.revisions[0].partLayout = PartLayout(nodes: parts)
        state.selectPartNodes(["part-0", "part-6"])
        state.togglePartNode("part-4", extendingRange: true)
        XCTAssertEqual(state.selectedSolids, [0, 4, 5, 6])
        XCTAssertEqual(state.selectedPartNodeIDs, ["part-0", "part-4", "part-5", "part-6"])

        state.selectPartNodes(["part-0", "part-2", "part-3", "part-4", "part-6"])
        state.togglePartNode("part-3", extendingRange: true)
        XCTAssertEqual(state.selectedSolids, [0, 4, 6])
        XCTAssertEqual(state.selectedPartNodeIDs, ["part-0", "part-4", "part-6"])
    }

    @MainActor
    func testShiftDeselectIncludesPartiallySelectedBoundary() {
        let state = state()
        state.revisions[0].partLayout = PartLayout(nodes: [
            PartNode(id: "compound", name: "Compound", solidIndices: [0, 1]),
            PartNode(id: "board", name: "Board", solidIndices: [2])])
        state.selectParts([0, 2])
        state.togglePartNode("board", extendingRange: true)
        XCTAssertTrue(state.selectedSolids.isEmpty, "The partially selected endpoint must also be deselected.")
        XCTAssertTrue(state.selectedPartNodeIDs.isEmpty)
    }

    @MainActor
    func testFolderRangeSelectsDescendantsAndPreservesPartsAndFoldersOutsideRange() {
        let state = state()
        let folders = (0..<5).map { index in
            PartNode(id: "folder-\(index)", name: "Folder \(index)", solidIndices: [], children: [
                PartNode(id: "first-\(index)", name: "First", solidIndices: [index * 2]),
                PartNode(id: "second-\(index)", name: "Second", solidIndices: [index * 2 + 1])])
        }
        state.revisions[0].partLayout = PartLayout(nodes: folders + [PartNode(id: "loose", name: "Loose", solidIndices: [10])],
                                                  collapsedNodeIDs: ["folder-4"])
        state.selectPartNodes(["folder-0", "folder-4", "loose"])
        state.togglePartNode("folder-3", extendingRange: true)
        XCTAssertEqual(state.selectedSolids, [0, 1, 6, 7, 8, 9, 10])
        XCTAssertEqual(state.selectedPartNodeIDs, ["folder-0", "folder-3", "folder-4", "loose"])

        state.selectedSolids.insert(4)
        state.togglePartNode("folder-3", extendingRange: true)
        XCTAssertEqual(state.selectedSolids, [0, 1, 8, 9, 10], "Deselect the partial folder boundary as well as the clicked folder.")
        XCTAssertEqual(state.selectedPartNodeIDs, ["folder-0", "folder-4", "loose"])
    }

    @MainActor
    func testShiftClickSelectsAndDeselectsEmptyFolderRanges() {
        let state = state()
        state.revisions[0].partLayout = PartLayout(nodes: ["first", "middle", "last"].map {
            PartNode(id: $0, name: $0, solidIndices: [], children: [])
        })
        state.selectPartNodes(["first"])
        state.togglePartNode("last", extendingRange: true)
        XCTAssertEqual(state.selectedPartNodeIDs, ["first", "middle", "last"])
        state.togglePartNode("last")
        state.togglePartNode("first", extendingRange: true)
        XCTAssertTrue(state.selectedPartNodeIDs.isEmpty)
        XCTAssertTrue(state.selectedSolids.isEmpty)
    }

    @MainActor
    func testFolderRangeDeselectsSelectedEmptyDescendantsInsideCollapsedFolders() {
        let state = state()
        state.revisions[0].partLayout = PartLayout(nodes: [
            PartNode(id: "parent", name: "Parent", solidIndices: [], children: [
                PartNode(id: "empty", name: "Empty", solidIndices: [], children: []),
                PartNode(id: "part", name: "Part", solidIndices: [0])]),
            PartNode(id: "next", name: "Next", solidIndices: [], children: []),
            PartNode(id: "outside", name: "Outside", solidIndices: [], children: [])],
            collapsedNodeIDs: ["parent"])
        state.selectPartNodes(["empty", "part", "outside"])
        state.togglePartNode("parent", extendingRange: true)
        XCTAssertTrue(state.selectedSolids.isEmpty)
        XCTAssertEqual(state.selectedPartNodeIDs, ["outside"])
    }

    @MainActor
    func testViewportSelectionMapsToPhysicalPartsAndRejectsInvalidIndices() {
        let state = state()
        state.selectParts([0, 2, 999])
        XCTAssertEqual(state.selectedSolids, [0, 2])
        XCTAssertEqual(state.selectedPartNodeIDs, ["base", "board"])
        state.selectParts([])
        XCTAssertTrue(state.selectedSolids.isEmpty)
        XCTAssertTrue(state.selectedPartNodeIDs.isEmpty)
    }

    @MainActor
    func testSavedPartsRemainAvailableBeforePreviewIsRegenerated() {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]),
            PartNode(id: "lid", name: "Lid", solidIndices: [1])])]
        let revision = ProjectRevision(model: .bracket, parts: parts)
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id

        XCTAssertNil(state.mesh)
        XCTAssertEqual(state.partTree, parts)
        state.selectParts([0, 999])
        XCTAssertEqual(state.selectedSolids, [0])
        XCTAssertEqual(state.selectedPartNodeIDs, ["base"])
        XCTAssertFalse(state.canExport)
    }

    @MainActor
    func testUserHierarchyTakesPrecedenceOverSavedDefaultsWithoutPreview() {
        let defaults = [PartNode(id: "base", name: "Base", solidIndices: [0])]
        let arranged = [PartNode(id: "user-folder:fixture", name: "My assembly", solidIndices: [], children: [
            PartNode(id: "base", name: "Custom base", solidIndices: [0])])]
        let revision = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: arranged), parts: defaults)
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id

        XCTAssertEqual(state.partTree, arranged)
    }

    @MainActor
    func testUnpreparedRevisionDoesNotUsePreviousRevisionsDisplayMeshAsParts() {
        let state = state()
        let unprepared = ProjectRevision(model: .bracket)
        state.revisions.append(unprepared)
        state.selectedRevisionID = unprepared.id

        XCTAssertNotNil(state.mesh)
        XCTAssertTrue(state.partTree.isEmpty)
    }

    @MainActor
    func testVisitedRevisionRestoresPreviewWithoutSTEPOrWorkerAndKeepsNativeArtifact() {
        let parts = [PartNode(id: "shell", name: "Shell", solidIndices: [0])]
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                                  volume: 1, area: 1, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: "", parts: parts, brepPath: "/private/tmp/session/model.brep")
        let revision = ProjectRevision(model: .bracket, preview: preview, parts: parts)
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id

        XCTAssertTrue(state.loadStoredRevision())
        XCTAssertEqual(state.mesh?.brepPath, preview.brepPath)
        XCTAssertEqual(state.mesh?.stepPath, "")
        XCTAssertFalse(state.isWorking)
        XCTAssertTrue(state.canExport)
        XCTAssertNil(state.saveStatus, "Using an in-memory preview must not save project data")
    }

    @MainActor
    func testSwitchingVisitedRevisionsPreservesHierarchyVisibilityAndConversation() throws {
        let parts = [PartNode(id: "shell", name: "Shell", solidIndices: [0])]
        var custom = PartLayout(nodes: parts)
        let folder = try custom.createFolder(named: "Printing")
        try custom.move(["shell"], toParent: folder)
        try custom.rename("shell", to: "My shell")
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                                  volume: 1, area: 1, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: "", parts: parts, brepPath: "/private/tmp/session/model.brep")
        let first = ProjectRevision(model: .bracket, preview: preview, hiddenSolids: [], parts: parts)
        let second = ProjectRevision(model: .bracket, preview: preview, partLayout: custom,
                                    hiddenSolids: [0], parts: parts)
        let history = [ChatMessage(role: "user", content: "Make the shell"),
                       ChatMessage(role: "assistant", content: "Created the shell")]
        let state = AppState()
        state.messages = history
        state.revisions = [first, second]
        state.selectedRevisionID = second.id
        XCTAssertTrue(state.loadStoredRevision())
        XCTAssertEqual(state.partTree, custom.nodes)
        XCTAssertEqual(state.hiddenSolids, [0])
        state.selectedRevisionID = first.id
        XCTAssertTrue(state.loadStoredRevision())
        XCTAssertEqual(state.partTree, parts)
        XCTAssertTrue(state.hiddenSolids.isEmpty)
        state.selectedRevisionID = second.id
        XCTAssertTrue(state.loadStoredRevision())
        XCTAssertEqual(state.partTree, custom.nodes)
        XCTAssertEqual(state.hiddenSolids, [0])
        XCTAssertEqual(state.revisions.count, 2)
        XCTAssertEqual(state.messages, history)
        XCTAssertNil(state.saveStatus)
    }

    @MainActor
    func testReplayRemapsSolidOrderByPartIdentityWithoutMovingOrRenamingUserItems() throws {
        let original = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]),
            PartNode(id: "lid", name: "Lid", solidIndices: [1])])]
        let reordered = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [0]),
            PartNode(id: "base", name: "Base", solidIndices: [1])])]
        var arranged = PartLayout(nodes: original)
        let folder = try arranged.createFolder(named: "Print tray")
        try arranged.move(["base"], toParent: folder)
        try arranged.rename("base", to: "Printed base")
        let revision = ProjectRevision(model: .bracket, partLayout: arranged, hiddenSolids: [0], parts: original)
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                                  volume: 1, area: 1, solids: 2, faces: 12, buildSeconds: 0, threads: 1,
                                  stepPath: "", parts: reordered)
        let restored = try AppState.restoredPartState(for: revision, preview: preview, selected: [1])
        XCTAssertEqual(restored.hidden, [1], "The same physical base must stay hidden")
        XCTAssertEqual(restored.selected, [0], "The same physical lid must stay selected")
        XCTAssertEqual(restored.parts[0].children?.map(\.id), ["base", "lid"])
        XCTAssertEqual(restored.parts[0].children?.map(\.solidIndices), [[1], [0]])
        let restoredLayout = try XCTUnwrap(restored.layout)
        XCTAssertEqual(restoredLayout.nodes.map(\.id), arranged.nodes.map(\.id))
        XCTAssertEqual(restoredLayout.nodes.last?.children?.first?.id, "base")
        XCTAssertEqual(restoredLayout.nodes.last?.children?.first?.name, "Printed base")
        XCTAssertEqual(restoredLayout.nodes.last?.children?.first?.solidIndices, [1])
        XCTAssertEqual(restoredLayout.movedNodeIDs, arranged.movedNodeIDs)
        XCTAssertEqual(restoredLayout.userFolderIDs, arranged.userFolderIDs)
        XCTAssertEqual(restoredLayout.renamedNodes, arranged.renamedNodes)
    }

    @MainActor
    func testReplayRejectsChangedSemanticIdentitiesInsteadOfHidingAnUnrelatedSolid() {
        let previous = [PartNode(id: "base", name: "Base", solidIndices: [0])]
        let revision = ProjectRevision(model: .bracket, hiddenSolids: [0], parts: previous)
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                                  volume: 1, area: 1, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: "", parts: [PartNode(id: "unrelated", name: "Other solid", solidIndices: [0])])
        XCTAssertThrowsError(try AppState.restoredPartState(for: revision, preview: preview, selected: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("different part identities"))
        }
    }

    @MainActor
    func testReplayOfGenericHistoryKeepsItsOnlyAvailableOwnershipAndNames() throws {
        let previous = [PartNode(id: "solid/0", name: "Part 1", solidIndices: [0])]
        var layout = PartLayout(nodes: previous)
        try layout.rename("solid/0", to: "My bracket")
        let revision = ProjectRevision(model: .bracket, partLayout: layout, hiddenSolids: [0], parts: previous)
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                                  volume: 1, area: 1, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                                  stepPath: "", parts: [PartNode(id: "name:Bracket", name: "Bracket", solidIndices: [0])])
        let restored = try AppState.restoredPartState(for: revision, preview: preview, selected: [0])
        XCTAssertEqual(restored.parts, previous)
        XCTAssertEqual(restored.layout, layout)
        XCTAssertEqual(restored.hidden, [0])
        XCTAssertEqual(restored.selected, [0])
    }
}
