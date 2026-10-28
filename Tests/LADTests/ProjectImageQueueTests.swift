import AppKit
import XCTest
@testable import LAD

final class ProjectImageQueueTests: XCTestCase {
    @MainActor
    func testQueuedImageEditPreservesSuspendedDraftAndPortableImages() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.isWorking = true
        let first = try fixture.image("First.png", color: .systemBlue)
        let second = try fixture.image("Second.png", color: .systemPink)
        let draft = try fixture.image("Draft.png", color: .systemGreen)
        XCTAssertNotEqual(first.sha256, second.sha256, "The queued references must contain two distinct image payloads.")
        state.prompt = "Use both views of this enclosure"
        state.pendingAttachments = [first, second]
        state.submit()
        let queued = try XCTUnwrap(state.queuedRequests.first)
        XCTAssertEqual(queued.attachments, [first, second])

        state.prompt = "Keep this unsent reference"
        state.pendingAttachments = [draft]
        state.beginEditingQueuedRequest(id: queued.id)
        XCTAssertEqual(state.pendingAttachments, [first, second])
        state.removeAttachment(id: first.id)
        state.prompt = "Use only the second view"
        XCTAssertTrue(state.commitEditingQueuedRequest())
        XCTAssertEqual(state.queuedRequests.first?.attachments, [second])
        XCTAssertEqual(state.pendingAttachments, [draft])
        XCTAssertEqual(state.prompt, "Keep this unsent reference")

        state.beginEditingQueuedRequest(id: queued.id)
        state.pendingAttachments = [first]
        state.cancelEditingQueuedRequest()
        XCTAssertEqual(state.queuedRequests.first?.attachments, [second])
        XCTAssertEqual(state.pendingAttachments, [draft])
        XCTAssertTrue(state.isWorking, "Editing image references must leave the active design request alone.")
        XCTAssertTrue(state.messages.isEmpty)
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        let reopened = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: fixture.directory))
        reopened.loadProject(saved, from: try XCTUnwrap(state.projectURL))
        XCTAssertEqual(reopened.pendingAttachments, [draft])
        XCTAssertEqual(reopened.queuedRequests.first?.attachments, [second])
        XCTAssertEqual(reopened.pendingAttachments[0].imageData, draft.imageData)
        XCTAssertTrue(reopened.queuePaused)
        await reopened.prepareToQuit()
    }

    @MainActor
    func testImagesCanBeAttachedAndQueuedDuringGenerationWithoutInterruptingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.isWorking = true
        let image = try fixture.image("Reference.png", color: .systemOrange)
        let file = fixture.directory.appendingPathComponent("Reference.png")
        try image.data.write(to: file)
        state.attachSourceFiles(urls: [file])
        state.submit()
        XCTAssertTrue(state.queuedRequests.isEmpty, "Submitting while attachment capture is pending must not lose the image.")
        let deadline = ContinuousClock.now + .seconds(5)
        while state.pendingAttachments.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.pendingAttachments.count, 1)
        XCTAssertTrue(state.pendingAttachments.first?.isImage == true)
        XCTAssertTrue(state.isWorking)
        XCTAssertTrue(state.messages.isEmpty)
        state.submit() // An image-only prompt is valid and queues behind the existing request.
        let queued = try XCTUnwrap(state.queuedRequests.first)
        XCTAssertTrue(queued.content.isEmpty)
        XCTAssertEqual(queued.attachments?.first?.imageData, image.imageData)
        XCTAssertTrue(state.pendingAttachments.isEmpty)
        XCTAssertTrue(state.isWorking)
        try FileManager.default.removeItem(at: file)
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.queuedRequests?.first?.attachments?.first?.imageData, image.imageData,
                       "The queued image must remain portable after its original file is removed.")
        XCTAssertEqual(saved.queuePaused, true)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let state: AppState
        private let originalCodex: Any?

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-image-queue-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            originalCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.newProject()
        }

        func image(_ name: String, color: NSColor) throws -> SourceAttachment {
            let data = try ImageAttachmentTestImage.png(color, width: 8, height: 6)
            return try SourceImport.imageAttachment(data: data, name: name)
        }

        func cleanUp() {
            state.cancel()
            if let originalCodex { UserDefaults.standard.set(originalCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
