import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Reads only the package's presentation image. Quick Look never loads CAD
/// recipes, starts a worker, or follows original input paths.
public enum ProjectThumbnailReader {
    public static let maximumImageBytes = 8 * 1_024 * 1_024
    public static let maximumManifestBytes = 32 * 1_024 * 1_024
    public static let maximumDimension = 4_096

    public static func imageData(in package: URL) throws -> Data? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data?, Error>?
        coordinator.coordinate(readingItemAt: package, options: [], error: &coordinationError) { readable in
            result = Result { try readImage(in: readable) }
        }
        guard let result else {
            throw coordinationError ?? CocoaError(.fileReadUnknown)
        }
        return try result.get()
    }

    private struct Manifest: Decodable {
        var thumbnail: Thumbnail?
    }

    private struct Thumbnail: Decodable {
        var path: String
        var sha256: String
    }

    private static func readImage(in package: URL) throws -> Data? {
        // Open every component relative to the already-open package and refuse
        // symlinks, including during replacement of an untrusted package.
        let descriptor = open(package.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        let manifestData = try readFile("project.json", relativeTo: descriptor, maximumBytes: maximumManifestBytes)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard let thumbnail = manifest.thumbnail else { return nil }
        let hash = thumbnail.sha256
        guard hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              thumbnail.path == "assets/sha256/\(hash.prefix(2))/\(hash)" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try readFile(thumbnail.path, relativeTo: descriptor, maximumBytes: maximumImageBytes)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == hash,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...maximumDimension).contains(width.intValue),
              (1...maximumDimension).contains(height.intValue),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func readFile(_ path: String, relativeTo package: Int32, maximumBytes: Int) throws -> Data {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last else { throw CocoaError(.fileReadInvalidFileName) }
        var directories = [Int32]()
        defer { directories.reversed().forEach { close($0) } }
        var parent = package
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixError() }
            directories.append(next)
            parent = next
        }
        let descriptor = openat(parent, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0,
              status.st_size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        }
        return data
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
