import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class ProjectSidebarLayoutTests: XCTestCase {
    @MainActor
    func testSidebarPanesResizeIndependentlyWithMeasurements() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(width: 1280, height: 1000)
        let host = NSHostingView(rootView: WorkspaceView(state: fixture.state))
        window.contentView = host
        defer { close(window) }
        window.orderFront(nil)
        _ = try await sidebar(in: host, paneCount: 2)
        fixture.state.selectedSolids = [0]
        let split = try await sidebar(in: host, paneCount: 3)
        let height = split.bounds.height
        split.setPosition(height * 0.30, ofDividerAt: 0)
        split.setPosition(height * 0.60, ofDividerAt: 1)
        await settle(host)
        let initial = split.arrangedSubviews.map { $0.frame.height }

        split.setPosition(height * 0.30 + 60, ofDividerAt: 0)
        await settle(host)
        let firstDrag = split.arrangedSubviews.map { $0.frame.height }
        XCTAssertEqual(firstDrag[0] - initial[0], 60, accuracy: 3)
        XCTAssertEqual(initial[1] - firstDrag[1], 60, accuracy: 3)
        XCTAssertEqual(firstDrag[2], initial[2], accuracy: 3,
                       "The Parts divider should resize its neighboring Measurements pane.")

        split.setPosition(height * 0.60 + 60, ofDividerAt: 1)
        await settle(host)
        let secondDrag = split.arrangedSubviews.map { $0.frame.height }
        XCTAssertEqual(secondDrag[0], firstDrag[0], accuracy: 3)
        XCTAssertEqual(secondDrag[1] - firstDrag[1], 60, accuracy: 3)
        XCTAssertEqual(firstDrag[2] - secondDrag[2], 60, accuracy: 3,
                       "The Design divider should resize independently of Parts.")
        XCTAssertTrue(secondDrag.allSatisfy { $0 > 90 })
        XCTAssertEqual(secondDrag.reduce(0, +) + split.dividerThickness * 2, height, accuracy: 3)
        try snapshot(host, to: "/tmp/lad-resizable-sidebar.png")

        fixture.state.clearSelections()
        let withoutMeasurements = try await sidebar(in: host, paneCount: 2)
        XCTAssertTrue(withoutMeasurements.arrangedSubviews.allSatisfy { $0.frame.height >= 139 })
        XCTAssertFalse(fixture.state.isWorking, "A layout fixture must never start CAD or Codex work.")
    }

    @MainActor
    func testExpandedProgramFillsTheDesignPaneAndScrollsCompleteLongSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(width: 360, height: 700)
        let pane = ProjectDetailsPane(state: fixture.state, project: fixture.model, isProgramExpanded: .constant(true))
        let host = NSHostingView(rootView: pane)
        // A pane receives a bounded rectangle from its native split view.
        // Do not let this standalone hosting fixture resize the window to the
        // program's intrinsic content size instead of exercising that bound.
        host.sizingOptions = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        defer { close(window) }
        window.orderFront(nil)
        let scroll = try await programScroll(in: host)
        XCTAssertEqual(host.bounds.height, 700, accuracy: 1, "The fixture must retain the requested pane height.")
        XCTAssertGreaterThan(scroll.frame.height, 400,
                             "Expanded source must use the available pane height, rather than a 220-point cap.")
        let frame = host.convert(scroll.bounds, from: scroll)
        let bottomGap = host.isFlipped ? host.bounds.maxY - frame.maxY : frame.minY - host.bounds.minY
        XCTAssertGreaterThanOrEqual(bottomGap, 0)
        XCTAssertLessThanOrEqual(bottomGap, 25, "No unused region should remain below the expanded program.")
        XCTAssertGreaterThan(frame.width, host.bounds.width - 65,
                             "Copy controls must not reserve a separate column beside the code.")
        let oldHeight = scroll.frame.height
        window.setContentSize(NSSize(width: 360, height: 900))
        await settle(host)
        XCTAssertEqual(host.bounds.height, 900, accuracy: 1)
        XCTAssertEqual(scroll.frame.height - oldHeight, 200, accuracy: 4,
                       "The program must grow with its Design pane.")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height * 1.5)
        XCTAssertGreaterThan(document.bounds.width, scroll.contentSize.width * 1.5,
                             "Long source lines must remain horizontally scrollable rather than wrapping or being truncated.")
        let lastY = document.isFlipped ? document.bounds.maxY - scroll.contentSize.height : document.bounds.minY
        let lastX = document.bounds.maxX - scroll.contentSize.width
        scroll.contentView.scroll(to: NSPoint(x: lastX, y: lastY))
        scroll.reflectScrolledClipView(scroll.contentView)
        let visible = scroll.documentVisibleRect
        XCTAssertEqual(visible.maxX, document.bounds.maxX, accuracy: 3)
        if document.isFlipped { XCTAssertEqual(visible.maxY, document.bounds.maxY, accuracy: 3) }
        else { XCTAssertEqual(visible.minY, document.bounds.minY, accuracy: 3) }
        try snapshot(host, to: "/tmp/lad-expanded-program-pane.png")
    }

    @MainActor
    private func sidebar(in host: NSView, paneCount: Int) async throws -> NSSplitView {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let split = descendants(host).compactMap({ $0 as? NSSplitView }).first(where: {
                !$0.isVertical && $0.arrangedSubviews.count == paneCount && $0.bounds.height > 300
            }) { return split }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The sidebar did not provide \(paneCount) native resizable panes.")
        return try XCTUnwrap(descendants(host).compactMap { $0 as? NSSplitView }.first { !$0.isVertical })
    }

    @MainActor
    private func programScroll(in host: NSView) async throws -> NSScrollView {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
                !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 100
            }) { return scroll }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The expanded CadQuery program has no visible scroll area.")
        return try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "LAD sidebar layout check"
        return window
    }

    @MainActor
    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    @MainActor
    private func snapshot(_ view: NSView, to path: String) throws {
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let oldCodex: Any?
        let state: AppState
        let model: ModelSpec

        init() throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for native sidebar layout checks.") }
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-sidebar-layout-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            oldCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
            let source = (0..<220).map { "# Source line \($0): " + String(repeating: "complete source remains scrollable ", count: 8) }.joined(separator: "\n")
                + "\nresult = cq.Workplane('XY').box(10, 20, 5)\n# FINAL_SOURCE_LINE\n"
            model = ModelSpec(title: "Sidebar layout fixture", summary: "Native layout checks", units: "mm", script: source)
            let parts = [PartNode(id: "body", name: "Fixture body", solidIndices: [0])]
            var preview = PreviewMesh(vertices: [[0,0,0],[10,0,0],[10,20,0],[0,20,0]],
                triangles: [[0,1,2],[0,2,3]], edges: [[0,0,0,10,0,0]], bounds: [0,0,0,10,20,5],
                volume: 1000, area: 700, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                stepPath: directory.appendingPathComponent("session-preview").path, triangleSolids: [0,0], edgeSolids: [0], parts: parts)
            preview.topology = CADTopology(vertices: [], edges: [], faces: [],
                parts: [CADPart(solidIndex: 0, area: 700, volume: 1000, bounds: preview.bounds, centroid: [5,10,2.5])])
            let revision = ProjectRevision(model: model, preview: preview, parts: parts)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.revisions = [revision]
            state.selectedRevisionID = revision.id
            state.mesh = preview
        }

        func cleanUp() {
            state.cancel()
            if let oldCodex { UserDefaults.standard.set(oldCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
