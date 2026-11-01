import Foundation

/// A separate design starts from one validated revision with a clean conversation.
enum SaveNewProject {
    static func snapshot(from original: LADProject, revisionID: UUID? = nil) throws -> LADProject {
        var revision: ProjectRevision
        if let revisionID {
            guard let requested = original.revisions.first(where: { $0.id == revisionID }) else {
                throw LADError.message("That design version is no longer available.")
            }
            revision = requested
        } else {
            guard let latest = original.revisions.last else {
                throw LADError.message("There is no design to save.")
            }
            revision = latest
        }
        revision.userMessageID = nil
        revision.responseMessageID = nil
        if revision.parts == nil, let preview = revision.preview {
            guard (1...4_096).contains(preview.solids) else {
                throw LADError.message("The saved design contains an invalid solid count.")
            }
            revision.parts = preview.parts ?? (0..<preview.solids).map {
                PartNode(id: "solid/\($0)", name: "Part \($0 + 1)", solidIndices: [$0])
            }
        }
        if revision.partLayout == nil { revision.partLayout = revision.parts.map { PartLayout(nodes: $0) } }
        revision.runtime = revision.runtime ?? revision.preview?.runtime
        revision.preview = nil
        revision.stepData = nil
        return LADProject(messages: [], revisions: [revision], selectedRevisionID: revision.id,
                          projectID: UUID(), codexSettings: original.codexSettings,
                          projectName: original.projectName, showGrid: original.showGrid,
                          projectionMode: original.projectionMode, displayMode: original.displayMode,
                          recentPartColors: original.recentPartColors,
                          partsPaneFraction: original.partsPaneFraction)
    }
}
