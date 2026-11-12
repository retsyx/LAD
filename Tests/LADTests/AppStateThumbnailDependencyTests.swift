import AppKit
import Combine
import XCTest
@testable import LAD

final class AppStateThumbnailDependencyTests: XCTestCase {
    @MainActor
    func testLoadedThumbnailAndUnrelatedSavesDoNotResolveColorsScheduleOrRender() async throws {
        let fixture = try Fixture(savedImage: true)
        defer { fixture.cleanUp() }
        try await waitForSave(fixture.state)
        let state = fixture.state
        XCTAssertEqual(fixture.probe.inputs.count, 0)
        XCTAssertEqual(state.projectThumbnailWork.renders, 0)
        XCTAssertEqual(state.projectThumbnailWork.scheduledRenders, 0)
        XCTAssertEqual(try ProjectStore.read(from: fixture.url).thumbnailData, fixture.probe.firstPNG)
        let work = state.projectThumbnailWork
        var publishedURLs = [URL?]()
        let observation = ObservationRecorder({ state.projectURL }) { publishedURLs.append($0) }

        state.prompt = "A draft"
        state.showGrid.toggle()
        try await waitForSave(state)
        state.messages.append(ChatMessage(role: "assistant", content: "An unrelated transcript update", phase: "commentary"))
        state.saveProject()
        try await waitForSave(state)
        try state.renameRevision(id: fixture.firstID, to: "Named version")
        state.setPartFolderExpanded("folder", isExpanded: false)
        state.renamePartNode("body", to: "Renamed body")
        state.revisions[0].model.title = "A presentation title"
        state.revisions[0].model.summary = "A presentation summary"
        state.revisions[0].model.sourceName = "Only provenance.step"
        state.saveProject()
        try await waitForSave(state)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(state.projectThumbnailWork.inputResolutions, work.inputResolutions)
        XCTAssertEqual(state.projectThumbnailWork.scheduledRenders, work.scheduledRenders)
        XCTAssertEqual(state.projectThumbnailWork.renders, work.renders)
        XCTAssertTrue(publishedURLs.isEmpty, "An unchanged save URL must not invalidate the workspace")
        XCTAssertEqual(try ProjectStore.read(from: fixture.url).thumbnailData, fixture.probe.firstPNG)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testPresentationAndRecipeChangesInvalidateOnlyTheirMatchingImage() async throws {
        let fixture = try Fixture(savedImage: true)
        defer { fixture.cleanUp() }
        let state = fixture.state
        try await waitForSave(state)
        state.displayMode = .shaded
        try await waitForRender(1, fixture: fixture)
        state.projectionMode = .perspective
        try await waitForRender(2, fixture: fixture)
        state.togglePartVisibility([0])
        try await waitForRender(3, fixture: fixture)
        state.setPartColor(PartColor(red: 1, green: 0, blue: 0), for: "body")
        try await waitForRender(4, fixture: fixture)
        state.selectRevision(fixture.secondID)
        try await waitForRender(5, fixture: fixture)
        XCTAssertEqual(fixture.probe.inputs[4].revisionID, fixture.secondID)

        // A changed recipe must not render the previous mesh while its replay
        // is pending, even if a caller retained the old validation receipt.
        state.revisions[1].model.script = "result = cq.Solid.makeBox(2, 3, 4)"
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fixture.probe.inputs.count, 5)
        var replacement = fixture.preview
        replacement.stepPath += "-replacement"
        replacement.validatedHash = String(repeating: "b", count: 64)
        state.revisions[1].validatedHash = replacement.validatedHash
        state.revisions[1].preview = replacement
        state.mesh = replacement
        try await waitForRender(6, fixture: fixture)
        XCTAssertEqual(fixture.probe.inputs[5].validationHash, replacement.validatedHash)
        XCTAssertEqual(fixture.probe.inputs[5].geometryPath, replacement.stepPath)
    }

    @MainActor
    func testMatchingReplayReusesImageAcrossArtifactPathsButNewReceiptRenders() async throws {
        let fixture = try Fixture(savedImage: true)
        defer { fixture.cleanUp() }
        let state = fixture.state
        try await waitForSave(state)
        let before = try ProjectStore.readArchive(from: fixture.url)
        var replay = fixture.preview
        replay.stepPath += "-new-session"
        replay.brepPath = "/tmp/new-session/model.brep"
        state.mesh = replay
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(fixture.probe.inputs.count, 0)
        XCTAssertEqual(state.projectThumbnailWork.scheduledRenders, 0)
        XCTAssertGreaterThan(state.projectThumbnailWork.reusedImages, 0)
        XCTAssertEqual(try ProjectStore.readArchive(from: fixture.url), before)

        replay.validatedHash = String(repeating: "c", count: 64)
        state.revisions[0].validatedHash = replay.validatedHash
        state.revisions[0].preview = replay
        state.mesh = replay
        try await waitForRender(1, fixture: fixture)
        XCTAssertEqual(fixture.probe.inputs[0].validationHash, replay.validatedHash)
    }

    @MainActor
    func testEditingUnrenderedOtherVersionPreservesUnchangedImageButEditingItsOwnerDoesNot() async throws {
        let fixture = try Fixture(savedImage: true)
        defer { fixture.cleanUp() }
        let state = fixture.state
        try await waitForSave(state)
        state.selectRevision(fixture.secondID)
        state.setPartColor(PartColor(red: 1, green: 0, blue: 0), for: "body")
        state.selectRevision(fixture.firstID)
        try await waitForSave(state)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(fixture.probe.inputs.count, 0)
        XCTAssertEqual(state.projectThumbnailWork.renders, 0)
        let restored = try ProjectStore.read(from: fixture.url)
        XCTAssertEqual(restored.selectedRevisionID, fixture.firstID)
        XCTAssertEqual(restored.thumbnailData, fixture.probe.firstPNG)

        // In contrast, changing that retained image's own version while it is
        // inactive must clear it before navigation returns to the version.
        state.selectRevision(fixture.secondID)
        let green = PartColor(red: 0, green: 1, blue: 0)
        state.revisions[0].partColors = ["body": green]
        state.selectRevision(fixture.firstID)
        try await waitForRender(1, fixture: fixture)
        XCTAssertEqual(fixture.probe.inputs[0].revisionID, fixture.firstID)
        XCTAssertEqual(fixture.probe.inputs[0].solidColors[0], green)
    }

    @MainActor
    func testSourceBytesInvalidateImageWhileInputNamesDoNot() async throws {
        let fixture = try Fixture(savedImage: true)
        defer { fixture.cleanUp() }
        let state = fixture.state
        try await waitForSave(state)
        // These schema fixtures are never sent to the native engine. The
        // injected preview/renderer isolate thumbnail dependency decisions.
        let firstSTEP = Data(("ISO-10303-21;\n/*" + String(repeating: "a", count: 100) + "*/\nEND-ISO-10303-21;\n").utf8)
        let secondSTEP = Data(("ISO-10303-21;\n/*" + String(repeating: "b", count: 100) + "*/\nEND-ISO-10303-21;\n").utf8)
        @MainActor func replacePreview(_ marker: Character) {
            var preview = fixture.preview
            preview.stepPath += "-\(marker)"
            preview.validatedHash = String(repeating: String(marker), count: 64)
            state.revisions[0].validatedHash = preview.validatedHash
            state.revisions[0].preview = preview
            state.mesh = preview
        }
        @MainActor func assertWaitingForReplay(_ renders: Int) async throws {
            state.saveProject()
            try await waitForSave(state)
            XCTAssertNil(try ProjectStore.read(from: fixture.url).thumbnailData)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(fixture.probe.inputs.count, renders, "Old geometry must not be rendered for changed original bytes")
        }

        state.revisions[0].model.inputAssets = [CADInputAsset(id: "reference", name: "source.step", format: "step", data: firstSTEP)]
        try await assertWaitingForReplay(0)
        replacePreview("d")
        try await waitForRender(1, fixture: fixture)
        let work = state.projectThumbnailWork
        state.revisions[0].model.inputAssets![0].name = "A provenance-only filename.step"
        state.saveProject()
        try await waitForSave(state)
        XCTAssertEqual(state.projectThumbnailWork.inputResolutions, work.inputResolutions)
        XCTAssertEqual(state.projectThumbnailWork.scheduledRenders, work.scheduledRenders)
        XCTAssertEqual(state.projectThumbnailWork.renders, work.renders)

        state.revisions[0].model.inputAssets![0].data = secondSTEP
        try await assertWaitingForReplay(1)
        replacePreview("e")
        try await waitForRender(2, fixture: fixture)
        state.revisions[0].model.sourceSTEP = firstSTEP
        try await assertWaitingForReplay(2)
        replacePreview("f")
        try await waitForRender(3, fixture: fixture)
        state.revisions[0].model.sourceSTEP = secondSTEP
        try await assertWaitingForReplay(3)
        replacePreview("a")
        try await waitForRender(4, fixture: fixture)
    }

    @MainActor
    func testCanceledRenderCannotReplaceNewPresentationOrReplacementProject() async throws {
        let fixture = try Fixture(savedImage: false, blockFirst: true)
        defer { fixture.probe.releaseFirst(); fixture.cleanUp() }
        let state = fixture.state
        try await waitUntil { fixture.probe.inputs.count == 1 }
        state.displayMode = .wireframe
        try await waitForRender(2, fixture: fixture)
        XCTAssertEqual(try ProjectStore.read(from: fixture.url).thumbnailData, fixture.probe.secondPNG)
        fixture.probe.releaseFirst()
        try await Task.sleep(for: .milliseconds(100))
        try await waitForSave(state)
        XCTAssertEqual(try ProjectStore.read(from: fixture.url).thumbnailData, fixture.probe.secondPNG)

        // A pending capture belongs to its originating project session.
        fixture.probe.blockNext = true
        state.displayMode = .translucent
        try await waitUntil { fixture.probe.inputs.count == 3 }
        state.newProjectWithSubmittedRequest()
        fixture.probe.releaseFirst()
        try await waitForSave(state)
        let newURL = try XCTUnwrap(state.projectURL)
        XCTAssertNotEqual(newURL, fixture.url)
        XCTAssertNil(try ProjectStore.read(from: newURL).thumbnailData)
        XCTAssertTrue(state.revisions.isEmpty)
    }

    @MainActor
    private func waitForRender(_ count: Int, fixture: Fixture) async throws {
        try await waitUntil { fixture.probe.inputs.count >= count }
        try await waitForSave(fixture.state)
    }

    @MainActor
    private func waitForSave(_ state: AppState) async throws {
        try await waitUntil {
            if let conflict = state.saveConflict { throw conflict }
            if let status = state.saveStatus, status != "Saving…" { throw LADError.message(status) }
            return !state.hasUnsavedChanges && state.saveStatus == nil
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while try !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for thumbnail/save work")
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class Probe {
        let firstPNG: Data
        let secondPNG: Data
        var inputs = [ProjectThumbnail.Input]()
        var blockNext: Bool
        private var continuation: CheckedContinuation<Void, Never>?

        init(blockFirst: Bool) throws {
            firstPNG = try Self.png(red: 0.2)
            secondPNG = try Self.png(red: 0.8)
            blockNext = blockFirst
        }

        func render(_ preview: PreviewMesh, _ input: ProjectThumbnail.Input) async throws -> Data {
            inputs.append(input)
            let first = inputs.count == 1
            if blockNext {
                blockNext = false
                await withCheckedContinuation { continuation = $0 }
            }
            return first ? firstPNG : secondPNG
        }

        func releaseFirst() {
            continuation?.resume(); continuation = nil
        }

        private static func png(red: CGFloat) throws -> Data {
            let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            for y in 0..<2 { for x in 0..<2 { image.setColor(NSColor(deviceRed: red, green: 0.3, blue: 0.5, alpha: 1), atX: x, y: y) } }
            return try XCTUnwrap(image.representation(using: .png, properties: [:]))
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let url: URL
        let state: AppState
        let probe: Probe
        let preview: PreviewMesh
        let firstID: UUID
        let secondID: UUID

        init(savedImage: Bool, blockFirst: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-thumbnail-dependencies-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            url = directory.appendingPathComponent("Fixture.lad", isDirectory: true)
            probe = try Probe(blockFirst: blockFirst)
            let nodes = [PartNode(id: "folder", name: "Folder", solidIndices: [], children: [
                PartNode(id: "body", name: "Body", solidIndices: [0])
            ])]
            preview = PreviewMesh(vertices: [[0,0,0],[1,0,0],[0,1,0],[0,0,1]],
                triangles: [[0,2,1],[0,1,3],[0,3,2],[1,2,3]], edges: [], bounds: [0,0,0,1,1,1],
                volume: 1.0 / 6, area: 2.366, solids: 1, faces: 4, buildSeconds: 0, threads: 1,
                stepPath: "/tmp/thumbnail-dependency/model.step", parts: nodes, validatedHash: String(repeating: "a", count: 64))
            let spec = ModelSpec(title: "Fixture", summary: "Synthetic validated preview", units: "mm", script: "result = cq.Solid.makeBox(1, 1, 1)")
            let first = ProjectRevision(model: spec, parts: nodes, validatedHash: preview.validatedHash)
            let second = ProjectRevision(model: spec, parts: nodes, validatedHash: preview.validatedHash)
            firstID = first.id; secondID = second.id
            var project = LADProject(messages: [], revisions: [first, second], selectedRevisionID: first.id,
                projectID: UUID(), projectionMode: .isometric)
            try ProjectStore.write(project, to: url, thumbnail: savedImage ? probe.firstPNG : nil)
            project = try ProjectStore.read(from: url)
            project.revisions[0].preview = preview
            var secondPreview = preview
            secondPreview.stepPath += "-second"
            project.revisions[1].preview = secondPreview
            let renderer = probe
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory),
                thumbnailRenderer: { try await renderer.render($0, $1) })
            state.loadProject(project, from: url)
        }

        func cleanUp() {
            probe.releaseFirst()
            state.newProject()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
