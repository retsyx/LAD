import XCTest
@testable import LAD

final class AppStateCodexTests: XCTestCase {
    private let deep = CodexModelDescriptor(id: "deep", displayName: "Deep",
                                            reasoningEfforts: ["high", "ultra"].map { CodexReasoningOption(id: $0) },
                                            defaultReasoningEffort: "high", isDefault: true)
    private let quick = CodexModelDescriptor(id: "quick", displayName: "Quick",
                                             reasoningEfforts: ["low", "medium"].map { CodexReasoningOption(id: $0) },
                                             defaultReasoningEffort: "medium")

    @MainActor
    func testInitialSelectionPinsConfigurationAndIgnoresLaterConfigurationChanges() {
        let initial = AppState.normalizedCodexSettings(CodexProjectSettings(), models: [deep, quick],
                                                       configuredModelID: deep.id, configuredReasoningEffort: "ultra")
        XCTAssertEqual(initial.model, "deep")
        XCTAssertEqual(initial.reasoningEffort, "ultra")
        XCTAssertEqual(initial.reasoningByModel, ["deep": "ultra"])
        let restored = AppState.normalizedCodexSettings(initial, models: [deep, quick],
                                                        configuredModelID: quick.id, configuredReasoningEffort: "low")
        XCTAssertEqual(restored, initial)
    }

    @MainActor
    func testInitialModelUsesCatalogDefaultAndDoesNotInventAnUnavailableModel() {
        let resolved = AppState.normalizedCodexSettings(CodexProjectSettings(), models: [deep, quick],
                                                        configuredModelID: nil, configuredReasoningEffort: nil)
        XCTAssertEqual(resolved.model, "deep")
        XCTAssertEqual(resolved.reasoningEffort, "high")
        let unresolved = AppState.normalizedCodexSettings(CodexProjectSettings(), models: [],
                                                          configuredModelID: nil, configuredReasoningEffort: nil)
        XCTAssertEqual(unresolved, CodexProjectSettings())
    }

    @MainActor
    func testUnavailableSavedModelAndEffortSurviveWithoutInventedCapabilities() {
        let saved = CodexProjectSettings(model: "custom-provider/model", reasoningEffort: "adaptive_deep",
                                          reasoningByModel: ["custom-provider/model": "adaptive_deep", "deep": "ultra"])
        let restored = AppState.normalizedCodexSettings(saved, models: [deep, quick],
                                                        configuredModelID: quick.id, configuredReasoningEffort: "medium")
        XCTAssertEqual(restored, saved)
    }

    @MainActor
    func testKnownModelReconcilesStaleEffortWithinOnlyThatProjectsMemory() {
        let first = CodexProjectSettings(model: "quick", reasoningEffort: "ultra", reasoningByModel: ["quick": "ultra"])
        let second = CodexProjectSettings(model: "deep", reasoningEffort: "ultra", reasoningByModel: ["deep": "ultra"])
        let normalized = AppState.normalizedCodexSettings(first, models: [deep, quick],
                                                          configuredModelID: deep.id, configuredReasoningEffort: "ultra")
        XCTAssertEqual(normalized.reasoningEffort, "medium")
        XCTAssertEqual(normalized.reasoningByModel, ["quick": "medium"])
        XCTAssertEqual(second.reasoningByModel, ["deep": "ultra"])
        XCTAssertEqual(second.reasoningEffort, "ultra")
    }

    @MainActor
    func testIndependentProjectStateKeepsItsOwnSelectionAndPerModelMemory() {
        let first = AppState(), second = AppState()
        first.selectCodexModel("project-only-a")
        first.selectCodexReasoningEffort("high")
        second.selectCodexModel("project-only-b")
        second.selectCodexReasoningEffort("ultra")
        first.selectCodexModel("project-only-b")
        first.selectCodexReasoningEffort("medium")
        first.selectCodexModel("project-only-a")
        XCTAssertEqual(first.model, "project-only-a")
        XCTAssertEqual(first.reasoningEffort, .high)
        XCTAssertEqual(first.codexSettings.reasoningByModel["project-only-b"], "medium")
        XCTAssertEqual(second.model, "project-only-b")
        XCTAssertEqual(second.reasoningEffort, .ultra)
        XCTAssertEqual(second.codexSettings.reasoningByModel["project-only-b"], "ultra")
        // A composer becoming visible before session restore must not create
        // an unrelated empty iCloud document or overwrite the last project.
        XCTAssertNil(first.projectURL)
        XCTAssertNil(second.projectURL)
        XCTAssertNil(first.saveStatus)
        XCTAssertNil(second.saveStatus)
    }

    @MainActor
    func testCatalogNormalizationWaitsForProjectRestoreBeforeChangingOrSavingState() {
        let state = AppState()
        state.normalizeCodexSelection()
        XCTAssertEqual(state.codexSettings, CodexProjectSettings())
        XCTAssertNil(state.projectURL)
        XCTAssertNil(state.saveStatus)
    }
}
