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
