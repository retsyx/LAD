import Foundation
import XCTest
@testable import LAD

final class ProjectCodexSettingsTests: XCTestCase {
    func testModelReasoningAndPerModelMemoryTravelWithCompleteZIPProject() throws {
        var original = project()
        original.codexSettings = CodexProjectSettings(model: "design-model", reasoningEffort: "ultra",
                                                     reasoningByModel: ["design-model": "ultra", "quick-model": "medium"])
        let encoded = try ProjectStore.encode(original)
        XCTAssertEqual(encoded.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(encoded)) as? [String: Any])
        let settings = try XCTUnwrap(manifest["codexSettings"] as? [String: Any])
        XCTAssertEqual(settings["model"] as? String, "design-model")
        XCTAssertEqual(settings["reasoningEffort"] as? String, "ultra")
        XCTAssertEqual(settings["reasoningByModel"] as? [String: String], original.codexSettings?.reasoningByModel)
        let restored = try ProjectStore.decode(encoded)
        XCTAssertEqual(restored.codexSettings, original.codexSettings)
        XCTAssertEqual(restored.projectID, original.projectID)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.selectedRevisionID, original.selectedRevisionID)
        XCTAssertEqual(restored.revisions.map(\.id), original.revisions.map(\.id))
        XCTAssertEqual(restored.revisions.map(\.model), original.revisions.map(\.model))
    }

    func testProjectsWithoutSavedSelectionDoNotAcquireAnotherProjectsChoice() throws {
        let original = project()
        let restored = try ProjectStore.decode(ProjectStore.encode(original))
        XCTAssertNil(restored.codexSettings)
        var configured = project()
        configured.codexSettings = CodexProjectSettings(model: "configured-elsewhere", reasoningEffort: "low")
        _ = try ProjectStore.decode(ProjectStore.encode(configured))
        XCTAssertNil(try ProjectStore.decode(ProjectStore.encode(original)).codexSettings)
    }

    func testReasoningMemoryIsIsolatedBetweenProjectsAndPortableCopies() throws {
        let models = [
            CodexModelDescriptor(id: "deep", displayName: "Deep", reasoningEfforts: ["low", "ultra"].map { CodexReasoningOption(id: $0) }, defaultReasoningEffort: "ultra"),
            CodexModelDescriptor(id: "quick", displayName: "Quick", reasoningEfforts: ["low", "high"].map { CodexReasoningOption(id: $0) }, defaultReasoningEffort: "low")
        ]
        var first = project()
        first.codexSettings = CodexProjectSettings(model: "deep", reasoningEffort: "ultra", reasoningByModel: ["quick": "low"])
        var second = project()
        second.codexSettings = CodexProjectSettings(model: "deep", reasoningEffort: "low", reasoningByModel: ["quick": "high"])
        var firstSettings = try XCTUnwrap(ProjectStore.decode(ProjectStore.encode(first)).codexSettings)
        var secondSettings = try XCTUnwrap(ProjectStore.decode(ProjectStore.encode(second)).codexSettings)
        XCTAssertEqual(CodexModelSelection.selectModel("quick", currentModel: firstSettings.model, currentEffort: firstSettings.reasoningEffort,
                                                       models: models, configuredModelID: nil, preferences: &firstSettings.reasoningByModel), "low")
        XCTAssertEqual(CodexModelSelection.selectModel("quick", currentModel: secondSettings.model, currentEffort: secondSettings.reasoningEffort,
                                                       models: models, configuredModelID: nil, preferences: &secondSettings.reasoningByModel), "high")
        XCTAssertEqual(firstSettings.reasoningByModel["deep"], "ultra")
        XCTAssertEqual(secondSettings.reasoningByModel["deep"], "low")
        var copy = firstSettings
        CodexModelSelection.rememberEffort("high", for: "quick", preferences: &copy.reasoningByModel)
        XCTAssertEqual(firstSettings.reasoningByModel["quick"], "low")
        XCTAssertEqual(second.codexSettings?.reasoningByModel["quick"], "high")
    }

    func testMalformedSelectionsAreRejectedOnWriteAndRead() throws {
        let invalid = [
            CodexProjectSettings(model: String(repeating: "a", count: 257)),
            CodexProjectSettings(model: String(repeating: "🧱", count: 65)),
            CodexProjectSettings(model: "model\nnext"),
            CodexProjectSettings(reasoningEffort: "high\""),
            CodexProjectSettings(reasoningEffort: "HIGH"),
            CodexProjectSettings(reasoningByModel: ["model\u{0}": "high"]),
            CodexProjectSettings(reasoningByModel: ["model": " high"]),
            CodexProjectSettings(reasoningByModel: Dictionary(uniqueKeysWithValues: (0...256).map { ("model-\($0)", "high") }))
        ]
        let original = project()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(ProjectStore.encode(original))) as? [String: Any])
        for settings in invalid {
            var value = original
            value.codexSettings = settings
            XCTAssertThrowsError(try ProjectStore.encode(value))
            var changed = manifest
            changed["codexSettings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
            let corrupted = try ProjectZIP.encode(JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try ProjectStore.decode(corrupted))
        }
    }

    func testCustomModelAndFutureReasoningTokensRemainPortable() throws {
        var value = project()
        value.codexSettings = CodexProjectSettings(model: "provider/custom:model-v2", reasoningEffort: "adaptive_deep",
                                                  reasoningByModel: ["": "", "provider/custom:model-v2": "adaptive_deep"])
        XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(value)).codexSettings, value.codexSettings)
    }

    func testAutosaveRestoreAndSaveCopyKeepIndependentDocumentChoices() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-project-model-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("LAD", isDirectory: true))
        var first = project()
        first.codexSettings = CodexProjectSettings(model: "deep", reasoningEffort: "ultra", reasoningByModel: ["quick": "low"])
        var second = project()
        second.codexSettings = CodexProjectSettings(model: "quick", reasoningEffort: "medium", reasoningByModel: ["deep": "high"])
        let firstID = try XCTUnwrap(first.projectID), secondID = try XCTUnwrap(second.projectID)
        let firstURL = try await store.write(project: first, projectID: firstID, title: "First", sequence: 1)
        let secondURL = try await store.write(project: second, projectID: secondID, title: "Second", sequence: 2)
        let restoredFirst = try await store.restoreRecent(preferredURL: firstURL, projectID: firstID)
        let restoredSecond = try await store.restoreRecent(preferredURL: secondURL, projectID: secondID)
        XCTAssertEqual(restoredFirst?.project.codexSettings, first.codexSettings)
        XCTAssertEqual(restoredSecond?.project.codexSettings, second.codexSettings)
        let copy = directory.appendingPathComponent("Copy.lad")
        try await store.writeCopy(first, to: copy)
        XCTAssertEqual(try ProjectStore.read(from: copy).codexSettings, first.codexSettings)
        XCTAssertEqual(try ProjectStore.read(from: secondURL).codexSettings, second.codexSettings)
    }

    private func project() -> LADProject {
        let first = ProjectRevision(model: .bracket)
        var wider = ModelSpec.bracket
        wider.title = "Wider bracket"
        wider.script = wider.script.replacingOccurrences(of: "box(80, 50, 6", with: "box(100, 50, 6")
        let last = ProjectRevision(model: wider)
        return LADProject(messages: [ChatMessage(role: "user", content: "Make a bracket"),
                                     ChatMessage(role: "assistant", content: "I’ll make the base and mounting holes.", phase: "commentary"),
                                     ChatMessage(role: "assistant", content: "Model ready.", phase: "final_answer"),
                                     ChatMessage(role: "user", content: "Make it wider")],
                          revisions: [first, last], selectedRevisionID: last.id, projectID: UUID())
    }
}
