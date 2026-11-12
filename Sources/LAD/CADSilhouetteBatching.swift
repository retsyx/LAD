import Foundation
import simd

/// Disjoint projected masks can share a contour pass. Overlapping masks keep
/// separate passes so nested parts and occluded faces retain their own outline.
enum CADSilhouetteBatching {
    struct Bounds: Sendable {
        var low = SIMD3<Double>(repeating: .infinity)
        var high = SIMD3<Double>(repeating: -.infinity)
        mutating func include(_ point: [Double]) {
            include(SIMD3(point[0], point[1], point[2]))
        }
        mutating func include(_ point: SIMD3<Float>) { include(SIMD3<Double>(point)) }
        mutating func include(_ value: SIMD3<Double>) {
            low = simd_min(low, value); high = simd_max(high, value)
        }
        var values: [Double] { [low.x, low.y, low.z, high.x, high.y, high.z] }
    }
    struct Rect: Equatable {
        var low: SIMD2<Double>
        var high: SIMD2<Double>

        static let full = Rect(low: SIMD2(repeating: -1), high: SIMD2(repeating: 1))
        var vector: SIMD4<Float> { SIMD4(Float(low.x), Float(low.y), Float(high.x), Float(high.y)) }
        func overlaps(_ other: Rect) -> Bool {
            low.x <= other.high.x && high.x >= other.low.x && low.y <= other.high.y && high.y >= other.low.y
        }
        func union(_ other: Rect) -> Rect { Rect(low: simd_min(low, other.low), high: simd_max(high, other.high)) }
    }

    struct Batch {
        var items: [Int]
        var rect: Rect
    }

    /// XY/w is captured from the actual camera, including explicit render roll.
    /// A box crossing the eye plane conservatively occupies the whole viewport.
    static func project(bounds: [Double], transform: simd_float4x4, projection: AssemblyGrabProjection,
                        pixels: SIMD2<Double>) -> Rect? {
        guard bounds.count == 6, projection.worldToClip.count == 16,
              pixels.x > 0, pixels.y > 0 else { return .full }
        let matrix = projection.worldToClip
        var low = SIMD2<Double>(repeating: .infinity), high = SIMD2<Double>(repeating: -.infinity)
        var behind = 0
        for corner in 0..<8 {
            let local = SIMD4<Float>(Float(bounds[corner & 1 == 0 ? 0 : 3]),
                                     Float(bounds[corner & 2 == 0 ? 1 : 4]),
                                     Float(bounds[corner & 4 == 0 ? 2 : 5]), 1)
            let world = SIMD4<Double>(transform * local)
            let w = matrix[12] * world.x + matrix[13] * world.y + matrix[14] * world.z + matrix[15]
            guard w.isFinite else { return .full }
            if w <= 1e-8 { behind += 1; continue }
            let point = SIMD2((matrix[0] * world.x + matrix[1] * world.y + matrix[2] * world.z + matrix[3]) / w,
                              (matrix[4] * world.x + matrix[5] * world.y + matrix[6] * world.z + matrix[7]) / w)
            guard point.x.isFinite, point.y.isFinite else { return .full }
            low = simd_min(low, point); high = simd_max(high, point)
        }
        if behind == 8 { return nil }
        if behind > 0 { return .full }
        // Two output pixels cover line/MSAA coverage and the contour's one-pixel
        // neighbor reads. No stale mask texels can reach a bounded contour pass.
        let padding = SIMD2(repeating: 4.0) / pixels
        low -= padding; high += padding
        guard low.x < 1, low.y < 1, high.x > -1, high.y > -1 else { return nil }
        low = simd_max(low, SIMD2(repeating: -1)); high = simd_min(high, SIMD2(repeating: 1))
        let first = (low + SIMD2(repeating: 1)) * pixels / 2
        let last = (high + SIMD2(repeating: 1)) * pixels / 2
        // Clear complete MSAA pixels. A fractional clear-quad edge could leave
        // old samples whose resolved coverage becomes a false rectangle contour.
        return Rect(low: SIMD2(floor(first.x), floor(first.y)) * 2 / pixels - SIMD2(repeating: 1),
                    high: SIMD2(ceil(last.x), ceil(last.y)) * 2 / pixels - SIMD2(repeating: 1))
    }

    static func make(_ rectangles: [Rect?]) -> [Batch] {
        let ordered = rectangles.indices.filter { rectangles[$0] != nil }.sorted {
            let lhs = rectangles[$0]!, rhs = rectangles[$1]!
            return lhs.low.x == rhs.low.x ? $0 < $1 : lhs.low.x < rhs.low.x
        }
        var batches: [Batch] = [], active: [Int] = []
        var owners = [Int](repeating: 0, count: rectangles.count)
        var occupied = [Int](repeating: -1, count: rectangles.count)
        for (stamp, item) in ordered.enumerated() {
            let rect = rectangles[item]!
            active.removeAll { rectangles[$0]!.high.x < rect.low.x }
            for previous in active where rect.overlaps(rectangles[previous]!) { occupied[owners[previous]] = stamp }
            var batch = 0
            while batch < batches.count && occupied[batch] == stamp { batch += 1 }
            if batch == batches.count { batches.append(Batch(items: [item], rect: rect)) }
            else { batches[batch].items.append(item); batches[batch].rect = batches[batch].rect.union(rect) }
            owners[item] = batch
            active.append(item)
        }
        return batches
    }
}
