import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class ExternalAgentAuditTests: XCTestCase {
    private let request = "Create a 10 mm cube"

    private func audit() -> ProjectTaskAudit {
        ProjectTaskAudit(externalClient: ProjectExternalAgentIdentity(clientID: "client-1", name: "CAD assistant", version: "1.2"),
                         request: request)
    }

    private func project() -> LADProject {
        LADProject(messages: [], revisions: [], selectedRevisionID: nil, projectID: UUID(), taskAudits: [audit()])
    }

    private func packageURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-external-audit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder); ProjectPackage.clearSessionCache() }
        return folder.appendingPathComponent("Design.lad", isDirectory: true)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hexDigest(data)
    }

    func testExternalTaskRoundTripsWithoutInventingChatOrModelMetadata() throws {
        var value = project()
        value.taskAudits![0].events = [ProjectActivityEvent(id: "call-1", category: "tool", title: "lad_build", status: "completed",
            input: request, files: [ProjectActivityFile(name: "candidate.py", path: "/removed/candidate.py", data: Data(ModelSpec.bracket.script.utf8))])]
        let snapshot = try ProjectArchive.split(value)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.metadata) as? [String: Any])
        let row = try XCTUnwrap((metadata["taskAudits"] as? [[String: Any]])?.first)
        XCTAssertNil(row["userMessageID"])
        XCTAssertNil(row["model"])
        XCTAssertNil(row["reasoningEffort"])
        XCTAssertNil(row["request"])
        XCTAssertEqual(row["requestAsset"] as? String, digest(Data(request.utf8)))
        XCTAssertEqual(snapshot.assets.count, 2, "The request and tool input share exact bytes; the candidate is stored once.")

        let url = try packageURL()
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: url)
        XCTAssertTrue(restored.messages.isEmpty)
        XCTAssertEqual(restored.taskAudits?.first?.externalClient, value.taskAudits?.first?.externalClient)
        XCTAssertEqual(restored.taskAudits?.first?.request, request)
        XCTAssertEqual(restored.taskAudits?.first?.events.first?.files, value.taskAudits?.first?.events.first?.files)
        XCTAssertNil(restored.taskAudits?.first?.model)
        XCTAssertNil(restored.taskAudits?.first?.reasoningEffort)
        XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(restored)).taskAudits, restored.taskAudits)
    }

    func testExternalTaskProvenanceCannotReplaceMissingOrInvalidInitiatingRequest() throws {
        let corruptions: [(inout ProjectTaskAudit) -> Void] = [
            { $0.externalClient = nil },
            { $0.externalClient!.clientID = "" },
            { $0.externalClient!.name = "\n" },
            { $0.externalClient!.version = "invalid\nversion" },
            { $0.request = nil },
            { $0.request = " " },
            { $0.request = "invalid\0request" },
            { $0.request = String(repeating: "a", count: 1_000_001) },
            { $0.userMessageID = UUID() },
            { $0.additionalUserMessageIDs = [UUID()] },
            { $0.model = "private\nmetadata" }
        ]
        for (index, corrupt) in corruptions.enumerated() {
            var value = project()
            corrupt(&value.taskAudits![0])
            XCTAssertThrowsError(try ProjectStore.validate(value), "Corruption \(index)")
        }
        var internalTask = ProjectTaskAudit(userMessageID: UUID(), model: "local-model", reasoningEffort: "high")
        XCTAssertThrowsError(try ProjectStore.validateTaskAudits([internalTask], messages: []))
        let user = ChatMessage(role: "user", content: "Inspect this design")
        internalTask.userMessageID = user.id
        XCTAssertNoThrow(try ProjectStore.validateTaskAudits([internalTask], messages: [user]))
        internalTask.model = nil
        XCTAssertThrowsError(try ProjectStore.validateTaskAudits([internalTask], messages: [user]))
    }

    func testCommitReceiptSurvivesReopeningAndItsRevisionReferenceIsAlwaysChecked() throws {
        var value = project()
        let revision = ProjectRevision(model: .bracket)
        value.revisions = [revision]
        value.selectedRevisionID = revision.id
        value.taskAudits![0].committedRevisionID = revision.id
        value.taskAudits![0].commitKey = "commit-1"
        value.taskAudits![0].commitArtifactID = "candidate-1"
        let url = try packageURL()
        try ProjectStore.write(value, to: url)
        ProjectPackage.clearSessionCache()
        XCTAssertEqual(try ProjectStore.read(from: url).taskAudits, value.taskAudits)

        let corruptions: [(inout LADProject) -> Void] = [
            { $0.taskAudits![0].commitKey = nil },
            { $0.taskAudits![0].commitKey = String(repeating: "a", count: 129) },
            { $0.taskAudits![0].commitArtifactID = "invalid\nartifact" },
            { $0.taskAudits![0].committedRevisionID = UUID() },
            { $0.revisions = []; $0.selectedRevisionID = nil }
        ]
        for (index, corrupt) in corruptions.enumerated() {
            var changed = value
            corrupt(&changed)
            var verified = [String: Data]()
            try ProjectStore.validate(value, verifiedAttachmentPayloads: &verified)
            XCTAssertThrowsError(try ProjectStore.validate(changed, verifiedAttachmentPayloads: &verified, validatedPrevious: value),
                                 "Incremental validation must recheck receipt corruption \(index)")
        }
    }

    func testIncrementalActivityAndSettingsSavesReuseRequestAsset() throws {
        let url = try packageURL()
        var value = project()
        try ProjectStore.write(value, to: url)
        let hash = digest(Data(request.utf8))
        let assetURL = url.appendingPathComponent("assets/sha256/\(hash.prefix(2))/\(hash)")
        let original = try FileManager.default.attributesOfItem(atPath: assetURL.path)
        let bytes = try Data(contentsOf: assetURL)
        for index in 0..<3 {
            value.taskAudits![0].events.append(ProjectActivityEvent(id: "call-\(index)", category: "tool", title: "lad_inspect", status: "completed"))
            try ProjectStore.write(value, to: url)
        }
        value.showGrid = false
        try ProjectStore.write(value, to: url)
        let current = try FileManager.default.attributesOfItem(atPath: assetURL.path)
        XCTAssertEqual(current[.systemFileNumber] as? NSNumber, original[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(current[.modificationDate] as? Date, original[.modificationDate] as? Date)
        XCTAssertEqual(try Data(contentsOf: assetURL), bytes)
        ProjectPackage.clearSessionCache()
        let restored = try ProjectStore.read(from: url)
        XCTAssertEqual(restored.taskAudits, value.taskAudits)
        XCTAssertEqual(restored.showGrid, false)
    }

    func testTranscriptIdentifiesExternalActorAndOnlyReportedModelMetadata() {
        var task = audit()
        let text = ProjectActivityTranscript.text(for: [task])
        XCTAssertTrue(text.contains("CAD assistant (1.2)"))
        XCTAssertTrue(text.contains("Client ID: client-1"))
        XCTAssertTrue(text.contains("Request:\n\(request)"))
        XCTAssertFalse(text.contains("Default model"))
        XCTAssertFalse(text.contains("Optional("))
        task.model = "external-model"
        task.reasoningEffort = "high"
        XCTAssertTrue(ProjectActivityTranscript.text(for: [task]).contains("external-model · high"))
    }
}
