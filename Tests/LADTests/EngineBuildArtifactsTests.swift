import Darwin
import Foundation
import XCTest
@testable import LAD

final class EngineBuildArtifactsTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-artifact-owner-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func preview(artifacts: EngineBuildArtifacts) -> PreviewMesh {
        var preview = PreviewMesh(vertices: [], triangles: [], edges: [], bounds: [0, 0, 0, 1, 1, 1],
            volume: 1, area: 6, solids: 1, faces: 6, buildSeconds: 0, threads: 1,
            stepPath: artifacts.folder.appendingPathComponent("model.step").path,
            brepPath: artifacts.folder.appendingPathComponent("model.brep").path)
        preview.buildArtifacts = artifacts
        return preview
    }

    private func waitForRemoval(_ folder: URL) async throws {
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: folder.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("CAD scratch files remained after their last session owner was released: \(folder.path)")
    }

    func testPreviewCopiesRetainArtifactsAndCodableDoesNotGrantOwnership() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var owner: EngineBuildArtifacts? = try .create(in: root, token: UUID(), containsSTEP: false)
        let folder = try XCTUnwrap(owner?.folder)
        var first: PreviewMesh? = preview(artifacts: try XCTUnwrap(owner))
        var second = first
        let data = try JSONEncoder().encode(try XCTUnwrap(first))
        let decoded = try JSONDecoder().decode(PreviewMesh.self, from: data)
        XCTAssertNil(decoded.buildArtifacts)
        owner = nil
        first = nil
        XCTAssertNotNil(second?.buildArtifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(EngineBuildArtifacts.removeAbandoned(in: root), 0)
        second = nil
        try await waitForRemoval(folder)
        XCTAssertEqual(decoded.brepPath, folder.appendingPathComponent("model.brep").path)
    }

    func testWorkerInheritedLeasePreventsCleanupAfterHostOwnerIsReleased() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var owner: EngineBuildArtifacts? = try .create(in: root, token: UUID(), containsSTEP: false)
        let folder = try XCTUnwrap(owner?.folder)
        let input = try XCTUnwrap(owner).workerInput()
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/bin/sleep")
        worker.arguments = ["30"]
        worker.standardInput = input
        try worker.run()
        defer { if worker.isRunning { worker.terminate(); worker.waitUntilExit() } }
        try input.close()
        owner = nil
        XCTAssertEqual(EngineBuildArtifacts.removeAbandoned(in: root), 0,
                       "A worker that outlives LAD still owns its build directory.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        worker.terminate()
        worker.waitUntilExit()
        _ = EngineBuildArtifacts.removeAbandoned(in: root)
        try await waitForRemoval(folder)
    }

    func testUnmarkedAndSymlinkedDirectoriesArePreserved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("LAD-build-\(UUID())")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let external = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("LAD-build-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertEqual(EngineBuildArtifacts.removeAbandoned(in: root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    @MainActor
    func testPreparationAndRuntimeFailuresReleasePartiallyWrittenBuilds() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineService(temporaryDirectory: root)
        let source = Data("ISO-10303-21;\nEND-ISO-10303-21;\n".utf8)
        let spec = ModelSpec(title: "Failure", summary: "Partially staged input", units: "mm", script: "result = None",
            sourceSTEP: source, inputAssets: [CADInputAsset(id: "invalid", name: "input.obj", format: "obj", data: Data())])
        do {
            _ = try await engine.buildPreview(spec, python: "/missing/python", threads: 1)
            XCTFail("The invalid input must fail during staging.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("imported geometry input")) }
        do {
            _ = try await engine.runtimeInfo(python: "/usr/bin/false", threads: 1)
            XCTFail("The worker must fail before returning runtime metadata.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not inspect")) }
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try await waitForRemoval(folder)
        }
    }

    @MainActor
    func testCancellationBeforeLaunchReleasesScratchDirectory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineService(temporaryDirectory: root)
        let task = Task { try await engine.buildPreview(.bracket, python: "/missing/python", threads: 1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("The canceled build must not launch.") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try await waitForRemoval(folder)
        }
    }

    @MainActor
    func testNativePreviewSurvivesServiceReleaseUntilItsLastCopyIsDiscarded() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to verify native artifact lifetime.")
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine: EngineService? = EngineService(temporaryDirectory: root)
        var first: PreviewMesh? = try await engine!.buildPreview(.bracket, python: EngineService.defaultPython, threads: 2)
        let folder = try XCTUnwrap(first?.buildArtifacts?.folder)
        var second = first
        engine = nil
        first = nil
        // A validated preview carries its own trusted native ownership, even
        // when another service exports it after the producing service closes.
        let exported = try await EngineService(temporaryDirectory: root).exportSTEP(
            try XCTUnwrap(second), python: EngineService.defaultPython, threads: 2)
        XCTAssertTrue(exported.starts(with: Data("ISO-10303-21;".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        second = nil
        try await waitForRemoval(folder)
        for remaining in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try await waitForRemoval(remaining)
        }
    }

    @MainActor
    func testNativeCancellationStopsWorkerBeforeRemovingItsDirectory() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to verify native worker cancellation.")
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineService(temporaryDirectory: root)
        let spec = ModelSpec(title: "Cancellation", summary: "Wait until explicitly canceled", units: "mm", script: """
        from pathlib import Path
        import os, time
        Path(os.environ['LAD_MODEL_OUTPUT']).joinpath('started').write_text('ready')
        time.sleep(30)
        result = cq.Solid.makeBox(1, 1, 1)
        """)
        let task = Task { try await engine.buildPreview(spec, python: EngineService.defaultPython, threads: 2) }
        var runningFolder: URL?
        for _ in 0..<150 {
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            if let folder = folders.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("started").path) }) {
                runningFolder = folder
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("The running worker must be canceled.") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let folder = try XCTUnwrap(runningFolder, "The worker must have entered its generated program before cancellation.")
        try await waitForRemoval(folder)
    }
}
