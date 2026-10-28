import Foundation

/// Adjacent display-triangle planes for a sampled CAD edge. Zero means no
/// reliable matching plane, allowing the renderer's conservative fallback.
struct CADStrokeSurface: Sendable {
    var first: SIMD3<Double> = .zero
    var second: SIMD3<Double> = .zero

    /// Match coordinates instead of mesh indices: OpenCascade duplicates
    /// vertices at face boundaries and supplies already located world points.
    /// Only requested segments enter the lookup; each triangle is visited once.
    static func matching(_ mesh: PreviewMesh) -> [CADStrokeSurface] {
        var result = [CADStrokeSurface](repeating: CADStrokeSurface(), count: mesh.edges.count)
        guard !mesh.edges.isEmpty, !mesh.triangles.isEmpty else { return result }
        let edgeOwners: [Int]?, triangleOwners: [Int]?
        switch (mesh.edgeSolids, mesh.triangleSolids) {
        case (nil, nil): edgeOwners = nil; triangleOwners = nil
        case (.some(let edges), .some(let triangles)):
            guard edges.count == mesh.edges.count, triangles.count == mesh.triangles.count,
                  mesh.solids > 0 else { return result }
            edgeOwners = edges; triangleOwners = triangles
        default:
            // Mixing known and unknown ownership can attach a coincident
            // neighboring part's plane to the wrong CAD edge.
            return result
        }

        var requested: [Segment: Int] = [:]
        requested.reserveCapacity(mesh.edges.count)
        var aliases = [Int](repeating: -1, count: mesh.edges.count)
        for (index, edge) in mesh.edges.enumerated() {
            let owner = edgeOwners?[index] ?? 0
            guard edge.count == 6, owner >= 0, edgeOwners == nil || owner < mesh.solids,
                  let start = Point(edge[0], edge[1], edge[2]),
                  let end = Point(edge[3], edge[4], edge[5]), start != end else { continue }
            let segment = Segment(start, end, owner: owner)
            if let original = requested[segment] { aliases[index] = original }
            else { requested[segment] = index; aliases[index] = index }
        }
        guard !requested.isEmpty else { return result }
        let points: [Point?] = mesh.vertices.map {
            guard $0.count == 3 else { return nil }
            return Point($0[0], $0[1], $0[2])
        }

        for (index, triangle) in mesh.triangles.enumerated() {
            let owner = triangleOwners?[index] ?? 0
            guard triangle.count == 3, owner >= 0, triangleOwners == nil || owner < mesh.solids else { continue }
            let a = triangle[0], b = triangle[1], c = triangle[2]
            guard a >= 0, a < points.count, b >= 0, b < points.count, c >= 0, c < points.count,
                  let pa = points[a], let pb = points[b], let pc = points[c] else { continue }
            let ab = pa == pb ? nil : requested[Segment(pa, pb, owner: owner)]
            let bc = pb == pc ? nil : requested[Segment(pb, pc, owner: owner)]
            let ca = pc == pa ? nil : requested[Segment(pc, pa, owner: owner)]
            guard ab != nil || bc != nil || ca != nil,
                  let normal = triangleNormal(mesh.vertices[a], mesh.vertices[b], mesh.vertices[c]) else { continue }
            if let ab { result[ab].include(normal) }
            if let bc { result[bc].include(normal) }
            if let ca { result[ca].include(normal) }
        }
        // Duplicate or oppositely directed display segments share the same
        // adjacent planes without multiplying triangle-to-segment work.
        for index in aliases.indices where aliases[index] >= 0 && aliases[index] != index {
            result[index] = result[aliases[index]]
        }
        return result
    }

    private mutating func include(_ normal: SIMD3<Double>) {
        if first == .zero { first = normal; return }
        guard second == .zero else { return }
        // Opposite windings still describe one plane. Keep the first actual
        // triangle's winding, while deduplicating coplanar neighbors.
        let dot = first.x * normal.x + first.y * normal.y + first.z * normal.z
        if abs(dot) < 1 - 1e-12 { second = normal }
    }

    private static func triangleNormal(_ a: [Double], _ b: [Double], _ c: [Double]) -> SIMD3<Double>? {
        let ab = SIMD3(b[0] - a[0], b[1] - a[1], b[2] - a[2])
        let ac = SIMD3(c[0] - a[0], c[1] - a[1], c[2] - a[2])
        let scale = max(abs(ab.x), abs(ab.y), abs(ab.z), abs(ac.x), abs(ac.y), abs(ac.z))
        guard scale.isFinite, scale > 0 else { return nil }
        let u = ab / scale, v = ac / scale
        let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        let crossScale = max(abs(cross.x), abs(cross.y), abs(cross.z))
        guard crossScale.isFinite, crossScale > 0 else { return nil }
        let n = cross / crossScale
        let length = sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
        guard length.isFinite, length > 0 else { return nil }
        return n / length
    }

    private struct Point: Hashable {
        let x: Int64, y: Int64, z: Int64
        init?(_ x: Double, _ y: Double, _ z: Double) {
            // Int64(exactly:) rejects nonfinite and out-of-range values without
            // trapping at Double's rounded representation of Int64.max.
            guard let x = Int64(exactly: (x * 10_000_000).rounded()),
                  let y = Int64(exactly: (y * 10_000_000).rounded()),
                  let z = Int64(exactly: (z * 10_000_000).rounded()) else { return nil }
            self.x = x; self.y = y; self.z = z
        }
        func precedes(_ other: Point) -> Bool {
            x != other.x ? x < other.x : y != other.y ? y < other.y : z < other.z
        }
    }

    private struct Segment: Hashable {
        let start: Point, end: Point
        let owner: Int
        init(_ a: Point, _ b: Point, owner: Int) {
            if a.precedes(b) { start = a; end = b }
            else { start = b; end = a }
            self.owner = owner
        }
    }
}
