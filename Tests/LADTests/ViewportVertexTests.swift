import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportVertexTests: XCTestCase {
    private let vertex = CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: 0)
    private let edge = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)

    @MainActor
    func testViewportVertexHoverAndSelectionReuseNativeCenterAndCaptureVisibleArtifacts() async throws {
        let view = try makeView()
        let preview = cornerPreview()
        let colors = [0: PartColor(red: 0.38, green: 0.67, blue: 0.82)]
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], projection: .isometric, solidColors: colors)
        view.layout()
        try await ready(view)
        let point = projectedCorner(in: view)
        XCTAssertEqual(view.feature(at: NSPoint(x: point.x - 11, y: point.y)), vertex,
                       "A small native vertex needs the same usable screen-point acquisition radius as its visible target.")
        view.mouseMoved(with: try mouse(.mouseMoved, at: point))
        let overlay = try featureNode(vertex, in: view)
        try await visible(overlay)
        let center = try XCTUnwrap(overlay.geometry)
        XCTAssertEqual(center.elements.first?.primitiveType, .point)
        XCTAssertEqual(overlay.categoryBitMask, CADHighlightTechnique.seedCategory)
        XCTAssertTrue(overlay.childNodes.isEmpty, "Screen-space circles need only the native vertex center.")
        let material = try XCTUnwrap(center.firstMaterial)
        XCTAssertEqual(material.diffuse.contents as? NSColor, .red)
        XCTAssertFalse(material.readsFromDepthBuffer,
                       "Highlight overlays remain visible through other geometry.")
        XCTAssertFalse(material.writesToDepthBuffer)
        let hover = try await CADAgentRenderer.capturePNG(view: view)
        try hover.write(to: URL(fileURLWithPath: "/tmp/lad-vertex-hover.png"))
        XCTAssertGreaterThan(try markerPixels(hover, around: point, in: view), 35,
                             "A cloned native agent capture must contain the hovered dot, including its screen-size uniforms.")

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric, solidColors: colors, selectedFeatures: [vertex])
        try await ready(view)
        XCTAssertTrue(overlay.geometry === center)
        XCTAssertEqual(material.diffuse.contents as? NSColor, .blue)
        let selected = try await CADAgentRenderer.capturePNG(view: view)
        try selected.write(to: URL(fileURLWithPath: "/tmp/lad-vertex-selected.png"))
        XCTAssertGreaterThan(try markerPixels(selected, around: point, in: view), 45)
        XCTAssertNotEqual(hover, selected, "Hover and selection must be visually distinguishable in a rendered image.")

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [], projection: .isometric, solidColors: colors,
                    selectedFeatures: [vertex, edge])
        try await ready(view)
        let selectedEdge = try featureNode(edge, in: view)
        try await visible(selectedEdge)
        XCTAssertEqual(selectedEdge.geometry?.firstMaterial?.diffuse.contents as? NSColor, .red)
        XCTAssertEqual(material.diffuse.contents as? NSColor, .blue)
        view.mouseMoved(with: try mouse(.mouseMoved, at: point))
        XCTAssertEqual(material.diffuse.contents as? NSColor, .blue, "Hover cannot downgrade a selected dot.")
        view.mouseExited(with: try mouse(.mouseExited, at: NSPoint(x: -1, y: -1)))
        XCTAssertFalse(overlay.isHidden)
        view.setFrameSize(NSSize(width: 800, height: 600))
        view.layout()
        XCTAssertEqual((view.technique?.value(forKey: "cadReferenceHeight") as? NSNumber)?.doubleValue, 600)
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [0], projection: .isometric, solidColors: colors,
                    selectedFeatures: [vertex, edge])
        XCTAssertTrue(overlay.isHidden)
        XCTAssertNil(view.feature(at: projectedCorner(in: view)), "Hidden owners must exclude their vertices from picking as well as rendering.")
    }

    @MainActor
    private func markerPixels(_ data: Data, around point: NSPoint, in view: CADSceneView) throws -> Int {
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        let centerX = Int((point.x * scale).rounded())
        let centerY = image.pixelsHigh - 1 - Int((point.y * scale).rounded())
        let radius = Int((10 * scale).rounded())
        var count = 0
        for y in max(0, centerY - radius)...min(image.pixelsHigh - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(image.pixelsWide - 1, centerX + radius) {
                let c = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if c.redComponent > 0.5, c.redComponent > c.blueComponent + 0.12,
                   c.greenComponent > c.blueComponent + 0.08 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CADSceneView(frame: NSRect(x: 0, y: 0, width: 512, height: 512), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
    }

    @MainActor
    private func ready(_ view: CADSceneView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingCaptureResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingCaptureResources)
    }

    @MainActor
    private func visible(_ node: SCNNode) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while node.isHidden, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(node.isHidden)
    }

    @MainActor
    private func projectedCorner(in view: CADSceneView) -> NSPoint {
        let point = view.projectPoint(SCNVector3(-10, -10, 0))
        return NSPoint(x: CGFloat(point.x), y: CGFloat(point.y))
    }

    @MainActor
    private func featureNode(_ id: CADFeatureID, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene?.rootNode.childNode(withName: "feature:\(id.kind.rawValue):\(id.solidIndex):\(id.localIndex)", recursively: true))
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        if type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    }

    private func cornerPreview() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-10,-10,0],[10,-10,0],[10,10,0],[-10,10,0]],
            triangles: [[0,1,2],[0,2,3]], edges: [[-10,-10,0,10,-10,0]], bounds: [-10,-10,0,10,10,0],
            volume: 0, area: 400, solids: 1, faces: 1, buildSeconds: 0, threads: 1,
            stepPath: "/tmp/viewport-vertex-corner", triangleSolids: [0,0], edgeSolids: [0])
        preview.topology = CADTopology(vertices: [CADVertex(id: vertex, position: [-10,-10,0])],
            edges: [CADEdge(id: edge, type: "LINE", length: 20, polyline: [[-10,-10,0],[10,-10,0]])],
            faces: [], parts: [])
        preview.edgeFeatures = [0]
        return preview
    }
}
