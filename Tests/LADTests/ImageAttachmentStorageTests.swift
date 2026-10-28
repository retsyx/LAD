import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LAD

final class ImageAttachmentStorageTests: XCTestCase {
    func testFoldersWithImageSuffixesRemainPathDrops() throws {
        let directory = try temporaryDirectory()
        let folder = directory.appendingPathComponent("Photos.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let symlink = directory.appendingPathComponent("Folder alias.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: folder)
        XCTAssertFalse(SourceImport.isImageURL(folder))
        XCTAssertFalse(SourceImport.isImageURL(symlink))
        XCTAssertTrue(SourceImport.isImageURL(directory.appendingPathComponent("Missing.png")),
                      "A missing image must still reach image import and report its missing path.")
        XCTAssertFalse(SourceImport.isImageURL(URL(string: "https://example.com/image.png")!))
    }

    func testLoadingImagesKeepsPortableBytesAndOriginalFilesUnchanged() throws {
        let directory = try temporaryDirectory()
        let png = try imageData(type: .png)
        let jpeg = try imageData(type: .jpeg)
        let first = directory.appendingPathComponent("Corner.png")
        let second = directory.appendingPathComponent("Case.jpeg")
        try png.write(to: first)
        try jpeg.write(to: second)
        let images = try SourceImport.load(urls: [first, second, first])
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images.allSatisfy(\.isImage))
        XCTAssertEqual(images.map(\.content), ["", ""])
        XCTAssertEqual(images.map(\.data), [png, jpeg])
        XCTAssertEqual(images.map(\.byteCount), [png.count, jpeg.count])
        XCTAssertEqual(images.map(\.fileExtension), ["png", "jpg"])
        XCTAssertEqual(images[0].sha256, digest(png))
        XCTAssertEqual(try Data(contentsOf: first), png)
        XCTAssertEqual(try Data(contentsOf: second), jpeg)
        XCTAssertEqual(try JSONDecoder().decode([SourceAttachment].self, from: JSONEncoder().encode(images)), images)
    }

    func testNativeAndRotatedImagesBecomeUprightPortablePNGs() throws {
        let native = try SourceImport.imageAttachment(data: imageData(type: .tiff), name: "Native.tiff")
        XCTAssertEqual(native.fileExtension, "png")
        XCTAssertTrue(native.path.hasPrefix("clipboard://"))
        XCTAssertTrue(native.content.isEmpty)
        let nativeProperties = try properties(native.data)
        XCTAssertEqual(nativeProperties.width, 40)
        XCTAssertEqual(nativeProperties.height, 20)
        XCTAssertEqual(nativeProperties.type, UTType.png.identifier)

        let rotated = try SourceImport.imageAttachment(data: imageData(type: .jpeg, orientation: 6), name: "Portrait.jpg")
        let rotatedProperties = try properties(rotated.data)
        XCTAssertEqual(rotated.fileExtension, "png")
        XCTAssertEqual(rotatedProperties.width, 20, "EXIF rotation must become actual upright image pixels.")
        XCTAssertEqual(rotatedProperties.height, 40)
        XCTAssertEqual(rotatedProperties.orientation, 1)
        try SourceImport.validateAttachments([native, rotated])
    }

    func testImagesHaveTheirOwnBudgetAlongsideFourTextSources() throws {
        let directory = try temporaryDirectory()
        // PNG noise is intentionally larger than the existing 1 MiB text-file
        // limit. Image attachments must not be truncated or counted as text.
        let largePNG = try imageData(type: .png, width: 900, height: 900, noise: true)
        XCTAssertGreaterThan(largePNG.count, SourceImport.maximumFileBytes)
        let url = directory.appendingPathComponent("Detailed.png")
        try largePNG.write(to: url)
        let loaded = try XCTUnwrap(SourceImport.load(urls: [url]).first)
        XCTAssertEqual(loaded.data, largePNG)

        let source = text("result = cq.Workplane('XY').box(1,2,3)", name: "body.py")
        let sources = (0..<SourceImport.maximumFiles).map { index -> SourceAttachment in
            var copy = source; copy.id = UUID(); copy.path = "/sources/\(index).py"; return copy
        }
        let image = try SourceImport.imageAttachment(data: imageData(type: .png))
        let images = (0..<SourceImport.maximumImages).map { index -> SourceAttachment in
            var copy = image; copy.id = UUID(); copy.path = "clipboard://\(index)"; return copy
        }
        XCTAssertNoThrow(try SourceImport.validateAttachments(sources + images))
        var extraImage = image; extraImage.id = UUID()
        XCTAssertThrowsError(try SourceImport.validateAttachments(images + [extraImage]))
        var extraSource = source; extraSource.id = UUID()
        XCTAssertThrowsError(try SourceImport.validateAttachments(sources + [extraSource]))

        var oversized = image
        oversized.imageData = Data(repeating: 0, count: SourceImport.maximumImageFileBytes + 1)
        XCTAssertThrowsError(try SourceImport.validateAttachments([oversized]))
        var large = image
        large.imageData = image.data + Data(repeating: 0, count: 14 * 1_048_576)
        let tooMuch = (0..<5).map { _ -> SourceAttachment in var copy = large; copy.id = UUID(); return copy }
        XCTAssertThrowsError(try SourceImport.validateAttachments(tooMuch))
    }

    func testCorruptBinaryOversizedDimensionsAndMislabeledImageSnapshotsAreRejected() throws {
        XCTAssertThrowsError(try SourceImport.imageAttachment(data: Data("not an image".utf8)))
        XCTAssertThrowsError(try SourceImport.imageAttachment(data: Data()))
        let excessive = try imageData(type: .png, width: SourceImport.maximumImageDimension + 1, height: 1)
        XCTAssertThrowsError(try SourceImport.imageAttachment(data: excessive))
        var image = try SourceImport.imageAttachment(data: imageData(type: .png))
        image.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try SourceImport.validateAttachments([image]))
        image = try SourceImport.imageAttachment(data: imageData(type: .png))
        image.content = "Hidden alternate text payload"
        XCTAssertThrowsError(try SourceImport.validateAttachments([image]))

        let jpeg = try SourceImport.imageAttachment(data: imageData(type: .jpeg))
        var mislabeled = jpeg; mislabeled.id = UUID(); mislabeled.name = "Wrong.png"
        XCTAssertThrowsError(try SourceImport.validateAttachments([jpeg, mislabeled]),
                             "A reused payload must still validate each attachment's declared file format.")
    }

    func testZIPArchiveDeduplicatesImageBytesAcrossChatQueueAndDraftAndReloadsWithoutOriginals() throws {
        let directory = try temporaryDirectory()
        let firstURL = directory.appendingPathComponent("Reference.png")
        let secondURL = directory.appendingPathComponent("Detail.jpg")
        try imageData(type: .png).write(to: firstURL)
        try imageData(type: .jpeg).write(to: secondURL)
        let images = try SourceImport.load(urls: [firstURL, secondURL])
        var renamedCopy = images[0]
        renamedCopy.id = UUID(); renamedCopy.name = "Another reference.png"; renamedCopy.path = "/missing/copy.png"
        let source = text("// construction instructions", name: "Reference.fs")
        var project = LADProject(messages: [ChatMessage(role: "user", content: "Use these references", attachments: images + [source]),
                                            ChatMessage(role: "assistant", content: "I will inspect the reference images.", phase: "commentary")],
                                 revisions: [], selectedRevisionID: nil, projectID: UUID())
        project.queuedRequests = [ProjectQueuedRequest(content: "Refine this corner", attachments: [renamedCopy, images[1]])]
        project.draftPrompt = "Use these next"
        project.draftAttachments = images
        project.queuePaused = true
        let bytes = try ProjectStore.encode(project)
        XCTAssertEqual(bytes.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        let json = try manifest(bytes)
        let assets = try XCTUnwrap(json["assets"] as? [String: String])
        XCTAssertEqual(assets.count, 3, "Two image payloads and one source snapshot are shared across every reference.")
        XCTAssertEqual(assets[images[0].sha256], images[0].data.base64EncodedString())
        XCTAssertEqual(assets[images[1].sha256], images[1].data.base64EncodedString())
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let saved = try XCTUnwrap(messages[0]["attachments"] as? [[String: Any]])
        XCTAssertEqual(saved[0]["kind"] as? String, "image")
        XCTAssertEqual(saved[0]["contentAsset"] as? String, images[0].sha256)
        XCTAssertNil(saved[0]["imageData"])
        XCTAssertNil(saved[0]["content"])
        XCTAssertNil(saved[0]["thumbnail"])
        try FileManager.default.removeItem(at: firstURL)
        try FileManager.default.removeItem(at: secondURL)
        let restored = try ProjectStore.decode(bytes)
        XCTAssertEqual(restored.messages, project.messages)
        XCTAssertEqual(restored.queuedRequests, project.queuedRequests)
        XCTAssertEqual(restored.draftAttachments, project.draftAttachments)
        XCTAssertEqual(restored.draftAttachments?.map(\.data), images.map(\.data))
    }

    func testArchiveRejectsWrongImageKindAndImagePayloadIntegrity() throws {
        let image = try SourceImport.imageAttachment(data: imageData(type: .png))
        let project = LADProject(messages: [ChatMessage(role: "user", content: "See image", attachments: [image])],
                                 revisions: [], selectedRevisionID: nil)
        var json = try manifest(ProjectStore.encode(project))
        var messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        var attachments = try XCTUnwrap(messages[0]["attachments"] as? [[String: Any]])
        attachments[0]["kind"] = "executable"
        messages[0]["attachments"] = attachments; json["messages"] = messages
        XCTAssertThrowsError(try ProjectStore.decode(compressed(json)))

        json = try manifest(ProjectStore.encode(project))
        var assets = try XCTUnwrap(json["assets"] as? [String: String])
        assets[image.sha256] = Data("corrupt bytes".utf8).base64EncodedString()
        json["assets"] = assets
        XCTAssertThrowsError(try ProjectStore.decode(compressed(json)))
    }

    func testMergeDeduplicatesRepeatedImageContentAndUpdatesChangedFileSnapshots() throws {
        let first = try SourceImport.imageAttachment(data: imageData(type: .png), name: "First.png", path: "/first.png")
        let duplicate = try SourceImport.imageAttachment(data: first.data, name: "Second.png", path: "/second.png")
        XCTAssertEqual(try SourceImport.mergeAttachments(existing: [first], added: [duplicate]).count, 1)
        let changed = try SourceImport.imageAttachment(data: imageData(type: .jpeg), name: "First.jpg", path: first.path)
        let replacement = try SourceImport.mergeAttachments(existing: [first], added: [changed])
        XCTAssertEqual(replacement, [changed])
        let earlier = text("old", name: "body.py")
        var newer = text("new", name: "body.py"); newer.path = earlier.path
        XCTAssertEqual(try SourceImport.mergeAttachments(existing: [earlier], added: [newer]), [newer])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-image-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func imageData(type: UTType, width: Int = 40, height: Int = 20, orientation: Int = 1, noise: Bool = false) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0x12845678
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                if noise {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    pixels[index * 4 + channel] = UInt8(truncatingIfNeeded: seed >> 24)
                } else { pixels[index * 4 + channel] = channel == (index % width < width / 2 ? 0 : 2) ? 220 : 30 }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func properties(_ data: Data) throws -> (type: String, width: Int, height: Int, orientation: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let values = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        return (try XCTUnwrap(CGImageSourceGetType(source)) as String,
                try XCTUnwrap(values[kCGImagePropertyPixelWidth as String] as? Int),
                try XCTUnwrap(values[kCGImagePropertyPixelHeight as String] as? Int),
                values[kCGImagePropertyOrientation as String] as? Int ?? 1)
    }

    private func text(_ content: String, name: String) -> SourceAttachment {
        SourceAttachment(name: name, path: "/sources/\(name)", content: content, sha256: digest(Data(content.utf8)))
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func manifest(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectZIP.decode(data)) as? [String: Any])
    }
    private func compressed(_ manifest: [String: Any]) throws -> Data { try ProjectZIP.encode(JSONSerialization.data(withJSONObject: manifest)) }
}
