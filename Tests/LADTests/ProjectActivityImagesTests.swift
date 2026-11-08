import AppKit
import ImageIO
import XCTest
@testable import LAD

final class ProjectActivityImagesTests: XCTestCase {
    @MainActor
    func testImagesAreKeyedByTaskAndScopedEventAndUnchangedResultsReuseTheirIdentity() throws {
        let images = ProjectActivityImages()
        let red = try ImageAttachmentTestImage.png(.red)
        let blue = try ImageAttachmentTestImage.png(.blue)
        let first = ProjectActivityImageKey(taskID: UUID(), eventID: "project:tool:shared")
        let repair = ProjectActivityImageKey(taskID: first.taskID, eventID: "repair:tool:shared")
        let other = ProjectActivityImageKey(taskID: UUID(), eventID: first.eventID)
        images.store(red, for: first)
        let identity = try XCTUnwrap(images.images[first]?.id)
        images.store(red, for: first)
        XCTAssertEqual(images.images[first]?.id, identity)
        images.store(blue, for: repair)
        images.store(blue, for: other)
        XCTAssertEqual(images.images[first]?.data, red)
        XCTAssertEqual(images.images[repair]?.data, blue)
        XCTAssertEqual(images.images[other]?.data, blue)
        images.store(blue, for: first)
        XCTAssertNotEqual(images.images[first]?.id, identity, "A replacement image must trigger a new decode.")
        XCTAssertEqual(images.images[repair]?.data, blue)
    }

    @MainActor
    func testEncodedImageHistoryHasBoundedCountAndBytesAndClearsOnReset() throws {
        let red = try ImageAttachmentTestImage.png(.red)
        let blue = try ImageAttachmentTestImage.png(.blue)
        let task = UUID()
        let keys = (0..<3).map { ProjectActivityImageKey(taskID: task, eventID: "tool:\($0)") }
        let countBounded = ProjectActivityImages(maximumImages: 2)
        for key in keys { countBounded.store(red, for: key) }
        XCTAssertNil(countBounded.images[keys[0]])
        XCTAssertEqual(countBounded.images.count, 2)
        let byteBounded = ProjectActivityImages(maximumBytes: red.count + 1)
        byteBounded.store(red, for: keys[0])
        byteBounded.store(blue, for: keys[1])
        XCTAssertNil(byteBounded.images[keys[0]])
        XCTAssertEqual(byteBounded.images[keys[1]]?.data, blue)
        byteBounded.reset()
        XCTAssertTrue(byteBounded.images.isEmpty)
        byteBounded.store(Data("not a PNG".utf8), for: keys[2])
        XCTAssertTrue(byteBounded.images.isEmpty)
    }

    @MainActor
    func testJPEGKeepsExactOriginalBytesAndUsesItsOrientedDimensions() throws {
        let image = try jpeg(orientation: 6)
        let images = ProjectActivityImages()
        let key = ProjectActivityImageKey(taskID: UUID(), eventID: "image-view")
        images.store(image, for: key)
        let reference = try XCTUnwrap(images.images[key])
        XCTAssertEqual(reference.data, image)
        XCTAssertTrue(["jpg", "jpeg"].contains(reference.fileExtension))
        XCTAssertEqual(reference.pixelSize, CGSize(width: 10, height: 20))
        images.store(Data(repeating: 0, count: 32 * 1024 * 1024 + 1), for: key)
        XCTAssertEqual(images.images[key]?.id, reference.id, "Rejected bytes must not replace an existing image.")
    }

    @MainActor
    func testOpenExportsOriginalImagePrivatelyAndUsesTheSystemOpenerAfterWorkspaceRemoval() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try jpeg()
        let original = directory.appendingPathComponent("source.jpg")
        try image.write(to: original)
        var opened = [URL]()
        let images = ProjectActivityImages(temporaryDirectory: directory, opener: { url in
            opened.append(url)
            return true
        })
        let key = ProjectActivityImageKey(taskID: UUID(), eventID: "image-view")
        images.store(try Data(contentsOf: original), for: key)
        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                      "Storing a collapsed result must not create an export.")
        let reference = try XCTUnwrap(images.images[key])
        try await images.open(reference)
        let exported = try XCTUnwrap(opened.first)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(["jpg", "jpeg"].contains(exported.pathExtension))
        XCTAssertEqual(try Data(contentsOf: exported), image)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: exported.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        try Data("A viewer changed its temporary copy".utf8).write(to: exported)
        try await images.open(reference)
        XCTAssertEqual(try Data(contentsOf: exported), image, "Opening again must retain the original tool result.")
        images.reset()
        try await waitForRemoval(exported)
    }

    @MainActor
    func testEvictionRemovesExportedCopiesAndStaleImagesCannotOpen() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var opened = [URL]()
        let images = ProjectActivityImages(maximumImages: 1, temporaryDirectory: directory, opener: {
            opened.append($0)
            return true
        })
        let task = UUID()
        let first = ProjectActivityImageKey(taskID: task, eventID: "first")
        let second = ProjectActivityImageKey(taskID: task, eventID: "second")
        images.store(try ImageAttachmentTestImage.png(.red), for: first)
        let removed = try XCTUnwrap(images.images[first])
        try await images.open(removed)
        let exported = try XCTUnwrap(opened.first)
        images.store(try ImageAttachmentTestImage.png(.blue), for: second)
        try await waitForRemoval(exported)
        do {
            try await images.open(removed)
            XCTFail("Evicted images must not create another export.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
        XCTAssertEqual(opened.count, 1)
        images.reset()
    }

    @MainActor
    func testOpenFailureIsReportedAndResetRejectsAnOldReference() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var attempts = 0
        let images = ProjectActivityImages(temporaryDirectory: directory, opener: { _ in
            attempts += 1
            return false
        })
        let key = ProjectActivityImageKey(taskID: UUID(), eventID: "render")
        images.store(try ImageAttachmentTestImage.png(.red), for: key)
        let reference = try XCTUnwrap(images.images[key])
        do {
            try await images.open(reference)
            XCTFail("The system open failure must reach the caller.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be opened")) }
        XCTAssertEqual(attempts, 1)
        images.reset()
        do {
            try await images.open(reference)
            XCTFail("A previous design's image must not open after reset.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
        XCTAssertEqual(attempts, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-activity-image-open-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @MainActor
    private func jpeg(orientation: Int = 1) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try ImageAttachmentTestImage.png(.green, width: 20, height: 10) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitForRemoval(_ url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
