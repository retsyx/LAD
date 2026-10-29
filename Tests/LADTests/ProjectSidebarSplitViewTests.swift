import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class ProjectSidebarSplitViewTests: XCTestCase {
    @MainActor
    func testEmptyDesignAlwaysMountsTwoPanesAtDefaultFraction() async throws {
        let fixture = try Fixture(empty: true)
        defer { fixture.cleanUp() }
        let window = makeWindow(state: fixture.state, program: fixture.program)
        defer { close(window) }
        let split = try await nativeSplit(in: try XCTUnwrap(window.contentView))
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        assertFraction(0.75, in: split)
        XCTAssertEqual(fixture.state.partsPaneFraction, 0.75)
    }

    @MainActor
    func testSelectionProgramAndContentUpdatesRetainNativeHostsAndDivider() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(state: fixture.state, program: fixture.program)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let split = try await nativeSplit(in: host)
        let panes = split.arrangedSubviews.map(ObjectIdentifier.init)
        let hosts = split.arrangedSubviews.flatMap(\.subviews).map(ObjectIdentifier.init)
        let frame = window.frame, minimum = window.contentMinSize
        let top = split.arrangedSubviews[0].frame.height
        fixture.state.selectPartNodes(["body"])
        await settle(host)
        fixture.program.value = true
        fixture.state.revisions[0].model.script += "\n" + String(repeating: "# complete long source line\n", count: 300)
        fixture.state.revisions[0].model.summary = String(repeating: "Long design summary. ", count: 300)
        await settle(host)
        fixture.state.clearSelections()
        await settle(host)
        let updated = try await nativeSplit(in: host)
        XCTAssertTrue(updated === split)
        XCTAssertEqual(split.arrangedSubviews.map(ObjectIdentifier.init), panes)
        XCTAssertEqual(split.arrangedSubviews.flatMap(\.subviews).map(ObjectIdentifier.init), hosts)
        XCTAssertEqual(split.arrangedSubviews[0].frame.height, top, accuracy: 1)
        XCTAssertEqual(fixture.state.partsPaneFraction, 0.75)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.contentMinSize, minimum, "Hosting content must not resize the window or renegotiate its limits.")
    }

    @MainActor
    func testNativeDividerAndExternalFractionChangesStaySynchronizedAcrossResize() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.state.setPartsPaneFraction(0.6)
        let window = makeWindow(state: fixture.state, program: fixture.program)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let split = try await nativeSplit(in: host)
        assertFraction(0.6, in: split)
        split.setPosition((split.bounds.height - split.dividerThickness) * 0.4, ofDividerAt: 0)
        await settle(host)
        XCTAssertEqual(fixture.state.partsPaneFraction, 0.4, accuracy: 0.002)
        fixture.state.setPartsPaneFraction(0.7)
        await settle(host)
        assertFraction(0.7, in: split)
        window.setContentSize(NSSize(width: 410, height: 1000))
        await settle(host)
        assertFraction(0.7, in: split)
        XCTAssertEqual(fixture.state.partsPaneFraction, 0.7, accuracy: 1e-12)
    }

    @MainActor
    func testPixelMinimumNeverOverwritesStoredFractionDuringHeightOrWidthResize() async throws {
        let fixture = try Fixture(empty: true)
        defer { fixture.cleanUp() }
        fixture.state.setPartsPaneFraction(0.99)
        let window = makeWindow(state: fixture.state, program: fixture.program)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let split = try await nativeSplit(in: host)
        for size in [NSSize(width: 340, height: 180), NSSize(width: 430, height: 180), NSSize(width: 430, height: 110), NSSize(width: 340, height: 800)] {
            window.setContentSize(size)
            await settle(host)
            XCTAssertEqual(fixture.state.partsPaneFraction, 0.99, accuracy: 1e-12)
            XCTAssertEqual(split.arrangedSubviews.count, 2)
            XCTAssertTrue(split.arrangedSubviews.allSatisfy { $0.frame.height > 0 })
        }
        XCTAssertEqual(split.arrangedSubviews[1].frame.height, 72, accuracy: 1)
    }

    @MainActor
    func testSharedDesignWindowsSynchronizeNativeDividerChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = makeWindow(state: fixture.state, program: fixture.program)
        let second = makeWindow(state: fixture.state, program: fixture.program)
        defer { close(first); close(second) }
        second.setContentSize(NSSize(width: 410, height: 1000))
        let firstHost = try XCTUnwrap(first.contentView), secondHost = try XCTUnwrap(second.contentView)
        let firstSplit = try await nativeSplit(in: firstHost)
        let secondSplit = try await nativeSplit(in: secondHost)
        firstSplit.setPosition((firstSplit.bounds.height - firstSplit.dividerThickness) * 0.55, ofDividerAt: 0)
        await settle(firstHost)
        await settle(secondHost)
        XCTAssertEqual(fixture.state.partsPaneFraction, 0.55, accuracy: 0.002)
        assertFraction(0.55, in: firstSplit)
        assertFraction(0.55, in: secondSplit)
    }

    @MainActor
    func testReplacingProjectResetsFractionWithoutReplacingNativePaneHosts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.state.setPartsPaneFraction(0.42)
        let window = makeWindow(state: fixture.state, program: fixture.program)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let split = try await nativeSplit(in: host)
        let originalProjectID = fixture.state.projectEditingID
        let originalHosts = split.arrangedSubviews.flatMap(\.subviews).map(ObjectIdentifier.init)
        assertFraction(0.42, in: split)
        fixture.state.newProject()
        await settle(host)
        let updated = try await nativeSplit(in: host)
        XCTAssertNotEqual(fixture.state.projectEditingID, originalProjectID)
        XCTAssertTrue(updated === split)
        XCTAssertEqual(split.arrangedSubviews.flatMap(\.subviews).map(ObjectIdentifier.init), originalHosts)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        assertFraction(0.75, in: split)
        XCTAssertEqual(fixture.state.partsPaneFraction, 0.75)
        XCTAssertNil(fixture.state.current)
        await fixture.state.prepareToQuit()
    }

    @MainActor
    private func nativeSplit(in host: NSView) async throws -> ProjectSidebarNativeSplitView {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let split = descendants(host).compactMap({ $0 as? ProjectSidebarNativeSplitView }).first,
               split.bounds.height > 50, split.arrangedSubviews.count == 2 { return split }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LADError.message("The native fixed sidebar did not mount its two panes.")
    }

    @MainActor
    private func assertFraction(_ fraction: Double, in split: NSSplitView,
                                file: StaticString = #filePath, line: UInt = #line) {
        let available = split.bounds.height - split.dividerThickness
        XCTAssertEqual(split.arrangedSubviews[0].frame.height, available * CGFloat(fraction), accuracy: 1, file: file, line: line)
        XCTAssertEqual(split.arrangedSubviews[1].frame.height, available * CGFloat(1 - fraction), accuracy: 1, file: file, line: line)
    }

    @MainActor
    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func makeWindow(state: AppState, program: Expansion) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 340, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 800))
        container.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: Harness(state: state, program: program))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.contentMinSize = NSSize(width: 200, height: 100)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func close(_ window: NSWindow) { window.orderOut(nil); window.contentView = nil; window.close() }

    @MainActor
    private final class Expansion: ObservableObject { @Published var value = false }

    private struct Harness: View {
        @ObservedObject var state: AppState
        @ObservedObject var program: Expansion
        var body: some View { ProjectSidebarSplitView(state: state, isProgramExpanded: $program.value) }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let state: AppState
        let program = Expansion()
        let policy: NSApplication.ActivationPolicy

        init(empty: Bool = false) throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for native sidebar sizing tests.") }
            let app = NSApplication.shared
            policy = app.activationPolicy()
            app.setActivationPolicy(.regular)
            app.finishLaunching()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-sidebar-native-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
            if !empty {
                let parts = [PartNode(id: "body", name: "Body", solidIndices: [0])]
                var preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0,0,0,1,1,1],
                    volume: 1, area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
                    stepPath: directory.appendingPathComponent("preview").path, parts: parts)
                preview.topology = CADTopology(vertices: [], edges: [], faces: [], parts: [
                    CADPart(solidIndex: 0, area: 6, volume: 1, bounds: [0,0,0,1,1,1], centroid: [0.5,0.5,0.5])])
                let revision = ProjectRevision(model: .bracket, preview: preview, parts: parts)
                state.revisions = [revision]
                state.selectedRevisionID = revision.id
                state.mesh = preview
            }
        }

        func cleanUp() {
            state.cancel()
            NSApplication.shared.setActivationPolicy(policy)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
