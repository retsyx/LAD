import Foundation
import XCTest
@testable import LAD

final class CodexModelCatalogTests: XCTestCase {
    @MainActor
    func testUnsupportedModelLookupExplainsHowToRepairCodex() async throws {
        let rejection = try data(["id": 2, "error": ["code": -32601, "message": "Unknown method model/list"]])
        let fake = try FakeCatalog(responses: [rejection], configuration: nil)
        defer { fake.remove() }
        let catalog = CodexModelCatalog()
        await catalog.refresh(executable: fake.executable.path)
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertTrue(catalog.error?.contains("Update Codex and check its configuration") == true)
        XCTAssertTrue(catalog.error?.contains("Unknown method model/list") == true)
    }

    func testCatalogUsesActualModelIdentifiersAndAdvertisedCapabilities() throws {
        let page: [String: Any] = ["data": [
            ["id": "catalog-row", "model": "provider/model-a", "displayName": "Model A", "description": "A model",
             "supportedReasoningEfforts": [["reasoningEffort": "low", "description": "Fast"],
                                            ["reasoningEffort": "future_effort", "description": "Future capability"]],
             "defaultReasoningEffort": "future_effort", "isDefault": true],
            ["id": "hidden", "hidden": true],
            ["id": "model-b", "displayName": "Model B", "supportedReasoningEfforts": []]
        ], "nextCursor": "page-2"]
        let decoded = try CodexModelCatalog.decodePage(data(page))
        XCTAssertEqual(decoded.nextCursor, "page-2")
        XCTAssertEqual(decoded.models.map(\.id), ["provider/model-a", "model-b"])
        XCTAssertEqual(decoded.models[0].reasoningEfforts.map(\.id), ["low", "future_effort"])
        XCTAssertEqual(decoded.models[0].defaultReasoningEffort, "future_effort")
        XCTAssertTrue(decoded.models[0].isDefault)
        XCTAssertTrue(decoded.models[1].reasoningEfforts.isEmpty)
    }

    func testMalformedAndUnsafeCatalogCapabilitiesAreRejected() throws {
        let rows: [[String: Any]] = [
            ["model": "", "displayName": "Empty"],
            ["model": "contains\nnewline"],
            ["model": "a", "supportedReasoningEfforts": [["reasoningEffort": "high\"suffix"]]],
            ["model": "a", "supportedReasoningEfforts": [["reasoningEffort": ""]]],
            ["model": "a", "supportedReasoningEfforts": [["reasoningEffort": "high"], ["reasoningEffort": "high"]]],
            ["model": "a", "defaultReasoningEffort": "high\nother"],
            ["model": "a", "displayName": String(repeating: "x", count: 257)]
        ]
        for row in rows { XCTAssertThrowsError(try CodexModelCatalog.decodePage(data(["data": [row]]))) }
        XCTAssertThrowsError(try CodexModelCatalog.decodePage(data(["data": [["id": "same"], ["id": "same"]]])))
        XCTAssertThrowsError(try CodexModelCatalog.decodePage(Data(repeating: 32, count: 1_048_577)))
    }

    func testOnlySafeEffectiveConfigurationFieldsAreUsed() throws {
        let decoded = CodexModelCatalog.decodeConfiguration(try data(["config": [
            "model": "model-a", "model_reasoning_effort": "ultra", "irrelevant": "ignored"]]))
        XCTAssertEqual(decoded.model, "model-a")
        XCTAssertEqual(decoded.effort, "ultra")
        let invalid = CodexModelCatalog.decodeConfiguration(try data(["config": [
            "model": "model\nother", "model_reasoning_effort": "high\"suffix"]]))
        XCTAssertNil(invalid.model)
        XCTAssertNil(invalid.effort)
    }

    @MainActor
    func testShortLivedServerPaginationConfigurationAndExecutableScoping() async throws {
        let first = try data(["id": 2, "result": ["data": [["id": "model-a", "displayName": "Model A",
              "supportedReasoningEfforts": [["reasoningEffort": "high"]]]], "nextCursor": "next"]])
        let second = try data(["id": 3, "result": ["data": [["id": "model-b", "displayName": "Model B",
              "supportedReasoningEfforts": [["reasoningEffort": "low"]]]], "nextCursor": NSNull()]])
        let config = try data(["id": 4, "result": ["config": ["model": "model-b", "model_reasoning_effort": "low"]]])
        let fake = try FakeCatalog(responses: [first, second], configuration: config)
        defer { fake.remove() }
        let catalog = CodexModelCatalog()
        await catalog.refresh(executable: fake.executable.path)
        XCTAssertNil(catalog.error)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertEqual(catalog.models.map(\.id), ["model-a", "model-b"])
        XCTAssertEqual(catalog.configuredModelID, "model-b")
        XCTAssertEqual(catalog.configuredReasoningEffort, "low")
        XCTAssertTrue(catalog.matches(executable: fake.executable.path))
        let requests = try String(contentsOf: fake.requests, encoding: .utf8)
        XCTAssertTrue(requests.contains("model/list"))
        XCTAssertTrue(requests.contains("\"cursor\":\"next\""))
        XCTAssertTrue(requests.contains("config/read"))
        XCTAssertFalse(requests.contains("thread/start"))
        XCTAssertFalse(requests.contains("turn/start"))
        await catalog.refresh(executable: "/nonexistent/other-codex")
        XCTAssertTrue(catalog.models.isEmpty, "A different executable must not inherit the prior catalog")
        XCTAssertNil(catalog.configuredModelID)
        XCTAssertNil(catalog.configuredReasoningEffort)
        XCTAssertNotNil(catalog.error)
        XCTAssertFalse(catalog.isLoading)
    }

    @MainActor
    func testCancellationStopsLookupWithoutWaitingForDescendantEOF() async throws {
        let fake = try FakeCatalog(responses: [], configuration: nil, hang: true)
        defer { fake.remove() }
        let catalog = CodexModelCatalog()
        let task = Task { await catalog.refresh(executable: fake.executable.path) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        task.cancel()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertNil(catalog.error)
    }

    @MainActor
    func testExecutableExitingBeforeInitializeProducesAnErrorWithoutSIGPIPE() async throws {
        let fake = try FakeCatalog(responses: [], configuration: nil, exitEarly: true)
        defer { fake.remove() }
        let catalog = CodexModelCatalog()
        for _ in 0..<3 {
            await catalog.refresh(executable: fake.executable.path, force: true)
            XCTAssertNotNil(catalog.error)
            XCTAssertFalse(catalog.isLoading)
            XCTAssertTrue(catalog.models.isEmpty)
        }
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

private struct FakeCatalog {
    let directory: URL
    let executable: URL
    let requests: URL

    init(responses: [Data], configuration: Data?, hang: Bool = false, exitEarly: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-catalog-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("codex")
        requests = directory.appendingPathComponent("requests.jsonl")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let capture = quote(requests.path)
        let read = "IFS= read -r request || exit 0\nprintf '%s\\n' \"$request\" >> \(capture)\n"
        var script = "#!/bin/sh\n" + read
        if exitEarly {
            script = "#!/bin/sh\nexit 1\n"
        } else if hang {
            script += "/bin/sleep 10 &\nwait\n"
        } else {
            script += "printf '%s\\n' '{\"id\":1,\"result\":{}}'\n" + read // initialized
            for response in responses {
                script += read + "printf '%s\\n' " + quote(String(decoding: response, as: UTF8.self)) + "\n"
            }
            if let configuration {
                script += read + "printf '%s\\n' " + quote(String(decoding: configuration, as: UTF8.self)) + "\n"
            }
            script += "while IFS= read -r request; do :; done\n"
        }
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
