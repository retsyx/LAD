import CryptoKit
import Combine
import Foundation
import XCTest
@testable import LAD

final class AppStateConversationReplyTests: XCTestCase {
    @MainActor
    func testQuestionsAndUnsupportedExplanationsAreRepliesWithoutChangingTheDesign() async throws {
        for status in ["message", "unsupported"] {
            let question = "What lettering style would you like: rounded, handwritten, or angular?"
            let fixture = try Fixture(status: status, message: question)
            defer { fixture.cleanUp() }
            let state = fixture.state()
            let model = ModelSpec.bracket
            let part = PartNode(id: "bracket", name: "My bracket", solidIndices: [0])
            let layout = PartLayout(nodes: [part], renamedNodes: [part.id: part.name])
            let colors = [part.id: PartColor(red: 0.31, green: 0.57, blue: 0.72)]
            let preview = fixture.preview()
            let revision = ProjectRevision(model: model, preview: preview, partLayout: layout,
                hiddenSolids: [0], parts: [part], partColors: colors, name: "Original")
            state.revisions = [revision]
            state.selectedRevisionID = revision.id
            state.mesh = preview
            state.hiddenSolids = [0]
            let documentID = state.projectDocumentID
            state.prompt = "Can you use a different font for the raised lettering?"
            state.submit()
            state.prompt = "Keep this unsent draft"
            try await finish(state)

            XCTAssertNil(state.error, "An agent-authored explanation or question is normal conversation.")
            XCTAssertTrue(state.awaitingResponse)
            XCTAssertFalse(state.submissionWillQueue)
            XCTAssertFalse(state.isWorking)
            XCTAssertNil(state.runningCodexSelection)
            XCTAssertEqual(state.messages.last?.role, "assistant")
            XCTAssertEqual(state.messages.last?.phase, "response")
            XCTAssertEqual(state.messages.last?.content, question)
            XCTAssertFalse(state.messages.contains { $0.role == "system" && $0.content.contains("could not be completed") })
            XCTAssertEqual(state.prompt, "Keep this unsent draft")
            XCTAssertEqual(state.revisions.map(\.id), [revision.id])
            XCTAssertEqual(state.current, model)
            XCTAssertEqual(state.selectedRevisionID, revision.id)
            XCTAssertEqual(state.mesh?.stepPath, preview.stepPath)
            XCTAssertEqual(state.mesh?.vertices, preview.vertices)
            XCTAssertEqual(state.revisions.first?.partLayout, layout)
            XCTAssertEqual(state.revisions.first?.partColors, colors)
            XCTAssertEqual(state.hiddenSolids, [0])
            XCTAssertEqual(state.title, model.title)
            XCTAssertEqual(state.projectDocumentID, documentID)
            let audit = try XCTUnwrap(state.taskAudits.last)
            XCTAssertEqual(audit.status, "completed")
            XCTAssertNotNil(audit.finishedAt)
            XCTAssertFalse(audit.events.contains { $0.category == "validation" },
                "A conversational reply must not enter CAD validation or create a revision.")
            try fixture.codex.assertJobWasCleanedUp()
            await state.prepareToQuit()
        }
    }

    @MainActor
    func testBottomComposerAnswerRunsBeforePausedFollowupsWithItsCapturedChoicesAndContext() async throws {
        let question = "Should the HALO lettering be rounded, handwritten, or angular?"
        let fixture = try Fixture(message: question, delay: 0.2)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.prompt = "What fonts can you use for the raised HALO lettering?"
        state.submit()
        XCTAssertTrue(state.isWorking)
        state.selectCodexModel("queued-model")
        state.selectCodexReasoningEffort("low")
        state.prompt = "Add ventilation slots after the lettering is settled"
        state.submit()
        let queued = try XCTUnwrap(state.queuedRequests.first)
        state.prompt = "An unsent draft while Codex responds"
        try await finish(state)

        XCTAssertTrue(state.awaitingResponse)
        XCTAssertTrue(state.queuePaused)
        XCTAssertEqual(state.queuedRequests, [queued])
        XCTAssertEqual(state.taskAudits.count, 1, "Questions must not automatically dispatch the next queued change.")
        XCTAssertEqual(state.prompt, "An unsent draft while Codex responds")
        XCTAssertFalse(state.submissionWillQueue,
            "The existing bottom composer must send an answer instead of appending it behind paused follow-ups.")

        let answer = "Use rounded lettering with a 0.8 mm raised height."
        let source = fixture.attachment()
        state.selectCodexModel("reply-model")
        state.selectCodexReasoningEffort("high")
        state.pendingAttachments = [source]
        state.prompt = answer
        state.submit()
        XCTAssertTrue(state.isWorking)
        XCTAssertEqual(state.queuedRequests, [queued])
        XCTAssertEqual(state.messages.last(where: { $0.role == "user" })?.content, answer)
        XCTAssertEqual(state.messages.last(where: { $0.role == "user" })?.attachments, [source])
        XCTAssertTrue(state.prompt.isEmpty)
        XCTAssertTrue(state.pendingAttachments.isEmpty)
        try await finish(state)

        XCTAssertNil(state.error)
        XCTAssertEqual(state.taskAudits.count, 2)
        XCTAssertEqual(state.taskAudits.last?.model, "reply-model")
        XCTAssertEqual(state.taskAudits.last?.reasoningEffort, "high")
        XCTAssertEqual(state.taskAudits.map(\.status), ["completed", "completed"])
        XCTAssertEqual(state.queuedRequests, [queued], "Answering must preserve every pending request and its captured choices.")
        XCTAssertTrue(state.queuePaused)
        XCTAssertTrue(state.revisions.isEmpty)
        let input = try String(contentsOf: fixture.codex.inputURL, encoding: .utf8)
        XCTAssertTrue(input.contains(question), "The answer's new turn must include the saved assistant question.")
        XCTAssertTrue(input.contains(answer))
        XCTAssertTrue(input.contains("ATTACHED SOURCE FILE REFERENCES"))
        XCTAssertFalse(input.contains(source.content), "Source snapshots must remain local file references on replies too.")
        XCTAssertEqual(try fixture.codex.turnRequest()["model"] as? String, "reply-model")
        XCTAssertEqual(try fixture.codex.turnRequest()["effort"] as? String, "high")
        await state.prepareToQuit()
    }

    @MainActor
    func testValidatedAnswerCommitsBeforePausedQueueResumesAndKeepsTheUnsentDraft() async throws {
        let question = "Should the base be a rectangular box or a cylinder?"
        let fixture = try Fixture(message: question, delay: 0.15)
        defer { fixture.cleanUp() }
        let model = ModelSpec(title: "Conversation validation fixture", summary: "Created the rectangular base.",
            units: "mm", script: "result = cq.Workplane('XY').box(8, 6, 2)\n")
        let response = try JSONSerialization.data(withJSONObject: ["status": "ready", "message": "",
            "model": try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)), "assetIDs": []])
        let ready = try FakeCodex(responseJSON: String(decoding: response, as: UTF8.self), delay: 0.05)
        defer { ready.remove() }
        let state = fixture.state()
        defer { state.cancel() }
        let request = "Create a base and ask which shape I want."
        let queuedText = "Then rebuild the base with the same dimensions."
        let answer = "Use a rectangular box measuring 8 by 6 by 2 mm."
        state.prompt = request
        state.submit()
        state.selectCodexModel("queued-validation-model")
        state.selectCodexReasoningEffort("low")
        state.prompt = queuedText
        state.submit()
        let queued = try XCTUnwrap(state.queuedRequests.first)
        try await finish(state)
        XCTAssertTrue(state.awaitingResponse)
        XCTAssertTrue(state.queuePaused)
        XCTAssertTrue(state.revisions.isEmpty, "A question must never create a placeholder CAD revision.")
        XCTAssertEqual(state.taskAudits.count, 1)

        // The first fixture asks the question; both following calls return a
        // complete recipe that LAD's real worker must validate before commit.
        UserDefaults.standard.set(ready.executable.path, forKey: "codexPath")
        var committedRevisionsAtQueuedDispatch: Int?
        let observation = ObservationRecorder({ state.messages }) { messages in
            if messages.last?.role == "user", messages.last?.content == queuedText {
                committedRevisionsAtQueuedDispatch = state.revisions.count
            }
        }
        defer { observation.cancel() }
        state.selectCodexModel("answer-validation-model")
        state.selectCodexReasoningEffort("high")
        state.prompt = answer
        state.submit()
        XCTAssertEqual(state.queuedRequests, [queued])
        let draft = "Keep this next request unsent while the answer validates."
        let draftAttachment = fixture.attachment()
        state.prompt = draft
        state.pendingAttachments = [draftAttachment]
        let deadline = ContinuousClock.now + .seconds(60)
        while state.error == nil, state.isWorking || state.revisions.count < 2,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertNil(state.error, "The actual CAD validation failed: \(state.error ?? state.activityStatus)")
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.revisions.count, 2)
        guard state.revisions.count == 2 else { return }
        XCTAssertEqual(committedRevisionsAtQueuedDispatch, 1,
            "A pending follow-up must not start until the user's answer has validated and committed.")
        let users = state.messages.filter { $0.role == "user" }
        XCTAssertEqual(users.map(\.content), [request, answer, queuedText])
        guard users.count == 3 else { return }
        XCTAssertEqual(state.revisions.map(\.userMessageID), [users[1].id, users[2].id])
        XCTAssertEqual(state.messages.filter { $0.phase == "response" }.map(\.content), [question])
        XCTAssertEqual(state.messages.filter { $0.phase == "final_answer" }.count, 2)
        XCTAssertEqual(state.taskAudits.map(\.status), ["completed", "completed", "completed"])
        XCTAssertEqual(state.taskAudits.map(\.model),
            ["conversation-fixture-model", "answer-validation-model", "queued-validation-model"])
        for audit in state.taskAudits.dropFirst() {
            XCTAssertTrue(audit.events.contains { $0.category == "validation" && $0.status == "completed" })
        }
        for pair in zip(state.taskAudits, state.taskAudits.dropFirst()) {
            XCTAssertLessThanOrEqual(try XCTUnwrap(pair.0.finishedAt), pair.1.startedAt)
        }
        XCTAssertEqual(state.mesh?.volume ?? 0, 96, accuracy: 1e-6)
        XCTAssertFalse(state.awaitingResponse)
        XCTAssertTrue(state.queuedRequests.isEmpty)
        XCTAssertEqual(state.prompt, draft)
        XCTAssertEqual(state.pendingAttachments, [draftAttachment])

        let turns = try ready.rpcRequests().filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(turns.count, 2)
        guard turns.count == 2 else { return }
        let inputs = try turns.map { turn -> String in
            let parameters = try XCTUnwrap(turn["params"] as? [String: Any])
            let inputs = try XCTUnwrap(parameters["input"] as? [[String: Any]])
            return inputs.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        XCTAssertFalse(inputs[0].contains("CURRENT MODEL FILE:\n"))
        XCTAssertTrue(inputs[1].contains("CURRENT MODEL FILE:\n"),
            "The queued request must receive the newly committed recipe as its current design.")
        XCTAssertTrue(inputs[1].contains(answer))
        XCTAssertFalse(inputs[1].contains(model.script.trimmingCharacters(in: .whitespacesAndNewlines)),
            "The queued turn must receive the new program by reference rather than embedding it in the prompt.")
        let pathSection = try XCTUnwrap(inputs[1].components(separatedBy: "CURRENT MODEL FILE:\n").last?
            .components(separatedBy: "\n\n").first)
        let modelPath = try JSONDecoder().decode(String.self, from: Data(pathSection.utf8))
        let stagedModel = try JSONDecoder().decode(ModelSpec.self, from: ready.capturedData(at: modelPath))
        XCTAssertEqual(stagedModel.script, state.revisions[0].model.script)
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL, state.saveStatus ?? "The completed conversation should save."))
        XCTAssertEqual(saved.revisions.map(\.userMessageID), [users[1].id, users[2].id])
        XCTAssertEqual(saved.taskAudits?.map(\.status), ["completed", "completed", "completed"])
        XCTAssertEqual(saved.draftPrompt, draft)
        XCTAssertEqual(saved.draftAttachments, [draftAttachment])
    }

    @MainActor
    func testQuestionAndDraftReopenAsReplyContextWithoutResumingThePendingQueue() async throws {
        let question = "Which font style should I use for HALO?"
        let fixture = try Fixture(message: question, delay: 0.15)
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.prompt = "Can you change the lettering font?"
        state.submit()
        state.prompt = "Round the lid corners afterward"
        state.submit()
        let queued = try XCTUnwrap(state.queuedRequests.first)
        try await finish(state)
        let draft = "Use the handwritten style"
        let attachment = fixture.attachment()
        state.prompt = draft
        state.pendingAttachments = [attachment]
        await state.prepareToQuit()
        let file = try XCTUnwrap(state.projectURL, state.saveStatus ?? "The conversation and draft should autosave.")
        let saved = try ProjectStore.read(from: file)
        XCTAssertEqual(saved.messages.last?.phase, "response")
        XCTAssertEqual(saved.messages.last?.content, question)
        XCTAssertEqual(saved.draftPrompt, draft)
        XCTAssertEqual(saved.draftAttachments, [attachment])
        XCTAssertEqual(saved.queuedRequests, [queued])

        let reopened = fixture.state()
        reopened.loadProject(saved, from: file)
        XCTAssertTrue(reopened.awaitingResponse)
        XCTAssertFalse(reopened.submissionWillQueue)
        XCTAssertTrue(reopened.queuePaused)
        XCTAssertEqual(reopened.prompt, draft)
        XCTAssertEqual(reopened.pendingAttachments, [attachment])
        XCTAssertEqual(reopened.queuedRequests, [queued])
        XCTAssertEqual(reopened.taskAudits.count, 1, "Reopening must never send a queued turn or request an answer automatically.")
        reopened.submit()
        try await finish(reopened)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.messages.filter { $0.role == "user" }.map(\.content),
                       ["Can you change the lettering font?", draft])
        XCTAssertEqual(reopened.queuedRequests, [queued])
        XCTAssertEqual(reopened.taskAudits.count, 2)
        XCTAssertTrue(try String(contentsOf: fixture.codex.inputURL, encoding: .utf8).contains(question))
        await reopened.prepareToQuit()
    }

    @MainActor
    func testTransportFailuresStillProduceAnErrorAndFailedAudit() async throws {
        let fixture = try Fixture(body: "printf '%s\\n' 'Transport unavailable' >&2\nexit 7")
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.prompt = "Create raised lettering"
        state.submit()
        try await finish(state)

        XCTAssertTrue(state.error?.contains("Transport unavailable") == true)
        XCTAssertFalse(state.awaitingResponse)
        XCTAssertFalse(state.messages.contains { $0.phase == "response" })
        XCTAssertEqual(state.taskAudits.last?.status, "failed")
        XCTAssertTrue(state.revisions.isEmpty)
        XCTAssertFalse(state.isWorking)
        await state.prepareToQuit()
    }

    func testAssistantReplyRoundTripsButCannotStandInForAValidatedRevisionResponse() throws {
        let user = ChatMessage(role: "user", content: "Can you use another lettering font?")
        let reply = ChatMessage(role: "assistant", content: "Which font style would you like?", phase: "response")
        let project = LADProject(messages: [user, reply], revisions: [], selectedRevisionID: nil)
        let restored = try ProjectStore.decode(ProjectStore.encode(project))
        XCTAssertEqual(restored.messages, [user, reply])

        let revision = ProjectRevision(model: .bracket, userMessageID: user.id, responseMessageID: reply.id)
        let invalid = LADProject(messages: [user, reply], revisions: [revision], selectedRevisionID: revision.id)
        XCTAssertThrowsError(try ProjectStore.encode(invalid),
            "A question must not be linked to a validated CAD revision as if it completed the design.")
    }

    func testSaveNewDoesNotMistakeAReplyMatchingTheSummaryForAValidatedCloseout() throws {
        let model = ModelSpec.bracket
        let user = ChatMessage(role: "user", content: "Can you explain this design?",
            date: Date(timeIntervalSinceReferenceDate: 1))
        let reply = ChatMessage(role: "assistant", content: model.summary,
            date: Date(timeIntervalSinceReferenceDate: 3), phase: "response")
        for explicitLinks in [false, true] {
            let revision = ProjectRevision(model: model, date: Date(timeIntervalSinceReferenceDate: 2),
                userMessageID: explicitLinks ? user.id : nil, responseMessageID: explicitLinks ? reply.id : nil)
            let project = LADProject(messages: [user, reply], revisions: [revision], selectedRevisionID: revision.id)
            let copy = try SaveNewProject.snapshot(from: project)
            XCTAssertTrue(copy.messages.isEmpty,
                "Neither a matching summary nor explicit stale links make a normal reply a validated closeout.")
            XCTAssertNil(copy.revisions.first?.userMessageID)
            XCTAssertNil(copy.revisions.first?.responseMessageID)
            XCTAssertEqual(copy.revisions.first?.model, model)
            XCTAssertNoThrow(try ProjectStore.encode(copy))
        }
    }

    @MainActor
    private func finish(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isWorking, "The fake conversational task must finish.")
        if state.isWorking { state.cancel() }
        await Task.yield()
    }

    @MainActor
    private struct Fixture {
        let codex: FakeCodex
        let autosaves: URL
        let oldCodex: Any?

        init(status: String = "message", message: String, delay: Double = 0.05) throws {
            let data = try JSONSerialization.data(withJSONObject: ["status": status, "message": message,
                "model": NSNull(), "assetIDs": []], options: [.sortedKeys])
            try self.init(codex: FakeCodex(responseJSON: String(decoding: data, as: UTF8.self), delay: delay))
        }

        init(body: String) throws { try self.init(codex: FakeCodex(body: body)) }

        private init(codex: FakeCodex) throws {
            self.codex = codex
            autosaves = codex.directory.appendingPathComponent("autosaves", isDirectory: true)
            try FileManager.default.createDirectory(at: autosaves, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(codex.executable.path, forKey: "codexPath")
        }

        func state() -> AppState {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: autosaves))
            state.newProject()
            state.selectCodexModel("conversation-fixture-model")
            state.selectCodexReasoningEffort("high")
            return state
        }

        func attachment() -> SourceAttachment {
            let content = "# REPLY_SOURCE_SENTINEL\nletter_height = 0.8\n"
            let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            return SourceAttachment(name: "lettering.py", path: codex.directory.appendingPathComponent("lettering.py").path,
                content: content, sha256: digest)
        }

        func preview() -> PreviewMesh {
            PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2]], edges: [],
                bounds: [0, 0, 0, 1, 1, 1], volume: 1, area: 0.5, solids: 1, faces: 1,
                buildSeconds: 0, threads: 1, stepPath: codex.directory.appendingPathComponent("session-preview.json").path,
                triangleSolids: [0], edgeSolids: [])
        }

        func cleanUp() {
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            codex.remove()
        }
    }
}
