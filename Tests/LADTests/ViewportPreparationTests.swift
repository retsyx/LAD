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
    func testLargePreparationYieldsAndInstallsLatestStylePoseAndExplicitCamera() async throws {
        let view = try makeView(), preview = largeMesh("latest-state")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertTrue(view.isPreparingResources)
        XCTAssertFalse(view.hasRenderableGeometry, "Large CPU preparation must return before creating scene geometry.")
        XCTAssertNil(view.scene?.rootNode.childNode(withName: "solid:0", recursively: true))
        let pose = [1.0, 0, 0, 4, 0, 1, 0, -2, 0, 0, 1, 0, 0, 0, 0, 1]
        view.update(mesh: preview, mode: .translucent, grid: true, command: ViewportCommand(.top),
                    selectedSolids: [1], hiddenSolids: [0], projection: .isometric, solidTransforms: [1: pose])
        let requestedCamera = CADAgentCamera(yawDegrees: 25, elevationDegrees: 30, rollDegrees: 17, zoom: 1.2)
        try view.configureAgentView(named: "front", camera: requestedCamera)
        try await waitForPreparation(view)
        XCTAssertTrue(try node("solid:0", in: view).isHidden)
        let selected = try node("solid:1", in: view)
        XCTAssertFalse(selected.isHidden)
        XCTAssertEqual(selected.simdTransform.columns.3, SIMD4(4, -2, 0, 1))
        let color = try XCTUnwrap((selected.geometry?.firstMaterial?.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0.92, accuracy: 1e-6)
        XCTAssertFalse(try XCTUnwrap(selected.geometry?.firstMaterial).writesToDepthBuffer)
        let camera = try XCTUnwrap(view.pointOfView).simdTransform
        try view.configureAgentView(named: "front", camera: requestedCamera)
        XCTAssertEqual(view.pointOfView?.simdTransform, camera,
            "A camera configured while preparing must resolve from the final visible, posed bounds.")
    }

    @MainActor
    func testLargeReplacementAndEscapeCannotPublishStaleBuffersOrStrandPreparation() async throws {
        let view = try makeView()
        view.update(mesh: mesh("existing"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [1], hiddenSolids: [])
        try await waitForPreparation(view)
        view.update(mesh: largeMesh("discarded"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [1], hiddenSolids: [])
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        try await waitForPreparation(view)
        let unselected = try XCTUnwrap((node("solid:1", in: view).geometry?.firstMaterial?.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(unselected.redComponent, 0.70, accuracy: 1e-6,
            "Escape while preparing must neither invalidate the CPU generation nor skip the final unselected style.")

        view.update(mesh: largeMesh("replaced"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let final = mesh("replacement")
        view.update(mesh: final, mode: .shaded, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [1])
        let replacement = try node("solid:0", in: view)
        try await waitForPreparation(view)
        XCTAssertTrue(try node("solid:0", in: view) === replacement)
        XCTAssertEqual(replacement.geometry?.elements.first?.primitiveCount, 2)
        XCTAssertTrue(try node("solid:1", in: view).isHidden)
    }

    @MainActor
    func testDetachmentCancelsLargePreparationAndSameIdentityResumesOnReattachment() async throws {
        _ = NSApplication.shared
        let view = try makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        let preview = largeMesh("reattached")
        view.update(mesh: preview, mode: .edges, grid: false, command: ViewportCommand(.top),
                    selectedSolids: [1], hiddenSolids: [])
        XCTAssertTrue(view.isPreparingResources)
        window.contentView = nil
        // Yield to cancellation and any queued completion. Detached inputs may
        // be retained for reattachment, but cannot install a stale scene.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(view.hasRenderableGeometry)
        window.contentView = view
        try await waitForPreparation(view)
        XCTAssertTrue(view.hasRenderableGeometry)
        XCTAssertNotNil(view.scene?.rootNode.childNode(withName: "solid:1", recursively: true))
        XCTAssertEqual(view.agentCaptureMetadata["usesOrthographicProjection"] as? Bool, false)
    }

    @MainActor
    func testLargeCPUPreparationDoesNotKeepRemovedViewAlive() throws {
        weak var removed: CADSceneView?
        try autoreleasepool {
            let view = try makeView()
            removed = view
            view.update(mesh: largeMesh("released"), mode: .edges, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [])
            XCTAssertTrue(view.isPreparingResources)
        }
        XCTAssertNil(removed, "Pending CPU work must not retain the view through its task handle.")
    }

    @MainActor
    func testCubeDirectionWaitsForTheNewBoundsBeforeFitting() async throws {
        let view = try makeView()
        view.update(mesh: mesh("cube-existing"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        try await waitForPreparation(view)
        var preview = largeMesh("cube-replacement")
        preview.vertices = preview.vertices.map { $0.map { $0 * 100 } }
        preview.edges = preview.edges.map { $0.map { $0 * 100 } }
        preview.bounds = preview.bounds.map { $0 * 100 }
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let before = try XCTUnwrap(view.pointOfView).simdTransform
        view.selectOrientationCubeCorner(.rightBackTop)
        XCTAssertEqual(view.pointOfView?.simdTransform, before, "Do not start a transition fitted to the outgoing mesh.")
        XCTAssertFalse(view.isAnimatingCamera)
        try await waitForPreparation(view)
        let fitted = try XCTUnwrap(view.pointOfView).simdTransform
        view.selectOrientationCubeCorner(.rightBackTop)
        XCTAssertEqual(view.pointOfView?.simdTransform, fitted, "The queued corner must already fit the replacement's complete bounds.")
    }

    @MainActor
    func testViewsShareOneConversionThatContinuesWhileAnyViewWaits() async throws {
        let first = try makeView(), second = try makeView(), preview = largeMesh("shared")
        first.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        second.update(mesh: preview, mode: .shaded, grid: false, command: nil, selectedSolids: [1], hiddenSolids: [])
        // One view leaving must neither cancel nor restart the other's conversion.
        first.update(mesh: nil, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        try await waitForPreparation(second)
        XCTAssertTrue(second.hasRenderableGeometry)
        XCTAssertFalse(first.hasRenderableGeometry)
        XCTAssertEqual(preview.preparedDisplay.conversions, 1)

        // Returning to a prepared preview installs it without converting again.
        first.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        XCTAssertTrue(first.hasRenderableGeometry)
        try await waitForPreparation(first)
        XCTAssertEqual(preview.preparedDisplay.conversions, 1)
        XCTAssertEqual(try node("solid:1", in: first).geometry?.elements.first?.primitiveCount, 40_000)
    }

    @MainActor
    func testCaptureWaitResumesWhenPreparedAndStopsAtCancellationOrDeadline() async throws {
        let view = try makeView()
        view.update(mesh: largeMesh("awaited"), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertTrue(view.isPreparingCaptureResources)
        let expired = try await view.waitForCaptureResources(until: .now - .seconds(1))
        XCTAssertFalse(expired, "A passed deadline must not report prepared resources.")
        let canceled = Task { @MainActor in try await view.waitForCaptureResources(until: .now + .seconds(30)) }
        await Task.yield()
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("A canceled wait must throw.") } catch is CancellationError {}
        let prepared = try await view.waitForCaptureResources(until: .now + .seconds(30))
        XCTAssertTrue(prepared)
        XCTAssertFalse(view.isPreparingCaptureResources)
        XCTAssertTrue(view.hasRenderableGeometry)
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

    private func largeMesh(_ identity: String) -> PreviewMesh {
        var preview = mesh(identity)
        preview.triangles = Array(repeating: preview.triangles, count: 20_000).flatMap { $0 }
        preview.triangleSolids = Array(repeating: [0, 0, 1, 1], count: 20_000).flatMap { $0 }
        return preview
    }
}
