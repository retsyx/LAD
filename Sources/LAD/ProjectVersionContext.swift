import Foundation

/// Immutable recipes and document metadata visible to one agent task. Display
/// meshes, native caches and generated STEP exports never enter this snapshot.
struct ProjectVersionContext: Sendable {
    struct Version: Sendable {
        let id: UUID
        let number: Int
        let name: String?
        let date: Date
        let model: ModelSpec
        let runtime: CADRuntime?
        let partLayout: PartLayout?
        let parts: [PartNode]?
        let hiddenSolids: [Int]?
        let partColors: [String: PartColor]?
        let isCurrent: Bool

        var label: String { "v\(number)" }
    }

    let versions: [Version]
    let selectedRevisionID: UUID?

    static let empty = ProjectVersionContext(revisions: [], selectedRevisionID: nil)

    init(revisions: [ProjectRevision], selectedRevisionID: UUID?) {
        self.selectedRevisionID = selectedRevisionID
        versions = revisions.enumerated().map { index, revision in
            Version(id: revision.id, number: index + 1, name: revision.name, date: revision.date,
                    model: revision.model, runtime: revision.runtime ?? revision.preview?.runtime,
                    partLayout: revision.partLayout, parts: revision.parts ?? revision.preview?.parts,
                    hiddenSolids: revision.hiddenSolids, partColors: revision.partColors,
                    isCurrent: revision.id == selectedRevisionID)
        }
    }

    /// Stable IDs take precedence. Otherwise a history label and custom names
    /// may collide, so return all matches and let the caller ask for an ID.
    func matches(reference: String) -> [Version] {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let version = versions.first(where: { $0.id == id }) {
            return [version]
        }
        return versions.filter { $0.label == reference || $0.name == reference }
    }

    func version(id: String) throws -> Version {
        guard let uuid = UUID(uuidString: id), let version = versions.first(where: { $0.id == uuid }) else {
            throw LADError.message("The requested saved version is unavailable. Use a versionID returned by lad_versions or lad_version.")
        }
        return version
    }
}
