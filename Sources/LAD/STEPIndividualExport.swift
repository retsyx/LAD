import Darwin
import Foundation

enum STEPIndividualExport {
    struct Part: Equatable, Sendable {
        let name: String
        let solidIndices: [Int]
        let fileName: String

        init(name: String, solidIndices: [Int]) {
            self.init(name: name, solidIndices: solidIndices,
                      fileName: "\(STEPIndividualExport.filenameStem(name, fallback: "Part")).step")
        }

        fileprivate init(name: String, solidIndices: [Int], fileName: String) {
            self.name = name
            self.solidIndices = solidIndices
            self.fileName = fileName
        }
    }

    /// Use physical ownership, rather than folder descendants, so each solid
    /// occurs once and current tree names follow the captured export selection.
    static func parts(in nodes: [PartNode], selected: Set<Int>? = nil, solidCount: Int) -> [Part] {
        let available = Set(0..<max(0, solidCount))
        let requested = selected.map { $0.intersection(available) } ?? available
        var claimed = Set<Int>()
        var entries: [(name: String, indices: [Int])] = []
        for node in nodes.flatMap(\.flattened) {
            let indices = Set(node.solidIndices).intersection(requested).subtracting(claimed).sorted()
            guard !indices.isEmpty else { continue }
            entries.append((node.name, indices))
            claimed.formUnion(indices)
        }
        for index in requested.subtracting(claimed).sorted() {
            entries.append(("Part \(index + 1)", [index]))
        }

        let stems = entries.map { filenameStem($0.name, fallback: "Part") }
        let reserved = Set(stems.map(collisionKey))
        var used = Set<String>()
        return zip(entries, stems).map { entry, stem in
            var candidate = stem
            if used.contains(collisionKey(candidate)) {
                var suffix = 2
                repeat {
                    candidate = "\(stem) (\(suffix))"
                    suffix += 1
                } while used.contains(collisionKey(candidate)) || reserved.contains(collisionKey(candidate))
            }
            used.insert(collisionKey(candidate))
            return Part(name: entry.name, solidIndices: entry.indices, fileName: "\(candidate).step")
        }
    }

    static func folderName(for projectTitle: String) -> String {
        var title = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".lad") { title.removeLast(4) }
        return filenameStem(title, fallback: "Design")
    }

    /// Publish only complete exports. Approved replacements atomically exchange
    /// the finished folder with the old item before cleaning up its contents.
    static func write(_ data: [Data], parts: [Part], to folder: URL, replaceExisting: Bool = false) throws {
        try Task.checkCancellation()
        guard folder.isFileURL, !parts.isEmpty, parts.count == data.count,
              !folder.lastPathComponent.isEmpty, ![".", "..", "/"].contains(folder.lastPathComponent) else {
            throw LADError.message("The individual part export has an invalid destination or file list.")
        }
        var names = Set<String>()
        for part in parts {
            guard validFileName(part.fileName), names.insert(collisionKey(part.fileName)).inserted else {
                throw LADError.message("The individual part export contains invalid or duplicate filenames.")
            }
        }
        let destination = folder.standardizedFileURL
        var information = stat()
        if lstat(destination.path, &information) == 0 {
            guard replaceExisting else { throw destinationExists(destination) }
        } else {
            guard errno == ENOENT else { throw posixError(at: destination) }
        }

        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".lad-step-export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        for (part, bytes) in zip(parts, data) {
            try Task.checkCancellation()
            try bytes.write(to: staging.appendingPathComponent(part.fileName), options: .withoutOverwriting)
        }
        while true {
            try Task.checkCancellation()
            if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
            guard errno == EEXIST || errno == ENOTEMPTY else { throw posixError(at: destination) }
            guard replaceExisting else { throw destinationExists(destination) }
            if renamex_np(staging.path, destination.path, UInt32(RENAME_SWAP)) == 0 { return }
            // If the approved item disappeared, try publishing into its empty
            // path. Other errors leave the original item and staging untouched.
            guard errno == ENOENT else { throw posixError(at: destination) }
        }
    }

    static func filenameStem(_ name: String, fallback: String) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        var stem = name.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { unsafe.contains($0) ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading dots hide files in Finder; all-dot names must not become paths.
        let hiddenPrefix = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        while let first = stem.unicodeScalars.first, hiddenPrefix.contains(first) { stem.removeFirst() }
        // Leave room for a collision suffix and extension within APFS's limit.
        while stem.utf8.count > 220 { stem.removeLast() }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? fallback : stem
    }

    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name.hasSuffix(".step") &&
        !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":"
        }) && !name.hasPrefix(".")
    }

    private static func destinationExists(_ url: URL) -> LADError {
        .message("“\(url.lastPathComponent)” already exists. Choose a different export folder.")
    }

    private static func posixError(at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
