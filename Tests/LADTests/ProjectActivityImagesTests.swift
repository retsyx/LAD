import AppKit
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
        XCTAssertEqual(images.images[first]?.png, red)
        XCTAssertEqual(images.images[repair]?.png, blue)
        XCTAssertEqual(images.images[other]?.png, blue)
        images.store(blue, for: first)
        XCTAssertNotEqual(images.images[first]?.id, identity, "A replacement image must trigger a new decode.")
        XCTAssertEqual(images.images[repair]?.png, blue)
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
        XCTAssertEqual(byteBounded.images[keys[1]]?.png, blue)
        byteBounded.reset()
        XCTAssertTrue(byteBounded.images.isEmpty)
        byteBounded.store(Data("not a PNG".utf8), for: keys[2])
        XCTAssertTrue(byteBounded.images.isEmpty)
    }
}
