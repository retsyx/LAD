import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportPreparationTests: XCTestCase {
    @MainActor
    func testNewGeometryStaysHiddenUntilItsRenderResourcesArePrepared() async throws {
        let view = try makeView()
        view.update(mesh: mesh("first"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let first = try node("solid:0", in: view)
        let surfaceParent = try XCTUnwrap(first.parent)
        let edgeParent = try XCTUnwrap(node("edges:0", in: view).parent)
        XCTAssertTrue(view.isPreparingResources)
        XCTAssertTrue(surfaceParent.isHidden, "A model must not be presented before GPU preparation finishes.")
        XCTAssertTrue(edgeParent.isHidden)

        try await waitForPreparation(view)
        XCTAssertFalse(surfaceParent.isHidden)
        XCTAssertFalse(edgeParent.isHidden)
        XCTAssertTrue(try node("solid:0", in: view) === first)
    }

    @MainActor
    func testReplacementUsesOnlyTheLatestGeometryAndDisplayState() async throws {
        let view = try makeView()
        view.update(mesh: mesh("original"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let original = try node("solid:0", in: view)

        let replacement = mesh("replacement")
        view.update(mesh: replacement, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let latest = try node("solid:0", in: view)
        XCTAssertFalse(latest === original)
        XCTAssertNil(original.parent)
        XCTAssertTrue(view.isPreparingResources)
        XCTAssertTrue(try XCTUnwrap(latest.parent).isHidden)

        // Interaction can change while preparation is in flight. Completion
        // must use the latest state, including hidden parts and translucency.
        view.update(mesh: replacement, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [1], hiddenSolids: [0])
        try await waitForPreparation(view)
        XCTAssertTrue(try node("solid:0", in: view) === latest)
        XCTAssertTrue(latest.isHidden)
        XCTAssertFalse(try node("solid:1", in: view).isHidden)
        XCTAssertTrue(try node("edges:0", in: view).isHidden)
        XCTAssertFalse(try node("edges:1", in: view).isHidden)
        let material = try XCTUnwrap(node("solid:1", in: view).geometry?.firstMaterial)
        XCTAssertEqual(material.transparency, 1, accuracy: 1e-6)
        XCTAssertNotNil(material.shaderModifiers?[.fragment])
        XCTAssertEqual(material.transparencyMode, .aOne)
        XCTAssertFalse(material.writesToDepthBuffer)
        let color = try XCTUnwrap((material.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0.92, accuracy: 1e-6)
        XCTAssertEqual(color.greenComponent, 0.61, accuracy: 1e-6)
        XCTAssertEqual(color.blueComponent, 0.24, accuracy: 1e-6)
    }

    @MainActor
    func testClearingDuringPreparationCannotRestoreAnOldModel() async throws {
        let view = try makeView()
        view.update(mesh: mesh("first"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let surfaceParent = try XCTUnwrap(node("solid:0", in: view).parent)
        let edgeParent = try XCTUnwrap(node("edges:0", in: view).parent)
        XCTAssertTrue(view.isPreparingResources)
        view.update(mesh: nil, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertFalse(view.isPreparingResources)
        XCTAssertTrue(surfaceParent.childNodes.isEmpty)
        XCTAssertTrue(edgeParent.childNodes.isEmpty)

        // A later model's completed preparation provides an asynchronous
        // barrier before clearing again and checking delayed callbacks.
        view.update(mesh: mesh("next"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        try await waitForPreparation(view)
        view.update(mesh: mesh("canceled"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        view.update(mesh: nil, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(view.isPreparingResources)
        XCTAssertTrue(surfaceParent.childNodes.isEmpty)
        XCTAssertTrue(edgeParent.childNodes.isEmpty)
        XCTAssertTrue(surfaceParent.isHidden)
        XCTAssertTrue(edgeParent.isHidden)
    }

    @MainActor
    private func waitForPreparation(_ view: CADSceneView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while view.isPreparingResources, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(view.isPreparingResources, "Render preparation did not complete within five seconds.")
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is required to prepare viewport resources.")
        return CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
    }

    @MainActor
    private func node(_ name: String, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene?.rootNode.childNode(withName: name, recursively: true))
    }

    private func mesh(_ identity: String) -> PreviewMesh {
        PreviewMesh(vertices: [[-3, -1, 0], [-1, -1, 0], [-1, 1, 0], [-3, 1, 0],
                               [1, -1, 0], [3, -1, 0], [3, 1, 0], [1, 1, 0]],
                    triangles: [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]],
                    edges: [[-3, -1, 0, -1, -1, 0], [-1, -1, 0, -1, 1, 0],
                            [1, -1, 0, 3, -1, 0], [3, -1, 0, 3, 1, 0]],
                    bounds: [-3, -1, 0, 3, 1, 0], volume: 1, area: 8, solids: 2, faces: 2,
                    buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-preparation-\(identity)",
                    triangleSolids: [0, 0, 1, 1], edgeSolids: [0, 0, 1, 1])
    }
}
