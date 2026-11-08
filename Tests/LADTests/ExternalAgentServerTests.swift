import AppKit
import Foundation
import XCTest
@testable import LAD

final class ExternalAgentServerTests: XCTestCase {
    @MainActor
    func testCredentialsPersistOnlyTheirDigestAndRevocationInvalidatesPreviouslyCapturedClients() async throws {
        let fixture = try makeFixture()
        let issued = try fixture.server.access.create(name: "  Local assistant  ", capabilities: [.build])
        XCTAssertEqual(issued.client.name, "Local assistant")
        XCTAssertEqual(issued.client.capabilities, [.read, .build])
        XCTAssertEqual(issued.token.utf8.count, 64)
        let persisted = try XCTUnwrap(fixture.defaults.data(forKey: ExternalAgentAccess.clientsKey))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(issued.token))
        XCTAssertNotEqual(issued.client.credentialHash, issued.token)
        let restored = ExternalAgentAccess(defaults: fixture.defaults)
        XCTAssertEqual(restored.authenticate("Bearer \(issued.token)")?.id, issued.client.id)
        XCTAssertNil(restored.authenticate(issued.token))
        XCTAssertNil(restored.authenticate("Bearer " + String(repeating: "0", count: 64)))
        fixture.server.access.revoke(issued.client.id)
        XCTAssertNil(fixture.server.access.authenticate("Bearer \(issued.token)"))
        do {
            _ = try await fixture.server.call(name: "lad_projects", arguments: [:], client: issued.client)
            XCTFail("A captured client value must not survive credential revocation.")
        } catch { XCTAssertEqual(error.localizedDescription, ProjectAgentError.denied.localizedDescription) }
    }

    @MainActor
    func testDesignAllowlistAndCapabilitiesApplyBeforeAnyWorkOrNativeDialog() async throws {
        let fixture = try makeFixture()
        let first = try fixture.addProject(), second = try fixture.addProject()
        let restricted = try fixture.server.access.create(name: "Reader", capabilities: [], projectIDs: [first.projectDocumentID]).client
        let listed = try metadata(try await fixture.server.call(name: "lad_projects", arguments: [:], client: restricted))
        let projects = try XCTUnwrap(listed["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.compactMap { $0["projectID"] as? String }, [first.projectDocumentID.uuidString])
        for name in ["lad_build", "lad_commit", "lad_export_step", "lad_screenshot", "lad_project_create", "lad_project_open"] {
            do {
                _ = try await fixture.server.call(name: name, arguments: [:], client: restricted)
                XCTFail("\(name) must be denied before parsing task arguments or opening UI.")
            } catch { XCTAssertEqual(error.localizedDescription, ProjectAgentError.denied.localizedDescription, name) }
        }
        do {
            _ = try await fixture.server.call(name: "lad_task_begin", arguments: ["projectID": second.projectDocumentID.uuidString, "request": "Inspect"], client: restricted)
            XCTFail("An unauthorized design must not receive a task or audit.")
        } catch { XCTAssertEqual(error.localizedDescription, ProjectAgentError.denied.localizedDescription) }
        XCTAssertTrue(first.taskAudits.isEmpty)
        XCTAssertTrue(second.taskAudits.isEmpty)
        XCTAssertTrue(first.messages.isEmpty)
        XCTAssertNil(first.projectURL, "Discovery alone must not save an empty design.")
    }

    @MainActor
    func testTasksAndAuditStayWithTheirClientAndDesignAndCancellationIsIsolated() async throws {
        let fixture = try makeFixture()
        let first = try fixture.addProject(), second = try fixture.addProject()
        let one = try fixture.server.access.create(name: "First", capabilities: [.build]).client
        let two = try fixture.server.access.create(name: "Second", capabilities: [.build]).client
        let firstTask = try await begin(fixture.server, state: first, client: one)
        let secondTask = try await begin(fixture.server, state: second, client: two)
        let firstID = try XCTUnwrap(firstTask["taskID"] as? String), secondID = try XCTUnwrap(secondTask["taskID"] as? String)
        _ = try await fixture.server.call(name: "lad_versions", arguments: ["taskID": firstID], client: one)
        _ = try await fixture.server.call(name: "lad_versions", arguments: ["taskID": secondID], client: two)
        do {
            _ = try await fixture.server.call(name: "lad_task_status", arguments: ["taskID": firstID], client: two)
            XCTFail("A client must not discover another client's task.")
        } catch { XCTAssertEqual(error.localizedDescription, ProjectAgentError.unavailable.localizedDescription) }
        XCTAssertEqual(first.taskAudits.first?.externalClient?.clientID, one.id.uuidString)
        XCTAssertEqual(second.taskAudits.first?.externalClient?.clientID, two.id.uuidString)
        XCTAssertEqual(first.taskAudits.first?.events.map(\.title), ["lad_versions"])
        XCTAssertEqual(second.taskAudits.first?.events.map(\.title), ["lad_versions"])
        XCTAssertTrue(first.messages.isEmpty)
        XCTAssertTrue(second.messages.isEmpty)
        _ = try await fixture.server.call(name: "lad_task_cancel", arguments: ["taskID": firstID], client: one)
        XCTAssertEqual(first.taskAudits.first?.status, "canceled")
        let remaining = try metadata(try await fixture.server.call(name: "lad_task_status", arguments: ["taskID": secondID], client: two))
        XCTAssertEqual(remaining["status"] as? String, "running")
        fixture.server.access.revoke(two.id)
        XCTAssertEqual(second.taskAudits.first?.status, "canceled")
    }

    @MainActor
    func testStaleCandidateCannotChangeHistoryAndCurrentColorCommitKeepsSelectedRevision() throws {
        let fixture = try makeFixture()
        let state = try fixture.addProject()
        let client = ProjectExternalAgentIdentity(clientID: "test-client", name: "Test assistant")
        let obsolete = state.agentSnapshot(), staleTask = UUID()
        try state.beginExternalAgentAudit(id: staleTask, client: client, request: "Create a box")
        state.hiddenSolids = [0]
        XCTAssertThrowsError(try state.commitExternalAgent(candidate(), taskID: staleTask, artifactID: "candidate", expectedStateToken: obsolete.stateToken, key: "old", snapshot: obsolete))
        XCTAssertTrue(state.revisions.isEmpty)
        XCTAssertNil(state.mesh)
        XCTAssertNil(state.externalAgentReceipt(clientID: client.clientID, key: "old"))

        let snapshot = state.agentSnapshot(), taskID = UUID()
        try state.beginExternalAgentAudit(id: taskID, client: client, request: "Create a box")
        let revisionID = try state.commitExternalAgent(candidate(), taskID: taskID, artifactID: "candidate", expectedStateToken: snapshot.stateToken, key: "first", snapshot: snapshot)
        XCTAssertEqual(state.revisions.count, 1)
        XCTAssertEqual(state.selectedRevisionID, revisionID)
        XCTAssertTrue(state.messages.isEmpty)
        let source = try XCTUnwrap(state.current)
        let colored = ProjectAgentCandidate(model: source, preview: try XCTUnwrap(state.mesh), colorChanges: [CADPartColorChange(partID: "body", color: PartColor(red: 0.8, green: 0.3, blue: 0.2))])
        let colorSnapshot = state.agentSnapshot(), colorTask = UUID()
        try state.beginExternalAgentAudit(id: colorTask, client: client, request: "Color the body")
        let sameID = try state.commitExternalAgent(colored, taskID: colorTask, artifactID: "current", expectedStateToken: colorSnapshot.stateToken, key: "color", snapshot: colorSnapshot)
        XCTAssertEqual(sameID, revisionID)
        XCTAssertEqual(state.revisions.count, 1)
        XCTAssertEqual(state.selectedRevisionID, revisionID)
        XCTAssertEqual(state.revisions[0].partColors?["body"], colored.colorChanges.first?.color)
    }

    @MainActor
    func testCommitRetryUsesPersistedReceiptAfterTaskEndAndReopenWithoutDuplicateRevision() async throws {
        let fixture = try makeFixture()
        let state = try fixture.addProject()
        let issued = try fixture.server.access.create(name: "Writer", capabilities: [.commit])
        let task = try await begin(fixture.server, state: state, client: issued.client)
        let id = try XCTUnwrap(task["taskID"] as? String), taskID = try XCTUnwrap(UUID(uuidString: id))
        let expected = try XCTUnwrap(task["expectedStateToken"] as? String), snapshot = state.agentSnapshot()
        let revisionID = try state.commitExternalAgent(candidate(), taskID: taskID, artifactID: "candidate-1", expectedStateToken: expected, key: "retry-1", snapshot: snapshot)
        let arguments: [String: Any] = ["taskID": id, "artifactID": "candidate-1", "expectedStateToken": expected, "idempotencyKey": "retry-1"]
        let first = try metadata(try await fixture.server.call(name: "lad_commit", arguments: arguments, client: issued.client))
        XCTAssertEqual(first["revisionID"] as? String, revisionID.uuidString)
        XCTAssertEqual((first["persistence"] as? [String: Any])?["status"] as? String, "saved")
        do {
            _ = try await fixture.server.call(name: "lad_versions", arguments: ["taskID": id], client: issued.client)
            XCTFail("Completed tasks must not start additional CAD operations with a finished audit.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("task is complete")) }
        _ = try await fixture.server.call(name: "lad_task_end", arguments: ["taskID": id], client: issued.client)
        let retry = try metadata(try await fixture.server.call(name: "lad_commit", arguments: arguments, client: issued.client))
        XCTAssertEqual(retry["revisionID"] as? String, revisionID.uuidString)
        XCTAssertEqual(state.revisions.count, 1)
        var wrongArtifact = arguments
        wrongArtifact["artifactID"] = "another-candidate"
        do {
            _ = try await fixture.server.call(name: "lad_commit", arguments: wrongArtifact, client: issued.client)
            XCTFail("An idempotency key cannot authorize another candidate.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("another commit")) }

        let savedURL = try XCTUnwrap(state.projectURL)
        let saved = try ProjectStore.read(from: savedURL)
        let reopened = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: fixture.directory), python: "/usr/bin/true")
        reopened.loadProject(saved, from: savedURL)
        fixture.states.append(reopened)
        let coordinator = ProjectWindowCoordinator()
        coordinator.register(ProjectWindowSession(state: reopened), id: UUID(), sourceURL: savedURL)
        let freshServer = ExternalAgentServer(defaults: fixture.defaults, coordinator: coordinator)
        defer { freshServer.stop() }
        let afterReopen = try metadata(try await freshServer.call(name: "lad_commit", arguments: arguments, client: issued.client))
        XCTAssertEqual(afterReopen["revisionID"] as? String, revisionID.uuidString)
        XCTAssertEqual(reopened.revisions.count, 1)
        XCTAssertEqual(reopened.taskAudits.first?.commitArtifactID, "candidate-1")
    }

    @MainActor
    func testFailedSavingKeepsAcceptedCommitRetryableUntilStorageIsFixed() async throws {
        let fixture = try makeFixture()
        let blockedDirectory = fixture.directory.appendingPathComponent("blocked-save-folder", isDirectory: true)
        try Data("This regular file deliberately blocks directory creation.".utf8).write(to: blockedDirectory)
        let state = try fixture.addProject(rootDirectory: blockedDirectory)
        let issued = try fixture.server.access.create(name: "Retrying writer", capabilities: [.commit])
        let task = try await begin(fixture.server, state: state, client: issued.client)
        let id = try XCTUnwrap(task["taskID"] as? String), taskID = try XCTUnwrap(UUID(uuidString: id))
        let expected = try XCTUnwrap(task["expectedStateToken"] as? String)
        let revisionID = try state.commitExternalAgent(candidate(), taskID: taskID, artifactID: "candidate-1",
            expectedStateToken: expected, key: "save-retry", snapshot: state.agentSnapshot())
        let arguments: [String: Any] = ["taskID": id, "artifactID": "candidate-1", "expectedStateToken": expected, "idempotencyKey": "save-retry"]
        let failed = try metadata(try await fixture.server.call(name: "lad_commit", arguments: arguments, client: issued.client))
        XCTAssertEqual(failed["committed"] as? Bool, true)
        XCTAssertEqual(failed["revisionID"] as? String, revisionID.uuidString)
        let persistence = try XCTUnwrap(failed["persistence"] as? [String: Any])
        XCTAssertEqual(persistence["status"] as? String, "failed")
        XCTAssertNotNil(persistence["error"] as? String)
        XCTAssertEqual(state.revisions.count, 1)
        XCTAssertTrue(state.hasUnsavedChanges)

        try FileManager.default.removeItem(at: blockedDirectory)
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: false)
        let retried = try metadata(try await fixture.server.call(name: "lad_commit", arguments: arguments, client: issued.client))
        XCTAssertEqual(retried["committed"] as? Bool, true)
        XCTAssertEqual(retried["revisionID"] as? String, revisionID.uuidString)
        XCTAssertEqual((retried["persistence"] as? [String: Any])?["status"] as? String, "saved")
        XCTAssertEqual(state.revisions.count, 1)
        XCTAssertFalse(state.hasUnsavedChanges)
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.revisions.map(\.id), [revisionID])
        XCTAssertEqual(saved.taskAudits?.first?.commitKey, "save-retry")
    }

    @MainActor
    func testLiveEndpointRejectsUntrustedRequestsAndUploadsExactTaskScopedBytes() async throws {
        let fixture = try makeFixture()
        let state = try fixture.addProject()
        let owner = try fixture.server.access.create(name: "Owner", capabilities: [.build])
        let other = try fixture.server.access.create(name: "Other", capabilities: [.build])
        try await fixture.start()
        let endpoint = try XCTUnwrap(fixture.server.endpoint), port = try XCTUnwrap(URLComponents(string: endpoint)?.port)
        let headers = ["host": "127.0.0.1:\(port)", "authorization": "Bearer \(owner.token)", "content-type": "application/json",
                       "mcp-protocol-version": "2025-11-25", "accept": "application/json, text/event-stream"]
        let ping = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        var missingAuth = headers; missingAuth.removeValue(forKey: "authorization")
        XCTAssertEqual(fixture.server.admit(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: missingAuth, body: Data()))?.status, 401)
        var foreignHost = headers; foreignHost["host"] = "attacker.example:\(port)"
        XCTAssertEqual(fixture.server.admit(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: foreignHost, body: Data()))?.status, 403)
        var foreignOrigin = headers; foreignOrigin["origin"] = "https://attacker.example"
        XCTAssertEqual(fixture.server.admit(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: foreignOrigin, body: Data()))?.status, 403)
        var oversizedMCP = headers; oversizedMCP["content-length"] = String(4 * 1024 * 1024 + 1)
        XCTAssertEqual(fixture.server.admit(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: oversizedMCP, body: Data()))?.status, 413)
        XCTAssertEqual(fixture.server.admit(LoopbackHTTPRequest(method: "POST", target: "/m%63p", headers: oversizedMCP, body: Data()))?.status, 404,
                       "An encoded endpoint must not bypass the MCP body cap before accumulation.")
        let badID = Data("{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}".utf8)
        let invalidID = await fixture.server.handle(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: headers, body: badID))
        let invalidMethod = await fixture.server.handle(LoopbackHTTPRequest(method: "GET", target: "/mcp", headers: headers, body: Data()))
        let validPing = await fixture.server.handle(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: headers, body: ping))
        XCTAssertEqual(invalidID.status, 400)
        XCTAssertEqual(invalidMethod.status, 405)
        XCTAssertEqual(validPing.status, 200)

        var modernHeaders = headers
        modernHeaders["mcp-protocol-version"] = "2026-07-28"
        modernHeaders["mcp-method"] = "server/discover"
        let discover = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "server/discover", "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": [:]]]])
        let discovered = await fixture.server.handle(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: modernHeaders, body: discover))
        XCTAssertEqual(discovered.status, 200)
        modernHeaders["mcp-method"] = "tools/call"
        let mismatched = await fixture.server.handle(LoopbackHTTPRequest(method: "POST", target: "/mcp", headers: modernHeaders, body: discover))
        XCTAssertEqual(mismatched.status, 400)

        let task = try await begin(fixture.server, state: state, client: owner.client)
        let uploadURL = try XCTUnwrap(task["uploadURL"] as? String), taskID = try XCTUnwrap(task["taskID"] as? String)
        var uploadHead = headers
        uploadHead["content-type"] = "application/octet-stream"
        uploadHead["content-length"] = String(ProjectAgentSession.maximumUploadBytes)
        let uploadTarget = "/tasks/\(taskID)/files?name=reference.bin"
        XCTAssertNil(fixture.server.admit(LoopbackHTTPRequest(method: "POST", target: uploadTarget, headers: uploadHead, body: Data())))
        uploadHead["authorization"] = "Bearer \(other.token)"
        XCTAssertEqual(fixture.server.admit(LoopbackHTTPRequest(method: "POST", target: uploadTarget, headers: uploadHead, body: Data()))?.status, 404,
                       "Another client must be rejected from headers before its claimed upload body arrives.")
        let data = Data([0, 255, 13, 10, 42])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var uploadComponents = try XCTUnwrap(URLComponents(string: uploadURL))
        uploadComponents.queryItems = [URLQueryItem(name: "name", value: "référence.bin")]
        var upload = URLRequest(url: try XCTUnwrap(uploadComponents.url))
        upload.httpMethod = "POST"; upload.httpBody = data; upload.timeoutInterval = 5
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.setValue("Bearer \(owner.token)", forHTTPHeaderField: "Authorization")
        let (uploaded, uploadResponse) = try await session.data(for: upload)
        XCTAssertEqual((uploadResponse as? HTTPURLResponse)?.statusCode, 201)
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: uploaded) as? [String: Any])
        let downloadURL = try XCTUnwrap(descriptor["downloadURL"] as? String)
        var download = URLRequest(url: try XCTUnwrap(URL(string: downloadURL)))
        download.timeoutInterval = 5
        download.setValue("Bearer \(owner.token)", forHTTPHeaderField: "Authorization")
        let (downloaded, downloadResponse) = try await session.data(for: download)
        XCTAssertEqual((downloadResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(downloaded, data)
        let disposition = try XCTUnwrap((downloadResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"))
        XCTAssertTrue(disposition.unicodeScalars.allSatisfy(\.isASCII), "Unicode upload names need a safe HTTP header representation.")
        download.setValue("Bearer \(other.token)", forHTTPHeaderField: "Authorization")
        let (_, denied) = try await session.data(for: download)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
        _ = try await fixture.server.call(name: "lad_task_cancel", arguments: ["taskID": taskID], client: owner.client)
        download.setValue("Bearer \(owner.token)", forHTTPHeaderField: "Authorization")
        let (_, canceled) = try await session.data(for: download)
        XCTAssertEqual((canceled as? HTTPURLResponse)?.statusCode, 404)
    }

    @MainActor
    func testNativeHTTPWorkflowBuildsRendersExportsCommitsAndReplaysSavedDesign() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the full native HTTP CAD workflow.")
        }
        let fixture = try makeFixture()
        let python = try await CADRuntimeManager.resolvePython(EngineService.defaultPython)
        let state = try fixture.addProject(python: python)
        let issued = try fixture.server.access.create(name: "Native HTTP test", capabilities: [.build, .commit, .export])
        try await fixture.start()
        let endpoint = try XCTUnwrap(fixture.server.endpoint)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let listed = try metadata(try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_projects", arguments: [:]))
        XCTAssertEqual((listed["projects"] as? [[String: Any]])?.count, 1)
        let task = try metadata(try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_task_begin",
            arguments: ["projectID": state.projectDocumentID.uuidString, "request": "Create a 2 by 3 by 4 mm box", "model": "test-client-model"]))
        let taskID = try XCTUnwrap(task["taskID"] as? String), expected = try XCTUnwrap(task["expectedStateToken"] as? String)
        let source = Data("result = cq.Solid.makeBox(2, 3, 4)\n".utf8)
        let uploadURL = try XCTUnwrap(task["uploadURL"] as? String)
        var upload = URLRequest(url: try XCTUnwrap(URL(string: uploadURL + "?name=box.py")))
        upload.httpMethod = "POST"; upload.httpBody = source; upload.timeoutInterval = 10
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        let (uploaded, response) = try await client.data(for: upload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        let programID = try XCTUnwrap((JSONSerialization.jsonObject(with: uploaded) as? [String: Any])?["fileID"] as? String)
        let built = try metadata(try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_build",
            arguments: ["taskID": taskID, "programID": programID, "title": "HTTP box", "summary": "A native external-agent box."]))
        let artifactID = try XCTUnwrap(built["artifactID"] as? String)
        XCTAssertTrue(state.revisions.isEmpty, "Speculative builds must leave the live design unchanged.")
        let inspected = try metadata(try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_inspect",
            arguments: ["taskID": taskID, "artifactID": artifactID, "kind": "summary"]))
        XCTAssertEqual(inspected["volume"] as? Double ?? -1, 24, accuracy: 1e-8)
        _ = try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_validate", arguments: ["taskID": taskID, "artifactID": artifactID])
        _ = try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_measure", arguments: ["taskID": taskID, "artifactID": artifactID, "solidIndices": [0]])
        let rendered = try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_render",
            arguments: ["taskID": taskID, "artifactID": artifactID, "view": "isometric", "width": 256, "height": 256])
        let image = try XCTUnwrap((rendered["content"] as? [[String: Any]])?.first { $0["type"] as? String == "image" })
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(image["data"] as? String)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 256)
        XCTAssertEqual(bitmap.pixelsHigh, 256)
        var sampledColors = Set<String>()
        for y in stride(from: 0, to: 256, by: 16) {
            for x in stride(from: 0, to: 256, by: 16) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    sampledColors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(sampledColors.count, 3, "The native render must contain shaded CAD pixels, rather than only an empty background.")
        let renderEvent = try XCTUnwrap(state.taskAudits.first?.events.first { $0.title == "lad_render" && $0.status == "completed" })
        let imageKey = ProjectActivityImageKey(taskID: try XCTUnwrap(UUID(uuidString: taskID)), eventID: renderEvent.id)
        XCTAssertEqual(state.activityImages.images[imageKey]?.data, png, "Tool Activity must retain the exact PNG returned over MCP.")
        let exported = try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_export_step", arguments: ["taskID": taskID, "artifactID": artifactID])
        let stepID = try XCTUnwrap(metadata(exported)["path"] as? String)
        let standardFiles = try XCTUnwrap((exported["structuredContent"] as? [String: Any])?["files"] as? [[String: Any]])
        let file = try XCTUnwrap(standardFiles.first { $0["fileID"] as? String == stepID })
        let textFileBlocks = (exported["content"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
            guard let text = item["text"] as? String, let bytes = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }.flatMap { $0["files"] as? [[String: Any]] ?? [] }
        XCTAssertTrue(textFileBlocks.contains { $0["fileID"] as? String == stepID && $0["downloadURL"] is String },
                      "Clients that forward standard text content must receive usable download references.")
        var download = URLRequest(url: try XCTUnwrap(URL(string: try XCTUnwrap(file["downloadURL"] as? String))))
        download.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        let (step, stepResponse) = try await client.data(for: download)
        XCTAssertEqual((stepResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: step.prefix(100), as: UTF8.self).contains("ISO-10303-21"))
        let commitArguments: [String: Any] = ["taskID": taskID, "artifactID": artifactID, "expectedStateToken": expected, "idempotencyKey": "http-box-commit"]
        let committed = try metadata(try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_commit", arguments: commitArguments))
        XCTAssertEqual(committed["committed"] as? Bool, true)
        XCTAssertEqual((committed["persistence"] as? [String: Any])?["status"] as? String, "saved")
        XCTAssertEqual(state.revisions.count, 1)
        XCTAssertEqual(state.mesh?.volume ?? -1, 24, accuracy: 1e-8)
        XCTAssertTrue(state.messages.isEmpty)
        _ = try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_task_end", arguments: ["taskID": taskID])
        let retried = try metadata(try await httpTool(client, endpoint: endpoint, token: issued.token, name: "lad_commit", arguments: commitArguments))
        XCTAssertEqual(retried["revisionID"] as? String, committed["revisionID"] as? String)
        XCTAssertEqual(state.revisions.count, 1)
        ProjectPackage.clearSessionCache()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        let recipe = try XCTUnwrap(saved.revisions.first?.model)
        XCTAssertEqual(Data(recipe.script.utf8), source)
        XCTAssertNil(saved.revisions.first?.preview)
        XCTAssertTrue(saved.messages.isEmpty)
        let audit = try XCTUnwrap(saved.taskAudits?.first)
        XCTAssertTrue(audit.events.contains { $0.title == "lad_commit" && $0.status == "completed" })
        XCTAssertTrue(audit.events.contains { $0.title == "lad_build" && $0.files?.first?.data == source })
        XCTAssertTrue(audit.events.allSatisfy { $0.imageData == nil })
        XCTAssertEqual(state.activityImages.images[imageKey]?.data, png, "Task cleanup must retain its bounded in-memory preview.")
        let replay = try await EngineService().buildPreview(recipe, python: python, threads: 2)
        XCTAssertEqual(replay.volume, 24, accuracy: 1e-8)
        XCTAssertNotEqual(replay.brepPath, state.mesh?.brepPath, "Reopening must replay the portable program independently of the task's native cache.")
    }

    @MainActor
    private func httpTool(_ client: URLSession, endpoint: String, token: String, name: String, arguments: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint)))
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let (data, response) = try await client.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], String(decoding: data, as: UTF8.self))
        guard result["isError"] as? Bool != true else {
            throw LADError.message("\(name): \(String(decoding: data, as: UTF8.self))")
        }
        return result
    }

    @MainActor
    private func begin(_ server: ExternalAgentServer, state: AppState, client: ExternalAgentClient) async throws -> [String: Any] {
        try metadata(try await server.call(name: "lad_task_begin", arguments: ["projectID": state.projectDocumentID.uuidString, "request": "Inspect this design"], client: client))
    }

    private func metadata(_ result: [String: Any]) throws -> [String: Any] {
        let contents = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(contents.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func candidate() -> ProjectAgentCandidate {
        let model = ModelSpec(title: "External box", summary: "A box created by an external agent.", units: "mm", script: "result = cq.Solid.makeBox(2, 3, 4)\n")
        let preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 2, 3, 4], volume: 24, area: 52,
            solids: 1, faces: 6, buildSeconds: 0, threads: 1, stepPath: "/temporary/box.step", parts: [PartNode(id: "body", name: "Body", solidIndices: [0])])
        return ProjectAgentCandidate(model: model, preview: preview, colorChanges: [])
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        return fixture
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let suite: String
        let defaults: UserDefaults
        let coordinator = ProjectWindowCoordinator()
        let server: ExternalAgentServer
        var states: [AppState] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-external-server-test-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            suite = "LAD.external-server-test.\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            server = ExternalAgentServer(defaults: defaults, coordinator: coordinator)
        }

        func addProject(python: String = "/usr/bin/true", rootDirectory: URL? = nil) throws -> AppState {
            let root = rootDirectory ?? directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root), python: python, thumbnailRenderer: { _, _ in throw CancellationError() })
            state.newProject()
            coordinator.register(ProjectWindowSession(state: state), id: UUID(), sourceURL: nil)
            states.append(state)
            return state
        }

        func start() async throws {
            let probe = LoopbackHTTPServer { _ in LoopbackHTTPResponse(status: 204) }
            let port = try await probe.start()
            probe.stop()
            server.preferredPort = Int(port)
            server.enabled = true
            for _ in 0..<200 {
                if server.isRunning { return }
                if let error = server.error { throw LADError.message(error) }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LADError.message("The test loopback endpoint did not become ready.")
        }

        func close() async {
            server.stop()
            for state in states { await state.prepareToQuit() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            ProjectPackage.clearSessionCache()
        }
    }
}
