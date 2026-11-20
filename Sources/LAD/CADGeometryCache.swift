import CryptoKit
import Darwin
import Foundation

/// Validated viewport geometry of displayed design versions, kept across
/// launches in the user's Caches folder and never in a `.lad` package. Each
/// entry holds one build's native solid, display buffers and derived topology,
/// keyed by its complete replay inputs, the CAD runtime and the bundled
/// engine, so an entry is the geometry a new build would display. A design's
/// regular and 3D printing builds are separate entries. Agent tool builds
/// neither read nor fill the cache.
///
/// Entries beyond the byte bound are evicted least recently used first, by
/// each entry folder's modification time, so the order survives relaunches.
/// Every loaded entry is checked like a worker result; an unreadable one is
/// removed and the version rebuilds. Deleting the cache only costs rebuilds.
final class CADGeometryCache: @unchecked Sendable {
    /// The app enables its cache once at launch, before any design opens.
    /// Other hosts, including tests, have none unless they create their own.
    static var viewport: CADGeometryCache?

    static let defaultMaximumBytes: Int64 = 2 << 30

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LAD/Geometry", isDirectory: true)
    }

    /// Changes whenever the entry layout or the app's reading of it changes.
    private static let formatVersion = 1
    private static let resultName = "result.json"
    private static let brepName = "model.brep"
    private static let entryFiles = [resultName, PreviewMeshBuffers.fileName, brepName]
    private static let stagingPrefix = ".incoming-"

    let directory: URL
    let maximumBytes: Int64
    /// One version's geometry may take at most a quarter of the cache.
    var maximumEntryBytes: Int64 { maximumBytes / 4 }
    private let temporaryDirectory: URL
    private let lock = NSLock()

    init(directory: URL = defaultDirectory, maximumBytes: Int64 = defaultMaximumBytes,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
        self.maximumBytes = max(0, maximumBytes)
        self.temporaryDirectory = temporaryDirectory
    }

    /// The validated geometry a build of `spec` would display, if cached. The
    /// preview owns private copies of the entry's files, so later eviction
    /// never affects it.
    func preview(for spec: ModelSpec, print: Bool = false, python: String) async -> PreviewMesh? {
        await Task.detached(priority: .userInitiated) { [self] () -> PreviewMesh? in
            let key = Self.key(for: spec, print: print, python: python)
            let entry = directory.appendingPathComponent(key, isDirectory: true)
            guard FileManager.default.fileExists(atPath: entry.appendingPathComponent(Self.resultName).path),
                  let artifacts = try? EngineBuildArtifacts.create(in: temporaryDirectory, token: UUID(), containsSTEP: false)
            else { return nil }
            do {
                try lock.withLock {
                    for name in Self.entryFiles {
                        // APFS clones share the entry's blocks.
                        guard copyfile(entry.appendingPathComponent(name).path, artifacts.folder.appendingPathComponent(name).path,
                                       nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                            throw LADError.message("The cached design geometry is incomplete.")
                        }
                    }
                    // Mark the entry as just used.
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
                }
                return try Self.decode(artifacts)
            } catch {
                lock.withLock { try? FileManager.default.removeItem(at: entry) }
                return nil
            }
        }.value
    }

    /// Keep a newly built and validated version's geometry, replacing any
    /// entry for the same build, so an explicit rebuild refreshes it. Writing
    /// happens in the background; the returned task finishes with it.
    @discardableResult
    func store(_ preview: PreviewMesh, for spec: ModelSpec, print: Bool = false, python: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            guard preview.validatedHash != nil, preview.pendingValidationHash == nil,
                  let artifacts = preview.buildArtifacts, let source = preview.brepPath,
                  source == artifacts.folder.appendingPathComponent(Self.brepName).path else { return }
            let key = Self.key(for: spec, print: print, python: python)
            let entry = directory.appendingPathComponent(key, isDirectory: true)
            let manager = FileManager.default
            let staging = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try withExtendedLifetime(artifacts) {
                    guard copyfile(source, staging.appendingPathComponent(Self.brepName).path, nil,
                                   copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                        throw LADError.message("The design's native solid could not be cached.")
                    }
                }
                let buffers = try PreviewMeshBuffers.write(preview, to: staging.appendingPathComponent(PreviewMeshBuffers.fileName))
                // The result is written last; an entry is published by renaming it.
                try JSONEncoder().encode(Record(preview: preview, buffers: buffers))
                    .write(to: staging.appendingPathComponent(Self.resultName), options: .withoutOverwriting)
                guard Self.size(of: staging) <= maximumEntryBytes else {
                    throw LADError.message("The design's geometry is too large to cache.")
                }
                try lock.withLock {
                    try? manager.removeItem(at: entry)
                    try manager.moveItem(at: staging, to: entry)
                    evict(keeping: key)
                }
            } catch {
                try? manager.removeItem(at: staging)
            }
        }
    }

    /// Bytes held by cached entries.
    var byteCount: Int64 {
        lock.withLock { entries().reduce(0) { $0 + $1.bytes } }
    }

    /// The entry name for a build of `spec`. Display metadata is excluded, as
    /// it is from the worker's validation receipt; input bytes are hashed.
    static func key(for spec: ModelSpec, print: Bool, python: String) -> String {
        let identity = Identity(format: formatVersion, engine: engineFingerprint, runtime: python, print: print,
                                units: spec.units, script: spec.script, source: spec.sourceSTEP.map { SHA256.hexDigest($0) },
                                inputs: (spec.inputAssets ?? []).map {
                                    Identity.Input(id: $0.id, format: $0.format, sha256: SHA256.hexDigest($0.data))
                                })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hexDigest((try? encoder.encode(identity)) ?? Data())
    }

    /// The bundled engine sources, which determine meshing, topology and
    /// validation. Any engine change makes earlier entries unreachable.
    static let engineFingerprint: String = {
        let folder = ResourcePaths.root.appendingPathComponent("Engine", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".py") }.sorted()
        var hasher = SHA256()
        for name in names {
            let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) ?? Data()
            hasher.update(data: Data("\(name)\n\(SHA256.hexDigest(data))\n".utf8))
        }
        return hasher.finalize().hexString
    }()

    private struct Identity: Encodable {
        struct Input: Encodable {
            var id: String
            var format: String
            var sha256: String
        }
        var format: Int
        var engine: String
        var runtime: String
        var print: Bool
        var units: String
        var script: String
        var source: String?
        var inputs: [Input]
    }

    /// The preview's metadata with its buffer manifest, in the worker's
    /// `result.json` form.
    private struct Record: Encodable {
        var preview: PreviewMesh
        var buffers: PreviewMeshBuffers.Manifest
        private enum Keys: String, CodingKey { case meshBuffers }

        func encode(to encoder: Encoder) throws {
            try preview.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(buffers, forKey: .meshBuffers)
        }
    }

    private static func decode(_ artifacts: EngineBuildArtifacts) throws -> PreviewMesh {
        let folder = artifacts.folder
        var preview = try EngineService.decodePreview(folder.appendingPathComponent(resultName), in: folder)
        guard preview.validatedHash != nil, preview.pendingValidationHash == nil else {
            throw LADError.message("The cached design geometry is not validated.")
        }
        try EngineService.validateNativeSolid(in: folder)
        artifacts.discardAll(except: [brepName])
        preview.brepPath = folder.appendingPathComponent(brepName).path
        preview.stepPath = folder.appendingPathComponent("model.step").path
        preview.buildArtifacts = artifacts
        return preview
    }

    private static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        return files.reduce(0) { total, file in
            let values = try? file.resourceValues(forKeys: keys)
            return total + Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
    }

    /// Entries on disk, rescanned so other LAD processes' entries count too.
    /// Staging folders abandoned by an interrupted write are removed.
    private func entries() -> [(name: String, url: URL, bytes: Int64, used: Date)] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let abandoned = Date().addingTimeInterval(-3_600)
        return children.compactMap { child in
            let name = child.lastPathComponent
            let used = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if name.hasPrefix(Self.stagingPrefix) {
                if used < abandoned { try? FileManager.default.removeItem(at: child) }
                return nil
            }
            guard name.utf8.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return (name, child, Self.size(of: child), used)
        }
    }

    private func evict(keeping key: String) {
        let all = entries().sorted { $0.used < $1.used }
        var total = all.reduce(0) { $0 + $1.bytes }
        for entry in all where total > maximumBytes && entry.name != key {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }
}
