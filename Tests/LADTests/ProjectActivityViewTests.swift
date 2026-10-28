import AppKit
import XCTest
@testable import LAD

final class ProjectActivityViewTests: XCTestCase {
    @MainActor
    func testActivityPanelStartsHiddenWithoutCreatingAWindow() {
        let controller = ProjectActivityPanelController()
        XCTAssertFalse(controller.isVisible, "Tool activity is optional and must never appear in the default UI.")
        XCTAssertFalse(controller.hasPanel, "A closed activity pane must not create a hidden extra document window.")
        controller.hide()
        controller.close()
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(controller.hasPanel)
    }

    func testActivityCopyPreservesCompleteOrderedInputsOutputsAndOutcomes() throws {
        let input = "python external_surface.py --input source.step\n" + String(repeating: "loft α β γ\n", count: 5_000)
        let output = String(repeating: "native geometry valid\n", count: 5_000) + "all done"
        let first = ProjectActivityEvent(id: "command:1", category: "command", title: "Inspect source",
                                         status: "completed", input: input, output: output, durationSeconds: 2.5)
        let second = ProjectActivityEvent(id: "tool:2", category: "tool", title: "lad_render", status: "failed",
                                          input: "{\"view\":\"top\"}", output: "The design is empty.")
        let task = ProjectTaskAudit(userMessageID: UUID(), model: "test-model", reasoningEffort: "high",
                                   status: "failed", events: [first, second])
        let text = ProjectActivityTranscript.text(for: [task])
        XCTAssertTrue(text.contains("test-model"))
        XCTAssertTrue(text.contains("high"))
        XCTAssertTrue(text.contains("failed"))
        XCTAssertTrue(text.contains("Duration: 2.5 s"))
        XCTAssertTrue(text.contains(input), "Copy must include full tool inputs without truncation.")
        XCTAssertTrue(text.contains(output), "Copy must include full command output without truncation.")
        let firstPosition = try XCTUnwrap(text.range(of: "Inspect source")?.lowerBound)
        let secondPosition = try XCTUnwrap(text.range(of: "lad_render")?.lowerBound)
        XCTAssertLessThan(firstPosition, secondPosition)
        XCTAssertTrue(ProjectActivityTranscript.text(for: second).contains("The design is empty."))
    }

    func testActivityCopyRetainsExactCandidateAndProducerRecipes() {
        let recipe = "result = cq.Workplane('XY').circle(5).extrude(8)\n"
        let producer = "# Surface producer\nprint('λ mesh')\n"
        let event = ProjectActivityEvent(id: "build:1", category: "tool", title: "lad_build", status: "completed", files: [
            ProjectActivityFile(name: "program.py", path: "workspace/program.py", data: Data(recipe.utf8)),
            ProjectActivityFile(name: "producer.py", path: "workspace/producer.py", data: Data(producer.utf8))
        ])
        let text = ProjectActivityTranscript.text(for: event)
        XCTAssertTrue(text.contains(recipe))
        XCTAssertTrue(text.contains(producer))
        XCTAssertTrue(text.contains("workspace/program.py"))
        XCTAssertTrue(text.contains("workspace/producer.py"))
    }
}
