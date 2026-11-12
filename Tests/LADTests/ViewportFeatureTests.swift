import AppKit
import Metal
import SceneKit
import XCTest
import simd
@testable import LAD

final class ViewportFeatureTests: XCTestCase {
    private let vertex = CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: 0)
    private let edge = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)
    private let face = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)

    func testNativeVertexHasPriorityWithinPixelToleranceThenEdgeThenFace() {
        let corner = sample(vertex, screen: [10, 10])
        let segment = ViewportFeaturePicking.Edge(id: edge, start: sample(edge, screen: [0, 10]), end: sample(edge, screen: [100, 10]))
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [15, 10], vertices: [corner], edges: [segment], face: face), vertex)
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [50, 15], vertices: [corner], edges: [segment], face: face), edge)
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [50, 17], vertices: [corner], edges: [segment], face: face), face)
        XCTAssertNil(ViewportFeaturePicking.pick(at: [50, 17], vertices: [corner], edges: [segment], face: nil))
    }

    func testCurvedEdgeUsesItsPolylineAndClampsToSegmentEnds() {
        let segments = [ViewportFeaturePicking.Edge(id: edge, start: sample(edge, screen: [0, 20]), end: sample(edge, screen: [20, 40])),
                        ViewportFeaturePicking.Edge(id: edge, start: sample(edge, screen: [20, 40]), end: sample(edge, screen: [40, 20]))]
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [21, 39], vertices: [], edges: segments, face: nil), edge)
        XCTAssertNil(ViewportFeaturePicking.pick(at: [65, -5], vertices: [], edges: segments, face: nil),
                     "The extension of an edge is not selectable.")
    }

    func testLargerVertexTargetIsEasyToAcquireWithoutTakingOverDistantEdges() {
        let corner = sample(vertex, screen: [10, 10])
        let segment = ViewportFeaturePicking.Edge(id: edge, start: sample(edge, screen: [0, 10]), end: sample(edge, screen: [100, 10]))
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [21, 10], vertices: [corner], edges: [segment], face: face), vertex,
                       "The vertex target must include the neighborhood beyond the former eight-point radius.")
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [24, 10], vertices: [corner], edges: [segment], face: face), edge,
                       "Edges remain selectable outside the enlarged vertex target.")
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [21, 10], vertices: [corner], edges: [segment], face: face,
                                                  isVisible: { _, _ in false }), face,
                       "Enlarging the target must not select occluded vertices or edges.")
    }

    func testOccludedAndBehindCameraFeaturesAreNotPicked() {
        let visibleVertex = CADFeatureID(kind: .vertex, solidIndex: 1, localIndex: 0)
        let behindCamera = sample(vertex, screen: [10, 10], depth: -1)
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [10, 10], vertices: [behindCamera], edges: [], face: face), face)
        let occluded = sample(vertex, screen: [10, 10], world: [0, 0, -5])
        let visible = sample(visibleVertex, screen: [12, 10], world: [0, 0, 0])
        XCTAssertEqual(ViewportFeaturePicking.pick(at: [10, 10], vertices: [occluded, visible], edges: [], face: face,
                                                  isVisible: { world, _ in world.z >= 0 }), visibleVertex)
    }

    func testToggleSelectionPreservesClickOrderWithoutModifiers() {
        var selection: [CADFeatureID] = []
        selection = ViewportFeaturePicking.toggling(face, in: selection)
        selection = ViewportFeaturePicking.toggling(vertex, in: selection)
        selection = ViewportFeaturePicking.toggling(edge, in: selection)
        XCTAssertEqual(selection, [face, vertex, edge])
        selection = ViewportFeaturePicking.toggling(vertex, in: selection)
        XCTAssertEqual(selection, [face, edge])
        selection = ViewportFeaturePicking.toggling(vertex, in: selection)
        XCTAssertEqual(selection, [face, edge, vertex])
    }

    @MainActor
    func testViewportClickSelectsNativeFeaturesWithoutChangingParts() async throws {
        let view = try makeView()
        view.update(mesh: mesh(), mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [0], hiddenSolids: [])
        try await waitForPreparation(view)
        var partsChanged = 0
        var featureSelections = [[CADFeatureID]]()
        view.onSelectionChanged = { _ in partsChanged += 1 }
        view.onFeatureSelectionChanged = { featureSelections.append($0) }
        let targets: [(SCNVector3, CADFeatureID)] = [
            (SCNVector3(-10, -10, 0), vertex),
            (SCNVector3(0, -10, 0), edge),
            (SCNVector3(0, 0, 0), face)
        ]
        for (world, feature) in targets + targets.reversed() {
            let projected = view.projectPoint(world)
            let point = NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            XCTAssertEqual(view.feature(at: point), feature)
            view.mouseDown(with: try click(at: point))
            XCTAssertEqual(view.agentCaptureMetadata["selectedSolidIndices"] as? [Int], [0],
                           "Toggling a native \(feature.kind.rawValue) must preserve whole-part selection.")
        }
        XCTAssertEqual(featureSelections, [[vertex], [vertex, edge], [vertex, edge, face], [vertex, edge], [vertex], []])
        XCTAssertEqual(partsChanged, 0)
        XCTAssertEqual(view.feature(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)), face,
                       "An internal tessellation seam must resolve to the native CAD face.")
    }

    @MainActor
    func testEmptySingleClickPreservesSelectionAndDoubleClickClearsEverythingWithoutFit() async throws {
        let view = try makeView()
        view.update(mesh: mesh(), mode: .edges, grid: false, command: ViewportCommand(.front),
                    selectedSolids: [0], hiddenSolids: [], selectedFeatures: [face])
        try await waitForPreparation(view)
        var partSelections = [Set<Int>]()
        var featureSelections = [[CADFeatureID]]()
        var clearCount = 0
        view.onSelectionChanged = { partSelections.append($0) }
        view.onFeatureSelectionChanged = { featureSelections.append($0) }
        view.onDeselectAll = { clearCount += 1 }
        let camera = try XCTUnwrap(view.pointOfView)
        let before = camera.simdTransform
        let empty = NSPoint(x: 4, y: 4)
        view.mouseDown(with: try click(at: empty))
        XCTAssertTrue(partSelections.isEmpty)
        XCTAssertTrue(featureSelections.isEmpty)
        view.mouseDown(with: try click(at: empty, count: 2))
        XCTAssertEqual(partSelections, [[]])
        XCTAssertEqual(featureSelections, [[]])
        XCTAssertEqual(clearCount, 1)
        for column in 0..<4 {
            XCTAssertEqual(camera.simdTransform[column], before[column], "Double-clicking empty space must not fit or move the camera.")
        }
    }

    @MainActor
    func testRightClickContextMenuPreservesFeatureAndPartSelections() async throws {
        let view = try makeView()
        view.update(mesh: mesh(), mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [0], hiddenSolids: [], selectedFeatures: [face])
        try await waitForPreparation(view)
        var partChanges = 0
        var featureChanges = 0
        view.onSelectionChanged = { _ in partChanges += 1 }
        view.onFeatureSelectionChanged = { _ in featureChanges += 1 }
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: NSPoint(x: view.bounds.midX, y: view.bounds.midY), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        // This is the menu preparation used by rightMouseUp, without starting
        // AppKit's blocking menu-tracking loop in the test runner.
        let menu = try XCTUnwrap(view.menu(for: rightClick))
        XCTAssertEqual(partChanges, 0)
        XCTAssertEqual(featureChanges, 0)
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Hide Selected Parts")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Deselect All")).isEnabled)

        view.update(mesh: mesh(), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        let featureMenu = try XCTUnwrap(view.menu(for: rightClick))
        XCTAssertTrue(try XCTUnwrap(featureMenu.item(withTitle: "Hide Selected Parts")).isEnabled,
                      "Selected features allow hiding their owning parts without selecting the whole part.")
        XCTAssertTrue(try XCTUnwrap(featureMenu.item(withTitle: "Deselect All")).isEnabled)
        let material = try XCTUnwrap(node("solid:0", in: view).geometry?.firstMaterial)
        let color = try XCTUnwrap((material.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0.70, accuracy: 1e-6, "Opening the menu must not apply whole-part selection styling.")
        XCTAssertEqual(partChanges, 0)
        XCTAssertEqual(featureChanges, 0)
        view.update(mesh: mesh(), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [0], selectedFeatures: [face])
        XCTAssertFalse(try XCTUnwrap(view.menu(for: rightClick)?.item(withTitle: "Hide Selected Parts")).isEnabled)
    }

    @MainActor
    func testFeatureHighlightReusesPreviewSourcesAndSurvivesSelectionAndVisibilityChanges() async throws {
        let view = try makeView()
        let preview = mesh()
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        let surface = try node("solid:0", in: view)
        let highlight = try node("feature:face:0:0", in: view)
        XCTAssertTrue(highlight.geometry?.sources(for: .vertex).first === surface.geometry?.sources(for: .vertex).first)
        try await waitForPreparation(view)
        try await waitForHighlight(highlight)
        XCTAssertFalse(highlight.isHidden)
        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [])
        XCTAssertTrue(highlight.isHidden)
        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        XCTAssertTrue(try node("feature:face:0:0", in: view) === highlight)
        XCTAssertTrue(try node("solid:0", in: view) === surface)
        XCTAssertFalse(highlight.isHidden)
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [0], selectedFeatures: [face])
        XCTAssertTrue(highlight.isHidden)
        XCTAssertNil(view.feature(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
    }

    private func sample(_ id: CADFeatureID, screen: SIMD2<Double>, world: SIMD3<Double> = .zero,
                        depth: Double = 10) -> ViewportFeaturePicking.Vertex {
        .init(id: id, world: world, screen: screen, depth: depth)
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    }

    @MainActor
    private func click(at point: NSPoint, count: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
    }

    @MainActor
    private func waitForPreparation(_ view: CADSceneView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while view.isPreparingResources, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(view.isPreparingResources)
    }

    @MainActor
    private func waitForHighlight(_ node: SCNNode) async throws {
        let deadline = Date().addingTimeInterval(5)
        while node.isHidden, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(node.isHidden)
    }

    @MainActor
    private func node(_ name: String, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene.rootNode.childNode(withName: name, recursively: true))
    }

    private func mesh() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-10, -10, 0], [10, -10, 0], [10, 10, 0], [-10, 10, 0]],
                                  triangles: [[0, 1, 2], [0, 2, 3]],
                                  edges: [[-10, -10, 0, 10, -10, 0]],
                                  bounds: [-10, -10, 0, 10, 10, 0], volume: 1, area: 400, solids: 1, faces: 1,
                                  buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-native-features",
                                  triangleSolids: [0, 0], edgeSolids: [0])
        preview.topology = CADTopology(vertices: [CADVertex(id: vertex, position: [-10, -10, 0])],
                                       edges: [CADEdge(id: edge, type: "LINE", length: 20, polyline: [[-10, -10, 0], [10, -10, 0]])],
                                       faces: [CADFace(id: face, type: "PLANE", area: 400, center: [0, 0, 0], normal: [0, 0, 1])], parts: [])
        preview.triangleFaces = [0, 0]
        preview.edgeFeatures = [0]
        return preview
    }
}
