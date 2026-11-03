import AppKit
import Darwin
import Foundation

/// A fresh directory identity supplied by the autosave actor's ordinary
/// location validation. Cache optional branding, never filesystem validity.
struct ProjectFolderIdentity: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64

    init?(attributes: [FileAttributeKey: Any]) {
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              inode.uint64Value != 0 else { return nil }
        self.device = device.uint64Value
        self.inode = inode.uint64Value
    }
}

/// The ordinary iCloud folder needs custom Finder metadata; .lad documents use
/// the application's registered document icon and require no per-file writes.
enum ProjectFolderIcon {
    private struct Key: Hashable, Sendable {
        var path: String
        var identity: ProjectFolderIdentity
    }
    private static let lock = NSLock()
    private static var completed: Set<Key> = []
    private static var pending: Set<Key> = []

    private static func reserve(_ key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed.contains(key), !pending.contains(key) else { return false }
        pending.insert(key)
        return true
    }

    private static func finish(_ key: Key, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        pending.remove(key)
        if succeeded { completed.insert(key) }
    }

    static func apply(to url: URL, identity: ProjectFolderIdentity?,
                      schedule: (@escaping @MainActor () -> Void) -> Void = { work in Task { @MainActor in work() } },
                      perform: @escaping @MainActor (URL, ProjectFolderIdentity?) -> Bool = {
                          ProjectFolderIconCoordinator.shared.apply(to: $0, expectedIdentity: $1)
                      }) {
        let key = identity.map { Key(path: url.standardizedFileURL.path, identity: $0) }
        if let key, !reserve(key) { return }
        schedule {
            var succeeded = false
            defer { if let key { finish(key, succeeded: succeeded) } }
            // Recheck the actual directory on the main actor before AppKit:
            // it may have been replaced after the writer released coordination.
            succeeded = perform(url, identity)
        }
    }
}

/// NSWorkspace's resource manager is process-wide. Serialize its use on the
/// main actor, without waiting from autosave actors or coordinated accessors.
@MainActor
final class ProjectFolderIconCoordinator {
    static let shared = ProjectFolderIconCoordinator { url in
        guard let iconURL = Bundle.main.url(forResource: "LADFolder", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return false }
        return NSWorkspace.shared.setIcon(icon, forFile: url.path, options: [])
    }

    private let setIcon: @MainActor (URL) -> Bool
    private let readCustomIcon: @MainActor (URL) -> Bool?
    private var completed: Set<ProjectFolderIdentity> = []

    init(readCustomIcon: @escaping @MainActor (URL) -> Bool? = { ProjectFolderIconCoordinator.hasCustomIcon(at: $0) },
         setIcon: @escaping @MainActor (URL) -> Bool) {
        self.readCustomIcon = readCustomIcon
        self.setIcon = setIcon
    }

    @discardableResult
    func apply(to url: URL, expectedIdentity: ProjectFolderIdentity? = nil) -> Bool {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        let identity = ProjectFolderIdentity(attributes: attributes)
        if let expectedIdentity, identity != expectedIdentity { return false }
        if let identity, completed.contains(identity) { return true }
        guard let hasIcon = readCustomIcon(url) else { return false }
        guard hasIcon || setIcon(url.standardizedFileURL) else { return false }
        if let identity { completed.insert(identity) }
        return true
    }

    private static func hasCustomIcon(at url: URL) -> Bool? {
        // NSURLCustomIconKey is documented as unimplemented. FinderInfo's
        // big-endian flags at bytes 8–9 contain kHasCustomIcon (0x0400), and
        // persist across launches. Preserve any existing icon, including one
        // chosen by the user; unreadable metadata must not authorize a write.
        var info = [UInt8](repeating: 0, count: 32)
        let count = info.withUnsafeMutableBytes {
            getxattr(url.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        if count < 0 { return errno == ENOATTR ? false : nil }
        guard count >= 10 else { return nil }
        let flags = UInt16(info[8]) << 8 | UInt16(info[9])
        return flags & 0x0400 != 0
    }
}
