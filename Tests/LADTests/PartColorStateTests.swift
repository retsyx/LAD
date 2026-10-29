import XCTest
@testable import LAD

final class PartColorStateTests: XCTestCase {
    private let red = PartColor(red: 0.8, green: 0.1, blue: 0.1)
    private let blue = PartColor(red: 0.1, green: 0.2, blue: 0.8)

    func testCurrentColorsFollowStablePartOwnershipAndResetToNeutral() throws {
        let nodes = hierarchy()
        XCTAssertEqual(PartColorState.resolved(in: nodes, overrides: [:]), ["base": red])
        XCTAssertEqual(PartColorState.solidColors(in: nodes, overrides: ["base": blue, "lid": red]),
                       [2: blue, 0: red])
        let reset = try PartColorState.applying(changes: [.init(partID: "base", color: nil)],
                                              to: ["base": blue, "lid": red], in: nodes)
        XCTAssertEqual(reset, ["base": PartColorState.defaultFinish, "lid": red])
        XCTAssertEqual(PartColorState.solidColors(in: nodes, overrides: reset), [2: PartColorState.defaultFinish, 0: red])
    }

    func testGroupAssignmentExpandsPhysicalOwnersAndResetIsExplicit() throws {
        let nodes = hierarchy()
        let changes = try PartColorState.normalized(changes: [.init(partID: "case", color: blue)], in: nodes)
        XCTAssertEqual(changes, [.init(partID: "base", color: blue), .init(partID: "lid", color: blue)])
        XCTAssertEqual(try PartColorState.applying(changes: changes, to: [:], in: nodes), ["base": blue, "lid": blue])
        XCTAssertEqual(try PartColorState.normalized(changes: [.init(partID: "case", color: nil)], in: nodes),
                       [.init(partID: "base", color: nil), .init(partID: "lid", color: nil)])
    }

    func testInvalidAndAmbiguousBatchesAreRejectedBeforeApplyingAnyChanges() {
        let nodes = hierarchy(), original = ["base": red]
        let batches: [[CADPartColorChange]] = [
            [.init(partID: "base", color: blue), .init(partID: "missing", color: red)],
            [.init(partID: "base", color: PartColor(red: .nan, green: 0, blue: 0))],
            [.init(partID: "base", color: PartColor(red: 1.1, green: 0, blue: 0))],
            [.init(partID: "case", color: blue), .init(partID: "base", color: red)],
            [.init(partID: "base", color: red), .init(partID: "base", color: red)],
            [.init(partID: "empty", color: blue)]
        ]
        for changes in batches {
            XCTAssertThrowsError(try PartColorState.applying(changes: changes, to: original, in: nodes))
            XCTAssertEqual(original, ["base": red])
        }
        XCTAssertNoThrow(try PartColorState.normalized(changes: [.init(partID: "case", color: red),
                                                               .init(partID: "base", color: red)], in: nodes))
    }

    func testExpandedPhysicalGroupChangesDoNotRecolorItsChildren() throws {
        let nodes = [PartNode(id: "case", name: "Case", solidIndices: [0], children: [
            PartNode(id: "lid", name: "Lid", solidIndices: [1])])]
        XCTAssertEqual(try PartColorState.applyingPhysical(changes: [.init(partID: "case", color: red),
            .init(partID: "lid", color: blue)], to: [:], in: nodes), ["case": red, "lid": blue])
    }

    func testNeutralResetAndExplicitNeutralOverlapHaveTheSameCurrentColor() throws {
        let assignments = [CADPartColorChange(partID: "case", color: nil),
                           CADPartColorChange(partID: "base", color: PartColorState.defaultFinish)]
        XCTAssertEqual(try PartColorState.applying(changes: assignments, to: ["base": blue], in: hierarchy()),
                       ["base": PartColorState.defaultFinish, "lid": PartColorState.defaultFinish])
        XCTAssertEqual(try PartColorState.applying(changes: Array(assignments.reversed()), to: [:], in: hierarchy()),
                       ["base": PartColorState.defaultFinish, "lid": PartColorState.defaultFinish])
    }

    private func hierarchy() -> [PartNode] {
        [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [2], color: red),
            PartNode(id: "lid", name: "Lid", solidIndices: [0])]),
         PartNode(id: "empty", name: "Empty", solidIndices: [], children: [])]
    }
}
