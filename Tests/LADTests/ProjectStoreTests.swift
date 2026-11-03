import XCTest
import CryptoKit
@testable import LAD

final class ProjectStoreTests: XCTestCase {
    func testPartsLayoutVisibilityAndOwnershipRoundtrip() throws {
        var value = project()
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [PartNode(id: "body", name: "Body", solidIndices: [0])])]
        var layout = PartLayout(nodes: parts)
        let folder = try layout.createFolder(named: "Inspection")
        try layout.move(["body"], toParent: folder)
        try layout.rename("body", to: "Shell")
        try layout.setExpanded(false, for: "case")
        try layout.setExpanded(false, for: folder)
        value.revisions[1].preview?.parts = parts
        value.revisions[1].preview?.edgeSolids = [0, 0]
        value.revisions[1].partLayout = layout
        value.revisions[1].hiddenSolids = [0]
        value.messages.append(ChatMessage(role: "assistant", content: "I’m checking the shell clearance.", phase: "commentary"))
        value.messages.append(ChatMessage(role: "assistant", content: "Model ready. Shell clearance is validated.", phase: "final_answer"))
        let data = try ProjectStore.encode(value)
        XCTAssertEqual(data.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        let restored = try ProjectStore.decode(data)
        XCTAssertEqual(restored.revisions[1].parts, parts)
        XCTAssertNil(restored.revisions[1].preview)
        XCTAssertEqual(restored.revisions[1].partLayout, layout)
        XCTAssertEqual(restored.revisions[1].hiddenSolids, [0])
        XCTAssertNil(restored.revisions[1].stepData)
        XCTAssertEqual(restored.messages, value.messages)
        XCTAssertEqual(restored.revisions[0].partLayout?.nodes, restored.revisions[0].parts)
        XCTAssertNil(restored.revisions[0].preview?.parts)
    }

    func testRejectsInvalidCollapsedFolderReferences() throws {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "body", name: "Body", solidIndices: [0])])]
        for collapsed in [["missing"], ["body"], ["case", "case"]] {
            var value = project()
            value.revisions[0].parts = parts
            value.revisions[0].partLayout = PartLayout(nodes: parts, collapsedNodeIDs: collapsed)
            XCTAssertThrowsError(try ProjectStore.encode(value))
        }
    }

    func testRejectsInvalidPartOwnershipHierarchyAndVisibility() throws {
        let corruptions: [(inout ProjectRevision) -> Void] = [
            { $0.preview?.edgeSolids = [0] },
            { $0.preview?.edgeSolids = [0, 1] },
            { $0.preview?.parts = [] },
            { $0.preview?.parts = [PartNode(id: "one", name: "Part", solidIndices: [1])] },
            { $0.preview?.parts = [PartNode(id: "one", name: "Part", solidIndices: [0, 0])] },
            { $0.preview?.parts = [PartNode(id: "same", name: "Folder", solidIndices: [], children: [PartNode(id: "same", name: "Part", solidIndices: [0])])] },
            { $0.partLayout = PartLayout(nodes: [PartNode(id: "part", name: "Part", solidIndices: [])]) },
            { $0.hiddenSolids = [-1] },
            { $0.hiddenSolids = [1] },
            { $0.hiddenSolids = [0, 0] }
        ]
        for corrupt in corruptions {
            var value = project()
            corrupt(&value.revisions[1])
            XCTAssertThrowsError(try ProjectStore.encode(value))
        }
        var nested = PartNode(id: "body", name: "Body", solidIndices: [0])
        for i in 0..<34 { nested = PartNode(id: "folder-\(i)", name: "Folder", solidIndices: [], children: [nested]) }
        XCTAssertThrowsError(try ProjectStore.validatePartHierarchy([nested], solidCount: 1))
    }

    private let step = Data("ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('LAD test'),'2;1');\nENDSEC;\nDATA;\n#1=PRODUCT('part','part','',());\nENDSEC;\nEND-ISO-10303-21;\n".utf8)

    private func preview() -> PreviewMesh {
        // Tetrahedron, with well-formed indices and a visible selection ID.
        PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]],
                    triangles: [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]],
                    edges: [[0, 0, 0, 1, 0, 0], [0, 0, 0, 0, 1, 0]],
                    bounds: [0, 0, 0, 1, 1, 1], volume: 1.0 / 6, area: 2.366,
                    solids: 1, faces: 4, buildSeconds: 0.25, threads: 8,
                    stepPath: "/private/tmp/previous-machine/model.step", triangleSolids: [0, 0, 0, 0])
    }

    private func project() -> LADProject {
        let date = Date(timeIntervalSinceReferenceDate: 813_000_000.5)
        let messages = [ChatMessage(role: "user", content: "Create an 80 mm bracket", date: date),
                        ChatMessage(role: "assistant", content: "Added four holes.", date: date.addingTimeInterval(1)),
                        ChatMessage(role: "user", content: "Make the base 100 mm wide", date: date.addingTimeInterval(2)),
                        ChatMessage(role: "system", content: "Saved revision 2", date: date.addingTimeInterval(3))]
        var wider = ModelSpec.bracket
        wider.title = "Wide bracket"
        wider.script = wider.script.replacingOccurrences(of: "box(80, 50, 6", with: "box(100, 50, 6")
        let revisions = [ProjectRevision(model: .bracket, date: date, preview: preview(), stepData: step),
                         ProjectRevision(model: wider, date: date.addingTimeInterval(4), preview: preview(), stepData: step + Data("\n".utf8))]
        return LADProject(messages: messages, revisions: revisions, selectedRevisionID: revisions[1].id)
    }

    private func roundtrip(_ project: LADProject) throws -> LADProject {
        try ProjectStore.decode(ProjectStore.encode(project))
    }

    func testCompleteProjectRoundtripPreservesAllHistoryAndCADInstructions() throws {
        let original = project()
        let data = try ProjectStore.encode(original)
        let payload = try ProjectZIP.decode(data)
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("previous-machine"))
        let restored = try ProjectStore.decode(data)
        XCTAssertEqual(restored.formatVersion, 1)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.selectedRevisionID, original.selectedRevisionID)
        XCTAssertEqual(restored.revisions.map(\.id), original.revisions.map(\.id))
        XCTAssertEqual(restored.revisions.map(\.date), original.revisions.map(\.date))
        XCTAssertEqual(restored.revisions.map(\.model), original.revisions.map(\.model))
        for actual in restored.revisions {
            XCTAssertNil(actual.stepData, "Generated STEP bytes must not be stored in the project.")
            XCTAssertNil(actual.preview, "Derived display data must not be stored in the project.")
            XCTAssertEqual(actual.parts?.flatMap(\.allSolidIndices), [0])
        }
        // Serialization must not alter the live preview's temporary export path.
        XCTAssertEqual(original.revisions[0].preview?.stepPath, "/private/tmp/previous-machine/model.step")
    }

    func testPortableDiskRoundtripWithoutSessionGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Design.lad")
        let original = project()
        try ProjectStore.write(original, to: file)
        XCTAssertEqual(file.pathExtension, "lad")
        XCTAssertTrue(try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: ProjectStore.readArchive(from: file)) as? [String: Any] != nil, true)
        let restored = try ProjectStore.read(from: file)
        XCTAssertNil(restored.revisions.last?.stepData)
        var withoutGeometry = original
        withoutGeometry.revisions[0].preview = nil
        withoutGeometry.revisions[0].stepData = nil
        withoutGeometry.revisions[1].preview?.triangleSolids = nil
        let decoded = try roundtrip(withoutGeometry)
        XCTAssertNil(decoded.revisions[0].preview)
        XCTAssertNil(decoded.revisions[0].stepData)
        XCTAssertNil(decoded.revisions[1].preview?.triangleSolids)
    }

    func testProjectZIPCompressesSourceAssetsAndPreservesCompleteContents() throws {
        var original = project()
        let attachment = source(String(repeating: "(segment (start 1 2) (end 3 4) (width 0.25))\n", count: 8_000))
        original.messages[0].attachments = [attachment]
        let data = try ProjectStore.encode(original)
        let payload = try ProjectZIP.decode(data)
        XCTAssertEqual(data.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        XCTAssertLessThan(data.count, payload.count / 4, "Saved projects must compress their source assets")
        let restored = try ProjectStore.decode(data)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.revisions.map(\.model), original.revisions.map(\.model))
        XCTAssertEqual(restored.selectedRevisionID, original.selectedRevisionID)
    }

    func testProjectIdentitySurvivesPortableRoundtrip() throws {
        var original = project()
        let identity = UUID()
        original.projectID = identity
        let restored = try ProjectStore.decode(ProjectStore.encode(original))
        XCTAssertEqual(restored.projectID, identity)
        XCTAssertEqual(restored.formatVersion, 1)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.revisions.map(\.id), original.revisions.map(\.id))
        XCTAssertTrue(restored.revisions.allSatisfy { $0.stepData == nil })
    }

    func testRejectsFormerInlineDocumentInsteadOfRestoringIt() throws {
        let bytes = try JSONEncoder().encode(project())
        XCTAssertThrowsError(try ProjectStore.decode(bytes))
    }

    func testRejectsUnsupportedVersionMissingSelectionAndDuplicateIDs() throws {
        var value = project()
        value.formatVersion = 999
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.selectedRevisionID = UUID()
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.revisions[1].id = value.revisions[0].id
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.messages[1].id = value.messages[0].id
        XCTAssertThrowsError(try roundtrip(value))
    }

    func testRejectsCorruptedEmbeddedGeometryBeforeItReachesViewport() throws {
        let corruptions: [(inout PreviewMesh) -> Void] = [
            { $0.vertices[0] = [0, 0] },
            { $0.vertices[0][0] = 2_000_000 },
            { $0.vertices[0][0] = 2 }, // outside declared bounds
            { $0.triangles[0] = [0, 1] },
            { $0.triangles[0][0] = -1 },
            { $0.triangles[0][0] = 4 }, // index equals vertex count
            { $0.edges[0] = [0, 0, 0] },
            { $0.bounds = [0, 0, 0] },
            { $0.bounds[3] = -1 },
            { $0.volume = -1 },
            { $0.area = 0 },
            { $0.solids = 0 },
            { $0.faces = 0 },
            { $0.faces = -1 },
            { $0.threads = 0 },
            { $0.buildSeconds = -1 },
            { $0.triangleSolids = [0] },
            { $0.triangleSolids = [0, 0, 0, 1] },
            { $0.vertices = [] },
            { $0.triangles = [] }
        ]
        for (index, corrupt) in corruptions.enumerated() {
            var value = project()
            corrupt(&value.revisions[0].preview!)
            XCTAssertThrowsError(try roundtrip(value), "Corruption \(index) was accepted")
        }
        var nonfinite = project()
        nonfinite.revisions[0].preview!.vertices[0][0] = .nan
        XCTAssertThrowsError(try ProjectStore.encode(nonfinite))
        nonfinite = project(); nonfinite.revisions[0].preview!.bounds[0] = -.infinity
        XCTAssertThrowsError(try ProjectStore.encode(nonfinite))
        var excessive = preview()
        excessive.vertices = Array(repeating: [0, 0, 0], count: 1_000_001)
        XCTAssertThrowsError(try ProjectStore.validatePreview(excessive))
    }

    func testPreviewAcceptsMoreThanTwentyThousandNativeFaces() throws {
        var mesh = preview()
        mesh.faces = 56_156
        XCTAssertNoThrow(try ProjectStore.validatePreview(mesh))
        var value = project()
        value.revisions[0].preview = mesh
        XCTAssertNoThrow(try roundtrip(value))
    }

    func testRejectsMalformedSessionSTEPAssets() throws {
        var value = project()
        value.revisions[0].stepData = Data("This is not STEP geometry".utf8)
        XCTAssertThrowsError(try ProjectStore.encode(value))
        value = project(); value.revisions[0].stepData = Data("ISO-10303-21;\ntruncated".utf8)
        XCTAssertThrowsError(try ProjectStore.encode(value))
    }

    func testRejectsOversizeFileBeforeReadingItsContents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-oversize-\(UUID()).lad")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ProjectStore.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try ProjectStore.read(from: file))
    }

    private func source(_ content: String = "FeatureScript 2500;\n// Source dimensions: 64 × 42 mm\n") -> SourceAttachment {
        SourceAttachment(name: "enclosure.fs", path: "/source/no-longer-present/enclosure.fs", content: content,
                         sha256: SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    func testSourceAttachmentRoundtripPreservesCompleteTextWithoutOriginalFile() throws {
        var original = project()
        let attachment = source()
        original.messages[0].attachments = [attachment]
        let restored = try ProjectStore.decode(ProjectStore.encode(original))
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.messages[0].attachments?.first?.content, attachment.content)
        XCTAssertEqual(restored.messages[0].attachments?.first?.sha256, attachment.sha256)
        XCTAssertEqual(restored.messages[0].attachments?.first?.path, attachment.path)

        var noAttachments = original
        noAttachments.messages[0].attachments = nil
        let restoredWithoutAttachments = try roundtrip(noAttachments)
        XCTAssertNil(restoredWithoutAttachments.messages[0].attachments)
        XCTAssertEqual(restoredWithoutAttachments.messages[0].content, original.messages[0].content)
    }

    func testRejectsCorruptedAndExcessiveSourceAttachments() throws {
        var value = project()
        value.messages[0].attachments = [source()]
        value.messages[0].attachments![0].content += "// tampered"
        XCTAssertThrowsError(try roundtrip(value))

        value = project(); value.messages[0].attachments = Array(repeating: source(), count: 5)
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.messages[0].attachments = [source(), source()]
        value.messages[0].attachments![1].id = value.messages[0].attachments![0].id
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.messages[0].attachments = [source(String(repeating: "a", count: 1_048_577))]
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.messages[0].attachments = [source("")]
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.messages[0].attachments = [source("bad\0source")]
        XCTAssertThrowsError(try roundtrip(value))
        value = project(); value.messages[0].attachments = [source(String(repeating: "a", count: 800_000)), source(String(repeating: "b", count: 800_000)), source(String(repeating: "c", count: 800_000))]
        XCTAssertThrowsError(try roundtrip(value))
    }

    func testCadQueryProgramRoundtripPreservesEveryRevisionProgram() throws {
        var original = project()
        let program = """
        import cadquery as cq
        result = cq.Workplane("XY").rect(20, 12).workplane(offset=8).circle(6).loft()
        """
        original.revisions[1].model = ModelSpec(title: "Lofted adapter", summary: "A loft between a rectangular base and circular top.", units: "mm", script: program)
        let restored = try roundtrip(original)
        XCTAssertEqual(restored.revisions[1].model.script, program)
        XCTAssertNil(restored.revisions[1].stepData)
        XCTAssertEqual(restored.revisions[0].model, .bracket)
        XCTAssertFalse(restored.revisions[0].model.script.isEmpty)
    }

    func testRejectsInvalidCadQueryProgramDefinitions() throws {
        func model(_ script: String) -> ModelSpec {
            ModelSpec(title: "Program", summary: "Test program", units: "mm", script: script)
        }
        let invalid = [model(""), model(" \n\t\r "), model(String(repeating: "é", count: 100_001)), model("result = None\0")]
        for (index, badModel) in invalid.enumerated() {
            var value = project()
            value.revisions[0].model = badModel
            XCTAssertThrowsError(try ProjectStore.encode(value), "Invalid CadQuery definition \(index) was accepted")
        }
        var atLimit = project()
        atLimit.revisions[0].model = model(String(repeating: "#", count: 200_000))
        XCTAssertNoThrow(try roundtrip(atLimit))
        atLimit.revisions[0].model.script += "a"
        XCTAssertThrowsError(try ProjectStore.encode(atLimit))
    }

    func testModelProtocolRequiresProgramAndRejectsFeatureGraphFields() throws {
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ModelSpec.bracket)) as? [String: Any])
        XCTAssertNil(valid["nodes"])
        XCTAssertNil(valid["result"])
        for field in ["script", "nodes", "result"] {
            var changed = valid
            if field == "script" { changed.removeValue(forKey: field) }
            else { changed[field] = NSNull() }
            let bytes = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try JSONDecoder().decode(ModelSpec.self, from: bytes), "Unsupported definition \(field) was accepted")
        }
    }

    func testNativeSTEPSourceRoundtripPreservesBaseGeometryAcrossRevisions() throws {
        var original = project()
        let imported = ModelSpec(title: "PCB", summary: "Native board geometry imported from KiCad.", units: "mm",
                                 script: "result = imported_model",
                                 sourceSTEP: step, sourceName: "controller.kicad_pcb")
        original.revisions[0].model = imported
        var refined = imported
        refined.title = "Raised PCB"
        refined.script = "result = imported_model.translate((0, 0, 5))"
        original.revisions[1].model = refined

        let restored = try ProjectStore.decode(ProjectStore.encode(original))
        XCTAssertEqual(restored.revisions.map(\.model), original.revisions.map(\.model))
        XCTAssertEqual(restored.revisions.map { $0.model.sourceSTEP }, [step, step])
        XCTAssertEqual(restored.revisions.map { $0.model.sourceName }, ["controller.kicad_pcb", "controller.kicad_pcb"])
        XCTAssertNil(restored.revisions[1].stepData)
        XCTAssertNotEqual(restored.revisions[1].model.sourceSTEP, restored.revisions[1].stepData)

        // A program may retain source provenance without an imported STEP input.
        var metadataOnly = project()
        metadataOnly.revisions[0].model.sourceName = "controller.kicad_pcb"
        let metadata = try roundtrip(metadataOnly)
        XCTAssertNil(metadata.revisions[0].model.sourceSTEP)
        XCTAssertEqual(metadata.revisions[0].model.sourceName, "controller.kicad_pcb")
        let generated = try roundtrip(project())
        XCTAssertNil(generated.revisions[0].model.sourceSTEP)
        XCTAssertNil(generated.revisions[0].model.sourceName)
    }

    func testRejectsMalformedNativeSTEPSourceAndInvalidSourceNames() throws {
        for source in [Data(), Data("Not STEP geometry".utf8), Data("ISO-10303-21;\ntruncated".utf8)] {
            var value = project()
            value.revisions[0].model.sourceSTEP = source
            XCTAssertThrowsError(try roundtrip(value))
        }
        for name in ["", "   ", ".", "..", "/tmp/board.step", "parts/board.step", "parts\\board.step", "bad\0name.step", "bad\nname.step", String(repeating: "é", count: 129)] {
            var value = project()
            value.revisions[0].model.sourceName = name
            XCTAssertThrowsError(try roundtrip(value), "Invalid source name was accepted: \(name.debugDescription)")
        }
        var valid = project()
        valid.revisions[0].model.sourceSTEP = step
        valid.revisions[0].model.sourceName = String(repeating: "a", count: 251) + ".step"
        XCTAssertNoThrow(try roundtrip(valid))
    }

    func testNativeSTEPSourceAndImportedInputsSupport512MBBoundary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-source-boundary-\(UUID()).step")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        for size in [512_000_000, 512_000_001] {
            try handle.truncate(atOffset: UInt64(size))
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("ISO-10303-21;\n".utf8))
            let footer = Data("\nEND-ISO-10303-21;\n".utf8)
            try handle.seek(toOffset: UInt64(size - footer.count))
            try handle.write(contentsOf: footer)
            // The application boundary checks metadata and STEP delimiters;
            // exact geometry validation remains the native worker's job.
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            var model = ModelSpec.bracket
            model.sourceSTEP = data
            let asset = CADInputAsset(id: "reference", name: "reference.step", format: "step", data: data)
            if size == 512_000_000 {
                XCTAssertNoThrow(try ProjectStore.validateModel(model))
                XCTAssertNoThrow(try ProjectStore.validateInputAssets([asset]))
            } else {
                XCTAssertThrowsError(try ProjectStore.validateModel(model))
                XCTAssertThrowsError(try ProjectStore.validateInputAssets([asset]))
            }
        }
    }
}
