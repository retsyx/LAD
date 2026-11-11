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
        for count in [mesh.vertices.count, mesh.triangles.count, mesh.edges.count, mesh.topology?.parts.count ?? 0] {
            guard count <= remaining else { return true }
            remaining -= count
        }
        return false
    }

    /// Invalid display data is rejected at the same boundary as scene install.
    /// Cancellation is distinct from invalid input and propagates to its owner.
    static func prepare(_ mesh: PreviewMesh) throws -> Self? {
        try Task.checkCancellation()
        guard mesh.bounds.count == 6, mesh.bounds.allSatisfy({ $0.isFinite && abs($0) < 1e12 }),
              (0..<3).allSatisfy({ mesh.bounds[$0] <= mesh.bounds[$0 + 3] }),
              !mesh.vertices.isEmpty, mesh.vertices.count <= 1_000_000,
              !mesh.triangles.isEmpty, mesh.triangles.count <= 1_000_000 else { return nil }
        for (index, vertex) in mesh.vertices.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard vertex.count == 3, vertex.allSatisfy({ $0.isFinite && abs($0) < 1e12 }) else { return nil }
        }
        for (index, triangle) in mesh.triangles.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard triangle.count == 3, triangle.allSatisfy({ $0 >= 0 && $0 < mesh.vertices.count }) else { return nil }
        }
        if let normals = mesh.normals {
            guard normals.count == mesh.vertices.count else { return nil }
            for (index, normal) in normals.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                guard normal.count == 3, normal.allSatisfy(\.isFinite),
                      abs(normal.reduce(0) { $0 + $1 * $1 } - 1) <= 0.0001 else { return nil }
            }
        }
        let vertexData = try packedXYZ(count: mesh.vertices.count) { index in
            let vertex = mesh.vertices[index]
            return SIMD3(vertex[0], vertex[1], vertex[2])
        }
        let normalData: Data
        if let normals = mesh.normals {
            normalData = try packedXYZ(count: normals.count) { index in
                let normal = normals[index]
                return SIMD3(normal[0], normal[1], normal[2])
            }
        } else {
            normalData = try smoothNormals(vertices: mesh.vertices, triangles: mesh.triangles)
        }

        let solidMap = try validOwners(mesh.triangleSolids, count: mesh.triangles.count, solids: mesh.solids)
        var groups = [Int: [Int32]](), faceIDsBySolid = [Int: [CADFeatureID?]]()
        var faceIndices = [CADFeatureID: [Int32]](), faceBounds = [CADFeatureID: CADSilhouetteBatching.Bounds]()
        for (index, triangle) in mesh.triangles.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let solid = solidMap?[index] ?? 0
            let indices = triangle.map(Int32.init)
            groups[solid, default: []].append(contentsOf: indices)
            let feature = faceID(forTriangle: index, in: mesh, solid: solid)
            faceIDsBySolid[solid, default: []].append(feature)
            if let feature {
                faceIndices[feature, default: []].append(contentsOf: indices)
                for vertex in triangle { faceBounds[feature, default: .init()].include(mesh.vertices[vertex]) }
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
                bounds.include(mesh.vertices[Int(vertex)])
            }
            solidBounds[solid] = bounds.values
        }

        let owners = try validOwners(mesh.edgeSolids, count: mesh.edges.count, solids: mesh.solids)
        let surfaces = try CADStrokeSurface.matchingCancellable(mesh)
        var edgeGroups = [Int: [[Double]]](), surfaceGroups = [Int: [CADStrokeSurface]]()
        for (index, segment) in mesh.edges.prefix(250_000).enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard segment.count == 6, segment.allSatisfy({ $0.isFinite && abs($0) < 1e12 }) else { continue }
            let solid = owners?[index] ?? -1
            edgeGroups[solid, default: []].append(segment)
            surfaceGroups[solid, default: []].append(surfaces[index])
        }
        var edges = [Int: CADStrokeGeometry.Prepared]()
        for (solid, segments) in edgeGroups {
            edges[solid] = try CADStrokeGeometry.prepare(segments, surfaces: surfaceGroups[solid])
        }
        try Task.checkCancellation()
        return Self(mesh: mesh, vertexData: vertexData, normalData: normalData, vertexCount: mesh.vertices.count,
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
              faces.count == mesh.triangles.count, topology.faces.indices.contains(faces[index]) else { return nil }
        let id = topology.faces[faces[index]].id
        return id.kind == .face && id.solidIndex == solid ? id : nil
    }

    private static func packedXYZ(count: Int, value: (Int) -> SIMD3<Double>) throws -> Data {
        // SceneKit's convenience vector sources use Float32 GPU attributes.
        // Finish the existing Double calculations before narrowing once here.
        var data = Data(count: count * 3 * MemoryLayout<Float>.size)
        try data.withUnsafeMutableBytes { raw in
            let components = raw.bindMemory(to: Float.self)
            for index in 0..<count {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let point = value(index), start = index * 3
                components[start] = Float(point.x); components[start + 1] = Float(point.y); components[start + 2] = Float(point.z)
            }
        }
        return data
    }

    private static func smoothNormals(vertices: [[Double]], triangles: [[Int]]) throws -> Data {
        var sums = [SIMD3<Double>](repeating: .zero, count: vertices.count)
        for (index, triangle) in triangles.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let a = SIMD3(vertices[triangle[0]][0], vertices[triangle[0]][1], vertices[triangle[0]][2])
            let b = SIMD3(vertices[triangle[1]][0], vertices[triangle[1]][1], vertices[triangle[1]][2])
            let c = SIMD3(vertices[triangle[2]][0], vertices[triangle[2]][1], vertices[triangle[2]][2])
            let normal = simd_cross(b - a, c - a)
            for vertex in triangle { sums[vertex] += normal }
        }
        return try packedXYZ(count: sums.count) { index in
            let normal = sums[index]
            return simd_length_squared(normal) > 1e-24 ? simd_normalize(normal) : SIMD3(0, 0, 1)
        }
    }
}
