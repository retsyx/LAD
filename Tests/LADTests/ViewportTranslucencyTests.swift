import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportTranslucencyTests: XCTestCase {
    @MainActor
    func testProductionPhysicallyBasedFacesBlendTheirCompleteShading() async throws {
        let preview = nestedBoxes()
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        let opaque = try await CADAgentRenderer.capturePNG(view: view)
        try opaque.write(to: URL(fileURLWithPath: "/tmp/lad-translucency-pbr-opaque.png"))
        view.update(mesh: preview, mode: .translucent, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        let translucent = try await CADAgentRenderer.capturePNG(view: view)
        try translucent.write(to: URL(fileURLWithPath: "/tmp/lad-translucency-pbr-translucent.png"))
        let before = try XCTUnwrap(NSBitmapImageRep(data: opaque)), after = try XCTUnwrap(NSBitmapImageRep(data: translucent))
        for (x, y) in [(0, 0), (before.pixelsWide - 1, 0),
                       (0, before.pixelsHigh - 1), (before.pixelsWide - 1, before.pixelsHigh - 1)] {
            let a = try XCTUnwrap(before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let b = try XCTUnwrap(after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01)
            XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01)
            XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01)
            XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.01,
                           "Translucent compositing must retain the scene background and its opacity.")
        }
        var sampleCount = 0, opaqueSum = 0.0, translucentSum = 0.0
        for y in stride(from: 0, to: before.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: before.pixelsWide, by: 2) {
                let a = try XCTUnwrap(before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let b = try XCTUnwrap(after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let bright = (Double(a.redComponent) + Double(a.greenComponent) + Double(a.blueComponent)) / 3
                if bright > 0.65 {
                    sampleCount += 1; opaqueSum += bright
                    translucentSum += (Double(b.redComponent) + Double(b.greenComponent) + Double(b.blueComponent)) / 3
                }
            }
        }
        print("PBR bright face mean: opaque",opaqueSum / Double(sampleCount),"translucent",translucentSum / Double(sampleCount),"count",sampleCount)
        XCTAssertGreaterThan(sampleCount, 500)
        XCTAssertLessThan(translucentSum / Double(sampleCount), opaqueSum / Double(sampleCount) - 0.15,
            "Translucency must attenuate the complete physically based shaded face, including its highlights.")
        view.update(mesh: preview, mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [])
        let restoredPNG = try await CADAgentRenderer.capturePNG(view: view)
        let restored = try XCTUnwrap(NSBitmapImageRep(data: restoredPNG))
        for y in stride(from: 0, to: before.pixelsHigh, by: 15) {
            for x in stride(from: 0, to: before.pixelsWide, by: 15) {
                let a = try XCTUnwrap(before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let b = try XCTUnwrap(restored.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01)
                XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01)
                XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01)
            }
        }
    }

    @MainActor
    func testProductionPhysicallyBasedShellRevealsEnclosedPart() async throws {
        let preview = nestedBoxes()
        let colors = [0: PartColor(red: 1, green: 0, blue: 0), 1: PartColor(red: 0, green: 0, blue: 1)]
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: colors)
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0, 0, 10)
        camera.look(at: SCNVector3Zero)
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 3
        camera.camera?.automaticallyAdjustsZRange = false
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 100
        for solid in 0...1 {
            let material = try XCTUnwrap(view.scene.rootNode.childNode(withName: "solid:\(solid)", recursively: true)?.geometry?.firstMaterial)
            XCTAssertEqual(material.lightingModel, .physicallyBased,
                "This regression must exercise the production PBR lighting and specular path.")
        }
        func center() async throws -> NSColor {
            let png = try await CADAgentRenderer.capturePNG(view: view)
            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            return try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        let visible = try await center()
        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [1], solidColors: colors)
        let hidden = try await center()
        print("PBR enclosed blue: visible",visible.blueComponent,"hidden",hidden.blueComponent)
        XCTAssertGreaterThan(visible.blueComponent, hidden.blueComponent + 0.15,
            "The enclosed blue part must contribute through the production shaded red shell.")
        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [], solidColors: colors)
        let selectedVisible = try await center()
        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [1], solidColors: colors)
        let selectedHidden = try await center()
        XCTAssertGreaterThan(selectedVisible.blueComponent, selectedHidden.blueComponent + 0.15,
            "Selected gold PBR faces must remain translucent while preserving the enclosed part's custom color.")
    }

    /// The highlighted face fill is depth-tested against the depth-only face
    /// copies. Both must rasterize identical depths, or an obliquely viewed
    /// surface shows blocky and fan-shaped gaps in its fill.
    @MainActor
    func testSelectedFaceFillCoversAnObliqueTranslucentSurface() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let face = CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0)
        let preview = tessellatedPlate(divisions: 24)
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        for projection in ViewportProjectionMode.allCases {
            func capture(_ selected: [CADFeatureID]) async throws -> NSBitmapImageRep {
                view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                            selectedSolids: [], hiddenSolids: [], projection: projection, selectedFeatures: selected)
                let deadline = ContinuousClock.now + .seconds(10)
                while view.isPreparingCaptureResources, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertFalse(view.isPreparingCaptureResources)
                let camera = try XCTUnwrap(view.pointOfView)
                camera.position = SCNVector3(0.7, -4.5, 2.2)
                camera.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
                let png = try await CADAgentRenderer.capturePNG(view: view)
                return try XCTUnwrap(NSBitmapImageRep(data: png))
            }
            let plain = try await capture([])
            let highlighted = try await capture([face])
            var samples = 0, filled = 0
            for v in stride(from: -1.8, through: 1.8, by: 0.06) {
                for u in stride(from: -1.8, through: 1.8, by: 0.06) {
                    let projected = view.projectPoint(SCNVector3(u, v, 0))
                    let x = Int((CGFloat(projected.x) * CGFloat(plain.pixelsWide) / view.bounds.width).rounded(.down))
                    let y = plain.pixelsHigh - 1 - Int((CGFloat(projected.y) * CGFloat(plain.pixelsHigh) / view.bounds.height).rounded(.down))
                    guard x >= 0, y >= 0, x < plain.pixelsWide, y < plain.pixelsHigh,
                          let before = plain.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          let after = highlighted.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    samples += 1
                    if after.redComponent - after.blueComponent > before.redComponent - before.blueComponent + 0.2 { filled += 1 }
                }
            }
            XCTAssertGreaterThan(samples, 2_000)
            XCTAssertEqual(filled, samples,
                "The \(projection) translucent face fill must cover the whole selected surface without depth fighting.")
        }
    }

    @MainActor
    func testRepresentativePreviewUsesProductionTranslucency() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_TRANSLUCENCY_PREVIEW"] else {
            throw XCTSkip("Set LAD_TRANSLUCENCY_PREVIEW to inspect a representative preview with production materials.")
        }
        let preview = try JSONDecoder().decode(PreviewMesh.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for mode in [ViewportDisplayMode.edges, .translucent] {
            let png = try await CADAgentRenderer.renderPNG(preview: preview, display: mode, width: 1_024, height: 768)
            let prefix = ProcessInfo.processInfo.environment["LAD_TRANSLUCENCY_ARTIFACT_PREFIX"] ?? "/tmp/lad-translucency-representative"
            try png.write(to: URL(fileURLWithPath: "\(prefix)-\(mode.rawValue).png"))
        }
    }

    @MainActor
    func testTranslucentFacesRevealGeometryBehindThemAndRestoreOpaqueRendering() async throws {
        try await assertTranslucency(preview: layeredFaces())
    }

    @MainActor
    func testTranslucentClosedShellRevealsEnclosedPart() async throws {
        try await assertTranslucency(preview: nestedBoxes())
    }

    @MainActor
    private func assertTranslucency(preview: PreviewMesh) async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(view.isPreparingResources)
        let cameraNode = try XCTUnwrap(view.pointOfView)
        let camera = try XCTUnwrap(cameraNode.camera)
        cameraNode.position = SCNVector3(0, 0, 10)
        cameraNode.look(at: SCNVector3Zero)
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 3
        camera.automaticallyAdjustsZRange = false
        camera.zNear = 0.1
        camera.zFar = 100
        view.scene.background.contents = NSColor.black

        func prepareColors() throws {
            for solid in 0...1 {
                let material = try XCTUnwrap(view.scene.rootNode.childNode(withName: "solid:\(solid)", recursively: true)?.geometry?.firstMaterial)
                material.lightingModel = .constant
                material.diffuse.contents = solid == 0 ? NSColor.red : NSColor.blue
                material.emission.contents = NSColor.black
            }
        }
        func centerPixel(_ name: String) async throws -> NSColor {
            try prepareColors()
            let png = try await CADAgentRenderer.capturePNG(view: view)
            try png.write(to: URL(fileURLWithPath: "/tmp/lad-translucency-\(name).png"))
            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            return try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }

        let opaque = try await centerPixel("opaque")
        XCTAssertGreaterThan(opaque.redComponent, 0.8)
        XCTAssertLessThan(opaque.blueComponent, 0.05)

        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let translucent = try await centerPixel("translucent")
        print("Translucent center RGBA:", translucent.redComponent, translucent.greenComponent, translucent.blueComponent, translucent.alphaComponent)
        XCTAssertGreaterThan(translucent.blueComponent, 0.15,
            "The blue face behind the red front face must be visible in the actual composited image, not merely have transparent material settings.")
        XCTAssertLessThan(translucent.redComponent, opaque.redComponent - 0.15,
            "The red front face must blend with the scene rather than remain opaque.")

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        let restored = try await centerPixel("restored")
        XCTAssertEqual(restored.redComponent, opaque.redComponent, accuracy: 0.02)
        XCTAssertLessThan(restored.blueComponent, 0.05,
            "Returning to Edges must restore opaque depth-tested faces.")
    }

    private func layeredFaces() -> PreviewMesh {
        PreviewMesh(vertices: [[-2, -2, 1], [2, -2, 1], [2, 2, 1], [-2, 2, 1],
                               [-2, -2, 0], [2, -2, 0], [2, 2, 0], [-2, 2, 0]],
                    triangles: [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]], edges: [],
                    bounds: [-2, -2, 0, 2, 2, 1], volume: 1, area: 32, solids: 2, faces: 2,
                    buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-translucency-test.step",
                    triangleSolids: [0, 0, 1, 1])
    }

    /// One planar face of a single solid, finely triangulated like a CAD plate.
    private func tessellatedPlate(divisions: Int) -> PreviewMesh {
        var vertices = [[Double]](), triangles = [[Int]]()
        for row in 0...divisions {
            for column in 0...divisions {
                vertices.append([-2 + 4 * Double(column) / Double(divisions), -2 + 4 * Double(row) / Double(divisions), 0])
            }
        }
        for row in 0..<divisions {
            for column in 0..<divisions {
                let corner = row * (divisions + 1) + column, above = corner + divisions + 1
                triangles += [[corner, corner + 1, above + 1], [corner, above + 1, above]]
            }
        }
        var preview = PreviewMesh(vertices: vertices, triangles: triangles, edges: [],
            bounds: [-2, -2, 0, 2, 2, 0], volume: 1, area: 16, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-translucency-plate.step",
            triangleSolids: [Int](repeating: 0, count: triangles.count))
        preview.topology = CADTopology(vertices: [], edges: [], faces: [
            CADFace(id: CADFeatureID(kind: .face, solidIndex: 0, localIndex: 0), type: "PLANE", area: 16,
                    center: [0, 0, 0], normal: [0, 0, 1])
        ], parts: [])
        preview.triangleFaces = [Int](repeating: 0, count: triangles.count)
        return preview
    }

    private func nestedBoxes() -> PreviewMesh {
        let triangles = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7],
                         [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5],
                         [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        func vertices(_ s: Double) -> [[Double]] {
            [[-s, -s, -s], [s, -s, -s], [s, s, -s], [-s, s, -s],
             [-s, -s, s], [s, -s, s], [s, s, s], [-s, s, s]]
        }
        return PreviewMesh(vertices: vertices(2) + vertices(1),
            triangles: triangles + triangles.map { $0.map { $0 + 8 } }, edges: [],
            bounds: [-2, -2, -2, 2, 2, 2], volume: 72, area: 120, solids: 2, faces: 12,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-translucency-boxes-test.step",
            triangleSolids: [Int](repeating: 0, count: 12) + [Int](repeating: 1, count: 12))
    }
}
