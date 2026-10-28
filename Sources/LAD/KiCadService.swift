import CryptoKit
import Darwin
import Foundation

struct KiCadExport: Sendable {
    let stepURL: URL
    let boardURL: URL
    let diagnostics: String
    let missingModels: [String]
    let recoveredModels: [String]
    let modeledComponents: Int
    let boardThickness: Double?
    /// Digest of the exact source snapshot read before private staging/export.
    let sourceSHA256: String
}

/// KiCad, rather than generated Python, reads PCB projects and their component
/// models. All rewritten inputs and export files live in a private scratch folder.
@MainActor
final class KiCadService {
    private let executableOverride: URL?
    private let timeout: TimeInterval
    private let recoverMissingModels: Bool
    private let modelCache: URL?
    private var job: KiCadProcessJob?
    private var download: Task<Data, Error>?
    private var generation = UUID()

    init(executable: URL? = nil, timeout: TimeInterval = 300,
         recoverMissingModels: Bool = true, modelCache: URL? = nil) {
        executableOverride = executable
        self.timeout = timeout
        self.recoverMissingModels = recoverMissingModels
        self.modelCache = modelCache
    }

    static var defaultExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli",
            "/Applications/KiCad.app/Contents/MacOS/kicad-cli",
            home.appendingPathComponent("Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli").path,
            "/opt/homebrew/bin/kicad-cli", "/usr/local/bin/kicad-cli"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func exportSTEP(board: URL, onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> KiCadExport {
        cancel()
        let token = UUID()
        generation = token
        guard board.isFileURL, board.host == nil || board.host == "localhost",
              board.pathExtension.lowercased() == "kicad_pcb" else {
            throw LADError.message("Choose an exact .kicad_pcb file to export with KiCad.")
        }
        guard let executable = executableOverride ?? Self.defaultExecutable,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LADError.message("KiCad CLI was not found. Install KiCad for macOS, including its 3D model libraries, then try again.")
        }
        let source = board.resolvingSymlinksInPath().standardizedFileURL
        let (text, parsed, sourceSHA256) = try await Task.detached(priority: .userInitiated) {
            let data = try Self.readSource(source, maximumBytes: 20 * 1024 * 1024)
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw LADError.message("The KiCad board is not valid UTF-8 text: \(source.path)")
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (text, try KiCadBoardModels(text: text), digest)
        }.value
        try check(token)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-KiCad-\(token.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let folder = try EngineArtifact.canonicalDirectory(scratch)
        var succeeded = false
        defer {
            if token == generation { job = nil; download = nil }
            if !succeeded { try? FileManager.default.removeItem(at: folder) }
        }
        let sourceEnvironment = Self.environment(executable: executable, board: source, folder: folder)
        let variables = await Task.detached(priority: .userInitiated) {
            Self.modelVariables(executable: executable, board: source, environment: sourceEnvironment)
        }.value
        let environment = try Self.isolatedEnvironment(sourceEnvironment, executable: executable, folder: folder)
        var replacements: [String: String] = [:]
        var missing: [String] = []
        var recovered: [String] = []
        var downloaded: [String: URL] = [:]
        var attempted = Set<String>()
        onProgress("Reading \(source.lastPathComponent) and resolving its component models…")
        for model in parsed.models {
            try check(token)
            let expanded = Self.expand(model.path, variables: variables)
            var resolved = URL(fileURLWithPath: (expanded as NSString).expandingTildeInPath, relativeTo: source.deletingLastPathComponent()).standardizedFileURL
            if resolved.pathExtension.lowercased() == "wrl" {
                // VRML is a mesh; --subst-models requires an actual STEP/IGES
                // counterpart before KiCad can include its component solids.
                let stem = resolved.deletingPathExtension()
                resolved = ["step", "stp", "igs", "iges"].map { stem.appendingPathExtension($0) }
                    .first(where: Self.isRegularFile) ?? stem.appendingPathExtension("step")
            }
            var available = !expanded.contains("${") && Self.isRegularFile(resolved)
            var resolvedURL = resolved
            if !available, let libraryPath = Self.standardLibraryPath(model.path) {
                if let cached = modelCache?.appendingPathComponent(libraryPath), Self.isRegularFile(cached),
                   (try? Self.validatedSTEP(Self.readSource(cached, maximumBytes: 32 * 1024 * 1024))) != nil {
                    resolvedURL = cached
                    available = true
                    recovered.append("\(model.reference): \(libraryPath) (cached official KiCad model)")
                } else if let previous = downloaded[libraryPath] {
                    resolvedURL = previous; available = true
                    recovered.append("\(model.reference): \(libraryPath) (official KiCad library)")
                } else if recoverMissingModels, attempted.count < 8, attempted.insert(libraryPath).inserted {
                    onProgress("Recovering \(URL(fileURLWithPath: libraryPath).lastPathComponent) from KiCad’s official library…")
                    do {
                        let url = Self.officialModelURL(libraryPath)!
                        let task = Task { try await KiCadModelDownload.fetch(url) }
                        download = task
                        let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                        try check(token)
                        try Self.validatedSTEP(data)
                        let local = folder.appendingPathComponent("models").appendingPathComponent(libraryPath)
                        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try data.write(to: local, options: .atomic)
                        downloaded[libraryPath] = local
                        resolvedURL = local; available = true
                        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        recovered.append("\(model.reference): \(libraryPath) (official KiCad library, SHA-256 \(hash))")
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* A partial export is useful, but must disclose missing geometry. */ }
                    download = nil
                }
            }
            // Staging changes KIPRJMOD. Resolve every model path back to the
            // original project, including the project's own models directory.
            if !expanded.contains("${") || available { replacements[model.path] = resolvedURL.path }
            if !available { missing.append("\(model.reference): \(model.path)") }
        }
        try check(token)
        let staged = folder.appendingPathComponent(source.lastPathComponent)
        var stagedText = text
        for (original, replacement) in replacements {
            stagedText = stagedText.replacingOccurrences(of: Self.quoted(original), with: Self.quoted(replacement))
        }
        try Data(stagedText.utf8).write(to: staged, options: .atomic)
        let project = source.deletingPathExtension().appendingPathExtension("kicad_pro")
        if Self.isRegularFile(project) {
            try Self.readSource(project, maximumBytes: 20 * 1024 * 1024)
                .write(to: staged.deletingPathExtension().appendingPathExtension("kicad_pro"), options: .atomic)
        }
        let output = folder.appendingPathComponent("pcb.step")
        onProgress("Exporting PCB and available component solids with KiCad…")
        // Explicit output and origin avoid writing beside the user's board or
        // inheriting a GUI origin setting. No shell or generated command is used.
        let arguments = ["pcb", "export", "step", "--subst-models", "--user-origin", "0x0mm", "--output", output.path, staged.path]
        let process = KiCadProcessJob(executable: executable, arguments: arguments, directory: folder, environment: environment, timeout: timeout)
        job = process
        let status = try await withTaskCancellationHandler { try await process.run() } onCancel: { process.cancel() }
        try check(token)
        let log = process.diagnostics
        guard status == 0 else {
            throw LADError.message("KiCad could not export \(source.lastPathComponent) (exit \(status)).\n\n\(log.suffix(4_000))")
        }
        let data = try EngineArtifact.read(output, in: folder, maximumBytes: ProjectStore.maximumSTEPBytes)
        try Self.validatedSTEP(data)
        var diagnostics = "Source board: \(source.path)\nKiCad STEP origin: absolute PCB (0, 0); STEP Y is opposite PCB Y."
        if let thickness = parsed.thickness { diagnostics += "\nPCB thickness from source: \(thickness) mm." }
        diagnostics += "\nReferenced component models: \(parsed.models.count); unavailable: \(missing.count)."
        if !recovered.isEmpty { diagnostics += "\nRecovered models:\n" + recovered.joined(separator: "\n") }
        if !missing.isEmpty { diagnostics += "\nMissing component geometry (omitted from STEP):\n" + missing.joined(separator: "\n") }
        if !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { diagnostics += "\nKiCad output:\n" + log }
        succeeded = true
        return KiCadExport(stepURL: output, boardURL: source, diagnostics: diagnostics,
                           missingModels: missing, recoveredModels: recovered,
                           modeledComponents: parsed.models.count - missing.count, boardThickness: parsed.thickness,
                           sourceSHA256: sourceSHA256)
    }

    func cancel() {
        generation = UUID()
        download?.cancel(); download = nil
        job?.cancel(); job = nil
    }

    private func check(_ token: UUID) throws {
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    nonisolated private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    nonisolated private static func readSource(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LADError.message("KiCad input is unavailable: \(url.path)") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= maximumBytes else {
            throw LADError.message("KiCad input must be a nonempty regular file smaller than \(maximumBytes / 1_048_576) MB: \(url.path)")
        }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw LADError.message("KiCad input exceeds its size limit: \(url.path)") }
        return data
    }

    private static func validatedSTEP(_ data: Data) throws {
        guard data.starts(with: Data("ISO-10303-21;".utf8)),
              String(decoding: data.suffix(512), as: UTF8.self).contains("END-ISO-10303-21;") else {
            throw LADError.message("KiCad did not return a complete STEP design.")
        }
    }

    static func standardLibraryPath(_ path: String) -> String? {
        guard let match = path.range(of: #"^\$\{(?:KICAD[0-9]+_3DMODEL_DIR|KISYS3DMOD)\}/"#, options: .regularExpression) else { return nil }
        let suffix = String(path[match.upperBound...])
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasSuffix(".3dshapes"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9_+().= -]+$"#, options: .regularExpression) != nil }),
              ["step", "stp", "wrl"].contains(URL(fileURLWithPath: suffix).pathExtension.lowercased()) else { return nil }
        // VRML has no exact solids; KiCad's documented substitution uses a STEP
        // model with the same stem. Recovery never substitutes another part.
        return suffix.lowercased().hasSuffix(".wrl") ? String(suffix.dropLast(4)) + ".step" : suffix
    }

    static func officialModelURL(_ libraryPath: String) -> URL? {
        guard standardLibraryPath("${KICAD10_3DMODEL_DIR}/" + libraryPath) == libraryPath else { return nil }
        var components = URLComponents()
        components.scheme = "https"; components.host = "gitlab.com"
        components.path = "/kicad/libraries/kicad-packages3d/-/raw/master/" + libraryPath
        return components.url
    }

    private static func environment(executable: URL, board: URL, folder: URL) -> [String: String] {
        let ambient = ProcessInfo.processInfo.environment
        var result = ambient.filter { $0.key.hasPrefix("KICAD") || $0.key == "KISYS3DMOD" }
        result.merge(["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                      "LANG": "en_US.UTF-8", "LC_ALL": "C", "TMPDIR": folder.path]) { _, new in new }
        return result
    }

    /// KiCad CLI initializes the global library manager before processing its
    /// arguments. PCM discovery can traverse ~/Documents (including iCloud),
    /// making a GUI-launched child wait for macOS privacy or cloud access even
    /// though STEP export needs no symbol or footprint library tables.
    /// KICAD_CONFIG_HOME and KICAD_DOCUMENTS_HOME are documented overrides:
    /// https://docs.kicad.org/10.0/en/kicad/kicad.html#_advanced_environment_variables
    private static func isolatedEnvironment(_ source: [String: String], executable: URL, folder: URL) throws -> [String: String] {
        let config = folder.appendingPathComponent("config", isDirectory: true)
        let documents = folder.appendingPathComponent("documents", isDirectory: true)
        let packages = folder.appendingPathComponent("packages", isDirectory: true)
        let version = settingsVersion(executable: executable) ?? "10.0"
        let settings = config.appendingPathComponent(version, isDirectory: true)
        for directory in [settings, documents, packages] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let applicationSettings = """
        {"meta":{"version":0},"pcm":{"check_for_updates":false,"lib_auto_add":false,"lib_auto_remove":false}}
        """
        try Data(applicationSettings.utf8).write(to: settings.appendingPathComponent("kicad.json"), options: .atomic)
        try Data("{\"environment\":{\"vars\":{}}}".utf8)
            .write(to: settings.appendingPathComponent("kicad_common.json"), options: .atomic)
        for (name, head) in [("fp-lib-table", "fp_lib_table"), ("sym-lib-table", "sym_lib_table"), ("design-block-lib-table", "design_block_lib_table")] {
            try Data("(\(head) (version 7))\n".utf8).write(to: settings.appendingPathComponent(name), options: .atomic)
        }
        var result = source
        result["KICAD_CONFIG_HOME"] = config.path
        result["KICAD_DOCUMENTS_HOME"] = documents.path
        // Also cover an externally configured package path. These variables
        // control library discovery; component model paths were resolved first.
        for key in source.keys where key.range(of: #"^KICAD[0-9]+_3RD_PARTY$"#, options: .regularExpression) != nil {
            result[key] = packages.path
        }
        let major = version.split(separator: ".").first ?? "10"
        result["KICAD\(major)_3RD_PARTY"] = packages.path
        return result
    }

    nonisolated private static func settingsVersion(executable: URL) -> String? {
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = values["CFBundleShortVersionString"] as? String else { return nil }
        let components = version.split(separator: ".")
        guard components.count >= 2, components.prefix(2).allSatisfy({ Int($0) != nil }) else { return nil }
        return components.prefix(2).joined(separator: ".")
    }

    nonisolated private static func modelVariables(executable: URL, board: URL, environment: [String: String]) -> [String: String] {
        var variables = environment
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let plist = contents.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plist),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let version = values["CFBundleShortVersionString"] as? String,
           let major = version.split(separator: ".").first {
            let library = contents.appendingPathComponent("SharedSupport/3dmodels")
            let key = "KICAD\(major)_3DMODEL_DIR"
            if variables[key] == nil, FileManager.default.fileExists(atPath: library.path) { variables[key] = library.path }
            let configRoot = environment["KICAD_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/kicad", isDirectory: true)
            let config = configRoot.appendingPathComponent("\(major).0/kicad_common.json")
            if let data = try? readSource(config, maximumBytes: 4 * 1024 * 1024),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let env = json["environment"] as? [String: Any], let vars = env["vars"] as? [String: String] {
                // External environment overrides user settings, while user
                // settings override KiCad's built-in installation defaults.
                for (key, value) in vars where environment[key] == nil { variables[key] = value }
            }
        }
        let project = board.deletingPathExtension().appendingPathExtension("kicad_pro")
        if let data = try? readSource(project, maximumBytes: 20 * 1024 * 1024),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let vars = json["text_variables"] as? [String: String] { variables.merge(vars) { _, new in new } }
        variables["KIPRJMOD"] = board.deletingLastPathComponent().path
        return variables
    }

    private static func expand(_ value: String, variables: [String: String]) -> String {
        var expanded = value
        for _ in 0..<8 {
            let previous = expanded
            for (key, replacement) in variables { expanded = expanded.replacingOccurrences(of: "${\(key)}", with: replacement) }
            if previous == expanded { break }
        }
        return expanded
    }
}

/// Only assigned, visible footprint models are audited. This parser reads KiCad
/// strings and balanced lists; it never interprets board data as commands.
private struct KiCadBoardModels: Sendable {
    struct Model: Sendable { let reference: String; let path: String }
    let models: [Model]
    let thickness: Double?

    init(text: String) throws {
        var reader = KiCadSExpressionReader(bytes: Array(text.utf8))
        let board = try reader.read(depth: 0)
        guard board.head == "kicad_pcb" else { throw LADError.message("The selected file is not a KiCad PCB document.") }
        var found: [Model] = []
        for footprint in board.children where footprint.head == "footprint" || footprint.head == "module" {
            let property = footprint.children.first { $0.head == "property" && $0.atom(at: 1) == "Reference" }
            let legacyText = footprint.children.first { $0.head == "fp_text" && $0.atom(at: 1) == "reference" }
            let reference = property?.atom(at: 2) ?? legacyText?.atom(at: 2) ?? "Unknown component"
            for model in footprint.children where model.head == "model" {
                guard let path = model.atom(at: 1),
                      !model.children.contains(where: { $0.head == "hide" && $0.atom(at: 1) == "yes" }) else { continue }
                found.append(Model(reference: reference, path: path))
            }
        }
        models = found
        let general = board.children.first { $0.head == "general" }
        let thicknessValue = general?.children.first { $0.head == "thickness" }?.atom(at: 1)
        thickness = thicknessValue.flatMap(Double.init)
    }
}

private indirect enum KiCadSExpression {
    case atom(String), list([KiCadSExpression])
    var children: [KiCadSExpression] { if case .list(let values) = self { return values }; return [] }
    var atoms: [String] { children.compactMap { if case .atom(let value) = $0 { return value }; return nil } }
    func atom(at index: Int) -> String? {
        guard children.indices.contains(index), case .atom(let value) = children[index] else { return nil }
        return value
    }
    var head: String? { atom(at: 0) }
}

private struct KiCadSExpressionReader {
    let bytes: [UInt8]
    var offset = 0
    var count = 0
    mutating func read(depth: Int) throws -> KiCadSExpression {
        count += 1
        guard depth < 128, count < 2_000_000 else { throw LADError.message("KiCad board structure exceeds supported limits.") }
        while offset < bytes.count, bytes[offset] <= 32 { offset += 1 }
        guard offset < bytes.count else { throw LADError.message("The KiCad board document is incomplete.") }
        if bytes[offset] == 40 {
            offset += 1
            var values: [KiCadSExpression] = []
            while true {
                while offset < bytes.count, bytes[offset] <= 32 { offset += 1 }
                guard offset < bytes.count else { throw LADError.message("The KiCad board document has an unclosed list.") }
                if bytes[offset] == 41 { offset += 1; return .list(values) }
                values.append(try read(depth: depth + 1))
            }
        }
        var token: [UInt8] = []
        if bytes[offset] == 34 {
            offset += 1
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 { return .atom(String(decoding: token, as: UTF8.self)) }
                if byte == 92, offset < bytes.count { token.append(bytes[offset]); offset += 1 }
                else { token.append(byte) }
            }
            throw LADError.message("The KiCad board document has an unclosed string.")
        }
        while offset < bytes.count, bytes[offset] > 32, bytes[offset] != 40, bytes[offset] != 41 {
            token.append(bytes[offset]); offset += 1
        }
        guard !token.isEmpty else { throw LADError.message("The KiCad board document contains an unexpected delimiter.") }
        return .atom(String(decoding: token, as: UTF8.self))
    }
}

private final class KiCadDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "gitlab.com" ? request : nil)
    }
}

private enum KiCadModelDownload {
    static func fetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: KiCadDownloadDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 32 * 1024 * 1024 else {
            throw LADError.message("The official KiCad component model could not be downloaded.")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= 32 * 1024 * 1024 else { throw LADError.message("KiCad component model download exceeds 32 MB.") }
        }
        return data
    }
}

private final class KiCadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(value)
        if data.count > 65_536 { data.removeFirst(data.count - 65_536) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class KiCadProcessJob: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private let stdout = KiCadLog(), stderr = KiCadLog()
    private let timeout: TimeInterval
    private var cancelled = false, finished = false, launched = false
    var diagnostics: String { [stdout.text, stderr.text].filter { !$0.isEmpty }.joined(separator: "\n") }

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval) {
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardInput = FileHandle.nullDevice
        self.timeout = timeout
    }

    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let output = Pipe(), error = Pipe()
                process.standardOutput = output; process.standardError = error
                let readers = DispatchGroup()
                do {
                    lock.lock()
                    if cancelled { finished = true; lock.unlock(); throw CancellationError() }
                    do { try process.run(); launched = true; lock.unlock() }
                    catch { finished = true; lock.unlock(); throw error }
                    for (pipe, log) in [(output, stdout), (error, stderr)] {
                        try? pipe.fileHandleForWriting.close()
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            defer { readers.leave() }
                            while let data = try? pipe.fileHandleForReading.read(upToCount: 8_192), !data.isEmpty { log.append(data) }
                        }
                    }
                    let deadline = Date().addingTimeInterval(max(0.01, timeout))
                    var timedOut = false
                    while process.isRunning {
                        if !timedOut, Date() >= deadline { timedOut = true; cancel() }
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    process.waitUntilExit()
                    _ = readers.wait(timeout: .now() + 2)
                    lock.lock(); finished = true; let didCancel = cancelled; lock.unlock()
                    if timedOut { throw LADError.message("KiCad exceeded its \(Int(timeout))-second export limit. Check the board and referenced 3D models, then try again.") }
                    if didCancel { throw CancellationError() }
                    continuation.resume(returning: process.terminationStatus)
                } catch { continuation.resume(throwing: error) }
                try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close()
                try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true
        let running = launched && !finished && process.isRunning
        let pid = running ? process.processIdentifier : 0
        if running { process.terminate() }
        lock.unlock()
        if pid > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); defer { lock.unlock() }
                if !finished && process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
    }
}
