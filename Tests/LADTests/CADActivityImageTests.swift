import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class CADActivityImageTests: XCTestCase {
    @MainActor
    func testBridgeAssociatesExactPNGsWithEachCompletedRenderAndNeverReusesThemForFailures() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = ActivityImageCapture()
        let bridge = try CADAgentBridge(workspace: root, python: "/missing/python", threads: 1,
            current: .bracket, currentPreview: box(), engine: EngineService(), viewport: nil,
            hiddenSolids: [], solidColors: [:], onActivity: { events.append($0) })
        defer { bridge.stop() }
        bridge.start()

        let firstID = try send("lad_render", arguments: ["view": "front", "width": 320, "height": 256], in: root)
        let first = try await completed(firstID, events: events)
        let firstPNG = try assertImage(first, requestID: firstID, root: root, width: 320, height: 256)

        let secondID = try send("lad_render", arguments: ["view": "right", "width": 320, "height": 256], in: root)
        let second = try await completed(secondID, events: events)
        let secondPNG = try assertImage(second, requestID: secondID, root: root, width: 320, height: 256)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(firstPNG, secondPNG, "Different views must retain their own rendered results.")
        XCTAssertEqual(events.values.filter { $0.status == "running" }.compactMap(\.imageData), [])

        let invalidID = try send("lad_render", arguments: ["view": "unsupported"], in: root)
        let failed = try await completed(invalidID, events: events)
        XCTAssertEqual(failed.status, "failed")
        XCTAssertNil(failed.imageData)

        let inspectID = try send("lad_inspect", arguments: [:], in: root)
        let inspected = try await completed(inspectID, events: events)
        XCTAssertEqual(inspected.status, "completed")
        XCTAssertNil(inspected.imageData, "A later geometry query must not inherit a previous screenshot.")
        XCTAssertEqual(first.imageData, firstPNG, "Later calls must not mutate a retained event's exact PNG bytes.")
    }

    @MainActor
    func testScreenshotCarriesItsExactPNGInItsResultAndCanceledToolsReturnNone() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try CADAgentTools(directory: root, python: "/missing/python", threads: 1,
            current: .bracket, currentPreview: box(), engine: EngineService())
        let screenshot = try await tools.handle(name: "lad_screenshot", arguments: [:])
        let metadata = try content(screenshot)
        let path = try XCTUnwrap(metadata["path"] as? String)
        XCTAssertEqual(screenshot.image?.data, try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(screenshot.image?.path, path)
        let envelope = try XCTUnwrap(screenshot.envelope["content"] as? [[String: Any]])
        XCTAssertEqual(envelope.count, 2)
        XCTAssertEqual(envelope[0]["text"] as? String, screenshot.text)
        XCTAssertEqual(envelope[1] as NSDictionary, ["type": "image_path", "path": path, "mimeType": "image/png"] as NSDictionary)
        XCTAssertNil(screenshot.envelope["isError"])
        tools.cancel()
        do { _ = try await tools.handle(name: "lad_render", arguments: [:]); XCTFail("Canceled tools must not run.") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testCachedBuildCreatesNoScreenshotAndDoesNotChangeItsResponse() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("current.brep")
        try Data("DBRep_DrawableShape\n".utf8).write(to: native)
        let script = "result = cq.Solid.makeBox(6, 4, 2)\n"
        try Data(script.utf8).write(to: root.appendingPathComponent("program.py"))
        let model = ModelSpec(title: "Box", summary: "Fixture", units: "mm", script: script)
        var preview = box(); preview.brepPath = native.path
        let tools = try CADAgentTools(directory: root, python: "/missing/python", threads: 1,
            current: model, currentPreview: preview, engine: EngineService())
        let response = try await tools.handle(name: "lad_build", arguments: ["programPath": "program.py"])
        XCTAssertNil(response.image)
        XCTAssertEqual((response.envelope["content"] as? [[String: Any]])?.count, 1)
        XCTAssertNotNil(tools.validatedPreview(for: model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renders").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.stepPath))
    }

    @MainActor
    func testRenderImageIsArchivedAsOneAssetReferenceAndExcludedFromGenericCodable() throws {
        let bytes = try ImageAttachmentTestImage.png(.red, width: 40, height: 30)
        let event = ProjectActivityEvent(id: "tool:one", category: "tool", title: "lad_render", status: "completed",
            input: "{\"view\":\"front\"}", output: "Image result metadata", imageData: bytes)
        let encoded = try JSONEncoder().encode(event)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("imageData"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(bytes.base64EncodedString()))
        XCTAssertNil(try JSONDecoder().decode(ProjectActivityEvent.self, from: encoded).imageData)

        let user = ChatMessage(role: "user", content: "Review the design")
        var repeated = event
        repeated.id = "tool:two"
        let audit = ProjectTaskAudit(userMessageID: user.id, model: "test", reasoningEffort: "high", status: "completed",
                                     events: [event, repeated])
        let project = LADProject(messages: [user], revisions: [], selectedRevisionID: nil, taskAudits: [audit])
        let snapshot = try ProjectArchive.split(project)
        let hash = SHA256.hexDigest(bytes)
        XCTAssertEqual(snapshot.assets[hash], bytes, "The exact PNG is a content-addressed asset.")
        XCTAssertEqual(snapshot.assets.values.filter { $0 == bytes }.count, 1, "Identical images are stored once.")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.metadata) as? [String: Any])
        let rows = try XCTUnwrap((metadata["taskAudits"] as? [[String: Any]])?.first?["events"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["imageAsset"] as? String }, [hash, hash])
        XCTAssertTrue(rows.allSatisfy { $0["imageData"] == nil })
        XCTAssertEqual(try ProjectStore.decode(ProjectStore.encode(project)).taskAudits?.first?.events.map(\.imageData), [bytes, bytes])
    }

    @MainActor
    func testSavedImagesMustBePNGResultsOfImageTools() throws {
        let png = try ImageAttachmentTestImage.png(.blue)
        let user = ChatMessage(role: "user", content: "Review the design")
        for (title, image) in [("lad_measure", png), ("lad_render", Data("not a PNG".utf8))] {
            let event = ProjectActivityEvent(id: "tool:one", category: "tool", title: title, status: "completed", imageData: image)
            let audit = ProjectTaskAudit(userMessageID: user.id, model: "test", reasoningEffort: "high", status: "completed", events: [event])
            XCTAssertThrowsError(try ProjectStore.validate(LADProject(messages: [user], revisions: [], selectedRevisionID: nil,
                                                                      taskAudits: [audit])), title)
        }
    }

    private func send(_ name: String, arguments: [String: Any], in root: URL) throws -> String {
        let id = UUID().uuidString
        let request: [String: Any] = ["id": id, "name": name, "arguments": arguments]
        try JSONSerialization.data(withJSONObject: request)
            .write(to: root.appendingPathComponent(".lad-tools/requests/\(id).json"), options: .atomic)
        return id
    }

    @MainActor
    private func completed(_ id: String, events: ActivityImageCapture) async throws -> ProjectActivityEvent {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let event = events.values.last(where: { $0.id == "tool:\(id)" && $0.status != "running" }) { return event }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LADError.message("The image activity event did not finish.")
    }

    private func assertImage(_ event: ProjectActivityEvent, requestID: String, root: URL, width: Int, height: Int) throws -> Data {
        XCTAssertEqual(event.id, "tool:\(requestID)")
        XCTAssertEqual(event.status, "completed")
        let png = try XCTUnwrap(event.imageData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent(".lad-tools/responses/\(requestID).json"))) as? [String: Any])
        let metadata = try content(response)
        let path = try XCTUnwrap(metadata["path"] as? String)
        XCTAssertEqual(png, try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(metadata["byteCount"] as? Int, png.count)
        XCTAssertFalse(event.output?.contains(png.base64EncodedString()) == true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, width)
        XCTAssertEqual(bitmap.pixelsHigh, height)
        return png
    }

    private func content(_ result: CADAgentToolResult) throws -> [String: Any] {
        result.metadata
    }

    private func content(_ result: [String: Any]) throws -> [String: Any] {
        let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-activity-images-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return try EngineArtifact.canonicalDirectory(root)
    }

    private func box() -> PreviewMesh {
        PreviewMesh(vertices: [[-3,-2,-1],[3,-2,-1],[3,2,-1],[-3,2,-1],[-3,-2,1],[3,-2,1],[3,2,1],[-3,2,1]],
            triangles: [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]],
            edges: [], bounds: [-3,-2,-1,3,2,1], volume: 48, area: 88, solids: 1, faces: 6,
            buildSeconds: 0, threads: 1, stepPath: "/session/activity-image-box")
    }
}

private final class ActivityImageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProjectActivityEvent] = []
    func append(_ event: ProjectActivityEvent) { lock.lock(); events.append(event); lock.unlock() }
    var values: [ProjectActivityEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
