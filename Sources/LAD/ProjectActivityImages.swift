import Foundation
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A tool UUID is scoped to one attempt and task. Including the task identity
/// prevents images from one design request appearing in another result row.
struct ProjectActivityImageKey: Hashable, Sendable {
    var taskID: UUID
    var eventID: String
}

struct ProjectActivityImageReference: Identifiable, Sendable {
    var id = UUID()
    var data: Data
    var fileExtension: String
    var pixelSize: CGSize

}

/// Presents activity images. Saved render and screenshot PNGs belong to their
/// events; images an agent only viewed stay in a bounded session cache after
/// its private task directory is removed. Original encoded bytes are retained;
/// views downsample expanded rows without replacing the full-resolution image
/// used by external viewers.
@MainActor
final class ProjectActivityImages: ObservableObject {
    @Published private(set) var images: [ProjectActivityImageKey: ProjectActivityImageReference] = [:]
    /// Display metadata for saved event images, created only for expanded rows.
    private var saved: [ProjectActivityImageKey: ProjectActivityImageReference] = [:]
    private var order: [ProjectActivityImageKey] = []
    private let maximumImages: Int
    private let maximumBytes: Int
    private let temporaryDirectory: URL
    private let opener: @MainActor (URL) -> Bool
    private var files: ProjectActivityImageFiles

    init(maximumImages: Int = 128, maximumBytes: Int = 128 * 1024 * 1024,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         opener: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.maximumImages = max(1, maximumImages)
        self.maximumBytes = max(1, maximumBytes)
        self.temporaryDirectory = temporaryDirectory
        self.opener = opener
        self.files = ProjectActivityImageFiles(in: temporaryDirectory)
    }

    func store(_ data: Data, for key: ProjectActivityImageKey) {
        guard images[key]?.data != data, data.count <= 32 * 1024 * 1024,
              let reference = Self.reference(for: data) else { return }
        var retained = images
        var removedIDs = retained[key].map { [$0.id] } ?? []
        order.removeAll { $0 == key }
        order.append(key)
        retained[key] = reference
        var bytes = retained.values.reduce(0) { $0 + $1.data.count }
        while order.count > maximumImages || (order.count > 1 && bytes > maximumBytes) {
            if let removed = retained.removeValue(forKey: order.removeFirst()) {
                bytes -= removed.data.count
                removedIDs.append(removed.id)
            }
        }
        images = retained
        let files = files
        if !removedIDs.isEmpty { Task { await files.remove(removedIDs) } }
    }

    /// The image for one activity row: its saved PNG, otherwise a session image.
    func reference(for key: ProjectActivityImageKey, savedImage: Data?) -> ProjectActivityImageReference? {
        guard let savedImage else { return images[key] }
        if let existing = saved[key], existing.data == savedImage { return existing }
        guard let reference = Self.reference(for: savedImage) else { return nil }
        saved[key] = reference
        return reference
    }

    func open(_ reference: ProjectActivityImageReference) async throws {
        guard contains(reference) else { throw LADError.message("This image is no longer available.") }
        try Task.checkCancellation()
        let files = files
        let url = try await files.export(reference)
        guard contains(reference) else {
            await files.remove([reference.id])
            throw LADError.message("This image is no longer available.")
        }
        try Task.checkCancellation()
        guard opener(url) else { throw LADError.message("The image could not be opened.") }
    }

    func reset() {
        order = []; images = [:]; saved = [:]
        let previous = files
        files = ProjectActivityImageFiles(in: temporaryDirectory)
        Task { await previous.removeAll() }
    }

    private func contains(_ reference: ProjectActivityImageReference) -> Bool {
        images.values.contains { $0.id == reference.id } || saved.values.contains { $0.id == reference.id }
    }

    private static func reference(for data: Data) -> ProjectActivityImageReference? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image),
              let suffix = type.preferredFilenameExtension,
              !suffix.isEmpty, suffix.utf8.count <= 12,
              suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        var size = CGSize(width: width.doubleValue, height: height.doubleValue)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber,
           (5...8).contains(orientation.intValue) {
            size = CGSize(width: size.height, height: size.width)
        }
        return ProjectActivityImageReference(data: data, fileExtension: suffix, pixelSize: size)
    }
}

/// Export only after an explicit open action, independently of the agent's
/// temporary workspace. Serial file work stays off the main actor.
private actor ProjectActivityImageFiles {
    private static let cleanupQueue = DispatchQueue(label: "LAD.ActivityImageCleanup", qos: .utility)
    private let directory: URL
    private var exports: [UUID: URL] = [:]
    private var directoryCreated = false

    init(in parent: URL) {
        directory = parent.appendingPathComponent("LAD-activity-images-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        let directory = directory
        Self.cleanupQueue.async { try? FileManager.default.removeItem(at: directory) }
    }

    func export(_ reference: ProjectActivityImageReference) throws -> URL {
        let manager = FileManager.default
        if !directoryCreated {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            directoryCreated = true
        }
        let url = directory.appendingPathComponent("Image-\(reference.id.uuidString).\(reference.fileExtension)")
        // Recreate exact original bytes if an external viewer edited its copy.
        try reference.data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        exports[reference.id] = url
        return url
    }

    func remove(_ ids: [UUID]) {
        for id in ids {
            if let url = exports.removeValue(forKey: id) { try? FileManager.default.removeItem(at: url) }
        }
    }

    func removeAll() {
        exports = [:]
        try? FileManager.default.removeItem(at: directory)
        directoryCreated = false
    }
}
