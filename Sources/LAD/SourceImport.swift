import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A source or image snapshot travels with the design conversation, so later requests
/// and reopened projects do not depend on the original file still existing.
struct SourceAttachment: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var content: String
    var sha256: String
    /// Exact portable image bytes. Text source snapshots leave this nil.
    var imageData: Data? = nil

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isImage: Bool { imageData != nil }
    var data: Data { imageData ?? Data(content.utf8) }
    var byteCount: Int { imageData?.count ?? content.utf8.count }
}

enum SourceImport {
    static let maximumFileBytes = 1_048_576
    static let maximumTotalBytes = 2_097_152
    static let maximumFiles = 4
    static let maximumImages = 10
    static let maximumImageFileBytes = 20 * 1_048_576
    static let maximumImageTotalBytes = 64 * 1_048_576
    static let maximumAttachmentCount = maximumFiles + maximumImages
    static let maximumImagePixels = 64_000_000
    static let maximumImageDimension = 16_384
    static let supportedExtensions: Set<String> = ["fs", "scad", "py", "json", "txt", "kicad_pcb"]
    static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif"]

    static func isImageURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // Folder names can have image suffixes. Stat only the named item;
        // never enumerate a dropped folder or read any of its contents.
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { return false }
        return supportedImageExtensions.contains(url.pathExtension.lowercased()) ||
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Keep only formats accepted as local Codex image inputs. Native image
    /// formats, animation and orientation metadata become an upright PNG.
    /// No image payload is converted into prompt text.
    static func imageAttachment(data: Data, name: String = "Pasted image", path: String? = nil) throws -> SourceAttachment {
        let info = try imageSource(data)
        let upright = info.orientation == 1
        let preserve = upright && CGImageSourceGetCount(info.source) == 1 &&
            (info.type == UTType.png.identifier || info.type == UTType.jpeg.identifier)
        let bytes: Data
        let ext: String
        if preserve {
            bytes = data
            ext = info.type == UTType.jpeg.identifier ? "jpg" : "png"
            // Decode a bounded thumbnail as well as reading the header, so a
            // damaged payload cannot become a seemingly valid attachment.
            guard thumbnail(info.source, maximumDimension: 256) != nil else {
                throw LADError.message("The image could not be decoded.")
            }
        } else {
            guard let image = thumbnail(info.source, maximumDimension: max(info.width, info.height)) else {
                throw LADError.message("The image could not be decoded.")
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
                throw LADError.message("The image could not be prepared for the prompt.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw LADError.message("The image could not be prepared for the prompt.")
            }
            bytes = encoded as Data
            ext = "png"
            guard bytes.count <= maximumImageFileBytes else {
                throw LADError.message("The prepared image exceeds the 20 MiB image limit.")
            }
        }
        let id = UUID()
        let basename = (name as NSString).lastPathComponent
        let stem = (basename as NSString).deletingPathExtension
        let filename = "\(stem.isEmpty ? "Image" : stem).\(ext)"
        return SourceAttachment(id: id, name: filename, path: path ?? "clipboard://\(id.uuidString)",
                                content: "", sha256: digest(bytes), imageData: bytes)
    }

    static func mergeAttachments(existing: [SourceAttachment], added: [SourceAttachment]) throws -> [SourceAttachment] {
        let candidates = existing.filter { old in !added.contains(where: { $0.path == old.path }) } + added
        var identities = Set<String>()
        let result = candidates.filter { attachment in
            identities.insert(attachment.isImage ? "image:\(attachment.sha256)" : "source:\(attachment.path)").inserted
        }
        try validateAttachments(result)
        return result
    }

    static func validateAttachments(_ attachments: [SourceAttachment]) throws {
        var verified: [String: Data] = [:]
        try validateAttachments(attachments, verifiedPayloads: &verified)
    }

    /// A design can reference the same payload in its chat, queue and draft.
    /// Validate shared bytes once without trusting a claimed hash alone.
    static func validateAttachments(_ attachments: [SourceAttachment], verifiedPayloads: inout [String: Data]) throws {
        guard attachments.count <= maximumAttachmentCount, Set(attachments.map(\.id)).count == attachments.count else {
            throw LADError.message("The prompt contains too many attachments or duplicate attachment IDs.")
        }
        let sources = attachments.filter { !$0.isImage }
        let images = attachments.filter(\.isImage)
        guard sources.count <= maximumFiles, sources.reduce(0, { $0 + $1.byteCount }) <= maximumTotalBytes else {
            throw LADError.message("Attach at most four source files, totaling no more than 2 MiB, per request.")
        }
        guard images.count <= maximumImages, images.reduce(0, { $0 + $1.byteCount }) <= maximumImageTotalBytes else {
            throw LADError.message("Attach at most ten images, totaling no more than 64 MiB, per request.")
        }
        for attachment in attachments {
            guard !attachment.name.isEmpty, attachment.name.utf8.count <= 1_024,
                  !attachment.path.isEmpty, attachment.path.utf8.count <= 16_384 else {
                throw LADError.message("An attachment has an invalid name or file reference.")
            }
            let bytes = attachment.data
            let key = "\(attachment.isImage ? "image:\(attachment.fileExtension)" : "source"):\(attachment.sha256)"
            if attachment.isImage {
                guard attachment.content.isEmpty, !bytes.isEmpty, bytes.count <= maximumImageFileBytes,
                      ["png", "jpg", "jpeg"].contains(attachment.fileExtension) else {
                    throw LADError.message("An attached image is empty, invalid, or exceeds the 20 MiB image limit.")
                }
            } else {
                guard !bytes.isEmpty, bytes.count <= maximumFileBytes, !attachment.content.contains("\0") else {
                    throw LADError.message("An attached source file is empty, invalid, or exceeds the source size limit.")
                }
            }
            if let verified = verifiedPayloads[key] {
                guard verified == bytes else { throw LADError.message("An attachment failed its integrity check.") }
                continue
            }
            guard attachment.sha256 == digest(bytes) else { throw LADError.message("An attachment failed its integrity check.") }
            if attachment.isImage {
                let info = try imageSource(bytes)
                let expected = attachment.fileExtension == "png" ? UTType.png.identifier : UTType.jpeg.identifier
                guard info.type == expected, info.orientation == 1, CGImageSourceGetCount(info.source) == 1,
                      thumbnail(info.source, maximumDimension: 256) != nil else {
                    throw LADError.message("An attached image has an invalid or unsupported image payload.")
                }
            }
            verifiedPayloads[key] = bytes
        }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func imageSource(_ data: Data) throws -> (source: CGImageSource, type: String, width: Int, height: Int, orientation: Int) {
        guard !data.isEmpty, data.count <= maximumImageFileBytes else {
            throw LADError.message("Choose an image no larger than 20 MiB.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maximumImageDimension, height <= maximumImageDimension,
              width <= maximumImagePixels / height else {
            throw LADError.message("The image is unreadable or exceeds the supported image dimensions.")
        }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw LADError.message("The image has invalid orientation metadata.") }
        return (source, sourceType as String, width, height, orientation)
    }

    private static func thumbnail(_ source: CGImageSource, maximumDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ] as CFDictionary)
    }

    /// Extract only explicitly named local source paths. The path ends at its
    /// source extension, which also permits unquoted paths containing spaces.
    /// No directory enumeration, nested import resolution or shell is involved.
    static func referencedURLs(in prompt: String) -> [URL] {
        let source = prompt as NSString
        let range = NSRange(location: 0, length: source.length)
        let remotePattern = #"\b(?!file://)[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'`<>“”‘’]+"#
        let remoteRanges = (try? NSRegularExpression(pattern: remotePattern, options: [.caseInsensitive]))?
            .matches(in: prompt, range: range).map(\.range) ?? []
        let pattern = #"(?<![\p{L}\p{N}_/])(?:file://|~/|/)[^\r\n\"'`<>“”‘’]*?\.(?:kicad_pcb|scad|json|txt|py|fs)(?=$|[\s\"'`.,;:!?)\]}>“”‘’])"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var result: [URL] = []
        var seen = Set<String>()
        for match in expression.matches(in: prompt, range: range) {
            guard !remoteRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let candidate = source.substring(with: match.range)
            let url: URL
            if candidate.lowercased().hasPrefix("file://") {
                // URLComponents handles percent-encoded spaces as well as
                // human-written file:/// paths containing literal spaces.
                guard let parsed = URL(string: candidate), parsed.isFileURL else { continue }
                url = parsed.standardizedFileURL
            } else {
                let path = (candidate as NSString).expandingTildeInPath
                url = URL(fileURLWithPath: path).standardizedFileURL
            }
            guard seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// Call from a background task: file I/O and hashing may take time. Every
    /// named file must succeed; a missing source never silently becomes a guess.
    static func load(urls: [URL]) throws -> [SourceAttachment] {
        var unique: [URL] = []
        var seen = Set<String>()
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
                throw failure("Only local files are supported.", path: url.absoluteString)
            }
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(normalized.path).inserted { unique.append(normalized) }
        }
        guard unique.count <= maximumAttachmentCount else {
            throw LADError.message("The prompt contains too many attachments.")
        }
        guard unique.filter({ isImageURL($0) }).count <= maximumImages,
              unique.filter({ !isImageURL($0) }).count <= maximumFiles else {
            throw LADError.message("Attach at most four source files and ten images per request.")
        }
        var sourceBytes = 0, imageBytes = 0
        var attachments: [SourceAttachment] = []
        for url in unique {
            if isImageURL(url) {
                let data = try readRegularFile(url, maximumBytes: maximumImageFileBytes, kind: "image")
                let attachment: SourceAttachment
                do { attachment = try imageAttachment(data: data, name: url.lastPathComponent, path: url.path) }
                catch { throw failure(error.localizedDescription, path: url.path) }
                guard attachment.byteCount <= maximumImageTotalBytes - imageBytes else {
                    throw LADError.message("Image attachments exceed the 64 MiB total limit.")
                }
                imageBytes += attachment.byteCount
                attachments.append(attachment)
                continue
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                throw failure("Choose a .fs, .scad, .py, .json, .txt or .kicad_pcb source file.", path: url.path)
            }
            let data = try readRegularFile(url, maximumBytes: maximumFileBytes, kind: "source")
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw failure("The source must be UTF-8 text, not a binary file.", path: url.path)
            }
            let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
            guard !text.trimmingCharacters(in: whitespace).isEmpty else {
                throw failure("The source file is empty.", path: url.path)
            }
            let contentBytes = Data(text.utf8)
            guard contentBytes.count <= maximumTotalBytes - sourceBytes else {
                throw LADError.message("Source attachments exceed the 2 MiB total limit. Attach fewer files or a smaller design source.")
            }
            sourceBytes += contentBytes.count
            let digest = SHA256.hash(data: contentBytes).map { String(format: "%02x", $0) }.joined()
            attachments.append(SourceAttachment(name: url.lastPathComponent, path: url.path, content: text, sha256: digest))
        }
        try validateAttachments(attachments)
        return attachments
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int, kind: String) throws -> Data {
        // O_NONBLOCK prevents a named pipe from hanging the UI's import job.
        // Resolve symlinks once, then reject a final-component symlink swap.
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            throw failure("Could not read the source file (\(reason)). Check the path and file permissions.", path: url.path)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw failure("Choose a regular source file, not a directory or device.", path: url.path)
        }
        guard info.st_size <= maximumBytes else {
            throw failure("The \(kind) file exceeds its size limit.", path: url.path)
        }
        var data = Data()
        do {
            while let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumBytes else {
                    throw failure("The \(kind) file exceeds its size limit.", path: url.path)
                }
            }
        } catch let error as LADError { throw error }
        catch { throw failure("Could not read the source file: \(error.localizedDescription)", path: url.path) }
        return data
    }

    private static func failure(_ message: String, path: String) -> LADError {
        .message("\(message)\n\n\(path)")
    }
}
