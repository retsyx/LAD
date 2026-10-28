import AppKit
import Darwin
import Foundation

/// The ordinary iCloud folder needs custom Finder metadata; .lad documents use
/// the application's registered document icon and require no per-file writes.
enum ProjectFolderIcon {
    static func apply(to url: URL) {
        Task { @MainActor in ProjectFolderIconCoordinator.shared.apply(to: url) }
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

    init(setIcon: @escaping @MainActor (URL) -> Bool) {
        self.setIcon = setIcon
    }

    func apply(to url: URL) {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              Self.hasCustomIcon(at: url) == false else { return }
        _ = setIcon(url.standardizedFileURL)
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
