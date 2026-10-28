import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportColorTests: XCTestCase {
    private let coral = PartColor(red: 0.82, green: 0.39, blue: 0.32)
    private let teal = PartColor(red: 0.25, green: 0.61, blue: 0.56)

    @MainActor
    func testPartColorsRemainIndependentAcrossSelectionDisplayModesAndReset() async throws {
        let view = try makeView()
        let preview = mesh()
        let colors = [0: coral, 1: teal]
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: colors)
        try await waitForPreparation(view)
        let first = try node("solid:0", in: view)
        let second = try node("solid:1", in: view)
        let geometry = try XCTUnwrap(first.geometry)
        let material = try XCTUnwrap(geometry.firstMaterial)
        XCTAssertFalse(material === second.geometry?.firstMaterial)
        try assertColor(material, equals: coral)
        try assertColor(try XCTUnwrap(second.geometry?.firstMaterial), equals: teal)

        view.update(mesh: preview, mode: .translucent, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [1], solidColors: colors)
        try assertColor(material, equals: PartColor(red: 0.92, green: 0.61, blue: 0.24))
        XCTAssertEqual(material.transparency, 1, accuracy: 1e-6)
        XCTAssertNotNil(material.shaderModifiers?[.fragment])
        XCTAssertTrue(second.isHidden)
        try assertColor(try XCTUnwrap(second.geometry?.firstMaterial), equals: teal)

        view.update(mesh: preview, mode: .shaded, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: colors)
        try assertColor(material, equals: coral)
        XCTAssertEqual(material.transparency, 1)
        XCTAssertTrue(material.shaderModifiers?[.fragment]?.contains("#pragma opaque") == true)
        XCTAssertFalse(second.isHidden)

        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: colors)
        try assertColor(try XCTUnwrap(node("edges:0", in: view).geometry?.firstMaterial), equals: coral)
        try assertColor(try XCTUnwrap(node("edges:1", in: view).geometry?.firstMaterial), equals: teal)

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        try assertColor(material, equals: PartColor(red: 0.70, green: 0.75, blue: 0.80))
        try assertColor(try XCTUnwrap(second.geometry?.firstMaterial), equals: PartColor(red: 0.70, green: 0.75, blue: 0.80))
        XCTAssertTrue(try node("solid:0", in: view) === first)
        XCTAssertTrue(first.geometry === geometry)
        XCTAssertTrue(first.geometry?.firstMaterial === material)
    }

    @MainActor
    func testColorOnlyUpdatesReusePreparedGeometryAndUnchangedColorsDoNotRedraw() async throws {
        let view = try makeView()
        let preview = mesh()
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        try await waitForPreparation(view)
        let first = try node("solid:0", in: view)
        let geometry = try XCTUnwrap(first.geometry)
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: [0: coral])
        XCTAssertFalse(view.isPreparingResources)
        XCTAssertTrue(first.geometry === geometry)
        try assertColor(try XCTUnwrap(geometry.firstMaterial), equals: coral)

        view.needsDisplay = false
        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: [0: coral])
        XCTAssertFalse(view.needsDisplay)
        XCTAssertFalse(view.isPreparingResources)

        view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: [0: PartColor(red: .nan, green: 0, blue: 0)])
        try assertColor(try XCTUnwrap(geometry.firstMaterial), equals: PartColor(red: 0.70, green: 0.75, blue: 0.80))
    }

    @MainActor
    func testLatestColorsDuringPreparationReachLegacyPerSolidWireframe() async throws {
        let view = try makeView()
        let preview = mesh(ownedEdges: false)
        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: [0: coral])
        XCTAssertTrue(view.isPreparingResources)
        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [], solidColors: [0: teal])
        try await waitForPreparation(view)
        let first = try node("solid:0", in: view)
        XCTAssertFalse(first.isHidden)
        XCTAssertFalse(try node("solid:1", in: view).isHidden)
        XCTAssertTrue(try node("legacy-edges", in: view).isHidden)
        XCTAssertEqual(first.geometry?.firstMaterial?.fillMode, .lines)
        try assertColor(try XCTUnwrap(first.geometry?.firstMaterial), equals: teal)

        view.update(mesh: preview, mode: .wireframe, grid: false, command: nil,
                    selectedSolids: [], hiddenSolids: [])
        XCTAssertFalse(try node("legacy-edges", in: view).isHidden)
        XCTAssertTrue(first.isHidden)
        XCTAssertTrue(try node("solid:1", in: view).isHidden)
    }

    @MainActor
    private func makeView() throws -> CADSceneView {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CADSceneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
    }

    @MainActor
    private func waitForPreparation(_ view: CADSceneView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while view.isPreparingResources, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(view.isPreparingResources)
    }

    @MainActor
    private func node(_ name: String, in view: CADSceneView) throws -> SCNNode {
        try XCTUnwrap(view.scene?.rootNode.childNode(withName: name, recursively: true))
    }

    private func assertColor(_ material: SCNMaterial, equals expected: PartColor,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try XCTUnwrap((material.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertEqual(color.redComponent, CGFloat(expected.red), accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(color.greenComponent, CGFloat(expected.green), accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(color.blueComponent, CGFloat(expected.blue), accuracy: 1e-6, file: file, line: line)
    }

    private func mesh(ownedEdges: Bool = true) -> PreviewMesh {
        PreviewMesh(vertices: [[-3, -1, 0], [-1, -1, 0], [-1, 1, 0], [-3, 1, 0],
                               [1, -1, 0], [3, -1, 0], [3, 1, 0], [1, 1, 0]],
                    triangles: [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]],
                    edges: [[-3, -1, 0, -1, -1, 0], [-1, -1, 0, -1, 1, 0],
                            [1, -1, 0, 3, -1, 0], [3, -1, 0, 3, 1, 0]],
                    bounds: [-3, -1, 0, 3, 1, 0], volume: 1, area: 8, solids: 2, faces: 2,
                    buildSeconds: 0, threads: 1, stepPath: "/tmp/viewport-colors-test.step",
                    triangleSolids: [0, 0, 1, 1], edgeSolids: ownedEdges ? [0, 0, 1, 1] : nil)
    }
}
