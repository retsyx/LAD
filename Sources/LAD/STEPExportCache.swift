import Foundation

/// Recently exported STEP bytes, shared by every engine in the process so the
/// byte bound holds across design windows and agent sessions. Keys identify the
/// native geometry, subset, colors and arrangement. Entries go with the build
/// artifacts that produced them, so released geometry never keeps its bytes.
final class STEPExportCache: @unchecked Sendable {
    static let shared = STEPExportCache(maximumBytes: ProjectStore.maximumSTEPBytes, maximumEntries: 8)

    private struct Entry {
        var data: [Data]
        var bytes: Int
        var owner: String
    }

    let maximumBytes: Int
    let maximumEntries: Int
    private let lock = NSLock()
    private var entries: [AnyHashable: Entry] = [:]
    private var order: [AnyHashable] = []
    private var totalBytes = 0

    init(maximumBytes: Int, maximumEntries: Int) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(1, maximumEntries)
    }

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    func data(for key: AnyHashable) -> [Data]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        if order.last != key, let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return entry.data
    }

    /// Recoloring can produce many large STEP variants of one assembly. Keep a
    /// small, byte-bounded LRU rather than retaining every finish.
    func store(_ data: [Data], for key: AnyHashable, owner folder: URL) {
        let bytes = data.reduce(0) { $0 + $1.count }
        let owner = folder.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        removeEntry(key)
        guard bytes <= maximumBytes else { return }
        while let oldest = order.first, entries.count >= maximumEntries || totalBytes + bytes > maximumBytes {
            removeEntry(oldest)
        }
        entries[key] = Entry(data: data, bytes: bytes, owner: owner)
        order.append(key)
        totalBytes += bytes
    }

    /// Called when a build's native artifacts are released.
    func removeAll(ownedBy folder: URL) {
        let owner = folder.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        for key in order where entries[key]?.owner == owner { removeEntry(key) }
    }

    private func removeEntry(_ key: AnyHashable) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        order.removeAll { $0 == key }
    }
}
