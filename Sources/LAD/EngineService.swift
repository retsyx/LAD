import Foundation
import Darwin

enum EngineExportError: LocalizedError {
    case nativeArtifactUnavailable

    var errorDescription: String? {
        "The native geometry is unavailable. Rebuild the design and try again."
    }
}

/// A sandboxed CAD program run that failed: a design build or a mesh
/// reconstruction step. `kind` records why, so callers act on the failure
/// itself rather than on the wording of its message.
struct EngineBuildFailure: LocalizedError {
    enum Kind: Sendable, Equatable {
        /// The worker ran the program and reported that the design failed: a
        /// program error, invalid geometry or failed validation.
        case design
        /// The CAD runtime, its native libraries or its file access failed.
        case runtime
        /// The macOS sandbox could not start the program.
        case sandbox
        /// The program exceeded the engine's time limit.
        case timeout
        /// The engine stopped without reporting why.
        case engine
    }

    let kind: Kind
    /// The user-facing description.
    let message: String
    /// The worker's own report of the failure, when it made one.
    let report: String?

    var errorDescription: String? { message }

    /// Only a design the worker ran and rejected can be fixed by changing its program.
    var isRepairable: Bool { kind == .design }

    init(kind: Kind, message: String, report: String? = nil) {
        self.kind = kind; self.message = message; self.report = report
    }

    /// Classify a worker that exited unsuccessfully while performing `action`.
    init(action: String, sandboxed: Bool, diagnostic: EngineFailureDiagnostic.Diagnostic) {
        let text = diagnostic.text
        if text.contains("No module named") {
            self.init(kind: .runtime, message: "LAD’s CAD runtime is incomplete. Reinstall LAD and try again.\n\n\(text.suffix(1_200))",
                      report: diagnostic.report)
        } else if sandboxed, text.contains("sandbox_apply") || text.contains("sandbox-exec:") {
            self.init(kind: .sandbox, message: "The macOS sandbox could not start this design. Restart LAD outside an enclosing sandbox and try again.\n\n\(text.suffix(1_200))",
                      report: diagnostic.report)
        } else {
            // The worker states whether the design or its runtime failed.
            let kind: Kind = switch diagnostic.kind {
            case "design": .design
            case "runtime": .runtime
            default: .engine
            }
            self.init(kind: kind, message: "The CAD engine could not \(action).\n\n\(text)", report: diagnostic.report)
        }
    }
}

/// Worker failures remain bounded data from the private build directory.
/// A separate report keeps native validation details clear of stderr noise.
enum EngineFailureDiagnostic {
    struct Diagnostic: Sendable {
        /// The bounded failure text shown to the user.
        var text: String
        /// The worker's own report, when it made one.
        var report: String?
        /// The worker's classification of a reported failure: "design" or "runtime".
        var kind: String?
    }

    private struct Report: Decodable {
        var formatVersion: Int
        var message: String
        var failureKind: String?
    }

    private static let marker = "LAD CAD engine:"

    static func read(in folder: URL, stderr: String) -> Diagnostic {
        if let data = try? EngineArtifact.read(folder.appendingPathComponent("error.json"), in: folder,
                                               maximumBytes: 65_536),
           let report = try? JSONDecoder().decode(Report.self, from: data),
           report.formatVersion == 1, report.message.utf8.count <= 48_000,
           !report.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Diagnostic(text: "\(marker) \(report.message)",
                              report: report.message.trimmingCharacters(in: .whitespacesAndNewlines), kind: report.failureKind)
        }
        // Without a report file, the worker's last words on stderr are its report.
        let text = String(stderr.suffix(3_000))
        let report = text.range(of: marker, options: .backwards).map {
            String(text[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Diagnostic(text: text, report: report)
    }

    static func message(in folder: URL, stderr: String) -> String { read(in: folder, stderr: stderr).text }

    /// The failure as the agent and conversation see it: the worker's own
    /// report when it made one.
    static func repairText(for failure: Error) -> String {
        if let failure = failure as? EngineBuildFailure { return String((failure.report ?? failure.message).prefix(16_000)) }
        let description = failure.localizedDescription
        let diagnostic: String
        if let found = description.range(of: marker, options: .backwards) {
            diagnostic = String(description[found.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            diagnostic = description
        }
        return String(diagnostic.prefix(16_000))
    }
}

/// One build's inputs staged without a validated copy, whose new copies it keeps.
private final class ValidatedInputCopies: @unchecked Sendable {
    private let lock = NSLock()
    private let cache: CADValidatedInputCache
    private let runtime: String
    private var pending: [(key: CADValidatedInputCache.Key, name: String)] = []

    init(cache: CADValidatedInputCache, runtime: String) {
        self.cache = cache
        self.runtime = runtime
    }

    /// Stage the input's copy as `<stem>.validated.brep`; nil when none is kept yet.
    func stage(_ data: Data, format: String, stem: String, in folder: URL) -> String? {
        let key = CADValidatedInputCache.Key(data: data, format: format, runtime: runtime)
        let name = stem + CADValidatedInputCache.suffix
        if cache.stage(key, to: folder.appendingPathComponent(name)) { return name }
        lock.withLock { pending.append((key, name)) }
        return nil
    }

    func keep(from folder: URL) {
        for (key, name) in lock.withLock({ pending }) {
            let produced = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: produced.path) { cache.store(key, from: produced, in: folder) }
        }
    }
}

/// A separate process keeps the UI responsive and contains native-kernel failures.
/// Generated CAD programs run under a restricted macOS sandbox.
@MainActor
final class EngineService {
    private var job: EngineProcessJob?
    private var generation = UUID()
    private let temporaryDirectory: URL
    private struct STEPExportColor: Codable, Hashable, Sendable {
        var solidIndex: Int
        var color: PartColor
    }
    private struct STEPExportKey: Hashable {
        var nativePath: String
        var selection: [Int]?
        var colors: [STEPExportColor]
        var parts: [[Int]]? = nil
        var transforms: [AssemblySolidTransform] = []
    }

    /// Measurements, clearance checks, exports and runtime inspection share
    /// one long-lived worker; builds keep their own sandboxed process.
    let native: CADNativeWorker
    /// Verifies previews that deferred their exact checks, so measurements
    /// and exports never wait behind a verification.
    let verifier: CADNativeWorker
    /// Validated copies of imported inputs, shared by every engine.
    let inputCache: CADValidatedInputCache
    /// Each deferred verification by native solid path, retained for reuse.
    private var verifications: [String: Task<String, Error>] = [:]
    private var verificationOrder: [String] = []

    /// A sandboxed build worker started before this engine's next build, with
    /// the CAD runtime already loaded. It serves exactly one build.
    private struct PreparedBuildWorker {
        let python: String
        let artifacts: EngineBuildArtifacts
        let start: URL
        let job: EngineProcessJob
    }
    private var preparedWorker: PreparedBuildWorker?
    private var isPreparingWorker = false
    private var preparedWorkerExpiry: Task<Void, Never>?
    /// Builds served by a prepared worker, for regression tests.
    private(set) var preparedBuilds = 0
    var hasPreparedBuildWorker: Bool { preparedWorker != nil }

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory, inputCache: CADValidatedInputCache = .shared) {
        self.temporaryDirectory = temporaryDirectory
        self.inputCache = inputCache
        native = CADNativeWorker(temporaryDirectory: temporaryDirectory)
        verifier = CADNativeWorker(temporaryDirectory: temporaryDirectory)
    }

    deinit {
        job?.cancel()
        preparedWorker?.job.discard()
    }

    static var defaultPython: String {
        CADRuntimeManager.defaultPythonPath
    }

    func build(_ spec: ModelSpec, python: String, threads: Int) async throws -> PreviewMesh {
        try await buildModel(spec, python: python, threads: threads, deferSTEP: false)
    }

    /// Validate new or changed inputs, or reuse a matching saved validation hash.
    /// Retain the original native solid without keeping generated STEP bytes.
    /// `print` builds the program's 3D printing version (`lad.print`).
    /// `verifyLater` returns a displayable preview before its exact checks and
    /// STEP verification; accept it only through `verified`.
    func buildPreview(_ spec: ModelSpec, print: Bool = false, python: String, threads: Int,
                      validatedHash: String? = nil, verifyLater: Bool = false) async throws -> PreviewMesh {
        try await buildModel(spec, print: print, python: python, threads: threads, deferSTEP: true, validatedHash: validatedHash,
                             verifyLater: verifyLater)
    }

    /// Start the checks a preview deferred, unless they already started.
    @discardableResult
    func startVerification(_ preview: PreviewMesh, python: String, threads: Int) -> Task<String, Error>? {
        guard let receipt = preview.pendingValidationHash, let path = preview.brepPath else { return nil }
        if let running = verifications[path] { return running }
        let task: Task<String, Error>
        do {
            let source = try nativeSource(preview)
            // The worker compares STEP with the parts the build measured.
            guard let parts = preview.topology?.parts.sorted(by: { $0.solidIndex < $1.solidIndex }),
                  parts.map(\.solidIndex) == Array(0..<preview.solids) else {
                throw LADError.message("The design preview is missing its part measurements.")
            }
            let expected = parts.map { EngineWorkerRequest.ExpectedPart(volume: $0.volume, area: $0.area, bounds: $0.bounds,
                                                                        centroid: $0.centroid) }
            task = Task { @MainActor [self] in
                _ = try await runNative(on: verifier, python: python, threads: threads, action: "verify this design",
                                        designFailures: true) { folder in
                    try EngineWorkerRequest.verify(Self.stageNative(source, into: folder), expectedParts: expected).write(to: folder)
                }
                return receipt
            }
        } catch {
            task = Task { throw error }
        }
        verifications[path] = task
        verificationOrder.append(path)
        while verificationOrder.count > 64 { verifications[verificationOrder.removeFirst()] = nil }
        return task
    }

    /// The preview with its validation receipt once the exact checks and STEP
    /// verification it deferred pass. A canceled caller stops waiting at once.
    func verified(_ preview: PreviewMesh, python: String, threads: Int) async throws -> PreviewMesh {
        guard let task = startVerification(preview, python: python, threads: threads) else { return preview }
        let handoff = ResultHandoff<String>()
        let receipt: String
        do {
            receipt = try await withTaskCancellationHandler {
                Task { handoff.resume(with: await task.result) }
                return try await handoff.value()
            } onCancel: {
                handoff.resume(with: .failure(CancellationError()))
            }
        } catch let failure as EngineBuildFailure where failure.isRepairable {
            throw failure
        } catch {
            // Only a rejected design is a lasting verdict; a later call retries
            // a verification the engine could not complete.
            if !(error is CancellationError), let path = preview.brepPath, verifications[path] == task { verifications[path] = nil }
            throw error
        }
        var verified = preview
        verified.validatedHash = receipt
        verified.pendingValidationHash = nil
        return verified
    }

    private func buildModel(_ spec: ModelSpec, print: Bool = false, python: String, threads: Int, deferSTEP: Bool,
                            validatedHash: String? = nil, verifyLater: Bool = false) async throws -> PreviewMesh {
        let copies = ValidatedInputCopies(cache: inputCache, runtime: python)
        let output = try await run(python: python, threads: threads, scriptMode: true, deferSTEP: deferSTEP, validatedHash: validatedHash,
                                   verifyLater: verifyLater, afterExit: { copies.keep(from: $0) }) { folder in
            var sourceAsset: String?, sourceCopy: String?
            if let source = spec.sourceSTEP {
                try Self.validateSTEP(source)
                try source.write(to: folder.appendingPathComponent("source.step"), options: .atomic)
                sourceAsset = "source.step"
                sourceCopy = copies.stage(source, format: "step", stem: "source", in: folder)
            }
            var staged: [EngineWorkerRequest.InputAsset] = []
            if let assets = spec.inputAssets, !assets.isEmpty {
                guard assets.count <= 256, Set(assets.map(\.id)).count == assets.count else {
                    throw LADError.message("The design contains too many or duplicate imported geometry inputs.")
                }
                for (index, asset) in assets.enumerated() {
                    guard CADInputAsset.supportedFormats.contains(asset.format), !asset.data.isEmpty,
                          asset.data.count <= ProjectStore.maximumSTEPBytes else {
                        throw LADError.message("An imported geometry input is invalid or exceeds 512 MB.")
                    }
                    let stem = String(format: "input-%03d", index)
                    let name = "\(stem).\(asset.format)"
                    try asset.data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    staged.append(.init(id: asset.id, name: asset.name, format: asset.format, path: name,
                                        validatedBREP: copies.stage(asset.data, format: asset.format, stem: stem, in: folder)))
                }
            }
            try EngineWorkerRequest.build(title: spec.title, summary: spec.summary, units: spec.units, script: spec.script,
                                          sourceAsset: sourceAsset, inputAssets: staged, print: print,
                                          sourceValidatedBREP: sourceCopy).write(to: folder)
        }
        return try await readPreview(output, deferSTEP: deferSTEP)
    }

    func runtimeInfo(python: String, threads: Int) async throws -> CADRuntime {
        let output = try await runNative(python: python, threads: threads, action: "inspect the CAD runtime") { folder in
            try EngineWorkerRequest.runtime.write(to: folder)
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try EngineArtifact.read(output.folder.appendingPathComponent("result.json"), in: output.folder, maximumBytes: 65_536)
        }.value
        struct RuntimeResult: Decodable { var runtime: CADRuntime }
        return try JSONDecoder().decode(RuntimeResult.self, from: data).runtime
    }

    struct MeshOutput {
        var metadata: Data
        var record: Data
        var preview: PreviewMesh?
        var native: Data?
        var step: Data?
        /// Binary reference geometry published by open_reference. The file stays
        /// valid while `artifacts` lives.
        var reference: URL?
        var artifacts: EngineBuildArtifacts
    }

    /// All reconstruction operations, including authored programs, use the
    /// existing CAD process sandbox and cancellation/deadline enforcement.
    /// `clones` stage large workspace files, such as the reference mesh, as APFS
    /// clones instead of copying their bytes through memory.
    func meshOperation(request: Data, files: [String: Data], clones: [String: URL] = [:],
                       python: String, threads: Int) async throws -> MeshOutput {
        let output = try await run(python: python, threads: threads, scriptMode: true, deferSTEP: true,
                                   action: "inspect or revise the mesh reconstruction") { folder in
            for name in Array(files.keys) + Array(clones.keys) {
                guard name == URL(fileURLWithPath: name).lastPathComponent, !name.isEmpty else {
                    throw LADError.message("A reconstruction asset has an invalid private name.")
                }
            }
            for (name, data) in files {
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
            for (name, source) in clones {
                guard copyfile(source.path, folder.appendingPathComponent(name).path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                    throw LADError.message("A reconstruction asset could not be staged.")
                }
            }
            try request.write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        }
        let folder = output.folder
        let values = try await Task.detached(priority: .userInitiated) {
            let metadata = try EngineArtifact.read(folder.appendingPathComponent("mesh-result.json"), in: folder, maximumBytes: 4_000_000)
            let record = try EngineArtifact.read(folder.appendingPathComponent("mesh-record.json"), in: folder, maximumBytes: 128_000_000)
            let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] ?? [:]
            let native = object["native_preview"] as? Bool == true
                ? try EngineArtifact.read(folder.appendingPathComponent("model.brep"), in: folder, maximumBytes: 256_000_000) : nil
            let step = object["step_available"] as? Bool == true
                ? try EngineArtifact.read(folder.appendingPathComponent("export.step"), in: folder, maximumBytes: ProjectStore.maximumSTEPBytes) : nil
            let referenceURL = folder.appendingPathComponent("mesh-reference.npz")
            var reference: URL?
            if FileManager.default.fileExists(atPath: referenceURL.path) {
                // Validates a regular, unlinked file within the geometry size limit.
                let (file, _) = try EngineArtifact.openRegular(referenceURL, in: folder)
                try? file.close()
                reference = referenceURL
            }
            return (metadata, record, native, step, object["native_preview"] as? Bool == true, reference)
        }.value
        let preview = values.4 ? try await readPreview(output, deferSTEP: true) : nil
        try Task.checkCancellation()
        return MeshOutput(metadata: values.0, record: values.1, preview: preview, native: values.2, step: values.3,
                          reference: values.5, artifacts: output.artifacts)
    }

    /// Export an already built native solid, with no program replay or meshing.
    /// Repeated exports reuse bytes only for the same geometry, subset, RGB and placement.
    func exportSTEP(_ preview: PreviewMesh, solidIndices: Set<Int>? = nil, solidColors: [Int: PartColor] = [:],
                    solidTransforms: [Int: [Double]]? = nil,
                    python: String, threads: Int) async throws -> Data {
        defer { withExtendedLifetime(preview.buildArtifacts) {} }
        try Task.checkCancellation()
        let transforms = try AssemblySolidTransform.validatedRecords(solidTransforms ?? preview.assemblyPose?.solidTransforms ?? [:], solidCount: preview.solids)
        if let solidIndices {
            guard !solidIndices.isEmpty, solidIndices.allSatisfy({ $0 >= 0 && $0 < preview.solids }) else {
                throw LADError.message("Select at least one available part to export.")
            }
        }
        guard solidColors.count <= preview.solids,
              solidColors.allSatisfy({ (0..<preview.solids).contains($0.key) && $0.value.isValid }) else {
            throw LADError.message("The export colors must refer to available parts and use finite sRGB components between 0 and 1.")
        }
        let selection: [Int]? = solidIndices.flatMap { $0.count == preview.solids ? nil : $0.sorted() }
        let colors = solidColors.keys.sorted().map { STEPExportColor(solidIndex: $0, color: solidColors[$0]!) }
        // Raw bytes retain their original coordinates and carry no requested display colors.
        // Placement and current RGB must be written from native geometry.
        if transforms.isEmpty, selection == nil, colors.isEmpty, let artifacts = preview.buildArtifacts, artifacts.containsSTEP,
           preview.stepPath == artifacts.folder.appendingPathComponent("model.step").path {
            let source = URL(fileURLWithPath: preview.stepPath)
            return try await Task.detached(priority: .userInitiated) {
                let data = try EngineArtifact.read(source, in: source.deletingLastPathComponent(), maximumBytes: ProjectStore.maximumSTEPBytes)
                try Self.validateSTEP(data)
                return data
            }.value
        }
        if let path = preview.brepPath, let artifacts = preview.buildArtifacts,
           path == artifacts.folder.appendingPathComponent("model.brep").path {
            let cacheKey = STEPExportKey(nativePath: path, selection: selection, colors: colors, transforms: transforms)
            if let cached = cachedSTEP(for: cacheKey) { return cached[0] }
            let source = try nativeSource(preview)
            let output = try await runNative(python: python, threads: threads, action: "export this design") { folder in
                try EngineWorkerRequest.export(Self.stageNative(source, into: folder), .init(
                    solidIndices: selection, solidTransforms: transforms,
                    solidColors: colors.map { .init(solidIndex: $0.solidIndex, color: $0.color) })).write(to: folder)
            }
            let data = try await Task.detached(priority: .userInitiated) {
                let data = try EngineArtifact.read(output.folder.appendingPathComponent("model.step"), in: output.folder,
                                                   maximumBytes: ProjectStore.maximumSTEPBytes)
                try Self.validateSTEP(data)
                return data
            }.value
            try Task.checkCancellation()
            cacheSTEP([data], for: cacheKey, owner: artifacts)
            return data
        }
        throw EngineExportError.nativeArtifactUnavailable
    }

    /// Export all requested named parts in one worker, preserving their order.
    /// Placement is shared across files, so importing them together
    /// reconstructs the same layout as a combined export.
    func exportSTEPParts(_ preview: PreviewMesh, parts: [[Int]], solidColors: [Int: PartColor] = [:],
                         solidTransforms: [Int: [Double]]? = nil,
                         python: String, threads: Int) async throws -> [Data] {
        defer { withExtendedLifetime(preview.buildArtifacts) {} }
        try Task.checkCancellation()
        let transforms = try AssemblySolidTransform.validatedRecords(solidTransforms ?? preview.assemblyPose?.solidTransforms ?? [:], solidCount: preview.solids)
        let indices = parts.flatMap { $0 }
        guard !parts.isEmpty, parts.count <= preview.solids, parts.allSatisfy({ !$0.isEmpty }),
              indices.count <= preview.solids, Set(indices).count == indices.count,
              indices.allSatisfy({ (0..<preview.solids).contains($0) }) else {
            throw LADError.message("Select distinct available parts to export individually.")
        }
        guard solidColors.count <= preview.solids,
              solidColors.allSatisfy({ (0..<preview.solids).contains($0.key) && $0.value.isValid }) else {
            throw LADError.message("The export colors must refer to available parts and use finite sRGB components between 0 and 1.")
        }
        let parts = parts.map { $0.sorted() }
        let selection = indices.count == preview.solids ? nil : indices.sorted()
        let colors = solidColors.keys.sorted().map { STEPExportColor(solidIndex: $0, color: solidColors[$0]!) }
        guard let path = preview.brepPath, let artifacts = preview.buildArtifacts,
              path == artifacts.folder.appendingPathComponent("model.brep").path else {
            throw EngineExportError.nativeArtifactUnavailable
        }
        let cacheKey = STEPExportKey(nativePath: path, selection: selection, colors: colors, parts: parts, transforms: transforms)
        if let cached = cachedSTEP(for: cacheKey) { return cached }
        let source = try nativeSource(preview)
        let output = try await runNative(python: python, threads: threads, action: "export these design parts") { folder in
            try EngineWorkerRequest.export(Self.stageNative(source, into: folder), .init(
                solidIndices: selection, solidTransforms: transforms,
                solidColors: colors.map { .init(solidIndex: $0.solidIndex, color: $0.color) },
                individualParts: parts)).write(to: folder)
        }
        struct ExportedPart: Decodable { var path: String; var solidIndices: [Int] }
        struct ExportedParts: Decodable { var partFiles: [ExportedPart] }
        let data = try await Task.detached(priority: .userInitiated) {
            let metadata = try EngineArtifact.read(output.folder.appendingPathComponent("result.json"), in: output.folder,
                                                   maximumBytes: 1_000_000)
            let files = try JSONDecoder().decode(ExportedParts.self, from: metadata).partFiles
            guard files.count == parts.count else { throw LADError.message("The CAD engine returned an incomplete parts export.") }
            var result: [Data] = [], total = 0
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                guard file.path == String(format: "part-%04d.step", index), file.solidIndices == parts[index] else {
                    throw LADError.message("The CAD engine returned an invalid parts export.")
                }
                let bytes = try EngineArtifact.read(output.folder.appendingPathComponent(file.path), in: output.folder,
                                                    maximumBytes: ProjectStore.maximumSTEPBytes - total)
                try Self.validateSTEP(bytes)
                total += bytes.count
                result.append(bytes)
            }
            return result
        }.value
        try Task.checkCancellation()
        cacheSTEP(data, for: cacheKey, owner: artifacts)
        return data
    }

    /// Printing orientations for the requested solids of an already built
    /// native solid, honoring the program's pinned directions. No replay or
    /// meshing; placement on the bed is `PrintLayout`'s.
    func printOrientations(_ preview: PreviewMesh, solids: Set<Int>, python: String,
                           threads: Int) async throws -> [Int: PrintOrientation] {
        defer { withExtendedLifetime(preview.buildArtifacts) {} }
        try Task.checkCancellation()
        guard !solids.isEmpty else { return [:] }
        guard solids.allSatisfy({ (0..<preview.solids).contains($0) }) else {
            throw LADError.message("Choose available parts to orient for 3D printing.")
        }
        try PrintLayout.validatePins(preview)
        let requested = solids.sorted()
        let selection: [Int]? = requested.count == preview.solids ? nil : requested
        let pins = preview.printDown ?? []
        let source = try nativeSource(preview)
        let output = try await runNative(python: python, threads: threads, action: "orient this design for 3D printing") { folder in
            try EngineWorkerRequest.printOrientations(Self.stageNative(source, into: folder), solidIndices: selection,
                                                      printDown: pins).write(to: folder)
        }
        struct Report: Decodable { var orientations: [PrintOrientation] }
        let solidCount = preview.solids
        let orientations = try await Task.detached(priority: .userInitiated) {
            let data = try EngineArtifact.read(output.folder.appendingPathComponent("result.json"), in: output.folder, maximumBytes: 8_000_000)
            return try PrintLayout.validatedOrientations(JSONDecoder().decode(Report.self, from: data).orientations,
                                                         requested: requested, solidCount: solidCount)
        }.value
        try Task.checkCancellation()
        return orientations
    }

    /// Draw one planar face of an already built native solid as a 2D DXF in
    /// millimeters, with no program replay or meshing. Feature indices belong
    /// to this preview's own geometry, so there is no replay fallback.
    func exportFaceDXF(_ preview: PreviewMesh, face: CADFeatureID, solidTransforms: [Int: [Double]]? = nil,
                       python: String, threads: Int) async throws -> Data {
        defer { withExtendedLifetime(preview.buildArtifacts) {} }
        try Task.checkCancellation()
        guard face.kind == .face, (0..<preview.solids).contains(face.solidIndex), face.localIndex >= 0 else {
            throw LADError.message("Select a face of an available part to export.")
        }
        let transforms = try AssemblySolidTransform.validatedRecords(solidTransforms ?? preview.assemblyPose?.solidTransforms ?? [:], solidCount: preview.solids)
        let source = try nativeSource(preview)
        let output = try await runNative(python: python, threads: threads, action: "export this face") { folder in
            try EngineWorkerRequest.faceDXF(Self.stageNative(source, into: folder), face: face,
                                            solidTransforms: transforms).write(to: folder)
        }
        let data = try await Task.detached(priority: .userInitiated) {
            let data = try EngineArtifact.read(output.folder.appendingPathComponent("face.dxf"), in: output.folder,
                                               maximumBytes: Self.maximumDXFBytes)
            try Self.validateDXF(data)
            return data
        }.value
        try Task.checkCancellation()
        return data
    }

    nonisolated static let maximumDXFBytes = 512_000_000

    /// An ASCII DXF opens its first section and ends with an EOF marker.
    nonisolated static func validateDXF(_ data: Data) throws {
        func lines(_ bytes: Data) -> [String] {
            String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard data.count <= maximumDXFBytes, lines(data.prefix(64)).prefix(2) == ["0", "SECTION"],
              lines(data.suffix(64)).suffix(2) == ["0", "EOF"] else {
            throw LADError.message("The DXF drawing is invalid or exceeds 512 MB.")
        }
    }

    /// Every engine shares one byte-bounded cache, so several windows and
    /// agent sessions cannot each retain their own 512 MB of exports.
    private func cachedSTEP(for key: STEPExportKey) -> [Data]? {
        STEPExportCache.shared.data(for: key)
    }

    private func cacheSTEP(_ data: [Data], for key: STEPExportKey, owner artifacts: EngineBuildArtifacts) {
        STEPExportCache.shared.store(data, for: key, owner: artifacts.folder)
    }

    /// Unmoved single-item properties reuse session metadata. Posed properties
    /// and minimum distances come from the transformed native solids.
    func measure(_ preview: PreviewMesh, features: [CADFeatureID], solids: Set<Int>,
                 solidTransforms: [Int: [Double]]? = nil, python: String, threads: Int) async throws -> CADMeasurementReport {
        let transforms = solidTransforms ?? preview.assemblyPose?.solidTransforms ?? [:]
        if !transforms.isEmpty {
            let exact = try await nativeMeasurement(preview, features: features, solids: solids,
                                                    transforms: transforms, python: python, threads: threads)
            guard let topology = exact.topology else { throw LADError.message("The CAD engine returned incomplete assembly measurements.") }
            var posed = preview
            posed.topology = topology
            var report = try CADMeasurements.report(posed, features: features, solids: solids)
            if features.count + solids.count == 2, !(solids.isEmpty && features.allSatisfy({ $0.kind == .vertex })) {
                report.metrics += exact.metrics
                report.closestPoints = exact.closestPoints
            }
            return report
        }
        var report = try CADMeasurements.report(preview, features: features, solids: solids)
        guard report.features.count + report.solidIndices.count == 2,
              !(report.solidIndices.isEmpty && report.features.allSatisfy({ $0.kind == .vertex })) else { return report }
        let exact = try await nativeMeasurement(preview, features: report.features, solids: Set(report.solidIndices),
                                                transforms: nil, python: python, threads: threads)
        report.metrics += exact.metrics
        report.closestPoints = exact.closestPoints
        return report
    }

    /// Sparse exact metadata for the selected posed entities, without remeshing.
    func assemblyProperties(_ preview: PreviewMesh, features: [CADFeatureID], solids: Set<Int>,
                            python: String, threads: Int) async throws -> CADTopology {
        let exact = try await nativeMeasurement(preview, features: features, solids: solids,
                                                transforms: preview.assemblyPose?.solidTransforms ?? [:], python: python, threads: threads)
        guard let topology = exact.topology else { throw LADError.message("The CAD engine returned incomplete assembly properties.") }
        return topology
    }

    struct Clearance: Decodable, Sendable, Equatable {
        /// Exact minimum distance; zero for touching or interfering parts.
        var distance: Double
        /// Common volume when the distance is zero, or nil if OpenCascade could not resolve it.
        var overlapVolume: Double?
        var closestPoints: [[Double]]
    }

    /// Exact pairwise clearance at each supplied rigid pose, without meshing.
    /// `pairs` lists two disjoint solid-index groups per pair; the result is
    /// indexed by pose and then by pair.
    func clearance(_ preview: PreviewMesh, pairs: [[[Int]]], poses: [[Int: [Double]]],
                   python: String, threads: Int) async throws -> [[Clearance]] {
        let records = try poses.map { try AssemblySolidTransform.validatedRecords($0, solidCount: preview.solids) }
        let source = try nativeSource(preview)
        let output = try await runNative(python: python, threads: threads, action: "check this motion") { folder in
            try EngineWorkerRequest.clearance(Self.stageNative(source, into: folder), pairs: pairs, poses: records).write(to: folder)
        }
        struct Report: Decodable { var samples: [[Clearance]] }
        let report = try await Task.detached(priority: .userInitiated) {
            let data = try EngineArtifact.read(output.folder.appendingPathComponent("result.json"), in: output.folder, maximumBytes: 32_000_000)
            let report = try JSONDecoder().decode(Report.self, from: data)
            guard report.samples.count == poses.count, report.samples.allSatisfy({ sample in
                sample.count == pairs.count && sample.allSatisfy { item in
                    item.distance.isFinite && item.distance >= 0 && (item.overlapVolume.map { $0.isFinite && $0 >= 0 } ?? true)
                        && item.closestPoints.count == 2 && item.closestPoints.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
                }
            }) else { throw LADError.message("The CAD engine returned an invalid clearance report.") }
            return report
        }.value
        try Task.checkCancellation()
        return report.samples
    }

    private struct NativeMeasurement: Decodable, Sendable {
        var metrics: [CADMeasurementMetric]
        var closestPoints: [[Double]]?
        var topology: CADTopology?
    }

    private func nativeMeasurement(_ preview: PreviewMesh, features: [CADFeatureID], solids: Set<Int>,
                                   transforms: [Int: [Double]]?, python: String, threads: Int) async throws -> NativeMeasurement {
        let records = try transforms.map { try AssemblySolidTransform.validatedRecords($0, solidCount: preview.solids) }
        let source = try nativeSource(preview)
        let output = try await runNative(python: python, threads: threads, action: "measure these items") { folder in
            try EngineWorkerRequest.measure(Self.stageNative(source, into: folder), features: features,
                                            solidIndices: solids.sorted(), solidTransforms: records).write(to: folder)
        }
        let exact = try await Task.detached(priority: .userInitiated) {
            let data = try EngineArtifact.read(output.folder.appendingPathComponent("result.json"), in: output.folder, maximumBytes: 32_000_000)
            let result = try JSONDecoder().decode(NativeMeasurement.self, from: data)
            guard result.metrics.allSatisfy({ !$0.values.isEmpty && $0.values.allSatisfy(\.isFinite) }),
                  result.closestPoints.map({ $0.count == 2 && $0.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) }) ?? true else {
                throw LADError.message("The CAD engine returned an invalid measurement.")
            }
            return result
        }.value
        try Task.checkCancellation()
        return exact
    }

    /// A build's own native solid, identified by its unique session path.
    private struct NativeSource: Sendable {
        let url: URL
        let validated: Bool
        let artifacts: EngineBuildArtifacts
    }

    private func nativeSource(_ preview: PreviewMesh) throws -> NativeSource {
        guard let path = preview.brepPath, let artifacts = preview.buildArtifacts,
              path == artifacts.folder.appendingPathComponent("model.brep").path else { throw EngineExportError.nativeArtifactUnavailable }
        // A build that deferred its exact checks still checked closed solids;
        // its verification runs separately rather than in every native read.
        return NativeSource(url: URL(fileURLWithPath: path),
                            validated: preview.validatedHash != nil || preview.pendingValidationHash != nil, artifacts: artifacts)
    }

    /// Stage a build's solid into a request and return the request's reference
    /// to it. An APFS clone shares the file's blocks, so staging neither reads
    /// a large solid into memory nor duplicates it on disk.
    nonisolated private static func stageNative(_ source: NativeSource, into folder: URL) throws -> EngineWorkerRequest.NativeSource {
        try withExtendedLifetime(source.artifacts) {
            let marker = Data("DBRep_DrawableShape\n".utf8)
            guard let header = try? EngineArtifact.boundaries(source.url, in: source.url.deletingLastPathComponent(),
                                                              headerBytes: marker.count),
                  header.header == marker,
                  copyfile(source.url.path, folder.appendingPathComponent("source.brep").path, nil,
                           copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                throw EngineExportError.nativeArtifactUnavailable
            }
        }
        return EngineWorkerRequest.NativeSource(identity: source.url.path, validated: source.validated)
    }

    /// Native requests run on a long-lived worker. They never cancel a build
    /// running on this engine, and a build never cancels them. With
    /// `designFailures`, a rejected design is a repairable build failure.
    private func runNative(on worker: CADNativeWorker? = nil, python: String, threads: Int, action: String,
                           designFailures: Bool = false,
                           prepare: @escaping @Sendable (URL) throws -> Void) async throws -> RunResult {
        try Task.checkCancellation()
        let artifacts = try EngineBuildArtifacts.create(in: temporaryDirectory, token: UUID(), containsSTEP: false)
        let folder = artifacts.folder
        try await Task.detached(priority: .userInitiated) { try prepare(folder) }.value
        try Task.checkCancellation()
        let python = try await CADRuntimeManager.resolvePython(python)
        let reply: CADNativeWorker.Reply
        do { reply = try await (worker ?? native).perform(folder: folder, threads: max(1, min(256, threads)), python: python) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LADError.message("The CAD engine could not \(action).\n\n\(error.localizedDescription)") }
        try Task.checkCancellation()
        guard reply.status == "complete" else {
            if designFailures {
                throw EngineBuildFailure(action: action, sandboxed: false,
                                         diagnostic: EngineFailureDiagnostic.read(in: folder, stderr: reply.message ?? ""))
            }
            let diagnostic = EngineFailureDiagnostic.message(in: folder, stderr: reply.message ?? "")
            if diagnostic.contains("No module named") {
                throw LADError.message("LAD’s CAD runtime is incomplete. Reinstall LAD and try again.\n\n\(diagnostic.suffix(1_200))")
            }
            throw LADError.message("The CAD engine could not \(action).\n\n\(diagnostic)")
        }
        return RunResult(artifacts: artifacts, token: UUID())
    }

    nonisolated static func validateSTEP(_ data: Data) throws {
        try validateSTEP(size: data.count, header: data.prefix(512), footer: data.suffix(512))
    }

    nonisolated private static func validateSTEP(size: Int, header: Data, footer: Data) throws {
        guard size > 0, size <= ProjectStore.maximumSTEPBytes,
              String(decoding: header, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ISO-10303-21;"),
              String(decoding: footer, as: UTF8.self).contains("END-ISO-10303-21;") else {
            throw LADError.message("The STEP design is invalid or exceeds 512 MB.")
        }
    }

    struct RunResult: Sendable {
        var artifacts: EngineBuildArtifacts
        var token: UUID
        var folder: URL { artifacts.folder }
    }

    func run(python: String, threads: Int, scriptMode: Bool, deferSTEP: Bool = false, validatedHash: String? = nil,
                     verifyLater: Bool = false, action: String = "build this design", afterExit: (@Sendable (URL) -> Void)? = nil,
                     prepare: @escaping @Sendable (URL) throws -> Void) async throws -> RunResult {
        try Task.checkCancellation()
        cancel()
        let token = UUID()
        generation = token
        // Deferred-STEP builds of the same runtime use the prepared worker.
        let prepared = scriptMode && deferSTEP ? takePreparedWorker(python: python) : nil
        let artifacts: EngineBuildArtifacts
        do { artifacts = try prepared?.artifacts ?? EngineBuildArtifacts.create(in: temporaryDirectory, token: token, containsSTEP: !deferSTEP) }
        catch { prepared?.job.discard(); throw error }
        let folder = artifacts.folder
        defer { withExtendedLifetime(artifacts) {} }
        let request = folder.appendingPathComponent("request.json")
        do {
            try await Task.detached(priority: .userInitiated) { try prepare(folder) }.value
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
        } catch {
            prepared?.job.discard()
            throw error
        }
        let hash = validatedHash.flatMap { hash in
            hash.utf8.count == 64 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) ? hash : nil
        }
        let workerThreads = max(1, min(256, threads))
        var task: EngineProcessJob?
        if let prepared {
            var options: [String: Any] = ["threads": workerThreads, "deferStep": true, "verifyLater": verifyLater]
            options["validatedHash"] = hash
            let data = try JSONSerialization.data(withJSONObject: options)
            do {
                try await Task.detached(priority: .userInitiated) { try prepared.job.begin(options: data, at: prepared.start) }.value
                task = prepared.job
                preparedBuilds += 1
            } catch {
                // Its process ended while waiting; launch this build normally.
                prepared.job.discard()
            }
        }
        if task == nil {
            let python = try await CADRuntimeManager.resolvePython(python)
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
            var arguments = ["--request", request.path, "--output", folder.path, "--threads", String(workerThreads)]
                + (deferSTEP ? ["--defer-step"] : [])
            if let hash { arguments.append("--validated-hash=\(hash)") }
            if deferSTEP, verifyLater { arguments.append("--verify-later") }
            task = try Self.workerJob(python: python, sandboxed: scriptMode, arguments: arguments, artifacts: artifacts)
        }
        let running = task!
        job = running
        defer { if job === running { job = nil } }
        let status = try await withTaskCancellationHandler {
            try await running.run()
        } onCancel: {
            running.cancel()
        }
        // A failed program can still have imported and validated its inputs.
        if let afterExit { await Task.detached(priority: .userInitiated) { afterExit(folder) }.value }
        if scriptMode, deferSTEP { prepareBuildWorker(python: python) }
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        job = nil
        guard status == 0 else {
            let logData = try? EngineArtifact.tail(folder.appendingPathComponent("stderr.log"), in: folder, maximumBytes: 65_536)
            let log = logData.map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw EngineBuildFailure(action: action, sandboxed: scriptMode,
                                     diagnostic: EngineFailureDiagnostic.read(in: folder, stderr: log))
        }
        return RunResult(artifacts: artifacts, token: token)
    }

    /// A worker process for `arguments`, in the program sandbox when `sandboxed`.
    private static func workerJob(python: String, sandboxed: Bool, arguments: [String],
                                  artifacts: EngineBuildArtifacts) throws -> EngineProcessJob {
        let folder = artifacts.folder
        let launch = try workerLaunch(python: python)
        let worker = launch.worker, runtime = launch.runtime, actualRuntime = launch.actualRuntime, interpreter = launch.interpreter
        let executable: URL
        let launchArguments: [String]
        if sandboxed {
            executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            let profile = worker.deletingLastPathComponent().appendingPathComponent("script.sb")
            guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: profile.path) else {
                throw LADError.message("LAD could not start its CAD execution sandbox. Reinstall LAD and try again.")
            }
            let parameters = [
                ("RUNTIME", runtime.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path),
                ("PYTHON_BASE", pythonBaseDirectory(runtime: runtime, actualRuntime: actualRuntime).path),
                ("WORKER", worker.deletingLastPathComponent().path),
                ("OUTPUT", folder.path),
                ("PYTHON", interpreter.path), ("ENTRY_PYTHON", runtime.path)
            ]
            launchArguments = parameters.flatMap { ["-D", "\($0.0)=\($0.1)"] } + ["-f", profile.path, interpreter.path, worker.path] + arguments
        } else {
            executable = runtime
            launchArguments = [worker.path] + arguments
        }
        let environment = try workerEnvironment(folder: folder, launch: launch)
        return try EngineProcessJob(executable: executable, arguments: launchArguments, artifacts: artifacts, environment: environment)
    }

    /// Start a sandboxed worker for this engine's next deferred-STEP build, so
    /// Python and CadQuery are loaded before that build is requested. Each
    /// worker still runs one program; an unused one stops after five minutes.
    func prepareBuildWorker(python: String) {
        guard preparedWorker == nil, !isPreparingWorker else { return }
        isPreparingWorker = true
        Task { [weak self] in
            guard let self else { return }
            defer { isPreparingWorker = false }
            do {
                let resolved = try await CADRuntimeManager.resolvePython(python)
                let artifacts = try EngineBuildArtifacts.create(in: temporaryDirectory, token: UUID(), containsSTEP: false)
                let start = artifacts.folder.appendingPathComponent("start")
                guard mkfifo(start.path, 0o600) == 0 else { return }
                let job = try Self.workerJob(python: resolved, sandboxed: true,
                                             arguments: ["--await-build", start.path, "--output", artifacts.folder.path],
                                             artifacts: artifacts)
                try await Task.detached(priority: .utility) { try job.start() }.value
                preparedWorker?.job.discard()
                preparedWorker = PreparedBuildWorker(python: python, artifacts: artifacts, start: start, job: job)
                preparedWorkerExpiry?.cancel()
                preparedWorkerExpiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled, let self else { return }
                    preparedWorker?.job.discard()
                    preparedWorker = nil
                }
            } catch {
                return
            }
        }
    }

    private func takePreparedWorker(python: String) -> PreparedBuildWorker? {
        guard let worker = preparedWorker else { return nil }
        preparedWorker = nil
        preparedWorkerExpiry?.cancel(); preparedWorkerExpiry = nil
        guard worker.python == python, worker.job.isRunning else { worker.job.discard(); return nil }
        return worker
    }

    func readPreview(_ output: RunResult, deferSTEP: Bool) async throws -> PreviewMesh {
        let folder = output.folder, artifacts = output.artifacts
        let resultURL = folder.appendingPathComponent("result.json")
        let decoding = Task.detached(priority: .userInitiated) {
            let result = try Self.decodePreview(resultURL, in: folder)
            // Generated code cannot redirect the app to read an unrelated file.
            guard URL(fileURLWithPath: result.stepPath).path == folder.appendingPathComponent("model.step").path else {
                throw LADError.message("CAD engine returned an unexpected STEP asset path.")
            }
            if let path = result.brepPath {
                guard path == folder.appendingPathComponent("model.brep").path else {
                    throw LADError.message("CAD engine returned an unexpected native solid path.")
                }
                try Self.validateNativeSolid(in: folder)
            }
            if deferSTEP {
                guard result.brepPath == folder.appendingPathComponent("model.brep").path else {
                    throw LADError.message("CAD engine returned an unexpected native solid path.")
                }
                guard !FileManager.default.fileExists(atPath: result.stepPath) else {
                    throw LADError.message("CAD engine unexpectedly exported STEP while preparing a preview.")
                }
            } else {
                let step = try EngineArtifact.boundaries(folder.appendingPathComponent("model.step"), in: folder,
                                                         headerBytes: 512, footerBytes: 512)
                try Self.validateSTEP(size: step.size, header: step.header, footer: step.footer)
            }
            artifacts.discardAll(except: ["model.brep", "model.step"])
            return result
        }
        var mesh = try await withTaskCancellationHandler { try await decoding.value }
            onCancel: { decoding.cancel() }
        guard output.token == generation, !Task.isCancelled else { throw CancellationError() }
        mesh.buildArtifacts = output.artifacts
        return mesh
    }

    /// A preview in the worker's format, `result.json` plus its packed buffers
    /// in `folder`, decoded and completely checked.
    nonisolated static func decodePreview(_ resultURL: URL, in folder: URL) throws -> PreviewMesh {
        let data = try EngineArtifact.read(resultURL, in: folder, maximumBytes: 256_000_000)
        var result = try JSONDecoder().decode(PreviewMesh.self, from: data)
        guard let buffers = try PreviewMeshBuffers.manifest(in: data) else {
            throw LADError.message("The CAD engine returned an incomplete design preview.")
        }
        try PreviewMeshBuffers.read(buffers, in: folder, into: &result)
        guard result.vertexNormals != nil else {
            throw LADError.message("The CAD engine returned an incomplete design preview.")
        }
        try ProjectStore.validatePreview(result)
        try CADMeasurements.validateTopology(result)
        try PrintLayout.validatePins(result)
        if let motion = result.assemblyMotion {
            result.assemblyPose = try motion.solve(parts: result.parts ?? [])
        }
        return result
    }

    /// `folder/model.brep` is a native solid file.
    nonisolated static func validateNativeSolid(in folder: URL) throws {
        let marker = Data("DBRep_DrawableShape\n".utf8)
        let brep = try EngineArtifact.boundaries(folder.appendingPathComponent("model.brep"), in: folder,
                                                 headerBytes: marker.count)
        guard brep.header == marker else {
            throw LADError.message("CAD engine did not return native solid geometry.")
        }
    }

    func cancel() {
        generation = UUID()
        job?.cancel()
        job = nil
    }

    /// The worker script and interpreter for a resolved runtime.
    struct WorkerLaunch: Sendable {
        let worker: URL
        let runtime: URL
        let actualRuntime: URL
        let interpreter: URL
    }

    nonisolated static func workerLaunch(python: String) throws -> WorkerLaunch {
        let worker = ResourcePaths.root.appendingPathComponent("Engine/worker.py").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw LADError.message("LAD’s CAD engine is missing. Reinstall LAD and try again.")
        }
        let runtime = URL(fileURLWithPath: (python as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw LADError.message("LAD’s CAD runtime is missing. Restart LAD and try again.")
        }
        let actualRuntime = runtime.resolvingSymlinksInPath()
        // Homebrew/framework bin/python is a launcher that spawns Python.app.
        // Start the interpreter directly so generated code can never fork.
        let frameworkInterpreter = actualRuntime.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
        let interpreter = FileManager.default.isExecutableFile(atPath: frameworkInterpreter.path) ? frameworkInterpreter : actualRuntime
        return WorkerLaunch(worker: worker, runtime: runtime, actualRuntime: actualRuntime, interpreter: interpreter)
    }

    /// An allowlist avoids passing ambient credentials or model-service keys
    /// to the worker. Runtime/cache locations are explicit and local.
    nonisolated static func workerEnvironment(folder: URL, launch: WorkerLaunch) throws -> [String: String] {
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
        if launch.interpreter != launch.actualRuntime { environment["__PYVENV_LAUNCHER__"] = launch.runtime.path }
        return environment
    }

    private static func pythonBaseDirectory(runtime: URL, actualRuntime: URL) -> URL {
        let environment = runtime.deletingLastPathComponent().deletingLastPathComponent()
        if let configuration = try? String(contentsOf: environment.appendingPathComponent("pyvenv.cfg"), encoding: .utf8),
           let home = configuration.components(separatedBy: .newlines).first(where: { $0.hasPrefix("home = ") }) {
            return URL(fileURLWithPath: String(home.dropFirst(7))).deletingLastPathComponent().resolvingSymlinksInPath()
        }
        return actualRuntime.deletingLastPathComponent().deletingLastPathComponent()
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

    /// Inspect format markers without retaining the native geometry payload.
    /// Both ranges come from the same safely opened descriptor, including when
    /// a short file's header and footer overlap.
    static func boundaries(_ url: URL, in folder: URL, headerBytes: Int, footerBytes: Int = 0) throws
        -> (size: Int, header: Data, footer: Data) {
        let (file, size) = try openRegular(url, in: folder)
        defer { try? file.close() }
        guard size > 0, headerBytes >= 0, footerBytes >= 0 else {
            throw LADError.message("CAD engine design asset is empty or has invalid marker ranges.")
        }
        let headerCount = min(headerBytes, Int(size)), footerCount = min(footerBytes, Int(size))
        let header = try file.read(upToCount: headerCount) ?? Data()
        try file.seek(toOffset: UInt64(size - Int64(footerCount)))
        let footer = footerCount == 0 ? Data() : try file.read(upToCount: footerCount) ?? Data()
        var finalInfo = stat()
        guard header.count == headerCount, footer.count == footerCount,
              Darwin.fstat(file.fileDescriptor, &finalInfo) == 0, finalInfo.st_size == size else {
            throw LADError.message("The CAD engine design asset changed while it was being checked.")
        }
        return (Int(size), header, footer)
    }

    static func openRegular(_ url: URL, in folder: URL) throws -> (FileHandle, Int64) {
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
              info.st_size >= 0, info.st_size <= ProjectStore.maximumSTEPBytes else {
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
    private let artifacts: EngineBuildArtifacts
    private let workerInput: FileHandle
    private var stderr: FileHandle?

    init(executable: URL, arguments: [String], artifacts: EngineBuildArtifacts, environment: [String: String]) throws {
        self.artifacts = artifacts
        directory = artifacts.folder
        workerInput = try artifacts.workerInput()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = artifacts.folder
        process.environment = environment
        process.standardInput = workerInput
        process.standardOutput = FileHandle.nullDevice
    }

    /// Launch the process; `run` launches it when this was not called first.
    /// Foundation delivers a process's termination on its launching thread's
    /// run loop, so one thread launches the process and reaps it, however
    /// long a prepared worker waits for its build.
    func start() throws {
        let log = directory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { finished = true; try? handle.close(); throw CancellationError() }
        stderr = handle
        process.standardError = handle
        let started = DispatchSemaphore(value: 0)
        var failure: Error?
        let reaper = Thread { [process] in
            do { try process.run() } catch { failure = error; started.signal(); return }
            started.signal()
            process.waitUntilExit()
        }
        reaper.name = "LAD CAD worker"
        reaper.start()
        started.wait()
        if let failure { finished = true; try? handle.close(); throw failure }
        launched = true
    }

    var isRunning: Bool { lock.withLock { launched && !finished && process.isRunning } }

    /// Stop a launched worker that no build awaits. Its directory, which its
    /// process keeps leased, stays owned until that process has exited.
    func discard() {
        cancel()
        DispatchQueue.global(qos: .utility).async { [self] in
            while lock.withLock({ launched && process.isRunning }) { Thread.sleep(forTimeInterval: 0.03) }
            lock.withLock { finished = true }
            try? workerInput.close(); try? stderr?.close()
        }
    }

    /// Deliver a prepared worker's build options through its private FIFO,
    /// waiting while it finishes loading the CAD runtime.
    func begin(options: Data, at start: URL) throws {
        guard options.count <= Int(PIPE_BUF) else { throw LADError.message("The CAD build options are too large.") }
        var descriptor: Int32 = -1
        while descriptor < 0 {
            descriptor = Darwin.open(start.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            // ENXIO: the worker has not opened its end yet.
            if descriptor < 0 {
                guard errno == ENXIO, isRunning, !lock.withLock({ cancelled }) else {
                    throw LADError.message("The prepared CAD worker stopped before its build.")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        defer { Darwin.close(descriptor) }
        let written = options.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == options.count else { throw LADError.message("The prepared CAD worker did not accept its build.") }
    }

    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { try? workerInput.close(); try? stderr?.close() }
                do {
                    if !lock.withLock({ launched }) { try start() }
                    let deadline = Date().addingTimeInterval(600)
                    while process.isRunning {
                        if Date() >= deadline {
                            lock.lock(); timedOut = true; lock.unlock()
                            cancel()
                        }
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                    lock.lock()
                    finished = true
                    let didCancel = cancelled, didTimeOut = timedOut
                    lock.unlock()
                    if didTimeOut {
                        throw EngineBuildFailure(kind: .timeout, message: "The CAD engine exceeded its 10-minute limit. Simplify the design and try again.")
                    }
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
