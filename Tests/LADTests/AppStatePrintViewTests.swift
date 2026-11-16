import Foundation
import XCTest
@testable import LAD

/// The 3D printing views and printing exports share one geometry pipeline.
final class AppStatePrintViewTests: XCTestCase {
    private static let program = """
    plate = cq.Workplane("XY").box(40, 20, 6).val()
    plate = plate.cut(cq.Solid.makeCylinder(3, 3, cq.Vector(0, 0, 0)))
    plate = plate.cut(cq.Solid.makeCylinder(1.6, 10, cq.Vector(0, 0, -5)))
    if lad.print:
        plate = plate.fuse(cq.Solid.makeCylinder(1.6, 0.2, cq.Vector(0, 0, -0.2))).clean()
    peg = cq.Solid.makeCylinder(3, 15, cq.Vector(30, 0, 0))
    result = (cq.Assembly(name="Kit", metadata={"lad_id": "kit"})
        .add(plate, name="Plate", metadata={"lad_id": "plate", "lad_print_down": (0, 0, 1)})
        .add(peg, name="Peg", metadata={"lad_id": "peg"}))
    """

    @MainActor
    func testViewsShowPrintingVersionAndPackedLayoutAndExportsUseBoth() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the 3D printing views and export pipeline test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-print-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ModelSpec(title: "Counterbored kit", summary: "Printing version fixture.", units: "mm", script: Self.program)
        let engine = EngineService()
        let preview = try await engine.buildPreview(model, python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: preview.stepPath).deletingLastPathComponent()) }
        XCTAssertEqual(preview.printVersion, true)
        let parts = try XCTUnwrap(preview.parts)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("autosaves")))
        defer { state.cancel() }
        let revision = ProjectRevision(model: model, preview: preview, partLayout: PartLayout(nodes: parts), parts: parts)
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        // Unchanged features of both parts, and the counterbore floor and
        // shaft bore that the printing version's bridge changes.
        let design = try XCTUnwrap(preview.topology)
        let floor = try XCTUnwrap(design.faces.first { plateFace($0, "PLANE", z: 0) }?.id)
        let top = try XCTUnwrap(design.faces.first { plateFace($0, "PLANE", z: 3) }?.id)
        let bore = try XCTUnwrap(design.faces.first { plateFace($0, "CYLINDER", radius: 1.6) }?.id)
        let corner = try XCTUnwrap(design.vertices.first { $0.id.solidIndex == 0 && $0.position == [20, 10, 3] }?.id)
        let rim = try XCTUnwrap(design.edges.first {
            $0.id.solidIndex == 0 && $0.type == "LINE" && $0.startPoint?[2] == 3 && $0.endPoint?[2] == 3
        }?.id)
        let pegFace = try XCTUnwrap(design.faces.first { $0.id.solidIndex == 1 }?.id)
        var selection = [floor, top, bore, corner, rim, pegFace]
        state.selectFeatures(selection)
        state.selectParts([1])
        XCTAssertEqual(state.selectedFeatures, selection)

        // The design itself, oriented and packed.
        let cameraKey = state.viewportCameraKey
        var command = state.viewportCommand
        state.printLayoutView = true
        XCTAssertEqual(state.selectedFeatures, selection, "The layout only places the same geometry")
        try await waitForPrintView(state)
        XCTAssertNotEqual(state.viewportCommand, command, "Placing the parts frames them")
        XCTAssertEqual(state.displayedMesh?.brepPath, preview.brepPath)
        XCTAssertEqual(Set(state.displayedSolidTransforms.keys), [0, 1])
        state.printLayoutView = false
        XCTAssertFalse(state.isPreparingPrintView)
        XCTAssertTrue(state.displayedSolidTransforms.isEmpty)

        // The printing version where the design was built, under the same camera.
        command = state.viewportCommand
        state.printVersionView = true
        XCTAssertEqual(state.selectedFeatures, selection, "Selections stay while the printing version is prepared")
        try await waitForPrintView(state)
        XCTAssertEqual(state.viewportCommand, command, "Showing the printing version keeps the camera")
        XCTAssertEqual(state.viewportCameraKey, cameraKey)
        let printing = try XCTUnwrap(state.displayedMesh)
        XCTAssertNotEqual(printing.brepPath, preview.brepPath)
        XCTAssertEqual(printing.volume - preview.volume, Double.pi * 1.6 * 1.6 * 0.2, accuracy: 1e-4)
        XCTAssertTrue(state.displayedSolidTransforms.isEmpty)

        // The same selection on the printing version, measured there: the
        // bridge closes the counterbore floor and shortens the bore.
        let printed = try XCTUnwrap(printing.topology)
        var printedSelection = state.selectedFeatures
        XCTAssertEqual(printedSelection.count, selection.count)
        XCTAssertEqual(state.selectedSolids, [1])
        let closedFloor = try XCTUnwrap(printed.face(for: printedSelection[0]))
        XCTAssertTrue(plateFace(closedFloor, "PLANE", z: 0))
        XCTAssertEqual(closedFloor.area, .pi * 9, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(printed.face(for: printedSelection[2])).area, 2 * .pi * 1.6 * 2.8, accuracy: 1e-6)
        for (index, original) in [(1, top), (5, pegFace)] {
            let face = try XCTUnwrap(printed.face(for: printedSelection[index])), unchanged = try XCTUnwrap(design.face(for: original))
            XCTAssertEqual(face.area, unchanged.area, accuracy: 1e-9); XCTAssertEqual(face.center, unchanged.center, accuracy: 1e-9)
        }
        XCTAssertEqual(printed.vertex(for: printedSelection[3])?.position, [20, 10, 3])
        let printedRim = try XCTUnwrap(printed.edge(for: printedSelection[4])), designRim = try XCTUnwrap(design.edge(for: rim))
        XCTAssertEqual(Set([printedRim.startPoint, printedRim.endPoint]), Set([designRim.startPoint, designRim.endPoint]))
        XCTAssertEqual(state.measurementReport?.features, printedSelection)
        XCTAssertEqual(state.measurementReport?.solidIndices, [1])
        XCTAssertEqual(try area(state, printedSelection[0]), .pi * 9, accuracy: 1e-6)

        // Both: the printing version oriented and packed, as exported.
        state.printLayoutView = true
        try await waitForPrintView(state)
        XCTAssertEqual(state.displayedMesh?.brepPath, printing.brepPath)
        let layout = state.displayedSolidTransforms
        XCTAssertEqual(Set(layout.keys), [0, 1])
        let viewBounds = try (0..<2).map { solid -> [Double] in
            let part = try XCTUnwrap(printing.topology?.parts.first { $0.solidIndex == solid })
            return ViewportRigidTransform.bounds(part.bounds, matrix: try XCTUnwrap(ViewportRigidTransform.matrix(layout[solid]!)))
        }
        for box in viewBounds { XCTAssertEqual(box[2], 0, accuracy: 1e-6) }
        XCTAssertGreaterThanOrEqual(max(viewBounds[1][0] - viewBounds[0][3], viewBounds[0][0] - viewBounds[1][3],
                                        viewBounds[1][1] - viewBounds[0][4], viewBounds[0][1] - viewBounds[1][4]), 50 - 1e-6)
        XCTAssertEqual(layout[0]?[10] ?? 0, -1, accuracy: 1e-9, "The pinned top face of the plate faces the bed")

        XCTAssertEqual(state.selectedFeatures, printedSelection, "The layout only places the same geometry")
        state.togglePartVisibility([1])
        XCTAssertEqual(state.displayedSolidTransforms, layout, "Hiding a part never repacks the plate")
        state.togglePartVisibility([1])
        selection.removeLast(); printedSelection.removeLast()
        XCTAssertEqual(state.selectedFeatures, printedSelection, "Hiding a part deselects its features")

        let full = directory.appendingPathComponent("printing.step")
        state.exportSTEP(to: full, for3DPrinting: true)
        try await finish(state, expecting: full)
        let exported = try await readBounds(full)
        XCTAssertEqual(exported.count, 2)
        for (actual, expected) in zip(exported.sorted { $0[0] < $1[0] }, viewBounds.sorted { $0[0] < $1[0] }) {
            for (a, b) in zip(actual, expected) { XCTAssertEqual(a, b, accuracy: 1e-3) }
        }
        let subset = directory.appendingPathComponent("peg.step")
        state.exportSTEP(to: subset, solidIndices: [1], for3DPrinting: true)
        try await finish(state, expecting: subset)
        let pegs = try await readBounds(subset)
        let peg = try XCTUnwrap(pegs.first)
        XCTAssertEqual(Array(peg[0..<3]), [0, 0, 0].map(Double.init), accuracy: 1e-3)
        XCTAssertEqual(peg[5] - peg[2], 15, accuracy: 1e-3)

        // Prepared views return at once, without an empty interim display,
        // and switching back restores the design's own selection.
        command = state.viewportCommand
        state.printVersionView = false
        XCTAssertEqual(state.viewportCommand, command, "Leaving the printing version keeps the camera")
        XCTAssertFalse(state.isPreparingPrintView)
        XCTAssertEqual(state.displayedMesh?.brepPath, preview.brepPath)
        XCTAssertEqual(Set(state.displayedSolidTransforms.keys), [0, 1])
        XCTAssertEqual(state.selectedFeatures, selection)
        try await waitForMeasurement(state)
        XCTAssertEqual(state.measurementReport?.features, selection, "Placed parts are measured natively")
        state.printVersionView = true
        XCTAssertFalse(state.isPreparingPrintView)
        XCTAssertEqual(state.displayedSolidTransforms, layout)
        XCTAssertEqual(state.viewportCommand, command)
        XCTAssertEqual(state.selectedFeatures, printedSelection)
        state.printLayoutView = false
        XCTAssertNotEqual(state.viewportCommand, command, "Returning the parts frames them")

        // A selection made on the printing version maps back to the design,
        // without the printing-only bridge underside.
        let underside = try XCTUnwrap(printed.faces.first { plateFace($0, "PLANE", z: -0.2) }?.id)
        state.selectFeatures([underside, printedSelection[0]])
        command = state.viewportCommand
        state.printVersionView = false
        XCTAssertEqual(state.viewportCommand, command, "Leaving the printing version keeps the camera")
        XCTAssertEqual(state.displayedMesh?.brepPath, preview.brepPath)
        XCTAssertTrue(state.displayedSolidTransforms.isEmpty)
        XCTAssertEqual(state.selectedFeatures, [floor])
        XCTAssertEqual(try area(state, floor), .pi * (9 - 1.6 * 1.6), accuracy: 1e-6)
    }

    private func plateFace(_ face: CADFace, _ type: String, z: Double? = nil, radius: Double? = nil) -> Bool {
        face.id.solidIndex == 0 && face.type == type &&
            z.map { abs(face.center[2] - $0) < 1e-6 && abs(abs(face.normal?[2] ?? 0) - 1) < 1e-9 } ?? true &&
            radius.map { abs((face.radius ?? 0) - $0) < 1e-6 } ?? true
    }

    @MainActor
    private func area(_ state: AppState, _ face: CADFeatureID) throws -> Double {
        try XCTUnwrap(state.measurementReport?.metrics.first { $0.id == face.id + ":area" }?.values.first)
    }

    @MainActor
    private func waitForPrintView(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while state.isPreparingPrintView, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isPreparingPrintView)
    }

    @MainActor
    private func waitForMeasurement(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while state.isMeasuring, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(state.measurementError)
        XCTAssertFalse(state.isMeasuring)
    }

    @MainActor
    private func finish(_ state: AppState, expecting url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isWorking)
        XCTAssertNil(state.error)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LADError.message("No STEP was exported: \(state.error ?? state.activity)")
        }
    }

    @MainActor
    private func readBounds(_ url: URL) async throws -> [[Double]] {
        let python = EngineService.defaultPython
        return try await Task.detached {
            let script = """
            import json,sys
            import cadquery as cq
            boxes=[]
            for solid in cq.importers.importStep(sys.argv[1]).val().Solids():
                box=solid.BoundingBox(tolerance=1e-6)
                boxes.append([box.xmin,box.ymin,box.zmin,box.xmax,box.ymax,box.zmax])
            print('LAD_PRINT_BOUNDS='+json.dumps(boxes))
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", script, url.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .last(where: { $0.hasPrefix("LAD_PRINT_BOUNDS=") }) else { throw LADError.message("No exported bounds.") }
            return try JSONDecoder().decode([[Double]].self, from: Data(line.dropFirst("LAD_PRINT_BOUNDS=".count).utf8))
        }.value
    }
}

private func XCTAssertEqual(_ actual: [Double], _ expected: [Double], accuracy: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (a, b) in zip(actual, expected) { XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line) }
}
