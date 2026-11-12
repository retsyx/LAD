import Foundation
import simd

/// Immutable CPU drawing inputs. Preparing these buffers never creates or
/// mutates SceneKit objects, so large previews can leave the main actor before
/// native scene installation and renderer resource preparation.
struct CADViewportPreparedMesh: Sendable {
    let mesh: PreviewMesh
    let vertexData: Data
    let normalData: Data
    let vertexCount: Int
    let groups: [Int: [Int32]]
    let faceIDsBySolid: [Int: [CADFeatureID?]]
    let faceIndices: [CADFeatureID: [Int32]]
    let faceBounds: [CADFeatureID: CADSilhouetteBatching.Bounds]
    let solidBounds: [Int: [Double]]
    let edges: [Int: CADStrokeGeometry.Prepared]
    let hasOwnedEdges: Bool

    static func requiresBackgroundPreparation(_ mesh: PreviewMesh) -> Bool {
        // Bound every collection traversed even for synthetic previews whose
        // optional topology can be much larger than their display mesh.
        var remaining = 2_048
        for count in [mesh.vertexCount, mesh.triangleCount, mesh.edgeSegmentCount, mesh.topology?.parts.count ?? 0] {
            guard count <= remaining else { return true }
            remaining -= count
        }
        return false
    }

    /// Invalid display data is rejected at the same boundary as scene install.
    /// Cancellation is distinct from invalid input and propagates to its owner.
    static func prepare(_ mesh: PreviewMesh) throws -> Self? {
        try Task.checkCancellation()
        let vertexCount = mesh.vertexCount, triangleCount = mesh.triangleCount
        guard mesh.bounds.count == 6, mesh.bounds.allSatisfy({ $0.isFinite && abs($0) < 1e12 }),
              (0..<3).allSatisfy({ mesh.bounds[$0] <= mesh.bounds[$0 + 3] }),
              mesh.positions.count.isMultiple(of: 3), mesh.triangleIndices.count.isMultiple(of: 3),
              (1...1_000_000).contains(vertexCount), (1...1_000_000).contains(triangleCount) else { return nil }
        for (index, value) in mesh.positions.enumerated() {
            if index.isMultiple(of: 768) { try Task.checkCancellation() }
            guard value.isFinite, abs(value) < 1e12 else { return nil }
        }
        let maximumIndex = UInt32(vertexCount)
        for (index, vertex) in mesh.triangleIndices.enumerated() {
            if index.isMultiple(of: 768) { try Task.checkCancellation() }
            guard vertex < maximumIndex else { return nil }
        }
        if mesh.vertexNormals != nil {
            try Task.checkCancellation()
            guard mesh.hasValidNormals else { return nil }
        }
        // SceneKit uploads Float32 attributes; the packed arrays already match.
        let vertexData = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = try mesh.vertexNormals.map { normals in normals.withUnsafeBufferPointer { Data(buffer: $0) } }
            ?? smoothNormals(mesh)

        let solidMap = try validOwners(mesh.triangleSolids, count: triangleCount, solids: mesh.solids)
        var groups = [Int: [Int32]](), faceIDsBySolid = [Int: [CADFeatureID?]]()
        var faceIndices = [CADFeatureID: [Int32]](), faceBounds = [CADFeatureID: CADSilhouetteBatching.Bounds]()
        for index in 0..<triangleCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let solid = solidMap?[index] ?? 0
            let base = index * 3
            let corners: [Int32] = [Int32(mesh.triangleIndices[base]), Int32(mesh.triangleIndices[base + 1]),
                                    Int32(mesh.triangleIndices[base + 2])]
            groups[solid, default: []].append(contentsOf: corners)
            let feature = faceID(forTriangle: index, in: mesh, solid: solid)
            faceIDsBySolid[solid, default: []].append(feature)
            if let feature {
                faceIndices[feature, default: []].append(contentsOf: corners)
                for vertex in corners { faceBounds[feature, default: .init()].include(mesh.position(Int(vertex))) }
            }
        }

        var solidBounds = [Int: [Double]]()
        for (index, part) in (mesh.topology?.parts ?? []).enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if part.bounds.count == 6, part.bounds.allSatisfy(\.isFinite) { solidBounds[part.solidIndex] = part.bounds }
        }
        // Exact native bounds take precedence. Synthetic previews retain the
        // existing triangle-buffer fallback without changing fit or ownership.
        for (solid, indices) in groups where solidBounds[solid] == nil {
            var bounds = CADSilhouetteBatching.Bounds()
            for (index, vertex) in indices.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                bounds.include(mesh.position(Int(vertex)))
            }
            solidBounds[solid] = bounds.values
        }

        let segmentCount = mesh.edgePoints.count.isMultiple(of: 6) ? min(mesh.edgeSegmentCount, 250_000) : 0
        let owners = try validOwners(mesh.edgeSolids, count: mesh.edgeSegmentCount, solids: mesh.solids)
        let surfaces = try CADStrokeSurface.matchingCancellable(mesh)
        // Group segment indices by owner; the stroke buffers read the packed
        // points directly.
        var edgeGroups = [Int: [Int]]()
        for index in 0..<segmentCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            edgeGroups[owners?[index] ?? -1, default: []].append(index)
        }
        var edges = [Int: CADStrokeGeometry.Prepared]()
        for (solid, segments) in edgeGroups {
            edges[solid] = try CADStrokeGeometry.prepare(points: mesh.edgePoints, segments: segments, surfaces: surfaces)
        }
        try Task.checkCancellation()
        return Self(mesh: mesh, vertexData: vertexData, normalData: normalData, vertexCount: vertexCount,
                    groups: groups, faceIDsBySolid: faceIDsBySolid, faceIndices: faceIndices, faceBounds: faceBounds,
                    solidBounds: solidBounds, edges: edges, hasOwnedEdges: owners != nil)
    }

    private static func validOwners(_ owners: [Int]?, count: Int, solids: Int) throws -> [Int]? {
        guard let owners, owners.count == count else { return nil }
        for (index, owner) in owners.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard owner >= 0, owner < solids else { return nil }
        }
        return owners
    }

    private static func faceID(forTriangle index: Int, in mesh: PreviewMesh, solid: Int) -> CADFeatureID? {
        guard let topology = mesh.topology, let faces = mesh.triangleFaces,
              faces.count == mesh.triangleCount, topology.faces.indices.contains(faces[index]) else { return nil }
        let id = topology.faces[faces[index]].id
        return id.kind == .face && id.solidIndex == solid ? id : nil
    }

    /// Synthetic previews without native normals use area-weighted smooth
    /// normals, finished in Double before narrowing to SceneKit's Float32.
    private static func smoothNormals(_ mesh: PreviewMesh) throws -> Data {
        var sums = [SIMD3<Double>](repeating: .zero, count: mesh.vertexCount)
        for index in 0..<mesh.triangleCount {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let first = Int(mesh.triangleIndices[index * 3]), second = Int(mesh.triangleIndices[index * 3 + 1])
            let third = Int(mesh.triangleIndices[index * 3 + 2])
            let a = SIMD3<Double>(mesh.position(first)), b = SIMD3<Double>(mesh.position(second))
            let c = SIMD3<Double>(mesh.position(third))
            let normal = simd_cross(b - a, c - a)
            sums[first] += normal; sums[second] += normal; sums[third] += normal
        }
        var data = Data(count: sums.count * 3 * MemoryLayout<Float>.size)
        try data.withUnsafeMutableBytes { raw in
            let components = raw.bindMemory(to: Float.self)
            for (index, sum) in sums.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let normal = simd_length_squared(sum) > 1e-24 ? simd_normalize(sum) : SIMD3(0, 0, 1)
                components[index * 3] = Float(normal.x); components[index * 3 + 1] = Float(normal.y)
                components[index * 3 + 2] = Float(normal.z)
            }
        }
        return data
    }
}
