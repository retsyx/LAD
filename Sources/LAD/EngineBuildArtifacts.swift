import Darwin
import Foundation

// Darwin's Swift overlay exposes struct flock under this name, hiding the
// BSD function. Keep the binding local to the scratch-directory lease.
@_silgen_name("flock")
private func lockBuildFile(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Shared by copies of a session preview. The last copy releases its native
/// files; recipes and archives never retain this owner or its lease.
final class EngineBuildArtifacts: @unchecked Sendable {
    let folder: URL
    let containsSTEP: Bool
    private let lease: FileHandle
    private static let leaseName = ".lad-build-lease"
    private static let leaseContents = Data("LAD CAD scratch directory v1\n".utf8)
    private static let cleanupQueue = DispatchQueue(label: "LAD.CADArtifactCleanup", qos: .utility)
    private static let initialCleanup: Void = {
        let root = FileManager.default.temporaryDirectory
        cleanupQueue.async { _ = removeAbandoned(in: root) }
    }()

    private init(folder: URL, containsSTEP: Bool, lease: FileHandle) {
        self.folder = folder
        self.containsSTEP = containsSTEP
        self.lease = lease
    }

    static func create(in root: URL, token: UUID, containsSTEP: Bool) throws -> EngineBuildArtifacts {
        _ = initialCleanup
        let scratch = root.appendingPathComponent("LAD-build-\(token.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: scratch) } }
        let folder = try EngineArtifact.canonicalDirectory(scratch)
        let descriptor = Darwin.open(folder.appendingPathComponent(leaseName).path,
                                     O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LADError.message("Could not reserve the CAD build directory.") }
        let lease = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard lockBuildFile(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                throw LADError.message("Could not reserve the CAD build directory.")
            }
            try lease.write(contentsOf: leaseContents)
        } catch {
            try? lease.close()
            throw error
        }
        succeeded = true
        return EngineBuildArtifacts(folder: folder, containsSTEP: containsSTEP, lease: lease)
    }

    /// stdin carries an otherwise unused duplicate of the lease into the
    /// worker. Even if LAD crashes, the live worker keeps cleanup locked out.
    func workerInput() throws -> FileHandle {
        let descriptor = Darwin.fcntl(lease.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard descriptor >= 0 else { throw LADError.message("Could not reserve the CAD worker's build directory.") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        let folder = folder
        try? lease.close()
        Self.cleanupQueue.async { _ = Self.removeIfAbandoned(folder) }
    }

    /// Only marked, unlocked build directories are eligible. Old unleased
    /// directories cannot prove that another running LAD still needs them and
    /// are deliberately left for a separately verified migration cleanup.
    @discardableResult
    static func removeAbandoned(in root: URL) -> Int {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        return children.reduce(0) { $0 + (removeIfAbandoned($1) ? 1 : 0) }
    }

    private static func removeIfAbandoned(_ folder: URL) -> Bool {
        let name = folder.lastPathComponent
        guard name.hasPrefix("LAD-build-"), UUID(uuidString: String(name.dropFirst(10))) != nil else { return false }
        let directory = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return false }
        defer { Darwin.close(directory) }
        var directoryInfo = stat()
        guard Darwin.fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o777 == 0o700 else { return false }
        let descriptor = Darwin.openat(directory, leaseName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size == leaseContents.count,
              lockBuildFile(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        var contents = Data(count: leaseContents.count)
        let count = contents.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == leaseContents.count, contents == leaseContents else { return false }
        // Refuse a directory that was renamed/replaced while opening its lease.
        var current = stat()
        guard Darwin.lstat(folder.path, &current) == 0,
              current.st_dev == directoryInfo.st_dev, current.st_ino == directoryInfo.st_ino else { return false }
        do { try FileManager.default.removeItem(at: folder); return true }
        catch { return false }
    }
}
