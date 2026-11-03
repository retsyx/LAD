import AppKit
import Metal
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportCavitySurfaceTests: XCTestCase {
    @MainActor
    func testHollowSphereKeepsCavityTrianglesFacingOutwardAndInteriorVisible() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to verify the native hollow-sphere preview and Metal rendering.")
        }
        _ = NSApplication.shared
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let spec = ModelSpec(title: "Hollow sphere with cable opening",
                             summary: "Regression for inverted display triangles on a trimmed spherical cavity.",
                             units: "mm", script: Self.program)
        let preview = try await EngineService().buildPreview(spec, python: EngineService.defaultPython, threads: 2)
        let topology = try XCTUnwrap(preview.topology)
        let triangleFaces = try XCTUnwrap(preview.triangleFaces)
        let normals = try XCTUnwrap(preview.normals)
        let innerFaces = Set(topology.faces.indices.filter {
            topology.faces[$0].type == "SPHERE" && abs((topology.faces[$0].radius ?? -1) - 48) <= 1e-6
        })
        XCTAssertFalse(innerFaces.isEmpty)
        var checked = 0, inverted = [Int]()
        func vector(_ values: [Double]) -> SIMD3<Double> { SIMD3(values[0], values[1], values[2]) }
        for (index, triangle) in preview.triangles.enumerated() where innerFaces.contains(triangleFaces[index]) {
            let a = vector(preview.vertices[triangle[0]])
            let b = vector(preview.vertices[triangle[1]])
            let c = vector(preview.vertices[triangle[2]])
            let plane = simd_cross(b - a, c - a)
            guard simd_length_squared(plane) > 1e-20 else { continue }
            let outward = triangle.reduce(SIMD3<Double>.zero) { $0 + vector(normals[$1]) }
            checked += 1
            if simd_dot(plane, outward) <= 0 { inverted.append(index) }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertTrue(inverted.isEmpty, "Cavity display triangles must agree with their exact outward surface normals: \(inverted.prefix(12))")

        for mode in [ViewportDisplayMode.shaded, .edges] {
            let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), options: [
                SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
            ])
            view.update(mesh: preview, mode: mode, grid: false, command: nil,
                        selectedSolids: [], hiddenSolids: [], projection: .perspective)
            try view.configureAgentView(named: "front", camera: .init(yawDegrees: 90, elevationDegrees: 35, zoom: 1.5))
            view.layout()
            let png = try await CADAgentRenderer.capturePNG(view: view)
            try png.write(to: URL(fileURLWithPath: "/tmp/lad-cavity-surface-\(mode.rawValue).png"))
            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            // These patches lie on the spherical interior, away from the
            // cable opening and aperture rim. Inverted display triangles made
            // them uniform dark wedges in both production rendering modes.
            var darkestPatch = CGFloat(1)
            for (xs, ys) in [(505..<523, 443..<452), (280..<294, 477..<484),
                             (499..<503, 413..<417), (495..<499, 445..<448)] {
                var greens = [CGFloat]()
                for x in xs { for y in ys {
                    let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    greens.append(color.greenComponent)
                } }
                // Thin analytic edge ink may touch a patch in edges mode.
                // A missing surface instead darkens the complete patch.
                greens.sort()
                darkestPatch = min(darkestPatch, greens[greens.count / 2])
            }
            print("Cavity interior minimum patch median green", mode.rawValue, darkestPatch)
            XCTAssertGreaterThan(darkestPatch, 0.60, "Single-sided production PBR faces must not expose inverted-triangle wedges.")
        }
    }


    @MainActor
    func testTwistedEllipticalBoreKeepsEveryFaceOutwardAndRendersBothOpenings() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to verify the twisted native bore and Metal rendering.")
        }
        _ = NSApplication.shared
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let spec = ModelSpec(title: "Hollow sphere with twisted elliptical bore",
                             summary: "Regression for folded display cells on a trimmed four-turn B-spline bore.",
                             units: "mm", script: Self.twistedBoreProgram)
        let preview = try await EngineService().buildPreview(spec, python: EngineService.defaultPython, threads: 2)
        let topology = try XCTUnwrap(preview.topology)
        let triangleFaces = try XCTUnwrap(preview.triangleFaces)
        let normals = try XCTUnwrap(preview.normals)
        XCTAssertTrue(preview.hasValidNormals)
        XCTAssertTrue(topology.faces.contains { $0.type == "BSPLINE" }, "The fixture must retain its actual twisted surface.")
        XCTAssertEqual(Set(triangleFaces), Set(topology.faces.indices), "Every native face must be represented by display triangles.")
        var checked = 0, inverted = [Int](), meshArea = 0.0
        var meshAreaByFace = Array(repeating: 0.0, count: topology.faces.count)
        func vector(_ values: [Double]) -> SIMD3<Double> { SIMD3(values[0], values[1], values[2]) }
        for (index, triangle) in preview.triangles.enumerated() {
            let a = vector(preview.vertices[triangle[0]])
            let b = vector(preview.vertices[triangle[1]])
            let c = vector(preview.vertices[triangle[2]])
            let plane = simd_cross(b - a, c - a)
            let twiceArea = simd_length(plane)
            guard twiceArea > 1e-10 else { continue }
            let outward = triangle.reduce(SIMD3<Double>.zero) { $0 + vector(normals[$1]) }
            checked += 1
            meshArea += twiceArea / 2
            meshAreaByFace[triangleFaces[index]] += twiceArea / 2
            if simd_dot(plane, outward) <= 0 { inverted.append(index) }
        }
        XCTAssertGreaterThan(checked, 1_000)
        XCTAssertTrue(inverted.isEmpty, "All faces, including the twisted B-spline bore, must retain outward display cells: \(inverted.prefix(12))")
        let areaError = abs(meshArea - preview.area) / preview.area
        print("Twisted bore display/native area relative error", areaError)
        XCTAssertLessThan(areaError, 0.02, "Folded or overlapping display cells must not inflate the exact native surface area.")
        let boreFace = try XCTUnwrap(topology.faces.indices.filter { topology.faces[$0].type == "BSPLINE" }.max {
            topology.faces[$0].area < topology.faces[$1].area
        })
        let boreAreaError = abs(meshAreaByFace[boreFace] - topology.faces[boreFace].area) / topology.faces[boreFace].area
        print("Twisted bore face display/native area", meshAreaByFace[boreFace], topology.faces[boreFace].area,
              "relative error", boreAreaError)
        XCTAssertLessThan(boreAreaError, 0.01,
                         "The bore's local display-area error must not be concealed by the much larger spherical faces.")

        for projection in ViewportProjectionMode.allCases {
            for mode in [ViewportDisplayMode.shaded, .edges] {
                for (label, yaw, elevation) in [("aperture",90.0,35.0),("bore",45.0,-65.0)] {
                    let png = try await CADAgentRenderer.renderPNG(preview: preview, view: "front", projection: projection,
                        display: mode, width: 900, height: 900,
                        camera: .init(yawDegrees: yaw, elevationDegrees: elevation, zoom: 1.5))
                    try png.write(to: URL(fileURLWithPath: "/tmp/lad-twisted-bore-\(projection.rawValue)-\(mode.rawValue)-\(label).png"))
                    let image = try XCTUnwrap(NSBitmapImageRep(data: png))
                    var visibleSamples = 0
                    for y in stride(from: 0, to: image.pixelsHigh, by: 12) {
                        for x in stride(from: 0, to: image.pixelsWide, by: 12) {
                            let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            if color.greenComponent > 0.15 || color.redComponent > 0.15 { visibleSamples += 1 }
                        }
                    }
                    XCTAssertGreaterThan(visibleSamples, 500,
                        "The native aperture and bore must render in \(projection.rawValue) \(mode.rawValue), rather than return an empty image.")
                }
            }
        }
    }

    private static let program = """
    import cadquery as cq
    import math

    # Reference-aligned primary forms, in millimetres.
    axis = cq.Vector(0, math.sin(math.radians(55)), math.cos(math.radians(55)))
    sphere_lower = cq.Solid.makeSphere(50, angleDegrees1=-90, angleDegrees2=90)
    sphere_upper = cq.Solid.makeSphere(50, angleDegrees1=-90, angleDegrees2=90).rotate((0,0,0), (1,0,0), -55)
    # Use separate analytic sphere patches aligned with their respective intersections.
    lower_box = cq.Solid.makeBox(120, 120, 15, cq.Vector(-60, -60, -40))
    upper_box = cq.Solid.makeBox(120, 120, 85, cq.Vector(-60, -60, -25))
    lower = sphere_lower.intersect(lower_box)
    upper = sphere_upper.intersect(upper_box)
    foot = cq.Solid.makeCylinder(35, 6, cq.Vector(0,0,-40), cq.Vector(0,0,1))
    body = lower.fuse(foot)
    # Shallow cylindrical seat for the charger's outer edge.
    seat = cq.Solid.makeCylinder(28.18, 40, axis.multiply(36), axis)
    upper = upper.cut(seat)
    body = body.fuse(upper)
    # Open both coplanar patches of the underside and offset inward.
    bottom = [f for f in body.Faces() if f.geomType() == "PLANE" and abs(f.Center().z + 40) < 0.001]
    body = body.hollow(bottom, -2.0)
    # Preserve the unselected portion of the flat base around the selected opening.
    outer = cq.Solid.makeCylinder(34,2,cq.Vector(0,0,-40))
    inner = cq.Solid.makeCylinder(30,4,cq.Vector(0,0,-41))
    body = body.Solids()[0].fuse(outer.cut(inner))
    # Open the central charger aperture through the recessed wall.
    aperture = cq.Solid.makeCylinder(22.5, 12, axis.multiply(28), axis)
    body = body.cut(aperture)
    # Rounded rectangular cable opening through the rear shell.
    slot = cq.Workplane('XY').box(15, 200, 8.5).edges('|Y').fillet(3).val().translate((0, -100, -19.75))
    body = body.cut(slot).clean()
    result = cq.Assembly(name='MagSafe Holder')
    result.add(body, name='Holder', metadata={'lad_id': 'holder'})
    """

    private static let twistedBoreProgram = """
    import cadquery as cq
    import math

    # Reference-aligned primary forms, in millimetres.
    axis = cq.Vector(0, math.sin(math.radians(55)), math.cos(math.radians(55)))
    sphere_lower = cq.Solid.makeSphere(50, angleDegrees1=-90, angleDegrees2=90)
    sphere_upper = cq.Solid.makeSphere(50, angleDegrees1=-90, angleDegrees2=90).rotate((0,0,0), (1,0,0), -55)
    # Use separate analytic sphere patches aligned with their respective intersections.
    lower_box = cq.Solid.makeBox(120, 120, 15, cq.Vector(-60, -60, -40))
    upper_box = cq.Solid.makeBox(120, 120, 85, cq.Vector(-60, -60, -25))
    lower = sphere_lower.intersect(lower_box)
    upper = sphere_upper.intersect(upper_box)
    foot = cq.Solid.makeCylinder(35, 6, cq.Vector(0,0,-40), cq.Vector(0,0,1))
    body = lower.fuse(foot)
    # Shallow cylindrical seat for the charger's outer edge.
    seat = cq.Solid.makeCylinder(28.18, 40, axis.multiply(36), axis)
    upper = upper.cut(seat)
    body = body.fuse(upper)
    # Open both coplanar patches of the underside and offset inward.
    bottom = cq.Workplane(obj=body).faces("<Z").vals()
    body = body.hollow(bottom, -2.0)
    # Preserve the unselected portion of the flat base around the selected opening.
    outer = cq.Solid.makeCylinder(34,2,cq.Vector(0,0,-40))
    inner = cq.Solid.makeCylinder(30,4,cq.Vector(0,0,-41))
    body = body.Solids()[0].fuse(outer.cut(inner))
    # Weight chamber and its ceiling tie the threaded sleeve to the existing shell.
    barrel = cq.Solid.makeCylinder(35, 16, cq.Vector(0, 0, -40))
    web = cq.Solid.makeCylinder(43, 1.2, cq.Vector(0, 0, -25.2))
    body = body.fuse(barrel).fuse(web)
    # A rotating offset elliptical profile follows the observed four-turn bore.
    profile = cq.Workplane("XY", origin=(0, 0, -40)).moveTo(-1.146108, 0).ellipse(30.069444, 29.742879)
    bore = profile.twistExtrude(16, 1440, combine=False).val()
    body = body.cut(bore)
    # Open the central charger aperture through the recessed wall.
    aperture = cq.Solid.makeCylinder(22.5, 12, axis.multiply(28), axis)
    body = body.cut(aperture)
    # Rounded rectangular cable opening through the rear shell.
    slot = cq.Workplane('XY').box(15, 200, 8.5).edges('|Y').fillet(3).val().translate((0, -100, -19.75))
    body = body.cut(slot).clean()
    result = cq.Assembly(name='MagSafe Holder')
    result.add(body, name='Holder', metadata={'lad_id': 'holder'})
    """
}
