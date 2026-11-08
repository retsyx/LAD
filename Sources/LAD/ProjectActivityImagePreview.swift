import AppKit
import ImageIO
import SwiftUI

/// The original bytes stay in the session cache. Only expanded results create
/// a bounded display bitmap, independently of the original image dimensions.
struct ProjectActivityImagePreview: View {
    var reference: ProjectActivityImageReference
    var images: ProjectActivityImages
    @State private var image: NSImage?
    @State private var failed = false
    @State private var isOpening = false
    @State private var openError: String?

    var body: some View {
        ProjectActivityImageLayout(imageSize: reference.pixelSize) {
            Group {
                if let image {
                    ProjectActivityNativeImage(image: image, onOpen: openImage)
                        .accessibilityLabel("Tool image")
                        .accessibilityHint("Opens in the default app")
                        .accessibilityAction(named: "Open image", openImage)
                        .help("Double-click to open in the default app")
                } else if failed {
                    Text("Preview unavailable").font(.caption).foregroundStyle(Palette.muted)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("projectActivityImage-\(reference.id.uuidString)")
        .task(id: reference.id) {
            image = nil; failed = false
            let data = reference.data
            let decoded = await Task.detached(priority: .userInitiated) {
                ProjectActivityImageDecoder.preview(data)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded { image = NSImage(cgImage: decoded, size: .zero) }
            else { failed = true }
        }
        .onDisappear { image = nil }
        .alert("Couldn’t open image", isPresented: Binding(get: { openError != nil }, set: {
            if !$0 { openError = nil }
        })) {
            Button("OK", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
    }

    private func openImage() {
        guard !isOpening else { return }
        isOpening = true
        Task { @MainActor in
            defer { isOpening = false }
            do { try await images.open(reference) }
            catch { openError = error.localizedDescription }
        }
    }
}

private struct ProjectActivityNativeImage: NSViewRepresentable {
    var image: NSImage
    var onOpen: () -> Void

    func makeNSView(context: Context) -> ProjectActivityNativeImageView {
        let view = ProjectActivityNativeImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.unregisterDraggedTypes()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: ProjectActivityNativeImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.onOpen = onOpen
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProjectActivityNativeImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    static func dismantleNSView(_ view: ProjectActivityNativeImageView, coordinator: ()) {
        view.onOpen = nil
        view.image = nil
    }
}

private final class ProjectActivityNativeImageView: NSImageView {
    var onOpen: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onOpen?() }
    }
}

/// A bounded layout avoids propagating a large image's intrinsic size through
/// SwiftUI into the native Tool Activity panel, including during resizing.
struct ProjectActivityImageLayout: Layout {
    var imageSize: CGSize
    static let maximumHeight: CGFloat = 420

    static func fittedSize(_ image: CGSize, width: CGFloat) -> CGSize {
        guard image.width.isFinite, image.height.isFinite, image.width > 0, image.height > 0,
              width.isFinite, width > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(1, width / image.width, maximumHeight / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? min(imageSize.width, 640)
        let width = proposed.isFinite && proposed > 0 ? proposed : 1
        return CGSize(width: width, height: Self.fittedSize(imageSize, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = Self.fittedSize(imageSize, width: bounds.width)
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: size.width, height: size.height))
        }
    }
}

enum ProjectActivityImageDecoder {
    static let maximumDimension = 2_048

    static func preview(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ] as CFDictionary)
    }
}
