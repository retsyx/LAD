import CryptoKit
import Foundation

/// Session copies of a design's validated geometry inputs that a build worker
/// already imported, keyed by the input's exact bytes, its format and the CAD
/// runtime. A later build stages the copy beside the unchanged original, so
/// the worker does not translate that input again. Copies are temporary,
/// never saved, and their leased scratch directory is removed once LAD exits.
final class CADValidatedInputCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var digest: String
        var format: String
        var runtime: String

        init(data: Data, format: String, runtime: String) {
            digest = SHA256.hexDigest(data)
            self.format = format
            self.runtime = runtime
        }
    }

    private struct Entry {
        var name: String
        var bytes: Int
        var used: UInt64
    }

    static let shared = CADValidatedInputCache()
    /// The worker names each copy after its input: `input-000.validated.brep`.
    static let suffix = ".validated.brep"
    private static let marker = Data("DBRep_DrawableShape\n".utf8)

    private let lock = NSLock()
    private let root: URL
    private let maximumBytes: Int
    private var storage: EngineBuildArtifacts?
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var staged = 0

    init(root: URL = FileManager.default.temporaryDirectory, maximumBytes: Int = 2_147_483_648) {
        self.root = root
        self.maximumBytes = maximumBytes
    }

    /// Copies staged into builds, for regression tests.
    var stagedCopies: Int { lock.withLock { staged } }

    /// Copy the validated copy for `key` to `destination`, if one is kept.
    func stage(_ key: Key, to destination: URL) -> Bool {
        guard let source = lock.withLock({ () -> URL? in
            guard let folder = storage?.folder, var entry = entries[key] else { return nil }
            clock += 1
            entry.used = clock
            entries[key] = entry
            return folder.appendingPathComponent(entry.name)
        }) else { return false }
        // APFS clones the copy; the build receives its own single-link file.
        do { try FileManager.default.copyItem(at: source, to: destination) } catch {
            lock.withLock { if entries[key]?.name == source.lastPathComponent { entries[key] = nil } }
            return false
        }
        lock.withLock { staged += 1 }
        return true
    }

    /// Keep the copy a worker wrote for a newly imported input in `folder`.
    func store(_ key: Key, from produced: URL, in folder: URL) {
        guard let file = try? EngineArtifact.boundaries(produced, in: folder, headerBytes: Self.marker.count),
              file.header == Self.marker, file.size <= maximumBytes else { return }
        lock.withLock {
            guard entries[key] == nil else { return }
            do {
                if storage == nil {
                    storage = try EngineBuildArtifacts.create(in: root, token: UUID(), containsSTEP: false)
                }
                guard let storage else { return }
                let name = UUID().uuidString + Self.suffix
                try FileManager.default.moveItem(at: produced, to: storage.folder.appendingPathComponent(name))
                clock += 1
                entries[key] = Entry(name: name, bytes: file.size, used: clock)
                var total = entries.values.reduce(0) { $0 + $1.bytes }
                while total > maximumBytes, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
                    entries[oldest.key] = nil
                    total -= oldest.value.bytes
                    try? FileManager.default.removeItem(at: storage.folder.appendingPathComponent(oldest.value.name))
                }
            } catch {
                return
            }
        }
    }
}
