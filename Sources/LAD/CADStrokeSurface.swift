import Foundation

/// Adjacent display-triangle planes for a sampled CAD edge. Zero means no
/// reliable matching plane, allowing the renderer's conservative fallback.
struct CADStrokeSurface: Sendable {
    var first: SIMD3<Double> = .zero
    var second: SIMD3<Double> = .zero

    struct Join: Sendable {
        let origin: SIMD3<Float>
        let first: SIMD3<Float>
        let second: SIMD3<Float>
        let neighbor: SIMD3<Float>
    }

    /// Match coordinates instead of mesh indices: OpenCascade duplicates
    /// vertices at face boundaries and supplies already located world points.
    /// Only requested segments enter the lookup; each triangle is visited once.
    static func matchingCancellable(_ mesh: PreviewMesh) throws -> [CADStrokeSurface] {
        try matchingCancellable(mesh, recordSupport: nil)
    }

    private static func matchingCancellable(_ mesh: PreviewMesh,
        recordSupport: ((Segment, Int, SIMD3<Double>, SIMD3<Double>) -> Void)?) throws -> [CADStrokeSurface] {
        func checkCancellation() throws { try Task.checkCancellation() }
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
            guard ab != nil || bc != nil || ca != nil else { continue }
            let anchor = SIMD3<Double>(mesh.position(a))
            guard let normal = triangleNormal(anchor, SIMD3<Double>(mesh.position(b)),
                                              SIMD3<Double>(mesh.position(c))) else { continue }
            if let ab { result[ab].include(normal) }
            if let bc { result[bc].include(normal) }
            if let ca { result[ca].include(normal) }
            if let recordSupport {
                if ab != nil { recordSupport(Segment(pa, pb, owner: owner), index, normal, anchor) }
                if bc != nil { recordSupport(Segment(pb, pc, owner: owner), index, normal, anchor) }
                if ca != nil { recordSupport(Segment(pc, pa, owner: owner), index, normal, anchor) }
            }
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

    /// At a polyline joint, the stroke cap can cross triangles in the same
    /// face that do not share either segment. Retain their actual finite
    /// coverage, scoped to the solid, native face, and exact shared endpoint.
    static func matchingDisplay(_ mesh: PreviewMesh) throws -> (surfaces: [CADStrokeSurface], joins: [Int: [Join]]) {
        try Task.checkCancellation()
        let segmentCount = mesh.edgeSegmentCount, triangleCount = mesh.triangleCount
        let vertexCount = mesh.vertexCount
        guard (2...250_000).contains(segmentCount), (1...1_000_000).contains(triangleCount),
              (1...1_000_000).contains(vertexCount),
              mesh.edgePoints.count.isMultiple(of: 6), mesh.positions.count.isMultiple(of: 3),
              mesh.triangleIndices.count.isMultiple(of: 3),
              let topology = mesh.topology,
              let edgeOwners = mesh.edgeSolids, edgeOwners.count == segmentCount,
              let features = mesh.edgeFeatures, features.count == segmentCount,
              let triangleOwners = mesh.triangleSolids, triangleOwners.count == triangleCount,
              let faces = mesh.triangleFaces, faces.count == triangleCount else { return (try matchingCancellable(mesh), [:]) }

        func endpoint(_ segment: Int, end: Bool) -> SIMD3<Float> {
            let index = segment * 6 + (end ? 3 : 0)
            return SIMD3(mesh.edgePoints[index], mesh.edgePoints[index + 1], mesh.edgePoints[index + 2])
        }
        func segment(at index: Int) -> Segment? {
            let owner = edgeOwners[index], feature = features[index]
            guard owner >= 0, owner < mesh.solids, topology.edges.indices.contains(feature),
                  topology.edges[feature].id.kind == .edge, topology.edges[feature].id.solidIndex == owner,
                  let a = Point(endpoint(index, end: false)), let b = Point(endpoint(index, end: true)),
                  a != b else { return nil }
            return Segment(a, b, owner: owner)
        }
        var jointsAtStart = [Bool](repeating: false, count: segmentCount)
        var jointsAtEnd = jointsAtStart
        func markJoint(_ previous: Int, _ next: Int) {
            guard previous != next, endpoint(previous, end: true) == endpoint(next, end: false),
                  segment(at: previous) != nil, segment(at: next) != nil else { return }
            jointsAtEnd[previous] = true
            jointsAtStart[next] = true
        }
        var runStart = 0
        for index in 1..<segmentCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if edgeOwners[index] == edgeOwners[index - 1], features[index] == features[index - 1] {
                markJoint(index - 1, index)
            } else {
                if topology.edges.indices.contains(features[runStart]), topology.edges[features[runStart]].closed == true {
                    markJoint(index - 1, runStart)
                }
                runStart = index
            }
        }
        if topology.edges.indices.contains(features[runStart]), topology.edges[features[runStart]].closed == true {
            markJoint(segmentCount - 1, runStart)
        }

        struct FaceSupport {
            let face: Int
            let anchor: SIMD3<Double>
            var normal: SIMD3<Double>?

            mutating func include(_ candidate: SIMD3<Double>) {
                guard let normal else { return }
                // Conflicting oriented planes cannot give an exclusion.
                if CADStrokeSurface.dot(normal, candidate) < 1 - 1e-12 { self.normal = nil }
            }

            func isBehind(_ point: SIMD3<Float>) -> Bool {
                guard let normal else { return false }
                let displacement = SIMD3<Double>(point) - anchor
                let rounding = 8 * Double.ulpOfOne * max(1, abs(displacement.x), abs(displacement.y), abs(displacement.z))
                return CADStrokeSurface.dot(normal, displacement) <= rounding
            }
        }
        struct DirectSupport {
            var planes = CADStrokeSurface()
            var firstFace: FaceSupport? = nil
            var secondFace: FaceSupport? = nil
            var ambiguous = false

            mutating func include(face: Int, normal: SIMD3<Double>, anchor: SIMD3<Double>) {
                if firstFace?.face == face { firstFace?.include(normal) }
                else if secondFace?.face == face { secondFace?.include(normal) }
                else if firstFace == nil { firstFace = FaceSupport(face: face, anchor: anchor, normal: normal) }
                else if secondFace == nil { secondFace = FaceSupport(face: face, anchor: anchor, normal: normal) }
                else { ambiguous = true }
                planes.include(normal)
            }
        }
        var direct = [Segment: DirectSupport]()
        for index in 0..<segmentCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard jointsAtStart[index] || jointsAtEnd[index], let key = segment(at: index) else { continue }
            direct[key] = DirectSupport()
        }
        guard !direct.isEmpty else { return (try matchingCancellable(mesh), [:]) }

        func face(at index: Int, owner: Int) -> Int? {
            let face = faces[index]
            guard owner >= 0, owner < mesh.solids, topology.faces.indices.contains(face),
                  topology.faces[face].id.kind == .face, topology.faces[face].id.solidIndex == owner else { return nil }
            return face
        }
        func triangle(at index: Int) -> (owner: Int, face: Int, a: Int, b: Int, c: Int)? {
            let owner = triangleOwners[index], offset = index * 3
            guard let face = face(at: index, owner: owner), topology.faces[face].type != "PLANE" else { return nil }
            let a = Int(mesh.triangleIndices[offset]), b = Int(mesh.triangleIndices[offset + 1])
            let c = Int(mesh.triangleIndices[offset + 2])
            guard a < vertexCount, b < vertexCount, c < vertexCount else { return nil }
            return (owner, face, a, b, c)
        }
        let surfaces = try matchingCancellable(mesh) { key, triangle, normal, anchor in
            guard let face = face(at: triangle, owner: key.owner) else { return }
            direct[key]?.include(face: face, normal: normal, anchor: anchor)
        }

        struct FanCorner: Hashable {
            let origin: SIMD3<Float>
            let face: Int
        }
        struct IncidentSegment {
            let neighbor: SIMD3<Float>
            let planes: CADStrokeSurface
            let face: FaceSupport
        }
        var fans = [FanCorner: [IncidentSegment]]()
        for index in 0..<segmentCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard jointsAtStart[index] || jointsAtEnd[index], let key = segment(at: index),
                  let support = direct[key], !support.ambiguous, let first = support.firstFace else { continue }
            func register(in face: FaceSupport, end: Bool) {
                // An exactly planar CAD face has no additional plane at its
                // edge. Retain its ordinary direct support, without fan work.
                guard topology.faces[face.face].type != "PLANE" else { return }
                let corner = FanCorner(origin: endpoint(index, end: end), face: face.face)
                // A coincident vertex with many CAD edges must not multiply
                // every triangle in a malformed or unusually dense fan.
                guard fans[corner, default: []].count < 32 else { return }
                fans[corner, default: []].append(IncidentSegment(neighbor: endpoint(index, end: !end),
                                                                  planes: support.planes, face: face))
            }
            if jointsAtStart[index] { register(in: first, end: false) }
            if jointsAtEnd[index] { register(in: first, end: true) }
            if let second = support.secondFace {
                if jointsAtStart[index] { register(in: second, end: false) }
                if jointsAtEnd[index] { register(in: second, end: true) }
            }
        }

        var result = [Int: [Join]]()
        var remaining = 250_000
        for index in 0..<triangleCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if remaining == 0 { break }
            guard let (owner, face, a, b, c) = triangle(at: index) else { continue }
            let pa = mesh.position(a), pb = mesh.position(b), pc = mesh.position(c)
            let atA = fans[FanCorner(origin: pa, face: face)]
            let atB = fans[FanCorner(origin: pb, face: face)]
            let atC = fans[FanCorner(origin: pc, face: face)]
            guard atA != nil || atB != nil || atC != nil,
                  let normal = triangleNormal(SIMD3<Double>(pa), SIMD3<Double>(pb), SIMD3<Double>(pc)) else { continue }
            func append(_ segments: [IncidentSegment]?, origin: SIMD3<Float>, first: SIMD3<Float>, second: SIMD3<Float>) {
                guard let segments else { return }
                for segment in segments {
                    if remaining == 0 { break }
                    let planes = segment.planes
                    guard segment.neighbor != first, segment.neighbor != second,
                          !coplanar(planes.first, normal), !coplanar(planes.second, normal) else { continue }
                    // A triangle entirely behind its own supporting face
                    // cannot cut a stroke drawn on that front-facing plane.
                    if segment.face.isBehind(first), segment.face.isBehind(second), segment.face.isBehind(origin) { continue }
                    result[owner, default: []].append(Join(origin: origin, first: first, second: second,
                                                          neighbor: segment.neighbor))
                    remaining -= 1
                }
            }
            append(atA, origin: pa, first: pb, second: pc)
            append(atB, origin: pb, first: pc, second: pa)
            append(atC, origin: pc, first: pa, second: pb)
        }
        try Task.checkCancellation()
        return (surfaces, result)
    }

    private mutating func include(_ normal: SIMD3<Double>) {
        if first == .zero { first = normal; return }
        guard second == .zero else { return }
        // Opposite windings still describe one plane. Keep the first actual
        // triangle's winding, while deduplicating coplanar neighbors.
        if !Self.coplanar(first, normal) { second = normal }
    }

    private static func coplanar(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        abs(dot(a, b)) >= 1 - 1e-12
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
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
        init?(_ p: SIMD3<Float>) { self.init(p.x, p.y, p.z) }
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
