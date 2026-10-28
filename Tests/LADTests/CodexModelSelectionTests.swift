import Foundation
import XCTest
@testable import LAD

final class CodexModelSelectionTests: XCTestCase {
    private let deep = CodexModelDescriptor(id: "deep-model", displayName: "Deep model",
                                           reasoningEfforts: ["low", "medium", "high", "ultra"].map { CodexReasoningOption(id: $0) },
                                           defaultReasoningEffort: "high", isDefault: true)
    private let quick = CodexModelDescriptor(id: "quick-model", displayName: "Quick model",
                                            reasoningEfforts: ["low", "medium", "high"].map { CodexReasoningOption(id: $0) },
                                            defaultReasoningEffort: "medium")

    func testStatusShowsCapturedModelAndReasoningIncludingConfiguredDefaults() {
        let captured = CodexModelSelection.statusLabel(modelID: deep.id, effort: .ultra,
                                                       models: [deep, quick], configuredModelID: quick.id,
                                                       configuredReasoningEffort: "medium")
        XCTAssertEqual(captured, "Deep model · Ultra")
        let nextRequest = CodexModelSelection.statusLabel(modelID: quick.id, effort: .high,
                                                          models: [deep, quick], configuredModelID: deep.id,
                                                          configuredReasoningEffort: "ultra")
        XCTAssertEqual(nextRequest, "Quick model · High")
        XCTAssertEqual(captured, "Deep model · Ultra", "A later selection must not change an active task's label")
        XCTAssertEqual(CodexModelSelection.statusLabel(modelID: "", effort: .defaultConfiguration,
                                                       models: [deep, quick], configuredModelID: deep.id,
                                                       configuredReasoningEffort: "ultra"), "Deep model · Ultra")
        XCTAssertEqual(CodexModelSelection.statusLabel(modelID: "custom-model", effort: .low,
                                                       models: [deep, quick], configuredModelID: nil,
                                                       configuredReasoningEffort: nil), "custom-model · Low")
    }


    func testEffectiveConfigurationUsesActualConfiguredIdentityWithoutInventingCapabilities() {
        let models = [deep, quick]
        XCTAssertEqual(CodexModelSelection.effectiveModel(id: "", models: models, configuredModelID: quick.id), quick)
        XCTAssertEqual(CodexModelSelection.effectiveModel(id: "", models: models, configuredModelID: nil), deep)
        XCTAssertEqual(CodexModelSelection.effectiveModel(id: "", models: models, configuredModelID: ""), deep)
        XCTAssertEqual(CodexModelSelection.effectiveModel(id: deep.id, models: models, configuredModelID: quick.id), deep)
        XCTAssertNil(CodexModelSelection.effectiveModel(id: "custom-model", models: models, configuredModelID: deep.id))
        XCTAssertNil(CodexModelSelection.effectiveModel(id: "", models: models, configuredModelID: "configured-custom-model"))
        XCTAssertTrue(CodexModelSelection.supportedEfforts(id: "custom-model", models: models, configuredModelID: nil).isEmpty)
    }

    func testSwitchingModelsReplacesUnsupportedEffortAndRestoresEachModelsLastChoice() throws {
        var preferences: [String: String] = [:]
        let models = [deep, quick]
        let firstQuick = CodexModelSelection.selectModel(quick.id, currentModel: deep.id, currentEffort: "ultra",
                                                        models: models, configuredModelID: deep.id, preferences: &preferences)
        XCTAssertEqual(firstQuick, "medium", "The quick model does not advertise Ultra")
        CodexModelSelection.rememberEffort("high", for: quick.id, preferences: &preferences)
        let restoredDeep = CodexModelSelection.selectModel(deep.id, currentModel: quick.id, currentEffort: "high",
                                                          models: models, configuredModelID: deep.id, preferences: &preferences)
        XCTAssertEqual(restoredDeep, "ultra")
        let restoredQuick = CodexModelSelection.selectModel(quick.id, currentModel: deep.id, currentEffort: restoredDeep,
                                                           models: models, configuredModelID: deep.id, preferences: &preferences)
        XCTAssertEqual(restoredQuick, "high")
    }

    func testNewModelKeepsCompatibleExplicitEffortButUsesConcreteDefaultForBlankOrStaleValues() throws {
        var preferences: [String: String] = [:]
        XCTAssertEqual(CodexModelSelection.selectModel(quick.id, currentModel: deep.id, currentEffort: "high",
                                                       models: [deep, quick], configuredModelID: nil, preferences: &preferences), "high")
        CodexModelSelection.rememberEffort("ultra", for: quick.id, preferences: &preferences)
        XCTAssertEqual(CodexModelSelection.selectModel(quick.id, currentModel: deep.id, currentEffort: "ultra",
                                                       models: [deep, quick], configuredModelID: nil, preferences: &preferences), "medium")
        CodexModelSelection.rememberEffort("", for: quick.id, preferences: &preferences)
        XCTAssertEqual(CodexModelSelection.selectModel(quick.id, currentModel: deep.id, currentEffort: "",
                                                       models: [deep, quick], configuredModelID: nil, preferences: &preferences), "medium")
        let noReasoning = CodexModelDescriptor(id: "no-reasoning", displayName: "No reasoning")
        XCTAssertEqual(CodexModelSelection.normalizedEffort("ultra", for: noReasoning), "")
    }

    func testConfiguredModelAliasRemembersItsExplicitEffortWithoutErasingUnknownDefaults() throws {
        var preferences: [String: String] = [:]
        let models = [deep, quick]
        let quickEffort = CodexModelSelection.selectModel(quick.id, currentModel: "", currentEffort: "ultra",
                                                         models: models, configuredModelID: deep.id, preferences: &preferences)
        XCTAssertEqual(quickEffort, "medium")
        XCTAssertEqual(CodexModelSelection.selectModel(deep.id, currentModel: quick.id, currentEffort: quickEffort,
                                                       models: models, configuredModelID: deep.id, preferences: &preferences), "ultra")
        XCTAssertEqual(CodexModelSelection.selectModel("", currentModel: deep.id, currentEffort: "ultra",
                                                       models: models, configuredModelID: deep.id, preferences: &preferences), "ultra")

        CodexModelSelection.rememberEffort("high", for: deep.id, preferences: &preferences)
        _ = CodexModelSelection.selectModel(quick.id, currentModel: "", currentEffort: "",
                                            models: models, configuredModelID: deep.id, preferences: &preferences)
        XCTAssertEqual(CodexModelSelection.selectModel(deep.id, currentModel: quick.id, currentEffort: "medium",
                                                       models: models, configuredModelID: deep.id, preferences: &preferences), "high",
                       "Unresolved configuration defaults must not erase an explicit model preference")
    }

    func testConfigurationModeRestoresBlankSemanticsOrItsOwnSupportedOverride() throws {
        var preferences: [String: String] = [:]
        let models = [deep, quick]
        XCTAssertEqual(CodexModelSelection.selectModel("", currentModel: deep.id, currentEffort: "high",
                                                       models: models, configuredModelID: quick.id, preferences: &preferences), "")
        CodexModelSelection.rememberEffort("low", for: "", preferences: &preferences)
        XCTAssertEqual(CodexModelSelection.selectModel("", currentModel: deep.id, currentEffort: "ultra",
                                                       models: models, configuredModelID: quick.id, preferences: &preferences), "low")
        CodexModelSelection.rememberEffort("ultra", for: "", preferences: &preferences)
        XCTAssertEqual(CodexModelSelection.selectModel("", currentModel: deep.id, currentEffort: "high",
                                                       models: models, configuredModelID: quick.id, preferences: &preferences), "")
    }

    func testCustomModelIdentifiersRetainOverridesWithoutClaimingCatalogCapabilities() throws {
        var preferences: [String: String] = [:]
        XCTAssertEqual(CodexModelSelection.selectModel("custom-model", currentModel: deep.id, currentEffort: "ultra",
                                                       models: [deep, quick], configuredModelID: nil, preferences: &preferences), "ultra")
        CodexModelSelection.rememberEffort("minimal", for: "custom-model", preferences: &preferences)
        XCTAssertEqual(CodexModelSelection.selectModel("custom-model", currentModel: deep.id, currentEffort: "high",
                                                       models: [deep, quick], configuredModelID: nil, preferences: &preferences), "minimal")
    }

    func testFutureAdvertisedEffortTokensRemainForwardableAndMalformedOverridesAreRejected() throws {
        let adaptive = try XCTUnwrap(CodexReasoningEffort(rawValue: "adaptive_deep"))
        XCTAssertEqual(adaptive.rawValue, "adaptive_deep")
        XCTAssertEqual(adaptive.title, "Adaptive Deep")
        XCTAssertEqual(CodexReasoningEffort.none.rawValue, "none")
        XCTAssertEqual(CodexReasoningEffort.minimal.rawValue, "minimal")
        XCTAssertEqual(CodexReasoningEffort.defaultConfiguration.rawValue, "")
        for invalid in ["high\n", " high", "HIGH", "high\"", "reasoning=high", String(repeating: "a", count: 65)] {
            XCTAssertNil(CodexReasoningEffort(rawValue: invalid))
        }
        let future = CodexModelDescriptor(id: "future-model", displayName: "Future model",
                                          reasoningEfforts: [CodexReasoningOption(id: adaptive.rawValue)],
                                          defaultReasoningEffort: adaptive.rawValue)
        XCTAssertEqual(CodexModelSelection.normalizedEffort("ultra", for: future), adaptive.rawValue)
        XCTAssertEqual(CodexModelSelection.normalizedEffort(adaptive.rawValue, for: future), adaptive.rawValue)
        var preferences: [String: String] = [:]
        XCTAssertEqual(CodexModelSelection.selectModel(future.id, currentModel: deep.id, currentEffort: "ultra",
                                                       models: [deep, future], configuredModelID: nil, preferences: &preferences), adaptive.rawValue)
    }
}
