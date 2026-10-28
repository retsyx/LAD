import Foundation
import Darwin

enum EngineExportError: LocalizedError {
    case nativeArtifactUnavailable

    var errorDescription: String? {
        "The native geometry is unavailable. Rebuild the design and try again."
    }
}

/// A separate process keeps the UI responsive and contains native-kernel failures.
/// Generated CAD programs run under a restricted macOS sandbox.
@MainActor
final class EngineService {
    private var job: EngineProcessJob?
    private var generation = UUID()
    private var nativeArtifacts: Set<String> = []
    private var stepArtifacts: Set<String> = []
    private var exportedSTEP: [String: Data] = [:]

    static var defaultPython: String {
        let configured = ResourcePaths.root.appendingPathComponent("python-runtime.txt")
        if let path = try? String(contentsOf: configured, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           FileManager.default.isExecutableFile(atPath: path) { return path }
        let local = ResourcePaths.root.appendingPathComponent(".venv/bin/python").path
        return FileManager.default.isExecutableFile(atPath: local) ? local : "/opt/homebrew/bin/python3.11"
    }

    func build(_ spec: ModelSpec, python: String, threads: Int) async throws -> PreviewMesh {
        try await buildModel(spec, python: python, threads: threads, deferSTEP: false)
    }

    /// Prepare display data without serializing STEP. A private native solid
    /// lets a later export avoid executing the model a second time.
    func buildPreview(_ spec: ModelSpec, python: String, threads: Int) async throws -> PreviewMesh {
        try await buildModel(spec, python: python, threads: threads, deferSTEP: true)
    }

    private func buildModel(_ spec: ModelSpec, python: String, threads: Int, deferSTEP: Bool) async throws -> PreviewMesh {
        let output = try await run(python: python, threads: threads, scriptMode: true, deferSTEP: deferSTEP) { folder in
            var definition = spec
            definition.sourceSTEP = nil
            definition.sourceName = nil
            definition.reorganizePartIDs = nil
            definition.inputAssets = nil
            var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as! [String: Any]
            if let source = spec.sourceSTEP {
                try Self.validateSTEP(source)
                try source.write(to: folder.appendingPathComponent("source.step"), options: .atomic)
                payload["sourceAsset"] = "source.step"
            }
            if let assets = spec.inputAssets, !assets.isEmpty {
                guard assets.count <= 256, Set(assets.map(\.id)).count == assets.count else {
                    throw LADError.message("The design contains too many or duplicate imported geometry inputs.")
                }
                var staged: [[String: String]] = []
                for (index, asset) in assets.enumerated() {
                    guard CADInputAsset.supportedFormats.contains(asset.format), !asset.data.isEmpty,
                          asset.data.count <= ProjectStore.maximumSTEPBytes else {
                        throw LADError.message("An imported geometry input is invalid or exceeds 128 MB.")
                    }
                    let name = String(format: "input-%03d.%@", index, asset.format)
                    try asset.data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    staged.append(["id": asset.id, "name": asset.name, "format": asset.format, "path": name])
                }
                payload["inputAssets"] = staged
            }
            try JSONSerialization.data(withJSONObject: payload).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        }
        return try await readPreview(output, deferSTEP: deferSTEP)
    }

    func runtimeInfo(python: String, threads: Int) async throws -> CADRuntime {
        let output = try await run(python: python, threads: threads, scriptMode: false, action: "inspect the CAD runtime") { folder in
            try JSONSerialization.data(withJSONObject: ["operation": "runtime"])
                .write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        }
        defer { try? FileManager.default.removeItem(at: output.folder) }
        let data = try await Task.detached(priority: .userInitiated) {
            try EngineArtifact.read(output.folder.appendingPathComponent("result.json"), in: output.folder, maximumBytes: 65_536)
        }.value
        struct RuntimeResult: Decodable { var runtime: CADRuntime }
        return try JSONDecoder().decode(RuntimeResult.self, from: data).runtime
    }

    /// Prepare display data for an imported STEP source without evaluating a
    /// generated CAD program.
    func previewSTEP(_ stepData: Data, parts: [PartNode]?, python: String, threads: Int) async throws -> PreviewMesh {
        let output = try await run(python: python, threads: threads, scriptMode: false, action: "regenerate this design’s preview") { folder in
            try Self.validateSTEP(stepData)
            try stepData.write(to: folder.appendingPathComponent("preview.step"), options: .atomic)
            var payload: [String: Any] = ["operation": "preview", "stepAsset": "preview.step"]
            if let parts {
                payload["parts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parts))
            }
            try JSONSerialization.data(withJSONObject: payload).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        }
        return try await readPreview(output, deferSTEP: false)
    }

    /// Export an already built native solid, with no program replay or meshing.
    /// Repeated exports of the same session geometry reuse its exact bytes.
    func exportSTEP(_ preview: PreviewMesh, solidIndices: Set<Int>? = nil, python: String, threads: Int) async throws -> Data {
        if let solidIndices {
            guard !solidIndices.isEmpty, solidIndices.allSatisfy({ $0 >= 0 && $0 < preview.solids }) else {
                throw LADError.message("Select at least one available part to export.")
            }
        }
        let selection: [Int]? = solidIndices.flatMap { $0.count == preview.solids ? nil : $0.sorted() }
        // Whole imported/direct exports retain their original exact STEP bytes.
        if selection == nil, stepArtifacts.contains(preview.stepPath) {
            let source = URL(fileURLWithPath: preview.stepPath)
            return try await Task.detached(priority: .userInitiated) {
                let data = try EngineArtifact.read(source, in: source.deletingLastPathComponent(), maximumBytes: ProjectStore.maximumSTEPBytes)
                try Self.validateSTEP(data)
                return data
            }.value
        }
        if let path = preview.brepPath, nativeArtifacts.contains(path) {
            let cacheKey = path + (selection.map { ":solids:" + $0.map(String.init).joined(separator: ",") } ?? "")
            if let cached = exportedSTEP[cacheKey] { return cached }
            let bytes = try await nativeBytes(preview)
            let output = try await run(python: python, threads: threads, scriptMode: false, action: "export this design") { folder in
                try bytes.write(to: folder.appendingPathComponent("source.brep"), options: .atomic)
                var payload: [String: Any] = ["operation": "export", "brepAsset": "source.brep"]
                if let selection { payload["solidIndices"] = selection }
                try JSONSerialization.data(withJSONObject: payload).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
            }
            defer { try? FileManager.default.removeItem(at: output.folder) }
            let data = try await Task.detached(priority: .userInitiated) {
                let data = try EngineArtifact.read(output.folder.appendingPathComponent("model.step"), in: output.folder,
                                                   maximumBytes: ProjectStore.maximumSTEPBytes)
                try Self.validateSTEP(data)
                return data
            }.value
            guard generation == output.token, !Task.isCancelled else { throw CancellationError() }
            exportedSTEP[cacheKey] = data
            return data
        }
        throw EngineExportError.nativeArtifactUnavailable
    }

    /// Exact single-item properties are already available in session metadata.
    /// Only a general two-entity distance needs a native-kernel process.
    func measure(_ preview: PreviewMesh, features: [CADFeatureID], solids: Set<Int>, python: String, threads: Int) async throws -> CADMeasurementReport {
        var report = try CADMeasurements.report(preview, features: features, solids: solids)
        guard report.features.count + report.solidIndices.count == 2,
              !(report.solidIndices.isEmpty && report.features.allSatisfy({ $0.kind == .vertex })) else { return report }
        let bytes = try await nativeBytes(preview)
        let requestedFeatures = report.features, selectedIndices = report.solidIndices
        // Measuring an existing revision must not cancel a concurrent CAD build.
        let measurementWorker = EngineService()
        let output = try await measurementWorker.run(python: python, threads: threads, scriptMode: false, action: "measure these items") { folder in
            try bytes.write(to: folder.appendingPathComponent("source.brep"), options: .atomic)
            let featureData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requestedFeatures))
            let payload: [String: Any] = ["operation": "measure", "brepAsset": "source.brep", "features": featureData,
                                          "solidIndices": selectedIndices]
            try JSONSerialization.data(withJSONObject: payload).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        }
        defer { try? FileManager.default.removeItem(at: output.folder) }
        let exact = try await Task.detached(priority: .userInitiated) {
            let data = try EngineArtifact.read(output.folder.appendingPathComponent("result.json"), in: output.folder, maximumBytes: 1_000_000)
            let report = try JSONDecoder().decode(CADMeasurementReport.self, from: data)
            guard report.metrics.allSatisfy({ !$0.values.isEmpty && $0.values.allSatisfy(\.isFinite) }),
                  report.closestPoints?.count == 2,
                  report.closestPoints?.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) == true else {
                throw LADError.message("The CAD engine returned an invalid measurement.")
            }
            return report
        }.value
        try Task.checkCancellation()
        report.metrics += exact.metrics
        report.closestPoints = exact.closestPoints
        return report
    }

    private func nativeBytes(_ preview: PreviewMesh) async throws -> Data {
        guard let path = preview.brepPath, nativeArtifacts.contains(path) else { throw EngineExportError.nativeArtifactUnavailable }
        let source = URL(fileURLWithPath: path)
        do {
            return try await Task.detached(priority: .userInitiated) {
                let data = try EngineArtifact.read(source, in: source.deletingLastPathComponent(), maximumBytes: ProjectStore.maximumFileBytes)
                guard data.starts(with: Data("DBRep_DrawableShape\n".utf8)) else { throw EngineExportError.nativeArtifactUnavailable }
                return data
            }.value
        } catch { throw EngineExportError.nativeArtifactUnavailable }
    }

    nonisolated private static func validateSTEP(_ data: Data) throws {
        guard !data.isEmpty, data.count <= ProjectStore.maximumSTEPBytes,
              String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ISO-10303-21;"),
              String(decoding: data.suffix(512), as: UTF8.self).contains("END-ISO-10303-21;") else {
            throw LADError.message("The STEP design is invalid or exceeds 128 MB.")
        }
    }

    private struct RunResult: Sendable { var folder: URL; var token: UUID }

    private func run(python: String, threads: Int, scriptMode: Bool, deferSTEP: Bool = false,
                     action: String = "build this design",
                     prepare: @escaping @Sendable (URL) throws -> Void) async throws -> RunResult {
        cancel()
        let token = UUID()
        generation = token
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-build-\(token.uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // realpath must run after creation: nonexistent /var/folders children
        // otherwise keep the /var alias, which Seatbelt compares as /private/var.
        let folder = try EngineArtifact.canonicalDirectory(scratch)
        let request = folder.appendingPathComponent("request.json")
        try await Task.detached(priority: .userInitiated) { try prepare(folder) }.value
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        let worker = ResourcePaths.root.appendingPathComponent("Engine/worker.py").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw LADError.message("CAD engine missing. Run LAD from its source folder, or rebuild the app with Scripts/build-app.sh.")
        }
        let runtime = URL(fileURLWithPath: (python as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw LADError.message("Python runtime not found. Run Scripts/setup.sh, then choose .venv/bin/python in Settings.")
        }
        let arguments = [worker.path, "--request", request.path, "--output", folder.path, "--threads", String(max(1, min(256, threads)))] + (deferSTEP ? ["--defer-step"] : [])
        let actualRuntime = runtime.resolvingSymlinksInPath()
        // Homebrew/framework bin/python is a launcher that spawns Python.app.
        // Start the interpreter directly so generated code can never fork.
        let frameworkInterpreter = actualRuntime.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
        let interpreter = FileManager.default.isExecutableFile(atPath: frameworkInterpreter.path) ? frameworkInterpreter : actualRuntime
        let executable: URL
        let launchArguments: [String]
        if scriptMode {
            executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            let profile = worker.deletingLastPathComponent().appendingPathComponent("script.sb")
            guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: profile.path) else {
                throw LADError.message("Python CAD designs require the macOS execution sandbox. The sandbox tool or bundled Engine/script.sb is missing; rebuild LAD with Scripts/build-app.sh.")
            }
            let parameters = [
                ("RUNTIME", runtime.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path),
                ("PYTHON_BASE", actualRuntime.deletingLastPathComponent().deletingLastPathComponent().path),
                ("WORKER", worker.deletingLastPathComponent().path),
                ("OUTPUT", folder.path),
                ("PYTHON", interpreter.path), ("ENTRY_PYTHON", runtime.path)
            ]
            launchArguments = parameters.flatMap { ["-D", "\($0.0)=\($0.1)"] } + ["-f", profile.path, interpreter.path] + arguments
        } else {
            executable = runtime
            launchArguments = arguments
        }
        // An allowlist avoids passing ambient credentials or model-service keys
        // to generated Python. Runtime/cache locations are explicit and local.
        let temporary = folder.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var environment = [
            "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PYTHONUNBUFFERED": "1", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "MPLCONFIGDIR": folder.appendingPathComponent(".matplotlib").path,
            "XDG_CACHE_HOME": folder.appendingPathComponent(".cache").path,
            "TMPDIR": temporary.path, "LAD_MODEL_OUTPUT": folder.path
        ]
        if interpreter != actualRuntime { environment["__PYVENV_LAUNCHER__"] = runtime.path }
        let task = EngineProcessJob(executable: executable, arguments: launchArguments, directory: folder, environment: environment)
        job = task
        let status = try await withTaskCancellationHandler {
            try await task.run()
        } onCancel: {
            task.cancel()
        }
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        job = nil
        guard status == 0 else {
            let logData = try? EngineArtifact.tail(folder.appendingPathComponent("stderr.log"), in: folder, maximumBytes: 65_536)
            let log = logData.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if log.contains("No module named") {
                throw LADError.message("The CAD runtime is missing dependencies. Run Scripts/setup.sh.\n\n\(log.suffix(1_200))")
            }
            if scriptMode, log.contains("sandbox_apply") || log.contains("sandbox-exec:") {
                throw LADError.message("The macOS sandbox could not start the Python CAD design. Run the packaged LAD app outside an enclosing sandbox and check the selected Python runtime.\n\n\(log.suffix(1_200))")
            }
            throw LADError.message("The CAD engine could not \(action).\n\n\(log.suffix(3_000))")
        }
        return RunResult(folder: folder, token: token)
    }

    private func readPreview(_ output: RunResult, deferSTEP: Bool) async throws -> PreviewMesh {
        let folder = output.folder
        let resultURL = folder.appendingPathComponent("result.json")
        let mesh = try await Task.detached(priority: .userInitiated) {
            let data = try EngineArtifact.read(resultURL, in: folder, maximumBytes: ProjectStore.maximumFileBytes)
            let result = try JSONDecoder().decode(PreviewMesh.self, from: data)
            guard result.normals != nil else {
                throw LADError.message("The CAD engine returned an incomplete design preview.")
            }
            try ProjectStore.validatePreview(result)
            try CADMeasurements.validateTopology(result)
            // Generated code cannot redirect the app to read an unrelated file.
            guard URL(fileURLWithPath: result.stepPath).path == folder.appendingPathComponent("model.step").path else {
                throw LADError.message("CAD engine returned an unexpected STEP asset path.")
            }
            if let path = result.brepPath {
                guard path == folder.appendingPathComponent("model.brep").path else {
                    throw LADError.message("CAD engine returned an unexpected native solid path.")
                }
                let brep = try EngineArtifact.read(folder.appendingPathComponent("model.brep"), in: folder,
                                                   maximumBytes: ProjectStore.maximumFileBytes)
                guard brep.starts(with: Data("DBRep_DrawableShape\n".utf8)) else {
                    throw LADError.message("CAD engine did not return native solid geometry.")
                }
            }
            if deferSTEP {
                guard result.brepPath == folder.appendingPathComponent("model.brep").path else {
                    throw LADError.message("CAD engine returned an unexpected native solid path.")
                }
                guard !FileManager.default.fileExists(atPath: result.stepPath) else {
                    throw LADError.message("CAD engine unexpectedly exported STEP while preparing a preview.")
                }
            } else {
                let step = try EngineArtifact.read(folder.appendingPathComponent("model.step"), in: folder, maximumBytes: ProjectStore.maximumSTEPBytes)
                try Self.validateSTEP(step)
            }
            return result
        }.value
        guard output.token == generation, !Task.isCancelled else { throw CancellationError() }
        if let path = mesh.brepPath { nativeArtifacts.insert(path) }
        if !deferSTEP { stepArtifacts.insert(mesh.stepPath) }
        return mesh
    }

    func cancel() {
        generation = UUID()
        job?.cancel()
        job = nil
    }
}

/// Generated Python can write only the scratch directory, but an output could
/// still be a symlink or hardlink. Never follow either into the user's files.
enum EngineArtifact {
    static func canonicalDirectory(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(url.path, &buffer) != nil else { throw LADError.message("The CAD build directory could not be resolved.") }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    static func read(_ url: URL, in folder: URL, maximumBytes: Int) throws -> Data {
        let (file, size) = try openRegular(url, in: folder)
        defer { try? file.close() }
        guard size > 0, size <= maximumBytes else { throw LADError.message("CAD engine design asset exceeds its size limit or is empty.") }
        var data = Data()
        while let chunk = try file.read(upToCount: min(1_048_576, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw LADError.message("CAD engine design asset exceeds its size limit.") }
        }
        return data
    }

    static func tail(_ url: URL, in folder: URL, maximumBytes: Int) throws -> Data {
        let (file, size) = try openRegular(url, in: folder)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(max(0, size - Int64(maximumBytes))))
        return try file.read(upToCount: maximumBytes) ?? Data()
    }

    private static func openRegular(_ url: URL, in folder: URL) throws -> (FileHandle, Int64) {
        guard url.deletingLastPathComponent().path == folder.path,
              try canonicalDirectory(url.deletingLastPathComponent()).path == folder.path else {
            throw LADError.message("CAD engine returned an unsafe design asset path.")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LADError.message("CAD engine design asset is missing or is a symbolic link.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= 256 * 1024 * 1024 else {
            try? file.close()
            throw LADError.message("CAD engine design asset must be a regular file with one link and a supported size.")
        }
        return (file, info.st_size)
    }
}

/// Owns process lifecycle away from the main actor, including launch races,
/// deadline enforcement and a hard-kill fallback for native geometry calls.
private final class EngineProcessJob: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var launched = false
    private var timedOut = false
    private let directory: URL

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) {
        self.directory = directory
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
    }

    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let log = directory.appendingPathComponent("stderr.log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                do {
                    let stderr = try FileHandle(forWritingTo: log)
                    defer { try? stderr.close() }
                    process.standardError = stderr
                    lock.lock()
                    if cancelled {
                        finished = true; lock.unlock()
                        continuation.resume(throwing: CancellationError()); return
                    }
                    do { try process.run(); launched = true; lock.unlock() }
                    catch { finished = true; lock.unlock(); throw error }
                    let deadline = Date().addingTimeInterval(600)
                    while process.isRunning {
                        if Date() >= deadline {
                            lock.lock(); timedOut = true; lock.unlock()
                            cancel()
                        }
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                    process.waitUntilExit()
                    lock.lock()
                    finished = true
                    let didCancel = cancelled, didTimeOut = timedOut
                    lock.unlock()
                    if didTimeOut { throw LADError.message("The CAD engine exceeded its 10-minute limit. Simplify the design and try again.") }
                    if didCancel { throw CancellationError() }
                    continuation.resume(returning: process.terminationStatus)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = launched && !finished && process.isRunning
        let pid = running ? process.processIdentifier : 0
        if running { process.terminate() }
        lock.unlock()
        if pid > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                if !finished && process.isRunning { Darwin.kill(pid, SIGKILL) }
                lock.unlock()
            }
        }
    }
}
