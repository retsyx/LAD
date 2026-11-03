import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A coordinated read/write baseline. Never stored in the portable package.
struct ProjectFileOrigin: Sendable, Equatable {
    let readID = UUID()
    var url: URL
    var sha256: String

    init(url: URL, data: Data) {
        self.url = Self.canonicalURL(url)
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ other: URL) -> Bool {
        other.isFileURL && url.path == Self.canonicalURL(other).path
    }

    /// A package is presented as a document. Keep a stable URL spelling when
    /// Foundation discovers that its on-disk representation is a directory.
    static func documentURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
    }

    static func canonicalURL(_ url: URL) -> URL {
        documentURL(url.standardizedFileURL.resolvingSymlinksInPath())
    }
}

struct ProjectSaveConflict: LocalizedError, Sendable, Equatable {
    var file: ProjectFileOrigin
    var errorDescription: String? {
        "The design changed outside LAD. Overwrite the file or save with a different name."
    }
}

@MainActor
enum ProjectSaveConflictPrompt {
    enum Choice { case overwrite, saveAs(URL), cancel }

    static func choose(_ conflict: ProjectSaveConflict, in window: NSWindow) async -> Choice {
        let alert = NSAlert()
        alert.messageText = "“\(conflict.file.url.lastPathComponent)” changed outside LAD."
        alert.informativeText = "Overwrite it with your open design, or save your design with a different name."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Save with Different Name…")
        alert.addButton(withTitle: "Cancel")
        let response = await alert.beginSheetModal(for: window)
        if response == .alertFirstButtonReturn { return .overwrite }
        guard response == .alertSecondButtonReturn else { return .cancel }
        let panel = NSSavePanel()
        panel.title = "Save Design with Different Name"
        panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .package]
        panel.directoryURL = conflict.file.url.deletingLastPathComponent()
        panel.nameFieldStringValue = conflict.file.url.deletingPathExtension().lastPathComponent + " copy.lad"
        let result = await panel.beginSheetModal(for: window)
        guard result == .OK, let url = panel.url else { return .cancel }
        return .saveAs(url)
    }
}
