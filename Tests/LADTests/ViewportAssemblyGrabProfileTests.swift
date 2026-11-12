import AppKit
import Combine
import SceneKit
import simd
import XCTest
@testable import LAD

/// Opt-in native interaction measurement; no machine-specific timing limits.
final class ViewportAssemblyGrabProfileTests: XCTestCase {
    @MainActor
    func testProfileRepresentativeAssemblyCommandGrab() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_ASSEMBLY_GRAB_PROFILE_PREVIEW"] else {
            throw XCTSkip("Set LAD_ASSEMBLY_GRAB_PROFILE_PREVIEW to the native 64-part moving-assembly fixture.")
        }
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Live assembly profiling requires an awake display.") }
        var preview = try JSONDecoder().decode(PreviewMesh.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let request = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("request.json")
        let model = try JSONDecoder().decode(ModelSpec.self, from: Data(contentsOf: request))
        let motion = try XCTUnwrap(preview.assemblyMotion)
        let parts = try XCTUnwrap(preview.parts)
        preview.assemblyPose = try motion.solve(parts: parts)
        let body = try XCTUnwrap(parts.flatMap(\.flattened).first { $0.id == "part-27" }?.solidIndices.first)
        let part = try XCTUnwrap(preview.topology?.parts.first { $0.solidIndex == body })
        let connectorIDs = Set(motion.connectors.filter { $0.part == "part-27" }.map(\.id))
        let joint = try XCTUnwrap(motion.joints.first { connectorIDs.contains($0.child) && $0.type == .revolute })
        let original = [part.centroid[0] + 4, part.centroid[1] + 2, part.centroid[2] + 3]
        let initialWorld = AssemblySolidTransform.point(original, by: preview.assemblyPose?.solidTransforms[body] ?? AssemblyPose.identityTransform)
        let counter = AssemblyGrabProfileCounter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-grab-profile-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory),
            thumbnailRenderer: { _, _ in throw CancellationError() }, assemblyGrabSolver: { context, positions, target in
                let started = ProcessInfo.processInfo.systemUptime
                let pose = try context.solve(positions: positions, screenPoint: target)
                counter.solved(target: target, matrix: pose.solidTransforms[body] ?? AssemblyPose.identityTransform,
                               started: started, completed: ProcessInfo.processInfo.systemUptime)
                return pose
            })
        defer { state.cancel() }
        let revision = ProjectRevision(model: model, preview: preview, parts: parts)
        state.revisions = [revision]; state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let owner = UUID()
        view.assemblyGrabbingEnabled = state.canManipulateAssembly
        view.onAssemblyGrabBegan = { [weak state] solid, point, projection in
            state?.beginAssemblyGrab(ownerID: owner, solidIndex: solid, point: point, projection: projection) ?? false
        }
        view.onAssemblyGrabMoved = { [weak state] in state?.moveAssemblyGrab(ownerID: owner, screenPoint: $0) }
        view.onAssemblyGrabEnded = { [weak state] in state?.endAssemblyGrab(ownerID: owner) }
        view.onAssemblyGrabCancelled = { [weak state] in state?.cancelAssemblyGrab(ownerID: owner) }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        XCTAssertTrue(app.setActivationPolicy(.regular))
        defer { _ = app.setActivationPolicy(policy) }
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD assembly grab profile"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.delegate = nil; window.orderOut(nil); window.contentView = nil; window.close() }
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top), selectedSolids: [], hiddenSolids: [],
                    solidTransforms: state.assemblyPose?.solidTransforms ?? [:])
        try await waitUntil { !view.isPreparingResources }
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "solid:\(body)", recursively: true))
        counter.bind(node)
        view.delegate = counter
        let geometry = node.geometry
        let camera = try XCTUnwrap(view.pointOfView).simdTransform
        let subscription = ObservationRecorder({ state.assemblyPose }) { [weak state, weak view] pose in
            guard let state, let view else { return }
            view.update(mesh: state.mesh, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [],
                        solidTransforms: pose?.solidTransforms ?? [:])
        }
        defer { subscription.cancel() }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.displayIfNeeded(); view.layout()
        try await waitUntil { !view.isPreparingCaptureResources && counter.count > 0 && !view.isPlaying }
        let beforeFrames = counter.count
        let start = projected(initialWorld, view: view)
        let coldStart = ProcessInfo.processInfo.systemUptime
        view.mouseDown(with: try mouse(.leftMouseDown, point: start, view: view, modifiers: .command))
        let coldPickup = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
        XCTAssertTrue(state.isGrabbingAssembly)
        view.mouseUp(with: try mouse(.leftMouseUp, point: start, view: view))
        let warmStart = ProcessInfo.processInfo.systemUptime
        view.mouseDown(with: try mouse(.leftMouseDown, point: start, view: view, modifiers: .command))
        let warmPickup = (ProcessInfo.processInfo.systemUptime - warmStart) * 1_000
        XCTAssertTrue(state.isGrabbingAssembly)
        var finalPoint = start
        var eventCosts = [Double]()
        for index in 1...20 {
            let radians = (joint.position + Double(index) * 2) * .pi / 180
            let target = [part.centroid[0] + 4 * cos(radians) - 2 * sin(radians),
                          part.centroid[1] + 4 * sin(radians) + 2 * cos(radians), part.centroid[2] + 3]
            finalPoint = projected(target, view: view)
            let started = ProcessInfo.processInfo.systemUptime
            counter.input([Double(finalPoint.x), Double(finalPoint.y)], time: started)
            view.mouseDragged(with: try mouse(.leftMouseDragged, point: finalPoint, view: view))
            eventCosts.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            try await Task.sleep(for: .milliseconds(20))
        }
        view.mouseUp(with: try mouse(.leftMouseUp, point: finalPoint, view: view))
        try await waitUntil { !state.isSolvingAssembly && counter.count > beforeFrames && !view.isPlaying }
        XCTAssertNil(state.assemblyMotionError)
        XCTAssertEqual(try XCTUnwrap(state.assemblyPose?.positions[joint.id]), joint.position + 40, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(view.pointOfView).simdTransform, camera)
        XCTAssertTrue(node.geometry === geometry)
        let results = counter.results()
        XCTAssertGreaterThan(results.renderLatencies.count, 0, "At least one solved pointer target must reach an actual live frame.")
        let report: [String: Any] = [
            "solids": preview.solids, "faces": preview.faces, "triangles": preview.triangles.count,
            "edgeSegments": preview.edges.count, "coldPickupMS": coldPickup, "warmPickupMS": warmPickup,
            "pointerEventMS": summary(eventCosts), "solverMS": summary(results.solverCosts),
            "inputToRenderedPoseMS": summary(results.renderLatencies), "inputCount": results.inputs,
            "solveCount": results.solverCosts.count, "renderedPoseCount": results.renderLatencies.count,
            "unrenderedIntermediatePoses": results.pending
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "/tmp/lad-assembly-grab-profile.json"), options: .atomic)
        print("LAD assembly grab profile:", report)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw LADError.message("The live assembly profile did not reach its expected state.") }
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, point: NSPoint, view: CADSceneView,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func projected(_ point: [Double], view: CADSceneView) -> NSPoint {
        let p = view.projectPoint(SCNVector3(point[0], point[1], point[2]))
        return NSPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    private func summary(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        return ["count": Double(values.count), "meanMS": values.reduce(0, +) / Double(values.count),
                "p95MS": sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))], "maxMS": sorted.last!]
    }
}

private final class AssemblyGrabProfileCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private struct Input { var point: [Double]; var time: Double }
    private struct Pose { var matrix: [Float]; var inputTime: Double }
    private let lock = NSLock()
    private var node: SCNNode?
    private var frameCount = 0
    private var inputs = [Input]()
    private var pending = [Pose]()
    private var solverCosts = [Double]()
    private var renderLatencies = [Double]()
    var count: Int { lock.lock(); defer { lock.unlock() }; return frameCount }
    func bind(_ node: SCNNode) { lock.lock(); self.node = node; lock.unlock() }
    func input(_ point: [Double], time: Double) { lock.lock(); inputs.append(Input(point: point, time: time)); lock.unlock() }
    func solved(target: [Double], matrix: [Double], started: Double, completed: Double) {
        lock.lock(); defer { lock.unlock() }
        solverCosts.append((completed - started) * 1_000)
        if let input = inputs.last(where: { $0.point == target }) {
            pending.append(Pose(matrix: matrix.map(Float.init), inputTime: input.time))
        }
    }
    func results() -> (inputs: Int, solverCosts: [Double], renderLatencies: [Double], pending: Int) {
        lock.lock(); defer { lock.unlock() }
        return (inputs.count, solverCosts, renderLatencies, pending.count)
    }
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); let node = self.node; lock.unlock()
        let transform = node?.presentation.simdWorldTransform
        let rows = transform.map { m in (0..<16).map { m[$0 % 4][$0 / 4] } }
        let renderedAt = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        frameCount += 1
        guard let rows else { return }
        pending.removeAll { pose in
            guard zip(rows, pose.matrix).allSatisfy({ abs($0 - $1) <= 0.0001 }) else { return false }
            renderLatencies.append(max(0, renderedAt - pose.inputTime) * 1_000)
            return true
        }
    }
}
