import Foundation

/// A small Finder presentation image, independent of CAD replay and tool images.
@MainActor
enum ProjectThumbnail {
    static let dimension = 512

    struct Input: Equatable {
        var revisionID: UUID
        var geometryPath: String
        var nativePath: String?
        var validationHash: String?
        var projection: ViewportProjectionMode
        var display: ViewportDisplayMode
        var hiddenSolids: Set<Int>
        var solidColors: [Int: PartColor]
    }

    static func render(preview: PreviewMesh, projection: ViewportProjectionMode,
                       display: ViewportDisplayMode, hiddenSolids: Set<Int>,
                       solidColors: [Int: PartColor]) async throws -> Data {
        try await CADAgentRenderer.renderPNG(preview: preview, projection: projection, display: display,
            hiddenSolids: hiddenSolids, solidColors: solidColors, width: dimension, height: dimension)
    }

    static func render(project: LADProject, preview: PreviewMesh) async throws -> Data {
        guard let revision = project.revisions.first(where: { $0.id == project.selectedRevisionID }) else {
            throw LADError.message("The design has no selected version to preview.")
        }
        let parts = revision.partLayout?.nodes ?? revision.parts ?? preview.parts ?? []
        var preview = preview
        if let motion = preview.assemblyMotion {
            let nativeParts = preview.parts ?? parts, positions = revision.jointPositions ?? [:]
            let calculation = Task.detached(priority: .utility) {
                try motion.solve(parts: nativeParts, positions: positions)
            }
            preview.assemblyPose = try await withTaskCancellationHandler { try await calculation.value }
                onCancel: { calculation.cancel() }
        }
        return try await render(preview: preview, projection: project.projectionMode ?? .perspective,
            display: project.displayMode ?? .edges, hiddenSolids: Set(revision.hiddenSolids ?? []),
            solidColors: PartColorState.solidColors(in: parts, overrides: revision.partColors ?? [:]))
    }
}
