import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

/// Opt in with LAD_VIEWPORT_PROFILE_PREVIEW pointing to a real worker
/// result.json. This records a baseline without imposing machine-specific
/// performance thresholds on the ordinary test suite.
final class ViewportInteractionProfileTests: XCTestCase {
    @MainActor
    func testProfileRealPreviewNavigationAndFeaturePicking() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_VIEWPORT_PROFILE_PREVIEW"], !path.isEmpty else {
            throw XCTSkip("Set LAD_VIEWPORT_PROFILE_PREVIEW to a native preview result.json to profile interaction.")
        }
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Live viewport profiling requires a window server.") }
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        defer { _ = application.setActivationPolicy(previousPolicy) }
        application.finishLaunching()
        let preview = try JSONDecoder().decode(PreviewMesh.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let display = ProcessInfo.processInfo.environment["LAD_VIEWPORT_PROFILE_DISPLAY"]
            .flatMap(ViewportDisplayMode.init(rawValue:)) ?? .edges
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 618, height: 770), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let frames = ViewportProfileFrameCounter()
        view.delegate = frames
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD viewport interaction profile"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.delegate = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let pose = try preview.assemblyMotion?.solve(parts: preview.parts ?? [])
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        view.update(mesh: preview, mode: display, grid: true, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .perspective,
                    solidTransforms: pose?.solidTransforms ?? [:])
        let synchronousInstallMS = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1_000
        view.layout()
        let deadline = ContinuousClock.now + .seconds(30)
        var preparationActorGapsMS = [Double]()
        var previousPreparationTick = preparationStarted
        while view.isPreparingResources, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            let now = ProcessInfo.processInfo.systemUptime
            preparationActorGapsMS.append((now - previousPreparationTick) * 1_000)
            previousPreparationTick = now
        }
        XCTAssertFalse(view.isPreparingResources)
        let preparationMS = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1_000
        let beforeFirst = frames.count
        while frames.count <= beforeFirst, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(frames.count, beforeFirst, "The real hosted SCNView must render before profiling input.")
        try await Task.sleep(for: .milliseconds(300))

        let initialCamera = view.agentCaptureMetadata["cameraTransform"] as? [Double]
        var dragCosts = [Double]()
        let startPoint = NSPoint(x: 240, y: 380)
        view.rightMouseDown(with: try mouse(.rightMouseDown, at: startPoint, in: view))
        frames.beginRecording()
        let firstDragFrame = frames.count
        let dragStart = ProcessInfo.processInfo.systemUptime
        var lastPoint = startPoint
        for index in 0..<60 {
            lastPoint = NSPoint(x: startPoint.x + CGFloat(index + 1) * 2,
                                y: startPoint.y + CGFloat(sin(Double(index + 1) * 0.12) * 30))
            let event = try mouse(.rightMouseDragged, at: lastPoint, in: view)
            let started = ProcessInfo.processInfo.systemUptime
            view.rightMouseDragged(with: event)
            dragCosts.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            if let transform = view.pointOfView?.simdWorldTransform {
                frames.recordInput(pose: viewportProfilePose(transform), at: started)
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        let dragElapsed = ProcessInfo.processInfo.systemUptime - dragStart
        let dragFrameCount = frames.count - firstDragFrame
        view.rightMouseUp(with: try mouse(.rightMouseUp, at: lastPoint, in: view))
        let frameMetrics = frames.finishRecording()
        XCTAssertNotEqual(view.agentCaptureMetadata["cameraTransform"] as? [Double], initialCamera)

        // Separate SceneKit's first surface-ray acceleration cost from the
        // projected-topology rebuild. The original combined cold baseline is
        // retained in the saved before.json artifact for comparison.
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let surfaceStart = ProcessInfo.processInfo.systemUptime
        let firstSurfaceHits = view.hitTest(center, options: [.categoryBitMask: 1, .ignoreHiddenNodes: false,
                                                             .searchMode: SCNHitTestSearchMode.closest.rawValue])
        let firstSurfaceCost = (ProcessInfo.processInfo.systemUptime - surfaceStart) * 1_000
        let coldStart = ProcessInfo.processInfo.systemUptime
        let cold = view.feature(at: center)
        let coldCost = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
        var warmCosts = [Double](), warmHits = 0
        var warmFeatures = [String]()
        let points = (0..<40).map { index in
            NSPoint(x: view.bounds.width * (0.1 + 0.8 * CGFloat(index % 8) / 7),
                    y: view.bounds.height * (0.15 + 0.7 * CGFloat(index / 8) / 4))
        }
        for point in points {
            let started = ProcessInfo.processInfo.systemUptime
            let feature = view.feature(at: point)
            if feature != nil { warmHits += 1 }
            warmFeatures.append(feature?.id ?? "")
            warmCosts.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        }

        var hoverCosts = [Double]()
        if ProcessInfo.processInfo.environment["LAD_VIEWPORT_PROFILE_HOVER"] != "0" {
            for point in points {
                let event = try mouse(.mouseMoved, at: point, in: view)
                let started = ProcessInfo.processInfo.systemUptime
                view.mouseMoved(with: event)
                hoverCosts.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                try await Task.sleep(for: .milliseconds(16))
            }
            view.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited,
                location: NSPoint(x: -1, y: -1), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)))
        }
        let topology = preview.topology
        let report: [String: Any] = [
            "previewPath": path,
            "displayMode": display.rawValue,
            "viewportPoints": [618, 770],
            "backingScale": window.backingScaleFactor,
            "synchronousInstallMS": synchronousInstallMS,
            "preparationMS": preparationMS,
            "preparationActorGaps": summary(preparationActorGapsMS),
            "triangles": preview.triangles.count,
            "solids": preview.solids,
            "vertices": topology?.vertices.count ?? 0,
            "segments": topology?.edges.reduce(0) { $0 + max(0, $1.polyline.count - 1) } ?? 0,
            "drag": ["durationsMS": dragCosts, "summary": summary(dragCosts), "elapsedSeconds": dragElapsed,
                     "renderedFrames": dragFrameCount, "renderFPS": Double(dragFrameCount) / max(0.001, dragElapsed),
                     "inputToRenderMS": frameMetrics.latencies, "inputToRenderSummary": summary(frameMetrics.latencies),
                     "interframeGapsMS": frameMetrics.gaps, "interframeGapSummary": summary(frameMetrics.gaps),
                     "inputCount": frameMetrics.inputs, "matchedInputCount": frameMetrics.matched,
                     "coalescedInputCount": frameMetrics.coalesced, "unmatchedInputCount": frameMetrics.pending],
            "coldPickingMS": coldCost,
            "firstSurfaceHitMS": firstSurfaceCost,
            "firstSurfaceHitCount": firstSurfaceHits.count,
            "coldFeature": cold?.id as Any? ?? NSNull(),
            "warmPicking": ["durationsMS": warmCosts, "summary": summary(warmCosts), "hits": warmHits,
                            "featureIDs": warmFeatures],
            "hover": ["durationsMS": hoverCosts, "summary": summary(hoverCosts)]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/lad-viewport-interaction-profile.json"), options: [.atomic])
        let dragP95 = summary(dragCosts)["p95MS"] ?? 0
        let warmP95 = summary(warmCosts)["p95MS"] ?? 0
        print("LAD viewport profile: synchronous install=\(synchronousInstallMS) ms, preparation=\(preparationMS) ms, drag p95=\(dragP95) ms, FPS=\(Double(dragFrameCount) / max(0.001, dragElapsed)), cold pick=\(coldCost) ms, warm pick p95=\(warmP95) ms")
    }

    private func summary(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        return ["count": Double(values.count), "meanMS": values.reduce(0, +) / Double(values.count),
                "p50MS": sorted[(sorted.count - 1) / 2],
                "p95MS": sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))],
                "maxMS": sorted.last ?? 0]
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: CADSceneView) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
    }
}

private final class ViewportProfileFrameCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private struct Input {
        let pose: [Float]
        let time: TimeInterval
    }
    private let lock = NSLock()
    private var value = 0
    private var recording = false
    private var inputs = [Input]()
    private var recentFrames = [Input]()
    private var latencies = [Double]()
    private var frameTimes = [TimeInterval]()
    private var inputCount = 0
    private var coalesced = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }

    func beginRecording() {
        lock.lock(); defer { lock.unlock() }
        recording = true
        inputs.removeAll(); recentFrames.removeAll(); latencies.removeAll(); frameTimes.removeAll()
        inputCount = 0; coalesced = 0
    }

    func recordInput(pose: [Float], at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        inputCount += 1
        // A fast render can finish during rightMouseDragged, before its
        // updated camera is recorded on the main actor. Retain a few actual
        // rendered poses to account for that race without inventing latency.
        if let frame = recentFrames.last(where: { $0.time >= time && samePose($0.pose, pose) }) {
            latencies.append(max(0, frame.time - time) * 1_000)
            coalesced += inputs.count
            inputs.removeAll()
        } else { inputs.append(Input(pose: pose, time: time)) }
    }

    func finishRecording() -> (latencies: [Double], gaps: [Double], inputs: Int, matched: Int, coalesced: Int, pending: Int) {
        lock.lock(); defer { lock.unlock() }
        recording = false
        let gaps = zip(frameTimes, frameTimes.dropFirst()).map { ($0.1 - $0.0) * 1_000 }
        return (latencies, gaps, inputCount, latencies.count, coalesced, inputs.count)
    }

    func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let renderedAt = ProcessInfo.processInfo.systemUptime
        let pose = renderer.pointOfView.map { viewportProfilePose($0.presentation.simdWorldTransform) }
        lock.lock(); defer { lock.unlock() }
        value += 1
        guard recording else { return }
        frameTimes.append(renderedAt)
        guard let pose else { return }
        recentFrames.append(Input(pose: pose, time: renderedAt))
        if recentFrames.count > 8 { recentFrames.removeFirst(recentFrames.count - 8) }
        if let index = inputs.lastIndex(where: { samePose($0.pose, pose) }) {
            latencies.append(max(0, renderedAt - inputs[index].time) * 1_000)
            coalesced += index
            inputs.removeFirst(index + 1)
        }
    }

    private func samePose(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0.0 - $0.1) <= 0.000_1 }
    }
}

private func viewportProfilePose(_ matrix: simd_float4x4) -> [Float] {
    (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
}
