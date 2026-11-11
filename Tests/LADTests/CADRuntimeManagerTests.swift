import CryptoKit
import Foundation
import XCTest
@testable import LAD

@_silgen_name("flock")
private func lockTestFile(_ descriptor: Int32, _ operation: Int32) -> Int32

final class CADRuntimeManagerTests: XCTestCase {
    func testManifestRejectsTraversalAndIncompatibleArchitecture() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (identifier, architecture) in [("../outside", CADRuntimePayload.hostArchitecture),
                                            ("..", CADRuntimePayload.hostArchitecture), ("valid", "unsupported")] {
            try writeManifest(in: folder, identifier: identifier, architecture: architecture)
            XCTAssertThrowsError(try CADRuntimePayload.load(from: folder))
        }
        try writeManifest(in: folder)
        XCTAssertEqual(try CADRuntimePayload.load(from: folder).identifier, "test-runtime")
    }

    func testIntegrityFailureNeverPublishesAnInstallation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeManifest(in: folder)
        try Data("invalid archive".utf8).write(to: folder.appendingPathComponent("payload.tar.gz"))
        let root = folder.appendingPathComponent("Runtimes")
        let stale = root.appendingPathComponent(".install-\(UUID())")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("interrupted extraction".utf8).write(to: stale.appendingPathComponent("partial-runtime"))
        let unrelated = root.appendingPathComponent(".install-user-data")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        XCTAssertThrowsError(try CADRuntimeInstaller.install(payloadDirectory: folder, installationRoot: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("integrity check"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("test-runtime").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [".install-user-data", ".install.lock"])
    }

    @MainActor
    func testPreparationFailureIsObservableAndCanBeRetried() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = CADRuntimeManager(payloadDirectory: folder, installationRoot: folder.appendingPathComponent("Runtimes"))
        XCTAssertEqual(manager.phase, .idle)
        for _ in 0..<2 {
            do {
                _ = try await manager.ensureReady()
                XCTFail("A missing payload must fail closed")
            } catch {
                guard case .failed(let message) = manager.phase else { return XCTFail("Failure must be visible") }
                XCTAssertTrue(message.contains("bundled CAD runtime"))
            }
        }
    }

    @MainActor
    func testCanceledConsumerDoesNotBeginPreparationOrValidateAnOverride() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = CADRuntimeManager(payloadDirectory: folder, installationRoot: folder.appendingPathComponent("Runtimes"))
        let preparation = Task { try await manager.ensureReady() }
        preparation.cancel()
        do { _ = try await preparation.value; XCTFail("A canceled consumer must not prepare a runtime") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        let resolution = Task { try await CADRuntimeManager.resolvePython("/missing/python") }
        resolution.cancel()
        do { _ = try await resolution.value; XCTFail("Cancellation must precede override validation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testOfflineInstallationCoalescesAndSurvivesPayloadRemoval() async throws {
        let payload = CADRuntimeManager.bundledPayloadDirectory
        guard FileManager.default.fileExists(atPath: payload.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Run Scripts/setup.sh to prepare the standalone CAD payload")
        }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copiedPayload = folder.appendingPathComponent("payload with spaces")
        try FileManager.default.createDirectory(at: copiedPayload, withIntermediateDirectories: true)
        for name in ["manifest.json", "payload.tar.gz"] {
            try FileManager.default.copyItem(at: payload.appendingPathComponent(name), to: copiedPayload.appendingPathComponent(name))
        }
        let root = folder.appendingPathComponent("Application Support/Runtimes")
        let manager = CADRuntimeManager(payloadDirectory: copiedPayload, installationRoot: root)
        async let first = manager.ensureReady()
        async let second = manager.ensureReady()
        let paths = try await [first, second]
        XCTAssertEqual(paths[0], paths[1])
        XCTAssertEqual(manager.phase, .ready)
        let python = URL(fileURLWithPath: paths[0])
        let installed = python.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytecodeMarker = installed.appendingPathComponent(".bytecode-ready")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bytecodeMarker.path))
        let caches = installed.appendingPathComponent("python/lib/python3.11/site-packages/cadquery/__pycache__")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: caches.path).contains { $0.hasPrefix("__init__.") && $0.hasSuffix(".pyc") })
        let config = try String(contentsOf: installed.appendingPathComponent("venv/pyvenv.cfg"))
        XCTAssertTrue(config.contains(installed.appendingPathComponent("python/bin").path))
        XCTAssertFalse(config.contains(".install-"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".install-") }, [])
        // A new process/manager must reuse a complete installation without its
        // archive, network, source checkout interpreter or environment setup.
        try FileManager.default.removeItem(at: copiedPayload.appendingPathComponent("payload.tar.gz"))
        // Existing installations lacking the warmup marker are upgraded offline.
        try FileManager.default.removeItem(at: bytecodeMarker)
        let reopened = CADRuntimeManager(payloadDirectory: copiedPayload, installationRoot: root)
        let reopenedPath = try await reopened.ensureReady()
        XCTAssertEqual(reopenedPath, paths[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bytecodeMarker.path))
        let process = Process(), output = Pipe()
        process.executableURL = python
        process.arguments = ["-I", "-B", "-c", """
        import builtins, sys
        original_compile = builtins.compile
        def check_compile(source, filename, *args, **kwargs):
            if filename.endswith('.py'):
                raise AssertionError('Unexpected source compilation: ' + filename)
            return original_compile(source, filename, *args, **kwargs)
        builtins.compile = check_compile
        import cadquery
        print(sys.base_prefix)
        print(cadquery.__file__)
        """]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        for line in text.split(separator: "\n") {
            let resolved = URL(fileURLWithPath: String(line)).resolvingSymlinksInPath().path
            XCTAssertTrue(resolved.hasPrefix(installed.resolvingSymlinksInPath().path), text)
        }
    }

    @MainActor
    func testManagedRuntimeBuildsMeasuresAndExportsInsideNativeSandbox() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 outside an enclosing sandbox to verify the managed runtime")
        }
        let python = try await CADRuntimeManager.shared.ensureReady()
        XCTAssertEqual(python, EngineService.defaultPython)
        XCTAssertTrue(python.hasPrefix(CADRuntimeManager.defaultInstallationRoot.path))
        let engine = EngineService()
        let program = """
        cq.Sketch().segment((0,0),(10,0),tag='line').constrain('line','Fixed',None).solve()
        base = cq.Workplane('XY').box(20,15,6).edges('|Z').fillet(1)
        result = base.faces('>Z').workplane().text('L',3,0.5,combine=True)
        """
        let spec = ModelSpec(title: "Runtime verification", summary: "Fillet, solved sketch and native font construction.", units: "mm", script: program)
        let preview = try await engine.buildPreview(spec, python: python, threads: 2)
        XCTAssertEqual(preview.solids, 1)
        XCTAssertGreaterThan(preview.volume, 1700)
        let feature = try XCTUnwrap(preview.topology?.faces.first)
        let vertex = try XCTUnwrap(preview.topology?.vertices.first)
        let report = try await engine.measure(preview, features: [feature.id, vertex.id], solids: [], python: python, threads: 2)
        XCTAssertFalse(report.metrics.isEmpty)
        XCTAssertNotNil(report.metrics.first { $0.id == "pair:distance" })
        let step = try await engine.exportSTEP(preview, python: python, threads: 2)
        let imported = try await engine.previewSTEP(step, parts: preview.parts, python: python, threads: 2)
        XCTAssertEqual(imported.volume, preview.volume, accuracy: 1e-5)
        let workspace = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tools = try CADAgentTools(directory: workspace, python: python, threads: 2, current: nil, currentPreview: nil, engine: engine)
        let runtime = try await tools.handle(name: "lad_runtime", arguments: [:])
        let content = try XCTUnwrap(runtime["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(metadata["pythonExecutable"] as? String, python)
        let arguments = try CADAgentBridge.codexArguments(workspace: workspace, python: python,
                                                         server: ResourcePaths.root.appendingPathComponent("Engine/agent_server.py"))
        XCTAssertTrue(arguments.contains { $0.hasPrefix("mcp_servers.lad.command=") && $0.contains("venv/bin/python") })
    }

    func testSupersededRuntimesAreReclaimedExceptCurrentPreviousAndInUse() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Runtimes")
        let now = Date()
        for (name, age) in [("current", 0.0), ("previous", 3600.0), ("older", 7200.0), ("held", 10_800.0), ("oldest", 14_400.0)] {
            try fakeRuntime(name, in: root, lastUsed: now.addingTimeInterval(-age))
        }
        let unrelated = root.appendingPathComponent(".install-user-data")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        // Another process using a superseded runtime holds its shared use lock.
        let held = Darwin.open(root.appendingPathComponent("held/.in-use").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(lockTestFile(held, LOCK_SH), 0)
        CADRuntimeInstaller.pruneSuperseded(installationRoot: root, current: "current")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       [".install-user-data", ".install.lock", "current", "held", "previous"])
        Darwin.close(held)
        CADRuntimeInstaller.pruneSuperseded(installationRoot: root, current: "current")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       [".install-user-data", ".install.lock", "current", "previous"])
    }

    func testInstallationRetainsItsRuntimeAndFinishesInterruptedReclaims() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeManifest(in: folder)
        let root = folder.appendingPathComponent("Runtimes")
        let runtime = try fakeRuntime("test-runtime", in: root, lastUsed: Date(timeIntervalSince1970: 0))
        let interrupted = root.appendingPathComponent(".superseded-\(UUID())")
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: false)
        let python = try CADRuntimeInstaller.install(payloadDirectory: folder, installationRoot: root)
        XCTAssertEqual(URL(fileURLWithPath: python).resolvingSymlinksInPath(), runtime.appendingPathComponent("venv/bin/python").resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        let used = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: runtime.appendingPathComponent(".last-used").path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(used, Date().addingTimeInterval(-60))
        let probe = Darwin.open(runtime.appendingPathComponent(".in-use").path, O_RDWR)
        defer { Darwin.close(probe) }
        XCTAssertNotEqual(lockTestFile(probe, LOCK_EX | LOCK_NB), 0, "The installing process must hold its runtime")
        // A newer build keeps its own runtime and a more recently used one;
        // this process's runtime survives because it is still in use.
        try fakeRuntime("newer", in: root, lastUsed: Date())
        try fakeRuntime("recent", in: root, lastUsed: Date().addingTimeInterval(3600))
        CADRuntimeInstaller.pruneSuperseded(installationRoot: root, current: "newer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.path))
    }

    @discardableResult
    private func fakeRuntime(_ name: String, in root: URL, lastUsed: Date) throws -> URL {
        let runtime = root.appendingPathComponent(name)
        let bin = runtime.appendingPathComponent("venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let hash = String(repeating: "0", count: 64)
        for (marker, contents) in [(".ready", hash), (".bytecode-ready", "1:\(hash)")] {
            let url = runtime.appendingPathComponent(marker)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: lastUsed], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: lastUsed], ofItemAtPath: runtime.path)
        return runtime
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-runtime-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func writeManifest(in folder: URL, identifier: String = "test-runtime", architecture: String = CADRuntimePayload.hostArchitecture) throws {
        let payload = CADRuntimePayload(formatVersion: 1, identifier: identifier, architecture: architecture,
                                        pythonVersion: "3.11.18", archive: "payload.tar.gz", sha256: String(repeating: "0", count: 64))
        try JSONEncoder().encode(payload).write(to: folder.appendingPathComponent("manifest.json"))
    }
}
