import AppKit
import CryptoKit
import ImageIO
import Quartz
import SwiftUI

/// The full image remains in the archive asset. Only a small, bounded bitmap
/// is decoded for a thumbnail, and repeated composer updates reuse it.
@MainActor
private final class PromptImageThumbnailCache {
    static let shared = PromptImageThumbnailCache()
    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 96
        images.totalCostLimit = 32 * 1_024 * 1_024
    }

    func thumbnail(for attachment: SourceAttachment) async -> NSImage? {
        let key = attachment.sha256 as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let bytes = attachment.imageData else { return nil }
        let pixels = await Task.detached(priority: .userInitiated) { () -> PromptImagePixels? in
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return PromptImagePixels(image: image)
        }.value
        guard !Task.isCancelled, let pixels else { return nil }
        let image = NSImage(cgImage: pixels.image, size: NSSize(width: pixels.image.width, height: pixels.image.height))
        images.setObject(image, forKey: key, cost: pixels.image.bytesPerRow * pixels.image.height)
        return image
    }
}

private struct PromptImagePixels: @unchecked Sendable {
    let image: CGImage
}

struct PromptImageAttachmentView: View {
    let attachment: SourceAttachment
    var size: CGFloat = 112
    var onRemove: (() -> Void)? = nil
    var onPreview: (() -> Void)? = nil
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let onPreview {
                    Button(action: onPreview) { image }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Preview \(attachment.name)")
                        .help(attachment.name)
                } else { image }
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color(nsColor: .darkGray))
                        .frame(width: 19, height: 19)
                        .background(Color(nsColor: .lightGray), in: Circle())
                        .overlay(Circle().stroke(Palette.background, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Remove \(attachment.name)")
                .accessibilityLabel("Remove image \(attachment.name)")
                .accessibilityIdentifier("projectPromptImageRemove-\(attachment.id.uuidString)")
            }
        }
        .frame(width: size, height: size)
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectPromptImage-\(attachment.id.uuidString)")
        .task(id: attachment.sha256) {
            thumbnail = await PromptImageThumbnailCache.shared.thumbnail(for: attachment)
        }
    }

    private var image: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Rectangle().fill(Palette.raised)
                    .overlay(Image(systemName: "photo").foregroundStyle(Palette.muted))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(attachment.name)
    }
}

/// A private extraction exists only for this preview presentation. Quick Look
/// reads the archive-backed bytes even if the original image has been removed.
struct PromptImagePreview: View {
    let attachment: SourceAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var file: PromptImagePreviewFile?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(attachment.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            Group {
                if let file { PromptImageQuickLook(url: file.url) }
                else if let error { Text(error).foregroundStyle(Palette.muted).padding() }
                else { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 540, idealWidth: 800, minHeight: 420, idealHeight: 620)
        .accessibilityLabel("Image preview")
        .task(id: attachment.sha256) {
            do {
                let attachment = attachment
                let created = try await Task.detached(priority: .userInitiated) {
                    try PromptImagePreviewFile(attachment: attachment)
                }.value
                guard !Task.isCancelled else { return }
                file = created
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onDisappear { file = nil }
    }
}

final class PromptImagePreviewFile: @unchecked Sendable {
    let url: URL
    private let directory: URL

    init(attachment: SourceAttachment) throws {
        guard let data = attachment.imageData else { throw LADError.message("The image is unavailable.") }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("LAD-image-preview-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = attachment.fileExtension == "jpg" || attachment.fileExtension == "jpeg" ? "jpg" : "png"
        url = directory.appendingPathComponent("\(digest).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private struct PromptImageQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
