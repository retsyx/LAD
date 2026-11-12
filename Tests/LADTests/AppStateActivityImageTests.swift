import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import LAD

final class AppStateActivityImageTests: XCTestCase {
    @MainActor
    func testCompletedRenderImagesFollowExactTaskAndScopedEventIdentities() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = "Create a synthetic design"
        state.submit()
        let taskID = try XCTUnwrap(state.taskAudits.first?.id)
        let red = try ImageAttachmentTestImage.png(.red)
        let blue = try ImageAttachmentTestImage.png(.blue)
        let projectID = "project:tool:shared-render-id"
        let repairID = "repair:tool:shared-render-id"
        let projectKey = ProjectActivityImageKey(taskID: taskID, eventID: projectID)
        let repairKey = ProjectActivityImageKey(taskID: taskID, eventID: repairID)
        let viewedID = "project:server:thread:image-1"
        let viewedKey = ProjectActivityImageKey(taskID: taskID, eventID: viewedID)

        state.recordTaskEvent(event(projectID, status: "running", image: red))
        XCTAssertNil(savedImage(state, task: taskID, event: projectID), "An unfinished tool result must not expose a completed render image.")
        state.recordTaskEvent(event(projectID, image: red))
        state.recordTaskEvent(event(repairID, title: "lad_screenshot", image: blue))
        state.recordTaskEvent(event(viewedID, title: "imageView", status: "running", image: blue))
        XCTAssertNil(state.activityImages.images[viewedKey])
        state.recordTaskEvent(event(viewedID, title: "imageView", image: blue))
        XCTAssertEqual(state.activityImages.images[viewedKey]?.data, blue)
        XCTAssertNil(savedImage(state, task: taskID, event: viewedID), "Images an agent only viewed stay out of the saved log.")
        XCTAssertEqual(savedImage(state, task: taskID, event: projectID), red)
        XCTAssertEqual(savedImage(state, task: taskID, event: repairID), blue,
                       "Project and repair attempts may reuse native tool IDs without sharing their images.")
        XCTAssertEqual(state.activityImages.reference(for: projectKey, savedImage: red)?.data, red)
        XCTAssertEqual(state.activityImages.reference(for: repairKey, savedImage: blue)?.data, blue)
        XCTAssertEqual(state.taskAudits.first?.events.count, 3)

        state.recordTaskEvent(event(projectID, output: "Metadata-only completion update"))
        XCTAssertEqual(savedImage(state, task: taskID, event: projectID), red,
                       "Text-only upserts must retain the matching already-produced image.")
        XCTAssertEqual(state.taskAudits.first?.events.count, 3)
        XCTAssertEqual(state.taskAudits.first?.events.first?.output, "Metadata-only completion update")

        state.cancel() // Cancel before yielding: no Codex or CAD worker starts.
        await state.prepareToQuit()
    }

    @MainActor
    func testCanceledAndNonImageToolEventsCannotInjectOrReplaceCachedImages() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = "Create a synthetic design"
        state.submit()
        let taskID = try XCTUnwrap(state.taskAudits.first?.id)
        let red = try ImageAttachmentTestImage.png(.red)
        let blue = try ImageAttachmentTestImage.png(.blue)
        let acceptedID = "project:tool:accepted"
        let acceptedKey = ProjectActivityImageKey(taskID: taskID, eventID: acceptedID)
        state.recordTaskEvent(event(acceptedID, image: red))
        state.recordTaskEvent(event("project:tool:measurement", title: "lad_measure", image: blue))
        state.recordTaskEvent(event("project:tool:not-png", image: Data("not a PNG".utf8)))
        XCTAssertNil(state.activityImages.images[ProjectActivityImageKey(taskID: taskID, eventID: "project:tool:measurement")])
        XCTAssertNil(savedImage(state, task: taskID, event: "project:tool:measurement"),
                     "Even unexpected media on a text tool must stay out of the saved audit.")
        XCTAssertNil(savedImage(state, task: taskID, event: "project:tool:not-png"))
        state.stopGeneration()
        let finished = state.taskAudits
        state.recordTaskEvent(event(acceptedID, image: blue))
        state.recordTaskEvent(event("project:tool:late", image: blue))
        XCTAssertEqual(state.taskAudits, finished)
        XCTAssertEqual(savedImage(state, task: taskID, event: acceptedID), red)
        XCTAssertNil(state.activityImages.reference(for: acceptedKey, savedImage: nil))
        await state.prepareToQuit()
    }

    @MainActor
    func testIdenticalEventIDsStayIsolatedAcrossProjectsAndSuccessiveTasks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.state("first"), second = fixture.state("second")
        first.newProject(); second.newProject()
        first.prompt = "First synthetic design"; first.submit()
        second.prompt = "Second synthetic design"; second.submit()
        let firstTask = try XCTUnwrap(first.taskAudits.first?.id)
        let secondTask = try XCTUnwrap(second.taskAudits.first?.id)
        let red = try ImageAttachmentTestImage.png(.red)
        let blue = try ImageAttachmentTestImage.png(.blue)
        let eventID = "project:tool:reused"
        first.recordTaskEvent(event(eventID, image: red))
        second.recordTaskEvent(event(eventID, image: blue))
        XCTAssertEqual(savedImage(first, task: firstTask, event: eventID), red)
        XCTAssertEqual(savedImage(second, task: secondTask, event: eventID), blue)
        XCTAssertNil(savedImage(first, task: secondTask, event: eventID))
        XCTAssertNil(savedImage(second, task: firstTask, event: eventID))
        first.cancel()
        first.prompt = "Another synthetic request"; first.submit()
        let nextTask = try XCTUnwrap(first.taskAudits.last?.id)
        XCTAssertNotEqual(firstTask, nextTask)
        first.recordTaskEvent(event(eventID, image: blue))
        XCTAssertEqual(savedImage(first, task: firstTask, event: eventID), red)
        XCTAssertEqual(savedImage(first, task: nextTask, event: eventID), blue)
        first.cancel(); second.cancel()
        await first.prepareToQuit(); await second.prepareToQuit()
    }

    @MainActor
    func testRenderImagesAreSavedOnceAsPackageAssetsAndShownAfterReopening() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = "Create a synthetic design"
        state.submit()
        let taskID = try XCTUnwrap(state.taskAudits.first?.id)
        let png = try ImageAttachmentTestImage.png(.systemTeal, width: 80, height: 60)
        let viewed = try ImageAttachmentTestImage.png(.magenta, width: 20, height: 10)
        let eventID = "project:tool:render"
        state.recordTaskEvent(event(eventID, image: png))
        state.recordTaskEvent(event("project:tool:screenshot", title: "lad_screenshot", image: png))
        state.recordTaskEvent(event("project:server:thread:view", title: "imageView", image: viewed))
        let key = ProjectActivityImageKey(taskID: taskID, eventID: eventID)
        XCTAssertEqual(savedImage(state, task: taskID, event: eventID), png)
        state.cancel()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        ProjectPackage.clearSessionCache()
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.taskAudits, state.taskAudits)
        XCTAssertEqual(saved.taskAudits?.first?.events.compactMap(\.imageData), [png, png])
        let hash = SHA256.hexDigest(png)
        let asset = url.appendingPathComponent("assets/sha256/\(hash.prefix(2))/\(hash)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path), "Renders are stored as package assets.")
        let snapshot = try ProjectArchive.split(saved)
        XCTAssertEqual(snapshot.assets.values.filter { $0 == png }.count, 1, "Identical renders are stored once.")
        XCTAssertFalse(snapshot.assets.values.contains(viewed), "Images an agent only viewed stay out of the design.")
        XCTAssertFalse(String(decoding: snapshot.metadata, as: UTF8.self).contains(png.base64EncodedString()))

        let reopened = fixture.state("reopened")
        reopened.activityImages.store(viewed, for: key)
        reopened.loadProject(saved, from: url)
        XCTAssertTrue(reopened.activityImages.images.isEmpty, "Loading a design must discard any previous design's session images.")
        XCTAssertEqual(reopened.taskAudits, saved.taskAudits)
        XCTAssertEqual(reopened.activityImages.reference(for: key, savedImage: savedImage(reopened, task: taskID, event: eventID))?.data, png)
        await reopened.prepareToQuit()
    }

    @MainActor
    func testNewProjectClearsPriorTaskImagesAndRejectsItsLateCallbacks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = "Previous synthetic design"; state.submit()
        let oldTaskID = try XCTUnwrap(state.taskAudits.first?.id)
        let png = try ImageAttachmentTestImage.png(.orange)
        let oldID = "project:tool:old"
        state.recordTaskEvent(event(oldID, image: png))
        XCTAssertEqual(savedImage(state, task: oldTaskID, event: oldID), png)
        state.newProject()
        XCTAssertTrue(state.activityImages.images.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)
        state.recordTaskEvent(event("project:tool:late", image: png))
        XCTAssertTrue(state.activityImages.images.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)
        await state.prepareToQuit()
    }

    @MainActor
    private func savedImage(_ state: AppState, task: UUID, event: String) -> Data? {
        state.taskAudits.first { $0.id == task }?.events.first { $0.id == event }?.imageData
    }

    private func event(_ id: String, title: String = "lad_render", status: String = "completed",
                       output: String = "Rendered view metadata", image: Data? = nil) -> ProjectActivityEvent {
        ProjectActivityEvent(id: id, category: "tool", title: title, status: status,
                             input: "{\"view\":\"top\"}", output: output, imageData: image)
    }

    private struct Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-activity-images-state-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        @MainActor
        func state(_ name: String = "design") -> AppState {
            AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent(name, isDirectory: true)))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
