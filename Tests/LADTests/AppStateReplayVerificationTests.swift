import Foundation
import XCTest
@testable import LAD

/// A saved design whose validation receipt no longer matches displays first and
/// then earns its receipt; one that fails verification is reported, still shown.
final class AppStateReplayVerificationTests: XCTestCase {
    @MainActor
    func testStaleReceiptReplayDisplaysFirstThenRecordsItsReceipt() async throws {
        let (state, directory) = try fixture()
        defer { state.cancel(); try? FileManager.default.removeItem(at: directory) }
        let stale = String(repeating: "0", count: 64)
        let revision = ProjectRevision(model: ModelSpec(title: "Box", summary: "A box.", units: "mm",
                                                        script: "result = cq.Solid.makeBox(2,3,4)"),
                                       validatedHash: stale)
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        try await wait { state.mesh != nil }
        let pending = try XCTUnwrap(state.mesh?.pendingValidationHash, "The design displays before its exact checks.")
        try await wait { state.revisions[0].validatedHash != stale }
        XCTAssertEqual(state.revisions[0].validatedHash, pending)
        XCTAssertEqual(state.revisions[0].preview?.validatedHash, pending)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testFailedReplayVerificationIsReportedWithoutRemovingTheDesign() async throws {
        let (state, directory) = try fixture()
        defer { state.cancel(); try? FileManager.default.removeItem(at: directory) }
        let revision = ProjectRevision(model: ModelSpec(title: "Invalid edge curve", summary: "A curve defect.", units: "mm", script: """
            from OCP.BRep import BRep_Builder, BRep_Tool
            from OCP.gp import gp_Vec2d
            result = cq.Solid.makeBox(2,3,4)
            face = result.Faces()[0]
            edge = face.Edges()[0]
            curve = BRep_Tool.CurveOnSurface_s(edge.wrapped, face.wrapped, 0., 0.)
            BRep_Builder().UpdateEdge(edge.wrapped, curve.Translated(gp_Vec2d(0.001,0)), face.wrapped, 1e-7)
            """))
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        try await wait { state.error != nil }
        XCTAssertTrue(state.error?.contains("BRepCheck_InvalidCurveOnSurface") == true, state.error ?? "")
        XCTAssertNotNil(state.mesh, "A failed verification leaves the displayed design in place.")
        XCTAssertNil(state.revisions[0].validatedHash)
    }

    @MainActor
    private func fixture() throws -> (AppState, URL) {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to verify saved design replays.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-replay-verification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("autosaves"))), directory)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
