import Foundation

/// A compact description of the user's selected target at submission time.
/// This is request intent, not a serialized topology, display or measurement
/// cache. The referenced revision's program remains the source of geometry.
struct ProjectSelectionAnchor: Codable, Sendable, Equatable {
    var geometryType: String? = nil
    var position: [Double]? = nil
    var center: [Double]? = nil
    var normal: [Double]? = nil
    var axis: [Double]? = nil
    var direction: [Double]? = nil
    var startPoint: [Double]? = nil
    var endPoint: [Double]? = nil
    var radius: Double? = nil
    var majorRadius: Double? = nil
    var minorRadius: Double? = nil
    var length: Double? = nil
    var area: Double? = nil
    var volume: Double? = nil
    var bounds: [Double]? = nil
}

struct ProjectSelectedPart: Codable, Sendable, Equatable {
    /// Stable user-visible hierarchy identity; a solid-index fallback is used
    /// only when no named part metadata exists in the captured revision.
    var partID: String
    var name: String
    var path: [String]
    var solidIndex: Int
    var anchor: ProjectSelectionAnchor? = nil
}

struct ProjectSelectedFeature: Codable, Sendable, Equatable {
    var id: CADFeatureID
    var partID: String?
    var partName: String
    var partPath: [String]
    var anchor: ProjectSelectionAnchor? = nil
}

struct ProjectSelectionContext: Codable, Sendable, Equatable {
    var revisionID: UUID
    var capturedAt = Date()
    /// Whole-part selections, including explicitly selected folders' contents.
    /// Owning parts of selected subfeatures do not enter this collection.
    var parts: [ProjectSelectedPart]
    /// Preserves the user's feature-selection order, including mixed kinds.
    var features: [ProjectSelectedFeature]

    static let maximumParts = 8_192
    static let maximumFeatures = 8_192

    static func capture(revisionID: UUID, preview: PreviewMesh?, nodes: [PartNode],
                        selectedSolids: Set<Int>, selectedNodeIDs: Set<String>,
                        selectedFeatures: [CADFeatureID]) -> ProjectSelectionContext? {
        struct Owner {
            var id: String
            var name: String
            var path: [String]
        }
        var owners: [Int: Owner] = [:]
        var wholeParts = selectedSolids
        func visit(_ nodes: [PartNode], ancestors: [String]) {
            for node in nodes {
                let path = ancestors + [node.name]
                for index in node.solidIndices { owners[index] = Owner(id: node.id, name: node.name, path: path) }
                if selectedNodeIDs.contains(node.id) { wholeParts.formUnion(node.allSolidIndices) }
                visit(node.children ?? [], ancestors: path)
            }
        }
        visit(nodes, ancestors: [])
        // Saved hierarchy identities remain selectable while native geometry
        // is replaying. Preserve that part intent without inventing anchors or
        // starting a worker solely to capture the request.
        let solidCount = preview?.solids ?? ((owners.keys.filter { $0 >= 0 && $0 < 1_000_000 }.max() ?? -1) + 1)

        var seenFeatures = Set<CADFeatureID>()
        let orderedFeatures = selectedFeatures.filter {
            $0.solidIndex >= 0 && $0.solidIndex < solidCount && $0.localIndex >= 0 && seenFeatures.insert($0).inserted
        }
        let wanted = Set(orderedFeatures)
        let vertices = Dictionary(uniqueKeysWithValues: (preview?.topology?.vertices ?? [])
            .filter { wanted.contains($0.id) }.map { ($0.id, $0) })
        let edges = Dictionary(uniqueKeysWithValues: (preview?.topology?.edges ?? [])
            .filter { wanted.contains($0.id) }.map { ($0.id, $0) })
        let faces = Dictionary(uniqueKeysWithValues: (preview?.topology?.faces ?? [])
            .filter { wanted.contains($0.id) }.map { ($0.id, $0) })
        let partFacts = Dictionary(uniqueKeysWithValues: (preview?.topology?.parts ?? []).map { ($0.solidIndex, $0) })

        func owner(_ index: Int) -> Owner {
            owners[index] ?? Owner(id: "solid:\(index)", name: "Part \(index + 1)", path: ["Part \(index + 1)"])
        }
        let parts = wholeParts.filter { $0 >= 0 && $0 < solidCount }.sorted().map { index in
            let identity = owner(index)
            let anchor = partFacts[index].map { fact in
                ProjectSelectionAnchor(center: fact.centroid, area: fact.area, volume: fact.volume, bounds: fact.bounds)
            }
            return ProjectSelectedPart(partID: identity.id, name: identity.name, path: identity.path,
                                       solidIndex: index, anchor: anchor)
        }
        let features = orderedFeatures.compactMap { id -> ProjectSelectedFeature? in
            let anchor: ProjectSelectionAnchor
            switch id.kind {
            case .vertex:
                guard let vertex = vertices[id] else { return nil }
                anchor = ProjectSelectionAnchor(geometryType: "vertex", position: vertex.position)
            case .edge:
                guard let edge = edges[id] else { return nil }
                anchor = ProjectSelectionAnchor(geometryType: edge.type, center: edge.center, axis: edge.axis,
                    direction: edge.direction, startPoint: edge.startPoint, endPoint: edge.endPoint,
                    radius: edge.radius, majorRadius: edge.majorRadius, minorRadius: edge.minorRadius, length: edge.length)
            case .face:
                guard let face = faces[id] else { return nil }
                anchor = ProjectSelectionAnchor(geometryType: face.type, center: face.center, normal: face.normal,
                    axis: face.axis, radius: face.radius, majorRadius: face.majorRadius, minorRadius: face.minorRadius, area: face.area)
            }
            let identity = owner(id.solidIndex)
            return ProjectSelectedFeature(id: id, partID: owners[id.solidIndex]?.id, partName: identity.name,
                                          partPath: identity.path, anchor: anchor)
        }
        guard !parts.isEmpty || !features.isEmpty else { return nil }
        return ProjectSelectionContext(revisionID: revisionID, parts: parts, features: features)
    }

    func validate() throws {
        func invalid() -> LADError { .message("The saved selection references are invalid.") }
        func text(_ value: String, maximum: Int = 1_024) -> Bool {
            !value.isEmpty && value.utf8.count <= maximum &&
                value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        func path(_ values: [String]) -> Bool {
            !values.isEmpty && values.count <= 64 && values.allSatisfy { text($0) }
        }
        func vector(_ values: [Double]?, count: Int = 3) -> Bool {
            values.map { $0.count == count && $0.allSatisfy { $0.isFinite && abs($0) <= 1_000_000.1 } } ?? true
        }
        func nonnegative(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? true }
        func anchor(_ value: ProjectSelectionAnchor?) -> Bool {
            guard let value else { return true }
            return (value.geometryType.map { text($0, maximum: 64) } ?? true) &&
                [value.position, value.center, value.normal, value.axis, value.direction, value.startPoint, value.endPoint].allSatisfy { vector($0) } &&
                [value.radius, value.majorRadius, value.minorRadius, value.length, value.area, value.volume].allSatisfy(nonnegative) &&
                vector(value.bounds, count: 6) && (value.bounds.map { bounds in (0..<3).allSatisfy { bounds[$0] <= bounds[$0 + 3] } } ?? true)
        }
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              !parts.isEmpty || !features.isEmpty,
              parts.count <= Self.maximumParts, features.count <= Self.maximumFeatures,
              Set(parts.map(\.solidIndex)).count == parts.count,
              Set(features.map(\.id)).count == features.count,
              parts.allSatisfy({ $0.solidIndex >= 0 && $0.solidIndex < 1_000_000 && text($0.partID) && text($0.name) && path($0.path) && anchor($0.anchor) }),
              features.allSatisfy({ $0.id.solidIndex >= 0 && $0.id.solidIndex < 1_000_000 &&
                  $0.id.localIndex >= 0 && $0.id.localIndex < 1_000_000 &&
                  ($0.partID.map { text($0) } ?? true) && text($0.partName) && path($0.partPath) && anchor($0.anchor) }) else { throw invalid() }
    }
}
