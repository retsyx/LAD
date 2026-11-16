import Foundation
import simd

/// Corresponding native features of two builds of the same parts, such as a
/// design and its 3D printing version, whose solid indices identify the same
/// parts. A feature that the other build leaves unchanged has identical exact
/// geometry there. A changed feature, such as a counterbore floor that a
/// sacrificial bridge closes, corresponds to the nearby changed feature of the
/// same kind, type and direction on its part when each is the other's unique
/// nearest. Other features have no counterpart; native indices are never
/// carried from one build to another.
enum CADFeatureCorrespondence {
    /// Counterparts of `features` of `source` in `target`, in selection order.
    static func features(_ features: [CADFeatureID], from source: CADTopology, to target: CADTopology) -> [CADFeatureID] {
        var groups: [GroupKey: (source: Group, target: Group)] = [:]
        var found = Set<CADFeatureID>()
        return features.compactMap { feature in
            let key = GroupKey(solid: feature.solidIndex, kind: feature.kind)
            if groups[key] == nil {
                let scale = source.parts.first { $0.solidIndex == feature.solidIndex }.map { part in
                    simd_distance(vector(Array(part.bounds.prefix(3))) ?? .zero, vector(Array(part.bounds.suffix(3))) ?? .zero)
                } ?? 0
                groups[key] = (Group(source, key: key, scale: scale), Group(target, key: key, scale: scale))
            }
            guard let pair = groups[key], let facts = pair.source.facts(for: feature),
                  let match = counterpart(of: facts, from: pair.source, to: pair.target),
                  found.insert(match).inserted else { return nil }
            return match
        }
    }

    private static func counterpart(of feature: Facts, from source: Group, to target: Group) -> CADFeatureID? {
        if let same = target.unchanged(feature) { return same.id }
        guard let location = feature.location else { return nil }
        var nearest: (facts: Facts, distance: Double)?
        var ambiguous = false
        for candidate in target.items where source.compatible(feature, candidate) {
            guard let other = candidate.location else { continue }
            let distance = simd_distance(location, other)
            guard distance <= source.reach(feature, candidate) else { continue }
            if let best = nearest, distance > best.distance + source.tolerance { continue }
            guard source.unchanged(candidate) == nil else { continue }
            if let best = nearest, distance >= best.distance - source.tolerance {
                ambiguous = true
            } else {
                ambiguous = false
                nearest = (candidate, distance)
            }
        }
        guard let nearest, !ambiguous, let destination = nearest.facts.location else { return nil }
        // The replaced feature must also be the counterpart's unique nearest.
        let rival = source.items.contains { other in
            guard other.id != feature.id, source.compatible(other, nearest.facts), let position = other.location,
                  simd_distance(position, destination) <= nearest.distance + source.tolerance else { return false }
            return target.unchanged(other) == nil
        }
        return rival ? nil : nearest.facts.id
    }

    private struct GroupKey: Hashable {
        var solid: Int
        var kind: CADFeatureKind
    }

    /// Exact facts of one native feature.
    private struct Facts {
        var id: CADFeatureID
        var type: String
        /// A vertex position, an edge's center or a face's area centroid.
        var point: SIMD3<Double>?
        /// An edge's endpoints, in either order.
        var start: SIMD3<Double>?
        var end: SIMD3<Double>?
        var measures: [Double?]
        /// A plane's oriented normal.
        var normal: SIMD3<Double>?
        /// An axis or line direction, in either sense.
        var axis: SIMD3<Double>?
        /// Where a changed feature is compared with its counterpart.
        var location: SIMD3<Double>?
        /// Edge length or square root of face area; zero for a vertex.
        var size: Double

        init(_ vertex: CADVertex) {
            id = vertex.id; type = "vertex"; point = vector(vertex.position); measures = []
            location = point; size = 0
        }

        init(_ edge: CADEdge) {
            id = edge.id; type = edge.type; point = vector(edge.center)
            start = vector(edge.startPoint); end = vector(edge.endPoint)
            measures = [edge.length, edge.radius, edge.majorRadius, edge.minorRadius, edge.sweepDegrees]
            axis = vector(edge.axis ?? edge.direction); size = edge.length
            if let start, let end, edge.closed != true, simd_distance(start, end) > 0 { location = (start + end) / 2 }
            else if let point { location = point }
            else if !edge.polyline.isEmpty {
                let points = edge.polyline.compactMap(vector)
                location = points.isEmpty ? start : points.reduce(.zero, +) / Double(points.count)
            } else { location = start }
        }

        init(_ face: CADFace) {
            id = face.id; type = face.type; point = vector(face.center)
            measures = [face.area, face.perimeter, face.radius, face.majorRadius, face.minorRadius, face.semiAngleDegrees]
            normal = vector(face.normal); axis = vector(face.axis); location = point; size = face.area.squareRoot()
        }

        /// The positions that find an identical feature.
        var keys: [SIMD3<Double>] { [point ?? start, start, end].compactMap { $0 } }
    }

    /// One kind of feature on one part of one build.
    private struct Group {
        var items: [Facts] = []
        var byLocalIndex: [Int: Int] = [:]
        var cells: [SIMD3<Int64>: [Int]] = [:]
        /// Exact geometry agrees within a millionth of the part's size.
        var tolerance: Double
        /// A changed feature stays within half its size, or a hundredth of
        /// the part's size, of the feature it replaces.
        var partReach: Double
        var cell: Double

        init(_ topology: CADTopology, key: GroupKey, scale: Double) {
            tolerance = 1e-6 * max(1, scale); partReach = 0.01 * scale; cell = tolerance * 1_000
            switch key.kind {
            case .vertex: items = topology.vertices.filter { $0.id.solidIndex == key.solid }.map(Facts.init)
            case .edge: items = topology.edges.filter { $0.id.solidIndex == key.solid }.map(Facts.init)
            case .face: items = topology.faces.filter { $0.id.solidIndex == key.solid }.map(Facts.init)
            }
            for (index, item) in items.enumerated() {
                byLocalIndex[item.id.localIndex] = index
                for key in Set(item.keys.map(cellKey)) { cells[key, default: []].append(index) }
            }
        }

        func facts(for id: CADFeatureID) -> Facts? { byLocalIndex[id.localIndex].map { items[$0] } }

        /// This build's feature with exactly the geometry of `feature`.
        func unchanged(_ feature: Facts) -> Facts? {
            guard let key = feature.keys.first else { return nil }
            let center = cellKey(key)
            var matches: [Facts] = []
            for x in -1...1 { for y in -1...1 { for z in -1...1 {
                for index in cells[center &+ SIMD3(Int64(x), Int64(y), Int64(z))] ?? [] where same(items[index], feature) {
                    matches.append(items[index])
                }
            } } }
            return matches.first { $0.id.localIndex == feature.id.localIndex } ?? matches.min { $0.id.localIndex < $1.id.localIndex }
        }

        func compatible(_ a: Facts, _ b: Facts) -> Bool {
            a.type == b.type && direction(a.normal, b.normal, oriented: true) && direction(a.axis, b.axis, oriented: false)
        }

        func reach(_ a: Facts, _ b: Facts) -> Double { max(0.5 * max(a.size, b.size), partReach) }

        private func same(_ a: Facts, _ b: Facts) -> Bool {
            func near(_ p: SIMD3<Double>?, _ q: SIMD3<Double>?) -> Bool {
                switch (p, q) {
                case (nil, nil): return true
                case let (p?, q?): return simd_distance(p, q) <= tolerance
                default: return false
                }
            }
            func equal(_ x: Double?, _ y: Double?) -> Bool {
                switch (x, y) {
                case (nil, nil): return true
                case let (x?, y?): return abs(x - y) <= 1e-6 * max(1, abs(x), abs(y))
                default: return false
                }
            }
            return compatible(a, b) && a.measures.count == b.measures.count && near(a.point, b.point) &&
                ((near(a.start, b.start) && near(a.end, b.end)) || (near(a.start, b.end) && near(a.end, b.start))) &&
                zip(a.measures, b.measures).allSatisfy { equal($0.0, $0.1) }
        }

        private func cellKey(_ point: SIMD3<Double>) -> SIMD3<Int64> {
            SIMD3(Int64((point.x / cell).rounded(.down)), Int64((point.y / cell).rounded(.down)), Int64((point.z / cell).rounded(.down)))
        }
    }

    private static func direction(_ a: SIMD3<Double>?, _ b: SIMD3<Double>?, oriented: Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            let length = simd_length(a) * simd_length(b)
            guard length > 0 else { return false }
            let cosine = simd_dot(a, b) / length
            return (oriented ? cosine : abs(cosine)) >= 1 - 1e-9
        default: return false
        }
    }
}

private func vector(_ values: [Double]?) -> SIMD3<Double>? {
    guard let values, values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
    return SIMD3(values[0], values[1], values[2])
}
