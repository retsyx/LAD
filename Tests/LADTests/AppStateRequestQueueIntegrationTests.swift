import Foundation
import XCTest
@testable import LAD

final class AppStateRequestQueueIntegrationTests: XCTestCase {
    @MainActor
    func testCompletingAnActiveTurnWaitsForTheComposerEditAndSendsOnlyItsSavedVersion() async throws {
        let fixture = try Fixture(delay: 0.5, translateAttachedDimensions: true)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        defer { state.cancel() }
        state.prompt = "Create the first design"; state.submit()
        guard try await waitUntil("The original turn did not become steerable.", { state.canSteerQueuedRequests }) else { return }
        state.prompt = "Add the original queued change"; state.submit()
        let queued = try XCTUnwrap(state.queuedRequests.first)
        state.prompt = "Preserve my unsent next request"
        state.beginEditingQueuedRequest(id: queued.id)
        state.prompt = "Add the edited queued change using the attachment"
        state.selectCodexModel("edited-model"); state.selectCodexReasoningEffort("ultra")
        let source = fixture.directory.appendingPathComponent("queued-dimensions.py")
        let sourceText = "# EDITED_QUEUED_SOURCE\nwidth = 23\n"
        try Data(sourceText.utf8).write(to: source)
        let activity = state.activity
        state.attachSourceFiles(urls: [source])
        XCTAssertTrue(state.isWorking, "Reading an edited attachment must not cancel or replace the running Codex turn.")
        XCTAssertEqual(state.activity, activity)
        XCTAssertTrue(state.isReadingQueuedAttachments)
        XCTAssertFalse(state.canCommitQueuedRequest)
        XCTAssertFalse(state.commitEditingQueuedRequest(), "Save must wait for the edited source snapshot.")
        guard try await waitUntil("The edited source did not finish loading.", { !state.isReadingQueuedAttachments }) else { return }
        XCTAssertEqual(state.pendingAttachments.first?.content, sourceText)

        guard try await waitUntil("The original turn did not validate while its queued successor was being edited.", {
            state.revisions.count == 1 && !state.isWorking
        }) else { return }
        XCTAssertEqual(state.taskAudits.count, 1)
        XCTAssertEqual(state.queuedRequests.first?.content, queued.content)
        XCTAssertEqual(state.editingQueuedRequestID, queued.id)
        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content), ["Create the first design"])

        state.submit()
        XCTAssertNil(state.editingQueuedRequestID)
        XCTAssertEqual(state.prompt, "Preserve my unsent next request")
        XCTAssertEqual(state.taskAudits.count, 2, "Save should release exactly the edited next turn.")
        XCTAssertEqual(state.taskAudits.last?.model, "edited-model")
        XCTAssertEqual(state.taskAudits.last?.reasoningEffort, "ultra")
        guard try await waitUntil("The saved queued edit did not settle.", { !state.isWorking }) else { return }
        XCTAssertNil(state.error, "The saved edit failed: \(state.error ?? state.activityStatus)")
        XCTAssertEqual(state.revisions.count, 2,
                       "The saved edit did not validate: \(state.error ?? state.activityStatus); audit: \(state.taskAudits.last?.status ?? "missing")")
        guard state.revisions.count == 2 else { return }
        XCTAssertTrue(state.current?.script.contains("box(23, 4, 5)") == true,
                      "The mock agent should translate the edited source dimensions into a changed CAD program.")
        XCTAssertTrue(state.queuedRequests.isEmpty)
        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content),
                       ["Create the first design", "Add the edited queued change using the attachment"])
        XCTAssertEqual(state.messages.last(where: { $0.role == "user" })?.attachments?.first?.content, sourceText)
        XCTAssertEqual(try fixture.rpcParameters(method: "turn/start").count, 2)
        await state.prepareToQuit()
    }

    @MainActor
    func testThreeRequestsRunSeriallyAgainstEachNewValidatedRevision() async throws {
        let fixture = try Fixture(delay: 0.35)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        defer { state.cancel() }
        state.selectCodexModel("first-model"); state.selectCodexReasoningEffort("high")
        state.prompt = "Create the base"; state.submit()
        guard try await waitUntil("The first turn did not become steerable.", { state.canSteerQueuedRequests }) else { return }
        state.selectCodexModel("second-model"); state.selectCodexReasoningEffort("low")
        state.prompt = "Add the second feature"; state.submit()
        state.selectCodexModel("third-model"); state.selectCodexReasoningEffort("high")
        state.prompt = "Add the third feature"; state.submit()
        state.prompt = "Keep this unsent draft"
        XCTAssertEqual(state.queuedRequests.count, 2)
        guard try await waitUntil("The three queued requests did not validate serially.", {
            state.revisions.count == 3 && !state.isWorking && state.queuedRequests.isEmpty
        }) else { return }

        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content),
                       ["Create the base", "Add the second feature", "Add the third feature"])
        XCTAssertEqual(state.taskAudits.map(\.model), ["first-model", "second-model", "third-model"])
        XCTAssertEqual(state.taskAudits.map(\.reasoningEffort), ["high", "low", "high"])
        XCTAssertEqual(state.taskAudits.map(\.status), ["completed", "completed", "completed"])
        for pair in zip(state.taskAudits, state.taskAudits.dropFirst()) {
            XCTAssertLessThanOrEqual(try XCTUnwrap(pair.0.finishedAt), pair.1.startedAt,
                                     "The next turn must wait for the previous geometry to validate and commit.")
        }
        let turns = try fixture.rpcParameters(method: "turn/start")
        XCTAssertEqual(turns.count, 3)
        let texts = turns.map(fixture.inputText)
        XCTAssertFalse(texts[0].contains("CURRENT MODEL FILE:\n"))
        XCTAssertTrue(texts[1].contains("CURRENT MODEL FILE:\n"))
        XCTAssertTrue(texts[2].contains("CURRENT MODEL FILE:\n"))
        XCTAssertEqual(state.prompt, "Keep this unsent draft")
        XCTAssertEqual(state.model, "third-model")
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.revisions.count, 3)
        XCTAssertEqual(saved.draftPrompt, "Keep this unsent draft")
    }

    @MainActor
    func testSendNowAcknowledgementAfterTurnCompletionDoesNotDuplicateOrLoseTheRequest() async throws {
        let fixture = try Fixture(delay: 2, steeringMode: "finish-before-ack")
        defer { fixture.cleanUp() }
        let state = fixture.state()
        defer { state.cancel() }
        state.prompt = "Create the first design"; state.submit()
        guard try await waitUntil("The first turn did not become steerable.", { state.canSteerQueuedRequests }) else { return }
        let source = fixture.directory.appendingPathComponent("dimensions.py")
        let sourceText = "# STEERING_SOURCE_CONTENT_SENTINEL\nwidth = 23\n"
        try Data(sourceText.utf8).write(to: source)
        let information = "Use the dimensions in \"\(source.path)\" for this task."
        state.prompt = information; state.submit()
        let supplementalID = try XCTUnwrap(state.queuedRequests.first?.id)
        guard try await waitUntil("The supplemental source snapshot was not prepared.", {
            !state.preparingQueuedRequestIDs.contains(supplementalID)
        }) else { return }
        try FileManager.default.removeItem(at: source)
        state.prompt = "Then make the next design change"; state.submit()
        state.sendQueuedRequestNow(id: supplementalID)
        XCTAssertEqual(state.isSendingQueuedRequestID, supplementalID)
        state.removeQueuedRequest(id: supplementalID)
        state.editQueuedRequest(id: supplementalID, text: "This must not replace in-flight input")
        XCTAssertEqual(state.queuedRequests.first?.id, supplementalID)
        XCTAssertEqual(state.queuedRequests.first?.content, information)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.queuedRequests.contains(where: { $0.id == supplementalID }),
                      "A terminal notification before the RPC acknowledgement must not consume an unacknowledged item.")
        guard try await waitUntil("The acknowledged information and next queued turn did not finish.", {
            state.revisions.count == 2 && !state.isWorking && state.queuedRequests.isEmpty
        }) else { return }

        XCTAssertEqual(state.taskAudits.count, 2)
        let additionalID = try XCTUnwrap(state.taskAudits.first?.additionalUserMessageIDs?.first)
        XCTAssertEqual(state.taskAudits.first?.additionalUserMessageIDs?.count, 1)
        let additional = try XCTUnwrap(state.messages.first(where: { $0.id == additionalID }))
        XCTAssertEqual(additional.content, information)
        XCTAssertEqual(additional.attachments?.first?.content, sourceText)
        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content),
                       ["Create the first design", information, "Then make the next design change"])
        XCTAssertEqual(try fixture.rpcParameters(method: "turn/start").count, 2)
        let steering = try fixture.rpcParameters(method: "turn/steer")
        XCTAssertEqual(steering.count, 1)
        let text = fixture.inputText(try XCTUnwrap(steering.first))
        XCTAssertTrue(text.contains("ATTACHED SOURCE FILE REFERENCES"))
        XCTAssertFalse(text.contains("STEERING_SOURCE_CONTENT_SENTINEL"))
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.taskAudits?.first?.additionalUserMessageIDs, [additionalID])
        XCTAssertEqual(saved.messages.first(where: { $0.id == additionalID })?.attachments?.first?.content, sourceText)
    }

    @MainActor
    func testRejectedSendNowRemainsQueuedAndDoesNotReplayAutomaticallyAtCompletion() async throws {
        let fixture = try Fixture(delay: 0.6, steeringMode: "reject")
        defer { fixture.cleanUp() }
        let state = fixture.state()
        defer { state.cancel() }
        state.prompt = "Create the first design"; state.submit()
        guard try await waitUntil("The first turn did not become steerable.", { state.canSteerQueuedRequests }) else { return }
        state.prompt = "Retain this information when steering fails"; state.submit()
        let request = try XCTUnwrap(state.queuedRequests.first)
        state.sendQueuedRequestNow(id: request.id)
        guard try await waitUntil("The rejected steering request did not settle.", {
            state.isSendingQueuedRequestID == nil && state.queuePaused
        }) else { return }
        XCTAssertEqual(state.queuedRequests, [request])
        guard try await waitUntil("The original design did not finish after steering was rejected.", {
            state.revisions.count == 1 && !state.isWorking
        }) else { return }
        XCTAssertEqual(state.queuedRequests, [request])
        XCTAssertTrue(state.queuePaused)
        XCTAssertNotNil(state.queuedRequestErrors[request.id], "The queued delivery diagnostic must survive the original task's success.")
        XCTAssertEqual(state.taskAudits.count, 1)
        XCTAssertNil(state.taskAudits.first?.additionalUserMessageIDs)
        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content), ["Create the first design"])
        XCTAssertEqual(try fixture.rpcParameters(method: "turn/start").count, 1)
        await state.prepareToQuit()
    }

    @MainActor
    private func waitUntil(_ reason: String, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { XCTFail(reason); return false }
        return true
    }

    @MainActor
    private struct Fixture {
        let codex: FakeCodex
        let directory: URL
        let autosaves: URL
        let oldCodex: Any?

        init(delay: Double, steeringMode: String = "ack", translateAttachedDimensions: Bool = false) throws {
            let model = ModelSpec(title: "Queue integration fixture", summary: "Validated the requested design change.", units: "mm",
                                  script: "result = cq.Workplane('XY').box(3, 4, 5)\n")
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model))
            let response = String(decoding: try JSONSerialization.data(withJSONObject: ["status": "ready", "message": "Ready", "model": object, "assetIDs": []]), as: UTF8.self)
            if translateAttachedDimensions {
                // Returning the original program after receiving a source is
                // deliberately rejected by LAD. This scenario reads the
                // staged attachment and produces an actually changed program.
                let encodedResponse = Data(response.utf8).base64EncodedString()
                codex = try FakeCodex(body: #"""
                python3 - "$output" "$(dirname "$0")/request.txt" <<'PY'
                import base64, json, pathlib, re, sys, time
                time.sleep(\#(delay))
                response = json.loads(base64.b64decode('\#(encodedResponse)'))
                request = pathlib.Path(sys.argv[2]).read_text()
                marker = 'ATTACHED SOURCE FILE REFERENCES (JSON):\n'
                if marker in request:
                    references, _ = json.JSONDecoder().raw_decode(request.split(marker, 1)[1].lstrip())
                    source = pathlib.Path(references[0]['readPath']).read_text()
                    width = int(re.search(r'\bwidth\s*=\s*(\d+)', source).group(1))
                    response['model']['script'] = f"result = cq.Workplane('XY').box({width}, 4, 5)\n"
                pathlib.Path(sys.argv[1]).write_text(json.dumps(response))
                PY
                """#)
            } else {
                codex = try FakeCodex(responseJSON: response, delay: delay, steeringMode: steeringMode)
            }
            directory = codex.directory
            autosaves = directory.appendingPathComponent("autosaves", isDirectory: true)
            try FileManager.default.createDirectory(at: autosaves, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(codex.executable.path, forKey: "codexPath")
        }

        func state() -> AppState {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: autosaves))
            state.newProject()
            return state
        }

        func rpcParameters(method: String) throws -> [[String: Any]] {
            let text = try String(contentsOf: codex.rpcRequestsURL, encoding: .utf8)
            return try text.split(separator: "\n").compactMap { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                guard object?["method"] as? String == method else { return nil }
                return object?["params"] as? [String: Any]
            }
        }

        func inputText(_ parameters: [String: Any]) -> String {
            (parameters["input"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        func cleanUp() {
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            codex.remove()
        }
    }
}
