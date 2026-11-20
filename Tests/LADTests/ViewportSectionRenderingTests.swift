import AppKit
import SceneKit
import simd
import XCTest
@testable import LAD

final class ViewportSectionRenderingTests: XCTestCase {
    @MainActor
    func testLiveCaptureClipsFacesOrdinaryEdgesAndPartOutlines() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        let preview = PreviewMesh(positions: [-10, -10, 0, 10, -10, 0, 10, 10, 0, -10, 10, 0],
            triangleIndices: [0, 1, 2, 0, 2, 3], edgePoints: [-10, 0, 0, 10, 0, 0],
            bounds: [-10, -10, 0, 10, 10, 0], volume: 0, area: 400, solids: 1, faces: 1,
            buildSeconds: 0, threads: 1, stepPath: "section-plate", edgeSolids: [0])
        for mode in ViewportDisplayMode.allCases {
            view.update(mesh: preview, mode: mode, grid: false, command: ViewportCommand(.top),
                        selectedSolids: [0], hiddenSolids: [], projection: .isometric, sectionEnabled: true)
            let image = try await capture(view)
            let normal = try XCTUnwrap(view.sectionPlane).normal.x
            let background = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            let kept = try pixelBlock(view, image, around: SCNVector3(-5 * normal, 0, 0), radius: 2)
            let removed = try pixelBlock(view, image, around: SCNVector3(5 * normal, 0, 0), radius: 2)
            let clippedOutline = try pixelBlock(view, image, around: SCNVector3(5 * normal, 10, 0), radius: 4)
            XCTAssertTrue(kept.contains { abs($0.redComponent - background.redComponent) > 0.13 }, mode.rawValue)
            XCTAssertTrue((removed + clippedOutline).allSatisfy { abs($0.redComponent - background.redComponent) < 0.02 },
                          "Clipped scene geometry and selection outlines must both disappear in \(mode.rawValue).")
        }
        view.update(mesh: preview, mode: .shaded, grid: false, command: nil,
                    selectedSolids: [0], hiddenSolids: [], projection: .isometric, sectionEnabled: false)
        let full = try await capture(view)
        for x in [-5.0, 5.0] {
            let restored = try pixelBlock(view, full, around: SCNVector3(x, 0, 0), radius: 1)
            XCTAssertTrue(restored.allSatisfy { $0.redComponent > 0.25 })
        }
    }

    @MainActor
    func testSectionCapsHatchSolidAndLeaveAThroughHoleOpen() async throws {
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        let preview = tube()
        for projection in ViewportProjectionMode.allCases {
            for mode in [ViewportDisplayMode.edges, .translucent] {
                view.update(mesh: preview, mode: mode, grid: false, command: ViewportCommand(.right),
                            selectedSolids: [], hiddenSolids: [], projection: projection, sectionEnabled: true)
                let image = try await capture(view)
                let background = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
                let opening = try pixelBlock(view, image, around: SCNVector3Zero, radius: 5)
                let cut = try pixelBlock(view, image, around: SCNVector3(0, 0, 8), radius: 5).map(\.redComponent)
                XCTAssertTrue(opening.allSatisfy { abs($0.redComponent - background.redComponent) < 0.02 })
                XCTAssertGreaterThan(try XCTUnwrap(cut.min()), background.redComponent + 0.1)
                XCTAssertGreaterThan(try XCTUnwrap(cut.max()) - XCTUnwrap(cut.min()), 0.02,
                                     "The visual section stays hatched in \(projection) \(mode).")
            }
        }
    }

    @MainActor
    func testMovingSectionKeepsTheLastMatchingCapAndCoalescesPendingCuts() async throws {
        let preview = tube()
        let mesh = try XCTUnwrap(CADViewportPreparedMesh.prepare(preview))
        let initial = try XCTUnwrap(CADSectionPlane(bounds: preview.bounds, toward: SIMD3(1, 0, 0)))
        let firstMove = try XCTUnwrap(initial.setting(1, for: .offset))
        let skipped = try XCTUnwrap(initial.setting(2, for: .offset))
        let latest = try XCTUnwrap(initial.setting(3, for: .offset))
        let caps = CADViewportSectionCaps()
        let initialReady = expectation(description: "Initial section cap prepared")
        let latestReady = expectation(description: "Newest section cap prepared")
        var presented: [CADSectionPlane] = []
        func request(_ cut: CADSectionPlane) {
            caps.update(plane: cut, mesh: mesh, transforms: [:], hidden: [], mode: .edges, renderer: nil) { plane, geometry in
                guard let plane, let geometry else {
                    XCTFail("Moving an intersecting cut must publish its matching cap.")
                    return
                }
                let offset = plane.value(for: .offset)
                XCTAssertEqual(Double(geometry.boundingBox.min.x), offset, accuracy: 1e-6)
                XCTAssertEqual(Double(geometry.boundingBox.max.x), offset, accuracy: 1e-6)
                caps.node.geometry = geometry
                presented.append(plane)
                if plane == initial { initialReady.fulfill() }
                if plane == firstMove { XCTAssertTrue(caps.isPreparing) }
                if plane == latest { latestReady.fulfill() }
            }
        }
        request(initial)
        await fulfillment(of: [initialReady], timeout: 3)
        let originalCap = try XCTUnwrap(caps.node.geometry)

        request(firstMove)
        request(skipped)
        request(latest)
        XCTAssertIdentical(caps.node.geometry, originalCap)
        XCTAssertEqual(presented, [initial])
        await fulfillment(of: [latestReady], timeout: 3)
        XCTAssertEqual(presented, [initial, firstMove, latest])
        XCTAssertFalse(caps.isPreparing)
    }

    @MainActor
    func testDraggingSectionKeepsTheFramePlaneAndCapTogether() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = CADSceneView(frame: frame)
        view.preparesRendererResources = false
        window.contentView = view
        view.update(mesh: tube(), mode: .edges, grid: false, command: nil, selectedSolids: [], hiddenSolids: [],
                    projection: .isometric, sectionEnabled: true)
        let initialReady = try await view.waitForCaptureResources(until: .now + .seconds(3))
        XCTAssertTrue(initialReady)
        let initialPlane = try XCTUnwrap(view.sectionPlane)
        let cap = try XCTUnwrap(view.scene.rootNode.childNodes.first { $0.categoryBitMask == CADViewportCategory.sectionCaps })
        let initialGeometry = try XCTUnwrap(cap.geometry)
        let manipulator = try XCTUnwrap(view.subviews.compactMap { $0 as? CADSectionManipulator }.first)
        let handles = try XCTUnwrap(manipulator.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement })
        guard handles.count == 3 else { XCTFail("The section manipulator needs three handles."); return }
        func center(_ handle: NSAccessibilityElement) -> SIMD2<Double> {
            let rect = window.convertFromScreen(handle.accessibilityFrame())
            return SIMD2(rect.midX, rect.midY)
        }
        let arrow = center(handles[0])
        let hub = SIMD2(center(handles[1]).x, center(handles[2]).y)
        let end = arrow + 12 * simd_normalize(arrow - hub)
        func mouse(_ type: NSEvent.EventType, at point: SIMD2<Double>) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: point.y), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        manipulator.mouseDown(with: try mouse(.leftMouseDown, at: arrow))
        manipulator.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        let latestPlane = try XCTUnwrap(view.sectionPlane)
        XCTAssertNotEqual(latestPlane, initialPlane)
        XCTAssertIdentical(cap.geometry, initialGeometry)
        XCTAssertEqual(view.makeFrame(width: 640, height: 480).sectionPlane, initialPlane.equation)

        let movedReady = try await view.waitForCaptureResources(until: .now + .seconds(3))
        XCTAssertTrue(movedReady)
        let movedGeometry = try XCTUnwrap(cap.geometry)
        XCTAssertFalse(movedGeometry === initialGeometry)
        XCTAssertEqual(view.makeFrame(width: 640, height: 480).sectionPlane, latestPlane.equation)
        XCTAssertEqual(Double(movedGeometry.boundingBox.min.x), latestPlane.origin.x, accuracy: 1e-6)
    }

    @MainActor
    private func capture(_ view: CADSceneView) async throws -> NSBitmapImageRep {
        let png = try await CADAgentRenderer.capturePNG(view: view)
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    @MainActor
    private func pixelBlock(_ view: CADSceneView, _ image: NSBitmapImageRep, around world: SCNVector3,
                            radius: Int) throws -> [NSColor] {
        let point = view.projectPoint(world)
        let x = Int(point.x.rounded()), y = image.pixelsHigh - Int(point.y.rounded())
        return try (y - radius...y + radius).flatMap { row in
            try (x - radius...x + radius).map { column in
                try XCTUnwrap(image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
            }
        }
    }

    /// A closed rectangular tube with one hole through the section plane.
    private func tube() -> PreviewMesh {
        let corners: [SIMD2<Float>] = [.init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1)]
        var positions = [Float](), indices = [UInt32]()
        for x: Float in [-8, 8] {
            for radius: Float in [10, 6] {
                for corner in corners { positions.append(contentsOf: [x, radius * corner.x, radius * corner.y]) }
            }
        }
        func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
            indices.append(contentsOf: [a, b, c, a, c, d])
        }
        for i: UInt32 in 0..<4 {
            let j = (i + 1) % 4
            quad(i, j, j + 8, i + 8)
            quad(i + 4, i + 12, j + 12, j + 4)
            quad(i, i + 4, j + 4, j)
            quad(i + 8, j + 8, j + 12, i + 12)
        }
        return PreviewMesh(positions: positions, triangleIndices: indices, bounds: [-8, -10, -10, 8, 10, 10],
                           volume: 4_096, area: 2_560, solids: 1, faces: 16,
                           buildSeconds: 0, threads: 1, stepPath: "section-tube")
    }
}
