import CryptoKit
import Foundation
@testable import LAD

/// A design that fills every package section, built from fixed values so a
/// package written by an earlier format version can be compared exactly.
enum ProjectPackageFixture {
    /// A 4 × 3 sRGB PNG, used for an image attachment, a saved render and the
    /// Finder thumbnail.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAABKADAAQAAAABAAAAAwAAAAB3TCISAAAAG0lEQVQIHWNkYDjx34aBgQGGWRgCgDwkgCEAAIG7AyUaBIWiAAAAAElFTkSuQmCC")!

    static let step = Data(("ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('Fixture'),'2;1');\nENDSEC;\nDATA;\n" +
        (0..<40).map { "#\($0 + 1)=CARTESIAN_POINT('',(\(Double($0) * 0.1),-0.,1.E-07));\n" }.joined() +
        "ENDSEC;\nEND-ISO-10303-21;\n").utf8)

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }

    /// Seconds whose shortest and 17-digit decimal forms differ.
    static func date(_ offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000.123456789 + offset)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hexDigest(data)
    }

    static func project() -> LADProject {
        let sourceText = "# Bracket dimensions\nwidth = 80.1\nthickness = 0.30000000000000004\n"
        let source = SourceAttachment(id: id(1), name: "dimensions.py", path: "/missing/dimensions.py",
                                      content: sourceText, sha256: digest(Data(sourceText.utf8)))
        let image = SourceAttachment(id: id(2), name: "sketch.png", path: "/missing/sketch.png", content: "",
                                     sha256: digest(png), imageData: png)
        let first = id(10), second = id(11)
        let selection = ProjectSelectionContext(revisionID: first, capturedAt: date(100.1), parts: [
            ProjectSelectedPart(partID: "base", name: "Base", path: ["Bracket", "Base"], solidIndex: 0,
                                anchor: ProjectSelectionAnchor(center: [0.1, -0.0, 2.5e-7], volume: 1234.5678,
                                                               bounds: [-40, -25, 0, 40, 25, 6.000000000000001]))
        ], features: [
            ProjectSelectedFeature(id: CADFeatureID(kind: .face, solidIndex: 0, localIndex: 3), partID: "base",
                                   partName: "Base", partPath: ["Bracket", "Base"],
                                   anchor: ProjectSelectionAnchor(geometryType: "plane", normal: [-0.0, -0.0, -1],
                                                                  area: 0.30000000000000004)),
            ProjectSelectedFeature(id: CADFeatureID(kind: .edge, solidIndex: 1, localIndex: 0), partID: "upright",
                                   partName: "Upright", partPath: ["Bracket", "Upright"],
                                   anchor: ProjectSelectionAnchor(geometryType: "line", direction: [1e-17, 1, -0.0], length: 40))
        ], jointPositions: ["hinge": -0.0])
        let messages = [
            ChatMessage(id: id(20), role: "user", content: "Create a bracket with \"quoted\" text, -0 and 1e-0 / slashes",
                        date: date(0), attachments: [source]),
            ChatMessage(id: id(21), role: "assistant", content: "Checking the runtime.", date: date(5.5), phase: "commentary"),
            ChatMessage(id: id(22), role: "assistant", content: "Bracket ready.", date: date(60.25), phase: "final_answer"),
            ChatMessage(id: id(23), role: "user", content: "Make the base thicker ✓", date: date(120.7),
                        attachments: [image], selection: selection),
            ChatMessage(id: id(24), role: "assistant", content: "Thicker base ready.", date: date(180.9), phase: "final_answer")
        ]
        let parts = [PartNode(id: "bracket", name: "Bracket", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [0], color: PartColor(red: 0.1, green: 0.2, blue: 0.3)),
            PartNode(id: "upright", name: "Upright", solidIndices: [1])
        ])]
        var model = ModelSpec.bracket
        model.sourceSTEP = step
        model.sourceName = "board.step"
        var revisionA = ProjectRevision(id: first, model: model, date: date(61),
                                        partLayout: PartLayout(nodes: parts, movedNodeIDs: ["upright"], userFolderIDs: [],
                                                               renamedNodes: ["upright": "Wall"], collapsedNodeIDs: ["bracket"]),
                                        hiddenSolids: [1], parts: parts)
        revisionA.runtime = CADRuntime(python: "3.12.7", cadquery: "2.5.2", ocp: "7.8.1")
        revisionA.userMessageID = messages[0].id
        revisionA.responseMessageID = messages[2].id
        revisionA.name = "First bracket"
        revisionA.validatedHash = String(repeating: "ab", count: 32)
        var thicker = ModelSpec.bracket
        thicker.script += "\n# Thicker base: 8.000000000000002 mm\n"
        thicker.inputAssets = [CADInputAsset(id: "reference", name: "reference.step", format: "step", data: step)]
        thicker.reorganizePartIDs = ["upright"]
        var revisionB = ProjectRevision(id: second, model: thicker, date: date(181), parts: parts)
        revisionB.userMessageID = messages[3].id
        revisionB.responseMessageID = messages[4].id
        revisionB.partColors = ["upright": PartColor(red: 0.75, green: 0.1, blue: 0.125), "base": PartColor(red: 1, green: 0, blue: -0.0)]
        revisionB.jointPositions = ["hinge": -0.0, "slider": 12.345678901234567]
        let codex = ProjectTaskAudit(id: id(30), userMessageID: messages[0].id, startedAt: date(1), finishedAt: date(60),
                                     agent: "codex", model: "gpt-5", reasoningEffort: "high", status: "completed", events: [
            ProjectActivityEvent(id: "build-1", date: date(2), category: "tool", title: "lad_build", status: "completed",
                                 input: "{\"script\":\"result = 1\"}", output: "Built 2 solids in 0.1 s", durationSeconds: 1.25),
            ProjectActivityEvent(id: "change-1", date: date(3), category: "file_change", title: "candidate.py", status: "completed",
                                 files: [ProjectActivityFile(name: "candidate.py", path: "/tmp/task/candidate.py", data: Data(model.script.utf8))]),
            ProjectActivityEvent(id: "render-1", date: date(4), category: "tool", title: "lad_render", status: "completed",
                                 output: "{\"zoom\":0.1}", durationSeconds: 0.30000000000000004, imageData: png),
            ProjectActivityEvent(id: "command-1", date: date(5), category: "command", title: "ls", status: "failed",
                                 input: "ls", output: "", durationSeconds: 0)
        ], additionalUserMessageIDs: [messages[3].id])
        let external = ProjectTaskAudit(id: id(31), startedAt: date(190), finishedAt: date(195), model: "helper-model",
                                        status: "completed", events: [
            ProjectActivityEvent(id: "inspect-1", date: date(191), category: "diagnostic", title: "Inspect", status: "completed",
                                 output: "Bounds -0 to 40")
        ], externalClient: ProjectExternalAgentIdentity(clientID: "client-1", name: "Helper", version: "1.0"),
           request: "Inspect the bracket", committedRevisionID: second, commitKey: "commit-1", commitArtifactID: "artifact-1")
        var settings = CodexProjectSettings(vendor: .claude, model: "opus", reasoningEffort: "xhigh", reasoningByModel: ["opus": "xhigh"])
        settings.otherAgents = ["codex": AgentModelChoice(model: "gpt-5", reasoningEffort: "high", reasoningByModel: ["gpt-5": "high"])]
        return LADProject(messages: messages, revisions: [revisionA, revisionB], selectedRevisionID: second, projectID: id(99),
                          codexSettings: settings, projectName: "Legacy bracket", showGrid: false, projectionMode: .isometric,
                          displayMode: .shaded, recentPartColors: [PartColor(red: 0.1, green: 0.2, blue: 0.3)],
                          taskAudits: [codex, external],
                          queuedRequests: [
                            ProjectQueuedRequest(id: id(40), content: "Add fillets", date: date(200.01), attachments: [source],
                                                 codexSettings: settings, selection: selection),
                            ProjectQueuedRequest(id: id(41), content: "Then color it", date: date(200.02), attachments: [])
                          ],
                          draftPrompt: "Draft with -0", draftAttachments: [image], queuePaused: true,
                          partsPaneFraction: 0.6180339887498949)
    }
}
