import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import LAD

final class ProjectRequestQueueViewTests: XCTestCase {
    @MainActor
    func testQueuedEditingUsesTheSingleMainComposerAndRestoresItsDraft() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required to check the native composer.") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-queue-composer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let oldCodex = UserDefaults.standard.object(forKey: "codexPath")
        UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
        let first = ProjectQueuedRequest(content: "Add ventilation slots to the lid", codexSettings:
            CodexProjectSettings(model: "queued-fixture-model", reasoningEffort: "high"))
        let second = ProjectQueuedRequest(content: "Round the enclosure corners")
        var project = LADProject(messages: [], revisions: [], selectedRevisionID: nil,
                                 projectID: UUID(), codexSettings: CodexProjectSettings(model: "draft-fixture-model", reasoningEffort: "low"),
                                 projectName: "Queued composer check")
        project.queuedRequests = [first, second]
        project.draftPrompt = "Keep this unsent request while I edit the queue."
        project.queuePaused = true
        let projectURL = directory.appendingPathComponent("Queued composer check.lad")
        try ProjectStore.write(project, to: projectURL)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.loadProject(project, from: projectURL)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LAD queued composer integration check"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceView(state: state))
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer {
            state.cancel()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            try? FileManager.default.removeItem(at: directory)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = try await composer(in: host, showing: project.draftPrompt!)

        state.beginEditingQueuedRequest(id: first.id)
        let editingComposer = try await composer(in: host, showing: first.content)
        if window.isKeyWindow {
            let deadline = ContinuousClock.now + .seconds(3)
            while window.firstResponder !== editingComposer, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(window.firstResponder === editingComposer,
                          "Edit should focus the ordinary request editor rather than adding a queue-row editor.")
        }
        state.prompt = "Add ventilation slots with a 2 mm margin."
        _ = try await composer(in: host, showing: state.prompt)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/lad-queue-main-composer-edit.png"))

        state.submit()
        _ = try await composer(in: host, showing: project.draftPrompt!)
        XCTAssertEqual(state.queuedRequests.first?.content, "Add ventilation slots with a 2 mm margin.")
        XCTAssertNil(state.editingQueuedRequestID)
        state.beginEditingQueuedRequest(id: second.id)
        _ = try await composer(in: host, showing: second.content)
        state.prompt = "This edit will be canceled."
        _ = try await composer(in: host, showing: state.prompt)
        state.cancelEditingQueuedRequest()
        _ = try await composer(in: host, showing: project.draftPrompt!)
        XCTAssertEqual(state.queuedRequests.last, second)
        XCTAssertTrue(state.taskAudits.isEmpty)
        XCTAssertTrue(state.messages.isEmpty, "Editing must never launch or submit a Codex request.")
        await state.prepareToQuit()
    }

    @MainActor
    func testQueueHandlePayloadStaysPrivateAndRoundTripsOnlyToItsProject() async throws {
        let project = UUID(), request = UUID()
        let provider = ProjectRequestQueueDrag.provider(projectSessionID: project, requestID: request)
        XCTAssertEqual(provider.registeredTypeIdentifiers, [ProjectRequestQueueDrag.type.identifier])
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                       "Queue reorder payloads must not enter LAD file-open or path-drop handling.")
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                       "Dragging the handle must not insert a UUID into the chat editor or part tree.")
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: ProjectRequestQueueDrag.type.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: LADError.message("The queue handle did not provide its item identity.")) }
            }
        }
        XCTAssertEqual(ProjectRequestQueueDrag.requestID(from: data, projectSessionID: project), request)
        XCTAssertNil(ProjectRequestQueueDrag.requestID(from: data, projectSessionID: UUID()),
                     "A drop from another design or a previously loaded design must not reorder this queue.")
    }

    func testQueueDropRejectsFilePathsAndMalformedOrOversizedIdentities() throws {
        let project = UUID()
        XCTAssertNil(ProjectRequestQueueDrag.requestID(from: Data("/Users/example/design.lad".utf8), projectSessionID: project))
        XCTAssertNil(ProjectRequestQueueDrag.requestID(from: Data("file:///Users/example/design.lad".utf8), projectSessionID: project))
        XCTAssertNil(ProjectRequestQueueDrag.requestID(from: Data("{\"projectSessionID\":\"bad\",\"requestID\":\"bad\"}".utf8), projectSessionID: project))
        let missingRequest = try JSONSerialization.data(withJSONObject: ["projectSessionID": project.uuidString])
        XCTAssertNil(ProjectRequestQueueDrag.requestID(from: missingRequest, projectSessionID: project))
        XCTAssertNil(ProjectRequestQueueDrag.requestID(from: Data(repeating: 32, count: 1_025), projectSessionID: project))
    }

    @MainActor
    private func composer(in host: NSView, showing text: String) async throws -> NSTextView {
        func editors(_ view: NSView) -> [NSTextView] {
            let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(editors)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            let views = editors(host)
            if views.count == 1, views[0].string == text { return views[0] }
            try await Task.sleep(for: .milliseconds(10))
        }
        let views = editors(host)
        XCTAssertEqual(views.count, 1, "Queued edits must use the one ordinary request text box.")
        let result = try XCTUnwrap(views.first)
        XCTAssertEqual(result.string, text)
        return result
    }
}
