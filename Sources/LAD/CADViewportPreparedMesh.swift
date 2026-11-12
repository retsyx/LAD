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
        guard validBounds(mesh.bounds),
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

    private static func validBounds(_ bounds: [Double]) -> Bool {
        bounds.count == 6 && bounds.allSatisfy { $0.isFinite && abs($0) < 1e12 }
            && (0..<3).allSatisfy { bounds[$0] <= bounds[$0 + 3] }
    }

    /// These buffers presented for another copy of the same preview. Only the
    /// fit bounds may differ, and they pass the same checks as preparation.
    fileprivate func presenting(_ mesh: PreviewMesh) -> Self? {
        guard Self.validBounds(mesh.bounds) else { return nil }
        return Self(mesh: mesh, vertexData: vertexData, normalData: normalData, vertexCount: vertexCount,
                    groups: groups, faceIDsBySolid: faceIDsBySolid, faceIndices: faceIndices, faceBounds: faceBounds,
                    solidBounds: solidBounds, edges: edges, hasOwnedEdges: hasOwnedEdges)
    }

    /// Buffers another view or capture already prepared for this preview.
    static func shared(for mesh: PreviewMesh) -> Self? { mesh.preparedDisplay.reusable(for: mesh) }

    /// Reuse this preview's buffers, or convert them here and share them.
    static func prepareShared(_ mesh: PreviewMesh) throws -> Self? { try mesh.preparedDisplay.prepare(mesh) }

    /// Reuse this preview's buffers, or join a single conversion off the main
    /// actor. A canceled caller stops waiting immediately.
    static func prepareSharedInBackground(_ mesh: PreviewMesh) async throws -> Self? {
        try await mesh.preparedDisplay.prepareInBackground(mesh)
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

extension CADViewportPreparedMesh {
    /// One preview's converted buffers, shared by every copy of that preview:
    /// the live viewport, Finder thumbnails and agent images convert a build
    /// once. Session-only, never saved, and released with the preview's last
    /// copy, so the bounded preview retention also bounds these buffers.
    final class Shared: @unchecked Sendable {
        /// The storage of every array that preparation reads, except the fit
        /// bounds. Copies of one preview share their arrays; changing a copy's
        /// geometry gives it new storage, so it prepares its own buffers. The
        /// retained buffers keep these addresses from being reused meanwhile.
        private struct Inputs: Equatable {
            private struct Storage: Equatable {
                var address: UnsafeRawPointer?
                var count: Int
            }
            private var arrays: [Storage]
            private var solids: Int

            init(_ mesh: PreviewMesh) {
                func storage<T>(_ array: [T]?) -> Storage {
                    guard let array else { return Storage(address: nil, count: -1) }
                    return array.withUnsafeBufferPointer { Storage(address: UnsafeRawPointer($0.baseAddress), count: $0.count) }
                }
                let topology = mesh.topology
                arrays = [storage(mesh.positions), storage(mesh.triangleIndices), storage(mesh.edgePoints),
                          storage(mesh.vertexNormals), storage(mesh.triangleSolids), storage(mesh.edgeSolids),
                          storage(mesh.triangleFaces), storage(mesh.edgeFeatures), storage(topology?.vertices),
                          storage(topology?.edges), storage(topology?.faces), storage(topology?.parts)]
                solids = mesh.solids
            }
        }

        private struct Pending {
            let inputs: Inputs
            let worker: Task<Void, Never>
            var waiters: [UUID: CheckedContinuation<CADViewportPreparedMesh?, Error>]
        }

        private let lock = NSLock()
        private var ready: (inputs: Inputs, prepared: CADViewportPreparedMesh)?
        private var pending: [UUID: Pending] = [:]
        private var startedConversions = 0

        /// Conversions started for this preview. Regression tests compare it,
        /// like `AppState.projectThumbnailWork`.
        var conversions: Int { lock.withLock { startedConversions } }

        fileprivate func reusable(for mesh: PreviewMesh) -> CADViewportPreparedMesh? {
            let inputs = Inputs(mesh)
            guard let ready = lock.withLock({ self.ready }), ready.inputs == inputs else { return nil }
            return ready.prepared.presenting(mesh)
        }

        fileprivate func prepare(_ mesh: PreviewMesh) throws -> CADViewportPreparedMesh? {
            if let prepared = reusable(for: mesh) { return prepared }
            lock.withLock { startedConversions += 1 }
            guard let prepared = try CADViewportPreparedMesh.prepare(Self.retained(mesh)) else { return nil }
            let inputs = Inputs(mesh)
            lock.withLock { ready = (inputs, prepared) }
            return prepared.presenting(mesh)
        }

        fileprivate func prepareInBackground(_ mesh: PreviewMesh) async throws -> CADViewportPreparedMesh? {
            let inputs = Inputs(mesh), waiter = UUID()
            let prepared = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CADViewportPreparedMesh?, Error>) in
                    lock.lock()
                    if let ready, ready.inputs == inputs {
                        lock.unlock()
                        continuation.resume(returning: ready.prepared)
                        return
                    }
                    // The cancellation handler may already have found no waiter.
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let id = pending.first(where: { $0.value.inputs == inputs })?.key {
                        pending[id]?.waiters[waiter] = continuation
                    } else {
                        let id = UUID(), source = Self.retained(mesh)
                        startedConversions += 1
                        let worker = Task.detached(priority: .userInitiated) { [weak self] in
                            let result = Result { try CADViewportPreparedMesh.prepare(source) }
                            self?.finish(id, result)
                        }
                        pending[id] = Pending(inputs: inputs, worker: worker, waiters: [waiter: continuation])
                    }
                    lock.unlock()
                }
            } onCancel: {
                leave(waiter)
            }
            return prepared?.presenting(mesh)
        }

        private func finish(_ id: UUID, _ result: Result<CADViewportPreparedMesh?, Error>) {
            lock.lock()
            let entry = pending.removeValue(forKey: id)
            if let entry, case .success(let prepared?) = result { ready = (entry.inputs, prepared) }
            lock.unlock()
            for continuation in entry?.waiters.values.map({ $0 }) ?? [] { continuation.resume(with: result) }
        }

        /// The conversion continues while any other caller still waits for it.
        private func leave(_ waiter: UUID) {
            lock.lock()
            var continuation: CheckedContinuation<CADViewportPreparedMesh?, Error>?
            var abandoned: Task<Void, Never>?
            for (id, var entry) in pending {
                guard let found = entry.waiters.removeValue(forKey: waiter) else { continue }
                continuation = found
                if entry.waiters.isEmpty {
                    pending[id] = nil
                    abandoned = entry.worker
                } else {
                    pending[id] = entry
                }
                break
            }
            lock.unlock()
            abandoned?.cancel()
            continuation?.resume(throwing: CancellationError())
        }

        /// Retained buffers keep their source arrays, but not this slot.
        private static func retained(_ mesh: PreviewMesh) -> PreviewMesh {
            var source = mesh
            source.preparedDisplay = Shared()
            return source
        }
    }
}
