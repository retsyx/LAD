import Foundation
import XCTest
@testable import LAD

final class ExternalAgentProtocolTests: XCTestCase {
    @MainActor
    func testModernDiscoveryAndToolListsHaveRequiredResultMetadata() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let discovery = try object(await rig.server.handleMCP(request("server/discover"), client: rig.client))
        let result = try XCTUnwrap(discovery["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["ttlMs"] as? Int, 0)
        XCTAssertEqual(result["cacheScope"] as? String, "private")
        XCTAssertTrue((result["supportedVersions"] as? [String] ?? []).contains("2026-07-28"))
        XCTAssertNotNil((result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"])

        let listed = try object(await rig.server.handleMCP(request("tools/list"), client: rig.client))
        let tools = try XCTUnwrap(listed["result"] as? [String: Any])
        XCTAssertEqual(tools["ttlMs"] as? Int, 0)
        XCTAssertEqual(tools["cacheScope"] as? String, "private")
        XCTAssertTrue((tools["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "lad_projects" })
        let unavailable = await rig.server.handleMCP(try request("resources/list"), client: rig.client)
        XCTAssertEqual(unavailable.status, 404)
        XCTAssertEqual(try errorCode(unavailable), -32601)
    }

    @MainActor
    func testVersionsAndMirroredHeadersCannotDisagreeOrSilentlyDowngrade() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let missing = try request("tools/list", replacingHeaders: ["mcp-protocol-version": nil])
        let missingResponse = await rig.server.handleMCP(missing, client: rig.client)
        XCTAssertEqual(missingResponse.status, 400)
        XCTAssertEqual(try errorCode(missingResponse), -32020)

        let downgraded = try request("tools/list", replacingHeaders: ["mcp-protocol-version": "2025-11-25"])
        let downgradedResponse = await rig.server.handleMCP(downgraded, client: rig.client)
        XCTAssertEqual(try errorCode(downgradedResponse), -32020)
        let mismatched = try request("tools/list", replacingHeaders: ["mcp-method": "tools/call"])
        let mismatchedResponse = await rig.server.handleMCP(mismatched, client: rig.client)
        XCTAssertEqual(try errorCode(mismatchedResponse), -32020)
        let initialization = try request("initialize", params: ["protocolVersion": "2025-06-18"], version: "2025-11-25")
        let initializationResponse = await rig.server.handleMCP(initialization, client: rig.client)
        XCTAssertEqual(try errorCode(initializationResponse), -32020)

        let unsupported = try request("tools/list", version: "2099-01-01")
        let response = await rig.server.handleMCP(unsupported, client: rig.client)
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try errorCode(response), -32022)
        let data = try XCTUnwrap((try object(response)["error"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(data["requested"] as? String, "2099-01-01")
        XCTAssertEqual(data["supported"] as? [String], ExternalAgentServer.protocolVersions)
    }

    @MainActor
    func testMalformedIDsAndRequestsProduceProtocolErrorsWithoutNullModernIDs() async throws {
        let rig = try Rig()
        defer { rig.close() }
        for id in [1.5, true, NSNull()] as [Any] {
            let response = await rig.server.handleMCP(try request("tools/list", id: id), client: rig.client)
            let value = try object(response)
            XCTAssertEqual((value["error"] as? [String: Any])?["code"] as? Int, -32600)
            XCTAssertNil(value["id"])
        }
        let malformed = LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: [
            "content-type": "application/json", "accept": "application/json, text/event-stream",
            "mcp-protocol-version": "2026-07-28"
        ], body: Data("{".utf8))
        let malformedValue = try object(await rig.server.handleMCP(malformed, client: rig.client))
        XCTAssertNil(malformedValue["id"])
        XCTAssertEqual((malformedValue["error"] as? [String: Any])?["code"] as? Int, -32700)
        let array = LoopbackHTTPRequest(method: malformed.method, target: malformed.target, headers: malformed.headers,
                                       body: Data("[]".utf8))
        let arrayResponse = await rig.server.handleMCP(array, client: rig.client)
        XCTAssertEqual(try errorCode(arrayResponse), -32600)
        let incompatible = try request("tools/list", replacingHeaders: ["accept": "text/plain"])
        let incompatibleResponse = await rig.server.handleMCP(incompatible, client: rig.client)
        XCTAssertEqual(incompatibleResponse.status, 406)
    }

    @MainActor
    func testToolValidationAndEncodedNamesUseThePublicSchema() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let absentArguments = try request("tools/call", params: ["name": "lad_projects"])
        let absentArgumentsResponse = await rig.server.handleMCP(absentArguments, client: rig.client)
        XCTAssertNotNil(try object(absentArgumentsResponse)["result"])
        for params in [
            ["name": "missing_tool", "arguments": [:]],
            ["name": "lad_build", "arguments": ["taskID": UUID().uuidString]],
            ["name": "lad_task_status", "arguments": ["taskID": true]],
            ["name": "lad_projects", "arguments": ["unknown": "value"]]
        ] as [[String: Any]] {
            let response = await rig.server.handleMCP(try request("tools/call", params: params), client: rig.client)
            XCTAssertEqual(try errorCode(response), -32602)
        }
        let encoded = "=?base64?" + Data("lad_projects".utf8).base64EncodedString() + "?="
        let request = try request("tools/call", params: ["name": "lad_projects"], replacingHeaders: ["mcp-name": encoded])
        let response = await rig.server.handleMCP(request, client: rig.client)
        XCTAssertNotNil(try object(response)["result"])
    }

    @MainActor
    func testLegacyCancellationIsScopedToTheAuthenticatedClient() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let second = try rig.server.access.create(name: "Other client", capabilities: [.read]).client
        let started = expectation(description: "Both operations started")
        started.expectedFulfillmentCount = 2
        var cancelledFirst = false, cancelledSecond = false
        let first = Task { @MainActor in
            await rig.server.runMCPRequest(clientID: rig.client.id, id: "same-id", method: "tools/call") {
                started.fulfill()
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelledFirst = true }
                return LoopbackHTTPResponse(status: 200)
            }
        }
        let other = Task { @MainActor in
            await rig.server.runMCPRequest(clientID: second.id, id: "same-id", method: "tools/call") {
                started.fulfill()
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelledSecond = true }
                return LoopbackHTTPResponse(status: 200)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let cancel = try request("notifications/cancelled", params: ["requestId": "same-id"], id: nil, version: "2025-11-25")
        let cancelResponse = await rig.server.handleMCP(cancel, client: rig.client)
        XCTAssertEqual(cancelResponse.status, 202)
        let firstResponse = await first.value
        XCTAssertEqual(firstResponse.status, 204)
        XCTAssertTrue(cancelledFirst)
        XCTAssertFalse(cancelledSecond)
        rig.server.stop()
        let otherResponse = await other.value
        XCTAssertEqual(otherResponse.status, 204)
        XCTAssertTrue(cancelledSecond)
    }

    @MainActor
    func testDuplicateIDsRevokeAndTransportCancellationReleaseTheRequest() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let started = expectation(description: "Operation started")
        var cancelled = false
        let pending = Task { @MainActor in
            await rig.server.runMCPRequest(clientID: rig.client.id, id: 7, method: "tools/call") {
                started.fulfill()
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelled = true }
                return LoopbackHTTPResponse(status: 200)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let duplicate = await rig.server.runMCPRequest(clientID: rig.client.id, id: 7.0, method: "tools/call") {
            XCTFail("A duplicate numeric ID must never execute")
            return LoopbackHTTPResponse(status: 200)
        }
        XCTAssertEqual(try errorCode(duplicate), -32600)
        rig.server.access.revoke(rig.client.id)
        let pendingResponse = await pending.value
        XCTAssertEqual(pendingResponse.status, 204)
        XCTAssertTrue(cancelled)

        let parentStarted = expectation(description: "Transport-owned operation started")
        let parent = Task { @MainActor in
            await rig.server.runMCPRequest(clientID: UUID(), id: "connection", method: "tools/call") {
                parentStarted.fulfill()
                do { try await Task.sleep(for: .seconds(60)) } catch {}
                return LoopbackHTTPResponse(status: 200)
            }
        }
        await fulfillment(of: [parentStarted], timeout: 5)
        parent.cancel()
        let parentResponse = await parent.value
        XCTAssertEqual(parentResponse.status, 204)
    }

    private func request(_ method: String, params: [String: Any] = [:], id: Any? = 1, version: String = "2026-07-28",
                         replacingHeaders: [String: String?] = [:]) throws -> LoopbackHTTPRequest {
        var params = params
        if version == "2026-07-28" {
            params["_meta"] = ["io.modelcontextprotocol/protocolVersion": version,
                               "io.modelcontextprotocol/clientCapabilities": [:]] as [String: Any]
        }
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        var headers = ["content-type": "application/json", "accept": "application/json, text/event-stream",
                       "mcp-protocol-version": version, "mcp-method": method]
        if let name = params[method == "resources/read" ? "uri" : "name"] as? String { headers["mcp-name"] = name }
        for (name, value) in replacingHeaders { headers[name] = value }
        return LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: headers,
                                   body: try JSONSerialization.data(withJSONObject: message))
    }

    private func object(_ response: LoopbackHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func errorCode(_ response: LoopbackHTTPResponse) throws -> Int {
        try XCTUnwrap((try object(response)["error"] as? [String: Any])?["code"] as? Int)
    }

    @MainActor
    private final class Rig {
        let suite = "LAD.ExternalAgentProtocolTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let server: ExternalAgentServer
        let client: ExternalAgentClient
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            server = ExternalAgentServer(defaults: defaults)
            client = try server.access.create(name: "Protocol test", capabilities: [.read, .build]).client
        }
        func close() { server.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}
