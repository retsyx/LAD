enum PartSelection {
    /// Keeps complete selected folders when possible, and represents a partial
    /// folder selection with the selected parts inside it instead.
    static func nodeIDs(for solids: Set<Int>, keeping preferred: Set<String>, in roots: [PartNode]) -> Set<String> {
        var selected = Set<String>()
        var covered = Set<Int>()

        func preserve(_ nodes: [PartNode]) {
            for node in nodes {
                let geometry = node.allSolidIndices
                if preferred.contains(node.id), geometry.isSubset(of: solids),
                   node.isGroup || !geometry.isEmpty {
                    selected.insert(node.id)
                    covered.formUnion(geometry)
                } else {
                    preserve(node.children ?? [])
                }
            }
        }
        preserve(roots)

        let nodes = roots.flatMap(\.flattened)
        for node in nodes where !node.isGroup {
            let geometry = Set(node.solidIndices)
            guard geometry.isSubset(of: solids), !geometry.isDisjoint(with: solids.subtracting(covered)) else { continue }
            selected.insert(node.id)
            covered.formUnion(geometry)
        }

        // Assemblies may own a body directly. Use their folder ID only when
        // that also describes the complete selection of their descendants.
        for node in nodes where node.isGroup {
            let ownGeometry = Set(node.solidIndices)
            guard !ownGeometry.isDisjoint(with: solids.subtracting(covered)),
                  node.allSolidIndices.isSubset(of: solids) else { continue }
            selected.insert(node.id)
            covered.formUnion(node.allSolidIndices)
        }

        var canonical = Set<String>()
        func removeDescendants(_ nodes: [PartNode]) {
            for node in nodes {
                if selected.contains(node.id) { canonical.insert(node.id) }
                else { removeDescendants(node.children ?? []) }
            }
        }
        removeDescendants(roots)
        return canonical
    }
}
