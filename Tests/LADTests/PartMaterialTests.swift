import XCTest
@testable import LAD

final class PartMaterialTests: XCTestCase {
    private let aluminum = PartMaterial(name: "Aluminum 6061", density: 2.70)
    private let abs = PartMaterial(name: "ABS", density: 1.05)
    private let custom = PartMaterial(name: "Glass-filled nylon", density: 1.36)

    private let nodes = [PartNode(id: "case", name: "Case", solidIndices: [3], children: [
        PartNode(id: "base", name: "Base", solidIndices: [0]),
        PartNode(id: "lid", name: "Lid", solidIndices: [1])]),
        PartNode(id: "folder", name: "Folder", solidIndices: [], children: [
            PartNode(id: "board", name: "Board", solidIndices: [2])])]

    func testStandardMaterialsAreValidUniqueAndCoverCommonMetalsAndPlastics() {
        XCTAssertTrue(PartMaterial.standard.allSatisfy(\.isValid))
        XCTAssertEqual(Set(PartMaterial.standard.map(\.key)).count, PartMaterial.standard.count)
        for name in ["Aluminum 6061", "Stainless Steel 304", "Brass", "Copper", "Titanium Ti-6Al-4V", "ABS", "PLA", "PETG",
                     "Polycarbonate", "Nylon 6/6", "Acetal (POM)"] {
            XCTAssertTrue(PartMaterial.standard.contains { $0.name == name }, name)
        }
        XCTAssertTrue(PartMaterial.standard.contains(aluminum))
        let names = ["b", "A", "a 2", "a 10"].map { PartMaterial(name: $0, density: 1) }.sorted(by: PartMaterial.alphabetical).map(\.name)
        XCTAssertEqual(names, ["A", "a 2", "a 10", "b"])
    }

    func testValidationRejectsEmptyMultilineAndOutOfRangeMaterials() {
        XCTAssertEqual(try PartMaterial.validated(name: "  Oak ", density: 0.75), PartMaterial(name: "Oak", density: 0.75))
        for (name, density) in [("", 1.0), ("Two\nLines", 1.0), ("Zero", 0.0), ("Negative", -1.0), ("Huge", 101.0),
                                ("NaN", .nan), ("Infinite", .infinity), (String(repeating: "x", count: 257), 1.0)] {
            XCTAssertThrowsError(try PartMaterial.validated(name: name, density: density), name)
            XCTAssertFalse(PartMaterial(name: name, density: density).isValid, name)
        }
        XCTAssertFalse(PartMaterial(name: " Padded", density: 1).isValid)
    }

    func testFoldersExpandToPhysicalPartsAndConflictingBatchesFail() throws {
        let changes = try PartMaterialState.normalized(changes: [
            CADPartMaterialChange(partID: "case", material: aluminum),
            CADPartMaterialChange(partID: "folder", material: abs)], in: nodes)
        XCTAssertEqual(changes.map(\.partID), ["base", "board", "case", "lid"])
        let applied = try PartMaterialState.applyingPhysical(changes: changes, to: [:], in: nodes)
        XCTAssertEqual(applied, ["case": aluminum, "base": aluminum, "lid": aluminum, "board": abs])
        XCTAssertEqual(PartMaterialState.solidDensities(in: nodes, materials: applied), [0: 2.70, 1: 2.70, 2: 1.05, 3: 2.70])

        let cleared = try PartMaterialState.applyingPhysical(changes: [CADPartMaterialChange(partID: "lid", material: nil)],
                                                            to: applied, in: nodes)
        XCTAssertNil(cleared["lid"])
        XCTAssertNil(PartMaterialState.solidDensities(in: nodes, materials: cleared)[1])

        for batch in [[CADPartMaterialChange(partID: "case", material: aluminum), CADPartMaterialChange(partID: "lid", material: abs)],
                      [CADPartMaterialChange(partID: "missing", material: abs)],
                      [CADPartMaterialChange(partID: "base", material: abs), CADPartMaterialChange(partID: "base", material: abs)],
                      [CADPartMaterialChange(partID: "base", material: PartMaterial(name: "Bad", density: 0))]] {
            XCTAssertThrowsError(try PartMaterialState.normalized(changes: batch, in: nodes))
        }
        XCTAssertThrowsError(try PartMaterialState.normalized(changes: [CADPartMaterialChange(partID: "empty", material: abs)],
            in: [PartNode(id: "empty", name: "Empty", solidIndices: [], children: [])]))
    }

    func testAgentChangesKeepNewerUserEditsAndDropRemovedParts() throws {
        let started = ["base": abs, "lid": abs]
        // During the task the user changed the lid and unassigned the base.
        let current = ["lid": aluminum]
        let changes = [CADPartMaterialChange(partID: "base", material: custom),
                       CADPartMaterialChange(partID: "lid", material: custom),
                       CADPartMaterialChange(partID: "board", material: custom),
                       CADPartMaterialChange(partID: "removed", material: custom)]
        let result = try PartMaterialState.applyingAgentChanges(changes, in: nodes, current: current, startedWith: started)
        XCTAssertEqual(result, ["lid": aluminum, "board": custom])
    }

    func testStableIdentitiesRetainMaterialsAndOnlyGenericRebuildsMigrate() {
        let changed = [PartNode(id: "base", name: "Base", solidIndices: [1]), PartNode(id: "new", name: "New", solidIndices: [0])]
        XCTAssertEqual(PartMaterialState.retained(["base": abs, "lid": aluminum], in: changed), ["base": abs])
        XCTAssertNil(PartMaterialState.retained(["lid": aluminum], in: changed))
        let old = [PartNode(id: "solid/0", name: "Part 1", solidIndices: [0])]
        let named = [PartNode(id: "base", name: "Base", solidIndices: [0])]
        XCTAssertNil(PartMaterialState.retained(["solid/0": abs], in: named))
        XCTAssertEqual(PartMaterialState.retained(["solid/0": abs], in: named, remappingGenericFrom: old), ["base": abs])
    }

    func testDesignMaterialsMergeByNameWithoutDuplicates() throws {
        let merged = PartMaterialState.merging([custom, PartMaterial(name: "GLASS-FILLED NYLON", density: 2), abs,
                                                PartMaterial(name: "Invalid", density: 0)], into: [abs])
        XCTAssertEqual(merged, [abs, custom])
        XCTAssertNoThrow(try PartMaterialState.validateDesignMaterials(merged))
        XCTAssertThrowsError(try PartMaterialState.validateDesignMaterials([abs, PartMaterial(name: "abs", density: 1.2)]))
        XCTAssertThrowsError(try PartMaterialState.validateDesignMaterials([PartMaterial(name: "Bad", density: -1)]))
    }

    func testPartMeasurementsReportMassIncludingUnassignedZeroMass() throws {
        let topology = CADTopology(vertices: [], edges: [], faces: [], parts: [
            CADPart(solidIndex: 0, area: 6, volume: 1_000, bounds: [0, 0, 0, 10, 10, 10], centroid: [5, 5, 5]),
            CADPart(solidIndex: 1, area: 6, volume: 2_000, bounds: [0, 0, 0, 10, 10, 20], centroid: [5, 5, 10])])
        let preview = PreviewMesh(bounds: [0, 0, 0, 10, 10, 20], volume: 3_000, area: 12, solids: 2, faces: 0,
                                  buildSeconds: 0, threads: 1, stepPath: "/unused.step", topology: topology)
        let report = try CADMeasurements.report(preview, features: [], solids: [0, 1])
        let unassigned = CADMeasurements.addingMass(to: report, topology: topology, densities: [:])
        let massIndex = try XCTUnwrap(unassigned.metrics.firstIndex { $0.id == "parts:mass" })
        XCTAssertEqual(unassigned.metrics[massIndex - 1].id, "parts:volume")
        XCTAssertEqual(unassigned.metrics[massIndex].values, [0])
        XCTAssertEqual(unassigned.metrics[massIndex].formattedValue, "0 g")

        let assigned = CADMeasurements.addingMass(to: unassigned, topology: topology, densities: [0: 2.70, 1: 1.05])
        XCTAssertEqual(assigned.metrics.filter { $0.id == "parts:mass" }.count, 1)
        XCTAssertEqual(try XCTUnwrap(assigned.metrics.first { $0.id == "parts:mass" }?.values.first), 2.7 + 2.1, accuracy: 1e-9)

        let feature = CADMeasurementReport(title: "Vertex", metrics: [], features: [], solidIndices: [])
        XCTAssertTrue(CADMeasurements.addingMass(to: feature, topology: topology, densities: [0: 1]).metrics.isEmpty,
                      "Only whole-part selections have mass.")
    }

    @MainActor
    func testLibraryPersistsCustomMaterialsAndProtectsStandardOnes() throws {
        let suite = "LAD-materials-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = PartMaterialLibrary(defaults: defaults)
        XCTAssertEqual(library.materials.count, PartMaterial.standard.count)
        XCTAssertEqual(library.materials, library.materials.sorted(by: PartMaterial.alphabetical))

        XCTAssertEqual(try library.add(name: " Glass-filled nylon ", density: 1.36), custom)
        XCTAssertTrue(library.isCustom(custom))
        XCTAssertEqual(try library.add(name: "Glass-filled nylon", density: 1.36), custom, "Adding an identical material is idempotent")
        XCTAssertThrowsError(try library.add(name: "glass-filled NYLON", density: 1.4))
        XCTAssertThrowsError(try library.add(name: "abs", density: 1.2), "Standard names stay unique")
        XCTAssertThrowsError(try library.add(name: "Zero", density: 0))
        XCTAssertEqual(library.material(named: "GLASS-FILLED nylon"), custom)

        let reopened = PartMaterialLibrary(defaults: defaults)
        XCTAssertEqual(reopened.customMaterials, [custom])
        XCTAssertTrue(reopened.materials.contains(custom))

        reopened.remove(abs)
        XCTAssertTrue(reopened.contains(abs), "Standard materials cannot be removed")
        reopened.remove(custom)
        XCTAssertFalse(reopened.contains(custom))
        XCTAssertTrue(PartMaterialLibrary(defaults: defaults).customMaterials.isEmpty)
        XCTAssertNil(defaults.object(forKey: PartMaterialLibrary.preferenceKey))

        // Corrupt or shadowing saved entries are ignored rather than trusted.
        defaults.set(try JSONEncoder().encode([PartMaterial(name: "ABS", density: 9), PartMaterial(name: "Bad", density: -1), custom]),
                     forKey: PartMaterialLibrary.preferenceKey)
        XCTAssertEqual(PartMaterialLibrary(defaults: defaults).customMaterials, [custom])
    }

    func testDensityEntryAcceptsLocalizedAndPlainNumbers() {
        XCTAssertEqual(PartMaterialPicker.density(from: " 2.7 "), 2.7)
        XCTAssertNil(PartMaterialPicker.density(from: "dense"))
        XCTAssertEqual(PartMaterialPicker.densityLabel(2.7), 2.7.formatted(.number.precision(.fractionLength(2...6))) + " g/cm³")
        XCTAssertEqual(PartMaterialPicker.densityLabel(0), "0 g/cm³")
    }
}
