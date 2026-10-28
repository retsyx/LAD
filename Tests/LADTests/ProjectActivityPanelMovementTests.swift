import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class ProjectActivityPanelMovementTests: XCTestCase {
    @MainActor
    func testMovingPanelRetainsRequestedFramesWhileLogAndRenderContentChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let panel = fixture.panel
        let ownerFrame = fixture.owner.frame
        let initialSize = panel.frame.size
        let minimum = panel.contentMinSize
        let maximum = panel.contentMaxSize
        let recorder = FrameRecorder()
        let center = NotificationCenter.default
        let moved = center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated { if let panel { recorder.moves.append(panel.frame) } }
        }
        let resized = center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated { if let panel { recorder.resizes.append(panel.frame) } }
        }
        defer { center.removeObserver(moved); center.removeObserver(resized) }
        let visible = try XCTUnwrap(fixture.owner.screen ?? NSScreen.main).visibleFrame
        let start = NSPoint(x: visible.minX + 24, y: visible.minY + 24)
        let offsets: [NSPoint] = [NSPoint(x: 0, y: 0), NSPoint(x: 20, y: 12), NSPoint(x: 42, y: 24),
                                  NSPoint(x: 66, y: 36), NSPoint(x: 44, y: 24), NSPoint(x: 22, y: 12)]
        let wide = try ImageAttachmentTestImage.png(.systemBlue, width: 640, height: 180)
        let tall = try ImageAttachmentTestImage.png(.systemOrange, width: 240, height: 480)

        // Tool result/cache arrivals and changing request text update the real
        // activity host during consecutive native moves. Expanded image drawing
        // is verified separately by ProjectActivityImageViewTests; it does not
        // depend on accessibility publication in this movement fixture.
        fixture.state.activityImages.store(wide,
            for: ProjectActivityImageKey(taskID: fixture.task.id, eventID: fixture.render.id))
        try await fixture.settle()

        for (index, offset) in offsets.enumerated() {
            let requested = NSRect(origin: NSPoint(x: start.x + offset.x, y: start.y + offset.y), size: initialSize)
            panel.setFrameOrigin(requested.origin)
            fixture.state.messages[0].content = index.isMultiple(of: 2)
                ? "Review the rendered view"
                : String(repeating: "Review the selected geometry and retain every existing detail. ", count: 60)
            fixture.state.activityImages.store(index.isMultiple(of: 2) ? wide : tall,
                for: ProjectActivityImageKey(taskID: fixture.task.id, eventID: fixture.render.id))
            try await fixture.settle()
            assertRect(panel.frame, equals: requested)
            assertRect(fixture.owner.frame, equals: ownerFrame)
            XCTAssertEqual(panel.contentMinSize, minimum)
            XCTAssertEqual(panel.contentMaxSize, maximum)
            XCTAssertNil(panel.parent, "A freely movable activity panel must not participate in native child-window tracking.")
            XCTAssertTrue((fixture.owner.childWindows ?? []).isEmpty)
        }
        XCTAssertFalse(recorder.moves.isEmpty, "The test must exercise native window movement.")
        XCTAssertTrue(recorder.resizes.isEmpty, "Log measurements and image-result arrivals must not resize a window while it is being moved.")
        XCTAssertTrue(recorder.moves.allSatisfy { $0.size == initialSize })
        XCTAssertEqual(minimum, NSSize(width: 480, height: 320))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertNil(NSApplication.shared.modalWindow)
        XCTAssertFalse(fixture.state.isWorking, "Displaying and moving activity must not start agent or CAD work.")
        await fixture.state.prepareToQuit()
    }

    @MainActor
    func testMovingAndResizingOwnerLeavesIndependentActivityFrameUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let panel = fixture.panel
        let visible = try XCTUnwrap(fixture.owner.screen ?? NSScreen.main).visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.minY + 40))
        try await fixture.settle()
        let activityFrame = panel.frame
        let ownerFrame = fixture.owner.frame

        for offset in [NSPoint(x: 26, y: 14), NSPoint(x: 50, y: 28), NSPoint(x: 12, y: 8)] {
            fixture.owner.setFrameOrigin(NSPoint(x: ownerFrame.minX + offset.x, y: ownerFrame.minY + offset.y))
            fixture.state.messages[0].content = "Inspect the independently positioned activity window at \(offset.x)."
            try await fixture.settle()
            assertRect(panel.frame, equals: activityFrame)
            XCTAssertNil(panel.parent)
            XCTAssertTrue((fixture.owner.childWindows ?? []).isEmpty)
        }

        fixture.owner.setContentSize(NSSize(width: 780, height: 610))
        try await fixture.settle()
        assertRect(panel.frame, equals: activityFrame)
        XCTAssertTrue(fixture.controller.isVisible)
        XCTAssertTrue(panel.isVisible)
        await fixture.state.prepareToQuit()
    }

    @MainActor
    func testOwnerMinimizeRestoresOnlyAnExplicitlyOpenActivityPanel() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let panel = fixture.panel
        try await fixture.settle()
        let content = try XCTUnwrap(panel.contentView)
        let activityFrame = panel.frame
        XCTAssertTrue(fixture.controller.isVisible)
        XCTAssertTrue(panel.isVisible)

        fixture.owner.miniaturize(nil)
        try await waitUntil { fixture.owner.isMiniaturized && !panel.isVisible }
        XCTAssertTrue(fixture.controller.isVisible, "Minimizing temporarily orders out an explicitly open pane.")
        XCTAssertTrue(panel.contentView === content, "Minimizing must retain the current tool-result disclosures and previews.")
        assertRect(panel.frame, equals: activityFrame)

        fixture.owner.deminiaturize(nil)
        try await waitUntil { !fixture.owner.isMiniaturized && panel.isVisible }
        XCTAssertTrue(fixture.controller.isVisible)
        XCTAssertTrue(panel.contentView === content)
        assertRect(panel.frame, equals: activityFrame)

        fixture.owner.miniaturize(nil)
        try await waitUntil { fixture.owner.isMiniaturized && !panel.isVisible }
        fixture.controller.hide()
        XCTAssertFalse(fixture.controller.isVisible)
        XCTAssertNil(panel.contentView)
        fixture.owner.deminiaturize(nil)
        try await waitUntil { !fixture.owner.isMiniaturized }
        try await fixture.settle()
        XCTAssertFalse(panel.isVisible, "Restoring the owner must not reopen an explicitly hidden activity pane.")
        XCTAssertFalse(fixture.controller.isVisible)
        XCTAssertNil(panel.parent)
        XCTAssertTrue((fixture.owner.childWindows ?? []).isEmpty)
        await fixture.state.prepareToQuit()
    }

    @MainActor
    func testNativeUserResizeAndSizeConstraintsSurviveSubsequentContentMeasurement() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let panel = fixture.panel
        try await fixture.settle()
        // AppKit, rather than SwiftUI's ideal content size, owns the resizable
        // panel's limits. Deliberately exercise nondefault native limits too.
        let minimum = NSSize(width: 530, height: 350)
        let maximum = NSSize(width: 980, height: 740)
        panel.contentMinSize = minimum
        panel.contentMaxSize = maximum
        let visible = try XCTUnwrap(fixture.owner.screen ?? NSScreen.main).visibleFrame
        let origin = NSPoint(x: visible.minX + 30, y: visible.minY + 30)
        let requested = panel.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 610, height: 420)))
        let frame = NSRect(origin: origin, size: requested.size)
        panel.setFrame(frame, display: true)
        try await fixture.settle()
        assertRect(panel.frame, equals: frame)

        for index in 0..<4 {
            fixture.state.messages[0].content = String(repeating: "Updated audit request ", count: (index + 1) * 35)
            fixture.state.activityImages.store(try ImageAttachmentTestImage.png(index.isMultiple(of: 2) ? .red : .green,
                width: index.isMultiple(of: 2) ? 600 : 200, height: index.isMultiple(of: 2) ? 160 : 400),
                for: ProjectActivityImageKey(taskID: fixture.task.id, eventID: fixture.render.id))
            try await fixture.settle()
            XCTAssertEqual(panel.contentMinSize, minimum, "SwiftUI content must not overwrite native minimum size.")
            XCTAssertEqual(panel.contentMaxSize, maximum, "SwiftUI content must not overwrite native maximum size.")
            assertRect(panel.frame, equals: frame)
            let content = try XCTUnwrap(panel.contentView)
            XCTAssertEqual(content.frame.size.width, panel.contentLayoutRect.width, accuracy: 0.5)
            XCTAssertEqual(content.frame.size.height, panel.contentLayoutRect.height, accuracy: 0.5)
        }
        fixture.owner.close()
        XCTAssertFalse(fixture.controller.isVisible)
        XCTAssertFalse(fixture.controller.hasPanel)
        await fixture.state.prepareToQuit()
    }

    private func assertRect(_ actual: NSRect, equals expected: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.size.width, expected.size.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.size.height, expected.size.height, accuracy: 0.5, file: file, line: line)
    }

    @MainActor
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(condition(), "Expected the native window lifecycle transition to finish.", file: file, line: line)
    }

    @MainActor
    private final class FrameRecorder {
        var moves: [NSRect] = []
        var resizes: [NSRect] = []
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let state: AppState
        let owner: NSWindow
        let controller: ProjectActivityPanelController
        let panel: NSPanel
        let task: ProjectTaskAudit
        let render: ProjectActivityEvent

        init() throws {
            _ = NSApplication.shared
            guard let screen = NSScreen.main, screen.visibleFrame.width >= 850, screen.visibleFrame.height >= 700 else {
                throw XCTSkip("A window server with space for a movable activity panel is required.")
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-activity-move-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let loadedState = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: folder.appendingPathComponent("Autosave")))
            let user = ChatMessage(role: "user", content: "Review the rendered view")
            let renderEvent = ProjectActivityEvent(id: "project:tool:render", category: "tool", title: "lad_render", status: "completed",
                output: "{\"content\":[{\"type\":\"image_path\",\"path\":\"/temporary/render.png\"}]}")
            let commands = (0..<24).map { index in
                ProjectActivityEvent(id: "command:\(index)", category: "command", title: "Inspect geometry \(index)", status: "completed",
                    input: "python inspect.py --part \(index)", output: String(repeating: "Validated native geometry output.\n", count: 50))
            }
            let audit = ProjectTaskAudit(userMessageID: user.id, startedAt: Date().addingTimeInterval(-60), finishedAt: Date(), model: "test-model", reasoningEffort: "high",
                status: "completed", events: commands + [renderEvent])
            let project = LADProject(messages: [user], revisions: [], selectedRevisionID: nil, taskAudits: [audit])
            let source = folder.appendingPathComponent("Movement.lad")
            try ProjectStore.write(project, to: source)
            loadedState.loadProject(project, from: source)
            let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.minY + 10,
                width: 820, height: 650), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 650))
            window.makeKeyAndOrderFront(nil)
            let activityController = ProjectActivityPanelController()
            activityController.toggle(state: loadedState, owner: window)
            let activityPanel = try XCTUnwrap(activityController.panel)
            directory = folder; state = loadedState; owner = window
            controller = activityController; panel = activityPanel
            task = audit; render = renderEvent
        }

        func settle() async throws {
            for _ in 0..<3 {
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
        }

        func close() {
            controller.close()
            owner.close()
            state.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
