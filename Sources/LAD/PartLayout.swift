import Foundation

enum PartLayoutError: LocalizedError, Equatable {
    case unknownNode(String)
    case invalidParent(String)
    case invalidGroup(String)
    case recursiveMove
    case emptyName

    var errorDescription: String? {
        switch self {
        case .unknownNode: return "That part or folder is no longer in the design."
        case .invalidParent: return "Parts can only be moved into a folder."
        case .invalidGroup: return "Choose a folder to ungroup."
        case .recursiveMove: return "A folder cannot be moved into itself or one of its subfolders."
        case .emptyName: return "Enter a name."
        }
    }
}

/// The user's organization is kept apart from Codex's latest assembly tree.
/// Geometry always comes from the latest defaults; only organization is retained.
struct PartLayout: Codable, Sendable, Equatable {
    var nodes: [PartNode]
    var movedNodeIDs: [String] = []
    var userFolderIDs: [String] = []
    var renamedNodes: [String: String] = [:]
    /// Folders are expanded unless their stable identity is listed here.
    var collapsedNodeIDs: [String] = []

    init(nodes: [PartNode], movedNodeIDs: [String] = [], userFolderIDs: [String] = [],
         renamedNodes: [String: String] = [:], collapsedNodeIDs: [String] = []) {
        self.nodes = nodes
        self.movedNodeIDs = movedNodeIDs
        self.userFolderIDs = userFolderIDs
        self.renamedNodes = renamedNodes
        self.collapsedNodeIDs = collapsedNodeIDs
    }

    private enum CodingKeys: String, CodingKey {
        case nodes, movedNodeIDs, userFolderIDs, renamedNodes, collapsedNodeIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try values.decode([PartNode].self, forKey: .nodes)
        movedNodeIDs = try values.decodeIfPresent([String].self, forKey: .movedNodeIDs) ?? []
        userFolderIDs = try values.decodeIfPresent([String].self, forKey: .userFolderIDs) ?? []
        renamedNodes = try values.decodeIfPresent([String: String].self, forKey: .renamedNodes) ?? [:]
        collapsedNodeIDs = try values.decodeIfPresent([String].self, forKey: .collapsedNodeIDs) ?? []
    }

    mutating func setExpanded(_ isExpanded: Bool, for id: String) throws {
        guard let node = Self.index(nodes)[id]?.node else { throw PartLayoutError.unknownNode(id) }
        guard node.isGroup else { throw PartLayoutError.invalidGroup(id) }
        var collapsed = Set(collapsedNodeIDs)
        if isExpanded { collapsed.remove(id) }
        else { collapsed.insert(id) }
        collapsedNodeIDs = collapsed.sorted()
    }

    mutating func move(_ ids: Set<String>, toParent parentID: String?) throws {
        let records = Self.index(nodes)
        for id in ids where records[id] == nil { throw PartLayoutError.unknownNode(id) }
        try validateParent(parentID, records: records)
        let roots = records.values.filter { record in
            ids.contains(record.node.id) && !Self.ancestors(of: record.node.id, in: records).contains(where: ids.contains)
        }.sorted { $0.order < $1.order }
        if let parentID, roots.contains(where: { $0.node.allNodeIDs.contains(parentID) }) {
            throw PartLayoutError.recursiveMove
        }
        let movedIDs = Set(roots.map { $0.node.id })
        var updated = Self.removing(movedIDs, from: nodes)
        let moving = roots.map { $0.node }
        if let parentID {
            _ = Self.edit(parentID, in: &updated) { $0.children = ($0.children ?? []) + moving }
        } else {
            updated.append(contentsOf: moving)
        }
        nodes = updated
        markMoved(moving.map(\.id))
    }

    @discardableResult
    mutating func createFolder(named name: String, parentID: String? = nil) throws -> String {
        let title = try normalizedName(name)
        try validateParent(parentID, records: Self.index(nodes))
        let id = "user-folder:\(UUID().uuidString.lowercased())"
        let folder = PartNode(id: id, name: title, solidIndices: [], children: [])
        if let parentID {
            _ = Self.edit(parentID, in: &nodes) { $0.children = ($0.children ?? []) + [folder] }
        } else {
            nodes.append(folder)
        }
        userFolderIDs.append(id)
        return id
    }

    mutating func rename(_ id: String, to name: String) throws {
        let title = try normalizedName(name)
        guard Self.edit(id, in: &nodes, body: { $0.name = title }) else { throw PartLayoutError.unknownNode(id) }
        renamedNodes[id] = title
    }

    mutating func ungroup(_ id: String) throws {
        guard let record = Self.index(nodes)[id] else { throw PartLayoutError.unknownNode(id) }
        guard record.node.isGroup || userFolderIDs.contains(id) else { throw PartLayoutError.invalidGroup(id) }
        let children = record.node.children ?? []
        let ownSolids = record.node.solidIndices
        var replacement = children
        if !ownSolids.isEmpty {
            var ownPart = record.node
            ownPart.children = nil
            replacement.insert(ownPart, at: 0)
        }
        Self.replacing(id, with: replacement, in: &nodes)
        markMoved(replacement.map(\.id))
        userFolderIDs.removeAll { $0 == id }
        collapsedNodeIDs.removeAll { $0 == id }
        if ownSolids.isEmpty {
            movedNodeIDs.removeAll { $0 == id }
            renamedNodes.removeValue(forKey: id)
        }
    }

    /// Only use when rebuilding the same program: solid indices identify the
    /// old generic leaves before a named assembly tree became available.
    func remappingGenericParts(to defaults: [PartNode]) -> PartLayout {
        let old = Self.index(nodes)
        let owners = Dictionary(grouping: Self.index(defaults).values.filter {
            !$0.node.isGroup && $0.node.solidIndices.count == 1
        }, by: { $0.node.solidIndices[0] })
        var replacements = [String: String]()
        for (id, record) in old {
            guard !record.node.isGroup, record.node.solidIndices.count == 1,
                  !userFolderIDs.contains(id) else { continue }
            let solid = record.node.solidIndices[0]
            guard id == "solid/\(solid)", let matches = owners[solid], matches.count == 1,
                  let owner = matches.first?.node.id, owner != id, old[owner] == nil else { continue }
            replacements[id] = owner
        }
        guard !replacements.isEmpty else { return self }
        func remapped(_ children: [PartNode]) -> [PartNode] {
            children.map { node in
                var result = node
                result.id = replacements[node.id] ?? node.id
                if let children = node.children { result.children = remapped(children) }
                return result
            }
        }
        var result = self
        result.nodes = remapped(nodes)
        result.movedNodeIDs = []
        for id in movedNodeIDs {
            let replacement = replacements[id] ?? id
            if !result.movedNodeIDs.contains(replacement) { result.movedNodeIDs.append(replacement) }
        }
        result.renamedNodes = [:]
        for (id, title) in renamedNodes where replacements[id] == nil { result.renamedNodes[id] = title }
        for (id, title) in renamedNodes {
            if let replacement = replacements[id], result.renamedNodes[replacement] == nil {
                result.renamedNodes[replacement] = title
            }
        }
        let groups = Set(Self.index(result.nodes).values.filter { $0.node.isGroup }.map { $0.node.id })
        result.collapsedNodeIDs = Set(collapsedNodeIDs).intersection(groups).sorted()
        return result
    }

    func reconciled(with defaults: [PartNode], allowingPlacementChanges: Set<String> = []) -> PartLayout {
        let old = Self.index(nodes)
        let current = Self.index(defaults)
        let folders = Set(userFolderIDs).filter { old[$0] != nil }
        let locks = Set(movedNodeIDs).subtracting(allowingPlacementChanges).filter {
            old[$0] != nil && (current[$0] != nil || folders.contains($0))
        }
        var records = current
        let protectedFolders = folders.filter { current[$0] == nil || !allowingPlacementChanges.contains($0) }
        var protected = locks.union(protectedFolders)

        // A surviving moved part may still belong to a folder Codex removed.
        // Restore only that folder's structure, never stale solid indices.
        for id in locks.union(folders) {
            for ancestor in Self.ancestors(of: id, in: old) {
                guard records[ancestor] == nil, var record = old[ancestor], record.node.isGroup else { continue }
                record.node.solidIndices = []
                records[ancestor] = record
                protected.insert(ancestor)
            }
        }
        for id in folders {
            guard let oldRecord = old[id] else { continue }
            var record = current[id] ?? oldRecord
            record.node.name = oldRecord.node.name
            // An explicitly reused folder may now own a generated body. Its
            // current ownership is geometry metadata, not a stale snapshot.
            if current[id] == nil { record.node.solidIndices = [] }
            if record.node.children == nil { record.node.children = [] }
            records[id] = record
        }

        var parents = [String: Placement]()
        for (id, record) in records {
            let proposed = protected.contains(id) ? old[id]?.parent : record.parent
            var parent = proposed
            var visited = Set<String>()
            while let candidate = parent,
                  records[candidate]?.node.isGroup != true && !(folders.contains(candidate) && records[candidate] != nil) {
                guard visited.insert(candidate).inserted else { parent = nil; break }
                parent = old[candidate]?.parent ?? current[candidate]?.parent
            }
            parents[id] = Placement(parent: parent)
        }

        // A new Codex placement can point back into a user-moved group. Break
        // that cycle at an unlocked node so the user's move remains intact.
        for id in records.keys.sorted() {
            var path = [String]()
            var cursor: String? = id
            while let next = cursor {
                if let start = path.firstIndex(of: next) {
                    let cycle = Array(path[start...])
                    let release = cycle.first(where: { !protected.contains($0) }) ?? next
                    parents[release] = Placement(parent: nil)
                    break
                }
                path.append(next)
                cursor = parents[next]?.parent
            }
        }

        var siblings = [String: [String]]()
        for id in records.keys {
            let key = parents[id]?.parent ?? Self.rootKey
            siblings[key, default: []].append(id)
        }
        var oldSiblings = [String: [String]]()
        for record in old.values.sorted(by: { $0.order < $1.order }) {
            oldSiblings[record.parent ?? Self.rootKey, default: []].append(record.node.id)
        }
        for key in Array(siblings.keys) {
            var children = siblings[key, default: []].filter { !protected.contains($0) }.sorted {
                let left = current[$0]?.order ?? Int.max
                let right = current[$1]?.order ?? Int.max
                return left == right ? $0 < $1 : left < right
            }
            let preserved = siblings[key, default: []].filter { protected.contains($0) }.sorted {
                let left = old[$0]?.order ?? Int.max
                let right = old[$1]?.order ?? Int.max
                return left == right ? $0 < $1 : left < right
            }
            var placed = Set(children)
            for id in preserved.reversed() {
                guard let record = old[id] else { children.append(id); continue }
                let previousOrder = oldSiblings[record.parent ?? Self.rootKey, default: []]
                let following = previousOrder.dropFirst(record.siblingIndex + 1)
                let preceding = previousOrder.prefix(record.siblingIndex).reversed()
                if let anchor = following.first(where: placed.contains), let position = children.firstIndex(of: anchor) {
                    children.insert(id, at: position)
                } else if let anchor = preceding.first(where: placed.contains), let position = children.firstIndex(of: anchor) {
                    children.insert(id, at: position + 1)
                } else {
                    children.insert(id, at: min(record.siblingIndex, children.count))
                }
                placed.insert(id)
            }
            siblings[key] = children
        }

        func rebuilt(_ key: String) -> [PartNode] {
            siblings[key, default: []].compactMap { id in
                guard var node = records[id]?.node else { return nil }
                let children = rebuilt(id)
                if node.isGroup || folders.contains(id) { node.children = children }
                if children.isEmpty, !folders.contains(id), locks.contains(id), old[id]?.node.isGroup == false {
                    node.children = nil
                }
                if let title = renamedNodes[id] { node.name = title }
                if node.isGroup, children.isEmpty, node.solidIndices.isEmpty, !folders.contains(id) { return nil }
                return node
            }
        }
        let result = rebuilt(Self.rootKey)
        let retained = Self.index(result)
        let retainedIDs = Set(retained.keys)
        return PartLayout(nodes: result,
                          movedNodeIDs: movedNodeIDs.filter { locks.contains($0) && retainedIDs.contains($0) },
                          userFolderIDs: userFolderIDs.filter { retainedIDs.contains($0) },
                          renamedNodes: renamedNodes.filter { retainedIDs.contains($0.key) },
                          collapsedNodeIDs: Set(collapsedNodeIDs).filter { retained[$0]?.node.isGroup == true }.sorted())
    }

    private static let rootKey = "\u{0}lad-parts-root"
    private struct Placement { var parent: String? }
    private struct Record {
        var node: PartNode
        var parent: String?
        var siblingIndex: Int
        var order: Int
    }

    private static func index(_ nodes: [PartNode]) -> [String: Record] {
        var result = [String: Record]()
        var order = 0
        func visit(_ children: [PartNode], parent: String?) {
            for (position, node) in children.enumerated() {
                guard result[node.id] == nil else { continue }
                result[node.id] = Record(node: node, parent: parent, siblingIndex: position, order: order)
                order += 1
                visit(node.children ?? [], parent: node.id)
            }
        }
        visit(nodes, parent: nil)
        return result
    }

    private static func ancestors(of id: String, in records: [String: Record]) -> [String] {
        var result = [String]()
        var cursor = records[id]?.parent
        while let parent = cursor, !result.contains(parent) {
            result.append(parent)
            cursor = records[parent]?.parent
        }
        return result
    }

    private func normalizedName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PartLayoutError.emptyName }
        return result
    }

    private func validateParent(_ id: String?, records: [String: Record]) throws {
        guard let id else { return }
        guard let node = records[id]?.node else { throw PartLayoutError.unknownNode(id) }
        guard node.isGroup || userFolderIDs.contains(id) else { throw PartLayoutError.invalidParent(id) }
    }

    private mutating func markMoved(_ ids: [String]) {
        for id in ids where !movedNodeIDs.contains(id) { movedNodeIDs.append(id) }
    }

    @discardableResult
    private static func edit(_ id: String, in nodes: inout [PartNode], body: (inout PartNode) -> Void) -> Bool {
        for position in nodes.indices {
            if nodes[position].id == id { body(&nodes[position]); return true }
            if var children = nodes[position].children, edit(id, in: &children, body: body) {
                nodes[position].children = children
                return true
            }
        }
        return false
    }

    private static func removing(_ ids: Set<String>, from nodes: [PartNode]) -> [PartNode] {
        nodes.filter { !ids.contains($0.id) }.map { node in
            var result = node
            if let children = node.children { result.children = removing(ids, from: children) }
            return result
        }
    }

    private static func replacing(_ id: String, with replacement: [PartNode], in nodes: inout [PartNode]) {
        for position in nodes.indices {
            if nodes[position].id == id {
                nodes.replaceSubrange(position...position, with: replacement)
                return
            }
            if var children = nodes[position].children {
                replacing(id, with: replacement, in: &children)
                nodes[position].children = children
            }
        }
    }
}
