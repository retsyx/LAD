import XCTest
@testable import LAD

final class AppStateColorTests: XCTestCase {
    private let red = PartColor(red: 0.8, green: 0.3, blue: 0.25)
    private let blue = PartColor(red: 0.25, green: 0.5, blue: 0.8)

    @MainActor
    func testContextColorUsesSelectedPartsButAnUnselectedRowTargetsOnlyItself() {
        let state = state()
        state.setPartColor(red, for: "base")
        state.selectPartNodes(["base", "board"])
        XCTAssertNil(state.partColor(for: "base"), "Mixed colors have no single picker value")
        state.setPartColor(blue, for: "base")
        XCTAssertEqual(state.solidColors, [0: blue, 2: blue])
        XCTAssertEqual(state.partColor(for: "board"), blue)

        state.setPartColor(red, for: "lid")
        XCTAssertEqual(state.solidColors, [0: blue, 1: red, 2: blue])
        XCTAssertEqual(state.recentPartColors, [red, blue])
        state.setPartColor(nil, for: "base")
        XCTAssertEqual(state.solidColors, [1: red])
        XCTAssertEqual(state.recentPartColors, [red, blue], "Resetting preserves the design's recent choices")
    }

    @MainActor
    func testFolderColorIncludesItsOwnGeometryAndDescendantsAndSurvivesOrganization() {
        let state = state()
        state.setPartColor(blue, for: "case")
        XCTAssertEqual(state.solidColors, [0: blue, 1: blue, 3: blue])
        XCTAssertEqual(state.partColor(for: "case"), blue)
        state.renamePartNode("base", to: "Printed base")
        state.movePartNodes(["base"], toParent: nil)
        XCTAssertEqual(state.solidColors, [0: blue, 1: blue, 3: blue])
        state.setPartColor(nil, for: "case")
        XCTAssertEqual(state.solidColors, [0: blue], "The moved part retains its independent color")
    }

    @MainActor
    func testHistoryAndRefinementsKeepColorsByPartIdentityNotSolidIndex() throws {
        let state = state()
        state.setPartColor(red, for: "base")
        state.setPartColor(blue, for: "lid")
        let original = try XCTUnwrap(state.revisions.first)
        let changedParts = [PartNode(id: "base", name: "Base", solidIndices: [1]),
                            PartNode(id: "new", name: "New part", solidIndices: [0])]
        let retained = AppState.retainedPartColors(original.partColors ?? [:], in: changedParts)
        XCTAssertEqual(retained, ["base": red])
        let changed = ProjectRevision(model: .bracket, parts: changedParts, partColors: retained)
        state.revisions.append(changed)
        state.selectedRevisionID = changed.id
        XCTAssertEqual(state.solidColors, [1: red])
        state.selectedRevisionID = original.id
        XCTAssertEqual(state.solidColors, [0: red, 1: blue])
    }

    @MainActor
    func testRecentColorsAreBoundedUniqueAndInvalidAssignmentsDoNotChangeState() {
        let state = state()
        for color in PartColor.curated { state.setPartColor(color, for: "base") }
        XCTAssertEqual(state.recentPartColors, Array(PartColor.curated.reversed().prefix(PartColor.maximumRecentCount)))
        state.setPartColor(PartColor.curated[5], for: "base")
        XCTAssertEqual(state.recentPartColors.first, PartColor.curated[5])
        XCTAssertEqual(Set(state.recentPartColors).count, state.recentPartColors.count)
        let before = state.solidColors
        state.setPartColor(PartColor(red: .nan, green: 0, blue: 0), for: "base")
        state.setPartColor(red, for: "missing")
        XCTAssertEqual(state.solidColors, before)
    }

    @MainActor
    func testSaveNewRetainsColorsAndRecentChoicesWithoutOtherHistory() throws {
        let state = state()
        state.setPartColor(red, for: "base")
        state.setPartColor(blue, for: "lid")
        let latest = try XCTUnwrap(state.revisions.last)
        let original = LADProject(messages: [], revisions: [ProjectRevision(model: .bracket), latest],
                                  selectedRevisionID: latest.id, recentPartColors: state.recentPartColors)
        let copy = try ProjectStore.decode(ProjectStore.encode(SaveNewProject.snapshot(from: original)))
        XCTAssertEqual(copy.revisions.count, 1)
        XCTAssertEqual(copy.revisions[0].partColors, ["base": red, "lid": blue])
        XCTAssertEqual(copy.recentPartColors, [blue, red])
    }

    @MainActor
    func testOnlySameProgramRebuildMigratesGenericPartColors() {
        let old = [PartNode(id: "solid/0", name: "Part 1", solidIndices: [0])]
        let named = [PartNode(id: "base", name: "Base", solidIndices: [0])]
        XCTAssertNil(AppState.retainedPartColors(["solid/0": red], in: named))
        XCTAssertEqual(AppState.retainedPartColors(["solid/0": red], in: named, remappingGenericFrom: old), ["base": red])
    }

    @MainActor
    private func state() -> AppState {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [3], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0]),
            PartNode(id: "lid", name: "Lid", solidIndices: [1])]),
            PartNode(id: "board", name: "Board", solidIndices: [2])]
        let revision = ProjectRevision(model: .bracket, partLayout: PartLayout(nodes: parts), parts: parts)
        let state = AppState()
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        return state
    }
}
