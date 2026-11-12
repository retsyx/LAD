import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class CADAgentRendererTests: XCTestCase {
    @MainActor
    func testIndependentRendersUsePartColorsAndCurrentAssignments() async throws {
        var preview = twoParts()
        preview.parts = [PartNode(id: "red", name: "Red", solidIndices: [0],
                                 color: PartColor(red: 0.85, green: 0.08, blue: 0.08)),
                         PartNode(id: "green", name: "Green", solidIndices: [1],
                                  color: PartColor(red: 0.08, green: 0.85, blue: 0.08))]
        let authored = try await CADAgentRenderer.renderPNG(preview: preview, view: "top", display: .shaded,
                                                          width: 320, height: 240)
        let counts = dominantColors(try XCTUnwrap(NSBitmapImageRep(data: authored)))
        XCTAssertGreaterThan(counts.red, 10)
        XCTAssertGreaterThan(counts.green, 10)
        let overridden = try await CADAgentRenderer.renderPNG(preview: preview, view: "top", display: .shaded,
            solidColors: [0: PartColor(red: 0.08, green: 0.85, blue: 0.08)], width: 320, height: 240)
        let overrideCounts = dominantColors(try XCTUnwrap(NSBitmapImageRep(data: overridden)))
        XCTAssertEqual(overrideCounts.red, 0)
        XCTAssertGreaterThan(overrideCounts.green, counts.green)
        try authored.write(to: URL(fileURLWithPath: "/private/tmp/lad-agent-part-colors.png"))
    }

    @MainActor
    func testNamedViewsProduceRealPNGImagesInRequestedDimensions() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var images = [String: Data]()
        for name in ["isometric", "front", "back", "left", "right", "top", "bottom"] {
            let data = try await CADAgentRenderer.renderPNG(preview: box(), view: name, width: 320, height: 240)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, 320)
            XCTAssertEqual(bitmap.pixelsHigh, 240)
            XCTAssertGreaterThan(sampledColors(bitmap).count, 2, "The image must include rendered geometry, not just a clear background.")
            images[name] = data
        }
        XCTAssertNotEqual(images["front"], images["right"], "The requested view must change the rendered camera.")
        XCTAssertNotEqual(images["top"], images["bottom"])
    }

    @MainActor
    func testCapturePreservesLiveCameraMaterialsAndHiddenState() async throws {
        let view = try makeView()
        let preview = box()
        let color = PartColor(red: 0.25, green: 0.61, blue: 0.56)
        view.update(mesh: preview, mode: .translucent, grid: true, command: ViewportCommand(.right),
                    selectedSolids: [], hiddenSolids: [], solidColors: [0: color])
        try await ready(view)
        let camera = try XCTUnwrap(view.pointOfView)
        let pose = camera.simdTransform
        let material = try XCTUnwrap(view.scene.rootNode.childNode(withName: "solid:0", recursively: true)?.geometry?.firstMaterial)
        let diffuse = try XCTUnwrap(material.diffuse.contents as? NSColor)
        let transparency = material.transparency
        let captured = try await CADAgentRenderer.captureWithMetadata(view: view)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: captured.png))
        XCTAssertEqual(bitmap.pixelsWide, 400)
        XCTAssertEqual(bitmap.pixelsHigh, 300)
        let capturePose = try XCTUnwrap(captured.metadata["cameraTransform"] as? [Double])
        XCTAssertEqual(capturePose.count, 16)
        for column in 0..<4 {
            for row in 0..<4 { XCTAssertEqual(capturePose[column * 4 + row], Double(pose[column][row])) }
        }
        XCTAssertEqual(captured.metadata["display"] as? String, "translucent")
        XCTAssertEqual(captured.metadata["gridVisible"] as? Bool, true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: captured.metadata))
        for column in 0..<4 { XCTAssertEqual(camera.simdTransform[column], pose[column]) }
        XCTAssertEqual(material.diffuse.contents as? NSColor, diffuse)
        XCTAssertEqual(material.transparency, transparency)
        XCTAssertEqual(material.transparencyMode, .aOne)
        XCTAssertFalse(view.isPreparingResources)
        XCTAssertTrue(view.hasRenderableGeometry)

        // A separate image uses its own view and camera. It must leave the
        // currently visible user's scene untouched too.
        _ = try await CADAgentRenderer.renderPNG(preview: preview, view: "top", projection: .perspective,
                                               display: .wireframe, width: 160, height: 120)
        for column in 0..<4 { XCTAssertEqual(camera.simdTransform[column], pose[column]) }
        XCTAssertEqual(material.diffuse.contents as? NSColor, diffuse)
    }

    @MainActor
    func testCaptureMetadataTracksActualCameraProjectionVisibilityAndSelectionWithoutMutation() async throws {
        let view = try makeView()
        let feature = CADFeatureID(kind: .face, solidIndex: 1, localIndex: 0)
        view.update(mesh: twoParts(), mode: .translucent, grid: true, command: ViewportCommand(.right),
                    selectedSolids: [1], hiddenSolids: [0], projection: .isometric, selectedFeatures: [feature])
        try await ready(view)
        let camera = try XCTUnwrap(view.pointOfView)
        let before = camera.simdWorldTransform
        let metadata = view.agentCaptureMetadata
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: metadata))
        let matrix = try XCTUnwrap(metadata["cameraTransform"] as? [Double])
        XCTAssertEqual(matrix.count, 16)
        XCTAssertEqual(metadata["cameraTransformLayout"] as? String, "column-major")
        for column in 0..<4 {
            for row in 0..<4 { XCTAssertEqual(matrix[column * 4 + row], Double(before[column][row])) }
            XCTAssertEqual(camera.simdWorldTransform[column], before[column], "Reading capture metadata must leave the camera untouched.")
        }
        XCTAssertEqual(metadata["usesOrthographicProjection"] as? Bool, true)
        XCTAssertEqual(metadata["orthographicScale"] as? Double, camera.camera?.orthographicScale)
        XCTAssertEqual(metadata["fieldOfViewDegrees"] as? Double, camera.camera.map { Double($0.fieldOfView) })
        XCTAssertEqual(metadata["viewportSize"] as? [Double], [400, 300])
        XCTAssertEqual(metadata["hiddenSolidIndices"] as? [Int], [0])
        XCTAssertEqual(metadata["selectedSolidIndices"] as? [Int], [1])
        XCTAssertEqual(metadata["display"] as? String, "translucent")
        XCTAssertEqual(metadata["gridVisible"] as? Bool, true)
        let features = try XCTUnwrap(metadata["selectedFeatures"] as? [[String: Any]])
        XCTAssertEqual(features.first?["id"] as? String, feature.id)
        XCTAssertEqual(features.first?["kind"] as? String, "face")
        XCTAssertEqual(features.first?["solidIndex"] as? Int, 1)

        // Camera commands and direct camera movement must both be reflected:
        // metadata is derived from the actual view, not a stale default pose.
        try view.configureAgentView(named: "top")
        let top = try XCTUnwrap(view.agentCaptureMetadata["cameraTransform"] as? [Double])
        XCTAssertNotEqual(top, matrix)
        camera.localTranslate(by: SCNVector3(3, -4, 2))
        let moved = try XCTUnwrap(view.agentCaptureMetadata["cameraTransform"] as? [Double])
        XCTAssertNotEqual(moved, top)
        view.update(mesh: twoParts(), mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], projection: .perspective)
        let perspective = view.agentCaptureMetadata
        XCTAssertEqual(perspective["usesOrthographicProjection"] as? Bool, false)
        XCTAssertEqual(perspective["hiddenSolidIndices"] as? [Int], [])
        XCTAssertEqual(perspective["selectedSolidIndices"] as? [Int], [])
        XCTAssertEqual((perspective["selectedFeatures"] as? [[String: Any]])?.count, 0)
    }

    @MainActor
    func testRenderingHonorsPartVisibilityAndDisplayColors() async throws {
        let preview = twoParts()
        let colors = [0: PartColor(red: 0.85, green: 0.08, blue: 0.08),
                      1: PartColor(red: 0.08, green: 0.85, blue: 0.08)]
        let all = try await CADAgentRenderer.renderPNG(preview: preview, view: "top", display: .shaded,
                                                     solidColors: colors, width: 320, height: 240)
        let greenOnly = try await CADAgentRenderer.renderPNG(preview: preview, view: "top", display: .shaded,
                                                           hiddenSolids: [0], solidColors: colors, width: 320, height: 240)
        let allCounts = dominantColors(try XCTUnwrap(NSBitmapImageRep(data: all)))
        let isolatedCounts = dominantColors(try XCTUnwrap(NSBitmapImageRep(data: greenOnly)))
        XCTAssertGreaterThan(allCounts.red, 10)
        XCTAssertGreaterThan(allCounts.green, 10)
        XCTAssertEqual(isolatedCounts.red, 0, "Hidden geometry must not appear in an agent image.")
        XCTAssertGreaterThan(isolatedCounts.green, 10)
    }

    @MainActor
    func testImagesOfAPreparedPreviewReuseItsBuffersAndMatchAFreshConversion() async throws {
        var preview = twoParts()
        preview.triangles = Array(repeating: preview.triangles, count: 600).flatMap { $0 }
        preview.triangleSolids = Array(repeating: [0, 0, 1, 1], count: 600).flatMap { $0 }
        XCTAssertTrue(CADViewportPreparedMesh.requiresBackgroundPreparation(preview))
        let view = try makeView()
        view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        try await ready(view)
        XCTAssertTrue(view.hasRenderableGeometry)
        XCTAssertEqual(preview.preparedDisplay.conversions, 1)

        let colors = [0: PartColor(red: 0.85, green: 0.08, blue: 0.08), 1: PartColor(red: 0.08, green: 0.85, blue: 0.08)]
        // Isolated parts fit different bounds, and poses only move nodes; all
        // of them, and Finder thumbnails, present the same converted buffers.
        @MainActor func images(_ preview: PreviewMesh) async throws -> [Data] {
            var posed = preview
            posed.assemblyPose = AssemblyPose(positions: [:], solidTransforms: [1: [1, 0, 0, 2, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1]])
            return [
                try await CADAgentRenderer.renderPNG(preview: preview, view: "top", display: .shaded,
                                                     solidColors: colors, width: 320, height: 240),
                try await CADAgentRenderer.renderPNG(preview: preview, view: "front", projection: .perspective,
                    display: .edges, hiddenSolids: [0], solidColors: colors, width: 320, height: 240),
                try await CADAgentRenderer.renderPNG(preview: posed, view: "top", display: .shaded,
                                                     solidColors: colors, width: 320, height: 240),
                try await ProjectThumbnail.render(preview: preview, projection: .perspective, display: .edges,
                                                  hiddenSolids: [], solidColors: colors)
            ]
        }
        let shared = try await images(preview)
        XCTAssertEqual(preview.preparedDisplay.conversions, 1, "Images of a prepared preview must not convert it again.")

        var separate = preview
        separate.preparedDisplay = .init()
        let converted = try await images(separate)
        XCTAssertEqual(separate.preparedDisplay.conversions, 1)
        XCTAssertEqual(shared, converted, "Shared buffers must render the same images as a fresh conversion.")

        var moved = preview
        moved.vertices = moved.vertices.map { $0.map { $0 * 2 } }
        XCTAssertNil(CADViewportPreparedMesh.shared(for: moved), "A copy with different geometry must prepare its own buffers.")
    }

    @MainActor
    func testImageFileAndDataAPIsAgreeAndRejectInvalidRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-render-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("design.png")
        let written = try await CADAgentRenderer.render(preview: box(), to: url, width: 128, height: 96)
        XCTAssertEqual(written, url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        XCTAssertEqual(bitmap.pixelsWide, 128)
        XCTAssertEqual(bitmap.pixelsHigh, 96)
        for dimensions in [(0, 128), (128, 0), (2_049, 128), (128, 2_049)] {
            do {
                _ = try await CADAgentRenderer.renderPNG(preview: box(), width: dimensions.0, height: dimensions.1)
                XCTFail("Invalid image dimensions must be rejected.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("pixels")) }
        }
        do {
            _ = try await CADAgentRenderer.renderPNG(preview: box(), view: "unrecognized")
            XCTFail("Unknown view names must be rejected.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("isometric")) }
        let empty = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
                                volume: 0, area: 0, solids: 0, faces: 0, buildSeconds: 0, threads: 1, stepPath: "empty-render")
        do {
            _ = try await CADAgentRenderer.renderPNG(preview: empty)
            XCTFail("Invalid preview data must not produce a misleading blank design image.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("renderable geometry")) }
    }

    @MainActor
    func testCanceledRenderDoesNotWriteAnImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-canceled-render-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await CADAgentRenderer.render(preview: box(), to: url, width: 128, height: 96) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled rendering must stop before writing an image.") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    @MainActor
    private func ready(_ view: CADSceneView) async throws {
        while view.isPreparingCaptureResources { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func sampledColors(_ bitmap: NSBitmapImageRep) -> Set<String> {
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
            }
        }
        return colors
    }

    private func dominantColors(_ bitmap: NSBitmapImageRep) -> (red: Int, green: Int) {
        var red = 0, green = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 1.5 * c.greenComponent && c.redComponent > 0.25 { red += 1 }
                if c.greenComponent > 1.5 * c.redComponent && c.greenComponent > 0.25 { green += 1 }
            }
        }
        return (red, green)
    }

    private func box() -> PreviewMesh {
        PreviewMesh(vertices: [[-3,-2,-1],[3,-2,-1],[3,2,-1],[-3,2,-1],[-3,-2,1],[3,-2,1],[3,2,1],[-3,2,1]],
                    triangles: [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
                                [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]],
                    edges: [[-3,-2,-1,3,-2,-1],[3,-2,-1,3,2,-1],[3,2,-1,-3,2,-1],[-3,2,-1,-3,-2,-1],
                            [-3,-2,1,3,-2,1],[3,-2,1,3,2,1],[3,2,1,-3,2,1],[-3,2,1,-3,-2,1]],
                    bounds: [-3,-2,-1,3,2,1], volume: 48, area: 88, solids: 1, faces: 6,
                    buildSeconds: 0, threads: 1, stepPath: "/tmp/agent-render-box",
                    triangleSolids: Array(repeating: 0, count: 12), edgeSolids: Array(repeating: 0, count: 8))
    }

    private func twoParts() -> PreviewMesh {
        var preview = PreviewMesh(vertices: [[-5,-1,0],[-3,-1,0],[-3,1,0],[-5,1,0],[3,-1,0],[5,-1,0],[5,1,0],[3,1,0]],
                                  triangles: [[0,1,2],[0,2,3],[4,5,6],[4,6,7]], edges: [],
                                  bounds: [-5,-1,0,5,1,0], volume: 2, area: 8, solids: 2, faces: 2,
                                  buildSeconds: 0, threads: 1, stepPath: "/tmp/agent-render-visibility", triangleSolids: [0,0,1,1])
        preview.topology = CADTopology(vertices: [], edges: [], faces: [], parts: [
            CADPart(solidIndex: 0, area: 4, volume: 1, bounds: [-5,-1,0,-3,1,0], centroid: [-4,0,0]),
            CADPart(solidIndex: 1, area: 4, volume: 1, bounds: [3,-1,0,5,1,0], centroid: [4,0,0])
        ])
        return preview
    }
}
