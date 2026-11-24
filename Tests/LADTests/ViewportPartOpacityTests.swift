import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

/// A part color's alpha makes that part translucent in the shaded and edge
/// displays: it composites over the opaque scene independently of submission
/// order, opaque parts and section caps in front of it hide it, and the
/// translucent and wireframe displays ignore it. Every check reads pixels of
/// production captures.
final class ViewportPartOpacityTests: XCTestCase {
    private let red = PartColor(red: 0.85, green: 0.10, blue: 0.15)
    private let blue = PartColor(red: 0.10, green: 0.25, blue: 0.90)
    private var previews: [ObjectIdentifier: PreviewMesh] = [:]

    @MainActor
    func testPartialOpacityRevealsEnclosedPartOnlyInShadedAndEdgeDisplays() async throws {
        let view = try await makeView(preview: nestedBoxes())
        for mode in [ViewportDisplayMode.shaded, .edges] {
            let translucent = [0: red.with(alpha: 0.35), 1: blue]
            let visible = try await centerColor(view, mode: mode, colors: translucent)
            let hidden = try await centerColor(view, mode: mode, colors: translucent, hidden: [1])
            XCTAssertGreaterThan(visible.blueComponent, hidden.blueComponent + 0.1,
                "The enclosed blue part must show through the \(mode) shell whose alpha is below 1.")
            let opaque = try await centerColor(view, mode: mode, colors: [0: red, 1: blue])
            let opaqueHidden = try await centerColor(view, mode: mode, colors: [0: red, 1: blue], hidden: [1])
            XCTAssertLessThan(difference(opaque, opaqueHidden), 0.01, "An opaque \(mode) shell must hide the enclosed part.")
            XCTAssertGreaterThan(opaque.redComponent, visible.redComponent + 0.1,
                "The \(mode) shell's color must fade with its alpha.")
        }
        for mode in [ViewportDisplayMode.translucent, .wireframe] {
            let partial = try await capture(view, mode: mode, colors: [0: red.with(alpha: 0.35), 1: blue.with(alpha: 0.6)])
            let opaque = try await capture(view, mode: mode, colors: [0: red, 1: blue])
            XCTAssertLessThan(try largestDifference(partial, opaque), 0.01, "The \(mode) display must ignore part alpha.")
        }
    }

    @MainActor
    func testOpaquePartsHidePartiallyOpaquePartsBehindThem() async throws {
        let view = try await makeView(preview: layeredPlates())
        let covered = try await centerColor(view, mode: .edges, colors: [0: red, 1: blue.with(alpha: 0.5)])
        let alone = try await centerColor(view, mode: .edges, colors: [0: red, 1: blue.with(alpha: 0.5)], hidden: [1])
        XCTAssertLessThan(difference(covered, alone), 0.01,
            "A partially opaque part behind an opaque part must not bleed through it.")
        let revealed = try await centerColor(view, mode: .edges, colors: [0: red.with(alpha: 0.5), 1: blue])
        let uncovered = try await centerColor(view, mode: .edges, colors: [0: red.with(alpha: 0.5), 1: blue], hidden: [1])
        XCTAssertGreaterThan(revealed.blueComponent, uncovered.blueComponent + 0.15,
            "An opaque part behind a partially opaque part must remain visible through it.")
        let clear = try await centerColor(view, mode: .shaded, colors: [0: red.with(alpha: 0), 1: blue])
        let only = try await centerColor(view, mode: .shaded, colors: [0: red, 1: blue], hidden: [0])
        XCTAssertLessThan(difference(clear, only), 0.01, "A fully transparent part must not tint the parts behind it.")
    }

    @MainActor
    func testPartialOpacityIsIndependentOfSolidSubmissionOrder() async throws {
        let view = try await makeView(preview: nestedBoxes())
        for colors in [[0: red.with(alpha: 0.5), 1: blue.with(alpha: 0.6)], [0: red.with(alpha: 0.4), 1: blue]] {
            for projection in ViewportProjectionMode.allCases {
                let solids = try (0...1).map { try XCTUnwrap(view.scene.rootNode.childNode(withName: "solid:\($0)", recursively: true)) }
                solids[0].renderingOrder = 10; solids[1].renderingOrder = 20
                let forward = try await centerColor(view, mode: .edges, colors: colors, projection: projection)
                solids[0].renderingOrder = 20; solids[1].renderingOrder = -20
                let reversed = try await centerColor(view, mode: .edges, colors: colors, projection: projection)
                solids.forEach { $0.renderingOrder = 0 }
                XCTAssertLessThan(difference(forward, reversed), 0.015,
                    "Partially opaque \(projection) parts must composite identically in either submission order.")
            }
        }
    }

    @MainActor
    func testFullOpacityRestoresOpaqueRenderingAndBackgroundIsRetained() async throws {
        let view = try await makeView(preview: nestedBoxes())
        let opaque = try await capture(view, mode: .edges, colors: [0: red, 1: blue])
        let partial = try await capture(view, mode: .edges, colors: [0: red.with(alpha: 0.3), 1: blue])
        for (x, y) in [(0, 0), (opaque.pixelsWide - 1, 0), (0, opaque.pixelsHigh - 1), (opaque.pixelsWide - 1, opaque.pixelsHigh - 1)] {
            XCTAssertLessThan(difference(try color(opaque, x, y), try color(partial, x, y)), 0.01,
                "Compositing partially opaque parts must retain the scene background.")
        }
        XCTAssertGreaterThan(try largestDifference(opaque, partial), 0.1)
        let restored = try await capture(view, mode: .edges, colors: [0: red, 1: blue])
        XCTAssertLessThan(try largestDifference(opaque, restored), 0.01, "Full opacity must restore opaque depth-tested faces.")
    }

    @MainActor
    func testPartiallyOpaquePartKeepsCrispEdgesAndShowsEdgesBehindIt() async throws {
        let preview = nestedBoxes(withEdges: true)
        let view = try await makeView(preview: preview)
        // Off the diagonal, so the shell's and enclosed part's edges stay apart.
        try view.configureAgentView(named: "front", camera: .init(yawDegrees: -60, elevationDegrees: 25, target: [0, 0, 0]))
        func capture(_ mode: ViewportDisplayMode, shellAlpha: Double) async throws -> NSBitmapImageRep {
            view.update(mesh: preview, mode: mode, grid: false, command: nil, selectedSolids: [], hiddenSolids: [],
                        solidColors: [0: red.with(alpha: shellAlpha), 1: blue])
            return try await captureImage(view)
        }
        let opaque = try await capture(.edges, shellAlpha: 1)
        let partial = try await capture(.edges, shellAlpha: 0.3)
        let shaded = try await capture(.shaded, shellAlpha: 0.3)
        // The nearest vertical edges of the shell and of the enclosed part, each
        // between two of its visible faces.
        let shellEdge = SCNVector3(2, -2, -1.2), innerEdge = SCNVector3(1, -1, 0)
        let ink = try darkest(view, partial, around: shellEdge)
        XCTAssertLessThan(ink, 0.12, "A partially opaque part's own edges must be drawn over its faces.")
        XCTAssertEqual(ink, try darkest(view, opaque, around: shellEdge), accuracy: 0.05,
                       "Edges of a partially opaque part must stay as crisp as an opaque part's edges.")
        XCTAssertGreaterThan(try darkest(view, shaded, around: shellEdge), ink + 0.05)
        XCTAssertLessThan(try darkest(view, partial, around: innerEdge), try darkest(view, shaded, around: innerEdge) - 0.05,
                          "The enclosed part's edges must show through the partially opaque shell.")
    }

    @MainActor
    func testSectionCapsHidePartiallyOpaqueFacesBehindThem() async throws {
        let preview = nestedBoxes()
        let view = try await makeView(preview: preview)
        // The front view looks along +Y; removing the nearer half turns the cap toward the camera.
        let plane = try XCTUnwrap(CADSectionPlane(point: SIMD3(0, 0, 0), normal: SIMD3(0, -1, 0), cameraRight: SIMD3(1, 0, 0)))
        func cut(_ shell: PartColor) async throws -> NSColor {
            view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.front), selectedSolids: [],
                        hiddenSolids: [1], projection: .isometric, solidColors: [0: shell], sectionEnabled: true)
            view.configureAgentSection(plane)
            let image = try await captureImage(view)
            return try color(image, image.pixelsWide / 2, image.pixelsHigh / 2)
        }
        let opaque = try await cut(red)
        XCTAssertEqual(view.sectionPlane, plane)
        XCTAssertLessThan(abs(opaque.redComponent - opaque.blueComponent), 0.1, "The neutral section cap must face the camera.")
        let partial = try await cut(red.with(alpha: 0.3))
        XCTAssertLessThan(difference(opaque, partial), 0.01, "A section cap must hide the partially opaque faces behind it.")
    }

    /// A partially opaque face that shares an opaque face's surface, as a
    /// window pane flush with its frame, consistently draws over it. Their
    /// separate tessellations must not fight for depth.
    @MainActor
    func testCoincidentPartiallyOpaqueFaceConsistentlyCoversOpaqueFace() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let colors = [0: red, 1: blue.with(alpha: 0.5)]
        func capture(_ preview: PreviewMesh, hidden: Set<Int> = []) async throws -> NSBitmapImageRep {
            view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: hidden,
                        solidColors: colors)
            let camera = try XCTUnwrap(view.pointOfView)
            camera.position = SCNVector3(2.2, -3.6, 2.4)
            camera.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
            return try await captureImage(view)
        }
        let coincident = try await capture(coplanarPlates(lift: 0))
        let lifted = try await capture(coplanarPlates(lift: 0.05))
        let bare = try await capture(coplanarPlates(lift: 0), hidden: [1])
        var samples = 0, unlike = 0, untinted = 0
        for v in stride(from: -1.6, through: 1.6, by: 0.08) {
            for u in stride(from: -1.6, through: 1.6, by: 0.08) {
                let point = view.projectPoint(SCNVector3(u, v, 0))
                let x = Int(CGFloat(point.x) * CGFloat(coincident.pixelsWide) / view.bounds.width)
                let y = coincident.pixelsHigh - 1 - Int(CGFloat(point.y) * CGFloat(coincident.pixelsHigh) / view.bounds.height)
                samples += 1
                let color = try color(coincident, x, y)
                if difference(color, try self.color(lifted, x, y)) > 0.03 { unlike += 1 }
                if difference(color, try self.color(bare, x, y)) < 0.05 { untinted += 1 }
            }
        }
        XCTAssertGreaterThan(samples, 1_000)
        XCTAssertEqual(unlike, 0, "A coincident partially opaque face must look as if it lay just in front of the opaque face.")
        XCTAssertEqual(untinted, 0, "The coincident partially opaque face must tint the opaque face everywhere.")
    }

    @MainActor
    func testHighlightedFaceOfPartiallyOpaquePartStaysTranslucent() async throws {
        let face = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)
        let preview = plateOverSquare()
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        func capture(features: [CADFeatureID] = [], parts: Set<Int> = [], hidden: Set<Int> = []) async throws -> NSBitmapImageRep {
            view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: parts, hiddenSolids: hidden,
                        solidColors: [0: PartColorState.defaultFinish.with(alpha: 0.4), 1: blue], selectedFeatures: features)
            let camera = try XCTUnwrap(view.pointOfView)
            camera.position = SCNVector3(0.7, -4.5, 2.2)
            camera.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
            return try await captureImage(view)
        }
        let plain = try await capture()
        let selected = try await capture(features: [face])
        let part = try await capture(parts: [0])
        let uncovered = try await capture(features: [face], hidden: [1])
        func pixel(_ image: NSBitmapImageRep, _ u: Double, _ v: Double, _ w: Double = 0) throws -> NSColor {
            let projected = view.projectPoint(SCNVector3(u, v, w))
            return try color(image, Int(CGFloat(projected.x) * CGFloat(image.pixelsWide) / view.bounds.width),
                             image.pixelsHigh - 1 - Int(CGFloat(projected.y) * CGFloat(image.pixelsHigh) / view.bounds.height))
        }
        var tinted = 0, unlike = 0, changedOther = 0, hiddenBehind = 0, samples = 0
        for v in stride(from: -1.5, through: 1.5, by: 0.1) {
            for u in stride(from: -1.5, through: 1.5, by: 0.1) where abs(u) > 0.3 {
                let before = try pixel(plain, u, v), after = try pixel(selected, u, v)
                if u > 0 { if difference(before, after) > 0.02 { changedOther += 1 }; continue }
                samples += 1
                if after.redComponent - after.blueComponent > before.redComponent - before.blueComponent + 0.05 { tinted += 1 }
                if difference(after, try pixel(part, u, v)) > 0.02 { unlike += 1 }
            }
        }
        for v in stride(from: -0.4, through: 0.8, by: 0.1) {
            for u in stride(from: -1.4, through: -0.7, by: 0.1) {
                if try pixel(selected, u, v, -0.6).blueComponent < pixel(uncovered, u, v, -0.6).blueComponent + 0.1 { hiddenBehind += 1 }
            }
        }
        XCTAssertGreaterThan(samples, 100)
        XCTAssertEqual(tinted, samples, "The highlighted face must take the highlight color.")
        XCTAssertEqual(unlike, 0, "A face fill must match whole-part selection of the partially opaque part.")
        XCTAssertEqual(changedOther, 0, "The part's other faces must keep their own color.")
        XCTAssertEqual(hiddenBehind, 0, "The part behind the highlighted face must remain visible through it.")
    }

    /// The live render thread draws partially opaque parts with extra scene
    /// passes; every published frame must complete and the view must go idle.
    @MainActor
    func testLiveViewportCompletesEveryFrameWithPartiallyOpaqueParts() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for live viewport drawing.") }
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        defer { _ = application.setActivationPolicy(previousPolicy) }
        application.finishLaunching()
        let preview = nestedBoxes(withEdges: true)
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let frames = ViewportRenderCounter(view)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "LAD part opacity test"
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        func show(_ mode: ViewportDisplayMode, alpha: Double, command: ViewportCommand.Action? = nil) {
            view.update(mesh: preview, mode: mode, grid: true, command: command.map(ViewportCommand.init),
                        selectedSolids: [], hiddenSolids: [], solidColors: [0: red.with(alpha: alpha), 1: blue])
        }
        show(.edges, alpha: 1, command: .isometric)
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        view.layout()
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isPreparingResources)
        try await waitForFrame(frames, after: 0)
        for (mode, alpha) in [(ViewportDisplayMode.edges, 0.3), (.shaded, 0.3), (.edges, 0.6), (.translucent, 0.6),
                              (.edges, 1), (.edges, 0.3)] {
            let before = frames.count
            show(mode, alpha: alpha)
            try await waitForFrame(frames, after: before)
            try await waitForIdle(frames, view)
        }
        // Rapid camera changes coalesce, and none may stall the render thread.
        let before = frames.count
        for action in Array(repeating: [ViewportCommand.Action.front, .right, .top, .isometric], count: 6).joined() {
            show(.edges, alpha: 0.3, command: action)
            try await Task.sleep(for: .milliseconds(3))
        }
        try await waitForFrame(frames, after: before)
        try await waitForIdle(frames, view)
        XCTAssertTrue(view.renderedShowsModel)
    }

    @MainActor
    private func waitForFrame(_ frames: ViewportRenderCounter, after previous: Int,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while frames.count <= previous, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(frames.count, previous, "The live viewport must draw the change.", file: file, line: line)
    }

    /// Waits until no frame is pending and none has completed for a while.
    @MainActor
    private func waitForIdle(_ frames: ViewportRenderCounter, _ view: CADSceneView,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var previous = frames.count, lastChange = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            if frames.count != previous { previous = frames.count; lastChange = ContinuousClock.now }
            if !view.hasPendingFrames, ContinuousClock.now - lastChange >= .milliseconds(250) { return }
        }
        XCTFail("Every published frame must complete, and an unchanged viewport must become idle.", file: file, line: line)
    }

    // MARK: Support

    @MainActor
    private func makeView(preview: PreviewMesh) async throws -> CADSceneView {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is required for opacity pixel tests.") }
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        previews[ObjectIdentifier(view)] = preview
        return view
    }

    /// Looks straight down -Z at the origin, so the +Z faces are in front.
    @MainActor
    private func capture(_ view: CADSceneView, mode: ViewportDisplayMode, colors: [Int: PartColor], hidden: Set<Int> = [],
                         projection: ViewportProjectionMode = .isometric) async throws -> NSBitmapImageRep {
        view.update(mesh: try XCTUnwrap(previews[ObjectIdentifier(view)]), mode: mode, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: hidden, projection: projection, solidColors: colors)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0, 0, 10)
        camera.look(at: SCNVector3Zero)
        camera.camera?.orthographicScale = 3
        camera.camera?.fieldOfView = 40
        camera.camera?.automaticallyAdjustsZRange = false
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 100
        return try await captureImage(view)
    }

    @MainActor
    private func centerColor(_ view: CADSceneView, mode: ViewportDisplayMode, colors: [Int: PartColor], hidden: Set<Int> = [],
                             projection: ViewportProjectionMode = .isometric) async throws -> NSColor {
        let image = try await capture(view, mode: mode, colors: colors, hidden: hidden, projection: projection)
        var sum = [CGFloat](repeating: 0, count: 3), count: CGFloat = 0
        for y in (image.pixelsHigh / 2 - 3)...(image.pixelsHigh / 2 + 3) {
            for x in (image.pixelsWide / 2 - 3)...(image.pixelsWide / 2 + 3) {
                let pixel = try color(image, x, y)
                sum[0] += pixel.redComponent; sum[1] += pixel.greenComponent; sum[2] += pixel.blueComponent
                count += 1
            }
        }
        return NSColor(srgbRed: sum[0] / count, green: sum[1] / count, blue: sum[2] / count, alpha: 1)
    }

    @MainActor
    private func captureImage(_ view: CADSceneView) async throws -> NSBitmapImageRep {
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingCaptureResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingCaptureResources)
        let png = try await CADAgentRenderer.capturePNG(view: view)
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    private func color(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: min(max(x, 0), image.pixelsWide - 1),
                                    y: min(max(y, 0), image.pixelsHigh - 1))?.usingColorSpace(.sRGB))
    }

    private func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
    }

    private func largestDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> CGFloat {
        var largest: CGFloat = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: a.pixelsWide, by: 3) {
                largest = max(largest, difference(try color(a, x, y), try color(b, x, y)))
            }
        }
        return largest
    }

    /// The darkest luminance near a world point, which finds a thin edge line.
    @MainActor
    private func darkest(_ view: CADSceneView, _ image: NSBitmapImageRep, around world: SCNVector3) throws -> CGFloat {
        let point = view.projectPoint(world)
        let x = Int(CGFloat(point.x) * CGFloat(image.pixelsWide) / view.bounds.width)
        let y = image.pixelsHigh - 1 - Int(CGFloat(point.y) * CGFloat(image.pixelsHigh) / view.bounds.height)
        var result: CGFloat = 1
        for row in (y - 3)...(y + 3) {
            for column in (x - 3)...(x + 3) {
                let pixel = try color(image, column, row)
                result = min(result, 0.2126 * pixel.redComponent + 0.7152 * pixel.greenComponent + 0.0722 * pixel.blueComponent)
            }
        }
        return result
    }

    private func nestedBoxes(withEdges: Bool = false) -> PreviewMesh {
        let triangles = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7],
                         [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5],
                         [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        func vertices(_ s: Double) -> [[Double]] {
            [[-s, -s, -s], [s, -s, -s], [s, s, -s], [-s, s, -s],
             [-s, -s, s], [s, -s, s], [s, s, s], [-s, s, s]]
        }
        func edges(_ s: Double) -> [[Double]] {
            let corners = vertices(s)
            let pairs = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
            return pairs.map { corners[$0.0] + corners[$0.1] }
        }
        return PreviewMesh(vertices: vertices(2) + vertices(1),
            triangles: triangles + triangles.map { $0.map { $0 + 8 } }, edges: withEdges ? edges(2) + edges(1) : [],
            bounds: [-2, -2, -2, 2, 2, 2], volume: 72, area: 120, solids: 2, faces: 12,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-part-opacity-boxes\(withEdges ? "-edges" : "").step",
            triangleSolids: [Int](repeating: 0, count: 12) + [Int](repeating: 1, count: 12),
            edgeSolids: withEdges ? [Int](repeating: 0, count: 12) + [Int](repeating: 1, count: 12) : nil)
    }

    /// Two square plates facing +Z: solid 0 in front of solid 1.
    private func layeredPlates() -> PreviewMesh {
        PreviewMesh(vertices: [[-2, -2, 1], [2, -2, 1], [2, 2, 1], [-2, 2, 1],
                               [-2, -2, 0], [2, -2, 0], [2, 2, 0], [-2, 2, 0]],
                    triangles: [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]], edges: [],
                    bounds: [-2, -2, 0, 2, 2, 1], volume: 1, area: 32, solids: 2, faces: 2,
                    buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-part-opacity-plates.step",
                    triangleSolids: [0, 0, 1, 1])
    }

    /// An opaque plate (solid 0) and a partially opaque plate (solid 1) on the
    /// same square, with different triangulations, the second raised by `lift`.
    private func coplanarPlates(lift: Double) -> PreviewMesh {
        var vertices = [[Double]](), triangles = [[Int]](), solids = [Int]()
        func plate(divisions: Int, z: Double, solid: Int, flipped: Bool) {
            let first = vertices.count
            for row in 0...divisions {
                for column in 0...divisions {
                    vertices.append([-2 + 4 * Double(column) / Double(divisions), -2 + 4 * Double(row) / Double(divisions), z])
                }
            }
            for row in 0..<divisions {
                for column in 0..<divisions {
                    let corner = first + row * (divisions + 1) + column, above = corner + divisions + 1
                    triangles += flipped ? [[corner, corner + 1, above], [corner + 1, above + 1, above]]
                        : [[corner, corner + 1, above + 1], [corner, above + 1, above]]
                    solids += [solid, solid]
                }
            }
        }
        plate(divisions: 13, z: 0, solid: 0, flipped: false)
        plate(divisions: 7, z: lift, solid: 1, flipped: true)
        return PreviewMesh(vertices: vertices, triangles: triangles, edges: [], bounds: [-2, -2, 0, 2, 2, lift],
                           volume: 1, area: 32, solids: 2, faces: 2, buildSeconds: 0, threads: 1,
                           stepPath: "/tmp/viewport-part-opacity-coplanar-\(lift).step", triangleSolids: solids)
    }

    /// A finely triangulated plate whose halves are two planar faces, over a
    /// smaller square part beneath the first face.
    private func plateOverSquare(divisions: Int = 24) -> PreviewMesh {
        var vertices = [[Double]](), triangles = [[Int]](), faces = [Int]()
        for row in 0...divisions {
            for column in 0...divisions {
                vertices.append([-2 + 4 * Double(column) / Double(divisions), -2 + 4 * Double(row) / Double(divisions), 0])
            }
        }
        for row in 0..<divisions {
            for column in 0..<divisions {
                let corner = row * (divisions + 1) + column, above = corner + divisions + 1
                triangles += [[corner, corner + 1, above + 1], [corner, above + 1, above]]
                faces += Array(repeating: column < divisions / 2 ? 0 : 1, count: 2)
            }
        }
        let square = vertices.count
        vertices += [[-1.6, -1, -0.6], [-0.4, -1, -0.6], [-0.4, 1, -0.6], [-1.6, 1, -0.6]]
        triangles += [[square, square + 1, square + 2], [square, square + 2, square + 3]]
        faces += [2, 2]
        let solids = Array(repeating: 0, count: triangles.count - 2) + [1, 1]
        var preview = PreviewMesh(vertices: vertices, triangles: triangles, edges: [],
            bounds: [-2, -2, -0.6, 2, 2, 0], volume: 1, area: 18.4, solids: 2, faces: 3,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-part-opacity-plate.step", triangleSolids: solids)
        func face(_ solid: Int, _ local: Int, area: Double, center: [Double]) -> CADFace {
            CADFace(id: CADFeatureID(kind: .face, solidIndex: solid, localIndex: local), type: "PLANE", area: area,
                    center: center, normal: [0, 0, 1])
        }
        preview.topology = CADTopology(vertices: [], edges: [], faces: [
            face(0, 0, area: 8, center: [-1, 0, 0]), face(0, 1, area: 8, center: [1, 0, 0]),
            face(1, 0, area: 2.4, center: [-1, 0, -0.6])
        ], parts: [])
        preview.triangleFaces = faces
        return preview
    }
}

private extension PartColor {
    func with(alpha: Double) -> PartColor { PartColor(red: red, green: green, blue: blue, alpha: alpha) }
}
