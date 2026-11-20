import AppKit
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportSectionRenderingTests: XCTestCase {
    @MainActor
    func testSectionStartedOnAnObliqueFaceKeepsItsSurfaceVisibleAndPickable() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        let face = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)
        let bounds: [Double] = [7.25, -7.5, -1.25, 27.25, 12.5, 8.75]
        var preview = PreviewMesh(positions: [7.25, -7.5, -1.25, 27.25, -7.5, 8.75,
                                              27.25, 12.5, 8.75, 7.25, 12.5, -1.25],
            triangleIndices: [0, 1, 2, 0, 2, 3], bounds: bounds, volume: 0, area: 400,
            solids: 1, faces: 1, buildSeconds: 0, threads: 1, stepPath: "section-from-oblique-face")
        preview.topology = CADTopology(vertices: [], edges: [], faces: [
            CADFace(id: face, type: "PLANE", area: 200 * sqrt(5), center: [17.25, 2.5, 3.75],
                    normal: [-1 / sqrt(5), 0, 2 / sqrt(5)])
        ], parts: [])
        preview.triangleFaces = [0, 0]
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        let original = try await capture(view)
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face], sectionEnabled: true)
        let section = try await capture(view)
        XCTAssertEqual(view.sectionPlane?.value(for: .offset), 0)
        for x in [12.25, 17.25, 22.25] {
            let sample = SCNVector3(x, 3.5, (x - 17.25) * 0.5 + 3.75)
            let before = try pixelBlock(view, original, around: sample, radius: 2).map(\.redComponent)
            let after = try pixelBlock(view, section, around: sample, radius: 2).map(\.redComponent)
            XCTAssertGreaterThan(try XCTUnwrap(before.min()), 0.25)
            for (first, second) in zip(before, after) { XCTAssertEqual(first, second, accuracy: 0.025) }
            let point = view.projectPoint(sample)
            XCTAssertEqual(view.feature(at: NSPoint(x: CGFloat(point.x), y: CGFloat(point.y))), face)
        }
    }

    @MainActor
    func testLiveCaptureClipsFacesOrdinaryEdgesAndPartOutlines() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        let preview = PreviewMesh(positions: [-10, -10, 0, 10, -10, 0, 10, 10, 0, -10, 10, 0],
            triangleIndices: [0, 1, 2, 0, 2, 3], edgePoints: [-10, 0, 0, 10, 0, 0],
            bounds: [-10, -10, 0, 10, 10, 0], volume: 0, area: 400, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "section-plate", edgeSolids: [0])
        for mode in ViewportDisplayMode.allCases {
            view.update(mesh: preview, mode: mode, grid: false, command: ViewportCommand(.top),
                        selectedSolids: [0], hiddenSolids: [], projection: .isometric, sectionEnabled: true)
            let image = try await capture(view)
            let normal = try XCTUnwrap(view.sectionPlane).normal.x
            let background = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            let kept = try pixelBlock(view, image, around: SCNVector3(-5 * normal, 0, 0), radius: 2)
            let removed = try pixelBlock(view, image, around: SCNVector3(5 * normal, 0, 0), radius: 2)
            let clippedOutline = try pixelBlock(view, image, around: SCNVector3(5 * normal, 10, 0), radius: 4)
            XCTAssertTrue(kept.contains { abs($0.redComponent - background.redComponent) > 0.13 }, mode.rawValue)
            XCTAssertTrue((removed + clippedOutline).allSatisfy { abs($0.redComponent - background.redComponent) < 0.02 },
                          "Clipped scene geometry and selection outlines must both disappear in \(mode.rawValue).")
        }
        view.update(mesh: preview, mode: .shaded, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [], projection: .isometric, sectionEnabled: false)
        let full = try await capture(view)
        for x in [-5.0, 5.0] {
            let restored = try pixelBlock(view, full, around: SCNVector3(x, 0, 0), radius: 1)
            XCTAssertTrue(restored.allSatisfy { $0.redComponent > 0.25 })
        }
    }

    @MainActor
    func testEnablingSectionPreservesOrdinaryEdgeWidthAndClipsCrossingEdges() async throws {
        // Both faces are retained so the cut cannot change edge occlusion.
        // Their shared rim lies in the plane, while its ribbon straddles it.
        let preview = PreviewMesh(positions: [-10, -8, -2.5, 0, -8, 0, 0, 8, 0, -10, 8, -2.5,
                                              0, -8, -4, 0, 8, -4],
            triangleIndices: [0, 1, 2, 0, 2, 3, 1, 4, 5, 1, 5, 2],
            edgePoints: [-10, -8, -2.5, -10, 8, -2.5, 0, -8, 0, 0, 8, 0,
                         -10, -10, 0, 10, -10, 0],
            bounds: [-10, -10, -4, 10, 8, 0], volume: 0, area: 229, solids: 1, faces: 2,
            buildSeconds: 0, threads: 1, stepPath: "section-edge-ribbons",
            triangleSolids: [0, 0, 0, 0], edgeSolids: [0, 0, 0])
        var camera = CADAgentCamera()
        camera.position = [11, -7, 61]
        camera.target = [0, 0, 0]

        for projection in ViewportProjectionMode.allCases {
            let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 512, height: 360))
            view.preparesRendererResources = false
            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: projection)
            try view.configureAgentView(named: "isometric", camera: camera)
            let ready = try await view.waitForCaptureResources(until: .now + .seconds(3))
            XCTAssertTrue(ready)
            let edge = try XCTUnwrap(view.scene.rootNode.childNode(withName: "edges:0", recursively: true))
            edge.geometry?.firstMaterial?.diffuse.contents = NSColor.magenta
            let whole = try await capture(view)
            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: projection, sectionEnabled: true)
            let section = try await capture(view)
            XCTAssertEqual(view.sectionPlane?.equation, SIMD4<Float>(1, 0, 0, 0))

            func ink(_ image: NSBitmapImageRep, at point: SCNVector3) throws -> CGFloat {
                try pixelBlock(view, image, around: point, radius: 3).reduce(0) { coverage, color in
                    coverage + max(0, min(color.redComponent, color.blueComponent) - color.greenComponent)
                }
            }
            for y in [-5.0, 0.0, 5.0] {
                for point in [SCNVector3(-10, y, -2.5), SCNVector3(0, y, 0)] {
                    let original = try ink(whole, at: point)
                    XCTAssertGreaterThan(original, 3, "\(projection) must render the original edge.")
                    XCTAssertEqual(try ink(section, at: point), original, accuracy: original * 0.12,
                                   "\(projection) section changed the width near \(point).")
                }
            }
            let kept = SCNVector3(-5, -10, 0)
            let removed = SCNVector3(5, -10, 0)
            let original = try ink(whole, at: kept)
            XCTAssertGreaterThan(original, 3)
            XCTAssertEqual(try ink(section, at: kept), original, accuracy: original * 0.12)
            XCTAssertGreaterThan(try ink(whole, at: removed), 3)
            XCTAssertEqual(try ink(section, at: removed), 0, accuracy: 0.1,
                           "The crossing stroke must still end at the cut.")

            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: projection)
            let restored = try await capture(view)
            XCTAssertEqual(try ink(restored, at: removed), try ink(whole, at: removed), accuracy: 0.1)
        }
    }

    @MainActor
    func testSectionCapsHatchSolidAndLeaveAThroughHoleOpen() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        let preview = tube()
        for projection in ViewportProjectionMode.allCases {
            for mode in [ViewportDisplayMode.edges, .translucent] {
                view.update(mesh: preview, mode: mode, grid: false, command: ViewportCommand(.right),
                            selectedSolids: [], hiddenSolids: [], projection: projection, sectionEnabled: true)
                let image = try await capture(view)
                let background = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
                let opening = try pixelBlock(view, image, around: SCNVector3Zero, radius: 5)
                let cut = try pixelBlock(view, image, around: SCNVector3(0, 0, 8), radius: 5).map(\.redComponent)
                XCTAssertTrue(opening.allSatisfy { abs($0.redComponent - background.redComponent) < 0.02 })
                XCTAssertGreaterThan(try XCTUnwrap(cut.min()), background.redComponent + 0.1)
                XCTAssertGreaterThan(try XCTUnwrap(cut.max()) - XCTUnwrap(cut.min()), 0.02,
                                     "The visual section stays hatched in \(projection) \(mode).")
            }
        }
    }

    @MainActor
    func testMovingSectionKeepsTheLastMatchingCapAndCoalescesPendingCuts() async throws {
        let preview = tube()
        let mesh = try XCTUnwrap(CADViewportPreparedMesh.prepare(preview))
        let initial = try XCTUnwrap(CADSectionPlane(bounds: preview.bounds, toward: SIMD3(1, 0, 0)))
        let firstMove = try XCTUnwrap(initial.setting(1, for: .offset))
        let skipped = try XCTUnwrap(initial.setting(2, for: .offset))
        let latest = try XCTUnwrap(initial.setting(3, for: .offset))
        let caps = CADViewportSectionCaps()
        let initialReady = expectation(description: "Initial section cap prepared")
        let latestReady = expectation(description: "Newest section cap prepared")
        var presented: [CADSectionPlane] = []
        func request(_ cut: CADSectionPlane) {
            caps.update(plane: cut, mesh: mesh, transforms: [:], hidden: [], mode: .edges, renderer: nil) { plane, geometry in
                guard let plane, let geometry else {
                    XCTFail("Moving an intersecting cut must publish its matching cap.")
                    return
                }
                let offset = plane.value(for: .offset)
                XCTAssertEqual(Double(geometry.boundingBox.min.x), offset, accuracy: 1e-6)
                XCTAssertEqual(Double(geometry.boundingBox.max.x), offset, accuracy: 1e-6)
                caps.node.geometry = geometry
                presented.append(plane)
                if plane == initial { initialReady.fulfill() }
                if plane == firstMove { XCTAssertTrue(caps.isPreparing) }
                if plane == latest { latestReady.fulfill() }
            }
        }
        request(initial)
        await fulfillment(of: [initialReady], timeout: 3)
        let originalCap = try XCTUnwrap(caps.node.geometry)

        request(firstMove)
        request(skipped)
        request(latest)
        XCTAssertIdentical(caps.node.geometry, originalCap)
        XCTAssertEqual(presented, [initial])
        await fulfillment(of: [latestReady], timeout: 3)
        XCTAssertEqual(presented, [initial, firstMove, latest])
        XCTAssertFalse(caps.isPreparing)
    }

    @MainActor
    func testDraggingSectionKeepsTheFramePlaneAndCapTogether() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = CADSceneView(frame: frame)
        view.preparesRendererResources = false
        window.contentView = view
        view.update(mesh: tube(), mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [],
                    projection: .isometric, sectionEnabled: true)
        let initialReady = try await view.waitForCaptureResources(until: .now + .seconds(3))
        XCTAssertTrue(initialReady)
        let initialPlane = try XCTUnwrap(view.sectionPlane)
        let cap = try XCTUnwrap(view.scene.rootNode.childNodes.first { $0.categoryBitMask == CADViewportCategory.sectionCaps })
        let initialGeometry = try XCTUnwrap(cap.geometry)
        let manipulator = try XCTUnwrap(view.subviews.compactMap { $0 as? CADSectionManipulator }.first)
        let handles = try XCTUnwrap(manipulator.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement })
        guard handles.count == 3 else { XCTFail("The section manipulator needs three handles."); return }
        func center(_ handle: NSAccessibilityElement) -> SIMD2<Double> {
            let rect = window.convertFromScreen(handle.accessibilityFrame())
            return SIMD2(rect.midX, rect.midY)
        }
        let arrow = center(handles[0])
        let hub = SIMD2(center(handles[1]).x, center(handles[2]).y)
        let end = arrow + 12 * simd_normalize(arrow - hub)
        func mouse(_ type: NSEvent.EventType, at point: SIMD2<Double>) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: point.y), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        manipulator.mouseDown(with: try mouse(.leftMouseDown, at: arrow))
        manipulator.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        let latestPlane = try XCTUnwrap(view.sectionPlane)
        XCTAssertNotEqual(latestPlane, initialPlane)
        XCTAssertIdentical(cap.geometry, initialGeometry)
        XCTAssertEqual(view.makeFrame(width: 640, height: 480).sectionPlane, initialPlane.equation)

        let movedReady = try await view.waitForCaptureResources(until: .now + .seconds(3))
        XCTAssertTrue(movedReady)
        let movedGeometry = try XCTUnwrap(cap.geometry)
        XCTAssertFalse(movedGeometry === initialGeometry)
        XCTAssertEqual(view.makeFrame(width: 640, height: 480).sectionPlane, latestPlane.equation)
        XCTAssertEqual(Double(movedGeometry.boundingBox.min.x), latestPlane.origin.x, accuracy: 1e-6)
    }

    @MainActor
    func testMovingPartKeepsRenderedPoseAndCapTogether() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for live section movement.") }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        XCTAssertTrue(app.setActivationPolicy(.regular))
        defer { _ = app.setActivationPolicy(policy) }
        app.finishLaunching()

        let size = NSRect(x: 50, y: 50, width: 640, height: 480)
        let view = CADSceneView(frame: size)
        let frames = ViewportRenderCounter(view)
        let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD moving section test"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        let preview = tube()
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.right),
                    selectedSolids: [], hiddenSolids: [], projection: .isometric, sectionEnabled: true)
        var camera = CADAgentCamera()
        camera.position = [20, -35, 20]
        camera.target = [0, 0, 0]
        try view.configureAgentView(named: "isometric", camera: camera)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        view.layout()

        func waitForSettledFrame(after generation: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            let ready = try await view.waitForCaptureResources(until: deadline)
            XCTAssertTrue(ready)
            while (frames.count <= generation || view.hasPendingFrames), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(frames.count, generation)
            XCTAssertFalse(view.hasPendingFrames)
        }

        try await waitForSettledFrame(after: 0)
        let body = try XCTUnwrap(view.scene.rootNode.childNode(withName: "solid:0", recursively: true))
        let cap = try XCTUnwrap(view.scene.rootNode.childNodes.first { $0.categoryBitMask == CADViewportCategory.sectionCaps })
        let section = try XCTUnwrap(view.sectionPlane)
        func assertMatchingSection(file: StaticString = #filePath, line: UInt = #line) throws {
            _ = try XCTUnwrap(cap.geometry, "The section cap disappeared during motion.", file: file, line: line)
            let bounds = cap.boundingBox
            let low = cap.convertPosition(bounds.min, to: nil)
            let high = cap.convertPosition(bounds.max, to: nil)
            let bodyY = Double(body.simdWorldTransform.columns.3.y)
            XCTAssertEqual(Double(low.y), preview.bounds[1] + bodyY, accuracy: 1e-5, file: file, line: line)
            XCTAssertEqual(Double(high.y), preview.bounds[4] + bodyY, accuracy: 1e-5, file: file, line: line)
            XCTAssertEqual(view.makeFrame(width: 640, height: 480).sectionPlane, section.equation, file: file, line: line)
        }
        func applyPose(to view: CADSceneView, y: Double, x: Double = 0, sectionEnabled: Bool = true) {
            let transform = [1.0, 0, 0, x, 0, 1, 0, y, 0, 0, 1, 0, 0, 0, 0, 1]
            view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [],
                        projection: .isometric, solidTransforms: [0: transform], sectionEnabled: sectionEnabled)
        }

        try assertMatchingSection()
        let original = try await CADAgentRenderer.capturePNG(view: view)

        // Repeated slider values reach the viewport before a fresh cap can finish.
        let beforeSlider = frames.count
        for y in [1.0, 2.0, 3.0] {
            applyPose(to: view, y: y)
            try assertMatchingSection()
        }
        try await waitForSettledFrame(after: beforeSlider)
        XCTAssertEqual(body.simdWorldTransform.columns.3.y, 3)
        try assertMatchingSection()

        // Grab the exposed outer wall, which lies behind the cut and outside its cap.
        let hit = view.projectPoint(SCNVector3(-4, -7, 0))
        let start = NSPoint(x: CGFloat(hit.x), y: CGFloat(hit.y))
        func mouse(_ type: NSEvent.EventType, x: CGFloat, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let point = view.convert(NSPoint(x: start.x + x, y: start.y), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        }
        view.assemblyGrabbingEnabled = true
        view.onAssemblyGrabBegan = { solid, _, _ in solid == 0 }
        view.onAssemblyGrabMoved = { [weak view] point in
            if let view { applyPose(to: view, y: 3 + (point[0] - Double(start.x)) / 10) }
        }
        let beforeGrab = frames.count
        view.mouseDown(with: try mouse(.leftMouseDown, x: 0, modifiers: .command))
        XCTAssertTrue(view.isGrabbingAssembly)
        for x: CGFloat in [10, 20, 30] {
            view.mouseDragged(with: try mouse(.leftMouseDragged, x: x))
            try assertMatchingSection()
        }
        view.mouseUp(with: try mouse(.leftMouseUp, x: 30))
        try await waitForSettledFrame(after: beforeGrab)
        XCTAssertEqual(body.simdWorldTransform.columns.3.y, 6, accuracy: 1e-5)
        try assertMatchingSection()
        let moved = try await CADAgentRenderer.capturePNG(view: view)
        XCTAssertNotEqual(moved, original)

        // A reversal must settle at the most recently requested pose.
        applyPose(to: view, y: 8)
        applyPose(to: view, y: 6)
        try assertMatchingSection()
        let reversed = try await view.waitForCaptureResources(until: .now + .seconds(10))
        XCTAssertTrue(reversed)
        XCTAssertEqual(body.simdWorldTransform.columns.3.y, 6)
        try assertMatchingSection()

        // Turning off the section during preparation should display the requested pose immediately.
        applyPose(to: view, y: 9)
        try assertMatchingSection()
        applyPose(to: view, y: 9, sectionEnabled: false)
        XCTAssertEqual(body.simdWorldTransform.columns.3.y, 9)
        XCTAssertNil(cap.geometry)
        XCTAssertEqual(view.makeFrame(width: 640, height: 480).sectionPlane, .zero)

        // A completed pose still needs a new frame when neither position intersects the cut.
        for x in [-9.0, -10.0] {
            let before = frames.count
            applyPose(to: view, y: 9, x: x)
            try await waitForSettledFrame(after: before)
            XCTAssertEqual(Double(body.simdWorldTransform.columns.3.x), x)
            XCTAssertNil(cap.geometry)
            XCTAssertEqual(view.makeFrame(width: 640, height: 480).sectionPlane, section.equation)
        }
    }

    @MainActor
    private func capture(_ view: CADSceneView) async throws -> NSBitmapImageRep {
        let png = try await CADAgentRenderer.capturePNG(view: view)
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    @MainActor
    private func pixelBlock(_ view: CADSceneView, _ image: NSBitmapImageRep, around world: SCNVector3,
                            radius: Int) throws -> [NSColor] {
        let point = view.projectPoint(world)
        let x = Int(point.x.rounded()), y = image.pixelsHigh - Int(point.y.rounded())
        return try (y - radius...y + radius).flatMap { row in
            try (x - radius...x + radius).map { column in
                try XCTUnwrap(image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
            }
        }
    }

    /// A closed rectangular tube with one hole through the section plane.
    private func tube() -> PreviewMesh {
        let corners: [SIMD2<Float>] = [.init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1)]
        var positions = [Float](), indices = [UInt32]()
        for x: Float in [-8, 8] {
            for radius: Float in [10, 6] {
                for corner in corners { positions.append(contentsOf: [x, radius * corner.x, radius * corner.y]) }
            }
        }
        func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
            indices.append(contentsOf: [a, b, c, a, c, d])
        }
        for i: UInt32 in 0..<4 {
            let j = (i + 1) % 4
            quad(i, j, j + 8, i + 8)
            quad(i + 4, i + 12, j + 12, j + 4)
            quad(i, i + 4, j + 4, j)
            quad(i + 8, j + 8, j + 12, i + 12)
        }
        return PreviewMesh(positions: positions, triangleIndices: indices, bounds: [-8, -10, -10, 8, 10, 10],
                           volume: 4_096, area: 2_560, solids: 1, faces: 16,
                           buildSeconds: 0, threads: 1, stepPath: "section-tube")
    }
}
