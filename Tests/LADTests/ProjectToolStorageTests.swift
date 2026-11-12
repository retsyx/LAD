import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class ProjectToolStorageTests: XCTestCase {
    private let step = Data("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;\n".utf8)

    func testImportedInputsAndAuditPayloadsShareTheExistingContentAddressedTable() throws {
        let text = String(decoding: step, as: UTF8.self)
        let imported = CADInputAsset(id: "foreign-geometry", name: "external.step", format: "step", data: step)
        let source = SourceAttachment(name: "external.py", path: "/original/external.py", content: text, sha256: digest(step))
        let user = ChatMessage(role: "user", content: "Use the external geometry", attachments: [source])
        let model = ModelSpec(title: "Imported geometry", summary: "Exact imported geometry.", units: "mm", script: text,
                              sourceSTEP: step, sourceName: "external.step", inputAssets: [imported])
        let event = ProjectActivityEvent(id: "tool-1", category: "tool", title: "Import geometry", status: "completed",
                                         input: text, output: text, durationSeconds: 0.4)
        let audit = ProjectTaskAudit(userMessageID: user.id, model: "test-model", reasoningEffort: "high",
                                     status: "completed", events: [event])
        let revisions = [ProjectRevision(model: model), ProjectRevision(model: model)]
        let project = LADProject(messages: [user], revisions: revisions, selectedRevisionID: revisions.last?.id, taskAudits: [audit])
        let encoded = try ProjectStore.encode(project)
        let manifest = try manifest(encoded)
        let assets = try XCTUnwrap(manifest["assets"] as? [String: String])
        XCTAssertEqual(assets, [digest(step): step.base64EncodedString()], "Logical file roles and repeated history must share exact bytes.")

        let storedRevisions = try XCTUnwrap(manifest["revisions"] as? [[String: Any]])
        for revision in storedRevisions {
            let inputs = try XCTUnwrap(revision["inputAssets"] as? [[String: Any]])
            XCTAssertEqual(inputs.first?["dataAsset"] as? String, digest(step))
            XCTAssertNil(inputs.first?["data"])
            XCTAssertNil(revision["preview"])
            XCTAssertNil(revision["stepData"])
            XCTAssertNil(revision["brepPath"])
        }
        let tasks = try XCTUnwrap(manifest["taskAudits"] as? [[String: Any]])
        let events = try XCTUnwrap(tasks.first?["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["inputAsset"] as? String, digest(step))
        XCTAssertEqual(events.first?["outputAsset"] as? String, digest(step))
        XCTAssertNil(events.first?["input"])
        XCTAssertNil(events.first?["output"])

        let restored = try ProjectStore.decode(encoded)
        XCTAssertEqual(restored.taskAudits, [audit])
        XCTAssertEqual(restored.revisions.map(\.model), revisions.map(\.model))
        XCTAssertTrue(restored.revisions.allSatisfy { $0.preview == nil })
    }

    func testAuditKeepsLongCompleteOutputsAndDistinguishesEmptyFromMissingText() throws {
        let output = String(repeating: "tool output 0123456789\n", count: 60_000)
        var project = fixture()
        project.taskAudits?[0].events = [
            ProjectActivityEvent(id: "command-1", category: "command", title: "Run external tool", status: "completed", input: "", output: output),
            ProjectActivityEvent(id: "command-2", category: "command", title: "Inspect result", status: "completed", input: nil, output: "")
        ]
        let restored = try ProjectStore.decode(ProjectStore.encode(project))
        XCTAssertEqual(restored.taskAudits, project.taskAudits)
        XCTAssertEqual(restored.taskAudits?[0].events[0].output?.utf8.count, output.utf8.count)
        XCTAssertEqual(restored.taskAudits?[0].events[0].input, "")
        XCTAssertNil(restored.taskAudits?[0].events[1].input)
        XCTAssertEqual(restored.taskAudits?[0].events[1].output, "")
    }

    func testSaveNewKeepsRequiredImportedInputsWithoutConversationOrAudit() throws {
        var original = fixture()
        let firstUser = original.messages[0]
        let firstResponse = ChatMessage(role: "assistant", content: "First design ready.", phase: "final_answer")
        let secondUser = ChatMessage(role: "user", content: "Use the external mesh")
        let secondResponse = ChatMessage(role: "assistant", content: "Second design ready.", phase: "final_answer")
        let failedUser = ChatMessage(role: "user", content: "Try a later change")
        original.messages = [firstUser, firstResponse, secondUser, secondResponse, failedUser]
        original.revisions[0].userMessageID = firstUser.id
        original.revisions[0].responseMessageID = firstResponse.id
        let input = CADInputAsset(id: "external-mesh", name: "sdf.stl", format: "stl", data: Data("solid sdf\nendsolid sdf\n".utf8))
        var secondModel = ModelSpec.bracket
        secondModel.inputAssets = [input]
        let second = ProjectRevision(model: secondModel, userMessageID: secondUser.id, responseMessageID: secondResponse.id)
        original.revisions.append(second)
        original.selectedRevisionID = original.revisions.first?.id
        let secondAudit = ProjectTaskAudit(userMessageID: secondUser.id, model: "test-model", reasoningEffort: "high", status: "completed")
        original.taskAudits?.append(secondAudit)
        original.taskAudits?.append(ProjectTaskAudit(userMessageID: failedUser.id, model: "test-model", reasoningEffort: "high", status: "failed"))

        let copy = try SaveNewProject.snapshot(from: original)
        XCTAssertTrue(copy.messages.isEmpty)
        XCTAssertEqual(copy.revisions.map(\.id), [second.id])
        XCTAssertEqual(copy.revisions[0].model.inputAssets, [input])
        XCTAssertNil(copy.taskAudits)
        XCTAssertNil(copy.revisions[0].userMessageID)
        XCTAssertNil(copy.revisions[0].responseMessageID)
        XCTAssertNotEqual(copy.projectID, original.projectID)
        let restored = try ProjectStore.decode(ProjectStore.encode(copy))
        XCTAssertNil(restored.taskAudits)
        XCTAssertTrue(restored.messages.isEmpty)
        XCTAssertEqual(restored.revisions[0].model.inputAssets, [input])
    }

    func testOldFormatFourDocumentWithoutOptionalAuditOrImportedInputFieldsStillOpens() throws {
        let project = LADProject(messages: [], revisions: [ProjectRevision(model: .bracket)], selectedRevisionID: nil)
        let document = try manifest(ProjectStore.encode(project))
        XCTAssertEqual(document["formatVersion"] as? Int, 4)
        XCTAssertNil(document["taskAudits"])
        let restored = try ProjectStore.decode(compress(document))
        XCTAssertNil(restored.taskAudits)
        XCTAssertNil(restored.revisions[0].model.inputAssets)
    }

    func testCandidateAndProducerSourcesArePortableAndDeduplicatedAgainstFinalPrograms() throws {
        var project = fixture()
        let finalProgram = Data(ModelSpec.bracket.script.utf8)
        let candidate = Data("result = cq.Workplane('XY').box(11, 12, 13)\n".utf8)
        let dependency = Data("numpy==2.4.0\n".utf8)
        project.taskAudits?[0].events[0].files = [
            ProjectActivityFile(name: "program.py", path: "/deleted/workspace/program.py", data: finalProgram),
            ProjectActivityFile(name: "earlier.py", path: "/deleted/workspace/earlier.py", data: candidate),
            ProjectActivityFile(name: "requirements.txt", path: "/deleted/workspace/requirements.txt", data: dependency),
            ProjectActivityFile(name: "empty.lock", path: "/deleted/workspace/empty.lock", data: Data())
        ]
        let sources = try XCTUnwrap(project.taskAudits?[0].events[0].files)
        let second = ProjectActivityEvent(id: "tool-2", category: "tool", title: "Review the same program", status: "completed", files: [sources[0]])
        project.taskAudits?[0].events.append(second)
        let encoded = try ProjectStore.encode(project)
        let document = try manifest(encoded)
        let assets = try XCTUnwrap(document["assets"] as? [String: String])
        XCTAssertEqual(assets[digest(finalProgram)], finalProgram.base64EncodedString())
        XCTAssertEqual(assets[digest(candidate)], candidate.base64EncodedString())
        XCTAssertEqual(assets[digest(dependency)], dependency.base64EncodedString())
        XCTAssertEqual(assets[digest(Data())], "")
        let revisions = try XCTUnwrap(document["revisions"] as? [[String: Any]])
        let tasks = try XCTUnwrap(document["taskAudits"] as? [[String: Any]])
        let events = try XCTUnwrap(tasks[0]["events"] as? [[String: Any]])
        let storedFiles = try XCTUnwrap(events[0]["files"] as? [[String: Any]])
        XCTAssertEqual(revisions[0]["scriptAsset"] as? String, storedFiles[0]["dataAsset"] as? String)
        XCTAssertNil(storedFiles[0]["data"])
        let restored = try ProjectStore.decode(encoded)
        XCTAssertEqual(restored.taskAudits, project.taskAudits)
        XCTAssertEqual(restored.taskAudits?[0].events[0].files, sources)
    }

    func testAuditSourceSnapshotsRejectBinaryGeometryDisplayCachesAndUnsafeMetadata() throws {
        let sources: [ProjectActivityFile] = [
            ProjectActivityFile(name: "frame.png", path: "/workspace/frame.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            ProjectActivityFile(name: "solid.step", path: "/workspace/solid.step", data: step),
            ProjectActivityFile(name: "disguised.txt", path: "/workspace/disguised.txt", data: step),
            ProjectActivityFile(name: "disguised.json", path: "/workspace/disguised.json", data: Data("{\"vertices\":[],\"triangles\":[],\"stepPath\":\"/private/model.step\"}".utf8)),
            ProjectActivityFile(name: "bytes.py", path: "/workspace/bytes.py", data: Data([0xFF, 0xFE])),
            ProjectActivityFile(name: "nul.py", path: "/workspace/nul.py", data: Data("result\0oops".utf8)),
            ProjectActivityFile(name: "../program.py", path: "/workspace/program.py", data: Data("result = None".utf8)),
            ProjectActivityFile(name: "program.py", path: "", data: Data("result = None".utf8)),
            ProjectActivityFile(name: "program.py", path: "/workspace/program.py", data: Data(repeating: 0x20, count: ProjectActivityFile.maximumBytes + 1))
        ]
        for source in sources {
            var project = fixture()
            project.taskAudits?[0].events[0].files = [source]
            XCTAssertThrowsError(try ProjectStore.encode(project), "Must reject \(source.name)")
        }
        var project = fixture()
        let file = ProjectActivityFile(name: "program.py", path: "/workspace/program.py", data: Data("result = None".utf8))
        project.taskAudits?[0].events[0].files = [file, file]
        XCTAssertThrowsError(try ProjectStore.encode(project))
    }

    func testInlineAuditOrInputBytesAndMissingReferencesAreRejected() throws {
        var project = fixture()
        project.revisions[0].model.inputAssets = [CADInputAsset(id: "external", name: "external.step", format: "step", data: step)]
        let valid = try manifest(ProjectStore.encode(project))
        var document = valid
        var tasks = try XCTUnwrap(document["taskAudits"] as? [[String: Any]])
        var events = try XCTUnwrap(tasks[0]["events"] as? [[String: Any]])
        events[0]["output"] = "Inline data must not bypass asset validation"
        tasks[0]["events"] = events; document["taskAudits"] = tasks
        XCTAssertThrowsError(try ProjectStore.decode(compress(document)))

        document = valid
        tasks = try XCTUnwrap(document["taskAudits"] as? [[String: Any]])
        events = try XCTUnwrap(tasks[0]["events"] as? [[String: Any]])
        events[0]["outputAsset"] = String(repeating: "0", count: 64)
        tasks[0]["events"] = events; document["taskAudits"] = tasks
        XCTAssertThrowsError(try ProjectStore.decode(compress(document)))

        document = valid
        var revisions = try XCTUnwrap(document["revisions"] as? [[String: Any]])
        var inputs = try XCTUnwrap(revisions[0]["inputAssets"] as? [[String: Any]])
        inputs[0]["data"] = step.base64EncodedString()
        revisions[0]["inputAssets"] = inputs; document["revisions"] = revisions
        XCTAssertThrowsError(try ProjectStore.decode(compress(document)))
    }

    func testInvalidTaskIdentityPrivateReasoningAndInvalidInputKindsAreRejected() throws {
        var project = fixture()
        project.taskAudits?[0].userMessageID = UUID()
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project = fixture(); project.taskAudits?[0].events[0].category = "reasoning"
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project = fixture(); project.taskAudits?[0].events[0].durationSeconds = -1
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project = fixture(); project.taskAudits?[0].events[0].durationSeconds = .infinity
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project = fixture()
        let duplicate = project.taskAudits![0].events[0]
        project.taskAudits?[0].events.append(duplicate)
        XCTAssertThrowsError(try ProjectStore.encode(project))
        project = fixture()
        let startedAt = project.taskAudits![0].startedAt
        project.taskAudits?[0].finishedAt = startedAt.addingTimeInterval(-1)
        XCTAssertThrowsError(try ProjectStore.encode(project))

        for (name, format) in [("preview.png", "png"), ("../external.step", "step"), ("external.step", "STEP")] {
            project = fixture()
            project.revisions[0].model.inputAssets = [CADInputAsset(id: "external", name: name, format: format, data: step)]
            XCTAssertThrowsError(try ProjectStore.encode(project))
        }
        project = fixture()
        let input = CADInputAsset(id: "same", name: "external.step", format: "step", data: step)
        project.revisions[0].model.inputAssets = [input, input]
        XCTAssertThrowsError(try ProjectStore.encode(project))
    }

    private func fixture() -> LADProject {
        let user = ChatMessage(role: "user", content: "Build a design")
        let event = ProjectActivityEvent(id: "tool-1", category: "tool", title: "Build", status: "completed",
                                         input: "workspace/program.py", output: "{\"artifactID\":\"build-1\"}", durationSeconds: 1)
        let task = ProjectTaskAudit(userMessageID: user.id, model: "test-model", reasoningEffort: "high", status: "completed", events: [event])
        return LADProject(messages: [user], revisions: [ProjectRevision(model: .bracket)], selectedRevisionID: nil,
                          projectID: UUID(), taskAudits: [task])
    }

    private func manifest(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(data)) as? [String: Any])
    }

    private func compress(_ document: [String: Any]) throws -> Data {
        try ProjectZIP.encode(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
    }

    private func digest(_ data: Data) -> String { SHA256.hexDigest(data) }
}
