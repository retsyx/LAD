import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LAD

final class CodexImageInputTests: XCTestCase {
    @MainActor
    func testCurrentImagesBecomeOrderedVisualInputsWhileHistoricalImagesStayLocalReferences() async throws {
        let first = try image("Front view.png", red: 40)
        let second = try image("Side view.png", red: 180)
        let older = try image("Previous screenshot.png", red: 90)
        let source = source("reference.fs", content: "SOURCE_BYTES_STAY_LOCAL")
        let fixture = try FakeCodex(responseJSON: readyResponse(), delay: 0.02)
        defer { fixture.remove() }
        let service = CodexService()
        defer { service.cancel() }
        _ = try await service.generate(prompt: "Create the enclosure shown in these views", current: nil,
            history: [ChatMessage(role: "user", content: "Earlier reference", attachments: [older])],
            attachments: [first, source, second], executable: fixture.executable.path, model: "", onProgress: { _ in })

        let input = try userInput(try fixture.turnRequest())
        XCTAssertEqual(input.compactMap { $0["type"] as? String }, ["text", "localImage", "localImage"])
        let request = try XCTUnwrap(input.first?["text"] as? String)
        let currentReferences = try references(marker: "CURRENT IMAGE FILE REFERENCES (JSON):", in: request)
        XCTAssertEqual(currentReferences.map(\.name), [first.name, second.name])
        let manifest = try imageManifest(in: request, fixture: fixture)
        let imageReferences = manifest.map(\.file)
        XCTAssertEqual(imageReferences.map(\.name), [first.name, second.name, older.name])
        XCTAssertEqual(manifest.map(\.isCurrent), [true, true, false])
        XCTAssertEqual(input.dropFirst().compactMap { $0["path"] as? String }, currentReferences.map(\.readPath))
        XCTAssertEqual(try references(marker: "ATTACHED SOURCE FILE REFERENCES (JSON):", in: request).map(\.name), [source.name])
        for (reference, attachment) in zip(imageReferences, [first, second, older]) {
            XCTAssertEqual(try fixture.capturedData(at: reference.readPath), attachment.data)
            XCTAssertEqual(reference.path, attachment.path)
            XCTAssertEqual(reference.sha256, attachment.sha256)
            XCTAssertEqual(reference.byteCount, attachment.byteCount)
            XCTAssertFalse(request.contains(attachment.data.base64EncodedString()), "Image bytes must not become prompt text.")
        }
        XCTAssertFalse(request.contains(source.content))
        XCTAssertFalse(input.dropFirst().contains { $0["url"] != nil || $0["data"] != nil },
                       "Images must use local paths, never embedded data URLs.")
        try fixture.assertJobWasCleanedUp()
    }

    @MainActor
    func testCompleteSavedImageHistoryIsExtractedAndIndexedWithoutExpandingPromptText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-image-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("reference.png")
        var history: [ChatMessage] = []
        // Repeated versions of one original path must remain individually
        // available when referring to the corresponding older log message.
        for index in 0..<(SourceImport.maximumImages + 4) {
            try png(red: UInt8(index + 10)).write(to: original)
            let attachment = try XCTUnwrap(SourceImport.load(urls: [original]).first)
            history.append(ChatMessage(role: "user", content: "Saved reference \(index)", attachments: [attachment]))
        }
        // One binary payload may appear in several messages, but it should
        // occupy just one extracted task file, as it does in the ZIP archive.
        history.append(ChatMessage(role: "user", content: "Reuse the first view", attachments: history[0].attachments))
        let current = try image("Current view.png", red: 240)
        var project = LADProject(messages: history, revisions: [], selectedRevisionID: nil)
        project.draftAttachments = [current]
        let reopened = try ProjectStore.decode(ProjectStore.encode(project))
        try FileManager.default.removeItem(at: original)

        let fixture = try FakeCodex(responseJSON: readyResponse(), delay: 0.02)
        defer { fixture.remove() }
        let service = CodexService()
        defer { service.cancel() }
        _ = try await service.generate(prompt: "Use the first saved image with this current view", current: nil,
            history: reopened.messages, attachments: try XCTUnwrap(reopened.draftAttachments),
            executable: fixture.executable.path, model: "", onProgress: { _ in })
        let input = try userInput(try fixture.turnRequest())
        XCTAssertEqual(input.compactMap { $0["type"] as? String }, ["text", "localImage"])
        let request = try XCTUnwrap(input[0]["text"] as? String)
        let manifest = try imageManifest(in: request, fixture: fixture)
        XCTAssertEqual(manifest.count, history.count + 1)
        XCTAssertEqual(manifest.filter(\.isCurrent).map(\.attachmentID), [current.id])
        XCTAssertEqual(manifest.filter { !$0.isCurrent }.compactMap(\.messageID), history.map(\.id))
        XCTAssertTrue(manifest.filter { !$0.isCurrent }.allSatisfy { $0.messageDate != nil })

        let allAttachments = [current] + reopened.messages.flatMap { $0.attachments ?? [] }
        for (reference, attachment) in zip(manifest, allAttachments) {
            XCTAssertEqual(reference.attachmentID, attachment.id)
            XCTAssertEqual(reference.file.path, attachment.path)
            XCTAssertEqual(reference.file.sha256, attachment.sha256)
            XCTAssertEqual(try fixture.capturedData(at: reference.file.readPath), attachment.data)
            XCTAssertFalse(request.contains(attachment.data.base64EncodedString()))
        }
        let expectedFiles = Set(allAttachments.map(\.sha256)).count
        XCTAssertEqual(Set(manifest.map { $0.file.readPath }).count, expectedFiles)
        let extracted = try FileManager.default.contentsOfDirectory(at: fixture.captureURL.appendingPathComponent("context/images"),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(extracted.count, expectedFiles)
        for old in allAttachments.dropFirst() {
            XCTAssertFalse(request.contains(old.sha256), "Historical metadata belongs in the local manifest, not an ever-growing prompt.")
        }
        XCTAssertLessThan(request.utf8.count, 65_536)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        try fixture.assertJobWasCleanedUp()
    }

    @MainActor
    func testReopenedImageOnlyRequestAndRepairRestagePixelsAfterOriginalFileIsRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-image-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("reference.png")
        try png(red: 125).write(to: originalURL)
        let attachments = try SourceImport.load(urls: [originalURL])
        var project = LADProject(messages: [], revisions: [], selectedRevisionID: nil)
        project.draftAttachments = attachments
        let restored = try ProjectStore.decode(ProjectStore.encode(project))
        let reopened = try XCTUnwrap(restored.draftAttachments)
        try FileManager.default.removeItem(at: originalURL)

        let fixture = try FakeCodex(responseJSON: readyResponse(), delay: 0.02)
        defer { fixture.remove() }
        let service = CodexService()
        defer { service.cancel() }
        var stagedPaths: [String] = []
        // Repair turns use the same generate path with their captured images.
        for prompt in ["", "Repair the geometry while preserving this visual reference"] {
            _ = try await service.generate(prompt: prompt, current: .bracket, history: [], attachments: reopened,
                executable: fixture.executable.path, model: "", onProgress: { _ in })
            let input = try userInput(try fixture.turnRequest())
            let visual = try XCTUnwrap(input.first { $0["type"] as? String == "localImage" })
            let path = try XCTUnwrap(visual["path"] as? String)
            XCTAssertNotEqual(path, originalURL.path)
            XCTAssertEqual(try fixture.capturedData(at: path), attachments[0].data)
            stagedPaths.append(path)
            try fixture.assertJobWasCleanedUp()
        }
        XCTAssertNotEqual(stagedPaths[0], stagedPaths[1], "Each task must own and clean up its extracted image files.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
    }

    @MainActor
    func testMultipleImagesSteerTheAcknowledgedActiveTurnWithoutStartingAnotherRequest() async throws {
        let fixture = try FakeCodex(responseJSON: readyResponse(), delay: 1.0, steeringMode: "finish-before-ack")
        defer { fixture.remove() }
        let service = CodexService()
        defer { service.cancel() }
        let generation = Task {
            try await service.generate(prompt: "Create an enclosure", current: nil, history: [],
                executable: fixture.executable.path, model: "", onProgress: { _ in })
        }
        defer { generation.cancel() }
        try await waitUntil { service.canSteer }
        let turn = try XCTUnwrap(service.currentTurnID)
        let first = try image("Connector detail.png", red: 30)
        let second = try image("Lid detail.png", red: 220)
        let accepted = try await service.steer(prompt: "Use these additional views", attachments: [first, second])
        XCTAssertEqual(accepted, turn)
        _ = try await generation.value

        let requests = try fixture.rpcRequests()
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
        let params = try XCTUnwrap(requests.first { $0["method"] as? String == "turn/steer" }?["params"] as? [String: Any])
        XCTAssertEqual(params["expectedTurnId"] as? String, turn)
        let input = try userInput(params)
        XCTAssertEqual(input.compactMap { $0["type"] as? String }, ["text", "localImage", "localImage"])
        let text = try XCTUnwrap(input[0]["text"] as? String)
        let refs = try references(marker: "ATTACHED IMAGE FILE REFERENCES (JSON):", in: text)
        XCTAssertEqual(refs.map(\.name), [first.name, second.name])
        XCTAssertEqual(input.dropFirst().compactMap { $0["path"] as? String }, refs.map(\.readPath))
        for (reference, image) in zip(refs, [first, second]) {
            XCTAssertEqual(try fixture.capturedData(at: reference.readPath), image.data)
            XCTAssertFalse(text.contains(image.data.base64EncodedString()))
        }
        try fixture.assertJobWasCleanedUp()
    }

    @MainActor
    func testImageLimitIsCheckedLocallyBeforeLaunchingCodex() async throws {
        let fixture = try FakeCodex(responseJSON: readyResponse())
        defer { fixture.remove() }
        let images = try (0...SourceImport.maximumImages).map { try image("View \($0).png", red: UInt8($0)) }
        do {
            _ = try await CodexService().generate(prompt: "Use the references", current: nil, history: [], attachments: images,
                executable: fixture.executable.path, model: "", onProgress: { _ in })
            XCTFail("Too many current images must fail locally rather than silently omit visual inputs.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ten images"),
                          "Image limits should be checked before any transport work, not fail for an unrelated setup error.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.turnRequestURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.argumentsURL.path))
        }
    }

    private func userInput(_ params: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(params["input"] as? [[String: Any]])
    }

    private func references(marker: String, in request: String) throws -> [CodexSourceReference] {
        let range = try XCTUnwrap(request.range(of: marker + "\n"))
        let line = try XCTUnwrap(request[range.upperBound...].split(separator: "\n", maxSplits: 1).first)
        return try JSONDecoder().decode([CodexSourceReference].self, from: Data(line.utf8))
    }

    private func imageManifest(in request: String, fixture: FakeCodex) throws -> [CodexImageReference] {
        let range = try XCTUnwrap(request.range(of: "IMAGE REFERENCE MANIFEST FILE:\n"))
        let line = try XCTUnwrap(request[range.upperBound...].split(separator: "\n", maxSplits: 1).first)
        let path = try JSONDecoder().decode(String.self, from: Data(line.utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CodexImageReference].self, from: fixture.capturedData(at: path))
    }

    private func source(_ name: String, content: String) -> SourceAttachment {
        SourceAttachment(name: name, path: "/missing/\(name)", content: content,
            sha256: SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    private func image(_ name: String, red: UInt8) throws -> SourceAttachment {
        try SourceImport.imageAttachment(data: png(red: red), name: name)
    }

    private func png(red: UInt8) throws -> Data {
        let pixels = Data(Array(repeating: [red, UInt8(90), UInt8(180), UInt8(255)], count: 4).flatMap { $0 })
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    private func readyResponse() throws -> String {
        let model = ModelSpec.bracket
        let response: [String: Any] = ["status": "ready", "message": "Design ready.", "assetIDs": [], "model": [
            "title": model.title, "summary": model.summary, "units": model.units, "script": model.script]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "The isolated app-server fixture must expose an active turn.")
    }
}
