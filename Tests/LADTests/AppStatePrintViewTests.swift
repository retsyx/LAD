import Foundation
import XCTest
@testable import LAD

/// The 3D printing view and printing exports share one geometry pipeline.
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
    func testViewShowsPackedPrintingVersionAndExportsUseItsOrientations() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the 3D printing view and export pipeline test.")
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
        let face = try XCTUnwrap(preview.topology?.faces.first?.id)
        state.selectFeatures([face])
        XCTAssertEqual(state.selectedFeatures, [face])

        state.printView = true
        XCTAssertTrue(state.selectedFeatures.isEmpty, "Feature identities belong to one geometry")
        try await waitForPrintView(state)
        let printing = try XCTUnwrap(state.displayedMesh)
        XCTAssertNotEqual(printing.brepPath, preview.brepPath)
        XCTAssertEqual(printing.volume - preview.volume, Double.pi * 1.6 * 1.6 * 0.2, accuracy: 1e-4)
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

        state.togglePartVisibility([1])
        XCTAssertEqual(state.displayedSolidTransforms, layout, "Hiding a part never repacks the plate")
        state.togglePartVisibility([1])

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

        state.printView = false
        XCTAssertEqual(state.displayedMesh?.brepPath, preview.brepPath)
        XCTAssertTrue(state.displayedSolidTransforms.isEmpty)
    }

    @MainActor
    private func waitForPrintView(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while state.isPreparingPrintView, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isPreparingPrintView)
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
