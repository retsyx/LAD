import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportHoverTests: XCTestCase {
    private let vertex = CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: 0)
    private let edge = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 0)
    private let face = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)

    @MainActor
    func testTrackingIncludesMovementAndBoundaryEvents() throws {
        let view = try makeView()
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.contains {
            $0.options.contains(.mouseMoved) && $0.options.contains(.mouseEnteredAndExited) &&
            $0.options.contains(.inVisibleRect)
        })
    }

    @MainActor
    func testHoverFollowsTheClickableVertexEdgeAndFaceWithoutChangingSelection() async throws {
        let view = try await readyView()
        var partChanges = 0, featureChanges = 0, clears = 0
        view.onSelectionChanged = { _ in partChanges += 1 }
        view.onFeatureSelectionChanged = { _ in featureChanges += 1 }
        view.onDeselectAll = { clears += 1 }

        view.mouseEntered(with: try event(.mouseEntered, at: point([-10, -10, 0], in: view)))
        let vertexNode = try node(vertex, in: view)
        try await waitForHighlight(vertexNode)
        XCTAssertEqual(view.feature(at: point([-10, -10, 0], in: view)), vertex)

        view.mouseMoved(with: try event(.mouseMoved, at: point([0, -10, 0], in: view)))
        let edgeNode = try node(edge, in: view)
        try await waitForHighlight(edgeNode)
        XCTAssertTrue(vertexNode.isHidden)
        XCTAssertEqual(view.feature(at: point([0, -10, 0], in: view)), edge)

        view.mouseMoved(with: try event(.mouseMoved, at: point([0, 0, 0], in: view)))
        let faceNode = try node(face, in: view)
        try await waitForHighlight(faceNode)
        XCTAssertTrue(edgeNode.isHidden)
        XCTAssertEqual(view.feature(at: point([0, 0, 0], in: view)), face)
        XCTAssertEqual(partChanges, 0)
        XCTAssertEqual(featureChanges, 0, "Preselection must not become a measurement selection.")
        XCTAssertEqual(clears, 0)

        let geometry = try XCTUnwrap(faceNode.geometry)
        view.mouseMoved(with: try event(.mouseMoved, at: point([1, 1, 0], in: view)))
        XCTAssertTrue(try node(face, in: view) === faceNode)
        XCTAssertTrue(faceNode.geometry === geometry, "Moving within one face must reuse its highlight resources.")
        view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 2, y: 2)))
        XCTAssertTrue(faceNode.isHidden, "A button-held drag must not leave a hover at its starting feature.")
        view.mouseMoved(with: try event(.mouseMoved, at: point([1, 1, 0], in: view)))
        XCTAssertFalse(faceNode.isHidden)
        view.mouseExited(with: try event(.mouseExited, at: NSPoint(x: -1, y: -1)))
        XCTAssertTrue(faceNode.isHidden)
        XCTAssertEqual(partChanges, 0)
        XCTAssertEqual(featureChanges, 0)
    }

    @MainActor
    func testSelectedFeaturesUseThePartSelectionGoldAndFaceFinish() async throws {
        let view = try makeView()
        view.update(mesh: mesh(), mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [0], hiddenSolids: [], selectedFeatures: [vertex, edge, face])
        try await waitForPreparation(view)
        let part = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "solid:0", recursively: true)?.geometry?.firstMaterial)
        let partColor = try color(part.diffuse.contents)
        for feature in [vertex, edge, face] {
            let highlight = try node(feature, in: view)
            try await waitForHighlight(highlight)
            let material = try XCTUnwrap(highlight.geometry?.firstMaterial)
            assertEqualColor(try color(material.diffuse.contents), partColor)
            XCTAssertEqual(material.transparency, 1, accuracy: 1e-6)
        }
        let faceMaterial = try XCTUnwrap(node(face, in: view).geometry?.firstMaterial)
        XCTAssertEqual(faceMaterial.lightingModel, part.lightingModel)
        XCTAssertEqual(try number(faceMaterial.metalness.contents), try number(part.metalness.contents), accuracy: 1e-6)
        XCTAssertEqual(try number(faceMaterial.roughness.contents), try number(part.roughness.contents), accuracy: 1e-6)
        assertEqualColor(try color(faceMaterial.emission.contents), try color(part.emission.contents))
    }

    @MainActor
    func testHoverDoesNotDowngradeSelectedFeaturesAndExitPreservesSelection() async throws {
        let view = try makeView()
        let preview = mesh()
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        try await waitForPreparation(view)
        let selected = try node(face, in: view)
        try await waitForHighlight(selected)
        view.mouseMoved(with: try event(.mouseMoved, at: point([0, 0, 0], in: view)))
        XCTAssertEqual(selected.geometry?.firstMaterial?.transparency, 1)
        view.mouseExited(with: try event(.mouseExited, at: NSPoint(x: -1, y: -1)))
        XCTAssertFalse(selected.isHidden)
        XCTAssertEqual(selected.geometry?.firstMaterial?.transparency, 1)

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [])
        view.mouseMoved(with: try event(.mouseMoved, at: point([0, 0, 0], in: view)))
        try await waitForHighlight(selected)
        XCTAssertEqual(try XCTUnwrap(selected.geometry?.firstMaterial).transparency, 0.35, accuracy: 1e-6)
        XCTAssertEqual(selected.geometry?.firstMaterial?.transparencyMode, .singleLayer)
        view.mouseMoved(with: try event(.mouseMoved, at: NSPoint(x: 2, y: 2)))
        XCTAssertTrue(selected.isHidden, "Empty-space hover must clear only preselection.")
    }

    @MainActor
    func testHidingAndReplacingGeometryCannotRestoreAStaleHover() async throws {
        let view = try await readyView()
        view.mouseMoved(with: try event(.mouseMoved, at: point([0, 0, 0], in: view)))
        let oldHighlight = try node(face, in: view)
        // Hide immediately, while preparation of the new overlay may still be
        // in flight. Its completion must not reveal the hidden owner's face.
        view.update(mesh: mesh(), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [0])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(oldHighlight.isHidden)
        view.update(mesh: mesh(), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertTrue(oldHighlight.isHidden, "Showing a part must not restore an old hover.")

        view.mouseMoved(with: try event(.mouseMoved, at: point([0, 0, 0], in: view)))
        var replacement = mesh()
        replacement.stepPath = "/tmp/viewport-hover-replacement"
        view.update(mesh: replacement, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        view.update(mesh: nil, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(oldHighlight.parent)
        XCTAssertNil(view.scene?.rootNode.childNode(withName: name(face), recursively: true))
        XCTAssertNil(view.feature(at: NSPoint(x: 320, y: 240)))
    }

    @MainActor
    func testCameraAndViewportChangesClearHoverAndRefreshPickingCoordinates() async throws {
        let view = try await readyView()
        let preview = mesh()
        view.mouseMoved(with: try event(.mouseMoved, at: point([0, 0, 0], in: view)))
        let highlight = try node(face, in: view)
        try await waitForHighlight(highlight)
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.front),
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertTrue(highlight.isHidden)
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [])
        view.mouseMoved(with: try event(.mouseMoved, at: point([0, 0, 0], in: view)))
        try await waitForHighlight(highlight)
        view.setFrameSize(NSSize(width: 800, height: 600))
        view.layout()
        XCTAssertTrue(highlight.isHidden)
        let corner = point([-10, -10, 0], in: view)
        XCTAssertEqual(view.feature(at: corner), vertex, "A resized viewport must not use the old projected-feature cache.")
        view.mouseMoved(with: try event(.mouseMoved, at: corner))
        try await waitForHighlight(node(vertex, in: view))
    }

    @MainActor
    func testWindowResignationAndDetachmentClearOnlyHover() async throws {
        let view = try makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.update(mesh: mesh(), mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        try await waitForPreparation(view)
        let selected = try node(face, in: view)
        try await waitForHighlight(selected)
        view.mouseMoved(with: try event(.mouseMoved, at: point([-10, -10, 0], in: view)))
        let hovered = try node(vertex, in: view)
        try await waitForHighlight(hovered)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(hovered.isHidden)
        XCTAssertFalse(selected.isHidden)
        view.mouseMoved(with: try event(.mouseMoved, at: point([-10, -10, 0], in: view)))
        try await waitForHighlight(hovered)
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertTrue(hovered.isHidden, "Moving keyboard focus to the composer must clear preselection too.")
        XCTAssertFalse(selected.isHidden)
        view.mouseMoved(with: try event(.mouseMoved, at: point([-10, -10, 0], in: view)))
        try await waitForHighlight(hovered)
        view.removeFromSuperview()
        XCTAssertTrue(hovered.isHidden)
        XCTAssertFalse(selected.isHidden)
    }

    @MainActor
    func testHoverCacheStaysBoundedWhileRetainingSelectedGeometry() async throws {
        let view = try makeView()
        var preview = mesh()
        preview.bounds = [-45, -45, 0, 45, 45, 0]
        preview.vertices = [[-45, -45, 0], [45, -45, 0], [45, 45, 0], [-45, 45, 0]]
        preview.topology?.vertices = (0..<81).map { index in
            CADVertex(id: CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: index),
                      position: [Double(index % 9) * 10 - 40, Double(index / 9) * 10 - 40, 0])
        }
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [], selectedFeatures: [face])
        try await waitForPreparation(view)
        let selected = try node(face, in: view)
        try await waitForHighlight(selected)
        for vertex in try XCTUnwrap(preview.topology).vertices {
            view.mouseMoved(with: try event(.mouseMoved, at: point(vertex.position, in: view)))
        }
        let last = CADFeatureID(kind: .vertex, solidIndex: 0, localIndex: 80)
        try await waitForHighlight(node(last, in: view))
        let overlays = try XCTUnwrap(selected.parent).childNodes
        XCTAssertLessThanOrEqual(overlays.count, 66, "Exploring topology must not retain an overlay for every feature ever hovered.")
        XCTAssertTrue(try node(face, in: view) === selected)
        XCTAssertFalse(selected.isHidden, "Cache eviction must preserve selected geometry.")
    }

    @MainActor
    private func readyView() async throws -> CADSceneView {
        let view = try makeView()
        view.update(mesh: mesh(), mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [], hiddenSolids: [])
        try await waitForPreparation(view)
        return view
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        view.layout()
        return view
    }

    @MainActor
    private func point(_ position: [Double], in view: CADSceneView) -> NSPoint {
        let projected = view.projectPoint(SCNVector3(position[0], position[1], position[2]))
        return NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    }

    @MainActor
    private func waitForPreparation(_ view: CADSceneView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while view.isPreparingResources, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
    }

    @MainActor
    private func waitForHighlight(_ node: SCNNode) async throws {
        let deadline = Date().addingTimeInterval(5)
        while node.isHidden, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(node.isHidden)
    }

    private func name(_ id: CADFeatureID) -> String { "feature:\(id.kind.rawValue):\(id.solidIndex):\(id.localIndex)" }

    @MainActor
    private func node(_ id: CADFeatureID, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene?.rootNode.childNode(withName: name(id), recursively: true))
    }

    private func color(_ contents: Any?) throws -> NSColor {
        try XCTUnwrap((contents as? NSColor)?.usingColorSpace(.sRGB))
    }

    private func number(_ contents: Any?) throws -> Double { try XCTUnwrap(contents as? NSNumber).doubleValue }

    private func assertEqualColor(_ actual: NSColor, _ expected: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1e-6, file: file, line: line)
    }

    private func mesh() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-10, -10, 0], [10, -10, 0], [10, 10, 0], [-10, 10, 0]],
                                  triangles: [[0, 1, 2], [0, 2, 3]], edges: [[-10, -10, 0, 10, -10, 0]],
                                  bounds: [-10, -10, 0, 10, 10, 0], volume: 1, area: 400, solids: 1, faces: 1,
                                  buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-hover-features",
                                  triangleSolids: [0, 0], edgeSolids: [0])
        preview.topology = CADTopology(vertices: [CADVertex(id: vertex, position: [-10, -10, 0])],
                                       edges: [CADEdge(id: edge, type: "LINE", length: 20, polyline: [[-10, -10, 0], [10, -10, 0]])],
                                       faces: [CADFace(id: face, type: "PLANE", area: 400, center: [0, 0, 0], normal: [0, 0, 1])], parts: [])
        preview.triangleFaces = [0, 0]
        preview.edgeFeatures = [0]
        return preview
    }
}
