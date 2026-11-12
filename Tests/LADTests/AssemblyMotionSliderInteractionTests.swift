import AppKit
import SwiftUI
import XCTest
@testable import LAD

/// Drags the rendered SwiftUI slider with in-process mouse events. Each
/// drag passes an end, so its final value reveals the window held then.
final class AssemblyMotionSliderInteractionTests: XCTestCase {
    @MainActor
    func testReleasingAtEitherEndRecentersAContinuousRevoluteSlider() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(state: fixture.state, motion: fixture.motion)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let track = try await sliderFrame(in: host)
        let state = fixture.state
        XCTAssertEqual(state.jointPosition(Fixture.wheel), 0)

        for (end, expected) in [(1.4, 180.0), (1.4, 360), (-0.4, 180), (-0.4, 0), (-0.4, -180)] {
            // Each release at an end recenters the thumb, so the next drag starts in the middle.
            try await drag(from: 0.5, to: end, along: track, in: host, state: state)
            XCTAssertEqual(state.jointPosition(Fixture.wheel), expected, accuracy: 1e-6)
        }

        // Releasing between the ends keeps the window and the thumb position.
        try await drag(from: 0.5, to: 0.75, along: track, in: host, state: state)
        XCTAssertEqual(state.jointPosition(Fixture.wheel), -90, accuracy: 10)
        try await drag(from: 0.75, to: 1.4, along: track, in: host, state: state)
        XCTAssertEqual(state.jointPosition(Fixture.wheel), 0, accuracy: 1e-6)

        // A position set elsewhere shows within its own revolution.
        state.setJointPosition("wheel", to: 1000)
        try await settle(state, host: host)
        try await drag(from: 100.0 / 360, to: 1.4, along: track, in: host, state: state)
        XCTAssertEqual(state.jointPosition(Fixture.wheel), 1260, accuracy: 1e-6)
        XCTAssertNil(state.assemblyMotionError)
    }

    /// Presses at a fraction of the knob's travel, drags to another fraction
    /// (outside 0...1 to pass an end), and releases there.
    @MainActor
    private func drag(from start: Double, to end: Double, along track: NSRect, in host: NSView, state: AppState) async throws {
        let window = try XCTUnwrap(host.window)
        window.makeKey()
        let radius = track.height / 2
        func point(_ fraction: Double) -> NSPoint {
            NSPoint(x: track.minX + radius + (track.width - 2 * radius) * fraction, y: track.midY)
        }
        func send(_ type: NSEvent.EventType, _ location: NSPoint) async throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            // These events stay inside this test application's native event loop.
            NSApplication.shared.sendEvent(event)
            try await Task.sleep(for: .milliseconds(15))
        }
        try await send(.leftMouseDown, point(start))
        for step in 1...10 {
            try await send(.leftMouseDragged, point(start + (end - start) * Double(step) / 10))
        }
        try await send(.leftMouseUp, point(end))
        try await settle(state, host: host)
    }

    @MainActor
    private func settle(_ state: AppState, host: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        } while state.isSolvingAssembly && ContinuousClock.now < deadline
        XCTAssertFalse(state.isSolvingAssembly)
    }

    /// The rendered slider's frame in window coordinates: the only control
    /// spanning the pane's width (its keyboard proxy and focus ring share it).
    @MainActor
    private func sliderFrame(in host: NSView) async throws -> NSRect {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            let frames = descendants(host).dropFirst().map { $0.convert($0.bounds, to: nil) }
                .filter { $0.width > host.bounds.width * 0.75 && $0.height < 30 }
            if let frame = frames.first, frames.allSatisfy({ $0.equalTo(frame) }) { return frame }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LADError.message("The motion controls did not render their slider.")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func makeWindow(state: AppState, motion: AssemblyMotion) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LAD motion slider test"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AssemblyMotionControls(state: state, motion: motion).padding(16))
        host.sizingOptions = []
        window.contentView = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }

    @MainActor
    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    @MainActor
    private struct Fixture {
        static let wheel = AssemblyJoint(id: "wheel", name: "Wheel rotation", type: .revolute, parent: "a", child: "b")
        let directory: URL
        let state: AppState
        let motion: AssemblyMotion
        let previousPolicy: NSApplication.ActivationPolicy

        init() throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for native slider tests.") }
            let application = NSApplication.shared
            previousPolicy = application.activationPolicy()
            application.setActivationPolicy(.regular)
            application.finishLaunching()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-motion-slider-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let parts = [PartNode(id: "base", name: "Base", solidIndices: [0]),
                         PartNode(id: "wheel", name: "Wheel", solidIndices: [1])]
            motion = AssemblyMotion(grounded: ["base"], connectors: [
                .init(id: "a", part: "base", origin: [0, 0, 0]),
                .init(id: "b", part: "wheel", origin: [0, 0, 0])], joints: [Self.wheel])
            var preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 2, 1, 1],
                volume: 2, area: 12, solids: 2, faces: 12, buildSeconds: 0, threads: 1,
                stepPath: directory.appendingPathComponent("motion-preview").path, parts: parts)
            preview.topology = CADTopology(vertices: [], edges: [], faces: [], parts: (0..<2).map { index in
                CADPart(solidIndex: index, area: 6, volume: 1,
                        bounds: [Double(index), 0, 0, Double(index + 1), 1, 1], centroid: [Double(index) + 0.5, 0.5, 0.5])
            })
            preview.assemblyMotion = motion
            preview.assemblyPose = try motion.solve(parts: parts)
            let revision = ProjectRevision(model: ModelSpec(title: "Motion slider fixture", summary: "A continuous wheel",
                units: "mm", script: "result = cq.Workplane('XY').box(1, 1, 1)\n"), preview: preview, parts: parts)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.revisions = [revision]
            state.selectedRevisionID = revision.id
            state.mesh = preview
        }

        func cleanUp() {
            state.cancel()
            NSApplication.shared.setActivationPolicy(previousPolicy)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
