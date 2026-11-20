import Foundation
import simd

/// Part occupancy in the section plane. The input covers each solid's filled
/// interior, so cavities and open contours have already been excluded.
enum CADSectionInterference {
    struct Trapezoid {
        let owner: Int
        let bottomLeft, bottomRight, topRight, topLeft: SIMD2<Double>

        var bottomY: Double { bottomLeft.y }
        var topY: Double { topLeft.y }

        func edges(at y: Double) -> SIMD2<Double> {
            let t = (y - bottomY) / (topY - bottomY)
            return SIMD2(
                bottomLeft.x + (topLeft.x - bottomLeft.x) * t,
                bottomRight.x + (topRight.x - bottomRight.x) * t
            )
        }
    }

    struct Result {
        var normal = [SIMD2<Double>]()
        var interfering = [SIMD2<Double>]()
    }

    private struct Bounds {
        var minX, maxX, minY, maxY: Double

        init(_ trapezoid: Trapezoid) {
            minX = min(trapezoid.bottomLeft.x, trapezoid.topLeft.x)
            maxX = max(trapezoid.bottomRight.x, trapezoid.topRight.x)
            minY = trapezoid.bottomY
            maxY = trapezoid.topY
        }

        mutating func include(_ other: Bounds) {
            minX = min(minX, other.minX)
            maxX = max(maxX, other.maxX)
            minY = min(minY, other.minY)
            maxY = max(maxY, other.maxY)
        }
    }

    private struct Boundary {
        let owner, change: Int
        let bottom, top: Double

        var minX: Double { min(bottom, top) }
        var maxX: Double { max(bottom, top) }

        func x(at t: Double) -> Double { bottom + (top - bottom) * t }
    }

    /// Return a disjoint partition of the cut into ordinary and interfering
    /// faces. A nil result leaves the original caps in use.
    static func triangulate(_ trapezoids: [Trapezoid], tolerance: Double, maximumVertices: Int,
                            includesNormal: Bool = true) throws -> Result? {
        var boundsByOwner = [Int: Bounds]()
        for (index, trapezoid) in trapezoids.enumerated() {
            if index.isMultiple(of: 768) { try Task.checkCancellation() }
            let bounds = Bounds(trapezoid)
            if boundsByOwner[trapezoid.owner] == nil { boundsByOwner[trapezoid.owner] = bounds }
            else { boundsByOwner[trapezoid.owner]?.include(bounds) }
        }
        guard boundsByOwner.count > 1 else { return nil }

        // Reject separate parts before intersecting their tessellated contours.
        let boxes = boundsByOwner.sorted { $0.value.minX < $1.value.minX }
        var activeBoxes = [(owner: Int, bounds: Bounds)]()
        var candidates = Set<Int>()
        for (index, box) in boxes.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            activeBoxes.removeAll { $0.bounds.maxX - box.value.minX <= tolerance }
            for previous in activeBoxes {
                if min(previous.bounds.maxY, box.value.maxY) - max(previous.bounds.minY, box.value.minY) > tolerance {
                    candidates.insert(previous.owner)
                    candidates.insert(box.key)
                }
            }
            activeBoxes.append((box.key, box.value))
        }
        guard !candidates.isEmpty else { return nil }

        let spans = trapezoids.filter { candidates.contains($0.owner) }.sorted { $0.bottomY < $1.bottomY }
        let ordinates = Set(spans.flatMap { [$0.bottomY, $0.topY] }).sorted()
        var active = [Trapezoid]()
        var next = 0
        var result = Result()
        // Bound the work of pathological crossing arrangements as well as the
        // resulting mesh. This budget is shared by all bands in the section.
        var workRemaining = maximumVertices * 8
        for (index, bottom) in ordinates.dropLast().enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let top = ordinates[index + 1]
            active.removeAll { $0.topY <= bottom }
            while next < spans.count, spans[next].bottomY <= bottom {
                active.append(spans[next])
                next += 1
            }
            if active.isEmpty { continue }
            var boundaries = [Boundary]()
            boundaries.reserveCapacity(active.count * 2)
            for span in active {
                let low = span.edges(at: bottom), high = span.edges(at: top)
                boundaries.append(Boundary(owner: span.owner, change: 1, bottom: low.x, top: high.x))
                boundaries.append(Boundary(owner: span.owner, change: -1, bottom: low.y, top: high.y))
            }
            workRemaining -= boundaries.count
            guard workRemaining >= 0,
                  let divisions = try crossings(of: boundaries, workRemaining: &workRemaining) else { return nil }
            for (index, division) in zip(divisions, divisions.dropFirst()).enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                workRemaining -= boundaries.count
                guard workRemaining >= 0 else { return nil }
                let (lower, upper) = division
                let middle = (lower + upper) * 0.5
                let crossed = boundaries.sorted {
                    let first = $0.x(at: middle), second = $1.x(at: middle)
                    return first == second ? $0.change > $1.change : first < second
                }
                var covered = [Int: Int]()
                var start: Boundary?
                let lowerY = bottom + (top - bottom) * lower
                let upperY = bottom + (top - bottom) * upper
                for edge in crossed {
                    let precedingCoverage = min(covered.count, 2)
                    let count = (covered[edge.owner] ?? 0) + edge.change
                    covered[edge.owner] = count == 0 ? nil : count
                    let followingCoverage = min(covered.count, 2)
                    guard precedingCoverage != followingCoverage else { continue }
                    if let left = start, (precedingCoverage == 2 || includesNormal),
                       edge.x(at: middle) - left.x(at: middle) > tolerance {
                        guard result.normal.count + result.interfering.count + 6 <= maximumVertices else { return nil }
                        let a = SIMD2(left.x(at: lower), lowerY), b = SIMD2(edge.x(at: lower), lowerY)
                        let c = SIMD2(edge.x(at: upper), upperY), d = SIMD2(left.x(at: upper), upperY)
                        if precedingCoverage == 2 { result.interfering.append(contentsOf: [a, b, c, a, c, d]) }
                        else { result.normal.append(contentsOf: [a, b, c, a, c, d]) }
                    }
                    start = followingCoverage == 0 ? nil : edge
                }
            }
        }
        guard !result.interfering.isEmpty else { return nil }
        guard includesNormal else { return result }
        for (index, span) in trapezoids.enumerated() where !candidates.contains(span.owner) {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard result.normal.count + result.interfering.count + 6 <= maximumVertices else { return nil }
            let a = span.bottomLeft, b = span.bottomRight, c = span.topRight, d = span.topLeft
            result.normal.append(contentsOf: [a, b, c, a, c, d])
        }
        return result
    }

    /// Within one band the section edges are affine. Split at every crossing
    /// before classifying horizontal intervals so sloping edges meet exactly.
    private static func crossings(of boundaries: [Boundary], workRemaining: inout Int) throws -> [Double]? {
        let byBottom = boundaries.sorted { $0.bottom == $1.bottom ? $0.top < $1.top : $0.bottom < $1.bottom }
        if zip(byBottom, byBottom.dropFirst()).allSatisfy({ $0.top <= $1.top }) { return [0, 1] }

        let byMinimum = boundaries.sorted { $0.minX < $1.minX }
        var possible = [Boundary]()
        var divisions: Set<Double> = [0, 1]
        for edge in byMinimum {
            possible.removeAll { $0.maxX <= edge.minX }
            if workRemaining / 256 != (workRemaining - possible.count) / 256 { try Task.checkCancellation() }
            workRemaining -= possible.count
            guard workRemaining >= 0 else { return nil }
            for other in possible {
                let low = edge.bottom - other.bottom, high = edge.top - other.top
                if (low < 0 && high > 0) || (low > 0 && high < 0) {
                    divisions.insert(low / (low - high))
                }
            }
            possible.append(edge)
        }
        return divisions.sorted()
    }
}
