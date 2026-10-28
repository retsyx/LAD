import CoreGraphics

/// Logical screen-point sizes used by the highlight overlay and its captures.
enum CADHighlightStyle {
    static let hoverEdgeWidth: CGFloat = 3
    static let selectedEdgeWidth: CGFloat = 4
    static let hoverEdgeHaloWidth: CGFloat = 5
    static let selectedEdgeHaloWidth: CGFloat = 5.5
    static let hoverVertexDiameter: CGFloat = 7
    static let selectedVertexDiameter: CGFloat = 9
    static let hoverVertexHaloDiameter: CGFloat = 11
    static let selectedVertexHaloDiameter: CGFloat = 12

    static let maximumEdgeRadius = max(hoverEdgeHaloWidth, selectedEdgeHaloWidth) / 2
    static let maximumRadius = max(maximumEdgeRadius, max(hoverVertexHaloDiameter, selectedVertexHaloDiameter) / 2)
}
