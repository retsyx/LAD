import Foundation
import Darwin

/// Serializes complete projects into the visible iCloud Drive LAD folder.
/// All coordination and potentially large archive work stays off the main actor.
actor ProjectAutosaveStore {
    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LAD", isDirectory: true)
    }

    nonisolated let managedDirectory: URL
    private let requiresCloudDrive: Bool
    private var saved: [UUID: SavedFile] = [:]

    private struct Fingerprint: Equatable {
        var size: UInt64
        var modified: Date
        var inode: UInt64
    }

    private struct SavedFile {
        var url: URL
        var sequence: Int
        var fingerprint: Fingerprint
    }

    /// Bind the ownership fingerprint to the bytes written while the
    /// coordinator still excludes other writers.
    private struct WriteReceipt {
        var url: URL
        var fingerprint: Fingerprint
    }

    init(rootDirectory: URL? = nil) {
        managedDirectory = (rootDirectory ?? Self.defaultDirectory).standardizedFileURL
        requiresCloudDrive = rootDirectory == nil
    }

    func write(project: LADProject, projectID: UUID, title: String, sequence: Int, preferredURL: URL? = nil, preferExactName: Bool = false) throws -> URL {
        try prepareDirectory()
        defer { if requiresCloudDrive { ProjectFolderIcon.apply(to: managedDirectory) } }
        if let previous = saved[projectID], sequence <= previous.sequence {
            guard FileManager.default.fileExists(atPath: previous.url.path) else { throw changedExternally() }
            return previous.url
        }
        var portable = project
        portable.projectID = projectID
        let data = try ProjectStore.encode(portable)
        let base: String
        if let name = portable.projectName {
            try ProjectNaming.validateSavedName(name)
            base = name
        } else { base = Self.filenameStem(title) }
        let previous = saved[projectID]
        let preferred = preferredURL.flatMap { isManaged($0) ? $0.standardizedFileURL : nil }
        var source = [previous?.url, preferred].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let proposed = source,
           previous?.url.standardizedFileURL != proposed.standardizedFileURL || (try? Self.fingerprint(proposed)) != previous?.fingerprint {
            source = try ownedSource(proposed, project: portable, projectID: projectID, previous: previous)
        }

        // A deliberate inline rename can reclaim its exact name after a
        // collision disappears. Ordinary autosaves retain a stable suffix.
        if preferExactName, let source {
            let destination = managedDirectory.appendingPathComponent(base).appendingPathExtension("lad")
            if let result = try writeCandidate(data, project: portable, projectID: projectID, source: source, destination: destination, previous: previous) {
                remember(result, projectID: projectID, sequence: sequence)
                return result.url
            }
        }

        // Retain an existing collision suffix rather than renaming a project
        // every time another similarly titled project disappears.
        if let source, let matchingName = Self.matchingStem(source, stem: base) {
            let destination = managedDirectory.appendingPathComponent(matchingName).appendingPathExtension("lad")
            if let result = try writeCandidate(data, project: portable, projectID: projectID, source: source, destination: destination, previous: previous) {
                remember(result, projectID: projectID, sequence: sequence)
                return result.url
            }
        }
        for index in 1...10_000 {
            let name = index == 1 ? base : "\(base) (\(index))"
            let destination = managedDirectory.appendingPathComponent(name).appendingPathExtension("lad")
            if let result = try writeCandidate(data, project: portable, projectID: projectID, source: source, destination: destination, previous: previous) {
                remember(result, projectID: projectID, sequence: sequence)
                return result.url
            }
        }
        throw LADError.message("Could not choose an available filename in iCloud Drive/LAD.")
    }

    /// Restore the exact last project, including a renamed file after a crash.
    /// Without a prior identity, the newest cloud project is the initial choice.
    func restoreRecent(preferredURL: URL?, projectID: UUID?) throws -> (project: LADProject, url: URL)? {
        try prepareDirectory()
        defer { if requiresCloudDrive { ProjectFolderIcon.apply(to: managedDirectory) } }
        if let preferredURL, isManaged(preferredURL), FileManager.default.fileExists(atPath: preferredURL.path) {
            let snapshot = try Self.readSnapshot(from: preferredURL)
            if projectID == nil || snapshot.project.projectID == projectID {
                if let id = snapshot.project.projectID { saved[id] = SavedFile(url: preferredURL, sequence: -1, fingerprint: snapshot.fingerprint) }
                return (snapshot.project, preferredURL)
            }
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let candidates = try FileManager.default.contentsOfDirectory(at: managedDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "lad" }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
        for url in candidates {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            do {
                let snapshot = try Self.readSnapshot(from: url)
                guard projectID == nil || snapshot.project.projectID == projectID else { continue }
                if let id = snapshot.project.projectID { saved[id] = SavedFile(url: url, sequence: -1, fingerprint: snapshot.fingerprint) }
                return (snapshot.project, url)
            } catch {
                // A known identity must never be replaced by an unrelated
                // project merely because its own file cannot be read.
                if projectID == nil { throw error }
            }
        }
        if projectID != nil || preferredURL != nil {
            throw LADError.message("The last LAD design could not be found in iCloud Drive/LAD. Open its .lad file to continue.")
        }
        return nil
    }

    nonisolated static func readProject(from url: URL) throws -> LADProject {
        try readSnapshot(from: url).project
    }

    /// Explicit Save As uses the same writer so it cannot race an autosave to
    /// an open cloud project. Replacement here is authorized by the save panel.
    func writeCopy(_ project: LADProject, to url: URL, preserving sourceURL: URL? = nil, projectID sourceID: UUID? = nil) throws {
        func protectSource(at destination: URL) throws {
            let matchesPath = sourceURL.map {
                $0.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
            } ?? false
            let matchesIdentity = sourceID.map { id in
                (try? ProjectStore.read(from: destination).projectID) == id
            } ?? false
            guard !matchesPath, !matchesIdentity else {
                throw LADError.message("Choose a different filename to keep the open design’s complete history.")
            }
        }
        try protectSource(at: url)
        let data = try ProjectStore.encode(project)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<WriteReceipt, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writable in
            outcome = Result {
                try protectSource(at: writable)
                try data.write(to: writable, options: .atomic)
                return WriteReceipt(url: writable, fingerprint: try Self.fingerprint(writable))
            }
        }
        guard let outcome else { throw coordinationError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError) }
        let written = try outcome.get()
        for id in Array(saved.keys) where saved[id]?.url.standardizedFileURL == written.url.standardizedFileURL {
            if id == project.projectID, let sequence = saved[id]?.sequence { remember(written, projectID: id, sequence: sequence) }
            else { saved.removeValue(forKey: id) }
        }
    }

    private func prepareDirectory() throws {
        let parent = managedDirectory.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw LADError.message(requiresCloudDrive
                ? "iCloud Drive is unavailable. Enable iCloud Drive on this Mac so LAD can save your design."
                : "The design save directory is unavailable.")
        }
        if !FileManager.default.fileExists(atPath: managedDirectory.path) {
            do { try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: false) }
            catch {
                guard FileManager.default.fileExists(atPath: managedDirectory.path) else { throw error }
            }
        }
        let values = try managedDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LADError.message("The LAD save location must be a directory in iCloud Drive.")
        }
    }

    private func writeCandidate(_ data: Data, project: LADProject, projectID: UUID, source: URL?, destination: URL, previous: SavedFile?) throws -> WriteReceipt? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<WriteReceipt?, Error>?
        let moving = source.map { $0.standardizedFileURL != destination.standardizedFileURL } ?? false
        let accessor: (URL?, URL) -> Void = { old, target in
            outcome = Result {
                guard self.isManaged(target), old.map(self.isManaged) ?? true else {
                    throw LADError.message("The iCloud design location changed while saving. Open the design again.")
                }
                let manager = FileManager.default
                if manager.fileExists(atPath: target.path), target.standardizedFileURL != old?.standardizedFileURL {
                    // Existing files at a new title are collisions, even when
                    // they happen to contain a copy of the same project ID.
                    if moving {
                        // On a case-insensitive volume, the requested spelling
                        // can resolve to this very file. A different inode is
                        // always a collision, even if it has the same ID/data.
                        guard let old, try Self.isCaseAlias(old, target) else { return nil }
                    } else {
                        guard try self.canUpdate(target, project: project, projectID: projectID, previous: previous) else { return nil }
                    }
                }
                if let old, manager.fileExists(atPath: old.path) {
                    guard try self.canUpdate(old, project: project, projectID: projectID, previous: previous) else { return nil }
                    try data.write(to: old, options: .atomic)
                    if moving {
                        coordinator.item(at: old, willMoveTo: target)
                        // RENAME_EXCL changes filename case on APFS and makes
                        // the final move itself refuse a newly appeared file.
                        guard renamex_np(old.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: target.path])
                        }
                        coordinator.item(at: old, didMoveTo: target)
                        return WriteReceipt(url: target, fingerprint: try Self.fingerprint(target))
                    }
                    return WriteReceipt(url: old, fingerprint: try Self.fingerprint(old))
                }
                try data.write(to: target, options: .atomic)
                return WriteReceipt(url: target, fingerprint: try Self.fingerprint(target))
            }
        }
        if moving, let source {
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &coordinationError) {
                accessor($0, $1)
            }
        } else {
            coordinator.coordinate(writingItemAt: destination, options: [], error: &coordinationError) { accessor(source, $0) }
        }
        if let outcome {
            return try outcome.get()
        }
        throw coordinationError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
    }

    private func canUpdate(_ url: URL, project: LADProject, projectID: UUID, previous: SavedFile?) throws -> Bool {
        guard let current = try? Self.fingerprint(url) else { return false }
        if let previous, previous.url.standardizedFileURL == url.standardizedFileURL, previous.fingerprint == current { return true }
        let existing: LADProject
        do { existing = try ProjectStore.read(from: url) }
        catch { return false }
        guard existing.projectID == projectID else { return false }
        let incomingMessages = Dictionary(uniqueKeysWithValues: project.messages.map { ($0.id, $0) })
        let incomingRevisions = Dictionary(uniqueKeysWithValues: project.revisions.map { ($0.id, $0) })
        guard existing.messages.allSatisfy({ old in
            guard let new = incomingMessages[old.id], old.role == new.role, old.content == new.content else { return false }
            return (old.attachments ?? []).allSatisfy { attached in (new.attachments ?? []).contains { $0.path == attached.path && $0.sha256 == attached.sha256 } }
        }), existing.revisions.allSatisfy({ incomingRevisions[$0.id]?.model == $0.model }) else { throw changedExternally() }
        return true
    }

    private func ownedSource(_ url: URL, project: LADProject, projectID: UUID, previous: SavedFile?) throws -> URL? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<URL?, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            outcome = Result {
                guard self.isManaged(readable), try self.canUpdate(readable, project: project, projectID: projectID, previous: previous) else { return nil }
                return readable
            }
        }
        if let outcome { return try outcome.get() }
        throw coordinationError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
    }

    private func remember(_ receipt: WriteReceipt, projectID: UUID, sequence: Int) {
        saved[projectID] = SavedFile(url: receipt.url, sequence: sequence, fingerprint: receipt.fingerprint)
    }

    private func isManaged(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "lad" &&
            url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == managedDirectory.resolvingSymlinksInPath()
    }

    private func changedExternally() -> LADError {
        .message("The iCloud design changed outside LAD. Open the latest .lad file before continuing, or save a separate copy.")
    }

    private nonisolated static func readSnapshot(from url: URL) throws -> (project: LADProject, fingerprint: Fingerprint) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<(project: LADProject, fingerprint: Fingerprint), Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            outcome = Result { (try ProjectStore.read(from: readable), try fingerprint(readable)) }
        }
        if let outcome { return try outcome.get() }
        throw coordinationError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
    }

    private nonisolated static func fingerprint(_ url: URL) throws -> Fingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LADError.message("The design save location is not a regular file.")
        }
        return Fingerprint(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                           modified: attributes[.modificationDate] as? Date ?? .distantPast,
                           inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private nonisolated static func filenameStem(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_()"))
        let clean = title.precomposedStringWithCanonicalMapping.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let words = clean.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var result = String(words.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        // APFS limits each filename by UTF-8 bytes, not visible characters.
        // Keep room for the collision suffix and extension without splitting
        // a Unicode character or producing an invalid filesystem name.
        while result.utf8.count > 220 { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Untitled design" : result
    }

    private nonisolated static func matchingStem(_ url: URL, stem: String) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        if name.compare(stem, options: .caseInsensitive) == .orderedSame { return stem }
        guard name.hasSuffix(")"), let suffix = name.range(of: " (", options: .backwards),
              String(name[..<suffix.lowerBound]).compare(stem, options: .caseInsensitive) == .orderedSame,
              Int(name[suffix.upperBound...].dropLast()).map({ $0 >= 2 }) == true else { return nil }
        return stem + String(name[suffix.lowerBound...])
    }

    private nonisolated static func isCaseAlias(_ source: URL, _ destination: URL) throws -> Bool {
        guard source.lastPathComponent.compare(destination.lastPathComponent, options: .caseInsensitive) == .orderedSame else { return false }
        guard let first = try? fingerprint(source), let second = try? fingerprint(destination),
              first.inode != 0, first.inode == second.inode else { return false }
        // Distinct hard links on a case-sensitive volume are still separate
        // directory entries and must be treated as occupied destinations.
        let names = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        return names.contains(source.lastPathComponent) && !names.contains(destination.lastPathComponent)
    }
}
