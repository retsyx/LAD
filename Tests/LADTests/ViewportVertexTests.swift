import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportVertexTests: XCTestCase {
    private let vertex = CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: 0)
    private let edge = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)

    @MainActor
    func testNativeVertexIsRoundVisibleAndKeepsItsScreenSizeThroughBothProjectionZooms() throws {
        for orthographic in [false, true] {
            let geometry = CADVertexGeometry.make([0, 0, 0], color: .white, diameter: 12, viewportHeight: 192)
            let near = try footprint(render(geometry, orthographic: orthographic, zoomedOut: false))
            let far = try footprint(render(geometry, orthographic: orthographic, zoomedOut: true))
            XCTAssertGreaterThan(near.count, 50, "A native Metal vertex marker must remain plainly visible.")
            XCTAssertGreaterThanOrEqual(near.width, 10)
            XCTAssertLessThanOrEqual(near.width, 14)
            XCTAssertEqual(Double(near.width), Double(near.height), accuracy: 1)
            let coverage = Double(near.count) / Double(max(1, near.width * near.height))
            XCTAssertGreaterThan(coverage, 0.60)
            XCTAssertLessThan(coverage, 0.90, "The marker must be a round dot rather than a square point primitive.")
            XCTAssertEqual(Double(far.width), Double(near.width), accuracy: 1)
            XCTAssertEqual(Double(far.height), Double(near.height), accuracy: 1,
                           "Zooming must change geometry scale while retaining a readable vertex diameter.")
        }
    }

    @MainActor
    func testVertexCopiesRetainLogicalDiameterAtRetinaAndResizedCaptureResolutions() throws {
        let original = CADVertexGeometry.make([0, 0, 0], color: .white, diameter: 10, viewportHeight: 192)
        CADVertexGeometry.setDiameter(12, on: original)
        let copy = try XCTUnwrap(original.copy() as? SCNGeometry)
        CADVertexGeometry.copyParameters(from: original, to: copy)
        XCTAssertEqual(try number(copy, CADVertexGeometry.diameterKey), 12)
        XCTAssertEqual(try number(copy, CADVertexGeometry.viewportHeightKey), 192)
        let normal = try footprint(render(copy, orthographic: true, zoomedOut: false))
        let retina = try footprint(render(copy, orthographic: true, zoomedOut: false, size: CGSize(width: 512, height: 384)))
        XCTAssertEqual(Double(retina.width), Double(normal.width * 2), accuracy: 2)
        XCTAssertEqual(Double(retina.height), Double(normal.height * 2), accuracy: 2,
                       "A 2× capture must preserve the same logical marker diameter.")
        CADVertexGeometry.setViewportHeight(384, on: copy)
        let resized = try footprint(render(copy, orthographic: true, zoomedOut: false, size: CGSize(width: 512, height: 384)))
        XCTAssertEqual(Double(resized.width), Double(normal.width), accuracy: 1)
        XCTAssertEqual(Double(resized.height), Double(normal.height), accuracy: 1)
    }

    @MainActor
    func testRoundVertexRemainsVisibleOnItsFaceButCannotShowThroughNearerGeometry() throws {
        for orthographic in [false, true] {
            for z in [-0.5, -0.01] {
                let geometry = CADVertexGeometry.make([0, 0, z], color: .white, diameter: 12, viewportHeight: 192)
                let material = try XCTUnwrap(geometry.firstMaterial)
                XCTAssertTrue(material.readsFromDepthBuffer)
                XCTAssertFalse(material.writesToDepthBuffer)
                XCTAssertEqual(try footprint(render(geometry, orthographic: orthographic, zoomedOut: false, occluder: true)).count, 0,
                               "A dot just behind a face must be occluded rather than exposing hidden topology (z=\(z)).")
            }
            for z in [0.0, 0.1] {
                let geometry = CADVertexGeometry.make([0, 0, z], color: .white, diameter: 12, viewportHeight: 192)
                XCTAssertGreaterThan(try footprint(render(geometry, orthographic: orthographic, zoomedOut: false, occluder: true)).count, 50,
                                     "Coplanar and front vertices must remain visible on their own faces (z=\(z)).")
            }
        }
    }

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
    private func render(_ geometry: SCNGeometry, orthographic: Bool, zoomedOut: Bool,
                        size: CGSize = CGSize(width: 256, height: 192), occluder: Bool = false) throws -> NSBitmapImageRep {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = orthographic
        camera.camera?.orthographicScale = zoomedOut ? 4 : 2
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 100
        camera.camera?.wantsHDR = false
        camera.position = SCNVector3(0, 0, zoomedOut ? 8 : 4)
        scene.rootNode.addChildNode(camera)
        if occluder {
            let plane = SCNPlane(width: 2, height: 2)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(srgbRed: 0.05, green: 0.15, blue: 0.3, alpha: 1)
            material.isDoubleSided = true
            plane.materials = [material]
            scene.rootNode.addChildNode(SCNNode(geometry: plane))
        }
        let dot = SCNNode(geometry: geometry)
        dot.renderingOrder = 2
        scene.rootNode.addChildNode(dot)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    }

    private func footprint(_ image: NSBitmapImageRep) throws -> (width: Int, height: Int, count: Int) {
        var minX = image.pixelsWide, minY = image.pixelsHigh, maxX = -1, maxY = -1, count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let c = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if c.redComponent > 0.65, c.greenComponent > 0.65, c.blueComponent > 0.65 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    count += 1
                }
            }
        }
        return (max(0, maxX - minX + 1), max(0, maxY - minY + 1), count)
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
    private func number(_ geometry: SCNGeometry, _ key: String) throws -> Double {
        try XCTUnwrap(geometry.value(forKey: key) as? NSNumber).doubleValue
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
