import Foundation
import XCTest
@testable import LAD

final class AppStateRequestRevisionTests: XCTestCase {
    @MainActor
    func testRequestsRecordTheVersionShownAtSubmissionThroughQueueDispatchAndSave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let (first, second) = try installRevisions(in: state)
        state.selectRevision(first.id)
        state.isWorking = true
        state.prompt = "Add a fillet to the base"
        state.submit()
        let queued = try XCTUnwrap(state.queuedRequests.first)
        XCTAssertNil(queued.selection)
        XCTAssertEqual(queued.originRevisionID, first.id)

        state.cancel()
        state.selectedRevisionID = second.id
        state.resumeQueue()
        let message = try XCTUnwrap(state.messages.first(where: { $0.role == "user" }))
        XCTAssertEqual(message.originRevisionID, first.id,
                       "A queued request belongs to the version shown when it was submitted, not the one current at dispatch.")
        XCTAssertEqual(message.requestRevisionID, first.id)
        state.cancel()
        await state.prepareToQuit()
        let saved = try ProjectStore.read(from: XCTUnwrap(state.projectURL))
        XCTAssertEqual(saved.messages.first(where: { $0.id == message.id })?.originRevisionID, first.id)
    }

    @MainActor
    func testShowingARequestSelectsItsVersionAndRestoresItsSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let (first, second) = try installRevisions(in: state)
        let selection = ProjectSelectionContext(revisionID: first.id,
            parts: [ProjectSelectedPart(partID: "lid", name: "Lid", path: ["Case", "Lid"], solidIndex: 1)],
            features: [feature(id(.face, solid: 0), partID: "base", type: "PLANE"),
                       feature(id(.vertex, solid: 0), partID: "base", type: "vertex")])
        let request = ChatMessage(role: "user", content: "Change these", selection: selection, originRevisionID: first.id)
        let plain = ChatMessage(role: "user", content: "Add a part", originRevisionID: first.id)
        state.messages = [request, plain]
        XCTAssertEqual(state.selectedRevisionID, second.id)

        state.showRequestRevision(messageID: request.id)
        XCTAssertEqual(state.selectedRevisionID, first.id, "The version menu shows the request's version.")
        XCTAssertEqual(state.selectedSolids, [1])
        XCTAssertEqual(state.selectedFeatures, [id(.face, solid: 0), id(.vertex, solid: 0)])
        XCTAssertEqual(state.conversationFocus?.messageID, request.id)
        XCTAssertEqual(state.conversationFocus?.reveals, false,
                       "The pressed request stays in place rather than scrolling the conversation.")

        state.showRequestRevision(messageID: plain.id)
        XCTAssertEqual(state.selectedRevisionID, first.id)
        XCTAssertTrue(state.selectedSolids.isEmpty, "A request made without a selection shows none.")
        XCTAssertTrue(state.selectedFeatures.isEmpty)
        state.cancel()
        await state.prepareToQuit()
    }

    @MainActor
    func testRestoredSelectionFollowsStablePartIdentitiesAndDropsMismatchedFeatures() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        // A replay enumerated the named solids in the other order.
        let (first, _) = try installRevisions(in: state, firstOwners: (base: 1, lid: 0))
        let selection = ProjectSelectionContext(revisionID: first.id,
            parts: [ProjectSelectedPart(partID: "base", name: "Base", path: ["Case", "Base"], solidIndex: 0)],
            features: [feature(id(.face, solid: 0), partID: "base", type: "PLANE"),
                       feature(id(.edge, solid: 0), partID: "base", type: "CIRCLE")])
        let request = ChatMessage(role: "user", content: "Change the base", selection: selection, originRevisionID: first.id)
        state.messages = [request]
        state.showRequestRevision(messageID: request.id)
        XCTAssertEqual(state.selectedSolids, [1])
        XCTAssertEqual(state.selectedFeatures, [id(.face, solid: 1)],
                       "A feature whose captured type differs from the loaded topology is not shown.")
        state.cancel()
        await state.prepareToQuit()
    }

    @MainActor
    func testPrintingVersionSelectionShowsThePrintingVersionView() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let (first, _) = try installRevisions(in: state)
        let selection = ProjectSelectionContext(revisionID: first.id, parts: [],
            features: [feature(id(.edge, solid: 1), partID: "lid", type: "LINE")], printVersion: true)
        let request = ChatMessage(role: "user", content: "Change this edge", selection: selection, originRevisionID: first.id)
        state.messages = [request]
        XCTAssertFalse(state.printVersionView)
        state.showRequestRevision(messageID: request.id)
        XCTAssertTrue(state.printVersionView)
        XCTAssertEqual(state.selectedFeatures, [id(.edge, solid: 1)])
        state.cancel()
        await state.prepareToQuit()
    }

    @MainActor
    func testVersionMenuRevealsTheRequestThatProducedTheVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = fixture.state()
        let request = ChatMessage(role: "user", content: "Make it taller")
        let response = ChatMessage(role: "assistant", content: "Done", phase: "final_answer")
        state.messages = [request, response]
        let (first, second) = try installRevisions(in: state, firstMessages: (request.id, response.id))
        XCTAssertEqual(state.selectedRevisionID, second.id)
        state.selectRevisionRevealingRequest(first.id)
        XCTAssertEqual(state.selectedRevisionID, first.id)
        XCTAssertEqual(state.conversationFocus?.messageID, request.id)
        XCTAssertEqual(state.conversationFocus?.reveals, true)
        let focus = state.conversationFocus

        state.selectRevisionRevealingRequest(second.id)
        XCTAssertEqual(state.selectedRevisionID, second.id)
        XCTAssertEqual(state.conversationFocus, focus, "A version without a producing request leaves the conversation alone.")
        state.cancel()
        await state.prepareToQuit()
    }

    func testValidationRejectsInconsistentRequestVersions() throws {
        let revision = ProjectRevision(model: .bracket)
        let selection = ProjectSelectionContext(revisionID: revision.id,
            parts: [ProjectSelectedPart(partID: "base", name: "Base", path: ["Base"], solidIndex: 0)], features: [])
        let valid = ChatMessage(role: "user", content: "Change it", selection: selection, originRevisionID: revision.id)
        XCTAssertNoThrow(try ProjectStore.validate(LADProject(messages: [valid], revisions: [revision])))

        var otherVersion = valid
        otherVersion.originRevisionID = UUID()
        XCTAssertThrowsError(try ProjectStore.validate(LADProject(messages: [otherVersion], revisions: [revision])))
        let assistant = ChatMessage(role: "assistant", content: "Done", originRevisionID: revision.id)
        XCTAssertThrowsError(try ProjectStore.validate(LADProject(messages: [assistant], revisions: [revision])))
        var queued = LADProject(messages: [], revisions: [revision])
        queued.queuedRequests = [ProjectQueuedRequest(content: "Later", selection: selection, originRevisionID: UUID())]
        XCTAssertThrowsError(try ProjectStore.validate(queued))
    }

    // MARK: - Fixtures

    /// Two versions with session previews, so selecting either displays it
    /// without a CAD worker. The second is selected.
    @MainActor
    private func installRevisions(in state: AppState, firstOwners: (base: Int, lid: Int) = (0, 1),
                                  firstMessages: (user: UUID, response: UUID)? = nil) throws
        -> (ProjectRevision, ProjectRevision) {
        var first = ProjectRevision(model: .bracket, preview: try preview(owners: firstOwners),
                                    parts: parts(owners: firstOwners))
        first.userMessageID = firstMessages?.user
        first.responseMessageID = firstMessages?.response
        let second = ProjectRevision(model: .bracket, preview: try preview(owners: (0, 1)), parts: parts(owners: (0, 1)))
        state.revisions = [first, second]
        state.selectedRevisionID = second.id
        state.mesh = second.preview
        return (first, second)
    }

    private func parts(owners: (base: Int, lid: Int)) -> [PartNode] {
        [PartNode(id: "case", name: "Case", solidIndices: [], children: [
            PartNode(id: "base", name: "Base", solidIndices: [owners.base]),
            PartNode(id: "lid", name: "Lid", solidIndices: [owners.lid])
        ])]
    }

    private func preview(owners: (base: Int, lid: Int)) throws -> PreviewMesh {
        let topology = CADTopology(
            vertices: [CADVertex(id: id(.vertex, solid: 0), position: [0, 0, 0]),
                       CADVertex(id: id(.vertex, solid: 1), position: [10, 0, 0])],
            edges: [CADEdge(id: id(.edge, solid: 0), type: "LINE", length: 4,
                            polyline: [[0, 0, 0], [4, 0, 0]], direction: [1, 0, 0],
                            startPoint: [0, 0, 0], endPoint: [4, 0, 0]),
                    CADEdge(id: id(.edge, solid: 1), type: "LINE", length: 4,
                            polyline: [[10, 0, 0], [14, 0, 0]], direction: [1, 0, 0],
                            startPoint: [10, 0, 0], endPoint: [14, 0, 0])],
            faces: [CADFace(id: id(.face, solid: 0), type: "PLANE", area: 8,
                            center: [4.0 / 3, 4.0 / 3, 0], normal: [0, 0, 1]),
                    CADFace(id: id(.face, solid: 1), type: "PLANE", area: 8,
                            center: [10 + 4.0 / 3, 4.0 / 3, 0], normal: [0, 0, 1])],
            parts: [CADPart(solidIndex: 0, area: 48, volume: 16, bounds: [0, 0, 0, 4, 4, 1], centroid: [2, 2, 0.5]),
                    CADPart(solidIndex: 1, area: 48, volume: 16, bounds: [10, 0, 0, 14, 4, 1], centroid: [12, 2, 0.5])])
        let preview = PreviewMesh(vertices: [[0.0, 0, 0], [4, 0, 0], [0, 4, 0], [10, 0, 0], [14, 0, 0], [10, 4, 0]],
            triangles: [[0, 1, 2], [3, 4, 5]],
            edges: [[0, 0, 0, 4, 0, 0], [10, 0, 0, 14, 0, 0]], bounds: [0, 0, 0, 14, 4, 1],
            volume: 32, area: 96, solids: 2, faces: 2, buildSeconds: 0, threads: 1,
            stepPath: "/session/request-version-\(UUID().uuidString).step", triangleSolids: [0, 1], edgeSolids: [0, 1],
            parts: parts(owners: owners), topology: topology, triangleFaces: [0, 1], edgeFeatures: [0, 1])
        try CADMeasurements.validateTopology(preview)
        return preview
    }

    private func feature(_ id: CADFeatureID, partID: String, type: String) -> ProjectSelectedFeature {
        let name = partID == "base" ? "Base" : "Lid"
        return ProjectSelectedFeature(id: id, partID: partID, partName: name, partPath: ["Case", name],
                                      anchor: ProjectSelectionAnchor(geometryType: type))
    }

    private func id(_ kind: CADFeatureKind, solid: Int) -> CADFeatureID {
        CADFeatureID(kind: kind, solidIndex: solid, localIndex: 0)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        private let originalCodex: Any?

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-request-version-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            originalCodex = UserDefaults.standard.object(forKey: "codexPath")
            UserDefaults.standard.set(directory.appendingPathComponent("missing-codex").path, forKey: "codexPath")
        }

        func state() -> AppState {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("Design")))
            state.newProject()
            return state
        }

        func cleanUp() {
            if let originalCodex { UserDefaults.standard.set(originalCodex, forKey: "codexPath") }
            else { UserDefaults.standard.removeObject(forKey: "codexPath") }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
