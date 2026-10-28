import XCTest
@testable import LAD

final class PartSelectionPresentationTests: XCTestCase {
    func testFeatureOwnerRemainsPartialEvenWhenItIsTheOnlySolid() {
        let selection = PartSelectionPresentation(solidIndices: [4], selectedSolids: [],
                                                 featureSelectedSolids: [4], explicitlySelected: false)
        XCTAssertEqual(selection, .partial)
        XCTAssertTrue(selection.isSelected)
    }

    func testAllFeatureOwnersDoNotTurnAFolderIntoAWholePartSelection() {
        XCTAssertEqual(PartSelectionPresentation(solidIndices: [2, 4], selectedSolids: [],
                                                featureSelectedSolids: [2, 4], explicitlySelected: false), .partial)
    }

    func testWholePartSelectionTakesPrecedenceOverItsFeatures() {
        XCTAssertEqual(PartSelectionPresentation(solidIndices: [4], selectedSolids: [4],
                                                featureSelectedSolids: [4], explicitlySelected: false), .full)
    }

    func testFolderIsPartialUntilAllItsPartsAreSelected() {
        XCTAssertEqual(PartSelectionPresentation(solidIndices: [2, 4], selectedSolids: [2],
                                                featureSelectedSolids: [], explicitlySelected: false), .partial)
        XCTAssertEqual(PartSelectionPresentation(solidIndices: [2, 4], selectedSolids: [2, 4],
                                                featureSelectedSolids: [], explicitlySelected: false), .full)
    }

    func testUnrelatedFeatureDoesNotSelectRowAndEmptyFoldersNeedExplicitSelection() {
        XCTAssertEqual(PartSelectionPresentation(solidIndices: [4], selectedSolids: [],
                                                featureSelectedSolids: [9], explicitlySelected: false), .none)
        XCTAssertEqual(PartSelectionPresentation(solidIndices: [], selectedSolids: [],
                                                featureSelectedSolids: [], explicitlySelected: false), .none)
        XCTAssertEqual(PartSelectionPresentation(solidIndices: [], selectedSolids: [],
                                                featureSelectedSolids: [], explicitlySelected: true), .full)
    }
}
