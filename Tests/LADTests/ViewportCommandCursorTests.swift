import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportCommandCursorTests: XCTestCase {
    @MainActor
    func testStationaryCommandPressImmediatelyClearsHoverAndDrawsAfterIdle() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.ready()
        let point = host.center
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: point, host: host))
        host.view.mouseMoved(with: try mouse(.mouseMoved, at: point, host: host))
        let highlight = try host.highlight()
        try await waitUntil { !highlight.isHidden && !host.view.hasPendingFrames }
        let previous = host.frames.count
        let before = try await CADAgentRenderer.capturePNG(view: host.view)
        var selections = 0
        host.view.onSelectionChanged = { _ in selections += 1 }
        host.view.onFeatureSelectionChanged = { _ in selections += 1 }

        host.view.flagsChanged(with: try flags(.command, host: host))
        XCTAssertTrue(highlight.isHidden, "Pressing Command must clear the stationary feature immediately.")
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        try await waitUntil { host.frames.count > previous && !host.view.hasPendingFrames }
        let after = try await CADAgentRenderer.capturePNG(view: host.view)
        XCTAssertNotEqual(before, after, "The live hover-clear redraw must also appear in a detached capture.")
        XCTAssertEqual(selections, 0)

        host.view.flagsChanged(with: try flags([], host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "Releasing Command restores the normal cursor without pointer motion.")
    }

    @MainActor
    func testCommandEnterAndMovementSuppressHoverAndExitRestoresArrow() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.ready()
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host, modifiers: .command))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        host.view.mouseMoved(with: try mouse(.mouseMoved, at: host.center, host: host, modifiers: .command))
        XCTAssertTrue(host.optionalHighlight()?.isHidden ?? true)
        host.view.cursorUpdate(with: try mouse(.cursorUpdate, at: host.center, host: host, modifiers: .command))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        host.view.mouseExited(with: try mouse(.mouseExited, at: NSPoint(x: -1, y: -1), host: host, modifiers: .command))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host, modifiers: .command))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        host.view.assemblyGrabbingEnabled = false
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    @MainActor
    func testModifierReleaseKeepsAcceptedGrabAliveAndMouseUpHonorsHeldCommand() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.ready()
        var moves = 0, ends = 0, cancellations = 0
        host.view.onAssemblyGrabBegan = { _, _, _ in true }
        host.view.onAssemblyGrabMoved = { _ in moves += 1 }
        host.view.onAssemblyGrabEnded = { ends += 1 }
        host.view.onAssemblyGrabCancelled = { cancellations += 1 }
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host))
        host.view.flagsChanged(with: try flags(.command, host: host))
        host.view.mouseDown(with: try mouse(.leftMouseDown, at: host.center, host: host, modifiers: .command))
        XCTAssertTrue(host.view.isGrabbingAssembly)
        host.view.flagsChanged(with: try flags([], host: host))
        XCTAssertTrue(host.view.isGrabbingAssembly, "Modifier release changes the cursor while the button-held grab continues.")
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        let target = NSPoint(x: host.center.x + 20, y: host.center.y)
        host.view.mouseDragged(with: try mouse(.leftMouseDragged, at: target, host: host))
        XCTAssertEqual(moves, 1)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        host.view.mouseUp(with: try mouse(.leftMouseUp, at: target, host: host))
        XCTAssertEqual(ends, 1); XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)

        host.view.flagsChanged(with: try flags(.command, host: host))
        host.view.mouseDown(with: try mouse(.leftMouseDown, at: host.center, host: host, modifiers: .command))
        host.view.mouseUp(with: try mouse(.leftMouseUp, at: host.center, host: host, modifiers: .command))
        XCTAssertEqual(ends, 2)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand, "Releasing the mouse while Command remains down retains grab feedback.")
        host.view.flagsChanged(with: try flags([], host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    @MainActor
    func testLocalModifierMonitorWorksWithComposerFirstResponderAndStopsOnDetach() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.ready()
        XCTAssertTrue(host.window.makeFirstResponder(host.editor))
        host.editor.string = "Unsent draft"
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host))
        host.view.mouseMoved(with: try mouse(.mouseMoved, at: host.center, host: host))
        let highlight = try host.highlight()
        try await waitUntil { !highlight.isHidden }

        NSApplication.shared.sendEvent(try flags(.command, host: host))
        XCTAssertTrue(host.window.firstResponder === host.editor)
        XCTAssertEqual(host.editor.modifierEvents, 1, "The local monitor must preserve normal event delivery to the editor.")
        XCTAssertTrue(highlight.isHidden)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        NSApplication.shared.sendEvent(try flags([], host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        XCTAssertEqual(host.editor.string, "Unsent draft")

        host.window.pointerLocation = NSPoint(x: 100, y: 40)
        NSApplication.shared.sendEvent(try flags(.command, host: host))
        XCTAssertFalse(NSCursor.current === NSCursor.closedHand, "The actual pointer over the composer must override an older viewport mouse position.")
        NSApplication.shared.sendEvent(try flags([], host: host))
        host.window.pointerLocation = host.view.convert(host.center, to: nil)
        NSApplication.shared.sendEvent(try flags(.command, host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        host.view.removeFromSuperview()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        NSApplication.shared.sendEvent(try flags([], host: host))
        NSApplication.shared.sendEvent(try flags(.command, host: host))
        XCTAssertFalse(NSCursor.current === NSCursor.closedHand, "A detached viewport must remove its local modifier monitor.")
        XCTAssertTrue(host.window.firstResponder === host.editor)
    }

    @MainActor
    func testModifierEventsBelongToTheirKeyWindowAndDeactivationClearsHand() async throws {
        let first = try Host(origin: NSPoint(x: 50, y: 50))
        defer { first.close() }
        try await first.ready()
        first.view.mouseEntered(with: try mouse(.mouseEntered, at: first.center, host: first))
        NSApplication.shared.sendEvent(try flags(.command, host: first))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)

        let second = try Host(origin: NSPoint(x: 760, y: 50))
        defer { second.close() }
        try await second.ready()
        XCTAssertFalse(first.window.isKeyWindow)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        second.view.mouseEntered(with: try mouse(.mouseEntered, at: second.center, host: second))
        second.view.mouseMoved(with: try mouse(.mouseMoved, at: second.center, host: second))
        let highlight = try second.highlight()
        try await waitUntil { !highlight.isHidden }
        NSApplication.shared.sendEvent(try flags(.command, host: first))
        XCTAssertFalse(highlight.isHidden, "An inactive design's modifier event must not clear the active design's hover.")
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        NSApplication.shared.sendEvent(try flags(.command, host: second))
        XCTAssertTrue(highlight.isHidden)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        second.window.resignKey()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    @MainActor
    func testCommandClearsHoverWithoutClearingSelectedFeature() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.ready()
        host.view.update(mesh: Self.mesh(), mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [],
                         selectedFeatures: [.init(kind: .face, solidIndex: 0, localIndex: 0)])
        let selected = try host.highlight()
        try await waitUntil { !selected.isHidden }
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host))
        host.view.flagsChanged(with: try flags(.command, host: host))
        XCTAssertFalse(selected.isHidden)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
    }

    @MainActor
    func testFlippedContentUsesNativePointerOwnershipNearViewportBoundary() async throws {
        let host = try Host(flipped: true)
        defer { host.close() }
        try await host.ready()
        let point = NSPoint(x: host.view.bounds.midX, y: 10)
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: point, host: host))
        host.view.flagsChanged(with: try flags(.command, host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand, "Flipped hosting coordinates must still recognize the actual viewport under the pointer.")
        host.view.flagsChanged(with: try flags([], host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    @MainActor
    func testStaleViewportFeedbackDoesNotReplaceAnotherControlsIBeam() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.ready()
        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host))
        host.view.flagsChanged(with: try flags(.command, host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        host.window.pointerLocation = host.editor.convert(NSPoint(x: 100, y: 40), to: nil)
        NSCursor.iBeam.set()
        host.view.flagsChanged(with: try flags([], host: host))
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "A late modifier update must preserve the composer's cursor.")

        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host, modifiers: .command))
        let exit = try mouse(.mouseExited, at: NSPoint(x: -1, y: -1), host: host, modifiers: .command)
        NSCursor.iBeam.set()
        host.view.mouseExited(with: exit)
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "A late exit must preserve a cursor installed by the receiving control.")

        host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host, modifiers: .command))
        host.window.pointerLocation = host.editor.convert(NSPoint(x: 100, y: 40), to: nil)
        NSCursor.iBeam.set()
        host.view.removeFromSuperview()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam, "Detachment must not overwrite another control's cursor with stale viewport state.")
    }

    @MainActor
    func testNavigationHandStillClearsOnWindowDeactivation() async throws {
        for middleButton in [false, true] {
            let host = try Host()
            defer { host.close() }
            try await host.ready()
            host.view.mouseEntered(with: try mouse(.mouseEntered, at: host.center, host: host))
            if middleButton {
                host.view.otherMouseDown(with: try mouse(.otherMouseDown, at: host.center, host: host))
            } else {
                host.view.rightMouseDown(with: try mouse(.rightMouseDown, at: host.center, host: host))
                host.view.rightMouseDragged(with: try mouse(.rightMouseDragged,
                    at: NSPoint(x: host.center.x + 10, y: host.center.y), host: host))
            }
            XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
            host.window.resignKey()
            XCTAssertTrue(NSCursor.current === NSCursor.arrow, "Deactivation must still clear a hand owned by ordinary navigation.")
        }
    }

    @MainActor
    func testUnattachedStationaryCommandClearsHoverPreservingSelectionAndReleaseRestoresArrow() async throws {
        let view = try unattachedView()
        var preview = Self.mesh()
        let vertex = CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: 0)
        preview.topology?.vertices = [CADVertex(id: vertex, position: [-10, -10, 0])]
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [vertex])
        try await waitUntil { !view.isPreparingCaptureResources }
        var changes = 0
        view.onSelectionChanged = { _ in changes += 1 }
        view.onFeatureSelectionChanged = { _ in changes += 1 }
        let point = view.projectPoint(SCNVector3Zero)
        let center = NSPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        view.mouseMoved(with: try unattachedMouse(.mouseMoved, point: center))
        let hover = try XCTUnwrap(view.scene.rootNode.childNode(withName: "feature:face:0:0", recursively: true))
        // The selected vertex is a seed in the unoccluded highlight overlay.
        func selectedVertexShown() -> Bool {
            view.makeFrame(width: 64, height: 64).seeds.contains { $0.channel == .selectedVertex }
        }
        try await waitUntil { !hover.isHidden && selectedVertexShown() }
        view.flagsChanged(with: try flags(.command, windowNumber: 0))
        XCTAssertTrue(hover.isHidden)
        XCTAssertTrue(selectedVertexShown())
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        XCTAssertEqual(changes, 0)
        view.flagsChanged(with: try flags([], windowNumber: 0))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        XCTAssertTrue(selectedVertexShown())
        XCTAssertFalse(hover.isHidden, "Modifier release repicks the stationary pointer without losing selection.")
        XCTAssertEqual(changes, 0)
        NSCursor.arrow.set()
    }

    @MainActor
    func testUnattachedCommandEnterMoveAndMouseUpKeepHandUntilModifierRelease() async throws {
        let view = try unattachedView()
        view.update(mesh: Self.mesh(), mode: .edges, grid: false, command: ViewportCommand(.top), selectedSolids: [], hiddenSolids: [])
        try await waitUntil { !view.isPreparingCaptureResources }
        let point = view.projectPoint(SCNVector3Zero)
        let center = NSPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        var ends = 0
        view.onAssemblyGrabBegan = { _, _, _ in true }
        view.onAssemblyGrabEnded = { ends += 1 }
        view.mouseEntered(with: try unattachedMouse(.mouseEntered, point: center, modifiers: .command))
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        view.mouseMoved(with: try unattachedMouse(.mouseMoved, point: center, modifiers: .command))
        XCTAssertTrue(view.scene.rootNode.childNode(withName: "feature:face:0:0", recursively: true)?.isHidden ?? true)
        view.mouseDown(with: try unattachedMouse(.leftMouseDown, point: center, modifiers: .command))
        XCTAssertTrue(view.isGrabbingAssembly)
        view.mouseUp(with: try unattachedMouse(.leftMouseUp, point: center, modifiers: .command))
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(view.isGrabbingAssembly)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        view.flagsChanged(with: try flags([], windowNumber: 0))
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    @MainActor
    private func unattachedView() throws -> CADSceneView {
        _ = NSApplication.shared
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.assemblyGrabbingEnabled = true
        view.layout()
        return view
    }

    @MainActor
    private func unattachedMouse(_ type: NSEvent.EventType, point: NSPoint,
                                 modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        if type == .mouseEntered {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, host: Host,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let location = host.view.convert(point, to: nil)
        host.window.pointerLocation = location
        if [.mouseEntered, .mouseExited, .cursorUpdate].contains(type) {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func flags(_ modifiers: NSEvent.ModifierFlags, host: Host) throws -> NSEvent {
        try flags(modifiers, windowNumber: host.window.windowNumber)
    }

    @MainActor
    private func flags(_ modifiers: NSEvent.ModifierFlags, windowNumber: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw LADError.message("The Command cursor test did not reach its expected viewport state.") }
    }

    @MainActor
    private final class Host {
        let view: CADSceneView
        let window: CommandCursorWindow
        let editor = ModifierCountingEditor(frame: NSRect(x: 0, y: 0, width: 640, height: 80))
        let frames: ViewportRenderCounter
        private let policy: NSApplication.ActivationPolicy

        init(origin: NSPoint = NSPoint(x: 50, y: 50), flipped: Bool = false) throws {
            guard NSRunningApplication.current.bundleURL?.pathExtension == "app" ||
                    ProcessInfo.processInfo.environment["LAD_FOREGROUND_MODIFIER_TESTS"] == "1" else {
                throw XCTSkip("Native key-window modifier tests require a foreground application test host.")
            }
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("Command cursor tests need an awake display and native windows.") }
            _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let app = NSApplication.shared
            policy = app.activationPolicy()
            if app.activationPolicy() != .regular { XCTAssertTrue(app.setActivationPolicy(.regular)) }
            app.finishLaunching()
            view = CADSceneView(frame: NSRect(x: 0, y: 80, width: 640, height: 400))
            let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            let container: NSView = flipped ? FlippedCursorContainer(frame: frame) : NSView(frame: frame)
            container.addSubview(view); container.addSubview(editor)
            window = CommandCursorWindow(contentRect: NSRect(origin: origin, size: container.frame.size), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "LAD Command cursor test"
            window.isReleasedWhenClosed = false
            window.contentView = container
            window.pointerLocation = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            view.assemblyGrabbingEnabled = true
            frames = ViewportRenderCounter(view)
            view.update(mesh: ViewportCommandCursorTests.mesh(), mode: .edges, grid: false, command: ViewportCommand(.top),
                        selectedSolids: [], hiddenSolids: [])
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil); window.displayIfNeeded(); view.layout()
            NSCursor.arrow.set()
        }

        var center: NSPoint {
            let point = view.projectPoint(SCNVector3Zero)
            return NSPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        func optionalHighlight() -> SCNNode? { view.scene.rootNode.childNode(withName: "feature:face:0:0", recursively: true) }
        func highlight() throws -> SCNNode { try XCTUnwrap(optionalHighlight()) }
        func ready() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            _ = NSRunningApplication.current.activate(options: [])
            while !NSApplication.shared.isActive, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            while (view.isPreparingCaptureResources || !window.isKeyWindow || frames.count == 0 || view.hasPendingFrames), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard NSApplication.shared.isActive, window.isKeyWindow, !view.isPreparingCaptureResources,
                  frames.count > 0, !view.hasPendingFrames else {
                XCTFail("Native host inactive: appActive=\(NSApplication.shared.isActive), key=\(window.isKeyWindow), canKey=\(window.canBecomeKey), visible=\(window.isVisible), policy=\(NSApplication.shared.activationPolicy().rawValue), frames=\(frames.count), pending=\(view.hasPendingFrames)")
                throw LADError.message("The Command cursor host must be active and key before testing modifiers.")
            }
        }
        func close() {
            window.orderOut(nil); window.contentView = nil; window.close()
            NSCursor.arrow.set()
            _ = NSApplication.shared.setActivationPolicy(policy)
        }
    }

    private static func mesh() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-10, -10, 0], [10, -10, 0], [10, 10, 0], [-10, 10, 0]],
            triangles: [[0, 1, 2], [0, 2, 3]], edges: [], bounds: [-10, -10, 0, 10, 10, 0], volume: 1, area: 400,
            solids: 1, faces: 1, buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-command-cursor", triangleSolids: [0, 0], edgeSolids: [])
        preview.topology = CADTopology(vertices: [], edges: [],
            faces: [CADFace(id: .init(kind: .face, solidIndex: 0, localIndex: 0), type: "PLANE", area: 400, center: [0, 0, 0])], parts: [])
        preview.triangleFaces = [0, 0]
        return preview
    }
}

private final class FlippedCursorContainer: NSView {
    override var isFlipped: Bool { true }
}

private final class CommandCursorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var pointerLocation: NSPoint?
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation ?? super.mouseLocationOutsideOfEventStream }
}

private final class ModifierCountingEditor: NSTextView {
    private(set) var modifierEvents = 0
    override func flagsChanged(with event: NSEvent) { modifierEvents += 1; super.flagsChanged(with: event) }
}


