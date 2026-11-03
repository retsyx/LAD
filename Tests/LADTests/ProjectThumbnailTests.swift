import AppKit
import Metal
import XCTest
@testable import LAD

final class ProjectThumbnailTests: XCTestCase {
    @MainActor
    func testFinderThumbnailIsSmallAndContainsRenderedGeometry() async throws {
        guard MTLCreateSystemDefaultDevice() != nil, !NSScreen.screens.isEmpty else {
            throw XCTSkip("Metal and a window server are required for thumbnail rendering.")
        }
        let preview = PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]],
            triangles: [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]],
            edges: [[0, 0, 0, 1, 0, 0], [0, 0, 0, 0, 1, 0], [0, 0, 0, 0, 0, 1]],
            bounds: [0, 0, 0, 1, 1, 1], volume: 1.0 / 6, area: 2.366, solids: 1, faces: 4,
            buildSeconds: 0, threads: 1, stepPath: "/tmp/thumbnail-fixture/model.step")
        let bytes = try await ProjectThumbnail.render(preview: preview, projection: .perspective,
            display: .edges, hiddenSolids: [], solidColors: [:])
        let image = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        XCTAssertEqual(image.pixelsWide, 512)
        XCTAssertEqual(image.pixelsHigh, 512)
        XCTAssertLessThan(bytes.count, 1_000_000)
        let background = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        var different = 0
        for y in stride(from: 32, to: 480, by: 16) {
            for x in stride(from: 32, to: 480, by: 16) {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let distance = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if distance > 0.05 { different += 1 }
            }
        }
        XCTAssertGreaterThan(different, 20, "A Finder thumbnail must contain geometry, not just its background.")
    }

    func testSaveNewCarriesPresentationImageOnlyForItsMatchingVersion() throws {
        let first = ProjectRevision(model: .bracket), second = ProjectRevision(model: .bracket)
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let project = LADProject(messages: [], revisions: [first, second], selectedRevisionID: second.id,
            thumbnailData: png)
        let latest = try SaveNewProject.snapshot(from: project)
        XCTAssertEqual(latest.thumbnailData, png)
        let historical = try SaveNewProject.snapshot(from: project, revisionID: first.id)
        XCTAssertNil(historical.thumbnailData, "The current image must not be assigned to a different version.")
        let encoded = try JSONEncoder().encode(project)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["thumbnailData"], "Presentation bytes are separate from project metadata.")
    }
}
