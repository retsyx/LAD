import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class CADAgentArbitraryCameraTests: XCTestCase {
    @MainActor
    func testArbitraryAnglesAndRollReachActualCameraAndRenderedPixelsInBothProjections() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let yaw = 23.0, elevation = 17.0, roll = 37.0
        let radians = Double.pi / 180
        let expectedBack = SIMD3(cos(elevation * radians) * cos(yaw * radians),
                                 cos(elevation * radians) * sin(yaw * radians), sin(elevation * radians))
        for projection in [ViewportProjectionMode.perspective, .isometric] {
            let plain = try await CADAgentRenderer.renderWithMetadata(preview: assembly(), projection: projection,
                display: .shaded, solidColors: colors, width: 320, height: 240,
                camera: CADAgentCamera(yawDegrees: yaw, elevationDegrees: elevation))
            let rolled = try await CADAgentRenderer.renderWithMetadata(preview: assembly(), projection: projection,
                display: .shaded, solidColors: colors, width: 320, height: 240,
                camera: CADAgentCamera(yawDegrees: yaw, elevationDegrees: elevation, rollDegrees: roll))
            let back = try column(plain.metadata, 2)
            assertVector(back, expectedBack)
            assertVector(try column(rolled.metadata, 2), back)
            assertVector(try column(rolled.metadata, 3), try column(plain.metadata, 3))
            let right = try column(plain.metadata, 0), up = try column(plain.metadata, 1)
            let rolledRight = try column(rolled.metadata, 0)
            XCTAssertEqual(simd_dot(rolledRight, right), cos(roll * radians), accuracy: 0.00001)
            XCTAssertEqual(simd_dot(rolledRight, up), -sin(roll * radians), accuracy: 0.00001)
            XCTAssertEqual(plain.metadata["usesOrthographicProjection"] as? Bool, projection == .isometric)
            XCTAssertGreaterThan(try pixels(plain.png).count, 100)
            XCTAssertGreaterThan(try pixels(rolled.png).count, 100)
            XCTAssertNotEqual(plain.png, rolled.png, "Roll must rotate the actual asymmetric design image, not only its metadata.")
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: rolled.metadata))
            if projection == .isometric {
                try rolled.png.write(to: URL(fileURLWithPath: "/tmp/lad-agent-arbitrary-camera-roll.png"))
            }
        }
    }

    @MainActor
    func testExplicitPositionAndTargetAreCapturedExactlyWithoutMovingTheLiveViewport() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let live = CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        live.update(mesh: assembly(), mode: .translucent, grid: true, command: ViewportCommand(.right),
                    selectedSolids: [0], hiddenSolids: [1], projection: .perspective, solidColors: colors)
        while live.isPreparingCaptureResources { try await Task.sleep(for: .milliseconds(5)) }
        let liveCamera = try XCTUnwrap(live.pointOfView)
        let livePose = liveCamera.simdWorldTransform
        let liveMetadata = live.agentCaptureMetadata
        let liveMaterial = try XCTUnwrap(live.scene.rootNode.childNode(withName: "solid:0", recursively: true)?.geometry?.firstMaterial)
        let liveDiffuse = try XCTUnwrap(liveMaterial.diffuse.contents as? NSColor)
        let position = SIMD3<Double>(35, -20, 30), target = SIMD3<Double>(1, 2, 1)
        let backward = simd_normalize(position - target)
        for projection in [ViewportProjectionMode.perspective, .isometric] {
            let captured = try await CADAgentRenderer.renderWithMetadata(preview: assembly(), view: "front", projection: projection,
                display: .shaded, solidColors: colors, width: 320, height: 240,
                camera: CADAgentCamera(rollDegrees: 23, position: [35, -20, 30], target: [1, 2, 1]))
            assertVector(try column(captured.metadata, 3), position)
            assertVector(try column(captured.metadata, 2), backward)
            XCTAssertEqual(captured.metadata["cameraPosition"] as? [Double], [35, -20, 30])
            XCTAssertEqual(captured.metadata["cameraTarget"] as? [Double], [1, 2, 1])
            let fieldOfView = try XCTUnwrap(captured.metadata["fieldOfViewDegrees"] as? Double)
            XCTAssertEqual(fieldOfView, 38, accuracy: 0.0001)
            let scale = try XCTUnwrap(captured.metadata["orthographicScale"] as? Double)
            XCTAssertEqual(scale, simd_length(position - target) * tan(fieldOfView * .pi / 360), accuracy: 0.0001)
            XCTAssertEqual(captured.metadata["usesOrthographicProjection"] as? Bool, projection == .isometric)
            XCTAssertEqual(captured.metadata["viewportSize"] as? [Double], [320, 240])
            XCTAssertGreaterThan(try pixels(captured.png).count, 50)
            for index in 0..<4 { XCTAssertEqual(liveCamera.simdWorldTransform[index], livePose[index]) }
            XCTAssertEqual(liveMaterial.diffuse.contents as? NSColor, liveDiffuse)
            XCTAssertEqual(live.agentCaptureMetadata["hiddenSolidIndices"] as? [Int], liveMetadata["hiddenSolidIndices"] as? [Int])
            XCTAssertEqual(live.agentCaptureMetadata["selectedSolidIndices"] as? [Int], liveMetadata["selectedSolidIndices"] as? [Int])
            XCTAssertEqual(live.agentCaptureMetadata["gridVisible"] as? Bool, true)
            XCTAssertEqual(live.agentCaptureMetadata["display"] as? String, "translucent")
        }
    }

    @MainActor
    func testRelativeZoomChangesDistanceProjectionScaleAndVisiblePixelExtent() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let target = SIMD3<Double>(-0.5, 0.5, 2.5)
        for projection in [ViewportProjectionMode.perspective, .isometric] {
            let normal = try await CADAgentRenderer.renderWithMetadata(preview: assembly(), projection: projection,
                display: .shaded, solidColors: colors, width: 320, height: 240,
                camera: CADAgentCamera(yawDegrees: -47, elevationDegrees: 29))
            let zoomed = try await CADAgentRenderer.renderWithMetadata(preview: assembly(), projection: projection,
                display: .shaded, solidColors: colors, width: 320, height: 240,
                camera: CADAgentCamera(yawDegrees: -47, elevationDegrees: 29, zoom: 2))
            let firstDistance = simd_length(try column(normal.metadata, 3) - target)
            let secondDistance = simd_length(try column(zoomed.metadata, 3) - target)
            XCTAssertEqual(firstDistance / secondDistance, projection == .isometric ? 1 : 2, accuracy: 0.00001,
                           "Orthographic zoom changes scale while perspective zoom moves the eye toward the target.")
            XCTAssertEqual(normal.metadata["cameraTarget"] as? [Double], [-0.5, 0.5, 2.5])
            XCTAssertEqual(zoomed.metadata["cameraTarget"] as? [Double], [-0.5, 0.5, 2.5])
            let firstScale = try XCTUnwrap(normal.metadata["orthographicScale"] as? Double)
            let secondScale = try XCTUnwrap(zoomed.metadata["orthographicScale"] as? Double)
            XCTAssertEqual(firstScale / secondScale, 2, accuracy: 0.00001)
            assertVector(try column(normal.metadata, 2), try column(zoomed.metadata, 2))
            let firstPixels = try pixels(normal.png), secondPixels = try pixels(zoomed.png)
            XCTAssertGreaterThan(secondPixels.count, firstPixels.count * 2,
                                 "Zoom must visibly enlarge the design in both camera projections.")
            XCTAssertGreaterThan(secondPixels.width, firstPixels.width * 3 / 2)
            XCTAssertGreaterThan(secondPixels.height, firstPixels.height * 3 / 2)
        }
    }

    @MainActor
    func testSubsetFittingPrecedesRelativeZoomAndPNGFileAPIsForwardTheCamera() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let preview = assembly(), center = SIMD3<Double>(5.5, 2.5, 3)
        for projection in [ViewportProjectionMode.perspective, .isometric] {
            let fitted = try await CADAgentRenderer.renderWithMetadata(preview: preview, projection: projection,
                display: .shaded, hiddenSolids: [0], solidColors: colors, width: 320, height: 240,
                camera: CADAgentCamera(yawDegrees: 36, elevationDegrees: 27))
            let zoomed = try await CADAgentRenderer.renderWithMetadata(preview: preview, projection: projection,
                display: .shaded, hiddenSolids: [0], solidColors: colors, width: 320, height: 240,
                camera: CADAgentCamera(yawDegrees: 36, elevationDegrees: 27, zoom: 2))
            let firstDistance = simd_length(try column(fitted.metadata, 3) - center)
            let secondDistance = simd_length(try column(zoomed.metadata, 3) - center)
            XCTAssertEqual(firstDistance / secondDistance, projection == .isometric ? 1 : 2, accuracy: 0.00001)
            let back = try column(fitted.metadata, 2)
            assertVector(try column(fitted.metadata, 3) - back * firstDistance, center)
            XCTAssertEqual(fitted.metadata["hiddenSolidIndices"] as? [Int], [0])
            XCTAssertEqual(try pixels(fitted.png).redCount, 0)
            XCTAssertGreaterThan(try pixels(zoomed.png).count, try pixels(fitted.png).count)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-camera-file-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = CADAgentCamera(yawDegrees: 12, elevationDegrees: 41, rollDegrees: 19, zoom: 1.3)
        let direct = try await CADAgentRenderer.renderPNG(preview: preview, display: .shaded, solidColors: colors,
            width: 160, height: 120, camera: camera)
        let file = try await CADAgentRenderer.render(preview: preview, to: folder.appendingPathComponent("angle.png"),
            display: .shaded, solidColors: colors, width: 160, height: 120, camera: camera)
        XCTAssertEqual(try Data(contentsOf: file), direct)
        let preset = try await CADAgentRenderer.renderPNG(preview: preview, display: .shaded, solidColors: colors, width: 160, height: 120)
        XCTAssertNotEqual(direct, preset, "Both file and data wrappers must forward the arbitrary camera controls.")
    }

    @MainActor
    func testInvalidCameraIsRejectedBeforeAnEmptyPreviewCanAllocateDrawingResources() async throws {
        let empty = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1], volume: 0,
            area: 0, solids: 0, faces: 0, buildSeconds: 0, threads: 1, stepPath: "empty-camera-check")
        do {
            _ = try await CADAgentRenderer.renderWithMetadata(preview: empty, camera: CADAgentCamera(zoom: 0))
            XCTFail("Invalid camera controls must fail before rendering starts.")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("renderable geometry"))
            XCTAssertTrue(error.localizedDescription.lowercased().contains("zoom"))
        }
    }

    private var colors: [Int: PartColor] {
        [0: PartColor(red: 0.9, green: 0.08, blue: 0.08), 1: PartColor(red: 0.08, green: 0.85, blue: 0.12)]
    }

    private func column(_ metadata: [String: Any], _ column: Int) throws -> SIMD3<Double> {
        let values = try XCTUnwrap(metadata["cameraTransform"] as? [Double])
        XCTAssertEqual(values.count, 16)
        return SIMD3(values[column * 4], values[column * 4 + 1], values[column * 4 + 2])
    }

    private func assertVector(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
                              file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<3 { XCTAssertEqual(actual[index], expected[index], accuracy: 0.0001, file: file, line: line) }
    }

    private struct Pixels {
        var count: Int
        var redCount: Int
        var width: Int
        var height: Int
    }

    private func pixels(_ data: Data) throws -> Pixels {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1, count = 0, redCount = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let red = r > 0.22 && r > g * 1.4 && r > b * 1.4
                let green = g > 0.22 && g > r * 1.4 && g > b * 1.4
                guard red || green else { continue }
                count += 1
                if red { redCount += 1 }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return Pixels(count: count, redCount: redCount, width: max(0, maxX - minX + 1), height: max(0, maxY - minY + 1))
    }

    /// Two differently colored, offset closed prisms make camera direction,
    /// roll, magnification and isolated-component fitting visible in pixels.
    private func assembly() -> PreviewMesh {
        let boxes: [([Double], [Double])] = [([-8, -3, -1], [2, 3, 1]), ([4, 1, 0], [7, 4, 6])]
        let localFaces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                          [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        let localEdges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        var vertices: [[Double]] = [], triangles: [[Int]] = [], edges: [[Double]] = []
        var triangleSolids: [Int] = [], edgeSolids: [Int] = [], parts: [CADPart] = []
        for (index, box) in boxes.enumerated() {
            let low = box.0, high = box.1, offset = vertices.count
            let points = [[low[0], low[1], low[2]], [high[0], low[1], low[2]], [high[0], high[1], low[2]], [low[0], high[1], low[2]],
                          [low[0], low[1], high[2]], [high[0], low[1], high[2]], [high[0], high[1], high[2]], [low[0], high[1], high[2]]]
            vertices += points
            triangles += localFaces.map { $0.map { $0 + offset } }
            triangleSolids += Array(repeating: index, count: localFaces.count)
            edges += localEdges.map { points[$0.0] + points[$0.1] }
            edgeSolids += Array(repeating: index, count: localEdges.count)
            let size = (0..<3).map { high[$0] - low[$0] }
            let area = 2 * (size[0] * size[1] + size[1] * size[2] + size[0] * size[2])
            parts.append(CADPart(solidIndex: index, area: area, volume: size.reduce(1, *), bounds: low + high,
                                 centroid: (0..<3).map { (low[$0] + high[$0]) / 2 }))
        }
        return PreviewMesh(vertices: vertices, triangles: triangles, edges: edges, bounds: [-8, -3, -1, 7, 4, 6],
            volume: parts.map(\.volume).reduce(0, +), area: parts.map(\.area).reduce(0, +), solids: 2, faces: 12,
            buildSeconds: 0, threads: 1, stepPath: "arbitrary-camera-assembly", triangleSolids: triangleSolids,
            edgeSolids: edgeSolids, topology: CADTopology(vertices: [], edges: [], faces: [], parts: parts))
    }
}
