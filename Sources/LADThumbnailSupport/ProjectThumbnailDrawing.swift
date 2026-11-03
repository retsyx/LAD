import CoreGraphics

/// Quick Look supplies a bitmap whose pixel size includes the requested backing
/// scale. Use that bitmap's bounds in its current coordinate system, rather than
/// treating the request's point dimensions as pixel dimensions.
public enum ProjectThumbnailDrawing {
    public static func draw(_ image: CGImage, in context: CGContext) -> Bool {
        guard context.width > 0, context.height > 0 else { return false }
        let pixels = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        let bounds = context.convertToUserSpace(pixels)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0 else { return false }
        let ratio = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return true
    }
}
