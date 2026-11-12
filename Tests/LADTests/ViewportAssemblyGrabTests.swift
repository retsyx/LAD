import AppKit
import Combine
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportAssemblyGrabTests: XCTestCase {
    @MainActor
    func testCommandGrabUsesOriginalHitAndFrozenRolledProjectionWithoutSelectingFeatures() async throws {
        for projection in ViewportProjectionMode.allCases {
            let view = try makeView()
            let preview = mesh()
            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                        selectedSolids: [0], hiddenSolids: [], projection: projection,
                        solidTransforms: [0: translation(4, 3)])
            try view.configureAgentView(named: "top", camera: .init(rollDegrees: 31))
            try await ready(view)
            let camera = try XCTUnwrap(view.pointOfView).simdTransform
            let start = projected([4, 3, 0], in: view)
            var begins = 0, ends = 0, cancellations = 0, selections = 0
            var moves = [[Double]]()
            view.assemblyGrabbingEnabled = true
            view.onSelectionChanged = { _ in selections += 1 }
            view.onFeatureSelectionChanged = { _ in selections += 1 }
            view.onAssemblyGrabBegan = { [weak view] solid, original, snapshot in
                guard let view else { return false }
                begins += 1
                XCTAssertEqual(solid, 0)
                for coordinate in original { XCTAssertEqual(coordinate, 0, accuracy: 0.0001) }
                do { try snapshot.validate() }
                catch { XCTFail("Invalid grab projection: \(error)"); return false }
                let samples: [[Double]] = [[4, 3, 0], [8, 7, 0], [-2, -1, 2]]
                for point in samples {
                    let expected = self.projected(point, in: view)
                    let actual = snapshot.project(point)
                    XCTAssertEqual(actual?[0] ?? .nan, Double(expected.x), accuracy: 0.0001)
                    XCTAssertEqual(actual?[1] ?? .nan, Double(expected.y), accuracy: 0.0001)
                }
                return true
            }
            view.onAssemblyGrabMoved = { moves.append($0) }
            view.onAssemblyGrabEnded = { ends += 1 }
            view.onAssemblyGrabCancelled = { cancellations += 1 }
            view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view, modifiers: .command))
            XCTAssertTrue(view.isGrabbingAssembly)
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: start.offset(x: 2), in: view))
            XCTAssertTrue(moves.isEmpty, "A small Command click must not move the mechanism.")
            let moved = start.offset(x: 5, y: 2)
            let drag = try mouse(.leftMouseDragged, at: moved, in: view)
            XCTAssertEqual(drag.deltaX, 0); XCTAssertEqual(drag.deltaY, 0)
            view.mouseDragged(with: drag)
            XCTAssertEqual(moves, [[Double(moved.x), Double(moved.y)]])
            let released = start.offset(x: 9, y: 3)
            view.mouseUp(with: try mouse(.leftMouseUp, at: released, in: view))
            XCTAssertEqual(moves.last, [Double(released.x), Double(released.y)], "Release must deliver its newest target before ending.")
            XCTAssertEqual(begins, 1); XCTAssertEqual(ends, 1); XCTAssertEqual(cancellations, 0)
            XCTAssertEqual(selections, 0)
            XCTAssertFalse(view.isGrabbingAssembly)
            XCTAssertEqual(try XCTUnwrap(view.pointOfView).simdTransform, camera)
            _ = view.resignFirstResponder()
            XCTAssertEqual(cancellations, 0, "Normal release must leave the final pending solve alive.")
        }
    }

    @MainActor
    func testRejectedAndEmptyCommandGrabsPreserveSelectionAndOrdinaryClickStillPicks() async throws {
        let view = try makeView()
        let preview = mesh()
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [0], hiddenSolids: [])
        try await ready(view)
        let point = projected([0, 0, 0], in: view)
        var begins = 0, moves = 0, ends = 0, cancellations = 0, selections = 0
        view.assemblyGrabbingEnabled = true
        view.onAssemblyGrabBegan = { _, _, _ in begins += 1; return false }
        view.onAssemblyGrabMoved = { _ in moves += 1 }
        view.onAssemblyGrabEnded = { ends += 1 }
        view.onAssemblyGrabCancelled = { cancellations += 1 }
        view.onFeatureSelectionChanged = { _ in selections += 1 }
        for start in [point, NSPoint(x: 1, y: 1)] {
            view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view, modifiers: .command))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: start.offset(x: 30), in: view))
            view.mouseUp(with: try mouse(.leftMouseUp, at: start.offset(x: 30), in: view))
        }
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(moves, 0); XCTAssertEqual(ends, 0); XCTAssertEqual(cancellations, 0); XCTAssertEqual(selections, 0)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point, in: view))
        XCTAssertEqual(selections, 1, "Normal clicks must retain native feature selection.")
    }

    @MainActor
    func testPoseUpdatesContinueGrabWhileReplacementVisibilityProjectionAndEscapeCancelIt() async throws {
        for reason in ["replacement", "hidden", "projection", "camera", "resize", "escape", "disabled", "deactivated", "detached"] {
            let view = try makeView()
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.contentView = nil; window.close() }
            let preview = mesh()
            let selected: Set<Int> = reason == "escape" ? [0] : []
            let features: [CADFeatureID] = reason == "escape" ? [.init(kind: .face, solidIndex: 0, localIndex: 0)] : []
            view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top), selectedSolids: selected,
                        hiddenSolids: [], selectedFeatures: features)
            try await ready(view)
            let start = projected([0, 0, 0], in: view)
            var cancellations = 0, ends = 0, cleared = false
            var selectedParts: Set<Int> = selected
            var selectedFeatures = features
            view.onSelectionChanged = { selectedParts = $0 }
            view.onFeatureSelectionChanged = { selectedFeatures = $0 }
            view.onDeselectAll = { cleared = true }
            view.assemblyGrabbingEnabled = true
            view.onAssemblyGrabBegan = { _, _, _ in true }
            view.onAssemblyGrabCancelled = { cancellations += 1 }
            view.onAssemblyGrabEnded = { ends += 1 }
            view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view, modifiers: .command))
            XCTAssertTrue(view.isGrabbingAssembly, reason)
            view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: selected, hiddenSolids: [],
                        selectedFeatures: features, solidTransforms: [0: translation(1, 0)])
            XCTAssertTrue(view.isGrabbingAssembly, "Publishing a solved pose must retain the grab.")
            switch reason {
            case "replacement":
                var replacement = preview; replacement.stepPath += "-replacement"
                view.update(mesh: replacement, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
            case "hidden": view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [0])
            case "projection": view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [], projection: .isometric)
            case "camera": view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.right), selectedSolids: [], hiddenSolids: [])
            case "resize": view.setFrameSize(NSSize(width: 700, height: 500)); view.layout()
            case "escape": view.keyDown(with: try key(53, characters: "\u{1b}"))
            case "disabled": view.assemblyGrabbingEnabled = false
            case "deactivated": NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            case "detached": window.contentView = nil
            default: XCTFail(reason)
            }
            XCTAssertFalse(view.isGrabbingAssembly, reason)
            XCTAssertEqual(cancellations, 1, reason)
            if reason == "escape" {
                XCTAssertTrue(cleared)
                XCTAssertTrue(selectedParts.isEmpty)
                XCTAssertTrue(selectedFeatures.isEmpty)
            }
            view.mouseUp(with: try mouse(.leftMouseUp, at: start.offset(x: 10), in: view))
            XCTAssertEqual(ends, 0, "Cancellation must invalidate the old release: \(reason).")
        }
    }

    @MainActor
    func testRightAndMiddleGesturesCannotNavigateDuringGrab() async throws {
        let view = try makeView()
        view.update(mesh: mesh(), mode: .edges, grid: false, command: ViewportCommand(.top), selectedSolids: [], hiddenSolids: [])
        try await ready(view)
        view.assemblyGrabbingEnabled = true
        view.onAssemblyGrabBegan = { _, _, _ in true }
        let point = projected([0, 0, 0], in: view)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point, in: view, modifiers: .command))
        let camera = try XCTUnwrap(view.pointOfView).simdTransform
        view.rightMouseDown(with: try mouse(.rightMouseDown, at: point, in: view))
        view.rightMouseDragged(with: try mouse(.rightMouseDragged, at: point.offset(x: 40), in: view))
        view.otherMouseDown(with: try mouse(.otherMouseDown, at: point, in: view))
        view.otherMouseDragged(with: try mouse(.otherMouseDragged, at: point.offset(x: 40), in: view))
        XCTAssertTrue(view.isGrabbingAssembly)
        XCTAssertEqual(try XCTUnwrap(view.pointOfView).simdTransform, camera)
        view.mouseUp(with: try mouse(.leftMouseUp, at: point, in: view))
    }

    @MainActor
    func testCommandDragAfterIdleMovesPreparedGeometryInFreshLiveFrames() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for live assembly grabbing.") }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        XCTAssertTrue(app.setActivationPolicy(.regular))
        defer { _ = app.setActivationPolicy(policy) }
        app.finishLaunching()
        let view = try makeView()
        let frames = ViewportRenderCounter(view)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD constrained grab test"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let preview = mesh()
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top), selectedSolids: [], hiddenSolids: [])
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded(); view.layout()
        try await ready(view)
        try await waitUntil { frames.count > 0 && !view.hasPendingFrames }
        let count = frames.count
        let camera = try XCTUnwrap(view.pointOfView).simdTransform
        let geometry = view.scene.rootNode.childNode(withName: "solid:0", recursively: true)?.geometry
        let before = try await CADAgentRenderer.capturePNG(view: view)
        view.assemblyGrabbingEnabled = true
        view.onAssemblyGrabBegan = { _, _, _ in true }
        let grabbedTransform = translation(4, 0)
        view.onAssemblyGrabMoved = { [weak view] _ in
            view?.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [],
                        solidTransforms: [0: grabbedTransform])
        }
        let point = projected([0, 0, 0], in: view)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point, in: view, modifiers: .command))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: point.offset(x: 40), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point.offset(x: 40), in: view))
        try await waitUntil { frames.count > count && !view.hasPendingFrames }
        XCTAssertEqual(try XCTUnwrap(view.pointOfView).simdTransform, camera)
        XCTAssertTrue(view.scene.rootNode.childNode(withName: "solid:0", recursively: true)?.geometry === geometry)
        let after = try await CADAgentRenderer.capturePNG(view: view)
        XCTAssertNotEqual(after, before)
        XCTAssertFalse(view.hasPendingFrames)
    }

    @MainActor
    func testHostedCommandGrabDrivesRealJointPickingMeasurementsAndPortableSave() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for native constrained grabbing.")
        }
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for native constrained grabbing.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-native-grab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ModelSpec(title: "Grabbable arm", summary: "A hinged arm", units: "mm", script: """
        result = cq.Assembly(name='Mechanism')
        result.add(cq.Solid.makeBox(4,4,2).translate((-16,-2,-2)),name='Base',metadata={'lad_id':'base'})
        result.add(cq.Solid.makeBox(16,4,2).translate((0,-2,0)),name='Arm',metadata={'lad_id':'arm'})
        result.metadata['lad_motion']={'grounded':['base'],'connectors':[
          {'id':'a','part':'base','origin':[0,0,0]}, {'id':'b','part':'arm','origin':[0,0,0]}],
          'joints':[{'id':'hinge','type':'revolute','parent':'a','child':'b','limits':[-100,100]}]}
        """)
        let preview = try await EngineService(temporaryDirectory: directory).buildPreview(model, python: EngineService.defaultPython, threads: 2)
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory), python: EngineService.defaultPython,
                             thumbnailRenderer: { _, _ in throw CancellationError() })
        defer { state.cancel() }
        state.newProjectWithSubmittedRequest()
        let revision = ProjectRevision(model: model, preview: preview, parts: preview.parts)
        state.revisions = [revision]; state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        let arm = try XCTUnwrap(preview.parts?.flatMap(\.flattened).first { $0.id == "arm" }?.solidIndices.first)
        state.selectParts([arm])
        let owner = UUID()
        let view = try makeView()
        view.assemblyGrabbingEnabled = state.canManipulateAssembly
        view.onAssemblyGrabBegan = { [weak state] solid, point, projection in
            state?.beginAssemblyGrab(ownerID: owner, solidIndex: solid, point: point, projection: projection) ?? false
        }
        view.onAssemblyGrabMoved = { [weak state] point in state?.moveAssemblyGrab(ownerID: owner, screenPoint: point) }
        view.onAssemblyGrabEnded = { [weak state] in state?.endAssemblyGrab(ownerID: owner) }
        view.onAssemblyGrabCancelled = { [weak state] in state?.cancelAssemblyGrab(ownerID: owner) }
        view.onSelectionChanged = { [weak state] in state?.selectParts($0) }
        view.onFeatureSelectionChanged = { [weak state] in state?.selectFeatures($0) }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        XCTAssertTrue(app.setActivationPolicy(.regular))
        defer { _ = app.setActivationPolicy(policy) }
        app.finishLaunching()
        let frames = ViewportRenderCounter(view)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD native mechanism grab test"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: state.selectedSolids, hiddenSolids: [], solidTransforms: state.assemblyPose?.solidTransforms ?? [:])
        let subscription = ObservationRecorder({ state.assemblyPose }) { [weak state, weak view] pose in
            guard let state, let view else { return }
            view.update(mesh: state.mesh, mode: .edges, grid: false, command: nil,
                        selectedSolids: state.selectedSolids, hiddenSolids: state.hiddenSolids,
                        selectedFeatures: state.selectedFeatures, solidTransforms: pose?.solidTransforms ?? [:])
        }
        defer { subscription.cancel() }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.displayIfNeeded(); view.layout()
        try await ready(view)
        try await waitUntil { frames.count > 0 && !view.hasPendingFrames }
        let previousFrames = frames.count
        let surface = try XCTUnwrap(view.scene.rootNode.childNode(withName: "solid:\(arm)", recursively: true))
        let geometry = surface.geometry
        let camera = try XCTUnwrap(view.pointOfView).simdTransform
        let start = projected([12, 0, 2], in: view)
        let angle = 40.0 * Double.pi / 180
        let targetWorld = [12 * cos(angle), 12 * sin(angle), 2]
        let target = projected(targetWorld, in: view)
        view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view, modifiers: .command))
        XCTAssertTrue(view.isGrabbingAssembly); XCTAssertTrue(state.isGrabbingAssembly)
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: target, in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: target, in: view))
        try await waitUntil { !state.isSolvingAssembly }
        XCTAssertNil(state.assemblyMotionError)
        XCTAssertEqual(try XCTUnwrap(state.assemblyPose?.positions["hinge"]), 40, accuracy: 0.05)
        try await waitUntil { frames.count > previousFrames && !view.hasPendingFrames }
        XCTAssertTrue(surface.geometry === geometry)
        XCTAssertEqual(try XCTUnwrap(view.pointOfView).simdTransform, camera)
        XCTAssertEqual(state.selectedSolids, [arm]); XCTAssertTrue(state.selectedFeatures.isEmpty)
        XCTAssertEqual(view.feature(at: target)?.solidIndex, arm)
        XCTAssertEqual(view.feature(at: target)?.kind, .face)
        try await waitUntil { !state.isMeasuring && state.measurementReport != nil }
        XCTAssertNil(state.measurementError)
        let centroid = try XCTUnwrap(state.measurementReport?.metrics.first { $0.id == "parts:centroid" }?.values)
        XCTAssertEqual(centroid[0], 8 * cos(angle), accuracy: 0.01)
        XCTAssertEqual(centroid[1], 8 * sin(angle), accuracy: 0.01)
        XCTAssertEqual(centroid[2], 1, accuracy: 0.01)
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(try XCTUnwrap(saved.revisions.first?.jointPositions?["hinge"]), 40, accuracy: 0.05)
        XCTAssertEqual(saved.revisions.first?.model.script, model.script)
        XCTAssertNil(saved.revisions.first?.preview)
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    }

    @MainActor
    private func ready(_ view: CADSceneView) async throws { try await waitUntil { !view.isPreparingCaptureResources } }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw LADError.message("The assembly grab viewport did not reach its expected state.") }
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: CADSceneView,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func key(_ code: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @MainActor
    private func projected(_ point: [Double], in view: CADSceneView) -> NSPoint {
        let value = view.projectPoint(SCNVector3(point[0], point[1], point[2]))
        return NSPoint(x: CGFloat(value.x), y: CGFloat(value.y))
    }

    private func translation(_ x: Double, _ y: Double) -> [Double] {
        [1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, 0, 0, 0, 0, 1]
    }

    private func mesh() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-10, -10, 0], [10, -10, 0], [10, 10, 0], [-10, 10, 0]],
            triangles: [[0, 1, 2], [0, 2, 3]], edges: [[-10, -10, 0, 10, -10, 0]],
            bounds: [-10, -10, 0, 10, 10, 0], volume: 1, area: 400, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-assembly-grab", triangleSolids: [0, 0], edgeSolids: [0])
        preview.topology = CADTopology(vertices: [], edges: [],
            faces: [CADFace(id: .init(kind: .face, solidIndex: 0, localIndex: 0), type: "PLANE", area: 400, center: [0, 0, 0])], parts: [])
        preview.triangleFaces = [0, 0]
        return preview
    }
}

private extension NSPoint {
    func offset(x: CGFloat = 0, y: CGFloat = 0) -> NSPoint { NSPoint(x: self.x + x, y: self.y + y) }
}


