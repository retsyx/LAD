import Foundation
import XCTest
@testable import LAD

/// Native-geometry requests share one long-lived worker per engine.
final class EngineNativeWorkerTests: XCTestCase {
    private func requireRuntime() throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 for the long-lived native worker tests.")
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-native-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testMeasurementsAndExportsShareOneWorkerUntilItStops() async throws {
        try requireRuntime()
        let engine = EngineService()
        let spec = ModelSpec(title: "Two boxes", summary: "Separate solids for an exact distance.", units: "mm", script: """
        result = cq.Compound.makeCompound([cq.Solid.makeBox(1, 1, 1), cq.Solid.makeBox(1, 1, 1, pnt=cq.Vector(3, 0, 0))])
        """)
        let python = EngineService.defaultPython
        let preview = try await engine.buildPreview(spec, python: python, threads: 2)
        XCTAssertEqual(preview.solids, 2)
        for _ in 0..<2 {
            let report = try await engine.measure(preview, features: [], solids: [0, 1], python: python, threads: 2)
            let points = try XCTUnwrap(report.closestPoints)
            XCTAssertEqual(points[1][0] - points[0][0], 2, accuracy: 1e-7)
        }
        let step = try await engine.exportSTEP(preview, solidIndices: [1], python: python, threads: 2)
        XCTAssertTrue(String(decoding: step.prefix(64), as: UTF8.self).contains("ISO-10303-21"))
        var launches = await engine.native.launches
        XCTAssertEqual(launches, 1, "Measurements and exports reuse the same worker process.")

        await engine.native.stop()
        _ = try await engine.measure(preview, features: [], solids: [0, 1], python: python, threads: 2)
        launches = await engine.native.launches
        XCTAssertEqual(launches, 2, "A stopped worker restarts for the next request.")
    }

    func testIdleWorkerExitsAndCanceledCallersReturnPromptly() async throws {
        try requireRuntime()
        let python = try await CADRuntimeManager.resolvePython(EngineService.defaultPython)
        let worker = CADNativeWorker(temporaryDirectory: try folder(), idleTimeout: .milliseconds(300))
        func runtimeRequest() throws -> URL {
            let request = try folder()
            try Data(#"{"operation":"runtime"}"#.utf8).write(to: request.appendingPathComponent("request.json"))
            return request
        }
        let first = try runtimeRequest()
        let reply = try await worker.perform(folder: first, threads: 1, python: python)
        XCTAssertEqual(reply.status, "complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("result.json").path))
        var running = await worker.isRunning
        XCTAssertTrue(running)

        let canceled = Task { try await worker.perform(folder: try runtimeRequest(), threads: 1, python: python) }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("A canceled request must not report a result.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await worker.perform(folder: try runtimeRequest(), threads: 1, python: python)
        XCTAssertEqual(next.status, "complete", "A canceled request releases the worker for the next one.")

        try await Task.sleep(for: .seconds(1.5))
        running = await worker.isRunning
        XCTAssertFalse(running, "An idle worker exits.")
        let launches = await worker.launches
        XCTAssertEqual(launches, 1)
    }
}
