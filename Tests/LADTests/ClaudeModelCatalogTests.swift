import Foundation
import XCTest
@testable import LAD

final class ClaudeModelCatalogTests: XCTestCase {
    private let initialize = #"""
    {"models":[
     {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
     {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"For complex work","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
     {"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5","description":"Efficient","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
     {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","description":"Fast"}
    ],"account":{"subscriptionType":"max"}}
    """#

    @MainActor
    func testCatalogUsesListedModelsTheirEffortsAndTheCLIsAppliedSettings() throws {
        let settings = Data(#"{"effective":{"model":"opus"},"applied":{"model":"claude-opus-5-5","effort":"xhigh"}}"#.utf8)
        let snapshot = try CodexModelCatalog.decodeClaudeCatalog(initialize: Data(initialize.utf8), settings: settings)
        XCTAssertEqual(snapshot.models.map(\.id), ["opus", "sonnet", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(snapshot.models.filter(\.isDefault).map(\.id), ["opus"])
        XCTAssertEqual(snapshot.models[0].displayName, "Opus 5.5")
        XCTAssertEqual(snapshot.models[0].reasoningEfforts.map(\.id), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(snapshot.models[0].defaultReasoningEffort, "xhigh")
        XCTAssertEqual(snapshot.models[1].defaultReasoningEffort, "high")
        XCTAssertEqual(snapshot.models[2].reasoningEfforts, [])
        XCTAssertNil(snapshot.models[2].defaultReasoningEffort)
        XCTAssertEqual(snapshot.configuredModelID, "opus")
        XCTAssertEqual(snapshot.configuredReasoningEffort, "xhigh")
        // A new design starts from that installed configuration.
        let initial = AppState.normalizedCodexSettings(CodexProjectSettings(vendor: .claude), models: snapshot.models,
            configuredModelID: snapshot.configuredModelID, configuredReasoningEffort: snapshot.configuredReasoningEffort)
        XCTAssertEqual(initial.vendor, .claude)
        XCTAssertEqual(initial.model, "opus")
        XCTAssertEqual(initial.reasoningEffort, "xhigh")
    }

    func testConfiguredFullModelNamesMapToTheirListedAliasAndCustomNamesRemain() throws {
        func configured(_ model: String) throws -> String? {
            let settings = Data(#"{"effective":{"model":"\#(model)"},"applied":{"model":"\#(model)"}}"#.utf8)
            return try CodexModelCatalog.decodeClaudeCatalog(initialize: Data(initialize.utf8), settings: settings).configuredModelID
        }
        XCTAssertEqual(try configured("claude-sonnet-5-5"), "sonnet")
        XCTAssertEqual(try configured("opus[1m]"), "opus[1m]")
        XCTAssertNil(try configured("default"))
        let unconfigured = try CodexModelCatalog.decodeClaudeCatalog(initialize: Data(initialize.utf8), settings: nil)
        XCTAssertNil(unconfigured.configuredModelID)
        XCTAssertNil(unconfigured.configuredReasoningEffort)
        XCTAssertEqual(unconfigured.models.first(where: \.isDefault)?.id, "opus")
    }

    func testMalformedCatalogsAreRejected() {
        let invalid = [
            #"{"models":[]}"#,
            #"{"models":[{"value":"default","resolvedModel":"claude-opus-5-5"}]}"#,
            #"{"models":[{"value":"opus"},{"value":"opus"}]}"#,
            #"{"models":[{"value":"has space"}]}"#,
            #"{"models":[{"value":"opus","supportedEffortLevels":["High"]}]}"#,
            #"{"models":[{"value":"opus","supportedEffortLevels":["high","high"]}]}"#,
            #"{"nothing":true}"#
        ]
        for value in invalid {
            XCTAssertThrowsError(try CodexModelCatalog.decodeClaudeCatalog(initialize: Data(value.utf8), settings: nil), value)
        }
    }

    @MainActor
    func testLookupUsesOnlyControlRequestsOfTheChosenInstallation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-Claude-Catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        let models = try JSONSerialization.jsonObject(with: Data(initialize.utf8))
        let modelsJSON = String(decoding: try JSONSerialization.data(withJSONObject: models), as: UTF8.self)
        let script = """
        #!/usr/bin/python3
        import json, os, sys
        ROOT = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(ROOT, 'arguments.json'), 'w') as f: json.dump(sys.argv[1:], f)
        MODELS = json.loads(\(String(decoding: try JSONEncoder().encode(modelsJSON), as: UTF8.self)))
        for line in sys.stdin:
            request = json.loads(line)
            with open(os.path.join(ROOT, 'requests.jsonl'), 'a') as f: f.write(json.dumps(request) + '\\n')
            subtype = request['request']['subtype']
            body = MODELS if subtype == 'initialize' else {'effective': {'model': 'sonnet'}, 'applied': {'model': 'claude-sonnet-5-5', 'effort': 'medium'}}
            print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': request['request_id'], 'response': body}}), flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let catalog = CodexModelCatalog(vendor: .claude)
        await catalog.refresh(executable: executable.path, force: true)
        XCTAssertNil(catalog.error)
        XCTAssertEqual(catalog.models.map(\.id), ["opus", "sonnet", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(catalog.configuredModelID, "sonnet")
        XCTAssertEqual(catalog.configuredReasoningEffort, "medium")
        XCTAssertTrue(catalog.matches(executable: executable.path))
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("arguments.json"))) as? [String])
        XCTAssertEqual(arguments, ClaudeCodeJob.controlArguments)
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(requests.compactMap { $0["type"] as? String }, ["control_request", "control_request"],
                       "Catalog lookup must never send a user message")
    }

    @MainActor
    func testMissingInstallationExplainsHowToInstallClaudeCode() async {
        let catalog = CodexModelCatalog(vendor: .claude)
        await catalog.refresh(executable: "/nonexistent/claude", force: true)
        XCTAssertEqual(catalog.error, "Install Claude Code to load models.")
        XCTAssertTrue(catalog.models.isEmpty)
    }
}
