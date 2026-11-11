import Foundation
import XCTest
@testable import LAD

final class AgentVendorSelectionTests: XCTestCase {
    func testFirstLaunchChoiceIsRequiredOnlyWhenBothAgentsAreAvailableWithoutAChoice() {
        XCTAssertTrue(AgentVendorPreference.needsChoice(stored: nil, available: [.codex, .claude]))
        XCTAssertFalse(AgentVendorPreference.needsChoice(stored: .claude, available: [.codex, .claude]))
        XCTAssertFalse(AgentVendorPreference.needsChoice(stored: nil, available: [.claude]))
        XCTAssertFalse(AgentVendorPreference.needsChoice(stored: nil, available: [.codex]))
        XCTAssertFalse(AgentVendorPreference.needsChoice(stored: nil, available: []))
    }

    func testNewDesignsUseTheChosenOrOnlyAvailableAgent() {
        XCTAssertEqual(AgentVendorPreference.defaultVendor(stored: .claude, available: [.codex, .claude]), .claude)
        XCTAssertEqual(AgentVendorPreference.defaultVendor(stored: .codex, available: [.codex, .claude]), .codex)
        XCTAssertEqual(AgentVendorPreference.defaultVendor(stored: nil, available: [.claude]), .claude)
        XCTAssertEqual(AgentVendorPreference.defaultVendor(stored: nil, available: [.codex]), .codex)
        XCTAssertEqual(AgentVendorPreference.defaultVendor(stored: nil, available: [.codex, .claude]), .codex)
        XCTAssertEqual(AgentVendorPreference.defaultVendor(stored: nil, available: []), .codex)
        // An explicit choice is never silently replaced by another installation.
        XCTAssertEqual(AgentVendorPreference.defaultVendor(stored: .claude, available: [.codex]), .claude)
    }

    func testAnExplicitExecutableKeepsItsAgentAvailableEvenWhenItsFileIsMissing() {
        let key = ClaudeExecutable.preferenceKey
        let old = UserDefaults.standard.object(forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("/nonexistent/LAD-test/claude", forKey: key)
        XCTAssertFalse(AgentVendor.claude.isInstalled)
        XCTAssertTrue(AgentVendor.claude.isAvailable)
    }

    func testSelectionsSavedBeforeAgentChoiceRemainCodexSelections() throws {
        let legacy = Data(#"{"model":"gpt-design","reasoningEffort":"high","reasoningByModel":{"gpt-design":"high"}}"#.utf8)
        let settings = try JSONDecoder().decode(CodexProjectSettings.self, from: legacy)
        XCTAssertEqual(settings.vendor, .codex)
        XCTAssertEqual(settings.model, "gpt-design")
        XCTAssertEqual(settings.reasoningEffort, "high")
        XCTAssertEqual(settings.otherAgents, [:])
    }

    func testSwitchingAgentsRestoresEachAgentsLastChoiceInTheProject() throws {
        var settings = CodexProjectSettings(vendor: .codex, model: "gpt-design", reasoningEffort: "high",
                                            reasoningByModel: ["gpt-design": "high"])
        settings.switchAgent(to: .claude)
        XCTAssertEqual(settings.vendor, .claude)
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.reasoningEffort, "")
        XCTAssertEqual(settings.otherAgents["codex"], AgentModelChoice(model: "gpt-design", reasoningEffort: "high",
                                                                        reasoningByModel: ["gpt-design": "high"]))
        settings.model = "opus"; settings.reasoningEffort = "xhigh"; settings.reasoningByModel = ["opus": "xhigh"]
        settings.switchAgent(to: .codex)
        XCTAssertEqual(settings.model, "gpt-design")
        XCTAssertEqual(settings.reasoningEffort, "high")
        XCTAssertEqual(settings.otherAgents.keys.sorted(), ["claude"])
        settings.switchAgent(to: .claude)
        XCTAssertEqual(settings.model, "opus")
        XCTAssertEqual(settings.reasoningEffort, "xhigh")
        XCTAssertEqual(settings.reasoningByModel, ["opus": "xhigh"])
        let restored = try JSONDecoder().decode(CodexProjectSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
    }

    func testAgentModelAndEffortTravelWithTheDesignFile() throws {
        var value = project()
        value.codexSettings = CodexProjectSettings(vendor: .claude, model: "opus", reasoningEffort: "max",
            reasoningByModel: ["opus": "max"],
            otherAgents: ["codex": AgentModelChoice(model: "gpt-design", reasoningEffort: "low", reasoningByModel: [:])])
        let restored = try ProjectStore.decode(ProjectStore.encode(value))
        XCTAssertEqual(restored.codexSettings, value.codexSettings)
        var queued = value
        queued.queuedRequests = [ProjectQueuedRequest(content: "Make it thicker", codexSettings: value.codexSettings)]
        XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(queued)).queuedRequests?.first?.codexSettings?.vendor, .claude)
    }

    func testMalformedAgentMemoryIsRejected() throws {
        let invalid = [
            CodexProjectSettings(vendor: .claude, otherAgents: ["claude": AgentModelChoice(model: "opus")]),
            CodexProjectSettings(vendor: .codex, otherAgents: ["gemini": AgentModelChoice(model: "x")]),
            CodexProjectSettings(vendor: .codex, otherAgents: ["claude": AgentModelChoice(model: "opus\nnext")]),
            CodexProjectSettings(vendor: .codex, otherAgents: ["claude": AgentModelChoice(reasoningEffort: "HIGH")])
        ]
        for settings in invalid {
            var value = project()
            value.codexSettings = settings
            XCTAssertThrowsError(try ProjectStore.encode(value))
        }
    }

    func testTaskAuditsRecordTheAgentThatRanThem() throws {
        let message = ChatMessage(role: "user", content: "Make a bracket")
        let task = ProjectTaskAudit(userMessageID: message.id, agent: AgentVendor.claude.rawValue, model: "opus", reasoningEffort: "high")
        XCTAssertEqual(task.actorDescription, "Claude · opus · High")
        XCTAssertNoThrow(try ProjectStore.validateTaskAudits([task], messages: [message]))
        var unknown = task
        unknown.agent = "other"
        XCTAssertThrowsError(try ProjectStore.validateTaskAudits([unknown], messages: [message]))
        let legacy = ProjectTaskAudit(userMessageID: message.id, model: "gpt-design", reasoningEffort: "high")
        XCTAssertEqual(legacy.actorDescription, "gpt-design · High")
    }

    @MainActor
    func testClaudeRequestsAreRoutedToTheClaudeCatalogAndRemainSeparateFromCodex() {
        XCTAssertTrue(CodexModelCatalog.catalog(for: .codex) === CodexModelCatalog.shared)
        XCTAssertTrue(CodexModelCatalog.catalog(for: .claude) === CodexModelCatalog.claude)
        XCTAssertFalse(CodexModelCatalog.shared === CodexModelCatalog.claude)
        XCTAssertEqual(CodexModelCatalog.claude.vendor, .claude)
    }

    private func project() -> LADProject {
        let revision = ProjectRevision(model: .bracket)
        return LADProject(messages: [ChatMessage(role: "user", content: "Make a bracket")],
                          revisions: [revision], selectedRevisionID: revision.id, projectID: UUID())
    }
}
