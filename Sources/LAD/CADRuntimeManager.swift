import Combine
import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func lockRuntimeFile(_ descriptor: Int32, _ operation: Int32) -> Int32

/// One immutable, versioned runtime shared by every design window. Provisioning
/// uses only the app's payload, and never a user Python, shell setup or network.
@MainActor
final class CADRuntimeManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    static let shared = CADRuntimeManager()
    @Published private(set) var phase: Phase = .idle
    private var preparation: Task<String, Error>?
    private var readyPython: String?
    private let payloadDirectory: URL
    private let installationRoot: URL

    init(payloadDirectory: URL? = nil, installationRoot: URL? = nil) {
        self.payloadDirectory = payloadDirectory ?? Self.bundledPayloadDirectory
        self.installationRoot = installationRoot ?? Self.defaultInstallationRoot
    }

    static var bundledPayloadDirectory: URL {
        let packaged = ResourcePaths.root.appendingPathComponent("CADRuntime", isDirectory: true)
        if FileManager.default.fileExists(atPath: packaged.appendingPathComponent("manifest.json").path) { return packaged }
        return ResourcePaths.root.appendingPathComponent(".build/cad-runtime/\(CADRuntimePayload.hostArchitecture)", isDirectory: true)
    }

    static var defaultInstallationRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LAD/Runtimes", isDirectory: true)
    }

    static var defaultPythonPath: String {
        let identifier = (try? CADRuntimePayload.load(from: bundledPayloadDirectory).identifier) ?? "unavailable"
        return defaultInstallationRoot.appendingPathComponent(identifier).appendingPathComponent("venv/bin/python").path
    }

    /// Explicit interpreter arguments remain available to isolated test harnesses.
    /// The app's normal path always provisions and checks the managed runtime.
    static func resolvePython(_ requested: String?) async throws -> String {
        try Task.checkCancellation()
        if let requested, !requested.isEmpty, requested != defaultPythonPath {
            let path = (requested as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw LADError.message("The CAD runtime could not be found. Restart LAD and try again.")
            }
            return path
        }
        let python = try await shared.ensureReady()
        try Task.checkCancellation()
        return python
    }

    func ensureReady() async throws -> String {
        try Task.checkCancellation()
        if let readyPython, FileManager.default.isExecutableFile(atPath: readyPython) { return readyPython }
        if let preparation { return try await preparation.value }
        let payloadDirectory = payloadDirectory, installationRoot = installationRoot
        phase = .preparing
        // A window closing must not cancel provisioning another window needs.
        let task = Task.detached(priority: .userInitiated) {
            try CADRuntimeInstaller.install(payloadDirectory: payloadDirectory, installationRoot: installationRoot)
        }
        preparation = task
        do {
            let python = try await task.value
            readyPython = python
            phase = .ready
            preparation = nil
            return python
        } catch {
            phase = .failed(error.localizedDescription)
            preparation = nil
            throw error
        }
    }
}

struct CADRuntimePayload: Codable, Sendable {
    var formatVersion: Int
    var identifier: String
    var architecture: String
    var pythonVersion: String
    var archive: String
    var sha256: String

    static let hostArchitecture = "arm64"

    static func load(from directory: URL) throws -> Self {
        let file = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: file), data.count <= 65_536,
              let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.formatVersion == 1, payload.architecture == hostArchitecture,
              !payload.identifier.isEmpty, payload.identifier.count <= 160,
              payload.identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
              payload.identifier != ".", payload.identifier != "..",
              payload.archive == "payload.tar.gz", payload.sha256.count == 64,
              payload.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw LADError.message("LAD’s bundled CAD runtime is missing or incompatible. Reinstall LAD and try again.")
        }
        return payload
    }
}

enum CADRuntimeInstaller {
    static func install(payloadDirectory: URL, installationRoot: URL) throws -> String {
        let payload = try CADRuntimePayload.load(from: payloadDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: installationRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = try EngineArtifact.canonicalDirectory(installationRoot)
        // The process-wide task coalesces windows; this lock also covers two LAD
        // processes launched together. Never publish a partially prepared venv.
        let descriptor = Darwin.open(root.appendingPathComponent(".install.lock").path,
                                     O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LADError.message("LAD could not reserve its CAD runtime directory.") }
        defer { Darwin.close(descriptor) }
        guard lockRuntimeFile(descriptor, LOCK_EX) == 0 else {
            throw LADError.message("LAD could not reserve its CAD runtime directory.")
        }
        // A crash can leave an unpacked payload. Holding the cross-process lock
        // proves that no installer still owns these private staging directories.
        for abandoned in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = abandoned.lastPathComponent
            var info = stat()
            if name.hasPrefix(".install-"), UUID(uuidString: String(name.dropFirst(9))) != nil,
               Darwin.lstat(abandoned.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
               info.st_uid == getuid() {
                try? manager.removeItem(at: abandoned)
            }
        }
        let destination = root.appendingPathComponent(payload.identifier, isDirectory: true)
        let python = destination.appendingPathComponent("venv/bin/python")
        let marker = destination.appendingPathComponent(".ready")
        if (try? String(contentsOf: marker, encoding: .utf8)) == payload.sha256,
           manager.isExecutableFile(atPath: python.path) {
            try warmBytecode(python: python, directory: destination, payloadHash: payload.sha256)
            return python.path
        }

        let archive = payloadDirectory.appendingPathComponent(payload.archive)
        guard try fileHash(archive) == payload.sha256 else {
            throw LADError.message("LAD’s bundled CAD runtime failed its integrity check. Reinstall LAD and try again.")
        }
        let staging = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var promoted = false, completed = false
        defer {
            if !promoted { try? manager.removeItem(at: staging) }
            if promoted && !completed { try? manager.removeItem(at: destination) }
        }
        try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path, "--no-same-owner"], in: staging)
        let base = staging.appendingPathComponent("python/bin/python3")
        guard manager.isExecutableFile(atPath: base.path) else {
            throw LADError.message("LAD’s bundled CAD runtime is incomplete. Reinstall LAD and try again.")
        }
        // CAD packages live in the private base installation; this venv exposes
        // them without copying gigabytes or consulting any system environment.
        try run(base, ["-I", "-B", "-m", "venv", "--copies", "--system-site-packages", "--without-pip", staging.appendingPathComponent("venv").path], in: staging)
        let config = staging.appendingPathComponent("venv/pyvenv.cfg")
        // Python and Foundation can normalize /var and /private/var differently.
        // Write the final interpreter contract explicitly, rather than replacing
        // one spelling of the temporary path in venv-generated configuration.
        let configuration = """
        home = \(destination.appendingPathComponent("python/bin").path)
        include-system-site-packages = true
        version = \(payload.pythonVersion)
        executable = \(destination.appendingPathComponent("python/bin/python3").path)

        """
        try configuration.write(to: config, atomically: true, encoding: .utf8)
        // Activation scripts are unnecessary to native launches and otherwise
        // retain their temporary build location. Use `python -m` for facilities.
        for file in try manager.contentsOfDirectory(at: staging.appendingPathComponent("venv/bin"), includingPropertiesForKeys: nil) {
            if file.lastPathComponent.hasPrefix("activate") || file.lastPathComponent == "Activate.ps1" { try manager.removeItem(at: file) }
        }
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: staging, to: destination)
        promoted = true
        try warmBytecode(python: python, directory: destination, payloadHash: payload.sha256)
        try payload.sha256.write(to: marker, atomically: true, encoding: .utf8)
        completed = true
        return python.path
    }

    private static func warmBytecode(python: URL, directory: URL, payloadHash: String) throws {
        let marker = directory.appendingPathComponent(".bytecode-ready")
        let identity = "1:\(payloadHash)"
        guard (try? String(contentsOf: marker, encoding: .utf8)) != identity else { return }
        // Warm the installed CAD dependency tree once, including existing runtimes
        // from earlier app builds. -I ignores ambient Python settings; omit -B
        // here so imports can cache bytecode in this private installation.
        // Ordinary CAD workers continue to disable writes. No bundle files change.
        try run(python, ["-I", "-c", "import cadquery as cq, OCP, numpy, ssl, venv; assert cq.Workplane('XY').box(2,3,4).val().Volume() > 23.99"],
                in: directory, allowBytecodeWrites: true)
        try identity.write(to: marker, atomically: true, encoding: .utf8)
    }

    private static func fileHash(_ file: URL) throws -> String {
        guard let stream = try? FileHandle(forReadingFrom: file) else {
            throw LADError.message("LAD’s bundled CAD runtime is missing. Reinstall LAD and try again.")
        }
        defer { try? stream.close() }
        var hash = SHA256()
        while let chunk = try stream.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: URL, _ arguments: [String], in directory: URL, allowBytecodeWrites: Bool = false) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let temporary = directory.appendingPathComponent(".preparation", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let log = temporary.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stderr.close() }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": temporary.path, "TMPDIR": temporary.path,
                               "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "en_US.UTF-8",
                               "MPLCONFIGDIR": temporary.path, "XDG_CACHE_HOME": temporary.path]
        if allowBytecodeWrites { process.environment?.removeValue(forKey: "PYTHONDONTWRITEBYTECODE") }
        try process.run()
        let deadline = Date().addingTimeInterval(600)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw LADError.message("Preparing LAD’s CAD runtime took too long. Restart LAD and try again.")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self).suffix(2_000)
            throw LADError.message("LAD could not prepare its CAD runtime. Restart LAD and try again.\n\n\(details)")
        }
    }
}
