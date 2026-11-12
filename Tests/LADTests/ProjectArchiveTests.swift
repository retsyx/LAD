import CryptoKit
import XCTest
@testable import LAD

final class ProjectArchiveTests: XCTestCase {
    private let step = Data("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;\n".utf8)

    func testValidationReceiptRoundTripsAsOneOptionalRevisionField() throws {
        var value = project(attachments: [])
        value.revisions[0].validatedHash = String(repeating: "a", count: 64)
        let json = try archive(value)
        let stored = try XCTUnwrap(json["revisions"] as? [[String: Any]])
        XCTAssertEqual(stored[0]["validated_hash"] as? String, value.revisions[0].validatedHash)
        let restored = try ProjectStore.decode(ProjectStore.encode(value))
        XCTAssertEqual(restored.revisions[0].validatedHash, value.revisions[0].validatedHash)
        value.revisions[0].validatedHash = nil
        XCTAssertNil(try ProjectStore.decode(ProjectStore.encode(value)).revisions[0].validatedHash)
    }

    func testCommentaryAndValidatedFinalSummaryRemainInSavedConversation() throws {
        var value = project()
        value.messages = [
            ChatMessage(role: "user", content: "Add connector access"),
            ChatMessage(role: "assistant", content: "I’ll check connector positions and add matching cutouts.", phase: "commentary"),
            ChatMessage(role: "assistant", content: "The openings are aligned; I’m checking the lid clearance.", phase: "commentary"),
            ChatMessage(role: "assistant", content: "Model ready. Added HDMI and USB access.", phase: "final_answer")
        ]
        let encoded = try ProjectStore.encode(value)
        let restored = try ProjectStore.decode(encoded)
        XCTAssertEqual(restored.messages, value.messages)
        let json = try manifest(encoded)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertNil(messages[0]["phase"])
        XCTAssertEqual(messages[1]["phase"] as? String, "commentary")
        XCTAssertEqual(messages[3]["phase"] as? String, "final_answer")
    }

    func testAssistantMessagePhasesCannotBeAppliedToUserOrStatusMessages() throws {
        for (role, phase) in [("user", "commentary"), ("system", "final_answer"), ("assistant", "reasoning")] {
            var value = project()
            value.messages = [ChatMessage(role: role, content: "Test message", phase: phase)]
            XCTAssertThrowsError(try ProjectStore.encode(value))
        }
        var value = project()
        value.messages = [ChatMessage(role: "assistant", content: "A short update.", phase: "commentary")]
        var json = try archive(value)
        var messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        messages[0]["phase"] = "reasoning"
        json["messages"] = messages
        XCTAssertThrowsError(try ProjectStore.decode(compressed(json)))
    }

    func testShippedExampleContainsCompleteInstructionsWithoutGeneratedGeometry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Examples/Mounting Bracket.lad")
        XCTAssertTrue(try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectStore.readArchive(from: file)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 5)
        let example = try ProjectStore.read(from: file)
        XCTAssertEqual(example.revisions.count, 2)
        XCTAssertEqual(example.messages.count, 4)
        XCTAssertTrue(example.revisions.allSatisfy { $0.preview == nil && !$0.model.script.isEmpty })
        XCTAssertTrue(example.revisions.allSatisfy { $0.parts?.isEmpty == false })
        XCTAssertEqual(example.selectedRevisionID, example.revisions.last?.id)
    }

    func testIdenticalImportedBytesAcrossEveryStoredFileRoleAreStoredOnce() throws {
        // File payloads are opaque to the archive: this text deliberately fills
        // every file role to verify that deduplication is independent of role.
        let text = String(decoding: step, as: UTF8.self)
        let attachment = source(text, name: "board.kicad_pcb", path: "/old/board.kicad_pcb")
        var value = project(attachments: [attachment])
        let model = program(text, sourceSTEP: step)
        value.revisions = (0..<2).map { index in
            ProjectRevision(model: model, date: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        value.selectedRevisionID = value.revisions.last?.id
        let json = try archive(value)
        let assets = try XCTUnwrap(json["assets"] as? [String: String])
        let key = digest(step)
        XCTAssertEqual(assets, [key: step.base64EncodedString()])
        XCTAssertEqual(json["formatVersion"] as? Int, 4)
        for revision in try XCTUnwrap(json["revisions"] as? [[String: Any]]) {
            XCTAssertEqual(revision["sourceSTEPAsset"] as? String, key)
            XCTAssertEqual(revision["scriptAsset"] as? String, key)
            XCTAssertNil(revision["stepAsset"])
            let storedModel = try XCTUnwrap(revision["model"] as? [String: Any])
            XCTAssertNil(storedModel["script"])
            XCTAssertNil(storedModel["sourceSTEP"])
        }
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let attachments = try XCTUnwrap(messages[0]["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments[0]["contentAsset"] as? String, key)
        XCTAssertNil(attachments[0]["content"])

        let restored = try ProjectStore.decode(ProjectStore.encode(value))
        XCTAssertEqual(restored.messages, value.messages)
        XCTAssertEqual(restored.revisions.map(\.model), value.revisions.map(\.model))
        }

    func testRepeatedPCBReferencesKeepMetadataAndChangedBytesStoreSeparately() throws {
        let pcb = "(kicad_pcb (version 20240108) (general (thickness 1.6)))\n"
        let first = source(pcb, name: "board.kicad_pcb", path: "/original/board.kicad_pcb")
        let copied = source(pcb, name: "board.kicad_pcb", path: "/renamed folder/board.kicad_pcb")
        let changed = source(pcb + "; revision 2\n", name: "board.kicad_pcb", path: first.path)
        var value = project(attachments: [first])
        value.messages.append(ChatMessage(role: "user", content: "Use this copy", attachments: [copied]))
        value.messages.append(ChatMessage(role: "user", content: "Use the revised board", attachments: [changed]))
        let json = try archive(value)
        let assets = try XCTUnwrap(json["assets"] as? [String: String])
        XCTAssertEqual(assets.count, 3, "Two source snapshots and one shared CAD program")
        XCTAssertEqual(assets[first.sha256], Data(pcb.utf8).base64EncodedString())
        XCTAssertEqual(assets[changed.sha256], Data(changed.content.utf8).base64EncodedString())
        XCTAssertNotEqual(first.id, copied.id)
        XCTAssertNotEqual(first.sha256, changed.sha256)
        let restored = try ProjectStore.decode(ProjectStore.encode(value))
        XCTAssertEqual(restored.messages, value.messages)
        XCTAssertEqual(restored.messages.compactMap { $0.attachments?.first?.id }, [first.id, copied.id, changed.id])
        XCTAssertEqual(restored.messages.compactMap { $0.attachments?.first?.path }, [first.path, copied.path, changed.path])
    }

    func testGeneratedOutputsAreAbsentButSharedImportedInputsAndInstructionsSurvive() throws {
        let imported = step + Data("\n/* original imported PCB */\n".utf8)
        let output = step + Data("\n/* derived enclosure output */\n".utf8)
        let firstModel = program("result = imported_model", sourceSTEP: imported)
        let secondModel = program("result = imported_model.translate((0, 0, 5))", sourceSTEP: imported)
        var value = project()
        value.revisions = [ProjectRevision(model: .bracket),
                           ProjectRevision(model: firstModel),
                           ProjectRevision(model: secondModel)]
        value.selectedRevisionID = value.revisions.last?.id
        let json = try archive(value)
        let assets = try XCTUnwrap(json["assets"] as? [String: String])
        XCTAssertEqual(assets.count, 4, "One imported STEP and three revision programs are sufficient")
        XCTAssertEqual(assets[digest(imported)], imported.base64EncodedString())
        XCTAssertNil(assets[digest(output)], "No derived STEP output belongs in the project")
        let revisions = try XCTUnwrap(json["revisions"] as? [[String: Any]])
        XCTAssertEqual(revisions[1]["sourceSTEPAsset"] as? String, revisions[2]["sourceSTEPAsset"] as? String)
        XCTAssertTrue(revisions.allSatisfy { $0["stepAsset"] == nil && $0["stepData"] == nil && $0["preview"] == nil })
        let restored = try ProjectStore.decode(ProjectStore.encode(value))
        XCTAssertEqual(restored.revisions.map(\.model), value.revisions.map(\.model))
        XCTAssertEqual(restored.messages, value.messages)
        }

    func testRejectsFormerArchiveVersions() throws {
        let json = try archive(project())
        for version in [1, 2, 3, 5] {
            XCTAssertThrowsError(try ProjectStore.decode(mutated(json) { $0["formatVersion"] = version }))
        }
    }

    func testEveryRevisionRequiresProgramAssetWithoutGraphMetadata() throws {
        let json = try archive(project())
        let revisions = try XCTUnwrap(json["revisions"] as? [[String: Any]])
        for revision in revisions {
            XCTAssertNotNil(revision["scriptAsset"] as? String)
            let model = try XCTUnwrap(revision["model"] as? [String: Any])
            XCTAssertNil(model["nodes"])
            XCTAssertNil(model["result"])
            XCTAssertNil(model["script"])
            XCTAssertNil(model["sourceSTEP"])
        }
        let replacements: [Any?] = [nil, NSNull()]
        for replacement in replacements {
            XCTAssertThrowsError(try ProjectStore.decode(mutated(json) { json in
                try self.updateRevision(&json) { $0["scriptAsset"] = replacement }
            }))
        }
        for field in ["nodes", "result"] {
            XCTAssertThrowsError(try ProjectStore.decode(mutated(json) { json in
                try self.updateRevision(&json) { revision in
                    var model = try XCTUnwrap(revision["model"] as? [String: Any])
                    model[field] = NSNull()
                    revision["model"] = model
                }
            }))
        }
    }

    func testSavedRecipeRejectsMissingOrInvalidImportedInputsAndPrograms() throws {
        var value = project()
        value.revisions[0].model = program("result = imported_model", sourceSTEP: step)
        let json = try archive(value)
        for field in ["sourceSTEPAsset", "scriptAsset"] {
            let missing = try mutated(json) { json in
                try self.updateRevision(&json) { $0[field] = String(repeating: "0", count: 64) }
            }
            XCTAssertThrowsError(try ProjectStore.decode(missing), "Missing \(field) was accepted")
        }
        let invalidSTEP = Data("This is not an imported STEP model".utf8)
        let badKey = digest(invalidSTEP)
        let corruptedSource = try mutated(json) { json in
            var assets = try XCTUnwrap(json["assets"] as? [String: String])
            assets.removeValue(forKey: self.digest(self.step))
            assets[badKey] = invalidSTEP.base64EncodedString()
            json["assets"] = assets
            try self.updateRevision(&json) { $0["sourceSTEPAsset"] = badKey }
        }
        XCTAssertThrowsError(try ProjectStore.decode(corruptedSource), "Valid hash does not make invalid STEP usable")
    }

    func testHistoryKeepsPartsLayoutVisibilityAndCADInstructionsWithoutGeneratedGeometry() throws {
        let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "case/body", name: "Body", solidIndices: [0])
        ])]
        var originalLayout = PartLayout(nodes: parts)
        try originalLayout.rename("case/body", to: "First shell")
        try originalLayout.setExpanded(false, for: "case")
        var editedLayout = originalLayout
        let folder = try editedLayout.createFolder(named: "Print preparation")
        try editedLayout.move(["case/body"], toParent: folder)
        try editedLayout.rename("case/body", to: "Printed shell")
        try editedLayout.setExpanded(false, for: folder)
        var wider = ModelSpec.bracket
        wider.script = wider.script.replacingOccurrences(of: "box(80, 50, 6", with: "box(100, 50, 6")
        let date = Date(timeIntervalSinceReferenceDate: 810_000_000.5)
        var first = ProjectRevision(model: .bracket, date: date, preview: preview(parts: parts),
                                   partLayout: originalLayout, hiddenSolids: [])
        first.parts = parts
        first.runtime = CADRuntime(python: "3.11.13", cadquery: "2.6.1", ocp: "7.8.1.1")
        // The second revision exercises extracting the semantic hierarchy from
        // a live preview before that derived preview is discarded.
        let second = ProjectRevision(model: wider, date: date.addingTimeInterval(5), preview: preview(parts: parts),
                                    partLayout: editedLayout, hiddenSolids: [0])
        var value = project()
        value.revisions = [first, second]
        value.selectedRevisionID = second.id
        let encoded = try ProjectStore.encode(value)
        let payload = try ProjectZIP.decode(encoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        for revision in try XCTUnwrap(json["revisions"] as? [[String: Any]]) {
            for field in ["preview", "stepData", "stepAsset", "vertices", "triangles", "edges", "bounds", "triangleSolids", "edgeSolids", "stepPath", "buildSeconds"] {
                XCTAssertNil(revision[field], "Derived display field \(field) was saved")
            }
        }
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("old-display-cache"))
        let restored = try ProjectStore.decode(encoded)
        XCTAssertEqual(restored.projectID, value.projectID)
        XCTAssertEqual(restored.selectedRevisionID, value.selectedRevisionID)
        XCTAssertEqual(restored.messages, value.messages)
        XCTAssertEqual(restored.revisions.map(\.id), value.revisions.map(\.id))
        XCTAssertEqual(restored.revisions.map(\.date), value.revisions.map(\.date))
        XCTAssertEqual(restored.revisions.map(\.runtime), value.revisions.map(\.runtime))
        XCTAssertEqual(restored.revisions.map(\.model), value.revisions.map(\.model))
        XCTAssertTrue(restored.revisions.allSatisfy { $0.preview == nil })
        XCTAssertEqual(restored.revisions.map(\.parts), [parts, parts])
        XCTAssertEqual(restored.revisions.map(\.partLayout), [originalLayout, editedLayout])
        XCTAssertEqual(restored.revisions.map { $0.partLayout?.collapsedNodeIDs },
                       [["case"], ["case", folder].sorted()])
        XCTAssertEqual(restored.revisions.map(\.hiddenSolids), [[], [0]])
        XCTAssertEqual(value.revisions[0].preview?.stepPath, "/tmp/old-display-cache/model.step")
        XCTAssertEqual(value.revisions[0].preview?.vertices.count, 4, "Saving must not remove the live display cache")
    }

    func testUnnamedLiveModelKeepsGenericPartOwnershipWhenPreviewIsDropped() throws {
        var value = project()
        value.revisions[0].preview = preview(parts: nil)
        value.revisions[0].hiddenSolids = [0]
        let restored = try ProjectStore.decode(ProjectStore.encode(value))
        let expected = [PartNode(id: "solid/0", name: "Part 1", solidIndices: [0])]
        XCTAssertNil(restored.revisions[0].preview)
        XCTAssertEqual(restored.revisions[0].parts, expected)
        XCTAssertEqual(restored.revisions[0].partLayout?.nodes, expected)
        XCTAssertEqual(restored.revisions[0].hiddenSolids, [0])
    }

    func testRejectsCorruptedMissingMalformedAndUnreferencedAssets() throws {
        let value = project(attachments: [source("(kicad_pcb (version 20240108))")])
        let json = try archive(value)
        let corruptions: [(inout [String: Any]) throws -> Void] = [
            { json in
                var assets = try XCTUnwrap(json["assets"] as? [String: String])
                let key = try XCTUnwrap(assets.keys.first)
                assets[key] = Data("Changed bytes".utf8).base64EncodedString()
                json["assets"] = assets
            },
            { $0["assets"] = [String: String]() },
            { json in
                try self.updateAttachment(&json) { $0["contentAsset"] = "not-a-digest" }
            },
            { json in
                var assets = try XCTUnwrap(json["assets"] as? [String: String])
                let key = try XCTUnwrap(assets.keys.first)
                assets[key.uppercased()] = assets.removeValue(forKey: key)
                json["assets"] = assets
            },
            { json in
                var assets = try XCTUnwrap(json["assets"] as? [String: String])
                let unused = Data("An unrelated file".utf8)
                assets[self.digest(unused)] = unused.base64EncodedString()
                json["assets"] = assets
            },
            { json in
                try self.updateAttachment(&json) { $0["sha256"] = String(repeating: "0", count: 64) }
            }
        ]
        for (index, corrupt) in corruptions.enumerated() {
            XCTAssertThrowsError(try ProjectStore.decode(mutated(json, corrupt)), "Asset corruption \(index) was accepted")
        }
    }

    func testValidIntegrityHashDoesNotPermitInvalidUTF8InSourceOrProgram() throws {
        let bytes = Data([0xFF, 0xFE, 0x80])
        let key = digest(bytes)
        var sourceJSON = try archive(project(attachments: [source("valid source")]))
        sourceJSON["assets"] = [key: bytes.base64EncodedString()]
        try updateAttachment(&sourceJSON) {
            $0["contentAsset"] = key
            $0["sha256"] = key
        }
        XCTAssertThrowsError(try ProjectStore.decode(compressed(sourceJSON)))

        var value = project()
        value.revisions[0].model = program("result = imported_model")
        var programJSON = try archive(value)
        programJSON["assets"] = [key: bytes.base64EncodedString()]
        try updateRevision(&programJSON) { $0["scriptAsset"] = key }
        XCTAssertThrowsError(try ProjectStore.decode(compressed(programJSON)))
    }

    func testRejectsInlineFilePayloadsAndDerivedDisplayFields() throws {
        let value = project(attachments: [source("source text")])
        let json = try archive(value)
        let corruptions: [(inout [String: Any]) throws -> Void] = [
            { json in try self.updateAttachment(&json) { $0["content"] = "inline source" } },
            { json in try self.updateRevision(&json) { $0["preview"] = NSNull() } },
            { json in try self.updateRevision(&json) { $0["stepData"] = self.step.base64EncodedString() } },
            { json in try self.updateRevision(&json) { $0["stepAsset"] = NSNull() } },
            { json in try self.updateRevision(&json) { $0["stepAsset"] = self.digest(self.step) } },
            { json in
                try self.updateRevision(&json) { revision in
                    var model = try XCTUnwrap(revision["model"] as? [String: Any])
                    model["script"] = "result = imported_model"
                    revision["model"] = model
                }
            },
            { json in
                try self.updateRevision(&json) { revision in
                    var model = try XCTUnwrap(revision["model"] as? [String: Any])
                    model["sourceSTEP"] = self.step.base64EncodedString()
                    revision["model"] = model
                }
            }
        ]
        for (index, corrupt) in corruptions.enumerated() {
            XCTAssertThrowsError(try ProjectStore.decode(mutated(json, corrupt)), "Inline payload \(index) was accepted")
        }
    }

    func testReferencedFilesKeepTheirOwnRoleSizeLimits() throws {
        let sourceLimit = String(repeating: "a", count: SourceImport.maximumFileBytes)
        var sourceJSON = try archive(project(attachments: [source(sourceLimit)]))
        XCTAssertNoThrow(try ProjectStore.decode(compressed(sourceJSON)))
        let oversizedSource = Data((sourceLimit + "a").utf8)
        let sourceKey = digest(oversizedSource)
        sourceJSON["assets"] = [sourceKey: oversizedSource.base64EncodedString()]
        try updateAttachment(&sourceJSON) {
            $0["contentAsset"] = sourceKey
            $0["sha256"] = sourceKey
        }
        XCTAssertThrowsError(try ProjectStore.decode(compressed(sourceJSON)))

        var value = project()
        value.revisions[0].model = program(String(repeating: "#", count: 200_000))
        var programJSON = try archive(value)
        XCTAssertNoThrow(try ProjectStore.decode(compressed(programJSON)))
        let oversizedProgram = Data(String(repeating: "#", count: 200_001).utf8)
        let programKey = digest(oversizedProgram)
        programJSON["assets"] = [programKey: oversizedProgram.base64EncodedString()]
        try updateRevision(&programJSON) { $0["scriptAsset"] = programKey }
        XCTAssertThrowsError(try ProjectStore.decode(compressed(programJSON)))
    }

    func testLongHistorySharesImportedDataAndSourceTextWithoutArtificialReferenceQuota() throws {
        let payloadSize = 1_048_576
        var payload = Data("ISO-10303-21;\n".utf8)
        let footer = Data("\nEND-ISO-10303-21;\n".utf8)
        payload.append(Data(repeating: 32, count: payloadSize - payload.count - footer.count))
        payload.append(footer)
        let model = program("result = imported_model", sourceSTEP: payload)
        let attachment = source(String(decoding: payload, as: UTF8.self))
        let referenceCount = 600
        // The same bytes occur in both each revision's imported input and
        // each message's attachment; only their unique payload is stored.
        XCTAssertGreaterThan(2 * referenceCount * payload.count, ProjectStore.maximumFileBytes)
        var value = project()
        value.revisions = (0..<referenceCount).map { _ in ProjectRevision(model: model) }
        value.selectedRevisionID = value.revisions.last?.id
        value.messages = (0..<referenceCount).map { _ in
            ChatMessage(role: "user", content: "Use the same board", attachments: [attachment])
        }
        let compact = try ProjectStore.encode(value)
        XCTAssertLessThan(compact.count, 2_000_000, "Repeated imported data and text occupy one shared asset")
        let json = try manifest(compact)
        XCTAssertEqual((json["assets"] as? [String: String])?.count, 2)
        let restored = try ProjectStore.decode(compact)
        XCTAssertEqual(restored.revisions.count, referenceCount)
        XCTAssertEqual(restored.messages.count, referenceCount)
        XCTAssertTrue(restored.revisions.allSatisfy { $0.model.sourceSTEP == payload && $0.model.script == model.script })
        XCTAssertTrue(restored.messages.allSatisfy { $0.attachments == [attachment] })
        }

    func testArchiveEnvelopeCanContainMaximumGeometryInputAndMetadata() {
        let encodedInputBytes = ((ProjectStore.maximumSTEPBytes + 2) / 3) * 4
        XCTAssertGreaterThanOrEqual(ProjectStore.maximumFileBytes, encodedInputBytes + 1_048_576,
                                    "A supported imported input must fit the base64 manifest with room for its recipe and metadata.")
    }

    private func project(attachments: [SourceAttachment]? = nil) -> LADProject {
        let revision = ProjectRevision(model: .bracket)
        return LADProject(messages: [ChatMessage(role: "user", content: "Build a case for this board", attachments: attachments)],
                          revisions: [revision], selectedRevisionID: revision.id, projectID: UUID())
    }

    private func source(_ content: String, name: String = "board.kicad_pcb", path: String = "/missing/board.kicad_pcb") -> SourceAttachment {
        SourceAttachment(name: name, path: path, content: content, sha256: digest(Data(content.utf8)))
    }

    private func program(_ text: String, sourceSTEP: Data? = nil) -> ModelSpec {
        ModelSpec(title: "Board enclosure", summary: "An enclosure fitted around a PCB.", units: "mm", script: text, sourceSTEP: sourceSTEP, sourceName: "board.kicad_pcb")
    }

    private func preview(parts: [PartNode]?) -> PreviewMesh {
        PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]],
                    triangles: [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]],
                    edges: [[0, 0, 0, 1, 0, 0]], bounds: [0, 0, 0, 1, 1, 1],
                    volume: 1.0 / 6, area: 2.366, solids: 1, faces: 4,
                    buildSeconds: 0.25, threads: 8, stepPath: "/tmp/old-display-cache/model.step",
                    triangleSolids: [0, 0, 0, 0], edgeSolids: [0], parts: parts)
    }

    private func archive(_ project: LADProject) throws -> [String: Any] {
        try manifest(ProjectStore.encode(project))
    }

    private func manifest(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(data)) as? [String: Any])
    }

    private func compressed(_ json: [String: Any]) throws -> Data {
        try ProjectZIP.encode(JSONSerialization.data(withJSONObject: json))
    }

    private func mutated(_ json: [String: Any], _ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        var copy = json
        try mutate(&copy)
        return try compressed(copy)
    }

    private func updateRevision(_ json: inout [String: Any], _ update: (inout [String: Any]) throws -> Void) throws {
        var revisions = try XCTUnwrap(json["revisions"] as? [[String: Any]])
        try update(&revisions[0])
        json["revisions"] = revisions
    }

    private func updateAttachment(_ json: inout [String: Any], _ update: (inout [String: Any]) throws -> Void) throws {
        var messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        var attachments = try XCTUnwrap(messages[0]["attachments"] as? [[String: Any]])
        try update(&attachments[0])
        messages[0]["attachments"] = attachments
        json["messages"] = messages
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
