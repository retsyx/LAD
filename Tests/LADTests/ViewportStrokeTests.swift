import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportStrokeTests: XCTestCase {
    @MainActor
    func testStrokeBuffersRejectInvalidSegmentsAndContainFiniteIndexedTriangles() throws {
        let geometry = CADStrokeGeometry.make([
            [-1, 0, 0, 1, 0, 0],
            [0, 0, 0, 0, 0, 0],
            [0, 0, 0, .nan, 1, 0],
            [0, 0, 0, 1, 0],
            [0, 0, 0, .infinity, 0, 0]
        ], color: .white, width: 4, viewportHeight: 192)
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
        XCTAssertGreaterThan(positions.vectorCount, 0)
        for source in geometry.sources {
            XCTAssertEqual(source.vectorCount, positions.vectorCount)
            XCTAssertTrue(source.usesFloatComponents)
            for vector in 0..<source.vectorCount {
                for component in 0..<source.componentsPerVector {
                    XCTAssertTrue(try value(source, vector: vector, component: component).isFinite,
                                  "Malformed or degenerate input must never upload a NaN to Metal.")
                }
            }
        }
        for element in geometry.elements {
            XCTAssertEqual(element.primitiveType, .triangles)
            for offset in 0..<(element.primitiveCount * 3) {
                let index = try index(element, at: offset)
                XCTAssertGreaterThanOrEqual(index, 0)
                XCTAssertLessThan(index, positions.vectorCount)
            }
        }
        let empty = CADStrokeGeometry.make([[0, 0, 0, 0, 0, 0]], color: .white, width: 4, viewportHeight: 192)
        XCTAssertEqual(empty.elements.reduce(0) { $0 + $1.primitiveCount }, 0)
    }

    @MainActor
    func testMetalStrokeHasVisibleWidthGainAndConstantWidthThroughBothProjectionZooms() throws {
        for orthographic in [false, true] {
            let thin = CADStrokeGeometry.make([[-1, 0, 0, 1, 0, 0]], color: .white, width: 1.4, viewportHeight: 192)
            let thick = CADStrokeGeometry.make([[-1, 0, 0, 1, 0, 0]], color: .white, width: 4, viewportHeight: 192)
            let thinWidth = try strokeWidth(render(thin, orthographic: orthographic, zoomedOut: false))
            let nearWidth = try strokeWidth(render(thick, orthographic: orthographic, zoomedOut: false))
            let farWidth = try strokeWidth(render(thick, orthographic: orthographic, zoomedOut: true))
            XCTAssertGreaterThan(thinWidth, 0, "The ordinary CAD edge must render on Metal.")
            XCTAssertGreaterThanOrEqual(nearWidth, thinWidth + 2, "Selection must be visibly wider than an ordinary edge.")
            XCTAssertGreaterThanOrEqual(nearWidth, 3)
            XCTAssertLessThanOrEqual(nearWidth, 6)
            XCTAssertEqual(Double(nearWidth), Double(farWidth), accuracy: 1,
                           "Screen-space strokes must retain their width while zooming either projection.")
        }
    }

    @MainActor
    func testCopiedStrokeParametersRespectLogicalViewportAndRenderTargetResolution() throws {
        let original = CADStrokeGeometry.make([[-1, 0, 0, 1, 0, 0]], color: .white, width: 1.4, viewportHeight: 192)
        CADStrokeGeometry.setWidth(4, on: original)
        CADStrokeGeometry.setViewportHeight(192, on: original)
        let copy = try XCTUnwrap(original.copy() as? SCNGeometry)
        CADStrokeGeometry.copyParameters(from: original, to: copy)
        XCTAssertEqual(try number(copy, key: CADStrokeGeometry.widthKey), 4)
        XCTAssertEqual(try number(copy, key: CADStrokeGeometry.viewportHeightKey), 192)
        let normal = try strokeWidth(render(copy, orthographic: true, zoomedOut: false))
        let retina = try strokeWidth(render(copy, orthographic: true, zoomedOut: false, size: CGSize(width: 512, height: 384)))
        XCTAssertEqual(Double(retina), Double(normal * 2), accuracy: 2,
                       "Cloned agent screenshots need the same logical stroke width at their actual render resolution.")
        CADStrokeGeometry.setViewportHeight(384, on: copy)
        let resized = try strokeWidth(render(copy, orthographic: true, zoomedOut: false, size: CGSize(width: 512, height: 384)))
        XCTAssertEqual(Double(resized), Double(normal), accuracy: 1)
    }

    @MainActor
    func testThickEdgesRemainOccludedByFrontFaces() throws {
        for orthographic in [false, true] {
            for z in [-0.5, -0.01] {
                let behind = CADStrokeGeometry.make([[-0.7, 0, z, 0.7, 0, z]], color: .white, width: 6, viewportHeight: 192)
                XCTAssertTrue(try XCTUnwrap(behind.firstMaterial).readsFromDepthBuffer)
                XCTAssertEqual(try strokeWidth(render(behind, orthographic: orthographic, zoomedOut: false, occluder: true)), 0,
                               "A thicker overlay must not expose an edge even just behind a solid face (z=\(z)).")
            }
            for z in [0.0, 0.1] {
                let visible = CADStrokeGeometry.make([[-0.7, 0, z, 0.7, 0, z]], color: .white, width: 6, viewportHeight: 192)
                XCTAssertGreaterThan(try strokeWidth(render(visible, orthographic: orthographic, zoomedOut: false, occluder: true)), 3,
                                     "Front-facing and exactly coplanar edges must remain visible (z=\(z)).")
            }
        }
    }

    @MainActor
    func testViewportEdgeHoverAndSelectionReusePreparedCoreAndHaloWithSelectionPrecedence() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let preview = edgePreview()
        let edge = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [])
        view.layout()
        try await ready(view)
        let projected = view.projectPoint(SCNVector3(0, -10, 0))
        let point = NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        view.mouseMoved(with: try mouse(.mouseMoved, at: point))
        let overlay = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "feature:edge:0:0", recursively: true))
        try await visible(overlay)
        let core = try XCTUnwrap(overlay.geometry)
        let halo = try XCTUnwrap(overlay.childNode(withName: "edge-halo", recursively: false)?.geometry)
        XCTAssertEqual(try number(core, key: CADStrokeGeometry.widthKey), 3)
        XCTAssertEqual(try number(halo, key: CADStrokeGeometry.widthKey), 5)
        XCTAssertTrue(try XCTUnwrap(core.firstMaterial).isDoubleSided)
        XCTAssertTrue(try XCTUnwrap(halo.firstMaterial).readsFromDepthBuffer)
        XCTAssertEqual(core.sources(for: .vertex).first?.data, halo.sources(for: .vertex).first?.data)

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [], selectedFeatures: [edge])
        XCTAssertTrue(overlay.geometry === core)
        XCTAssertTrue(overlay.childNode(withName: "edge-halo", recursively: false)?.geometry === halo)
        XCTAssertEqual(try number(core, key: CADStrokeGeometry.widthKey), 4)
        XCTAssertEqual(try number(halo, key: CADStrokeGeometry.widthKey), 5.5)
        let part = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "solid:0", recursively: true)?.geometry?.firstMaterial)
        XCTAssertEqual(core.firstMaterial?.diffuse.contents as? NSColor, part.diffuse.contents as? NSColor)
        view.mouseMoved(with: try mouse(.mouseMoved, at: point))
        XCTAssertEqual(try number(core, key: CADStrokeGeometry.widthKey), 4, "Hover must not soften selected styling.")
        view.mouseExited(with: try mouse(.mouseExited, at: NSPoint(x: -1, y: -1)))
        XCTAssertFalse(overlay.isHidden, "Leaving the view must preserve the selected edge.")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [0], selectedFeatures: [edge])
        XCTAssertTrue(overlay.isHidden, "Both core and halo must disappear with their owning part.")
    }

    @MainActor
    func testCircularEdgeComparisonRendersNativeVisualReviewArtifacts() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 512, height: 512), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let preview = circularPreview()
        let colors = [0: PartColor(red: 0.38, green: 0.67, blue: 0.82)]
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], projection: .isometric, solidColors: colors)
        view.layout()
        try await ready(view)
        let baseline = try await CADAgentRenderer.capturePNG(view: view)
        try baseline.write(to: URL(fileURLWithPath: "/tmp/lad-edge-baseline.png"))
        try assertCircularCoverage(baseline, radius: 14, view: view, gold: false, label: "Baseline inner edge")

        let position = view.projectPoint(SCNVector3(-18, 0, 0))
        view.mouseMoved(with: try mouse(.mouseMoved, at: NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))))
        let overlay = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "feature:edge:0:0", recursively: true))
        try await visible(overlay)
        let hovered = try await CADAgentRenderer.capturePNG(view: view)
        try hovered.write(to: URL(fileURLWithPath: "/tmp/lad-edge-hover.png"))
        try assertCircularCoverage(hovered, radius: 14, view: view, gold: false, label: "Unselected inner edge during hover")
        try assertCircularCoverage(hovered, radius: 18, view: view, gold: true, label: "Hovered outer edge")

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .isometric, solidColors: colors,
                    selectedFeatures: [CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)])
        let selected = try await CADAgentRenderer.capturePNG(view: view)
        try selected.write(to: URL(fileURLWithPath: "/tmp/lad-edge-selected.png"))
        try assertCircularCoverage(selected, radius: 14, view: view, gold: false, label: "Unselected inner edge during selection")
        try assertCircularCoverage(selected, radius: 18, view: view, gold: true, label: "Selected outer edge")
        XCTAssertNotEqual(baseline, hovered, "Hover must be visible in an actual native viewport capture.")
        XCTAssertNotEqual(hovered, selected, "Selected and hovered edges must remain visually distinguishable.")
    }

    @MainActor
    private func assertCircularCoverage(_ data: Data, radius: Double, view: CADSceneView, gold: Bool, label: String,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: data), file: file, line: line)
        let scaleX = CGFloat(image.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(image.pixelsHigh) / view.bounds.height
        let samples = 360
        var covered = 0
        for index in 0..<samples {
            // Sample between tessellation vertices too: depth round-off can
            // leave their endpoints intact while making long arcs disappear.
            let angle = (Double(index) + 0.37) * 2 * Double.pi / Double(samples)
            let projected = view.projectPoint(SCNVector3(radius * cos(angle), radius * sin(angle), 0))
            let x = Int((CGFloat(projected.x) * scaleX).rounded())
            let y = image.pixelsHigh - 1 - Int((CGFloat(projected.y) * scaleY).rounded())
            var found = false
            for dy in -1...1 {
                for dx in -1...1 {
                    guard x + dx >= 0, x + dx < image.pixelsWide, y + dy >= 0, y + dy < image.pixelsHigh,
                          let color = image.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.sRGB) else { continue }
                    if gold {
                        found = found || (color.redComponent > 0.5 && color.redComponent > color.blueComponent + 0.12 &&
                                          color.greenComponent > color.blueComponent + 0.08)
                    } else {
                        found = found || (color.redComponent < 0.30 && color.greenComponent < 0.35 && color.blueComponent < 0.40)
                    }
                }
            }
            if found { covered += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(covered) / Double(samples), 0.99,
                                    "\(label) must be continuous rather than dashed by depth fighting (\(covered)/\(samples) samples visible).",
                                    file: file, line: line)
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
        let stroke = SCNNode(geometry: geometry)
        stroke.renderingOrder = 2
        scene.rootNode.addChildNode(stroke)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    }

    private func strokeWidth(_ image: NSBitmapImageRep) throws -> Int {
        let x = image.pixelsWide / 2
        return try (0..<image.pixelsHigh).reduce(0) { count, y in
            let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return count + (color.redComponent > 0.2 && color.greenComponent > 0.2 && color.blueComponent > 0.2 ? 1 : 0)
        }
    }

    private func value(_ source: SCNGeometrySource, vector: Int, component: Int) throws -> Double {
        let offset = source.dataOffset + vector * source.dataStride + component * source.bytesPerComponent
        XCTAssertLessThanOrEqual(offset + source.bytesPerComponent, source.data.count)
        return try source.data.withUnsafeBytes { bytes in
            if source.bytesPerComponent == 4 { return Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)) }
            if source.bytesPerComponent == 8 { return bytes.loadUnaligned(fromByteOffset: offset, as: Double.self) }
            throw XCTSkip("Unexpected floating-point vertex component size.")
        }
    }

    private func index(_ element: SCNGeometryElement, at index: Int) throws -> Int {
        let offset = index * element.bytesPerIndex
        let data = try XCTUnwrap(element.data)
        XCTAssertLessThanOrEqual(offset + element.bytesPerIndex, data.count)
        return try data.withUnsafeBytes { bytes in
            switch element.bytesPerIndex {
            case 1: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
            case 2: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            case 4: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            default: throw XCTSkip("Unexpected geometry index size.")
            }
        }
    }

    @MainActor
    private func number(_ geometry: SCNGeometry, key: String) throws -> Double {
        try XCTUnwrap(geometry.value(forKey: key) as? NSNumber).doubleValue
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
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        if type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    }

    private func edgePreview() -> PreviewMesh {
        let edge = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)
        var preview = PreviewMesh(vertices: [[-10, -10, 0], [10, -10, 0], [10, 10, 0], [-10, 10, 0]],
            triangles: [[0, 1, 2], [0, 2, 3]], edges: [[-10, -10, 0, 10, -10, 0]],
            bounds: [-10, -10, 0, 10, 10, 0], volume: 1, area: 400, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-stroke-features",
            triangleSolids: [0, 0], edgeSolids: [0])
        preview.topology = CADTopology(vertices: [],
            edges: [CADEdge(id: edge, type: "LINE", length: 20, polyline: [[-10, -10, 0], [10, -10, 0]])],
            faces: [], parts: [])
        preview.edgeFeatures = [0]
        return preview
    }

    private func circularPreview() -> PreviewMesh {
        let count = 240
        func circle(_ radius: Double) -> [[Double]] {
            (0...count).map { index in
                let angle = Double(index) * 2 * Double.pi / Double(count)
                return [radius * cos(angle), radius * sin(angle), 0]
            }
        }
        let outer = circle(18), inner = circle(14)
        let segments = [outer, inner].flatMap { points in
            zip(points, points.dropFirst()).map { $0.0 + $0.1 }
        }
        let triangles = (0..<count).map { [0, $0 + 1, ($0 + 1) % count + 1] }
        var preview = PreviewMesh(vertices: [[0, 0, 0]] + Array(outer.dropLast()), triangles: triangles,
            edges: segments, bounds: [-18, -18, 0, 18, 18, 0], volume: 0, area: .pi * 18 * 18,
            solids: 1, faces: 1, buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-stroke-circle",
            triangleSolids: Array(repeating: 0, count: count), edgeSolids: Array(repeating: 0, count: count * 2))
        preview.topology = CADTopology(vertices: [], edges: [
            CADEdge(id: CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0), type: "CIRCLE", length: 36 * .pi, polyline: outer),
            CADEdge(id: CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 1), type: "CIRCLE", length: 28 * .pi, polyline: inner)
        ], faces: [CADFace(id: CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0), type: "PLANE",
                          area: .pi * 18 * 18, center: [0, 0, 0], normal: [0, 0, 1])], parts: [])
        preview.triangleFaces = Array(repeating: 0, count: count)
        preview.edgeFeatures = Array(repeating: 0, count: count) + Array(repeating: 1, count: count)
        return preview
    }
}
