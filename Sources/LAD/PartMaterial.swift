import Foundation

/// A named density. Designs store complete definitions, so a saved assignment
/// never depends on the material library of the LAD installation opening it.
struct PartMaterial: Codable, Sendable, Equatable, Hashable {
    var name: String
    /// Grams per cubic centimeter.
    var density: Double

    static let maximumNameBytes = 256
    static let maximumDensity = 100.0
    static let densityUnit = "g/cm³"

    var isValid: Bool {
        (try? Self.validatedName(name)) == name && density.isFinite && density > 0 && density <= Self.maximumDensity
    }

    /// Material names are unique without regard to case.
    var key: String { Self.key(name) }

    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: nil)
    }

    static func validatedName(_ entered: String) throws -> String {
        guard entered.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }) else { throw LADError.message("Material names cannot contain line breaks or control characters.") }
        let name = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LADError.message("Enter a material name.") }
        guard name.utf8.count <= maximumNameBytes else { throw LADError.message("The material name is too long.") }
        return name
    }

    static func validated(name: String, density: Double) throws -> PartMaterial {
        let name = try validatedName(name)
        guard density.isFinite, density > 0, density <= maximumDensity else {
            throw LADError.message("Density must be greater than 0 and at most \(maximumDensity.formatted()) \(densityUnit).")
        }
        return PartMaterial(name: name, density: density)
    }

    /// Mass in grams of a volume in cubic millimeters.
    static func mass(volume: Double, density: Double) -> Double { volume * density / 1_000 }

    /// Typical densities of common engineering metals and plastics.
    static let standard: [PartMaterial] = [
        PartMaterial(name: "ABS", density: 1.05),
        PartMaterial(name: "Acetal (POM)", density: 1.41),
        PartMaterial(name: "Acrylic (PMMA)", density: 1.18),
        PartMaterial(name: "Aluminum 2024", density: 2.78),
        PartMaterial(name: "Aluminum 5052", density: 2.68),
        PartMaterial(name: "Aluminum 6061", density: 2.70),
        PartMaterial(name: "Aluminum 7075", density: 2.81),
        PartMaterial(name: "ASA", density: 1.07),
        PartMaterial(name: "Brass", density: 8.50),
        PartMaterial(name: "Bronze", density: 8.80),
        PartMaterial(name: "Cast Iron", density: 7.20),
        PartMaterial(name: "Copper", density: 8.96),
        PartMaterial(name: "Gold", density: 19.32),
        PartMaterial(name: "HDPE", density: 0.95),
        PartMaterial(name: "Lead", density: 11.34),
        PartMaterial(name: "LDPE", density: 0.92),
        PartMaterial(name: "Magnesium AZ31B", density: 1.77),
        PartMaterial(name: "Nickel", density: 8.90),
        PartMaterial(name: "Nylon 12", density: 1.01),
        PartMaterial(name: "Nylon 6/6", density: 1.14),
        PartMaterial(name: "PEEK", density: 1.32),
        PartMaterial(name: "PETG", density: 1.27),
        PartMaterial(name: "PLA", density: 1.24),
        PartMaterial(name: "Polycarbonate", density: 1.20),
        PartMaterial(name: "Polypropylene", density: 0.90),
        PartMaterial(name: "PTFE", density: 2.20),
        PartMaterial(name: "PVC", density: 1.40),
        PartMaterial(name: "Silver", density: 10.49),
        PartMaterial(name: "Stainless Steel 304", density: 8.00),
        PartMaterial(name: "Stainless Steel 316", density: 8.00),
        PartMaterial(name: "Steel 4140", density: 7.85),
        PartMaterial(name: "Steel, Mild", density: 7.85),
        PartMaterial(name: "Titanium", density: 4.51),
        PartMaterial(name: "Titanium Ti-6Al-4V", density: 4.43),
        PartMaterial(name: "TPU", density: 1.21),
        PartMaterial(name: "Tungsten", density: 19.25),
        PartMaterial(name: "Zinc", density: 7.14)
    ]

    static func alphabetical(_ lhs: PartMaterial, _ rhs: PartMaterial) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.density < rhs.density
        }
    }
}

/// An explicit stable-part assignment. A nil material leaves the part unassigned.
struct CADPartMaterialChange: Codable, Sendable, Equatable {
    var partID: String
    var material: PartMaterial?
}

/// Material state an agent task starts from.
struct CADPartMaterialContext: Sendable {
    /// Current assignments by stable physical part ID.
    var assignments: [String: PartMaterial] = [:]
    /// Materials defined for this design.
    var design: [PartMaterial] = []
    /// This installation's material library.
    var library: [PartMaterial] = PartMaterial.standard
}

/// The material edits a successful agent task commits.
struct CADPartMaterialPatch: Sendable, Equatable {
    var changes: [CADPartMaterialChange] = []
    /// Materials the agent defined for this design during the task.
    var definitions: [PartMaterial] = []
}

/// The current materials of one or more target parts.
struct PartMaterialAssignment: Equatable {
    var materials: Set<PartMaterial> = []
    /// At least one target part has no material.
    var includesUnassigned = false

    static let unassigned = PartMaterialAssignment(includesUnassigned: true)
    static func material(_ material: PartMaterial) -> PartMaterialAssignment { PartMaterialAssignment(materials: [material]) }

    func contains(_ material: PartMaterial?) -> Bool { material.map(materials.contains) ?? includesUnassigned }
}

enum PartMaterialState {
    static let maximumAssignments = 4_096
    static let maximumDesignMaterials = 1_024

    static func physicalIDs(in nodes: [PartNode]) -> Set<String> {
        Set(nodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map(\.id))
    }

    /// Unassigned parts have zero density.
    static func solidDensities(in nodes: [PartNode], materials: [String: PartMaterial]) -> [Int: Double] {
        guard !materials.isEmpty else { return [:] }
        var result: [Int: Double] = [:]
        for node in nodes.flatMap(\.flattened) {
            guard let material = materials[node.id], material.isValid else { continue }
            for solid in node.solidIndices { result[solid] = material.density }
        }
        return result
    }

    /// Validate the complete batch before changing anything. Folder targets
    /// expand to their physical owners; overlapping targets must agree.
    static func normalized(changes: [CADPartMaterialChange], in nodes: [PartNode]) throws -> [CADPartMaterialChange] {
        guard changes.count <= maximumAssignments else {
            throw LADError.message("Change at most \(maximumAssignments.formatted()) part materials at once.")
        }
        var byID: [String: PartNode] = [:]
        for node in nodes.flatMap(\.flattened) {
            guard byID.updateValue(node, forKey: node.id) == nil else {
                throw LADError.message("The design contains duplicate part identities.")
            }
        }
        var result: [String: CADPartMaterialChange] = [:]
        var targets = Set<String>()
        for change in changes {
            guard change.material?.isValid != false else { throw LADError.message("Part materials need a valid name and density.") }
            guard targets.insert(change.partID).inserted else {
                throw LADError.message("Choose each part or folder only once in a material change.")
            }
            guard let node = byID[change.partID] else {
                throw LADError.message("The material target ‘\(change.partID)’ is not part of this design.")
            }
            let physical = node.flattened.filter { !$0.solidIndices.isEmpty }
            guard !physical.isEmpty else {
                throw LADError.message("The material target ‘\(change.partID)’ contains no physical parts.")
            }
            for part in physical {
                let expanded = CADPartMaterialChange(partID: part.id, material: change.material)
                if let previous = result[part.id], previous.material != expanded.material {
                    throw LADError.message("Overlapping material targets assign different materials to ‘\(part.id)’.")
                }
                result[part.id] = expanded
            }
        }
        return result.values.sorted { $0.partID < $1.partID }
    }

    /// Apply changes that already address individual physical owners.
    static func applyingPhysical(changes: [CADPartMaterialChange], to materials: [String: PartMaterial],
                                 in nodes: [PartNode]) throws -> [String: PartMaterial] {
        let ids = physicalIDs(in: nodes)
        var seen = Set<String>()
        for change in changes {
            guard ids.contains(change.partID), seen.insert(change.partID).inserted else {
                throw LADError.message("Material changes must address distinct physical parts in this design.")
            }
            guard change.material?.isValid != false else { throw LADError.message("Part materials need a valid name and density.") }
        }
        var result = materials.filter { ids.contains($0.key) && $0.value.isValid }
        for change in changes { result[change.partID] = change.material }
        return result
    }

    /// Stable part identities keep their materials across refinements. Only an
    /// explicit rebuild of the same program may migrate old generic IDs.
    static func retained(_ materials: [String: PartMaterial], in nodes: [PartNode],
                         remappingGenericFrom previous: [PartNode] = []) -> [String: PartMaterial]? {
        let parts = nodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }
        let ids = Set(parts.map(\.id))
        var result = materials.filter { ids.contains($0.key) }
        for old in previous.flatMap(\.flattened) where old.solidIndices.count == 1 && old.id == "solid/\(old.solidIndices[0])" {
            guard !ids.contains(old.id), let material = materials[old.id] else { continue }
            let matches = parts.filter { $0.solidIndices == old.solidIndices }
            if matches.count == 1, let id = matches.first?.id, result[id] == nil { result[id] = material }
        }
        return result.isEmpty ? nil : result
    }

    /// A task's staged assignments apply to the parts that still exist. A
    /// newer edit made during that task remains current on the parts it changed.
    static func applyingAgentChanges(_ changes: [CADPartMaterialChange], in nodes: [PartNode],
                                     current: [String: PartMaterial],
                                     startedWith snapshot: [String: PartMaterial]) throws -> [String: PartMaterial] {
        let ids = physicalIDs(in: nodes)
        var result = try applyingPhysical(changes: changes.filter { ids.contains($0.partID) },
                                          to: retained(current, in: nodes) ?? [:], in: nodes)
        for id in Set(snapshot.keys).union(current.keys) where ids.contains(id) && current[id] != snapshot[id] {
            result[id] = current[id]
        }
        return result
    }

    /// Add new definitions to a design's materials, keeping existing names.
    static func merging(_ definitions: [PartMaterial], into design: [PartMaterial]) -> [PartMaterial] {
        var result = design
        var names = Set(design.map(\.key))
        for material in definitions where material.isValid && result.count < maximumDesignMaterials {
            if names.insert(material.key).inserted { result.append(material) }
        }
        return result
    }

    static func validateDesignMaterials(_ materials: [PartMaterial]) throws {
        guard materials.count <= maximumDesignMaterials, materials.allSatisfy(\.isValid),
              Set(materials.map(\.key)).count == materials.count else {
            throw LADError.message("The design's materials are invalid.")
        }
    }
}
