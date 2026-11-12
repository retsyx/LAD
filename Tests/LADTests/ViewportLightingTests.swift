import AppKit
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportLightingTests: XCTestCase {
    @MainActor
    func testAmbientIlluminationIsPreservedWhileDirectionalLightsFollowTheCamera() throws {
        let view = makeView()
        let root = try XCTUnwrap(view.scene.rootNode)
        let camera = try XCTUnwrap(view.pointOfView)
        let ambientNodes = lights(in: root, type: .ambient)
        XCTAssertEqual(ambientNodes.count, 1)
        let ambient = try XCTUnwrap(ambientNodes.first)
        XCTAssertTrue(ambient.parent === root)
        XCTAssertEqual(try XCTUnwrap(ambient.light).intensity, 480)
        let color = try XCTUnwrap((ambient.light?.color as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0.63, accuracy: 1e-6)
        XCTAssertEqual(color.greenComponent, 0.70, accuracy: 1e-6)
        XCTAssertEqual(color.blueComponent, 0.82, accuracy: 1e-6)

        let directional = lights(in: root, type: .directional)
        XCTAssertEqual(directional.count, 2)
        XCTAssertEqual(directional.compactMap { $0.light?.intensity }.sorted(), [700, 1_350])
        for light in directional {
            XCTAssertTrue(light.parent === camera, "Directional illumination moves with the active camera.")
            XCTAssertLessThan(cameraRelativeDirection(light, camera: camera).z, 0,
                              "Both lights illuminate the model from the camera-facing hemisphere.")
        }
        XCTAssertFalse(view.autoenablesDefaultLighting)
    }

    @MainActor
    func testDirectionalLightAnglesRemainConstantInCameraSpaceAcrossViewsAndProjections() throws {
        let view = makeView()
        let root = try XCTUnwrap(view.scene.rootNode)
        let camera = try XCTUnwrap(view.pointOfView)
        let directional = lights(in: root, type: .directional)
        XCTAssertEqual(directional.count, 2)
        let localDirections = directional.map { cameraRelativeDirection($0, camera: camera) }
        let localTransforms = directional.map(\.simdTransform)
        let ambient = try XCTUnwrap(lights(in: root, type: .ambient).first)
        let ambientTransform = ambient.simdWorldTransform
        var frontDirections: [SIMD3<Float>] = []

        for projection in ViewportProjectionMode.allCases {
            for action in [ViewportCommand.Action.front, .right, .top, .isometric] {
                view.update(mesh: nil, mode: .edges, grid: false, command: ViewportCommand(action),
                            selectedSolids: [], hiddenSolids: [], projection: projection)
                for (index, light) in directional.enumerated() {
                    assertVector(cameraRelativeDirection(light, camera: camera), equals: localDirections[index])
                    assertMatrix(light.simdTransform, equals: localTransforms[index])
                }
                assertMatrix(ambient.simdWorldTransform, equals: ambientTransform)
                if action == .front {
                    frontDirections = directional.map(\.simdWorldFront)
                } else if action == .right || action == .top {
                    for (index, light) in directional.enumerated() {
                        XCTAssertGreaterThan(simd_distance(light.simdWorldFront, frontDirections[index]), 0.1,
                                             "World-space light directions must rotate with the camera.")
                    }
                }
            }
        }
    }

    @MainActor
    func testPanAndZoomTranslationDoNotChangeDirectionalIlluminationAngles() throws {
        let view = makeView()
        let root = try XCTUnwrap(view.scene.rootNode)
        let camera = try XCTUnwrap(view.pointOfView)
        let directional = lights(in: root, type: .directional)
        XCTAssertEqual(directional.count, 2)
        let localDirections = directional.map { cameraRelativeDirection($0, camera: camera) }
        let worldDirections = directional.map(\.simdWorldFront)
        let originalPosition = camera.simdPosition

        // Directional lights have no distance falloff. Moving the camera for
        // pan or cursor-relative zoom must retain both illumination angles.
        for offset in [SIMD3<Float>(20, -35, 10), SIMD3<Float>(-500, 250, 1_000), SIMD3<Float>(0, 0, -100)] {
            camera.simdPosition = originalPosition + offset
            for (index, light) in directional.enumerated() {
                assertVector(cameraRelativeDirection(light, camera: camera), equals: localDirections[index])
                assertVector(light.simdWorldFront, equals: worldDirections[index])
            }
        }
    }

    @MainActor
    private func makeView() -> CADSceneView {
        CADSceneView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    }

    @MainActor
    private func lights(in root: SCNNode, type: SCNLight.LightType) -> [SCNNode] {
        var result: [SCNNode] = []
        root.enumerateChildNodes { node, _ in
            if node.light?.type == type { result.append(node) }
        }
        return result
    }

    @MainActor
    private func cameraRelativeDirection(_ light: SCNNode, camera: SCNNode) -> SIMD3<Float> {
        simd_normalize(camera.simdConvertVector(light.simdWorldFront, from: nil))
    }

    private func assertVector(_ actual: SIMD3<Float>, equals expected: SIMD3<Float>,
                              file: StaticString = #filePath, line: UInt = #line) {
        for component in 0..<3 {
            XCTAssertEqual(actual[component], expected[component], accuracy: 1e-5, file: file, line: line)
        }
    }

    private func assertMatrix(_ actual: simd_float4x4, equals expected: simd_float4x4,
                              file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 1e-5, file: file, line: line)
            }
        }
    }
}
