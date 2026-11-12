import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

/// Transparency must not depend on SceneKit's object/primitive submission order.
/// Keep production PBR materials and compare pixels inside the same overlapping
/// surfaces, away from silhouettes and physically changing intersections.
final class ViewportTranslucencyRotationTests: XCTestCase {
    @MainActor
    func testClosedPartsAreIndependentOfSolidAndTriangleSubmissionOrder() async throws {
        for (fixtureName, preview) in [("nested-boxes", nestedBoxes()), ("concave-ring", annularShellAndPost())] {
        for projection in ViewportProjectionMode.allCases {
            let view = try await makeView(preview: preview, projection: projection)
            try view.configureAgentView(named: "front", camera: .init(yawDegrees: -89, elevationDegrees: 0, target: [0, 0, 0]))
            let solids = try solidNodes(view)
            solids[0].renderingOrder = 10; solids[1].renderingOrder = 20
            let first = try await image(view)
            solids[0].renderingOrder = 20; solids[1].renderingOrder = 10
            let reversed = try await image(view)
            let difference = maximumCenterDifference(first, reversed)
            print("Translucency solid order difference", fixtureName, projection.rawValue, difference)
            try first.data.write(to: URL(fileURLWithPath: "/tmp/lad-translucency-order-\(fixtureName)-\(projection.rawValue)-forward.png"))
            try reversed.data.write(to: URL(fileURLWithPath: "/tmp/lad-translucency-order-\(fixtureName)-\(projection.rawValue)-reverse.png"))
            XCTAssertLessThan(difference, 0.015, "The same overlapping PBR surfaces must composite identically in either solid submission order.")

            for node in solids { try reverseTriangles(node) }
            let reversedTriangles = try await image(view)
            let triangleDifference = maximumCenterDifference(reversed, reversedTriangles)
            print("Translucency triangle order difference", projection.rawValue, triangleDifference)
            XCTAssertLessThan(triangleDifference, 0.015, "Reordering unchanged triangles must not alter transparent surface color or opacity.")

            view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                        selectedSolids: [0], hiddenSolids: [], projection: projection)
            let selectedFirst = try await image(view)
            solids[0].renderingOrder = 10; solids[1].renderingOrder = 20
            let selectedReversed = try await image(view)
            XCTAssertLessThan(maximumCenterDifference(selectedFirst, selectedReversed), 0.015,
                "Whole-part gold selection must remain equally stable when transparent geometry is submitted in the opposite order.")
        }
        }
    }

    @MainActor
    func testSmallOrbitsAcrossNestedPartCentersAreContinuous() async throws {
        for (fixtureName, preview) in [("nested-boxes", nestedBoxes()), ("concave-ring", annularShellAndPost())] {
        for projection in ViewportProjectionMode.allCases {
            let view = try await makeView(preview: preview, projection: projection)
            let solids = try solidNodes(view)
            solids[1].position.x = 0.25
            var previous: Pixels?
            var greatestDifference = 0.0
            for delta in [-1.0, -0.25, 0.25, 1.0] {
                try view.configureAgentView(named: "front", camera: .init(yawDegrees: -90 + delta, elevationDegrees: 0, target: [0, 0, 0]))
                let current = try await image(view)
                if let previous { greatestDifference = max(greatestDifference, maximumCenterDifference(previous, current)) }
                previous = current
            }
            print("Translucency small-orbit difference", fixtureName, projection.rawValue, greatestDifference)
            XCTAssertLessThan(greatestDifference, 0.04, "Minor rotations must not swap the transparency ordering of a closed shell and its enclosed part.")
        }
        }
    }

    @MainActor
    func testRepresentativeAssemblyBallastIsStableAcrossSmallPitchChangesAndDrawOrders() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_TRANSLUCENCY_PREVIEW"] else {
            throw XCTSkip("Set LAD_TRANSLUCENCY_PREVIEW to the current enclosure preview for its ballast regression.")
        }
        let preview = try PreviewMesh.loadResult(at: URL(fileURLWithPath: path))
        guard preview.solids == 63, let part = preview.topology?.parts.first(where: { $0.solidIndex == 2 }), part.bounds.count == 6 else {
            throw XCTSkip("This opt-in regression needs the 63-part enclosure with its native ballast bounds.")
        }
        let point = SCNVector3((part.bounds[0] + part.bounds[3]) / 2, part.bounds[1], (part.bounds[2] + part.bounds[5]) / 2)
        let colors = [0: PartColor(red: 0.7215686274509804, green: 0.4235294117647059, blue: 0.5294117647058824),
                      1: PartColor(red: 0.396078431372549, green: 0.6666666666666666, blue: 0.7607843137254902)]
        for projection in ViewportProjectionMode.allCases {
            let view = try await makeView(preview: preview, projection: projection, colors: colors, hidden: Set(51...58))
            let nodes = try (0..<preview.solids).map {
                try XCTUnwrap(view.scene?.rootNode.childNode(withName: "solid:\($0)", recursively: true))
            }
            var previous: Pixels?
            var largestPitchDifference = 0.0
            for (index, pitch) in [-1.0, -0.25, 0.25, 1.0].enumerated() {
                try view.configureAgentView(named: "front", camera: .init(yawDegrees: -90, elevationDegrees: pitch))
                let projected = view.projectPoint(point)
                let pixel = NSPoint(x: CGFloat(projected.x), y: view.bounds.height - CGFloat(projected.y) - 1)
                for (index, node) in nodes.enumerated() { node.renderingOrder = index }
                let forward = try await image(view, point: pixel, radius: 2)
                for (index, node) in nodes.enumerated() { node.renderingOrder = -index }
                let reverse = try await image(view, point: pixel, radius: 2)
                XCTAssertLessThan(maximumCenterDifference(forward, reverse), 0.015,
                    "The same visible ballast surfaces must not change opacity when the assembly's part submission order changes.")
                if let previous { largestPitchDifference = max(largestPitchDifference, maximumCenterDifference(previous, forward)) }
                previous = forward
                try forward.data.write(to: URL(fileURLWithPath: "/tmp/lad-translucency-assembly-\(projection.rawValue)-pitch-\(index).png"))
            }
            print("Actual enclosure ballast minor-pitch difference", projection.rawValue, largestPitchDifference)
            XCTAssertLessThan(largestPitchDifference, 0.04,
                "A small pitch change through the ballast's depth-sort crossover must not cause an abrupt opacity jump.")
        }
    }

    @MainActor
    func testSceneKitWithoutHighlightTechniqueIsComparedForDiagnosis() async throws {
        let view = try await makeView(preview: nestedBoxes(), projection: .isometric)
        try view.configureAgentView(named: "front", camera: .init(yawDegrees: -89, elevationDegrees: 0, target: [0, 0, 0]))
        let solids = try solidNodes(view)
        view.technique = nil
        solids[0].renderingOrder = 10; solids[1].renderingOrder = 20
        let first = try await image(view)
        solids[0].renderingOrder = 20; solids[1].renderingOrder = 10
        let second = try await image(view)
        print("Native SceneKit source-over order difference without highlight technique", maximumCenterDifference(first, second))
        XCTAssertGreaterThan(first.center.reduce(0, +), 0.1, "The diagnostic must render actual PBR geometry.")
    }

    @MainActor
    private func makeView(preview: PreviewMesh, projection: ViewportProjectionMode,
                          colors: [Int: PartColor]? = nil, hidden: Set<Int> = []) async throws -> CADSceneView {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is required for transparency pixel tests.") }
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: hidden, projection: projection,
                    solidColors: colors ?? [0: PartColor(red: 0.85, green: 0.10, blue: 0.15),
                                            1: PartColor(red: 0.10, green: 0.25, blue: 0.90)])
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isPreparingResources, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.isPreparingResources)
        for node in try solidNodes(view) {
            XCTAssertEqual(node.geometry?.firstMaterial?.lightingModel, .physicallyBased)
        }
        return view
    }

    @MainActor
    private func solidNodes(_ view: CADSceneView) throws -> [SCNNode] {
        try (0...1).map { try XCTUnwrap(view.scene?.rootNode.childNode(withName: "solid:\($0)", recursively: true)) }
    }

    private struct Pixels {
        let data: Data
        let center: [Double]
    }

    @MainActor
    private func image(_ view: CADSceneView, point: NSPoint? = nil, radius: Int = 7) async throws -> Pixels {
        let data = try await CADAgentRenderer.capturePNG(view: view)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var sum = [Double](repeating: 0, count: 3), count = 0.0
        let centerX = point.map { Int($0.x) } ?? bitmap.pixelsWide / 2
        let centerY = point.map { Int($0.y) } ?? bitmap.pixelsHigh / 2
        XCTAssertTrue((radius..<(bitmap.pixelsWide - radius)).contains(centerX))
        XCTAssertTrue((radius..<(bitmap.pixelsHigh - radius)).contains(centerY))
        for y in (centerY - radius)...(centerY + radius) {
            for x in (centerX - radius)...(centerX + radius) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                sum[0] += color.redComponent; sum[1] += color.greenComponent; sum[2] += color.blueComponent
                count += 1
            }
        }
        let mean = sum.map { $0 / count }
        let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        let backgroundRGB = [Double(background.redComponent), Double(background.greenComponent), Double(background.blueComponent)]
        XCTAssertGreaterThan(zip(mean, backgroundRGB).map { abs($0 - $1) }.max() ?? 0, 0.1,
            "Every comparison must contain rendered geometry; an empty resolve must never pass the ordering or continuity tests.")
        return Pixels(data: data, center: mean)
    }

    private func maximumCenterDifference(_ first: Pixels, _ second: Pixels) -> Double {
        zip(first.center, second.center).map { abs($0 - $1) }.max() ?? 0
    }

    @MainActor
    private func reverseTriangles(_ node: SCNNode) throws {
        let original = try XCTUnwrap(node.geometry)
        let elements = original.elements.map { element -> SCNGeometryElement in
            XCTAssertEqual(element.primitiveType, .triangles)
            let stride = element.bytesPerIndex * 3
            var data = Data()
            for primitive in (0..<element.primitiveCount).reversed() {
                data.append(element.data.subdata(in: (primitive * stride)..<((primitive + 1) * stride)))
            }
            return SCNGeometryElement(data: data, primitiveType: .triangles,
                primitiveCount: element.primitiveCount, bytesPerIndex: element.bytesPerIndex)
        }
        let geometry = SCNGeometry(sources: original.sources, elements: elements)
        geometry.materials = original.materials
        geometry.shaderModifiers = original.shaderModifiers
        node.geometry = geometry
    }

    private func nestedBoxes() -> PreviewMesh {
        let faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7],
                     [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5],
                     [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        func vertices(_ s: Double) -> [[Double]] {
            [[-s, -s, -s], [s, -s, -s], [s, s, -s], [-s, s, -s],
             [-s, -s, s], [s, -s, s], [s, s, s], [-s, s, s]]
        }
        return PreviewMesh(vertices: vertices(3) + vertices(1.4),
            triangles: faces + faces.map { $0.map { $0 + 8 } }, edges: [],
            bounds: [-3, -3, -3, 3, 3, 3], volume: 237, area: 260, solids: 2, faces: 12,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/translucency-order-fixture.step",
            triangleSolids: [Int](repeating: 0, count: 12) + [Int](repeating: 1, count: 12))
    }

    /// A hollow curved shell is concave and exposes multiple front/back layers.
    /// Its inner post lies in the cavity, rather than intersecting the shell.
    private func annularShellAndPost() -> PreviewMesh {
        var vertices = [[Double]](), normals = [[Double]](), triangles = [[Int]](), owners = [Int]()
        func triangle(_ points: [[Double]], _ directions: [[Double]], owner: Int) {
            let first = vertices.count
            vertices.append(contentsOf: points); normals.append(contentsOf: directions)
            triangles.append([first, first + 1, first + 2]); owners.append(owner)
        }
        let segments = 64
        let up = [0.0, 0.0, 1.0], down = [0.0, 0.0, -1.0]
        for i in 0..<segments {
            let a = Double(i) * .pi * 2 / Double(segments), b = Double(i + 1) * .pi * 2 / Double(segments)
            let na = [cos(a), sin(a), 0], nb = [cos(b), sin(b), 0]
            func point(_ r: Double, _ angle: Double, _ z: Double) -> [Double] { [r * cos(angle), r * sin(angle), z] }
            let ol = point(3, a, -2), on = point(3, b, -2), ou = point(3, a, 2), onu = point(3, b, 2)
            let il = point(2.25, a, -2), inn = point(2.25, b, -2), iu = point(2.25, a, 2), inu = point(2.25, b, 2)
            triangle([ol, on, onu], [na, nb, nb], owner: 0); triangle([ol, onu, ou], [na, nb, na], owner: 0)
            triangle([inn, il, iu], [nb.map(-), na.map(-), na.map(-)], owner: 0)
            triangle([inn, iu, inu], [nb.map(-), na.map(-), nb.map(-)], owner: 0)
            triangle([ou, onu, inu], [up, up, up], owner: 0); triangle([ou, inu, iu], [up, up, up], owner: 0)
            triangle([il, inn, on], [down, down, down], owner: 0); triangle([il, on, ol], [down, down, down], owner: 0)
            let pl = point(1.2, a, -1.5), pn = point(1.2, b, -1.5), pu = point(1.2, a, 1.5), pnu = point(1.2, b, 1.5)
            triangle([pl, pn, pnu], [na, nb, nb], owner: 1); triangle([pl, pnu, pu], [na, nb, na], owner: 1)
            triangle([[0, 0, 1.5], pu, pnu], [up, up, up], owner: 1)
            triangle([[0, 0, -1.5], pn, pl], [down, down, down], owner: 1)
        }
        return PreviewMesh(vertices: vertices, triangles: triangles, edges: [], bounds: [-3, -3, -2, 3, 3, 2],
            volume: 40, area: 160, solids: 2, faces: 7, buildSeconds: 0, threads: 1,
            stepPath: "/tmp/translucency-annular-shell-fixture.step", triangleSolids: owners, normals: normals)
    }
}
