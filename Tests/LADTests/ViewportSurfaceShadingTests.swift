import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportSurfaceShadingTests: XCTestCase {
    @MainActor
    func testExactCurvedSurfaceNormalsRemoveTriangulationDependentHighlightRipple() async throws {
        // This cylinder is invariant along X. Its staggered UV nodes, unequal
        // axial cells and alternating diagonals resemble an unstructured CAD
        // triangulation. Triangle averages vary along the axis although the
        // actual surface normal does not.
        let before = try await cylinderShot(exactNormals: false)
        let after = try await cylinderShot(exactNormals: true)
        try write(before.image, to: "/tmp/lad-surface-normals-before.png")
        try write(after.image, to: "/tmp/lad-surface-normals-after.png")

        let angles = stride(from: -0.7, through: 0.7, by: 0.05)
        let profiles = angles.map { angle -> (before: Double, after: Double) in
            let y = 2 * sin(angle), z = 2 * cos(angle)
            return (axialVariation(in: before, y: y, z: z), axialVariation(in: after, y: y, z: z))
        }
        let strongest = try XCTUnwrap(profiles.max { $0.before < $1.before })
        print("Curved highlight axial luminance variation: triangle-averaged=\(strongest.before), exact=\(strongest.after)")
        XCTAssertGreaterThan(strongest.before, 0.01,
            "The irregular curved control must reproduce visible triangle-dependent shading, rather than merely render two equivalent pictures.")
        XCTAssertLessThan(strongest.after, strongest.before * 0.3,
            "A smooth cylinder's highlight must cease following the irregular triangle layout when its exact surface normals are supplied.")
        XCTAssertLessThan(strongest.after, 0.015,
            "Exact normals should leave only small rasterization/view-vector differences along the otherwise invariant surface.")
    }

    @MainActor
    func testRepresentativeSavedPebbleWithExactAndTriangleAveragedNormals() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_SURFACE_NORMALS_PREVIEW"] else {
            throw XCTSkip("Set LAD_SURFACE_NORMALS_PREVIEW to inspect the current pebble preview independently of the live design.")
        }
        let preview = try PreviewMesh.loadResult(at: URL(fileURLWithPath: path))
        XCTAssertTrue(preview.hasValidNormals)
        XCTAssertGreaterThan(preview.solids, 1)
        var before = preview
        before.normals = nil
        let hidden = Set((0..<preview.solids).filter { $0 != 1 })
        let colors = [1: PartColor(red: 0.32, green: 0.67, blue: 0.80)]
        let beforePNG = try await CADAgentRenderer.renderPNG(preview: before, view: "isometric", projection: .isometric,
            display: .shaded, hiddenSolids: hidden, solidColors: colors, width: 1_024, height: 768)
        let afterPNG = try await CADAgentRenderer.renderPNG(preview: preview, view: "isometric", projection: .isometric,
            display: .shaded, hiddenSolids: hidden, solidColors: colors, width: 1_024, height: 768)
        try beforePNG.write(to: URL(fileURLWithPath: "/tmp/lad-pebble-shading-before.png"))
        try afterPNG.write(to: URL(fileURLWithPath: "/tmp/lad-pebble-shading-after.png"))
        XCTAssertNotEqual(beforePNG, afterPNG, "The representative image must actually consume the newly generated lighting normals.")
    }

    private struct Shot {
        var image: NSBitmapImageRep
        var projection: simd_float4x4
    }

    @MainActor
    private func cylinderShot(exactNormals: Bool) async throws -> Shot {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        view.update(mesh: cylinder(exactNormals: exactNormals), mode: .shaded, grid: false, command: nil,
            selectedSolids: [], hiddenSolids: [], solidColors: [0: PartColor(red: 0.32, green: 0.67, blue: 0.80)])
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingResources, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(view.isPreparingResources)
        let cameraNode = try XCTUnwrap(view.pointOfView)
        let camera = try XCTUnwrap(cameraNode.camera)
        // The long camera distance makes any PBR perspective view-vector
        // variation negligible while orthographic projection keeps the curved
        // patch large. Camera-local studio lighting remains production lighting.
        cameraNode.position = SCNVector3(0, 0, 1_000)
        cameraNode.look(at: SCNVector3Zero)
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 3
        camera.automaticallyAdjustsZRange = false
        camera.zNear = 1
        camera.zFar = 2_000
        let png = try await CADAgentRenderer.capturePNG(view: view)
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        let size = CGSize(width: image.pixelsWide, height: image.pixelsHigh)
        let matrix = simd_float4x4(camera.projectionTransform(withViewportSize: size)) * simd_inverse(cameraNode.simdWorldTransform)
        return Shot(image: image, projection: matrix)
    }

    private func axialVariation(in shot: Shot, y: Double, z: Double) -> Double {
        var luminances = [Double]()
        for x in stride(from: -2.4, through: 2.4, by: 0.02) {
            let clip = shot.projection * SIMD4<Float>(Float(x), Float(y), Float(z), 1)
            let column = Int((Double(clip.x / clip.w) * 0.5 + 0.5) * Double(shot.image.pixelsWide))
            let row = Int((0.5 - Double(clip.y / clip.w) * 0.5) * Double(shot.image.pixelsHigh))
            guard let color = shot.image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
            luminances.append(0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent) + 0.0722 * Double(color.blueComponent))
        }
        guard luminances.count > 200 else { return .infinity }
        let sorted = luminances.sorted()
        // Percentiles exclude a few rasterization outliers without obscuring
        // the broad, visible bright/dark patches caused by averaged normals.
        return sorted[sorted.count * 95 / 100] - sorted[sorted.count * 5 / 100]
    }

    private func cylinder(exactNormals: Bool) -> PreviewMesh {
        let xs = [-3.0, -2.7, -1.1, -0.9, -0.2, 0.4, 0.7, 2.1, 2.2, 3.0]
        let angles = stride(from: -1.2, through: 1.2, by: 0.3).map { $0 }
        var vertices = [[Double]](), normals = [[Double]](), triangles = [[Int]]()
        for (i, x) in xs.enumerated() {
            for (j, baseAngle) in angles.enumerated() {
                // Keep every node on the exact cylinder while breaking the
                // artificial alignment of angular rings between axial cells.
                // Adjacent angles remain strictly ordered (0.10 rad minimum).
                let angle = baseAngle + 0.10 * sin(Double(i) * 2.399 + Double(j) * 1.71)
                vertices.append([x, 2 * sin(angle), 2 * cos(angle)])
                normals.append([0, sin(angle), cos(angle)])
            }
        }
        for i in 0..<xs.count - 1 {
            for j in 0..<angles.count - 1 {
                let a = i * angles.count + j, b = (i + 1) * angles.count + j
                let c = b + 1, d = a + 1
                if (i + j).isMultiple(of: 2) { triangles.append(contentsOf: [[a, b, c], [a, c, d]]) }
                else { triangles.append(contentsOf: [[a, b, d], [b, c, d]]) }
            }
        }
        var mesh = PreviewMesh(vertices: vertices, triangles: triangles, edges: [],
            bounds: [-3, -2, 0, 3, 2, 2], volume: 1, area: 1, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/surface-shading-\(exactNormals ? "exact" : "averaged").step",
            triangleSolids: Array(repeating: 0, count: triangles.count))
        mesh.normals = exactNormals ? normals : nil
        return mesh
    }

    private func write(_ image: NSBitmapImageRep, to path: String) throws {
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
