import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class PartsSidebarInteractionTests: XCTestCase {
    @MainActor
    func testPlainLeftClickSelectsAndDeselectsRenderedPartRow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(state: fixture.state)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        try click(try await rowFrames(in: host)["base"], in: host)
        try await assertSelection([0], nodeIDs: ["base"], state: fixture.state, in: host)
        XCTAssertEqual(fixture.state.measurementReport?.solidIndices, [0])
        try click(try await rowFrames(in: host)["base"], in: host)
        try await assertSelection([], nodeIDs: [], state: fixture.state, in: host)
        XCTAssertFalse(fixture.state.hasMeasurementSelection)
        XCTAssertNil(fixture.state.measurementReport, "Deselecting the last part must clear its measurements.")

        try click(try await rowFrames(in: host)["base"], in: host)
        try await assertSelection([0], nodeIDs: ["base"], state: fixture.state, in: host)
        try click(try await rowFrames(in: host)["board"], in: host)
        try await assertSelection([0, 2], nodeIDs: ["base", "board"], state: fixture.state, in: host)
        XCTAssertEqual(fixture.state.measurementReport?.solidIndices, [0, 2],
                       "A plain click on an unselected row must preserve the previous selection.")
    }

    @MainActor
    func testPlainLeftClickRemovesOnlyClickedPartFromMultipleSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Prepare a multi-selection, then exercise the rendered row's actual
        // unmodified click action rather than calling the selection API again.
        fixture.state.selectPartNodes(["base", "lid", "board"])
        let window = makeWindow(state: fixture.state)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        try await assertSelection([0, 1, 2], nodeIDs: ["base", "lid", "board"], state: fixture.state, in: host)

        try click(try await rowFrames(in: host)["lid"], in: host)
        try await assertSelection([0, 2], nodeIDs: ["base", "board"], state: fixture.state, in: host)
        XCTAssertEqual(fixture.state.measurementReport?.solidIndices, [0, 2])
        XCTAssertTrue(fixture.state.hasMeasurementSelection)
        XCTAssertTrue(fixture.state.hiddenSolids.isEmpty, "The row click must not activate its neighboring visibility button.")
    }

    @MainActor
    func testPlainLeftClickRemovesChildSelectedThroughRenderedFolderRow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(state: fixture.state)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        try click(try await rowFrames(in: host)["case"], in: host)
        try await assertSelection([0, 1], nodeIDs: ["case"], state: fixture.state, in: host)
        try click(try await rowFrames(in: host)["base"], in: host)
        try await assertSelection([1], nodeIDs: ["lid"], state: fixture.state, in: host)
        XCTAssertEqual(fixture.state.measurementReport?.solidIndices, [1])
        XCTAssertTrue(fixture.state.isPartFolderExpanded("case"), "Selecting the folder must not click its disclosure control.")
    }

    @MainActor
    func testShiftClickSelectsRenderedPartRangeInEitherDirection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(state: fixture.state)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        for (selected, clicked) in [("base", "board"), ("board", "base")] {
            fixture.state.selectPartNodes([selected])
            try click(try await rowFrames(in: host)[clicked], in: host, modifiers: .shift)
            try await assertSelection([0, 1, 2], nodeIDs: ["base", "lid", "board"], state: fixture.state, in: host)
            XCTAssertEqual(fixture.state.measurementReport?.solidIndices, [0, 1, 2])
        }
        XCTAssertTrue(fixture.state.hiddenSolids.isEmpty)
        XCTAssertTrue(fixture.state.isPartFolderExpanded("case"))
    }

    @MainActor
    func testShiftClickDeselectsRenderedPartRangeInEitherDirection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = makeWindow(state: fixture.state)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        for (selected, clicked) in [(Set(["base", "lid"]), "base"), (Set(["lid", "board"]), "board")] {
            fixture.state.selectPartNodes(selected)
            try click(try await rowFrames(in: host)[clicked], in: host, modifiers: .shift)
            try await assertSelection([], nodeIDs: [], state: fixture.state, in: host)
            XCTAssertFalse(fixture.state.hasMeasurementSelection)
            XCTAssertNil(fixture.state.measurementReport)
        }
    }

    @MainActor
    func testShiftClickPreservesSelectedPartsOutsideRenderedRange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.state.selectPartNodes(["base", "board"])
        let window = makeWindow(state: fixture.state)
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)

        try click(try await rowFrames(in: host)["board"], in: host, modifiers: .shift)
        try await assertSelection([0], nodeIDs: ["base"], state: fixture.state, in: host)
        XCTAssertEqual(fixture.state.measurementReport?.solidIndices, [0])
    }

    @MainActor
    func testNativeTextDropsMatchingPartIDsCannotReorganizeTheSidebar() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.state.selectPartNodes(["lid"])
        var opened: [URL] = []
        let window = makeWindow(state: fixture.state, onProjectDrop: { opened.append($0) })
        defer { close(window) }
        let host = try XCTUnwrap(window.contentView)
        let rows = try await rowFrames(in: host)
        let folderFrame = try XCTUnwrap(rows["case"])
        let anchor = try XCTUnwrap(descendants(host).compactMap { $0 as? ProjectFileDropAnchor }.first)
        let surface = try XCTUnwrap(anchor.contentDropSurface)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let sender = PartsTextDraggingInfo(pasteboard: board)
        sender.draggingDestinationWindow = window

        let originalTree = fixture.state.partTree
        let originalModel = fixture.state.current
        let originalRevisionIDs = fixture.state.revisions.map(\.id)
        let originalRevisionID = fixture.state.selectedRevisionID
        let originalSolids = fixture.state.selectedSolids
        let originalNodeIDs = fixture.state.selectedPartNodeIDs
        let originalFeatures = fixture.state.selectedFeatures
        let originalError = fixture.state.error
        let headerPoint = NSPoint(x: host.bounds.midX,
                                  y: host.isFlipped ? 24 : host.bounds.height - 24)
        let folderPoint = NSPoint(x: folderFrame.midX, y: folderFrame.midY)

        // A generic text handler must not interpret these real stable IDs
        // as a request to move local parts, regardless of the drag's origin.
        for (text, point) in [("base", headerPoint), ("board", folderPoint)] {
            board.clearContents()
            XCTAssertTrue(board.writeObjects([text as NSString]))
            XCTAssertTrue(board.setString(text, forType: NSPasteboard.PasteboardType("public.text")))
            XCTAssertTrue(board.setData(Data(text.utf8), forType: NSPasteboard.PasteboardType("public.data")))
            // SwiftUI can install native drop destinations outside the normal
            // mouse hit ancestry. Reject text there as well as at the overlay.
            let textDestinations = descendants(host).filter { view in
                !(view is ProjectFileDropView) && !view.isHiddenOrHasHiddenAncestor &&
                    host.convert(view.bounds, from: view).contains(point) &&
                    board.availableType(from: view.registeredDraggedTypes) != nil
            }
            XCTAssertTrue(textDestinations.isEmpty, "Parts must not register a text drop destination: \(text)")
            sender.draggingSequenceNumber += 1
            sender.draggingLocation = host.convert(point, to: nil)
            XCTAssertEqual(surface.draggingEntered(sender), [], text)
            XCTAssertEqual(surface.draggingUpdated(sender), [], text)
            XCTAssertFalse(surface.prepareForDragOperation(sender), text)
            XCTAssertFalse(surface.performDragOperation(sender), text)
            surface.draggingEnded(sender)
            // A text provider can deliver asynchronously after native drop
            // callbacks return. Give it time to expose an accidental edit.
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(fixture.state.partTree, originalTree, text)
            XCTAssertEqual(fixture.state.current, originalModel, text)
            XCTAssertEqual(fixture.state.revisions.map(\.id), originalRevisionIDs, text)
            XCTAssertEqual(fixture.state.selectedRevisionID, originalRevisionID, text)
            XCTAssertEqual(fixture.state.selectedSolids, originalSolids, text)
            XCTAssertEqual(fixture.state.selectedPartNodeIDs, originalNodeIDs, text)
            XCTAssertEqual(fixture.state.selectedFeatures, originalFeatures, text)
            XCTAssertEqual(fixture.state.error, originalError, text)
            XCTAssertTrue(opened.isEmpty, "Text drops must not open a design.")
        }
    }

    @MainActor
    private func rowFrames(in host: NSView) async throws -> [String: NSRect] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let document = descendants(host).compactMap({ $0 as? NSScrollView }).first?.documentView {
                var frames = [NSRect]()
                for leaf in descendants(document) where leaf.subviews.isEmpty && !leaf.isHiddenOrHasHiddenAncestor {
                    let frame = host.convert(leaf.bounds, from: leaf)
                    // Main row buttons span the pane; disclosure and visibility
                    // buttons are narrow. Deduplicate native focus decorations.
                    guard frame.width > 120, frame.height >= 20, frame.height <= 45,
                          host.bounds.intersects(frame), !frames.contains(where: { approximatelyEqual($0, frame) }) else { continue }
                    frames.append(frame)
                }
                var rows = [[NSRect]]()
                for frame in frames {
                    if let row = rows.firstIndex(where: { abs($0[0].midY - frame.midY) < 1 }) {
                        rows[row].append(frame)
                    } else { rows.append([frame]) }
                }
                // The narrower rendered control is the name/select button;
                // a surrounding row can span its visibility button as well.
                let buttons = rows.compactMap { $0.min { $0.width < $1.width } }.sorted {
                    host.isFlipped ? $0.midY < $1.midY : $0.midY > $1.midY
                }
                if buttons.count == 4 {
                    return Dictionary(uniqueKeysWithValues: zip(["case", "base", "lid", "board"], buttons))
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let diagnostic = descendants(host).map {
            "\(String(describing: type(of: $0))) frame=\($0.frame) inHost=\(host.convert($0.bounds, from: $0)) label=\($0.accessibilityLabel() ?? "")"
        }.joined(separator: "\n")
        try? diagnostic.write(toFile: "/private/tmp/lad-parts-sidebar-native.txt", atomically: true, encoding: .utf8)
        throw LADError.message("The native Parts pane did not expose the four rendered row buttons. See /private/tmp/lad-parts-sidebar-native.txt.")
    }

    @MainActor
    private func click(_ frame: NSRect?, in host: NSView, modifiers: NSEvent.ModifierFlags = []) throws {
        let frame = try XCTUnwrap(frame)
        let window = try XCTUnwrap(host.window)
        window.makeKey()
        let location = host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        XCTAssertNotNil(host.hitTest(host.convert(location, from: nil)), "The rendered Parts row must have a native hit target.")
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        XCTAssertEqual(down.modifierFlags, modifiers)
        // Queue release first in case AppKit tracks the down synchronously.
        // These events stay inside this test application's native event loop.
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.sendEvent(down)
        if let release = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(release)
        }
    }

    @MainActor
    private func assertSelection(_ solids: Set<Int>, nodeIDs: Set<String>, state: AppState, in host: NSView,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while (state.selectedSolids != solids || state.selectedPartNodeIDs != nodeIDs), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.selectedSolids, solids, file: file, line: line)
        XCTAssertEqual(state.selectedPartNodeIDs, nodeIDs, file: file, line: line)
        XCTAssertFalse(state.isWorking, "Parts clicks must not start CAD or Codex work.", file: file, line: line)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
    }

    private func approximatelyEqual(_ first: NSRect, _ second: NSRect) -> Bool {
        abs(first.minX - second.minX) < 1 && abs(first.minY - second.minY) < 1 &&
            abs(first.width - second.width) < 1 && abs(first.height - second.height) < 1
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func makeWindow(state: AppState, onProjectDrop: (@MainActor (URL) -> Void)? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 340, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LAD Parts interaction test"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: PartsSidebar(state: state).overlay {
            if let onProjectDrop { ProjectFileDropTarget(onDrop: onProjectDrop) }
        })
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
        let directory: URL
        let state: AppState
        let previousPolicy: NSApplication.ActivationPolicy

        init() throws {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for native Parts interaction tests.") }
            let application = NSApplication.shared
            previousPolicy = application.activationPolicy()
            application.setActivationPolicy(.regular)
            application.finishLaunching()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-parts-interaction-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let parts = [PartNode(id: "case", name: "Case", solidIndices: [], children: [
                PartNode(id: "base", name: "Base", solidIndices: [0]),
                PartNode(id: "lid", name: "Lid", solidIndices: [1])]),
                PartNode(id: "board", name: "Board", solidIndices: [2])]
            var preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 3, 1, 1],
                volume: 3, area: 18, solids: 3, faces: 18, buildSeconds: 0, threads: 1,
                stepPath: directory.appendingPathComponent("selection-preview").path, parts: parts)
            preview.topology = CADTopology(vertices: [], edges: [], faces: [], parts: (0..<3).map { index in
                CADPart(solidIndex: index, area: 6, volume: 1,
                        bounds: [Double(index), 0, 0, Double(index + 1), 1, 1], centroid: [Double(index) + 0.5, 0.5, 0.5])
            })
            let revision = ProjectRevision(model: ModelSpec(title: "Parts interaction fixture", summary: "Native row clicks",
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

@MainActor
private final class PartsTextDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any? = nil
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        for (index, object) in objects.enumerated() {
            guard let writer = object as? any NSPasteboardWriting else { continue }
            var stop: ObjCBool = false
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
}
