import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportCurvedEdgeTests: XCTestCase {
    @MainActor
    func testSelectedRoundedBossKeepsItsWidthAcrossTheEntireVisibleArc() throws {
        for orthographic in [false, true] {
            for close in [false, true] {
                let shot = try selectedBoss(orthographic: orthographic, close: close)
                let label = "\(orthographic ? "ortho" : "perspective")-\(close ? "near" : "far")"
                try write(shot.image, to: "/tmp/lad-curved-selected-whole-arc-\(label).png")
                let samples = wholeVisibleArcWidths(in: shot)
                let bins = [0.0, 0.125, 0.25, 0.4, 0.7, 1.01]
                for (lower, upper) in zip(bins, bins.dropFirst()) {
                    let widths = samples.filter { $0.facing >= lower && $0.facing < upper }.map(\.width)
                    print("Whole selected arc \(label), facing \(lower)..<\(upper): n=\(widths.count), widths \(widths.min() ?? -1)...\(widths.max() ?? -1), mean \(widths.isEmpty ? -1 : widths.reduce(0, +) / Double(widths.count))")
                }
                XCTAssertGreaterThan(samples.count, 250, "Visibility comes from triangle-ray intersections, not the highlight or a front-arc cutoff.")
                XCTAssertGreaterThan(samples.filter { $0.facing > 0.01 && $0.facing < 0.4 }.count, 40,
                    "Exercise the shallow-view transitions which formerly narrowed the gold ribbon.")
                XCTAssertGreaterThanOrEqual(samples.map(\.width).min() ?? 0, 6,
                    "Every geometrically visible part of the 8-pixel stroke must retain its width, including silhouettes (\(label)).")
                XCTAssertLessThanOrEqual((samples.map(\.width).max() ?? 0) - (samples.map(\.width).min() ?? 0), 3,
                    "Gold thickness must remain uniform around the complete visible arc (\(label)).")
            }
        }
    }

    @MainActor
    func testSelectedRoundedBossInnerBoundaryStaysSmoothAcrossSegmentPhases() throws {
        for orthographic in [false, true] {
            let shot = try selectedBoss(orthographic: orthographic)
            let withoutSurfaces = try selectedBoss(orthographic: orthographic, surfaceDepth: false)
            let body = try XCTUnwrap(shot.image.colorAt(x: 320, y: 256)?.usingColorSpace(.sRGB))
            let controlBody = try XCTUnwrap(withoutSurfaces.image.colorAt(x: 320, y: 256)?.usingColorSpace(.sRGB))
            XCTAssertEqual(body.redComponent, controlBody.redComponent, accuracy: 0.01,
                "Highlight compositing must preserve the original body color.")
            XCTAssertEqual(body.greenComponent, controlBody.greenComponent, accuracy: 0.01)
            XCTAssertEqual(body.blueComponent, controlBody.blueComponent, accuracy: 0.01)
            let label = orthographic ? "ortho" : "perspective"
            try write(shot.image, to: "/tmp/lad-curved-selected-\(label).png")
            try write(withoutSurfaces.image, to: "/tmp/lad-curved-selected-\(label)-no-surfaces.png")
            let profile = selectedInnerBoundary(in: shot)
            let originalProfile = selectedInnerBoundary(in: withoutSurfaces)
            print("Selected curved inner boundary \(label): samples \(profile.count), per-segment ranges \(profile.map(\.range)), phase means \(profile.first?.offsets.indices.map { phase in profile.map { $0.offsets[phase] }.reduce(0, +) / Double(profile.count) } ?? [])")
            print("Selected curved inner boundary without surfaces \(label): minimum \(originalProfile.flatMap(\.offsets).min() ?? -.infinity), max per-segment range \(originalProfile.map(\.range).max() ?? .infinity)")
            XCTAssertGreaterThan(profile.count, 15, "Probe a substantial visible front arc of the actual rounded boss.")
            XCTAssertGreaterThanOrEqual(profile.flatMap(\.offsets).min() ?? -.infinity, 2,
                "The inner half of the 8-pixel gold stroke must survive depth testing, not just its centerline.")
            XCTAssertLessThanOrEqual(profile.map(\.range).max() ?? .infinity, 2,
                "The inner gold boundary must not retreat periodically at every polyline join (\(label)).")
            XCTAssertLessThan(originalProfile.flatMap(\.offsets).min() ?? .infinity, 2,
                "The same curved-ring control without triangle-plane depth must reproduce the missing inner stroke.")
            let occluded = try selectedBoss(orthographic: orthographic, occluder: true)
            try write(occluded.image, to: "/tmp/lad-curved-selected-\(label)-occluded.png")
            XCTAssertGreaterThan(goldPixels(in: shot.image), 500, "The surface-aware selected ring must actually render.")
            XCTAssertEqual(goldPixels(in: occluded.image), 0,
                "An independent face just in front of the complete ring must hide the surface-aware stroke (\(label)).")
        }
    }

    @MainActor
    func testSelectedSegmentCapsKeepUniformWidthOnAnObliquePlane() throws {
        for orthographic in [false, true] {
            let current = try tiltedLine(orthographic: orthographic, uncorrected: false)
            let uncorrected = try tiltedLine(orthographic: orthographic, uncorrected: true)
            let label = orthographic ? "ortho" : "perspective"
            try write(current.image, to: "/tmp/lad-edge-caps-\(label).png")
            try write(uncorrected.image, to: "/tmp/lad-edge-caps-\(label)-uncorrected.png")
            func widths(_ shot: Shot) -> [Int] {
                (0..<128).map { sample in
                    let x = -1.5 + (Double(sample) + 0.37) * 3 / 128
                    let clip = shot.matrix * SIMD4<Float>(Float(x), 0, Float(x * 0.7), 1)
                    let column = Int(((Double(clip.x / clip.w) * 0.5 + 0.5) * Double(shot.image.pixelsWide)).rounded())
                    return (shot.image.pixelsHigh / 2 - 8...shot.image.pixelsHigh / 2 + 8).filter { row in
                        guard let color = shot.image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return false }
                        return color.redComponent > color.blueComponent + 0.15 && color.greenComponent > color.blueComponent + 0.1
                    }.count
                }
            }
            let actual = widths(current), before = widths(uncorrected)
            print("Selected caps \(label): current \(actual.min()!)...\(actual.max()!), uncorrected \(before.min()!)...\(before.max()!) pixels")
            XCTAssertGreaterThanOrEqual(actual.min()!, 6, "The 4-point selected line should retain its full width at 2× output.")
            XCTAssertLessThanOrEqual(actual.max()! - actual.min()!, 2, "Segment joins must not create periodic missing gold.")
            XCTAssertGreaterThan(actual.min()!, before.min()! + 2, "The control must reproduce the original cap-depth discontinuity.")
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
        var eye = SIMD3<Double>(0, 0, 8)
        var viewDirection = SIMD3<Double>(0, 0, 1)
        var orthographic = false
    }

    private func wholeVisibleArcWidths(in shot: Shot) -> [(facing: Double, width: Double)] {
        let mesh = bossMesh()
        let triangles = mesh.triangles.map { triangle -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) in
            func p(_ index: Int) -> SIMD3<Double> { let v = mesh.vertices[index]; return SIMD3(v[0], v[1], v[2]) }
            let a = p(triangle[0]); return (a, p(triangle[1]) - a, p(triangle[2]) - a)
        }
        func visible(_ point: SIMD3<Double>, direction: SIMD3<Double>) -> Bool {
            let origin = point + direction * 1e-5
            for (a, ab, ac) in triangles {
                let h = simd_cross(direction, ac), determinant = simd_dot(ab, h)
                if abs(determinant) < 1e-12 { continue }
                let s = origin - a, u = simd_dot(s, h) / determinant
                if u < -1e-9 || u > 1 + 1e-9 { continue }
                let q = simd_cross(s, ab), v = simd_dot(direction, q) / determinant
                if v < -1e-9 || u + v > 1 + 1e-9 { continue }
                let distance = simd_dot(ac, q) / determinant
                if distance > 1e-5 && distance < simd_length(shot.eye - point) { return false }
            }
            return true
        }
        func project(_ p: SIMD3<Double>) -> SIMD2<Double> {
            let c = shot.matrix * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
            return SIMD2((Double(c.x / c.w) * 0.5 + 0.5) * Double(shot.image.pixelsWide),
                         (0.5 - Double(c.y / c.w) * 0.5) * Double(shot.image.pixelsHigh))
        }
        var result = [(facing: Double, width: Double)]()
        let points = circle(radius: 2.2, z: 2.8, count: 84)
        for (a, b) in zip(points, points.dropFirst()) {
            let start = SIMD3(a[0], a[1], a[2]), end = SIMD3(b[0], b[1], b[2])
            let tangent = simd_normalize(project(end) - project(start))
            let across = SIMD2(-tangent.y, tangent.x)
            for phase in [0.03, 0.12, 0.25, 0.375, 0.5, 0.625, 0.75, 0.88, 0.97] {
                let world = start + (end - start) * phase
                let direction = shot.orthographic ? shot.viewDirection : simd_normalize(shot.eye - world)
                guard visible(world, direction: direction) else { continue }
                let screen = project(world)
                guard screen.x > 10, screen.y > 10, screen.x < Double(shot.image.pixelsWide - 10), screen.y < Double(shot.image.pixelsHigh - 10) else { continue }
                var gold = [Double]()
                for step in -32...32 {
                    let offset = Double(step) / 4, pixel = screen + across * offset
                    guard let color = shot.image.colorAt(x: Int(pixel.x.rounded()), y: Int(pixel.y.rounded()))?.usingColorSpace(.sRGB) else { continue }
                    if color.redComponent > color.blueComponent + 0.2 && color.greenComponent > color.blueComponent + 0.12 { gold.append(offset) }
                }
                let radial = simd_normalize(SIMD3(world.x, world.y, 0))
                result.append((simd_dot(radial, direction), gold.isEmpty ? 0 : gold.last! - gold.first! + 0.25))
            }
        }
        return result
    }

    private struct InnerBoundary {
        var offsets: [Double]
        var range: Double { (offsets.max() ?? 0) - (offsets.min() ?? 0) }
    }

    /// Measure the innermost gold pixel relative to each *projected chord*, at
    /// nine phases. This sees periodic missing stroke width even if the entire
    /// centerline is visible. Only the exposed front arc is eligible.
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
    private func selectedBoss(orthographic: Bool, surfaceDepth: Bool = true, occluder: Bool = false, close: Bool = true) throws -> Shot {
        let scene = SCNScene(); scene.background.contents = NSColor.white
        let mesh = bossMesh()
        let surfaces = surfaceDepth ? CADStrokeSurface.matching(mesh) : nil
        if let surfaces {
            XCTAssertEqual(surfaces.count, mesh.edges.count)
            XCTAssertTrue(surfaces.allSatisfy { simd_length($0.first) > 0.9 && simd_length($0.second) > 0.9 },
                "The fixture must exercise both real adjacent triangle planes for every ring segment.")
        }
        scene.rootNode.addChildNode(SCNNode(geometry: bossGeometry()))
        let selectedColor = NSColor(srgbRed: 0.92, green: 0.61, blue: 0.24, alpha: 1)
        let inkColor = NSColor(srgbRed: 0.025, green: 0.035, blue: 0.05, alpha: 1)
        // Keep the real ordinary ribbon beneath selection, just as the live
        // viewport does. Its expanded depth must never hide native seeds.
        let ordinaryGeometry = CADStrokeGeometry.make(mesh.edges, color: inkColor,
            width: CADStrokeGeometry.normalWidth, viewportHeight: 256, surfaces: CADStrokeSurface.matching(mesh))
        ordinaryGeometry.materials.forEach { $0.writesToDepthBuffer = false }
        let ordinary = SCNNode(geometry: ordinaryGeometry)
        ordinary.categoryBitMask = 2; ordinary.renderingOrder = 1
        scene.rootNode.addChildNode(ordinary)
        for (width, color, order) in [(CGFloat(5.5), NSColor(srgbRed: 0.025, green: 0.035, blue: 0.05, alpha: 1), 5),
            (CGFloat(4), NSColor(srgbRed: 0.92, green: 0.61, blue: 0.24, alpha: 1), 6)] {
            let geometry = CADStrokeGeometry.make(mesh.edges, color: color, width: width,
                                                 viewportHeight: 256, surfaces: surfaces)
            let node = SCNNode(geometry: geometry); node.renderingOrder = order
            if surfaceDepth { node.categoryBitMask = CADHighlightTechnique.hiddenEdgeCategory }
            scene.rootNode.addChildNode(node)
        }
        if surfaceDepth {
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
        if surfaceDepth {
            renderer.technique = try XCTUnwrap(CADHighlightTechnique.make(viewportHeight: 256,
                selected: selectedColor, hover: selectedColor.blended(withFraction: 0.25, of: .white) ?? selectedColor,
                hoverHalo: selectedColor.blended(withFraction: 0.7, of: .white) ?? selectedColor, ink: inkColor))
        }
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
            matrix: simd_float4x4(try XCTUnwrap(camera.camera).projectionTransform(withViewportSize: size)) * simd_inverse(camera.simdWorldTransform),
            eye: position, viewDirection: direction, orthographic: orthographic)
    }

    @MainActor
    private func tiltedLine(orthographic: Bool, uncorrected: Bool) throws -> Shot {
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
        for (width, color, order) in [(CGFloat(5.5), NSColor.black, 5),
            (CGFloat(4), NSColor(srgbRed: 0.92, green: 0.61, blue: 0.24, alpha: 1), 6)] {
            let geometry = CADStrokeGeometry.make(segments(points), color: color, width: width, viewportHeight: 256)
            if uncorrected { geometry.shaderModifiers = [.geometry: Self.uncorrectedCaps] }
            let node = SCNNode(geometry: geometry); node.renderingOrder = order; scene.rootNode.addChildNode(node)
        }
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0,0,8)
        camera.camera?.fieldOfView = 38; camera.camera?.projectionDirection = .vertical
        camera.camera?.usesOrthographicProjection = orthographic; camera.camera?.orthographicScale = 1.8
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 100; camera.camera?.wantsHDR = false
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: nil)
        renderer.scene = scene; renderer.pointOfView = camera; renderer.autoenablesDefaultLighting = false
        XCTAssertTrue(renderer.prepare(scene, shouldAbortBlock: nil))
        let size = CGSize(width: 640, height: 512)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        return Shot(image: bitmap, matrix: simd_float4x4(try XCTUnwrap(camera.camera).projectionTransform(withViewportSize: size)) * simd_inverse(camera.simdWorldTransform))
    }

    private static let uncorrectedCaps = """
    #pragma arguments
    float cadEdgeWidth;
    float cadEdgeViewportHeight;
    #pragma body
    float4 cadClip = scn_node.modelViewProjectionTransform * _geometry.position;
    float4 cadDirection = scn_node.modelViewProjectionTransform * float4(_geometry.normal, 0.0);
    float2 cadPixels = (cadDirection.xy * cadClip.w - cadClip.xy * cadDirection.w) * scn_frame.viewportSize.xy;
    float cadLengthSquared = dot(cadPixels, cadPixels);
    if (cadLengthSquared > 1e-18 && abs(cadClip.w) > 1e-8) {
        float2 cadAlong = cadPixels * rsqrt(cadLengthSquared);
        float2 cadAcross = float2(-cadAlong.y, cadAlong.x);
        float cadScale = scn_frame.viewportSize.y / max(cadEdgeViewportHeight, 1.0);
        float2 cadOffset = cadAcross * _geometry.texcoords[0].x + cadAlong * _geometry.texcoords[0].y;
        cadClip.xy += cadOffset * cadEdgeWidth * cadScale * scn_frame.inverseResolution * cadClip.w;
        cadClip.z += 2e-6 * cadClip.w;
        _geometry.position = scn_node.inverseModelViewProjectionTransform * cadClip;
    }
    """

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
                                              color: ink, width: CADStrokeGeometry.normalWidth, viewportHeight: 512)
            let node = SCNNode(geometry: edges)
            node.renderingOrder = 1
            scene.rootNode.addChildNode(node)
        }
        if interiorProbe {
            // Keep the complete 4-point stroke footprint inside the body,
            // including at the distant views and near the cylinder silhouette.
            // A 0.01 mm inset lets its expanded pixels protrude over the rim.
            let hidden = CADStrokeGeometry.make(segments(circle(radius: 2.05, z: 2.65, count: 84)),
                                               color: .magenta, width: 4, viewportHeight: 512)
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
