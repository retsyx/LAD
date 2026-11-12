import AppKit
import XCTest
@testable import LAD

final class CADAgentRenderCameraToolTests: XCTestCase {
    @MainActor
    func testInvalidCameraArgumentsFailBeforeAnyBuildOrImage() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try CADAgentTools(directory: root, python: "/missing/python", threads: 1, current: nil,
            currentPreview: nil, engine: EngineService())
        let invalid: [[String: Any]] = [
            ["zoom": true], ["zoom": 0], ["zoom": -2], ["zoom": "2"], ["zoom": Double.infinity],
            ["yawDegrees": false], ["elevationDegrees": 91], ["rollDegrees": Double.nan],
            ["cameraPosition": [1, 2]], ["cameraTarget": [1, 2, 3, 4]],
            ["cameraPosition": [true, 1, 2]], ["cameraTarget": [0, Double.infinity, 0]],
            ["cameraPosition": [1, 2, 3], "yawDegrees": 12],
            ["cameraPosition": [1, 2, 3], "cameraTarget": [1, 2, 3]]
        ]
        for input in invalid {
            do { _ = try await tools.handle(name: "lad_render", arguments: input); XCTFail("Invalid camera was accepted: \(input)") }
            catch {
                XCTAssertTrue(error.localizedDescription.lowercased().contains("camera"))
                XCTAssertFalse(error.localizedDescription.contains("Python"), "Validation must precede CAD work.")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renders").path))
    }

    @MainActor
    func testToolReturnsActualCustomPoseAndExactObservedImage() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try CADAgentTools(directory: root, python: "/missing/python", threads: 1,
            current: .bracket, currentPreview: box(), engine: EngineService())
        let arguments: [String: Any] = ["view": "front", "projection": "perspective", "yawDegrees": 23.5,
            "elevationDegrees": 31.25, "rollDegrees": 17.0, "zoom": 1.4, "width": 320, "height": 256]
        let result = try await tools.handle(name: "lad_render", arguments: arguments)
        let metadata = try content(result)
        XCTAssertEqual(metadata["customCamera"] as? Bool, true)
        XCTAssertEqual(metadata["view"] as? String, "front", "The preset remains the base view.")
        XCTAssertEqual(metadata["zoom"] as? Double, 1.4)
        let requested = try XCTUnwrap(metadata["cameraParameters"] as? [String: Any])
        XCTAssertEqual(requested["yawDegrees"] as? Double, 23.5)
        let expected = try CADAgentCamera(yawDegrees: 23.5, elevationDegrees: 31.25, rollDegrees: 17, zoom: 1.4)
            .resolved(view: "front", bounds: box().bounds, width: 320, height: 256, orthographic: false)
        let position = try XCTUnwrap(metadata["cameraPosition"] as? [Double])
        for axis in 0..<3 { XCTAssertEqual(position[axis], expected.position[axis], accuracy: 0.00001) }
        XCTAssertEqual(try XCTUnwrap(metadata["cameraDistance"] as? Double), expected.distance, accuracy: 1e-10)
        XCTAssertEqual(metadata["cameraTarget"] as? [Double], [0, 0, 0])
        let path = try XCTUnwrap(metadata["path"] as? String)
        let png = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(result.image?.data, png)
        XCTAssertEqual(result.image?.path, path)
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(data: png)).pixelsWide, 320)
        XCTAssertEqual(metadata["byteCount"] as? Int, png.count)
    }

    private func content(_ result: CADAgentToolResult) throws -> [String: Any] {
        result.metadata
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-render-camera-tool-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func box() -> PreviewMesh {
        PreviewMesh(vertices: [[-3,-2,-1],[3,-2,-1],[3,2,-1],[-3,2,-1],[-3,-2,1],[3,-2,1],[3,2,1],[-3,2,1]],
            triangles: [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]],
            edges: [], bounds: [-3,-2,-1,3,2,1], volume: 48, area: 88, solids: 1, faces: 6,
            buildSeconds: 0, threads: 1, stepPath: "/session/custom-camera-box")
    }
}
