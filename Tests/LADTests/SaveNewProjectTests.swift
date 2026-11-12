import CryptoKit
import XCTest
@testable import LAD

final class SaveNewProjectTests: XCTestCase {
    private let step = Data("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;\n".utf8)

    func testLatestModelStartsWithNoConversationEvenWhenAnotherRevisionIsSelected() throws {
        let first = ProjectRevision(model: .bracket, date: date(10))
        var model = ModelSpec.bracket
        model.summary = "Added connector openings."
        let latest = ProjectRevision(model: model, date: date(20))
        let user = message("user", "Add connector openings", at: 11)
        let response = message("assistant", model.summary + "\n\nModel ready.", at: 20.001)
        let original = LADProject(messages: [
            message("user", "Create a bracket", at: 1),
            message("assistant", first.model.summary, at: 10.001),
            user,
            message("assistant", "I’ll add the openings.", at: 12, phase: "commentary"),
            message("system", "CAD validation failed; repairing.", at: 18),
            response,
            message("user", "Change the screws", at: 21),
            message("assistant", "I’ll check the screws.", at: 22, phase: "commentary"),
            message("system", "Design could not be completed.", at: 23)
        ], revisions: [first, latest], selectedRevisionID: first.id, projectID: UUID())

        let result = try SaveNewProject.snapshot(from: original)
        XCTAssertEqual(result.revisions.map(\.id), [latest.id])
        XCTAssertEqual(result.selectedRevisionID, latest.id)
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertNil(result.revisions[0].userMessageID)
        XCTAssertNil(result.revisions[0].responseMessageID)
        XCTAssertNotEqual(result.projectID, original.projectID)
        XCTAssertEqual(original.messages.count, 9)
        XCTAssertEqual(original.revisions.count, 2)
        XCTAssertEqual(original.selectedRevisionID, first.id)
    }

    func testSpecifiedHistoricalRevisionKeepsRequiredGeometryAndMetadataWithCleanConversation() throws {
        let historicalSource = source("historical source", name: "first.py")
        let laterSource = source("later source", name: "later.py")
        let user = message("user", "Create the first design", at: 1, attachments: [historicalSource])
        let response = message("assistant", "First design ready.", at: 10, phase: "final_answer")
        let laterUser = message("user", "Make a later design", at: 11, attachments: [laterSource])
        let laterResponse = message("assistant", "Later design ready.", at: 20, phase: "final_answer")
        let input = CADInputAsset(id: "reference", name: "reference.step", format: "step", data: step)
        var model = ModelSpec.bracket
        model.script = "result = imported_assets['reference']"
        model.inputAssets = [input]
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0])
        ])]
        let layout = PartLayout(nodes: parts, collapsedNodeIDs: ["case"])
        let runtime = CADRuntime(python: "3.11.18", cadquery: "2.8.0", ocp: "7.9.3")
        let historical = ProjectRevision(model: model, date: date(10),
                                         partLayout: layout, hiddenSolids: [0], parts: parts, runtime: runtime,
                                         userMessageID: user.id, responseMessageID: response.id,
                                         partColors: ["base": PartColor(red: 0.2, green: 0.4, blue: 0.6)],
                                         name: "First enclosure", validatedHash: String(repeating: "a", count: 64))
        let latest = ProjectRevision(model: .bracket, date: date(20), userMessageID: laterUser.id,
                                     responseMessageID: laterResponse.id)
        let audit = ProjectTaskAudit(userMessageID: user.id, model: "first-model", reasoningEffort: "high",
                                     status: "completed", events: [])
        let laterAudit = ProjectTaskAudit(userMessageID: laterUser.id, model: "later-model", reasoningEffort: "low",
                                          status: "completed", events: [])
        let original = LADProject(messages: [user, response, laterUser, laterResponse],
                                  revisions: [historical, latest], selectedRevisionID: latest.id,
                                  projectID: UUID(), projectName: "Existing design", showGrid: false,
                                  projectionMode: .isometric, displayMode: .translucent, taskAudits: [audit, laterAudit],
                                  queuedRequests: [ProjectQueuedRequest(content: "Another change", attachments: [laterSource])],
                                  draftPrompt: "Unsent draft", draftAttachments: [laterSource], queuePaused: true)

        let snapshot = try SaveNewProject.snapshot(from: original, revisionID: historical.id)
        let restored = try ProjectStore.decode(ProjectStore.encode(snapshot))
        XCTAssertEqual(restored.revisions.count, 1)
        let saved = try XCTUnwrap(restored.revisions.first)
        XCTAssertEqual(saved.id, historical.id)
        XCTAssertEqual(saved.model, historical.model)
        XCTAssertEqual(saved.name, historical.name)
        XCTAssertEqual(saved.partLayout, layout)
        XCTAssertEqual(saved.parts, parts)
        XCTAssertEqual(saved.hiddenSolids, [0])
        XCTAssertEqual(saved.partColors, historical.partColors)
        XCTAssertEqual(saved.runtime, runtime)
        XCTAssertEqual(saved.validatedHash, historical.validatedHash)
        XCTAssertNil(saved.preview)
        XCTAssertEqual(restored.selectedRevisionID, historical.id)
        XCTAssertTrue(restored.messages.isEmpty)
        XCTAssertNil(saved.userMessageID)
        XCTAssertNil(saved.responseMessageID)
        XCTAssertNil(restored.taskAudits)
        XCTAssertNil(restored.queuedRequests)
        XCTAssertNil(restored.draftPrompt)
        XCTAssertNil(restored.draftAttachments)
        XCTAssertNil(restored.queuePaused)
        XCTAssertEqual(restored.showGrid, false)
        XCTAssertEqual(restored.projectionMode, .isometric)
        XCTAssertEqual(restored.displayMode, .translucent)
        XCTAssertNotEqual(restored.projectID, original.projectID)
        XCTAssertEqual(original.selectedRevisionID, latest.id)
        XCTAssertEqual(original.revisions.count, 2)
        XCTAssertEqual(original.messages.count, 4)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(ProjectStore.encode(snapshot))) as? [String: Any])
        let assets = try XCTUnwrap(manifest["assets"] as? [String: String])
        XCTAssertNil(assets[historicalSource.sha256])
        XCTAssertNil(assets[laterSource.sha256])
        XCTAssertNil(assets[digest(Data(latest.model.script.utf8))])
        XCTAssertNotNil(assets[digest(step)])
    }

    func testMissingRequestedRevisionCannotFallBackToLatest() {
        let latest = ProjectRevision(model: .bracket)
        let original = LADProject(messages: [], revisions: [latest], selectedRevisionID: latest.id)
        XCTAssertThrowsError(try SaveNewProject.snapshot(from: original, revisionID: UUID())) {
            XCTAssertEqual($0.localizedDescription, "That design version is no longer available.")
        }
    }

    func testOnlyRequiredGeometrySurvivesZIPRoundtripWithoutConversationAssets() throws {
        let oldSource = source("obsolete board", name: "old.kicad_pcb")
        let currentSource = source("current board", name: "board.kicad_pcb")
        let user = message("user", "Build an enclosure around this board", at: 10, attachments: [currentSource])
        let response = message("assistant", "The enclosure is ready.", at: 21, phase: "final_answer")
        var oldModel = ModelSpec.bracket


        oldModel.script = "result = cq.Workplane('XY').box(5, 5, 5)"
        var model = ModelSpec.bracket


        model.script = "result = imported_model.translate((0, 0, 5))"
        model.sourceSTEP = step
        model.sourceName = "board.step"
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0])
        ])]
        let layout = PartLayout(nodes: parts, collapsedNodeIDs: ["case"])
        let runtime = CADRuntime(python: "3.11.0", cadquery: "2.6.0", ocp: "7.8.1")
        var latest = ProjectRevision(model: model, date: date(20),
                                    partLayout: layout, hiddenSolids: [0], parts: parts, runtime: runtime)
        latest.userMessageID = user.id
        latest.responseMessageID = response.id
        let settings = CodexProjectSettings(model: "custom-model", reasoningEffort: "high", reasoningByModel: ["custom-model": "high"])
        let original = LADProject(messages: [
            message("user", "Old request", at: 1, attachments: [oldSource]),
            message("assistant", "Old answer", at: 2), user,
            message("assistant", "Checking the board.", at: 11, phase: "commentary"), response
        ], revisions: [ProjectRevision(model: oldModel, date: date(2)), latest], selectedRevisionID: latest.id,
           projectID: UUID(), codexSettings: settings, projectName: "Workshop enclosure", showGrid: false,
           projectionMode: .isometric, displayMode: .translucent)

        let snapshot = try SaveNewProject.snapshot(from: original)
        let bytes = try ProjectStore.encode(snapshot)
        XCTAssertEqual(bytes.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        let restored = try ProjectStore.decode(bytes)
        XCTAssertTrue(restored.messages.isEmpty)
        XCTAssertEqual(restored.revisions.count, 1)
        let saved = try XCTUnwrap(restored.revisions.first)
        XCTAssertEqual(saved.model, model)
        XCTAssertNil(saved.userMessageID)
        XCTAssertNil(saved.responseMessageID)
        XCTAssertEqual(saved.parts, parts)
        XCTAssertEqual(saved.partLayout, layout)
        XCTAssertEqual(saved.hiddenSolids, [0])
        XCTAssertEqual(saved.runtime, runtime)
        XCTAssertNil(saved.preview)
        XCTAssertEqual(restored.codexSettings, settings)
        XCTAssertEqual(restored.projectName, "Workshop enclosure")
        XCTAssertEqual(restored.showGrid, false)
        XCTAssertEqual(restored.projectionMode, .isometric)
        XCTAssertEqual(restored.displayMode, .translucent)
        XCTAssertNotEqual(restored.projectID, original.projectID)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(bytes)) as? [String: Any])
        let assets = try XCTUnwrap(manifest["assets"] as? [String: String])
        XCTAssertEqual(Set(assets.keys), Set([digest(step), digest(Data(model.script.utf8))]))
        XCTAssertNil(assets[oldSource.sha256])
        XCTAssertNil(assets[currentSource.sha256])
        XCTAssertNil(assets[digest(Data(oldModel.script.utf8))])
        XCTAssertEqual(original.messages.count, 5)
    }

    func testEmptyProjectCannotBeSaved() {
        let original = LADProject(messages: [], revisions: [], selectedRevisionID: nil)
        XCTAssertThrowsError(try SaveNewProject.snapshot(from: original)) {
            XCTAssertEqual($0.localizedDescription, "There is no design to save.")
        }
    }

    func testSemanticMetadataSurvivesRemovingLegacyPreviewCache() throws {
        let parts = [PartNode(id: "base", name: "Base", solidIndices: [0])]
        let runtime = CADRuntime(python: "3.11.0", cadquery: "2.6.0", ocp: "7.8.1")
        let preview = PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2]],
                                  edges: [], bounds: [0, 0, 0, 1, 1, 1], volume: 1, area: 1,
                                  solids: 1, faces: 1, buildSeconds: 0.1, threads: 1,
                                  stepPath: "/tmp/generated-model.step", parts: parts, runtime: runtime)
        let revision = ProjectRevision(model: .bracket, preview: preview, hiddenSolids: [0])
        let original = LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id)
        let snapshot = try SaveNewProject.snapshot(from: original)
        XCTAssertNil(snapshot.revisions[0].preview)
        XCTAssertEqual(snapshot.revisions[0].parts, parts)
        XCTAssertEqual(snapshot.revisions[0].partLayout?.nodes, parts)
        XCTAssertEqual(snapshot.revisions[0].runtime, runtime)
        let restored = try ProjectStore.decode(ProjectStore.encode(snapshot))
        XCTAssertEqual(restored.revisions[0].hiddenSolids, [0])
        XCTAssertEqual(restored.revisions[0].parts, parts)
        XCTAssertNotNil(original.revisions[0].preview)
    }

    private func date(_ value: Double) -> Date { Date(timeIntervalSinceReferenceDate: value) }

    private func message(_ role: String, _ content: String, at time: Double, phase: String? = nil,
                         attachments: [SourceAttachment]? = nil) -> ChatMessage {
        ChatMessage(role: role, content: content, date: date(time), attachments: attachments, phase: phase)
    }

    private func source(_ content: String, name: String) -> SourceAttachment {
        SourceAttachment(name: name, path: "/original/" + name, content: content, sha256: digest(Data(content.utf8)))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hexDigest(data)
    }
}
