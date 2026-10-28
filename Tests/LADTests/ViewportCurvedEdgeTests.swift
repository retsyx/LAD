import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportCurvedEdgeTests: XCTestCase {
    @MainActor
    func testSelectedRoundedBossKeepsItsWidthAcrossTheEntireProjectedCurve() throws {
        for orthographic in [false, true] {
            for close in [false, true] {
                let shot = try selectedBoss(orthographic: orthographic, close: close)
                let widths = selectedCurveWidths(in: shot)
                let label = "\(orthographic ? "ortho" : "perspective")-\(close ? "near" : "far")"
                XCTAssertGreaterThan(widths.count, 700,
                    "Probe the complete projected curve, including the arc behind its own solid.")
                XCTAssertGreaterThanOrEqual(widths.min() ?? 0, 6,
                    "The complete selected curve must retain its screen-point width (\(label)).")
                XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 3,
                    "Gold thickness must remain uniform around the entire projected curve (\(label)).")
            }
        }
    }

    @MainActor
    func testSelectedRoundedBossInnerBoundaryStaysSmoothAndVisibleThroughNearerGeometry() throws {
        for orthographic in [false, true] {
            let shot = try selectedBoss(orthographic: orthographic)
            let baseline = try selectedBoss(orthographic: orthographic, highlighted: false)
            let body = try XCTUnwrap(shot.image.colorAt(x: 320, y: 256)?.usingColorSpace(.sRGB))
            let baselineBody = try XCTUnwrap(baseline.image.colorAt(x: 320, y: 256)?.usingColorSpace(.sRGB))
            XCTAssertEqual(body.redComponent, baselineBody.redComponent, accuracy: 0.01,
                "The overlay must preserve unhighlighted body color.")
            XCTAssertEqual(body.greenComponent, baselineBody.greenComponent, accuracy: 0.01)
            XCTAssertEqual(body.blueComponent, baselineBody.blueComponent, accuracy: 0.01)
            let profile = selectedInnerBoundary(in: shot)
            XCTAssertGreaterThan(profile.count, 15)
            XCTAssertGreaterThanOrEqual(profile.flatMap(\.offsets).min() ?? -.infinity, 2,
                "The full inner half of the selected stroke must remain visible.")
            XCTAssertLessThanOrEqual(profile.map(\.range).max() ?? .infinity, 2,
                "The inner gold boundary must not retreat at polyline joins.")
            let occluded = try selectedBoss(orthographic: orthographic, occluder: true)
            XCTAssertGreaterThan(goldPixels(in: shot.image), 500)
            XCTAssertGreaterThanOrEqual(goldPixels(in: occluded.image), goldPixels(in: shot.image) - 10,
                "The complete selected curve must remain visible through an independent nearer face.")
        }
    }

    @MainActor
    func testSelectedSegmentJoinsKeepUniformWidthOnAnObliquePlane() throws {
        for orthographic in [false, true] {
            let shot = try tiltedLine(orthographic: orthographic)
            let widths = (0..<128).map { sample in
                let x = -1.5 + (Double(sample) + 0.37) * 3 / 128
                let clip = shot.matrix * SIMD4<Float>(Float(x), 0, Float(x * 0.7), 1)
                let column = Int(((Double(clip.x / clip.w) * 0.5 + 0.5) * Double(shot.image.pixelsWide)).rounded())
                return (shot.image.pixelsHigh / 2 - 8...shot.image.pixelsHigh / 2 + 8).filter { row in
                    guard let color = shot.image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return false }
                    return color.redComponent > color.blueComponent + 0.15 && color.greenComponent > color.blueComponent + 0.1
                }.count
            }
            XCTAssertGreaterThanOrEqual(widths.min() ?? 0, 6,
                "The selected line should retain its complete width at 2× output.")
            XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 2,
                "Native centerline joins must not create periodic missing gold.")
        }
    }

    @MainActor
    func testCoherentRoundedBossBoundariesRemainContinuousAndDoNotRevealInteriorEdges() throws {
        for orthographic in [false, true] {
            for close in [false, true] {
                let shot = try render(orthographic: orthographic, close: close, edgeSamples: 84, interiorProbe: false)
                let label = "\(orthographic ? "ortho" : "perspective")-\(close ? "close" : "far")"
                try write(shot.image, to: "/tmp/lad-curved-edge-\(label).png")
                let top = coverage(circle(radius: 2, z: 3, count: 84), in: shot)
                let seam = coverage(circle(radius: 2.2, z: 2.8, count: 84), in: shot, frontOnly: true)
                XCTAssertGreaterThan(top.samples, 200)
                XCTAssertGreaterThan(seam.samples, 50)
                XCTAssertGreaterThanOrEqual(top.fraction, 0.98,
                    "The oblique top rim must be continuous (\(label): \(top.covered)/\(top.samples)).")
                XCTAssertGreaterThanOrEqual(seam.fraction, 0.98,
                    "A circular edge shared with the rounded-face mesh must not self-occlude (\(label): \(seam.covered)/\(seam.samples)).")
                let occlusion = try render(orthographic: orthographic, close: close, edgeSamples: 84, interiorProbe: true)
                try write(occlusion.image, to: "/tmp/lad-curved-edge-occlusion-\(label).png")
                XCTAssertEqual(magentaPixels(in: occlusion.image), 0,
                    "A nearby ring inside the boss must remain hidden; edge visibility cannot come from disabling depth tests (\(label)).")
                if orthographic && close {
                    let exposed = try render(orthographic: orthographic, close: close, edgeSamples: 84, interiorProbe: true, bodyVisible: false)
                    XCTAssertGreaterThan(magentaPixels(in: exposed.image), 100,
                        "The interior probe must actually render when its occluding body is removed.")
                }
            }
        }
    }

    @MainActor
    func testIndependentCoarseCircleSamplingProducesAReviewArtifact() throws {
        // The original worker sampled this size circle at about 24 points,
        // independently of an 84-point face boundary. This control deliberately
        // puts those chords inside the rounded mesh to detect the old mismatch.
        let shot = try render(orthographic: false, close: true, edgeSamples: 24, interiorProbe: false)
        try write(shot.image, to: "/tmp/lad-curved-edge-independent-coarse.png")
        let aligned = try render(orthographic: false, close: true, edgeSamples: 84, interiorProbe: false)
        let probe = circle(radius: 2.2, z: 2.8, count: 84)
        let coarse = coverage(probe, in: shot, frontOnly: true)
        let coherent = coverage(probe, in: aligned, frontOnly: true)
        XCTAssertLessThan(coarse.fraction, 0.9,
            "The original 24-point independent chord approximation should reproduce broken arcs (\(coarse.covered)/\(coarse.samples)).")
        XCTAssertGreaterThan(coherent.fraction - coarse.fraction, 0.1,
            "Boundary-aligned edges must materially restore the missing arc coverage (coarse \(coarse.fraction), aligned \(coherent.fraction)).")
    }

    private struct Shot {
        var image: NSBitmapImageRep
        var matrix: simd_float4x4
        var front = SIMD2<Double>(6, -8) / 10
    }

    private func selectedCurveWidths(in shot: Shot) -> [Double] {
        func project(_ point: SIMD3<Double>) -> SIMD2<Double> {
            let clip = shot.matrix * SIMD4<Float>(Float(point.x), Float(point.y), Float(point.z), 1)
            return SIMD2((Double(clip.x / clip.w) * 0.5 + 0.5) * Double(shot.image.pixelsWide),
                         (0.5 - Double(clip.y / clip.w) * 0.5) * Double(shot.image.pixelsHigh))
        }
        var widths = [Double]()
        let points = circle(radius: 2.2, z: 2.8, count: 84)
        for (a, b) in zip(points, points.dropFirst()) {
            let start = SIMD3(a[0], a[1], a[2]), end = SIMD3(b[0], b[1], b[2])
            let tangent = simd_normalize(project(end) - project(start))
            let across = SIMD2(-tangent.y, tangent.x)
            for phase in [0.03, 0.12, 0.25, 0.375, 0.5, 0.625, 0.75, 0.88, 0.97] {
                let screen = project(start + (end - start) * phase)
                guard screen.x > 10, screen.y > 10,
                      screen.x < Double(shot.image.pixelsWide - 10), screen.y < Double(shot.image.pixelsHigh - 10) else { continue }
                var gold = [Double]()
                for step in -32...32 {
                    let offset = Double(step) / 4, pixel = screen + across * offset
                    guard let color = shot.image.colorAt(x: Int(pixel.x.rounded()), y: Int(pixel.y.rounded()))?.usingColorSpace(.sRGB) else { continue }
                    if color.redComponent > color.blueComponent + 0.2 && color.greenComponent > color.blueComponent + 0.12 { gold.append(offset) }
                }
                widths.append(gold.isEmpty ? 0 : gold.last! - gold.first! + 0.25)
            }
        }
        return widths
    }

    private struct InnerBoundary {
        var offsets: [Double]
        var range: Double { (offsets.max() ?? 0) - (offsets.min() ?? 0) }
    }

    /// Measure the innermost gold pixel relative to each *projected chord*, at
    /// nine phases. This sees periodic missing stroke width even if the entire
    /// centerline is visible. Probe the inward boundary on the front arc.
    private func selectedInnerBoundary(in shot: Shot) -> [InnerBoundary] {
        func project(_ p: [Double]) -> SIMD2<Double> {
            let c = shot.matrix * SIMD4<Float>(Float(p[0]), Float(p[1]), Float(p[2]), 1)
            return SIMD2((Double(c.x / c.w) * 0.5 + 0.5) * Double(shot.image.pixelsWide),
                         (0.5 - Double(c.y / c.w) * 0.5) * Double(shot.image.pixelsHigh))
        }
        let center = project([0, 0, 2.8])
        let points = circle(radius: 2.2, z: 2.8, count: 84)
        var profiles = [InnerBoundary]()
        for (a, b) in zip(points, points.dropFirst()) {
            let radial = SIMD2((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            guard simd_dot(simd_normalize(radial), shot.front) > 0.65 else { continue }
            let start = project(a), end = project(b)
            let tangent = simd_normalize(end - start)
            var inward = SIMD2(-tangent.y, tangent.x)
            if simd_dot(inward, center - (start + end) / 2) < 0 { inward = -inward }
            var offsets = [Double]()
            for phase in [0.03, 0.12, 0.25, 0.375, 0.5, 0.625, 0.75, 0.88, 0.97] {
                let point = start + (end - start) * phase
                var innermost = -10.0
                for step in -24...32 {
                    let offset = Double(step) / 4
                    let pixel = point + inward * offset
                    let x = Int(pixel.x.rounded()), y = Int(pixel.y.rounded())
                    guard x >= 0, y >= 0, x < shot.image.pixelsWide, y < shot.image.pixelsHigh,
                          let color = shot.image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.redComponent > color.blueComponent + 0.2 && color.greenComponent > color.blueComponent + 0.12 {
                        innermost = offset
                    }
                }
                offsets.append(innermost)
            }
            profiles.append(InnerBoundary(offsets: offsets))
        }
        return profiles
    }

    @MainActor
    private func selectedBoss(orthographic: Bool, highlighted: Bool = true, occluder: Bool = false, close: Bool = true) throws -> Shot {
        let scene = SCNScene(); scene.background.contents = NSColor.white
        let mesh = bossMesh()
        scene.rootNode.addChildNode(SCNNode(geometry: bossGeometry()))
        let selectedColor = NSColor(srgbRed: 0.92, green: 0.61, blue: 0.24, alpha: 1)
        let inkColor = NSColor(srgbRed: 0.025, green: 0.035, blue: 0.05, alpha: 1)
        // Keep ordinary CAD ink beneath the unoccluded overlay, as in the
        // production viewport.
        let ordinaryGeometry = CADStrokeGeometry.make(mesh.edges, color: inkColor,
            viewportHeight: 256, surfaces: CADStrokeSurface.matching(mesh))
        ordinaryGeometry.materials.forEach { $0.writesToDepthBuffer = false }
        let ordinary = SCNNode(geometry: ordinaryGeometry)
        ordinary.categoryBitMask = 2; ordinary.renderingOrder = 1
        scene.rootNode.addChildNode(ordinary)
        if highlighted {
            let seed = SCNNode(geometry: CADStrokeSeedGeometry.make(mesh.edges))
            seed.categoryBitMask = CADHighlightTechnique.seedCategory
            scene.rootNode.addChildNode(seed)
        }
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38; camera.camera?.projectionDirection = .vertical
        camera.camera?.usesOrthographicProjection = orthographic; camera.camera?.orthographicScale = close ? 2.8 : 4.6
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 100; camera.camera?.wantsHDR = false
        let target = SIMD3<Double>(0, 0, 2.8)
        let direction = simd_normalize(SIMD3<Double>(6, -8, 7))
        let position = target + direction * (close ? 8 : 12)
        if occluder {
            // The ring's nearest point has camera-axis depth 2.2*10/sqrt(149)
            // = 1.8023 mm. This independent plane is only 0.0477 mm nearer;
            // its broad footprint covers the full stroke including its halo.
            let center = target + direction * 1.85
            let right = simd_normalize(simd_cross(direction, SIMD3<Double>(0, 0, 1)))
            let up = simd_normalize(simd_cross(right, direction))
            let corners = [center - right * 5 - up * 5, center + right * 5 - up * 5,
                           center + right * 5 + up * 5, center - right * 5 + up * 5]
            let plane = SCNGeometry(sources: [SCNGeometrySource(vertices: corners.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: Array(repeating: SCNVector3(direction.x, direction.y, direction.z), count: 4))],
                elements: [SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)])
            let material = SCNMaterial(); material.lightingModel = .constant
            material.diffuse.contents = NSColor(srgbRed: 0.35, green: 0.65, blue: 0.85, alpha: 1)
            material.isDoubleSided = true; plane.materials = [material]
            scene.rootNode.addChildNode(SCNNode(geometry: plane))
        }
        camera.position = SCNVector3(position.x, position.y, position.z)
        camera.look(at: SCNVector3(target.x, target.y, target.z), up: SCNVector3(0,0,1), localFront: SCNVector3(0,0,-1))
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: nil)
        renderer.scene = scene; renderer.pointOfView = camera; renderer.autoenablesDefaultLighting = false
        renderer.usesReverseZ = true
        renderer.technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: 256,
            selected: selectedColor, hover: selectedColor.blended(withFraction: 0.25, of: .white) ?? selectedColor,
            hoverHalo: selectedColor.blended(withFraction: 0.7, of: .white) ?? selectedColor, ink: inkColor))
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let size = CGSize(width: 640, height: 512)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        if !occluder {
            let background = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
            XCTAssertEqual(background.redComponent, 1, accuracy: 0.03)
            XCTAssertEqual(background.greenComponent, 1, accuracy: 0.03)
            XCTAssertEqual(background.blueComponent, 1, accuracy: 0.03)
        }
        return Shot(image: bitmap,
            matrix: simd_float4x4(try XCTUnwrap(camera.camera).projectionTransform(withViewportSize: size)) * simd_inverse(camera.simdWorldTransform))
    }

    @MainActor
    private func tiltedLine(orthographic: Bool) throws -> Shot {
        let scene = SCNScene()
        scene.background.contents = NSColor.white
        let face = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(-2,-1,-1.4), SCNVector3(2,-1,1.4),
            SCNVector3(2,1,1.4), SCNVector3(-2,1,-1.4)]), SCNGeometrySource(normals: Array(repeating: SCNVector3(-0.7,0,1), count: 4))],
            elements: [SCNGeometryElement(indices: [Int32(0),1,2,0,2,3], primitiveType: .triangles)])
        let fill = SCNMaterial(); fill.lightingModel = .constant
        fill.diffuse.contents = NSColor(srgbRed: 0.35, green: 0.65, blue: 0.85, alpha: 1)
        fill.isDoubleSided = true; face.materials = [fill]
        scene.rootNode.addChildNode(SCNNode(geometry: face))
        let points = (0...16).map { index -> [Double] in let x = -1.5 + Double(index) * 3 / 16; return [x, 0, x * 0.7] }
        let seed = SCNNode(geometry: CADStrokeSeedGeometry.make(segments(points)))
        seed.categoryBitMask = CADHighlightTechnique.seedCategory
        scene.rootNode.addChildNode(seed)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0,0,8)
        camera.camera?.fieldOfView = 38; camera.camera?.projectionDirection = .vertical
        camera.camera?.usesOrthographicProjection = orthographic; camera.camera?.orthographicScale = 1.8
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 100; camera.camera?.wantsHDR = false
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: nil)
        renderer.scene = scene; renderer.pointOfView = camera; renderer.autoenablesDefaultLighting = false
        renderer.technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: 256,
            selected: NSColor(srgbRed: 0.92, green: 0.61, blue: 0.24, alpha: 1),
            hover: .white, hoverHalo: .white, ink: .black))
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let size = CGSize(width: 640, height: 512)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        return Shot(image: bitmap, matrix: simd_float4x4(try XCTUnwrap(camera.camera).projectionTransform(withViewportSize: size)) * simd_inverse(camera.simdWorldTransform))
    }

    @MainActor
    private func render(orthographic: Bool, close: Bool, edgeSamples: Int, interiorProbe: Bool,
                        bodyVisible: Bool = true) throws -> Shot {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = SCNScene()
        scene.background.contents = NSColor.white
        let body = SCNNode(geometry: bossGeometry())
        body.isHidden = !bodyVisible
        scene.rootNode.addChildNode(body)
        let ink = NSColor(srgbRed: 0.025, green: 0.035, blue: 0.05, alpha: 1)
        for (radius, z) in [(4.0, 1.0), (2.2, 2.8), (2.0, 3.0)] {
            let edges = CADStrokeGeometry.make(segments(circle(radius: radius, z: z, count: edgeSamples)),
                                              color: ink, viewportHeight: 512)
            let node = SCNNode(geometry: edges)
            node.renderingOrder = 1
            scene.rootNode.addChildNode(node)
        }
        if interiorProbe {
            // Keep the ordinary edge footprint inside the body,
            // including at the distant views and near the cylinder silhouette.
            // A 0.01 mm inset lets its expanded pixels protrude over the rim.
            let hidden = CADStrokeGeometry.make(segments(circle(radius: 2.05, z: 2.65, count: 84)),
                                               color: .magenta, viewportHeight: 512)
            let hiddenNode = SCNNode(geometry: hidden)
            hiddenNode.renderingOrder = 2
            scene.rootNode.addChildNode(hiddenNode)
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        camera.camera?.projectionDirection = .vertical
        camera.camera?.usesOrthographicProjection = orthographic
        camera.camera?.orthographicScale = close ? 3.6 : 6.4
        camera.camera?.automaticallyAdjustsZRange = true
        camera.camera?.wantsHDR = false
        let target = SIMD3<Double>(0, 0, 1.4)
        let position = target + simd_normalize(SIMD3<Double>(6, -8, 7)) * (close ? 12 : 22)
        camera.position = SCNVector3(position.x, position.y, position.z)
        camera.look(at: SCNVector3(target.x, target.y, target.z), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let size = CGSize(width: 640, height: 512)
        let snapshot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let image = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(snapshot.tiffRepresentation)))
        let projection = simd_float4x4(try XCTUnwrap(camera.camera).projectionTransform(withViewportSize: size))
        return Shot(image: image, matrix: projection * simd_inverse(camera.simdWorldTransform))
    }

    private func bossMesh() -> PreviewMesh {
        let count = 84
        var profile: [(Double, Double)] = [(4, 0), (4, 1), (2.2, 1), (2.2, 2.8)]
        for step in 1...16 {
            let angle = Double(step) * .pi / 32
            profile.append((2 + 0.2 * cos(angle), 2.8 + 0.2 * sin(angle)))
        }
        var vertices = profile.flatMap { radius, z in Array(circle(radius: radius, z: z, count: count).dropLast()) }
        var indices = [Int32]()
        for ring in 0..<(profile.count - 1) {
            for index in 0..<count {
                let next = (index + 1) % count
                let a = Int32(ring * count + index), b = Int32(ring * count + next)
                let c = Int32((ring + 1) * count + index), d = Int32((ring + 1) * count + next)
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        let bottom = Int32(vertices.count), top = bottom + 1
        vertices.append(contentsOf: [[0, 0, 0], [0, 0, 3]])
        for index in 0..<count {
            let next = (index + 1) % count
            indices.append(contentsOf: [bottom, Int32(next), Int32(index)])
            indices.append(contentsOf: [top, Int32((profile.count - 1) * count + index), Int32((profile.count - 1) * count + next)])
        }
        return PreviewMesh(vertices: vertices,
            triangles: stride(from: 0, to: indices.count, by: 3).map { [Int(indices[$0]), Int(indices[$0 + 1]), Int(indices[$0 + 2])] },
            edges: segments(circle(radius: 2.2, z: 2.8, count: count)),
            bounds: [-4, -4, 0, 4, 4, 3], volume: 0, area: 0, solids: 1, faces: profile.count + 1,
            buildSeconds: 0, threads: 1, stepPath: "")
    }

    private func bossGeometry() -> SCNGeometry {
        let mesh = bossMesh()
        let vertices = mesh.vertices.map { SCNVector3($0[0], $0[1], $0[2]) }
        let indices = mesh.triangles.flatMap { $0.map(Int32.init) }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: Array(repeating: SCNVector3(0, 0, 1), count: vertices.count))],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(srgbRed: 0.35, green: 0.65, blue: 0.85, alpha: 1)
        material.isDoubleSided = false
        geometry.materials = [material]
        return geometry
    }

    private func circle(radius: Double, z: Double, count: Int) -> [[Double]] {
        (0...count).map { index in
            let angle = Double(index) * 2 * .pi / Double(count)
            return [radius * cos(angle), radius * sin(angle), z]
        }
    }

    private func segments(_ points: [[Double]]) -> [[Double]] {
        zip(points, points.dropFirst()).map { $0.0 + $0.1 }
    }

    private func coverage(_ points: [[Double]], in shot: Shot, frontOnly: Bool = false) -> (covered: Int, samples: Int, fraction: Double) {
        var covered = 0, samples = 0
        for pair in zip(points, points.dropFirst()) {
            for fraction in [0.25, 0.5, 0.75] {
                let world = SIMD3(pair.0[0], pair.0[1], pair.0[2]) +
                    (SIMD3(pair.1[0], pair.1[1], pair.1[2]) - SIMD3(pair.0[0], pair.0[1], pair.0[2])) * fraction
                if frontOnly, simd_dot(SIMD2(world.x, world.y), shot.front) < 0.35 * simd_length(SIMD2(world.x, world.y)) { continue }
                let clip = shot.matrix * SIMD4<Float>(Float(world.x), Float(world.y), Float(world.z), 1)
                guard clip.w > 0 else { continue }
                let x = Int(((Double(clip.x / clip.w) * 0.5 + 0.5) * Double(shot.image.pixelsWide)).rounded())
                let y = shot.image.pixelsHigh - 1 - Int(((Double(clip.y / clip.w) * 0.5 + 0.5) * Double(shot.image.pixelsHigh)).rounded())
                guard x >= 1, y >= 1, x < shot.image.pixelsWide - 1, y < shot.image.pixelsHigh - 1 else { continue }
                samples += 1
                var found = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        guard let color = shot.image.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.sRGB) else { continue }
                        // Include antialiased partial ink, but exclude both the
                        // blue body and white backdrop from edge coverage.
                        found = found || (color.redComponent < 0.60 && color.greenComponent < 0.77 && color.blueComponent < 0.82)
                    }
                }
                if found { covered += 1 }
            }
        }
        return (covered, samples, samples == 0 ? 0 : Double(covered) / Double(samples))
    }

    private func magentaPixels(in image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.7 && color.blueComponent > 0.7 && color.greenComponent < 0.3 { count += 1 }
            }
        }
        return count
    }

    private func goldPixels(in image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > color.blueComponent + 0.2 && color.greenComponent > color.blueComponent + 0.12 { count += 1 }
            }
        }
        return count
    }

    private func write(_ image: NSBitmapImageRep, to path: String) throws {
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
