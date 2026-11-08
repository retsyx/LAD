import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import LADThumbnailSupport

final class ProjectThumbnailReaderTests: XCTestCase {
    func testReadsVerifiedPNGFromManifestWithoutLoadingRecipes() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let image = try png()
        try write(image, to: package)
        XCTAssertEqual(try ProjectThumbnailReader.imageData(in: package), image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("revisions").path))
    }

    func testThumbnailReadDoesNotWaitForAnotherFileCoordinationClaim() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let image = try png()
        try write(image, to: package)
        let writerEntered = expectation(description: "The competing write claim is held")
        let writerFinished = expectation(description: "The competing writer has finished")
        let releaseWriter = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var error: NSError?
            coordinator.coordinate(writingItemAt: package, options: [], error: &error) { _ in
                writerEntered.fulfill()
                XCTAssertEqual(releaseWriter.wait(timeout: .now() + 15), .success)
            }
            XCTAssertNil(error)
            writerFinished.fulfill()
        }
        wait(for: [writerEntered], timeout: 5)

        // Quick Look already coordinates its request. A nested read must not
        // queue behind a writer that can itself be waiting for that request.
        DispatchQueue.global().async {
            defer { readerFinished.signal() }
            do {
                let actual = try ProjectThumbnailReader.imageData(in: package)
                XCTAssertEqual(actual, image)
            } catch { XCTFail("Could not read the existing thumbnail: \(error)") }
        }
        let readWhileWriterHeld = readerFinished.wait(timeout: .now() + 5)
        releaseWriter.signal()
        wait(for: [writerFinished], timeout: 5)
        if readWhileWriterHeld == .timedOut {
            XCTAssertEqual(readerFinished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(readWhileWriterHeld, .success,
                       "Thumbnail reads must not acquire another file-coordination claim.")
    }

    func testMissingThumbnailUsesDocumentIcon() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        try Data("{}".utf8).write(to: package.appendingPathComponent("project.json"))
        XCTAssertNil(try ProjectThumbnailReader.imageData(in: package))
    }

    func testRejectsChangedBytesAndInvalidImageEvenWithMatchingHash() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let image = try png()
        let file = try write(image, to: package)
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try ProjectThumbnailReader.imageData(in: package))
        try write(Data("not a PNG".utf8), to: package)
        XCTAssertThrowsError(try ProjectThumbnailReader.imageData(in: package))
    }

    func testRejectsTraversalAndSymbolicLinks() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let image = try png()
        let file = try write(image, to: package)
        let hash = digest(image)
        try manifest(path: "../\(hash)", hash: hash).write(to: package.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ProjectThumbnailReader.imageData(in: package))
        try manifest(path: "assets/sha256/\(hash.prefix(2))/\(hash)", hash: hash)
            .write(to: package.appendingPathComponent("project.json"))
        let outside = package.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try image.write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectThumbnailReader.imageData(in: package))
        try FileManager.default.removeItem(at: package.appendingPathComponent("assets"))
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("assets"),
                                                withDestinationURL: package.deletingLastPathComponent())
        XCTAssertThrowsError(try ProjectThumbnailReader.imageData(in: package))
    }

    func testRejectsOversizedManifestAndImage() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let image = Data(repeating: 0, count: ProjectThumbnailReader.maximumImageBytes + 1)
        try write(image, to: package)
        XCTAssertThrowsError(try ProjectThumbnailReader.imageData(in: package))
        let manifest = package.appendingPathComponent("project.json")
        try Data(repeating: 32, count: ProjectThumbnailReader.maximumManifestBytes + 1).write(to: manifest)
        XCTAssertThrowsError(try ProjectThumbnailReader.imageData(in: package))
    }

    private func temporaryPackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-thumbnail-\(UUID()).lad", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        return package
    }

    @discardableResult
    private func write(_ image: Data, to package: URL) throws -> URL {
        let hash = digest(image)
        let path = "assets/sha256/\(hash.prefix(2))/\(hash)"
        let file = package.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: file)
        try manifest(path: path, hash: hash).write(to: package.appendingPathComponent("project.json"))
        return file
    }

    private func manifest(path: String, hash: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["thumbnail": ["path": path, "sha256": hash]])
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
