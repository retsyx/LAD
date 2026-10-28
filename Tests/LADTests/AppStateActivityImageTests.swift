import AppKit
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

        state.recordTaskEvent(event(projectID, status: "running", image: red))
        XCTAssertNil(state.activityImages.images[projectKey], "An unfinished tool result must not expose a completed render image.")
        state.recordTaskEvent(event(projectID, image: red))
        state.recordTaskEvent(event(repairID, title: "lad_screenshot", image: blue))
        XCTAssertEqual(state.activityImages.images[projectKey]?.png, red)
        XCTAssertEqual(state.activityImages.images[repairKey]?.png, blue,
                       "Project and repair attempts may reuse native tool IDs without sharing their images.")
        XCTAssertEqual(state.taskAudits.first?.events.count, 2)
        XCTAssertTrue(state.taskAudits.first?.events.allSatisfy { $0.imageData == nil } == true)

        state.recordTaskEvent(event(projectID, output: "Metadata-only completion update"))
        XCTAssertEqual(state.activityImages.images[projectKey]?.png, red,
                       "Text-only upserts must retain the matching already-produced image.")
        XCTAssertEqual(state.taskAudits.first?.events.count, 2)
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
        XCTAssertNil(state.activityImages.images[ProjectActivityImageKey(taskID: taskID, eventID: "project:tool:measurement")])
        XCTAssertTrue(state.taskAudits.first?.events.allSatisfy { $0.imageData == nil } == true,
                      "Even unexpected media on a text tool must stay out of the saved audit.")
        state.stopGeneration()
        let finished = state.taskAudits
        state.recordTaskEvent(event(acceptedID, image: blue))
        state.recordTaskEvent(event("project:tool:late", image: blue))
        XCTAssertEqual(state.taskAudits, finished)
        XCTAssertEqual(state.activityImages.images[acceptedKey]?.png, red)
        XCTAssertNil(state.activityImages.images[ProjectActivityImageKey(taskID: taskID, eventID: "project:tool:late")])
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
        XCTAssertEqual(first.activityImages.images[ProjectActivityImageKey(taskID: firstTask, eventID: eventID)]?.png, red)
        XCTAssertEqual(second.activityImages.images[ProjectActivityImageKey(taskID: secondTask, eventID: eventID)]?.png, blue)
        XCTAssertNil(first.activityImages.images[ProjectActivityImageKey(taskID: secondTask, eventID: eventID)])
        XCTAssertNil(second.activityImages.images[ProjectActivityImageKey(taskID: firstTask, eventID: eventID)])
        first.cancel()
        first.prompt = "Another synthetic request"; first.submit()
        let nextTask = try XCTUnwrap(first.taskAudits.last?.id)
        XCTAssertNotEqual(firstTask, nextTask)
        first.recordTaskEvent(event(eventID, image: blue))
        XCTAssertEqual(first.activityImages.images[ProjectActivityImageKey(taskID: firstTask, eventID: eventID)]?.png, red)
        XCTAssertEqual(first.activityImages.images[ProjectActivityImageKey(taskID: nextTask, eventID: eventID)]?.png, blue)
        first.cancel(); second.cancel()
        await first.prepareToQuit(); await second.prepareToQuit()
    }

    @MainActor
    func testImagesNeverEnterTheAuditArchiveAndReopeningClearsSessionMedia() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        state.newProject()
        state.prompt = "Create a synthetic design"
        state.submit()
        let taskID = try XCTUnwrap(state.taskAudits.first?.id)
        let png = try ImageAttachmentTestImage.png(.systemTeal, width: 80, height: 60)
        let eventID = "project:tool:render"
        let completed = event(eventID, image: png)
        state.recordTaskEvent(completed)
        let key = ProjectActivityImageKey(taskID: taskID, eventID: eventID)
        XCTAssertEqual(state.activityImages.images[key]?.png, png)
        XCTAssertNil(state.taskAudits.first?.events.first?.imageData)
        let encodedEvent = try JSONEncoder().encode(completed)
        XCTAssertFalse(String(decoding: encodedEvent, as: UTF8.self).contains("imageData"))
        XCTAssertNil(try JSONDecoder().decode(ProjectActivityEvent.self, from: encodedEvent).imageData)
        state.cancel()
        await state.prepareToQuit()
        let url = try XCTUnwrap(state.projectURL)
        let bytes = try Data(contentsOf: url)
        let manifest = try ProjectZIP.decode(bytes)
        let manifestText = String(decoding: manifest, as: UTF8.self)
        XCTAssertFalse(manifestText.contains("imageData"))
        XCTAssertFalse(manifestText.contains(png.base64EncodedString()), "Derived screenshots must never become archive assets.")
        let saved = try ProjectStore.read(from: url)
        XCTAssertEqual(saved.taskAudits, state.taskAudits)
        XCTAssertTrue(saved.taskAudits?.flatMap(\.events).allSatisfy { $0.imageData == nil } == true)

        let reopened = fixture.state("reopened")
        reopened.activityImages.store(png, for: key)
        XCTAssertEqual(reopened.activityImages.images[key]?.png, png)
        reopened.loadProject(saved, from: url)
        XCTAssertTrue(reopened.activityImages.images.isEmpty, "Loading an archive must discard any previous design's session images.")
        XCTAssertEqual(reopened.taskAudits, saved.taskAudits)
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
        XCTAssertEqual(state.activityImages.images[ProjectActivityImageKey(taskID: oldTaskID, eventID: oldID)]?.png, png)
        state.newProject()
        XCTAssertTrue(state.activityImages.images.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)
        state.recordTaskEvent(event("project:tool:late", image: png))
        XCTAssertTrue(state.activityImages.images.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty)
        await state.prepareToQuit()
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
