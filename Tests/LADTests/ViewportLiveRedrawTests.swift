import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportLiveRedrawTests: XCTestCase {
    @MainActor
    func testWheelZoomRecoversAfterSurfaceAnchorBecomesTooSmallToHit() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for live viewport drawing.") }
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        defer { _ = application.setActivationPolicy(previousPolicy) }
        application.finishLaunching()

        for projection in ViewportProjectionMode.allCases {
            let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), options: [
                SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
            ])
            let frames = ViewportRenderCounter()
            view.delegate = frames
            let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 480, height: 360),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "LAD viewport wheel zoom test"
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer {
                view.delegate = nil
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            view.update(mesh: box(), mode: .edges, grid: false, command: ViewportCommand(.front),
                        selectedSolids: [], hiddenSolids: [], projection: projection)
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            view.layout()
            let deadline = ContinuousClock.now + .seconds(10)
            while view.isPreparingResources, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(view.isPreparingResources)
            guard try await waitForFrame(frames, after: 0, reason: "The wheel regression needs a rendered front surface.") else { return }
            guard try await waitForIdle(frames) else { return }
            let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            let hitOptions: [SCNHitTestOption: Any] = [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.closest.rawValue]
            XCTAssertFalse(view.hitTest(center, options: hitOptions).isEmpty)
            func projectedWidth() -> Double {
                abs(Double(view.projectPoint(SCNVector3(3, 0, 0)).x - view.projectPoint(SCNVector3(-3, 0, 0)).x))
            }
            let fittedWidth = projectedWidth()
            XCTAssertGreaterThan(fittedWidth, 50)

            for _ in 0..<6 {
                let before = frames.count
                view.scrollWheel(with: try wheel(-250, at: center, in: view))
                guard try await waitForFrame(frames, after: before, reason: "Wheel zoom-out must draw its new camera.") else { return }
            }
            guard try await waitForIdle(frames) else { return }
            let target = try XCTUnwrap(view.agentCaptureMetadata["cameraTarget"] as? [Double])
            XCTAssertGreaterThan(abs(target[1]), 10, "Surface zoom must have displaced the target behind this front-facing design.")
            XCTAssertLessThan(projectedWidth(), 0.1, "The regression must reach a subpixel design.")
            // The original ray still intersects its surface anchor. A one-point
            // pointer movement forces the empty-space fallback at this scale.
            let missedPoint = NSPoint(x: center.x + 1, y: center.y)
            XCTAssertTrue(view.hitTest(missedPoint, options: hitOptions).isEmpty)
            for step in 0..<8 {
                let projected = view.projectPoint(SCNVector3Zero)
                let point = step == 0 ? missedPoint : NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                let before = frames.count
                view.scrollWheel(with: try wheel(250, at: point, in: view))
                guard try await waitForFrame(frames, after: before, reason: "Wheel zoom-in after idle must draw its recovered camera.") else { return }
                let transform = try XCTUnwrap(view.pointOfView).simdWorldTransform
                let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                let backward = SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                XCTAssertGreaterThan(simd_dot(position, backward), 0, "Empty-space zoom must keep the design in front of the camera in \(projection.rawValue).")
                if projectedWidth() >= fittedWidth * 0.6 { break }
            }
            guard try await waitForIdle(frames) else { return }
            XCTAssertGreaterThanOrEqual(projectedWidth(), fittedWidth * 0.6, "Wheel zoom must recover visible design scale without Fit.")
            let recovered = view.projectPoint(SCNVector3Zero)
            XCTAssertTrue(view.bounds.insetBy(dx: 10, dy: 10).contains(NSPoint(x: CGFloat(recovered.x), y: CGFloat(recovered.y))))
            XCTAssertFalse(view.rendersContinuously, "Recovered wheel navigation must return to idle.")
        }
    }

    @MainActor
    func testIdleNativeViewportRendersDisplayAndCameraChangesIntoItsWindow() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for live viewport drawing.") }
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // XCTest does not run LAD's application launch lifecycle. Initialize
        // it here so the window can activate and receive visibility events.
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        defer { _ = application.setActivationPolicy(previousPolicy) }
        application.finishLaunching()
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let frames = ViewportRenderCounter()
        view.delegate = frames
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD viewport redraw test"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.delegate = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let preview = box()
        view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        view.layout()
        let preparationDeadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < preparationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(view.isPreparingResources)
        guard try await waitForFrame(frames, after: 0, reason: "A hosted viewport must draw its initial scene.") else { return }
        guard try await waitForIdle(frames) else { return }

        // Adding and removing a projected part outline changes the multipass
        // technique. Each new pipeline must finish its live frame and release
        // the redraw burst through the final completion marker.
        let beforeSelection = frames.count
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [])
        guard try await waitForFrame(frames, after: beforeSelection,
                                    reason: "Selecting a part after idle must draw its silhouette in a fresh live frame.") else { return }
        guard try await waitForIdle(frames) else { return }
        XCTAssertFalse(view.rendersContinuously, "A completed silhouette frame must let the viewport pause.")

        let beforeDeselection = frames.count
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        guard try await waitForFrame(frames, after: beforeDeselection,
                                    reason: "Deselecting a part after idle must remove its silhouette in a fresh live frame.") else { return }
        guard try await waitForIdle(frames) else { return }
        XCTAssertFalse(view.rendersContinuously, "Removing the silhouette must retain normal viewport pausing.")

        // Cold display links must restart after app/display lifecycle events,
        // even when no CAD geometry or camera property changes at that instant.
        // A timer-only burst can otherwise leave a stale drawable until the
        // user raises the window, while input changes accumulate underneath.
        try await Task.sleep(for: .seconds(1))
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let beforeWake = frames.count
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
            guard try await waitForFrame(frames, after: beforeWake,
                                        reason: "Waking the system or display must restart live viewport drawing.") else { return }
            guard try await waitForIdle(frames) else { return }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            let beforeActivation = frames.count
            NotificationCenter.default.post(name: name, object: NSApplication.shared)
            guard try await waitForFrame(frames, after: beforeActivation,
                                        reason: "App activation or a display change must restart live viewport drawing.") else { return }
            guard try await waitForIdle(frames) else { return }
        }

        // Observe the original SCNView's delegate. Independent SCNRenderer
        // snapshots would hide a broken live display link or paused renderer.
        let beforeWire = frames.count
        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        guard try await waitForFrame(frames, after: beforeWire,
                                    reason: "Changing rendering mode after idle must produce a fresh live frame.") else { return }
        guard try await waitForIdle(frames) else { return }

        let probe = SCNVector3(3, 2, 1)
        let beforeProjection = view.projectPoint(probe)
        let beforeFront = frames.count
        view.update(mesh: preview, mode: .wireframe, grid: false, command: ViewportCommand(.front),
                    selectedSolids: [], hiddenSolids: [])
        guard try await waitForFrame(frames, after: beforeFront,
                                    reason: "Changing the camera after idle must produce a fresh live frame.") else { return }
        guard try await waitForIdle(frames) else { return }
        let afterProjection = view.projectPoint(probe)
        XCTAssertGreaterThan(hypot(Double(afterProjection.x - beforeProjection.x),
                                  Double(afterProjection.y - beforeProjection.y)), 10,
                             "The live renderer's projection must reflect the newly drawn camera.")

        let beforeOrbit = view.projectPoint(probe)
        let beforeDragFrame = frames.count
        view.rightMouseDown(with: try mouse(.rightMouseDown, at: NSPoint(x: 200, y: 150), in: view))
        let drag = try mouse(.rightMouseDragged, at: NSPoint(x: 240, y: 170), in: view)
        XCTAssertEqual(drag.deltaX, 0)
        XCTAssertEqual(drag.deltaY, 0)
        view.rightMouseDragged(with: drag)
        view.rightMouseUp(with: try mouse(.rightMouseUp, at: NSPoint(x: 240, y: 170), in: view))
        guard try await waitForFrame(frames, after: beforeDragFrame,
                                    reason: "Right-dragging after idle must produce a fresh live frame.") else { return }
        guard try await waitForIdle(frames) else { return }
        let afterOrbit = view.projectPoint(probe)
        XCTAssertGreaterThan(hypot(Double(afterOrbit.x - beforeOrbit.x), Double(afterOrbit.y - beforeOrbit.y)), 5,
                             "The rendered camera must actually orbit in response to right-drag input.")

        window.orderOut(nil)
        let hiddenDeadline = ContinuousClock.now + .seconds(3)
        while window.occlusionState.contains(.visible), ContinuousClock.now < hiddenDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(window.occlusionState.contains(.visible))
        guard try await waitForIdle(frames) else { return }
        view.update(mesh: preview, mode: .wireframe, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [])
        // Leave the window hidden beyond a normal redraw burst. Merely
        // ordering it front must wake drawing without a key-window action.
        try await Task.sleep(for: .milliseconds(200))
        let beforeReveal = frames.count
        window.orderFront(nil)
        guard try await waitForFrame(frames, after: beforeReveal,
                                    reason: "Revealing a window must draw changes made while it was hidden.") else { return }
        guard try await waitForIdle(frames) else { return }
        let afterReveal = view.projectPoint(probe)
        XCTAssertGreaterThan(hypot(Double(afterReveal.x - afterOrbit.x), Double(afterReveal.y - afterOrbit.y)), 5,
                             "A revealed window must show its updated camera rather than a stale frame.")

        window.contentView = nil
        XCTAssertFalse(view.rendersContinuously, "A detached viewport must stop requesting frames.")
        guard try await waitForIdle(frames) else { return }
        let afterDetach = frames.count
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertEqual(frames.count, afterDetach, "Lifecycle notifications must not wake a detached viewport.")
    }

    @MainActor
    private func wheel(_ delta: Int32, at point: NSPoint, in view: CADSceneView) throws -> NSEvent {
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: delta, wheel2: 0, wheel3: 0))
        // CG-backed synthetic events have no window. Match their AppKit
        // location to the receiving view's window coordinates explicitly.
        scroll.location = .zero
        let origin = try XCTUnwrap(NSEvent(cgEvent: scroll)).locationInWindow
        scroll.location = CGPoint(x: 1, y: 1)
        let unit = try XCTUnwrap(NSEvent(cgEvent: scroll)).locationInWindow
        let desired = view.convert(point, to: nil)
        scroll.location = CGPoint(x: (desired.x - origin.x) / (unit.x - origin.x),
                                  y: (desired.y - origin.y) / (unit.y - origin.y))
        let event = try XCTUnwrap(NSEvent(cgEvent: scroll))
        let received = view.convert(event.locationInWindow, from: nil)
        XCTAssertEqual(received.x, point.x, accuracy: 0.01)
        XCTAssertEqual(received.y, point.y, accuracy: 0.01)
        return event
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: CADSceneView) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func waitForFrame(_ frames: ViewportRenderCounter, after previous: Int, reason: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while frames.count <= previous, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard frames.count > previous else {
            XCTFail(reason, file: file, line: line)
            return false
        }
        return true
    }

    @MainActor
    private func waitForIdle(_ frames: ViewportRenderCounter,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        var previous = frames.count
        var lastChange = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            let current = frames.count
            if current != previous { previous = current; lastChange = ContinuousClock.now }
            if ContinuousClock.now - lastChange >= .milliseconds(250) { return true }
        }
        XCTFail("An unchanged CAD viewport should become idle rather than render continuously.", file: file, line: line)
        return false
    }

    private func box() -> PreviewMesh {
        PreviewMesh(vertices: [[-3,-2,-1],[3,-2,-1],[3,2,-1],[-3,2,-1],[-3,-2,1],[3,-2,1],[3,2,1],[-3,2,1]],
            triangles: [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
                        [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]],
            edges: [[-3,-2,-1,3,-2,-1],[3,-2,-1,3,2,-1],[3,2,-1,-3,2,-1],[-3,2,-1,-3,-2,-1],
                    [-3,-2,1,3,-2,1],[3,-2,1,3,2,1],[3,2,1,-3,2,1],[-3,2,1,-3,-2,1]],
            bounds: [-3,-2,-1,3,2,1], volume: 48, area: 88, solids: 1, faces: 6,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/live-viewport-redraw-test",
            triangleSolids: Array(repeating: 0, count: 12), edgeSolids: Array(repeating: 0, count: 8))
    }
}

/// SceneKit invokes this callback from its rendering thread, independently of
/// the main actor that sends input and changes the document's display state.
private final class ViewportRenderCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
