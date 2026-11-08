import Foundation
import XCTest
@testable import LAD

final class EngineSTEPColorTests: XCTestCase {
    private let red = PartColor(red: 1, green: 0, blue: 0)
    private let blue = PartColor(red: 0, green: 0, blue: 1)
    private let green = PartColor(red: 0, green: 1, blue: 0)

    @MainActor
    func testInvalidExportColorsFailBeforeReadingGeometryOrStartingPython() async throws {
        let preview = unavailablePreview()
        for colors in [[-1: red], [2: red], [0: PartColor(red: -0.1, green: 0, blue: 0)],
                       [0: PartColor(red: .infinity, green: 0, blue: 0)], [0: PartColor(red: .nan, green: 0, blue: 0)]] {
            do {
                _ = try await EngineService().exportSTEP(preview, solidColors: colors, python: "/missing/python", threads: 1)
                XCTFail("Invalid current RGB must not start an export.")
            } catch {
                XCTAssertEqual(error.localizedDescription,
                    "The export colors must refer to available parts and use finite sRGB components between 0 and 1.")
            }
        }
        do {
            _ = try await EngineService().exportSTEP(preview, solidColors: [0: red], python: "/missing/python", threads: 1)
            XCTFail("Colored exports cannot fall back to unrelated raw STEP data.")
        } catch EngineExportError.nativeArtifactUnavailable {}
    }

    @MainActor
    func testFullAndSubsetSTEPColorsFollowCurrentRGBAndUseColorAwareCacheWithoutRebuilding() async throws {
        try requireRuntime()
        let service = EngineService()
        let preview = try await service.buildPreview(assembly(), python: EngineService.defaultPython, threads: 2)
        let native = URL(fileURLWithPath: try XCTUnwrap(preview.brepPath))
        defer { try? FileManager.default.removeItem(at: native.deletingLastPathComponent()) }
        let nativeBefore = try Data(contentsOf: native)
        let first = try await service.exportSTEP(preview, solidColors: [0: red, 1: blue],
                                                 python: EngineService.defaultPython, threads: 2)
        let firstPalette = try await palette(first)
        assertContains(red, in: firstPalette)
        assertContains(blue, in: firstPalette)

        var reordered = [1: blue]
        reordered[0] = red
        let cached = try await service.exportSTEP(preview, solidColors: reordered, python: "/missing/python", threads: 1)
        XCTAssertEqual(cached, first, "Dictionary insertion order must not change the export cache key.")
        let recolored = try await service.exportSTEP(preview, solidColors: [0: green, 1: blue],
                                                     python: EngineService.defaultPython, threads: 2)
        let recoloredPalette = try await palette(recolored)
        assertContains(green, in: recoloredPalette)
        assertContains(blue, in: recoloredPalette)
        XCTAssertFalse(contains(red, in: recoloredPalette), "Recoloring must not return the previous red cached STEP.")
        XCTAssertNotEqual(recolored, first)

        let neutral = try await service.exportSTEP(preview, solidColors: [0: PartColorState.defaultFinish, 1: blue],
                                                   python: EngineService.defaultPython, threads: 2)
        let neutralPalette = try await palette(neutral)
        assertContains(PartColorState.defaultFinish, in: neutralPalette)
        XCTAssertFalse(contains(green, in: neutralPalette))
        XCTAssertFalse(contains(red, in: neutralPalette))

        let subset = try await service.exportSTEP(preview, solidIndices: [1], solidColors: [0: red, 1: blue],
                                                  python: EngineService.defaultPython, threads: 2)
        let subsetPalette = try await palette(subset)
        assertContains(blue, in: subsetPalette)
        XCTAssertFalse(contains(red, in: subsetPalette), "Subset colors must use original native indices, not renumbered positions.")
        let imported = try await EngineService().previewSTEP(subset, parts: nil, python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: imported.stepPath).deletingLastPathComponent()) }
        XCTAssertEqual(imported.solids, 1)
        XCTAssertEqual(imported.volume, 30, accuracy: 1e-7)
        for (actual, expected) in zip(imported.bounds, [20.0, 7, 9, 25, 9, 12]) { XCTAssertEqual(actual, expected, accuracy: 1e-6) }
        XCTAssertEqual(try Data(contentsOf: native), nativeBefore, "Color export must reuse, not mutate or replay, session geometry.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.stepPath))
        try FileManager.default.removeItem(at: native)
        let subsetCached = try await service.exportSTEP(preview, solidIndices: [1], solidColors: [1: blue, 0: red],
                                                        python: "/missing/python", threads: 1)
        XCTAssertEqual(subsetCached, subset)
    }

    @MainActor
    func testExplicitColorsBypassPreviouslyGeneratedWholeSTEPBytes() async throws {
        try requireRuntime()
        let service = EngineService()
        let preview = try await service.build(assembly(), python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: preview.stepPath).deletingLastPathComponent()) }
        let original = try Data(contentsOf: URL(fileURLWithPath: preview.stepPath))
        let direct = try await service.exportSTEP(preview, python: "/missing/python", threads: 1)
        XCTAssertEqual(direct, original, "An internal geometry-only export may still reuse exact original STEP bytes.")
        let colored = try await service.exportSTEP(preview, solidColors: [0: red, 1: blue],
                                                   python: EngineService.defaultPython, threads: 2)
        XCTAssertNotEqual(colored, original)
        let colors = try await palette(colored)
        assertContains(red, in: colors)
        assertContains(blue, in: colors)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(preview.brepPath))
        do {
            _ = try await service.exportSTEP(preview, solidColors: [0: green, 1: blue],
                                             python: EngineService.defaultPython, threads: 2)
            XCTFail("A new color variant needs native geometry rather than returning stale raw STEP bytes.")
        } catch EngineExportError.nativeArtifactUnavailable {}
    }

    @MainActor
    func testPrintingArrangementBypassesOriginalSTEPAndHasSeparateColorAndSubsetCache() async throws {
        try requireRuntime()
        let service = EngineService()
        let preview = try await service.build(assembly(), python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: preview.stepPath).deletingLastPathComponent()) }
        let native = URL(fileURLWithPath: try XCTUnwrap(preview.brepPath))
        let nativeBefore = try Data(contentsOf: native)
        let original = try await service.exportSTEP(preview, python: "/missing/python", threads: 1)
        let arranged = try await service.exportSTEP(preview, arrangeFor3DPrinting: true,
                                                    python: EngineService.defaultPython, threads: 2)
        XCTAssertNotEqual(arranged, original, "Printing arrangement must bypass original-coordinate STEP bytes.")
        let imported = try await EngineService().previewSTEP(arranged, parts: nil, python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: imported.stepPath).deletingLastPathComponent()) }
        XCTAssertEqual(imported.solids, 2)
        XCTAssertEqual(imported.volume, preview.volume, accuracy: 1e-6)
        XCTAssertEqual(imported.bounds[2], 0, accuracy: 1e-6)
        let colors = [0: red, 1: blue]
        let colored = try await service.exportSTEP(preview, solidColors: colors, arrangeFor3DPrinting: true,
                                                   python: EngineService.defaultPython, threads: 2)
        let coloredPalette = try await palette(colored)
        assertContains(red, in: coloredPalette)
        assertContains(blue, in: coloredPalette)
        let subset = try await service.exportSTEP(preview, solidIndices: [1], solidColors: colors,
                                                  arrangeFor3DPrinting: true, python: EngineService.defaultPython, threads: 2)
        let subsetPalette = try await palette(subset)
        assertContains(blue, in: subsetPalette)
        XCTAssertFalse(contains(red, in: subsetPalette))
        let importedSubset = try await EngineService().previewSTEP(subset, parts: nil, python: EngineService.defaultPython, threads: 2)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: importedSubset.stepPath).deletingLastPathComponent()) }
        XCTAssertEqual(importedSubset.solids, 1)
        XCTAssertEqual(importedSubset.volume, 30, accuracy: 1e-6)
        XCTAssertEqual(importedSubset.bounds[2], 0, accuracy: 1e-6)
        XCTAssertEqual(try Data(contentsOf: native), nativeBefore, "Arranging export must leave the live native geometry unchanged.")
        try FileManager.default.removeItem(at: native)
        let cached = try await service.exportSTEP(preview, solidColors: colors, arrangeFor3DPrinting: true,
                                                  python: "/missing/python", threads: 1)
        XCTAssertEqual(cached, colored)
        let cachedSubset = try await service.exportSTEP(preview, solidIndices: [1], solidColors: colors,
                                                        arrangeFor3DPrinting: true, python: "/missing/python", threads: 1)
        XCTAssertEqual(cachedSubset, subset)
        do {
            _ = try await service.exportSTEP(preview, solidColors: colors, python: "/missing/python", threads: 1)
            XCTFail("Original-coordinate exports must not reuse an arranged color variant.")
        } catch EngineExportError.nativeArtifactUnavailable {}
    }

    @MainActor
    func testIndividualExportsRejectInvalidPartitionsBeforeReadingNativeGeometry() async throws {
        let preview = unavailablePreview()
        for parts in [[], [[]], [[0], [0]], [[0, 0]], [[-1]], [[2]], [[0, 1], [1]]] {
            do {
                _ = try await EngineService().exportSTEPParts(preview, parts: parts, python: "/missing/python", threads: 1)
                XCTFail("Invalid individual part ownership must not start a worker.")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Select distinct available parts to export individually.")
            }
        }
        do {
            _ = try await EngineService().exportSTEPParts(preview, parts: [[0]], python: "/missing/python", threads: 1)
            XCTFail("Individual export requires owned native geometry.")
        } catch EngineExportError.nativeArtifactUnavailable {}
    }

    @MainActor
    func testIndividualExportsPreserveOrderColorsGeometryPrintingPlacementAndSeparateCache() async throws {
        try requireRuntime()
        let service = EngineService()
        let preview = try await service.buildPreview(assembly(), python: EngineService.defaultPython, threads: 2)
        let native = URL(fileURLWithPath: try XCTUnwrap(preview.brepPath))
        defer { try? FileManager.default.removeItem(at: native.deletingLastPathComponent()) }
        let nativeBefore = try Data(contentsOf: native)
        let colors = [0: red, 1: blue]
        let ordinary = try await service.exportSTEPParts(preview, parts: [[1], [0]], solidColors: colors,
                                                         python: EngineService.defaultPython, threads: 2)
        let arranged = try await service.exportSTEPParts(preview, parts: [[1], [0]], solidColors: colors,
                                                         arrangeFor3DPrinting: true, python: EngineService.defaultPython, threads: 2)
        XCTAssertEqual(ordinary.count, 2)
        XCTAssertEqual(arranged.count, 2)
        var printingBounds: [[Double]] = []
        for (printing, files) in [(false, ordinary), (true, arranged)] {
            for index in files.indices {
                let expectedColor = index == 0 ? blue : red
                let palette = try await palette(files[index])
                assertContains(expectedColor, in: palette)
                XCTAssertFalse(contains(index == 0 ? red : blue, in: palette))
                let imported = try await EngineService().previewSTEP(files[index], parts: nil,
                    python: EngineService.defaultPython, threads: 2)
                defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: imported.stepPath).deletingLastPathComponent()) }
                XCTAssertEqual(imported.solids, 1)
                XCTAssertEqual(imported.volume, index == 0 ? 30 : 24, accuracy: 1e-6)
                if printing {
                    XCTAssertEqual(imported.bounds[2], 0, accuracy: 1e-6)
                    printingBounds.append(imported.bounds)
                } else {
                    let expected = index == 0 ? [20.0, 7, 9, 25, 9, 12] : [0.0, 0, 0, 2, 3, 4]
                    for (actual, value) in zip(imported.bounds, expected) { XCTAssertEqual(actual, value, accuracy: 1e-6) }
                }
            }
        }
        let a = printingBounds[0], b = printingBounds[1]
        XCTAssertGreaterThanOrEqual(max(b[0] - a[3], a[0] - b[3], b[1] - a[4], a[1] - b[4]), 50 - 1e-6)
        XCTAssertEqual(try Data(contentsOf: native), nativeBefore)
        try FileManager.default.removeItem(at: native)
        let cached = try await service.exportSTEPParts(preview, parts: [[1], [0]], solidColors: [1: blue, 0: red],
            arrangeFor3DPrinting: true, python: "/missing/python", threads: 1)
        XCTAssertEqual(cached, arranged)
        let ordinaryCached = try await service.exportSTEPParts(preview, parts: [[1], [0]], solidColors: colors,
            python: "/missing/python", threads: 1)
        XCTAssertEqual(ordinaryCached, ordinary)
        do {
            _ = try await service.exportSTEPParts(preview, parts: [[0], [1]], solidColors: colors,
                arrangeFor3DPrinting: true, python: "/missing/python", threads: 1)
            XCTFail("A differently ordered partition must not return mismatched cached files.")
        } catch EngineExportError.nativeArtifactUnavailable {}
    }

    private func contains(_ expected: PartColor, in palette: [PartColor]) -> Bool {
        palette.contains { abs($0.red - expected.red) < 1e-5 && abs($0.green - expected.green) < 1e-5 && abs($0.blue - expected.blue) < 1e-5 }
    }

    private func assertContains(_ expected: PartColor, in palette: [PartColor], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(contains(expected, in: palette), "Missing sRGB color \(expected) in independent STEPCAF palette \(palette).", file: file, line: line)
    }

    @MainActor
    private func palette(_ bytes: Data) async throws -> [PartColor] {
        let python = EngineService.defaultPython
        return try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-step-palette-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let step = directory.appendingPathComponent("export.step")
            try bytes.write(to: step)
            let script = """
            import json,sys
            from OCP.STEPCAFControl import STEPCAFControl_Reader
            from OCP.IFSelect import IFSelect_RetDone
            from OCP.TDocStd import TDocStd_Document
            from OCP.TCollection import TCollection_ExtendedString
            from OCP.TDF import TDF_LabelSequence
            from OCP.XCAFDoc import XCAFDoc_DocumentTool,XCAFDoc_ColorTool
            from OCP.Quantity import Quantity_Color,Quantity_TOC_sRGB
            doc=TDocStd_Document(TCollection_ExtendedString('colors'))
            reader=STEPCAFControl_Reader(); reader.SetColorMode(True)
            assert reader.ReadFile(sys.argv[1]) == IFSelect_RetDone
            assert reader.Transfer(doc)
            tool=XCAFDoc_DocumentTool.ColorTool_s(doc.Main())
            labels=TDF_LabelSequence(); tool.GetColors(labels)
            colors=[]
            for index in range(1,labels.Length()+1):
                color=Quantity_Color()
                assert XCAFDoc_ColorTool.GetColor_s(labels.Value(index),color)
                r,g,b=color.Values(Quantity_TOC_sRGB)
                colors.append({'red':r,'green':g,'blue':b})
            print('LAD_STEP_COLORS='+json.dumps(colors))
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", script, step.path]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LADError.message("STEPCAF verification failed: " + String(decoding: diagnostic, as: UTF8.self)) }
            guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("LAD_STEP_COLORS=") }) else {
                throw LADError.message("STEPCAF verification returned no RGB palette.")
            }
            return try JSONDecoder().decode([PartColor].self, from: Data(line.dropFirst("LAD_STEP_COLORS=".count).utf8))
        }.value
    }

    private func requireRuntime() throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for colored STEP round-trip and cache tests.")
        }
    }

    private func unavailablePreview() -> PreviewMesh {
        PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1], volume: 1,
                    area: 6, solids: 2, faces: 12, buildSeconds: 0, threads: 1,
                    stepPath: "/unregistered/model.step", brepPath: "/unregistered/model.brep")
    }

    private func assembly() -> ModelSpec {
        ModelSpec(title: "Colored STEP assembly", summary: "Two unchanged exact bodies with current RGB finishes.", units: "mm", script: """
        result=cq.Assembly(name='Parts', metadata={'lad_id':'parts'})
        result.add(cq.Solid.makeBox(2,3,4), name='First', metadata={'lad_id':'first'})
        result.add(cq.Solid.makeBox(5,2,3), name='Second', loc=cq.Location((20,7,9)), metadata={'lad_id':'second'})
        """)
    }
}
