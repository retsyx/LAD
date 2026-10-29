import Foundation

/// An explicit, stable-part assignment. A nil color selects the neutral finish.
struct CADPartColorChange: Codable, Sendable, Equatable {
    var partID: String
    var color: PartColor?
}

enum PartColorState {
    static let defaultFinish = PartColor(red: 0.70, green: 0.75, blue: 0.80)

    /// Resolve the current finish for each physical part. Build values supply
    /// colors when there is no saved current value for that stable identity.
    static func resolved(in nodes: [PartNode], overrides: [String: PartColor]) -> [String: PartColor] {
        var result: [String: PartColor] = [:]
        for node in nodes.flatMap(\.flattened) where !node.solidIndices.isEmpty {
            if let color = node.color, color.isValid { result[node.id] = color }
            if let color = overrides[node.id], color.isValid { result[node.id] = color }
        }
        return result
    }

    static func solidColors(in nodes: [PartNode], overrides: [String: PartColor]) -> [Int: PartColor] {
        let colors = resolved(in: nodes, overrides: overrides)
        var result: [Int: PartColor] = [:]
        for node in nodes.flatMap(\.flattened) {
            guard let color = colors[node.id] else { continue }
            for solid in node.solidIndices { result[solid] = color }
        }
        return result
    }

    /// Validate the complete batch before changing anything. Folder targets expand
    /// to their physical owners; overlapping targets must request the same finish.
    static func normalized(changes: [CADPartColorChange], in nodes: [PartNode]) throws -> [CADPartColorChange] {
        guard changes.count <= 4_096 else { throw LADError.message("Change at most 4,096 part colors at once.") }
        let flattened = nodes.flatMap(\.flattened)
        var byID: [String: PartNode] = [:]
        for node in flattened {
            guard byID.updateValue(node, forKey: node.id) == nil else {
                throw LADError.message("The design contains duplicate part identities.")
            }
        }
        var result: [String: CADPartColorChange] = [:]
        var targets = Set<String>()
        for change in changes {
            guard change.color?.isValid != false else {
                throw LADError.message("Part colors must have finite sRGB components between 0 and 1.")
            }
            guard targets.insert(change.partID).inserted else {
                throw LADError.message("Choose each part or folder only once in a color change.")
            }
            guard let node = byID[change.partID] else {
                throw LADError.message("The color target ‘\(change.partID)’ is not part of this design.")
            }
            let physical = node.flattened.filter { !$0.solidIndices.isEmpty }
            guard !physical.isEmpty else { throw LADError.message("The color target ‘\(change.partID)’ contains no physical parts.") }
            for part in physical {
                let expanded = CADPartColorChange(partID: part.id, color: change.color)
                if let previous = result[part.id],
                   (previous.color ?? defaultFinish) != (expanded.color ?? defaultFinish) {
                    throw LADError.message("Overlapping color targets assign different colors to ‘\(part.id)’.")
                }
                result[part.id] = expanded
            }
        }
        return result.values.sorted { $0.partID < $1.partID }
    }

    static func applying(changes: [CADPartColorChange], to overrides: [String: PartColor],
                         in nodes: [PartNode]) throws -> [String: PartColor] {
        try applyingPhysical(changes: normalized(changes: changes, in: nodes), to: overrides, in: nodes)
    }

    /// A staged patch already addresses individual physical owners. A folder
    /// can own solids too, so expanding these IDs again would recolor children.
    static func applyingPhysical(changes: [CADPartColorChange], to colors: [String: PartColor],
                                 in nodes: [PartNode]) throws -> [String: PartColor] {
        guard changes.count <= 4_096 else { throw LADError.message("Change at most 4,096 part colors at once.") }
        let ids = Set(nodes.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map(\.id))
        var seen = Set<String>()
        for change in changes {
            guard ids.contains(change.partID), seen.insert(change.partID).inserted else {
                throw LADError.message("Color changes must address distinct physical parts in this design.")
            }
            guard change.color?.isValid != false else {
                throw LADError.message("Part colors must have finite sRGB components between 0 and 1.")
            }
        }
        var result = colors.filter { ids.contains($0.key) && $0.value.isValid }
        for change in changes { result[change.partID] = change.color ?? defaultFinish }
        return result
    }

    /// Staged metadata describes current RGB values without changing saved
    /// hierarchy or the original build-provided values in document state.
    static func nodesWithCurrentColors(_ nodes: [PartNode], stored: [String: PartColor]) -> [PartNode] {
        let colors = resolved(in: nodes, overrides: stored)
        func copy(_ nodes: [PartNode]) -> [PartNode] {
            nodes.map { node in
                var result = node
                result.color = node.solidIndices.isEmpty ? nil : colors[node.id] ?? defaultFinish
                result.children = node.children.map(copy)
                return result
            }
        }
        return copy(nodes)
    }

}
