import AppKit
import SceneKit
import XCTest
@testable import LAD

final class ViewportPartsTests: XCTestCase {
    @MainActor
    func testOptionClickTogglesPartsIndependentlyAcrossProjectionAndDisplayModes() async throws {
        for projection in ViewportProjectionMode.allCases {
            for mode in [ViewportDisplayMode.edges, .wireframe] {
                let view = makeView()
                let preview = mesh()
                view.update(mesh: preview, mode: mode, grid: false, command: ViewportCommand(.top),
                            selectedSolids: [], hiddenSolids: [], projection: projection)
                try await waitForPreparation(view)
                var selections = [Set<Int>]()
                var featureChanges = 0
                var clearCount = 0
                view.onSelectionChanged = { selections.append($0) }
                view.onFeatureSelectionChanged = { _ in featureChanges += 1 }
                view.onDeselectAll = { clearCount += 1 }
                let points = [-2.0, 2.0].map { x in
                    let projected = view.projectPoint(SCNVector3(x, 0, 0))
                    return NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                }
                for point in [points[0], points[1], points[0], points[0]] {
                    view.mouseDown(with: try optionClick(at: point))
                }
                XCTAssertEqual(selections, [[0], [0, 1], [1], [0, 1]],
                               "Option-click must toggle only the clicked part in \(mode.rawValue), \(projection.rawValue).")
                XCTAssertEqual(featureChanges, 0)

                let empty = NSPoint(x: 4, y: 4)
                view.mouseDown(with: try optionClick(at: empty))
                XCTAssertEqual(selections.count, 4, "An empty Option-click must preserve part selection.")
                view.mouseDown(with: try optionClick(at: empty, count: 2))
                XCTAssertEqual(selections.last, [])
                XCTAssertEqual(clearCount, 1)

                view.update(mesh: preview, mode: mode, grid: false, command: nil,
                            selectedSolids: [1], hiddenSolids: [0], projection: projection)
                view.mouseDown(with: try optionClick(at: points[0]))
                XCTAssertEqual(selections.count, 5, "A user-hidden part must not be selectable.")
            }
        }
    }

    @MainActor
    func testOwnedEdgesHideTogetherWithTheirPartAndPreserveMultiselection() async throws {
        let view = makeView()
        var selectionChanges = 0
        view.onSelectionChanged = { _ in selectionChanges += 1 }
        view.update(mesh: mesh(), mode: .edges, grid: false, command: nil,
                    selectedSolids: [0, 1], hiddenSolids: [0])
        let first = try node("solid:0", in: view)
        let second = try node("solid:1", in: view)
        XCTAssertTrue(first.isHidden)
        XCTAssertFalse(second.isHidden)
        XCTAssertTrue(try node("edges:0", in: view).isHidden)
        XCTAssertFalse(try node("edges:1", in: view).isHidden)
        let edgeColor = try XCTUnwrap((node("edges:1", in: view).geometry?.firstMaterial?.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(edgeColor.redComponent, 0.1,
            "Selecting a part must leave ordinary interior edges dark; only its projected silhouette receives the highlight stroke.")
        let firstColor = try XCTUnwrap(first.geometry?.firstMaterial?.diffuse.contents as? NSColor)
        let secondColor = try XCTUnwrap(second.geometry?.firstMaterial?.diffuse.contents as? NSColor)
        XCTAssertEqual(firstColor, secondColor, "All selected parts receive the selection material.")

        view.update(mesh: mesh(), mode: .edges, grid: false, command: nil,
                    selectedSolids: [0, 1], hiddenSolids: [])
        XCTAssertFalse(first.isHidden)
        XCTAssertFalse(try node("edges:0", in: view).isHidden)
        XCTAssertTrue(try node("solid:0", in: view) === first, "Visibility changes preserve the installed geometry.")
        await Task.yield()
        XCTAssertEqual(selectionChanges, 0, "Installing a mesh must not clear the project-owned selection.")
    }

    @MainActor
    func testLegacyWireframeDoesNotLeaveHiddenPartsInCombinedEdgeBuffer() throws {
        let view = makeView()
        view.update(mesh: mesh(owners: nil), mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [0])
        XCTAssertTrue(try node("legacy-edges", in: view).isHidden)
        XCTAssertTrue(try node("solid:0", in: view).isHidden)
        let visible = try node("solid:1", in: view)
        XCTAssertFalse(visible.isHidden)
        XCTAssertEqual(visible.geometry?.firstMaterial?.fillMode, .lines)
    }

    @MainActor
    func testInvalidEdgeOwnersUseSafeLegacyVisibility() throws {
        let view = makeView()
        view.update(mesh: mesh(owners: [0]), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [1])
        XCTAssertTrue(try node("legacy-edges", in: view).isHidden)
        XCTAssertFalse(try node("solid:0", in: view).isHidden)
        XCTAssertTrue(try node("solid:1", in: view).isHidden)
    }

    @MainActor
    func testWireframeRemainsVisibleWhenNoAnalyticEdgesExist() throws {
        let view = makeView()
        var preview = mesh(owners: nil)
        preview.edges = []
        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertFalse(try node("solid:0", in: view).isHidden)
        XCTAssertFalse(try node("solid:1", in: view).isHidden)
    }

    @MainActor
    private func makeView() -> CADSceneView {
        CADSceneView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    }

    private func optionClick(at point: NSPoint, count: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .option,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
    }

    @MainActor
    private func waitForPreparation(_ view: CADSceneView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        SCNTransaction.flush()
    }

    @MainActor
    private func node(_ name: String, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene.rootNode.childNode(withName: name, recursively: true))
    }

    private func mesh(owners: [Int]? = [0, 0, 1, 1]) -> PreviewMesh {
        PreviewMesh(vertices: [[-3, -1, 0], [-1, -1, 0], [-1, 1, 0], [-3, 1, 0],
                               [1, -1, 0], [3, -1, 0], [3, 1, 0], [1, 1, 0]],
                    triangles: [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]],
                    edges: [[-3, -1, 0, -1, -1, 0], [-1, -1, 0, -1, 1, 0],
                            [1, -1, 0, 3, -1, 0], [3, -1, 0, 3, 1, 0]],
                    bounds: [-3, -1, 0, 3, 1, 0], volume: 1, area: 8, solids: 2, faces: 2,
                    buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-parts-test.step",
                    triangleSolids: [0, 0, 1, 1], edgeSolids: owners)
    }
}
