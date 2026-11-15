import AppKit
import Metal
import XCTest
@testable import LAD

final class CADAgentPrintVersionTests: XCTestCase {
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

    private static let splitWhenPrinting = """
    result = cq.Assembly(name="Kit", metadata={"lad_id": "kit"}).add(cq.Solid.makeBox(10, 10, 4), name="Base", metadata={"lad_id": "base"})
    if lad.print:
        result.add(cq.Solid.makeBox(2, 2, 2, cq.Vector(20, 0, 0)), name="Brim", metadata={"lad_id": "brim"})
    """

    private static let failsWhenPrinting = """
    if lad.print:
        raise ValueError("bridge layer is too thin")
    result = cq.Assembly(name="Kit", metadata={"lad_id": "kit"}).add(cq.Solid.makeBox(10, 10, 4), name="Base", metadata={"lad_id": "base"})
    """

    @MainActor
    func testPrintBuildsLayoutRendersAndCommitChecksUseTheSameProgram() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for 3D printing version agent tools.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-agent-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, program) in [("kit.py", Self.program), ("split.py", Self.splitWhenPrinting), ("fails.py", Self.failsWhenPrinting)] {
            try Data(program.utf8).write(to: root.appendingPathComponent(name))
        }
        let tools = try CADAgentTools(directory: root, python: EngineService.defaultPython, threads: 2,
            current: nil, currentPreview: nil, engine: EngineService())
        defer { tools.cancel() }

        let ordinary = try await tools.handle(name: "lad_build", arguments: ["programPath": "kit.py"]).metadata
        XCTAssertEqual(ordinary["definesPrintVersion"] as? Bool, true)
        XCTAssertNil(ordinary["print"])
        let pins = try XCTUnwrap(ordinary["printDown"] as? [[String: Any]])
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?["direction"] as? [Double], [0, 0, 1])
        let ordinaryID = try XCTUnwrap(ordinary["artifactID"] as? String)

        let printing = try await tools.handle(name: "lad_build", arguments: ["programPath": "kit.py", "print": true]).metadata
        XCTAssertEqual(printing["print"] as? Bool, true)
        let printingID = try XCTUnwrap(printing["artifactID"] as? String)
        XCTAssertNotEqual(printingID, ordinaryID)
        let added = try XCTUnwrap(printing["volume"] as? Double) - XCTUnwrap(ordinary["volume"] as? Double)
        XCTAssertEqual(added, Double.pi * 1.6 * 1.6 * 0.2, accuracy: 1e-4)
        do {
            _ = try await tools.handle(name: "lad_build", arguments: ["programPath": "kit.py", "print": "yes"])
            XCTFail("The printing option is a boolean")
        } catch { XCTAssertTrue(error.localizedDescription.contains("true or false")) }

        do {
            _ = try await tools.handle(name: "lad_render", arguments: ["artifactID": ordinaryID, "printLayout": true])
            XCTFail("A program with a printing version renders its layout from the printing artifact")
        } catch { XCTAssertTrue(error.localizedDescription.contains("print=true")) }
        do {
            _ = try await tools.handle(name: "lad_render", arguments: ["artifactID": printingID, "printLayout": true,
                                                                       "jointPositions": ["hinge": 1]])
            XCTFail("Printing layouts replace assembly poses")
        } catch { XCTAssertTrue(error.localizedDescription.contains("jointPositions")) }
        if MTLCreateSystemDefaultDevice() != nil {
            let layout = try await tools.handle(name: "lad_render", arguments: ["artifactID": printingID, "printLayout": true,
                                                                                "width": 320, "height": 256])
            XCTAssertEqual(layout.metadata["printLayout"] as? Bool, true)
            let built = try await tools.handle(name: "lad_render", arguments: ["artifactID": printingID,
                                                                               "width": 320, "height": 256])
            XCTAssertNotEqual(layout.image?.data, built.image?.data)
        }

        let model = ModelSpec(title: "Untitled design", summary: "CAD program built and validated by LAD.", units: "mm", script: Self.program)
        XCTAssertNotNil(tools.validatedPrintPreview(for: model))
        do {
            _ = try await tools.committableCandidate(artifactID: printingID)
            XCTFail("Only the ordinary build is committed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ordinary build")) }
        let candidate = try await tools.committableCandidate(artifactID: ordinaryID)
        XCTAssertEqual(candidate.model.script, Self.program)

        do {
            _ = try await tools.handle(name: "lad_build", arguments: ["programPath": "split.py", "print": true])
            XCTFail("A printing version cannot add parts")
        } catch { XCTAssertTrue(error.localizedDescription.contains("brim")) }

        let fails = try await tools.handle(name: "lad_build", arguments: ["programPath": "fails.py"]).metadata
        do {
            _ = try await tools.committableCandidate(artifactID: try XCTUnwrap(fails["artifactID"] as? String))
            XCTFail("A failing printing version blocks the commit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too thin")) }
    }
}
