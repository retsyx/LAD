import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class PartsSidebarScrollTests: XCTestCase {
    @MainActor
    func testNewRevisionDiscardsThePreviousRevisionsClampedScrollAnchor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(PartsSidebar(state: fixture.state), size: NSSize(width: 340, height: 420))
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let scroll = try await partsScroll(in: host)
        try await scrollTo(1400, scroll: scroll, host: host)
        window.setContentSize(NSSize(width: 340, height: 5000))
        await settle(host)
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 2)

        let previous = try XCTUnwrap(fixture.state.revisions.first)
        let next = ProjectRevision(model: previous.model, preview: previous.preview,
                                   partLayout: previous.partLayout, parts: previous.parts)
        fixture.state.revisions.append(next)
        fixture.state.selectedRevisionID = next.id
        await settle(host)
        window.setContentSize(NSSize(width: 340, height: 420))
        await settle(host)
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 2,
                       "A new revision must not recover a different revision's dormant scroll anchor.")
    }

    @MainActor
    func testNestedChildSelectionAndDeselectionPreserveMiddleScrollPosition() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(PartsSidebar(state: fixture.state), size: NSSize(width: 340, height: 420))
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let scroll = try await partsScroll(in: host)
        for offset: CGFloat in [700, 1400] {
            try await scrollTo(offset, scroll: scroll, host: host)
            let before = scroll.documentVisibleRect.minY
            let documentHeight = try XCTUnwrap(scroll.documentView).bounds.height
            fixture.state.selectPartNodes(["part-40"])
            await settle(host)
            XCTAssertEqual(fixture.state.selectedSolids, [40])
            XCTAssertEqual(scroll.documentVisibleRect.minY, before, accuracy: 2,
                           "Selecting a nested child must not move the Parts scroll position.")
            XCTAssertEqual(try XCTUnwrap(scroll.documentView).bounds.height, documentHeight, accuracy: 2,
                           "Selection styling must not change expanded folder heights.")
            fixture.state.selectPartNodes(["part-40"], extending: true)
            await settle(host)
            XCTAssertTrue(fixture.state.selectedSolids.isEmpty)
            XCTAssertEqual(scroll.documentVisibleRect.minY, before, accuracy: 2,
                           "Deselecting a nested child must not move the Parts scroll position.")
            XCTAssertTrue(fixture.state.isPartFolderExpanded("group-1"))
            XCTAssertTrue(fixture.state.isPartFolderExpanded("nested-1"))
        }
        XCTAssertFalse(fixture.state.isWorking)
    }

    @MainActor
    func testClickingVisibleNestedChildDoesNotJumpItsScrolledPane() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(PartsSidebar(state: fixture.state), size: NSSize(width: 340, height: 420))
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let scroll = try await partsScroll(in: host)
        try await scrollTo(900, scroll: scroll, host: host)
        let before = scroll.documentVisibleRect.minY
        let frame = try visibleRowFrame(in: scroll, host: host)
        try click(frame, in: host)
        await settle(host)
        XCTAssertEqual(fixture.state.selectedSolids.count, 1, "The native click must reach a physical child row.")
        XCTAssertEqual(scroll.documentVisibleRect.minY, before, accuracy: 2,
                       "A native left-click on a visible child must retain the scroll offset.")
        fixture.state.clearSelections()
        await settle(host)
        XCTAssertEqual(scroll.documentVisibleRect.minY, before, accuracy: 2)
    }

    @MainActor
    func testNearBottomSelectionPreservesOffsetExceptForRealViewportClamping() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(PartsSidebar(state: fixture.state), size: NSSize(width: 340, height: 420))
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let scroll = try await partsScroll(in: host)
        let document = try XCTUnwrap(scroll.documentView)
        try await scrollTo(max(0, document.bounds.maxY - scroll.contentSize.height - 8), scroll: scroll,
                           host: host, farFromBottom: false)
        let before = scroll.documentVisibleRect.minY
        fixture.state.selectPartNodes(["part-110"])
        await settle(host)
        assertPreservedOffset(before, scroll: scroll)
        fixture.state.selectPartNodes(["part-110"], extending: true)
        await settle(host)
        assertPreservedOffset(before, scroll: scroll)
        XCTAssertTrue(fixture.state.selectedSolids.isEmpty)
    }

    @MainActor
    func testExplicitScrollAfterViewportClampReplacesThePreviousAnchor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(PartsSidebar(state: fixture.state), size: NSSize(width: 340, height: 420))
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let scroll = try await partsScroll(in: host)
        let document = try XCTUnwrap(scroll.documentView)
        try await scrollTo(document.bounds.maxY - scroll.contentSize.height - 8, scroll: scroll,
                           host: host, farFromBottom: false)
        let before = scroll.documentVisibleRect.minY
        window.setContentSize(NSSize(width: 340, height: 900))
        await settle(host)
        let grownScroll = try await partsScroll(in: host)
        assertPreservedOffset(before, scroll: grownScroll)
        XCTAssertLessThan(grownScroll.documentVisibleRect.minY, before - 200,
                          "Growing the real viewport must clamp the near-bottom offset.")
        try await scrollTo(700, scroll: grownScroll, host: host)
        XCTAssertEqual(grownScroll.documentVisibleRect.minY, 700, accuracy: 2)
        window.setContentSize(NSSize(width: 340, height: 420))
        await settle(host)
        let restoredScroll = try await partsScroll(in: host)
        XCTAssertEqual(restoredScroll.documentVisibleRect.minY, 700, accuracy: 2,
                       "An explicit scroll after clamping must replace the earlier requested anchor.")
    }

    @MainActor
    func testWorkspaceMeasurementsAndPartsPaneGrowthPreserveItsScrolledContent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(WorkspaceView(state: fixture.state), size: NSSize(width: 1280, height: 1000))
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let initialSplit = try await sidebar(in: host, paneCount: 2)
        initialSplit.setPosition(initialSplit.bounds.height * 0.4, ofDividerAt: 0)
        await settle(host)
        let initialScroll = try await partsScroll(in: host)
        try await scrollTo(1000, scroll: initialScroll, host: host)
        let middle = initialScroll.documentVisibleRect.minY
        let documentHeight = try XCTUnwrap(initialScroll.documentView).bounds.height
        fixture.state.selectPartNodes(["part-40"])
        let measuredSplit = try await sidebar(in: host, paneCount: 3)
        await settle(host)
        let measuredScroll = try await partsScroll(in: host)
        assertPreservedOffset(middle, scroll: measuredScroll)
        XCTAssertEqual(try XCTUnwrap(measuredScroll.documentView).bounds.height, documentHeight, accuracy: 2)
        XCTAssertTrue(fixture.state.hasMeasurementSelection)

        let partsHeight = measuredSplit.arrangedSubviews[0].frame.height
        measuredSplit.setPosition(partsHeight + 60, ofDividerAt: 0)
        await settle(host)
        XCTAssertGreaterThan(measuredSplit.arrangedSubviews[0].frame.height, partsHeight + 40)
        let grownScroll = try await partsScroll(in: host)
        assertPreservedOffset(middle, scroll: grownScroll)
        fixture.state.clearSelections()
        _ = try await sidebar(in: host, paneCount: 2)
        await settle(host)
        let unselectedScroll = try await partsScroll(in: host)
        assertPreservedOffset(middle, scroll: unselectedScroll)
        XCTAssertEqual(try XCTUnwrap(unselectedScroll.documentView).bounds.height, documentHeight, accuracy: 2)

        // Inserting Measurements shrinks Parts, and removing it grows Parts
        // again. Begin near the bottom so a reset or gratuitous re-anchor is
        // visible while still allowing a genuine native bounds clamp.
        let document = try XCTUnwrap(unselectedScroll.documentView)
        try await scrollTo(max(0, document.bounds.maxY - unselectedScroll.contentSize.height - 8),
                           scroll: unselectedScroll, host: host, farFromBottom: false)
        let bottom = unselectedScroll.documentVisibleRect.minY
        fixture.state.selectPartNodes(["part-110"])
        _ = try await sidebar(in: host, paneCount: 3)
        let selectedScroll = try await partsScroll(in: host)
        await settle(host)
        assertPreservedOffset(bottom, scroll: selectedScroll)
        fixture.state.clearSelections()
        _ = try await sidebar(in: host, paneCount: 2)
        let finalScroll = try await partsScroll(in: host)
        await settle(host)
        assertPreservedOffset(bottom, scroll: finalScroll)
        XCTAssertFalse(fixture.state.isWorking)
    }

    @MainActor
    private func assertPreservedOffset(_ requested: CGFloat, scroll: NSScrollView,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let maximum = max(0, (scroll.documentView?.bounds.maxY ?? 0) - scroll.contentSize.height)
        XCTAssertEqual(scroll.documentVisibleRect.minY, min(requested, maximum), accuracy: 2,
                       "Selection must preserve the content offset, subject only to actual viewport bounds.", file: file, line: line)
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
        throw LADError.message("The workspace did not display the expected Parts/Measurements/Design panes.")
    }

    @MainActor
    private func partsScroll(in host: NSView) async throws -> NSScrollView {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
                ($0.documentView?.bounds.height ?? 0) > 1800 && $0.contentSize.height > 50
            }) { return scroll }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LADError.message("The native Parts scroll fixture did not display its expanded folder tree.")
    }

    @MainActor
    private func scrollTo(_ offset: CGFloat, scroll: NSScrollView, host: NSView, farFromBottom: Bool = true) async throws {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(host)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 300, "The regression must begin after actual scrolling.")
        let document = try XCTUnwrap(scroll.documentView)
        if farFromBottom {
            XCTAssertLessThan(scroll.documentVisibleRect.maxY, document.bounds.maxY - 100,
                              "The offset must be away from the bottom clamp before changing selection.")
        }
    }

    @MainActor
    private func visibleRowFrame(in scroll: NSScrollView, host: NSView) throws -> NSRect {
        let document = try XCTUnwrap(scroll.documentView)
        let visible = host.convert(scroll.documentVisibleRect, from: document).insetBy(dx: 0, dy: 45)
        var rows = [[NSRect]]()
        for leaf in descendants(document) where leaf.subviews.isEmpty && !leaf.isHiddenOrHasHiddenAncestor {
            let frame = host.convert(leaf.bounds, from: leaf)
            guard frame.width > 120, (20...40).contains(frame.height), visible.contains(frame) else { continue }
            if let index = rows.firstIndex(where: { abs($0[0].midY - frame.midY) < 1 }) { rows[index].append(frame) }
            else { rows.append([frame]) }
        }
        let buttons = rows.compactMap { $0.min { $0.width < $1.width } }
        return try XCTUnwrap(buttons.min { abs($0.midY - visible.midY) < abs($1.midY - visible.midY) })
    }

    @MainActor
    private func click(_ frame: NSRect, in host: NSView) throws {
        let window = try XCTUnwrap(host.window)
        let location = host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        XCTAssertNotNil(host.hitTest(host.convert(location, from: nil)))
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.sendEvent(down)
        if let release = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(release)
        }
    }

    @MainActor
    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func makeWindow<Content: View>(_ content: Content, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LAD Parts scroll test"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
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
        let directory: URL
        let state: AppState
        let policy: NSApplication.ActivationPolicy

        init() throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for native Parts scroll tests.") }
            let application = NSApplication.shared
            policy = application.activationPolicy()
            application.setActivationPolicy(.regular)
            application.finishLaunching()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-parts-scroll-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var next = 0
            let parts = [12, 55, 6, 36, 18].enumerated().map { group, count -> PartNode in
                let children = (0..<count).map { _ -> PartNode in
                    defer { next += 1 }
                    return PartNode(id: "part-\(next)", name: "Nested part \(next)", solidIndices: [next])
                }
                return PartNode(id: "group-\(group)", name: "Assembly \(group)", solidIndices: [], children: [
                    PartNode(id: "nested-\(group)", name: "Nested folder \(group)", solidIndices: [], children: children)])
            }
            var preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1],
                volume: Double(next), area: Double(next * 6), solids: next, faces: next * 6, buildSeconds: 0, threads: 1,
                stepPath: directory.appendingPathComponent("selection-preview").path, parts: parts)
            preview.topology = CADTopology(vertices: [], edges: [], faces: [], parts: (0..<next).map {
                CADPart(solidIndex: $0, area: 6, volume: 1, bounds: [0,0,0,1,1,1], centroid: [0.5,0.5,0.5])
            })
            let revision = ProjectRevision(model: .bracket, preview: preview, partLayout: PartLayout(nodes: parts), parts: parts)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            state.revisions = [revision]
            state.selectedRevisionID = revision.id
            state.mesh = preview
        }

        func cleanUp() {
            state.cancel()
            NSApplication.shared.setActivationPolicy(policy)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
