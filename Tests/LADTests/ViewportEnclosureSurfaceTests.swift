import AppKit
import Metal
import SceneKit
import XCTest
@testable import LAD

final class ViewportEnclosureSurfaceTests: XCTestCase {
    @MainActor
    func testRepresentativeEnclosureRoofDoesNotRevealHiddenEdges() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_EDGE_OCCLUSION_PREVIEW"] else {
            throw XCTSkip("Set LAD_EDGE_OCCLUSION_PREVIEW to the enclosure preview for its smooth-roof regression.")
        }
        let preview = try JSONDecoder().decode(PreviewMesh.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard preview.solids == 63, preview.bounds.count == 6 else {
            throw XCTSkip("This opt-in regression needs the 63-part enclosure.")
        }
        let label = ProcessInfo.processInfo.environment["LAD_EDGE_OCCLUSION_LABEL"] ?? "current"
        for projection in ViewportProjectionMode.allCases {
            let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 800), options: [
                SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
            ])
            view.update(mesh: preview, mode: .edges, grid: false, command: nil,
                selectedSolids: [], hiddenSolids: [], projection: projection,
                solidColors: [1: PartColor(red: 0.396, green: 0.667, blue: 0.761)])
            let deadline = ContinuousClock.now + .seconds(20)
            while view.isPreparingCaptureResources, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(view.isPreparingCaptureResources)
            for (index, angle) in [(-115.0, 60.0), (-90.0, 78.0), (-65.0, 88.0)].enumerated() {
                try view.configureAgentView(named: "top", camera: .init(yawDegrees: angle.0, elevationDegrees: angle.1, rollDegrees: 35, zoom: 1.1))
                let png = try await CADAgentRenderer.capturePNG(view: view)
                try png.write(to: URL(fileURLWithPath: "/tmp/lad-roof-\(label)-\(projection.rawValue)-\(index).png"))
                let image = try XCTUnwrap(NSBitmapImageRep(data: png))
                var darkSamples = 0, samples = 0
                // The inset roof is a continuous plane. Exclude its central
                // probe opening and sample away from all outer boundaries.
                for x in stride(from: 123.0, through: 171.0, by: 0.08) {
                    for y in stride(from: -100.0, through: -82.0, by: 0.08) {
                        guard hypot(x - 141.7, y + 90.4) > 4 else { continue }
                        let point = view.projectPoint(SCNVector3(x, y, 10.8186))
                        let column = Int(point.x), row = image.pixelsHigh - 1 - Int(point.y)
                        guard column >= 0, column < image.pixelsWide, row >= 0, row < image.pixelsHigh,
                              let color = image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                        samples += 1
                        if color.redComponent < 0.20 && color.greenComponent < 0.25 && color.blueComponent < 0.30 {
                            darkSamples += 1
                        }
                    }
                }
                print("Enclosure smooth roof dark samples", label, projection.rawValue, index, darkSamples, "/", samples)
                XCTAssertGreaterThan(samples, 50_000)
                XCTAssertEqual(darkSamples, 0, "Hidden assembly edges must not speckle the continuous lid roof.")
            }
        }
    }
}
