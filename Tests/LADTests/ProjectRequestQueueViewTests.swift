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

        let commandReturn = try returnKey(modifiers: .command, in: window)
        window.makeFirstResponder(editingComposer)
        XCTAssertTrue(editingComposer.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(state.editingQueuedRequestID, first.id)
        XCTAssertEqual(state.prompt, "Add ventilation slots with a 2 mm margin.")
        XCTAssertEqual(state.queuedRequests, [first, second], "Dispatch is unavailable while editing a queued request.")
        editingComposer.keyDown(with: try returnKey(in: window))
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
    func testComposerReturnQueuesTheDraftAndOptionReturnAddsANewline() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required to check the native composer.") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-composer-keys-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        state.newProject()
        state.isWorking = true // Queue without starting a Codex process or CAD worker.
        state.prompt = "Add vents"
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceView(state: state))
        window.contentView = host
        defer {
            state.cancel()
            window.orderOut(nil); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        window.makeKeyAndOrderFront(nil)
        let editor = try await composer(in: host, showing: "Add vents")
        window.makeFirstResponder(editor)
        editor.setMarkedText("設計", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        window.sendEvent(try returnKey(in: window))
        XCTAssertTrue(state.queuedRequests.isEmpty, "Return must confirm composed text before it can send a request.")
        editor.unmarkText()
        editor.insertText("Add vents", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        window.sendEvent(try returnKey(modifiers: .option, in: window))
        XCTAssertEqual(state.prompt, "Add vents\n", "Native newline insertion must update the composer binding.")
        XCTAssertTrue(state.queuedRequests.isEmpty)

        editor.insertText("with a 2 mm margin", replacementRange: editor.selectedRange())
        _ = try await composer(in: host, showing: "Add vents\nwith a 2 mm margin")
        window.sendEvent(try returnKey(in: window))
        XCTAssertEqual(state.queuedRequests.map(\.content), ["Add vents\nwith a 2 mm margin"])
        _ = try await composer(in: host, showing: "")
        window.sendEvent(try returnKey(in: window))
        XCTAssertEqual(state.queuedRequests.count, 1, "An empty composer must not send another request.")

        state.prompt = "Keep this unsent draft"
        _ = try await composer(in: host, showing: state.prompt)
        window.sendEvent(try returnKey(modifiers: .command, in: window))
        XCTAssertEqual(state.prompt, "Keep this unsent draft")
        XCTAssertEqual(state.queuedRequests.count, 1, "Command-Return must not submit the draft when live dispatch is unavailable.")
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)
        await state.prepareToQuit()
    }

    @MainActor
    func testCommandReturnDispatchesTheFirstQueuedRequestAfterReorderingAndKeepsTheDraft() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required to check the native composer.") }
        _ = NSApplication.shared
        let codex = try FakeCodex(responseJSON: #"{"status":"message","message":"Ready for more information.","assetIDs":[],"model":null}"#,
                                  delay: 10)
        let oldCodex = UserDefaults.standard.object(forKey: "codexPath")
        UserDefaults.standard.set(codex.executable.path, forKey: "codexPath")
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: codex.directory))
        state.newProject()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceView(state: state))
        window.contentView = host
        defer {
            state.cancel()
            window.orderOut(nil); window.contentView = nil; window.close()
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            codex.remove()
        }
        window.makeKeyAndOrderFront(nil)
        let editor = try await composer(in: host, showing: "")
        window.makeFirstResponder(editor)
        let commandReturn = try returnKey(modifiers: .command, in: window)
        if !window.performKeyEquivalent(with: commandReturn) { window.sendEvent(commandReturn) }
        XCTAssertTrue(state.messages.isEmpty, "Command-Return with an empty queue and empty composer must do nothing.")
        XCTAssertTrue(state.taskAudits.isEmpty)

        state.prompt = "Explain the available design controls"
        _ = try await composer(in: host, showing: state.prompt)
        window.makeFirstResponder(editor)
        if !window.performKeyEquivalent(with: commandReturn) { window.sendEvent(commandReturn) }
        XCTAssertTrue(state.prompt.isEmpty)
        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content), ["Explain the available design controls"],
                       "Command-Return must submit the composer when no request is queued.")
        let readyDeadline = ContinuousClock.now + .seconds(10)
        while !state.canSteerQueuedRequests, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.canSteerQueuedRequests, state.error ?? "The mock Codex turn did not become available.")
        guard state.canSteerQueuedRequests else { return }
        state.prompt = "Describe navigation"
        _ = try await composer(in: host, showing: state.prompt)
        window.makeFirstResponder(editor)
        window.sendEvent(commandReturn)
        XCTAssertEqual(state.queuedRequests.map(\.content), ["Describe navigation"],
                       "With an empty queue during a running task, Command-Return queues the draft just like Return.")
        XCTAssertTrue(state.prompt.isEmpty)
        state.prompt = "Describe selections"; state.submit()
        let next = try XCTUnwrap(state.queuedRequests.last)
        let later = try XCTUnwrap(state.queuedRequests.first)
        state.moveQueuedRequest(id: next.id, beforeID: later.id)
        state.prompt = "Keep this unsent draft"
        _ = try await composer(in: host, showing: state.prompt)
        window.makeFirstResponder(editor)
        if !window.performKeyEquivalent(with: commandReturn) { window.sendEvent(commandReturn) }
        let sentDeadline = ContinuousClock.now + .seconds(5)
        while state.queuedRequests.contains(where: { $0.id == next.id }), ContinuousClock.now < sentDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.queuedRequests.map(\.id), [later.id])
        XCTAssertEqual(state.prompt, "Keep this unsent draft")
        XCTAssertEqual(state.messages.filter { $0.role == "user" }.map(\.content),
                       ["Explain the available design controls", "Describe selections"])
        XCTAssertEqual(state.taskAudits.count, 1, "Dispatch must steer the existing task rather than start another one.")
        XCTAssertEqual(try codex.rpcRequests().filter { $0["method"] as? String == "turn/steer" }.count, 1)
        state.cancel()
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
    private func returnKey(modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
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
