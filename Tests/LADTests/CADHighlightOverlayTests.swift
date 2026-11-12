import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class CADHighlightOverlayTests: XCTestCase {
    @MainActor
    func testSelectedCoreMatchesTheSameConstantMaterialColorAndChannelsHaveDifferentWidths() throws {
        let shot = try render()
        let selected = try sample(shot, at: SCNVector3(0, 0.5, 0))
        let hover = try sample(shot, at: SCNVector3(0, -0.5, 0))
        let control = try sample(shot, at: controlPosition)
        assertColor(selected, equals: control, accuracy: 0.02,
            "Composited selected color must match the same NSColor on a constant SceneKit material")
        XCTAssertGreaterThan(colorDistance(selected, hover), 0.1, "Independent red/green seeds must produce their own style colors")
        let widths = try coreWidths(shot)
        XCTAssertGreaterThanOrEqual(widths.selected, 3, "The selected foreground core must render")
        XCTAssertGreaterThanOrEqual(widths.hover, 2, "The hover foreground core must render")
        XCTAssertGreaterThanOrEqual(widths.selected, widths.hover,
            "At 1×, integer counts of fully covered pixels can tie; the 2× test distinguishes their logical widths")
    }

    @MainActor
    func testSelectedStyleWinsWhereItsNativeSeedCrossesTheHoverSeed() throws {
        let shot = try render(crossing: true)
        let crossing = try sample(shot, at: SCNVector3(0, 0, 0))
        let selectedAway = try sample(shot, at: SCNVector3(0.8, 0, 0))
        let hoverAway = try sample(shot, at: SCNVector3(0, 0.7, 0))
        let control = try sample(shot, at: controlPosition)
        assertColor(crossing, equals: control, accuracy: 0.02, "Selected style must win over hover at the crossing")
        assertColor(selectedAway, equals: control, accuracy: 0.02, "The selected channel must retain its color away from the crossing")
        XCTAssertGreaterThan(colorDistance(crossing, hoverAway), 0.1)
    }

    @MainActor
    func testScreenPointWidthsScaleAtTwoTimesOutputResolutionAndOccludedSeedsRemainVisible() throws {
        let one = try render(scale: 1), two = try render(scale: 2)
        let first = try coreWidths(one), second = try coreWidths(two)
        XCTAssertGreaterThanOrEqual(first.selected, 3)
        XCTAssertGreaterThanOrEqual(first.hover, 2)
        XCTAssertEqual(Double(second.selected), Double(first.selected * 2), accuracy: 2,
            "Selected width must scale with output pixels while retaining its screen-point width")
        XCTAssertEqual(Double(second.hover), Double(first.hover * 2), accuracy: 2,
            "Hover width must scale with output pixels while retaining its screen-point width")
        XCTAssertGreaterThan(second.selected, second.hover)
        let hidden = try render(scale: 2, occluded: true)
        let selectedReference = try sample(two, at: SCNVector3(0, 0.5, 0))
        let hoverReference = try sample(two, at: SCNVector3(0, -0.5, 0))
        XCTAssertGreaterThan(countPixels(hidden.image, near: selectedReference), 100,
            "The overlay must retain the complete selected line behind an independent nearer face")
        XCTAssertGreaterThan(countPixels(hidden.image, near: hoverReference), 100,
            "The overlay must retain the complete hovered line behind an independent nearer face")
    }

    @MainActor
    func testTranslucentColorPassDoesNotOccludeHighlightOverlays() throws {
        let visible = try render(scale: 2, translucent: true)
        let selected = try sample(visible, at: SCNVector3(0, 0.5, 0))
        let hovered = try sample(visible, at: SCNVector3(0, -0.5, 0))
        XCTAssertGreaterThan(countPixels(visible.image, near: selected), 100)
        let occluded = try render(scale: 2, occluded: true, translucent: true)
        XCTAssertGreaterThan(countPixels(occluded.image, near: selected), 100,
            "The selected overlay ignores geometry depth in translucent mode too.")
        XCTAssertGreaterThan(countPixels(occluded.image, near: hovered), 100,
            "The hover overlay ignores geometry depth in translucent mode too.")
    }

    private var selectedColor: NSColor { NSColor(srgbRed: 0.96, green: 0.63, blue: 0.23, alpha: 1) }
    private var hoverColor: NSColor { NSColor(srgbRed: 0.35, green: 0.83, blue: 0.72, alpha: 1) }
    private var haloColor: NSColor { NSColor(srgbRed: 0.14, green: 0.22, blue: 0.28, alpha: 1) }
    private var inkColor: NSColor { NSColor(srgbRed: 0.025, green: 0.035, blue: 0.045, alpha: 1) }
    private var controlPosition: SCNVector3 { SCNVector3(-2.35, 1.25, -0.25) }

    private typealias Shot = ViewportPassShot

    @MainActor
    private func render(scale: Int = 1, crossing: Bool = false, occluded: Bool = false, translucent: Bool = false) throws -> Shot {
        let scene = SCNScene()
        scene.background.contents = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 2.4
        camera.camera?.zNear = 1; camera.camera?.zFar = 20
        camera.position = SCNVector3(0, 0, 10)
        scene.rootNode.addChildNode(camera)
        func plane(width: CGFloat, height: CGFloat, at position: SCNVector3, color: NSColor) -> SCNNode {
            let node = SCNNode(geometry: SCNPlane(width: width, height: height))
            let material = SCNMaterial()
            material.lightingModel = .constant; material.diffuse.contents = color
            node.geometry?.materials = [material]; node.position = position
            if translucent, let geometry = node.geometry {
                CADSceneView.configureFaceMaterial(material, translucent: true)
                for category in [CADViewportCategory.visibility, CADViewportCategory.revealage] {
                    node.addChildNode(CADSceneView.translucentCopy(of: geometry, category: category, visible: true))
                }
            }
            scene.rootNode.addChildNode(node)
            return node
        }
        _ = plane(width: 8, height: 6, at: SCNVector3(0, 0, -0.5),
            color: NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1))
        let control = plane(width: 0.65, height: 0.65, at: controlPosition, color: selectedColor)
        if translucent {
            // The control swatch is the reference color, not part of the
            // translucent design.
            control.childNodes.forEach { $0.removeFromParentNode() }
            if let material = control.geometry?.firstMaterial { CADSceneView.configureFaceMaterial(material, translucent: false) }
            control.categoryBitMask = CADViewportCategory.decorations
        }
        let selected = crossing ? [[-1.6, 0, 0, 1.6, 0, 0]] : [[-1.6, 0.5, 0, 1.6, 0.5, 0]]
        let hover = crossing ? [[0, -1.2, 0, 0, 1.2, 0]] : [[-1.6, -0.5, 0, 1.6, -0.5, 0]]
        if occluded {
            _ = plane(width: 8, height: 6, at: SCNVector3(0, 0, 0.2),
                color: NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1))
        }
        let palette = CADHighlightPalette(selected: selectedColor, hover: hoverColor, hoverHalo: haloColor, ink: inkColor,
                                          background: try XCTUnwrap(scene.background.contents as? NSColor))
        return try ViewportPassTestRenderer.render(scene: scene, camera: camera, width: 256 * scale, height: 192 * scale,
            referenceHeight: 192, translucent: translucent, palette: palette,
            seeds: [try ViewportPassTestRenderer.seeds(selected, channel: .selectedEdge),
                    try ViewportPassTestRenderer.seeds(hover, channel: .hoveredEdge)])
    }

    @MainActor
    private func sample(_ shot: Shot, at point: SCNVector3) throws -> NSColor {
        try shot.color(at: point)
    }

    @MainActor
    private func coreWidths(_ shot: Shot) throws -> (selected: Int, hover: Int) {
        let selected = try sample(shot, at: SCNVector3(0, 0.5, 0))
        let hover = try sample(shot, at: SCNVector3(0, -0.5, 0))
        var selectedWidth = 0, hoverWidth = 0
        for row in 0..<shot.image.pixelsHigh {
            let color = try XCTUnwrap(shot.image.colorAt(x: shot.image.pixelsWide / 2, y: row)?.usingColorSpace(.sRGB))
            if colorDistance(color, selected) < 0.065 { selectedWidth += 1 }
            if colorDistance(color, hover) < 0.065 { hoverWidth += 1 }
        }
        return (selectedWidth, hoverWidth)
    }

    private func countPixels(_ image: NSBitmapImageRep, near reference: NSColor) -> Int {
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colorDistance(color, reference) < 0.065 { count += 1 }
            }
        }
        return count
    }

    private func colorDistance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        max(abs(first.redComponent - second.redComponent), abs(first.greenComponent - second.greenComponent),
            abs(first.blueComponent - second.blueComponent))
    }

    private func assertColor(_ actual: NSColor, equals expected: NSColor, accuracy: CGFloat,
                             _ description: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: accuracy, description, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: accuracy, description, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: accuracy, description, file: file, line: line)
    }
}
