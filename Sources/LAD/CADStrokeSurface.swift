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
        matching(mesh, checkCancellation: {})
    }

    static func matchingCancellable(_ mesh: PreviewMesh) throws -> [CADStrokeSurface] {
        try matching(mesh, checkCancellation: { try Task.checkCancellation() })
    }

    private static func matching(_ mesh: PreviewMesh, checkCancellation: () throws -> Void) rethrows -> [CADStrokeSurface] {
        try checkCancellation()
        let segmentCount = mesh.edgeSegmentCount, triangleCount = mesh.triangleCount
        var result = [CADStrokeSurface](repeating: CADStrokeSurface(), count: segmentCount)
        guard segmentCount > 0, triangleCount > 0 else { return result }
        let edgeOwners: [Int]?, triangleOwners: [Int]?
        switch (mesh.edgeSolids, mesh.triangleSolids) {
        case (nil, nil): edgeOwners = nil; triangleOwners = nil
        case (.some(let edges), .some(let triangles)):
            guard edges.count == segmentCount, triangles.count == triangleCount,
                  mesh.solids > 0 else { return result }
            edgeOwners = edges; triangleOwners = triangles
        default:
            // Mixing known and unknown ownership can attach a coincident
            // neighboring part's plane to the wrong CAD edge.
            return result
        }

        let edges = mesh.edgePoints
        var requested: [Segment: Int] = [:]
        requested.reserveCapacity(segmentCount)
        var aliases = [Int](repeating: -1, count: segmentCount)
        for index in 0..<segmentCount {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let owner = edgeOwners?[index] ?? 0, base = index * 6
            guard owner >= 0, edgeOwners == nil || owner < mesh.solids,
                  let start = Point(edges[base], edges[base + 1], edges[base + 2]),
                  let end = Point(edges[base + 3], edges[base + 4], edges[base + 5]), start != end else { continue }
            let segment = Segment(start, end, owner: owner)
            if let original = requested[segment] { aliases[index] = original }
            else { requested[segment] = index; aliases[index] = index }
        }
        guard !requested.isEmpty else { return result }
        let positions = mesh.positions
        let points: [Point?] = try (0..<mesh.vertexCount).map { index in
            if index.isMultiple(of: 256) { try checkCancellation() }
            return Point(positions[index * 3], positions[index * 3 + 1], positions[index * 3 + 2])
        }

        let indices = mesh.triangleIndices
        for index in 0..<triangleCount {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let owner = triangleOwners?[index] ?? 0
            guard owner >= 0, triangleOwners == nil || owner < mesh.solids else { continue }
            let a = Int(indices[index * 3]), b = Int(indices[index * 3 + 1]), c = Int(indices[index * 3 + 2])
            guard a < points.count, b < points.count, c < points.count,
                  let pa = points[a], let pb = points[b], let pc = points[c] else { continue }
            let ab = pa == pb ? nil : requested[Segment(pa, pb, owner: owner)]
            let bc = pb == pc ? nil : requested[Segment(pb, pc, owner: owner)]
            let ca = pc == pa ? nil : requested[Segment(pc, pa, owner: owner)]
            guard ab != nil || bc != nil || ca != nil,
                  let normal = triangleNormal(SIMD3<Double>(mesh.position(a)), SIMD3<Double>(mesh.position(b)),
                                              SIMD3<Double>(mesh.position(c))) else { continue }
            if let ab { result[ab].include(normal) }
            if let bc { result[bc].include(normal) }
            if let ca { result[ca].include(normal) }
        }
        // Duplicate or oppositely directed display segments share the same
        // adjacent planes without multiplying triangle-to-segment work.
        for index in aliases.indices {
            if index.isMultiple(of: 256) { try checkCancellation() }
            guard aliases[index] >= 0, aliases[index] != index else { continue }
            result[index] = result[aliases[index]]
        }
        try checkCancellation()
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

    private static func triangleNormal(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double>? {
        let ab = b - a, ac = c - a
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
        init?(_ x: Float, _ y: Float, _ z: Float) { self.init(Double(x), Double(y), Double(z)) }
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
