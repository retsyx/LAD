import Foundation
import simd

enum CADSectionHandle: CaseIterable, Hashable {
    case offset, vertical, horizontal
}

/// A viewport-only cut in world CAD coordinates. The normal points into the
/// removed half-space. Angles are relative to the initial section basis.
struct CADSectionPlane: Equatable, Sendable {
    static let renderRoundoff = 8 * Float.ulpOfOne

    let center: SIMD3<Double>
    let origin: SIMD3<Double>
    let normal: SIMD3<Double>
    let horizontal: SIMD3<Double>
    let vertical: SIMD3<Double>

    private let initialNormal: SIMD3<Double>
    private let initialHorizontal: SIMD3<Double>
    private let offset: Double
    private let tilt: Double
    private let swing: Double

    var equation: SIMD4<Float> {
        SIMD4(SIMD3<Float>(normal), Float(-simd_dot(origin, normal)))
    }

    init?(bounds: [Double], toward cameraBackward: SIMD3<Double>, cameraRight: SIMD3<Double>? = nil) {
        guard bounds.count == 6, bounds.allSatisfy({ Float($0).isFinite }),
              bounds[0] <= bounds[3], bounds[1] <= bounds[4], bounds[2] <= bounds[5],
              cameraBackward.x.isFinite else { return nil }
        let low = SIMD3(bounds[0], bounds[1], bounds[2])
        let high = SIMD3(bounds[3], bounds[4], bounds[5])
        let center = (low + high) / 2
        let side = cameraBackward.x < 0 ? -1.0 : 1.0
        var origin = center
        if let right = cameraRight {
            // Place the hub at the edge of the initial cut just once. Orbiting
            // never chooses another edge, and rotation keeps this pivot fixed.
            let axis = abs(right.y) >= abs(right.z) ? 1 : 2
            if abs(right[axis]) > 1e-6 {
                let left = side * right.x < 0
                let towardHigh = left == (right[axis] < 0)
                origin[axis] = towardHigh ? high[axis] : low[axis]
            }
        }
        self.init(center: center, origin: origin, initialNormal: SIMD3(side, 0, 0),
                  initialHorizontal: SIMD3(0, side, 0), offset: 0, tilt: 0, swing: 0)
    }

    /// Align to an exact planar face, retaining material behind its outward normal.
    init?(point: SIMD3<Double>, normal: SIMD3<Double>, cameraRight: SIMD3<Double>) {
        let normalLength = simd_length(normal)
        guard (0..<3).allSatisfy({ Float(point[$0]).isFinite && cameraRight[$0].isFinite }),
              normalLength.isFinite, normalLength > 1e-12 else { return nil }
        let unitNormal = normal / normalLength
        let rightInPlane = cameraRight - unitNormal * simd_dot(cameraRight, unitNormal)
        let rightLength = simd_length(rightInPlane)
        let horizontal: SIMD3<Double>
        if rightLength.isFinite, rightLength > 1e-6 {
            horizontal = rightInPlane / rightLength
        } else {
            // An edge-on face can have no component of camera right in its plane.
            let up = abs(unitNormal.z) < 0.9 ? SIMD3(0.0, 0, 1) : SIMD3(0.0, 1, 0)
            horizontal = simd_normalize(simd_cross(up, unitNormal))
        }
        self.init(center: point, origin: point, initialNormal: unitNormal,
                  initialHorizontal: horizontal, offset: 0, tilt: 0, swing: 0)
        guard equation.w.isFinite else { return nil }
    }

    private init(center: SIMD3<Double>, origin: SIMD3<Double>, initialNormal: SIMD3<Double>, initialHorizontal: SIMD3<Double>,
                 offset: Double? = nil, tilt: Double, swing: Double) {
        self.center = center
        self.origin = origin
        self.initialNormal = initialNormal
        self.initialHorizontal = initialHorizontal
        self.tilt = tilt
        self.swing = swing

        let pitch = tilt.remainder(dividingBy: 360) * .pi / 180
        let yaw = swing.remainder(dividingBy: 360) * .pi / 180
        let yawNormal = cos(yaw) * initialNormal + sin(yaw) * initialHorizontal
        let initialVertical = simd_cross(initialNormal, initialHorizontal)
        normal = cos(pitch) * yawNormal + sin(pitch) * initialVertical
        horizontal = cos(yaw) * initialHorizontal - sin(yaw) * initialNormal
        vertical = simd_cross(normal, horizontal)
        self.offset = offset ?? simd_dot(origin - center, normal)
    }

    func value(for handle: CADSectionHandle) -> Double {
        switch handle {
        case .offset: return offset
        case .vertical: return tilt
        case .horizontal: return swing
        }
    }

    func setting(_ value: Double, for handle: CADSectionHandle) -> CADSectionPlane? {
        guard value.isFinite else { return nil }
        if value == self.value(for: handle) { return self }
        let nextOrigin = handle == .offset ? origin + normal * (value - offset) : origin
        let plane = CADSectionPlane(center: center, origin: nextOrigin, initialNormal: initialNormal,
                                    initialHorizontal: initialHorizontal,
                                    offset: handle == .offset ? value : nil,
                                    tilt: handle == .vertical ? value : tilt,
                                    swing: handle == .horizontal ? value : swing)
        return plane.equation.w.isFinite ? plane : nil
    }

    func signedDistance(to point: SIMD3<Double>) -> Double {
        simd_dot(point - origin, normal)
    }

    func contains(_ point: SIMD3<Double>) -> Bool {
        signedDistance(to: point) <= 0
    }

    /// Clip a native feature segment in world space before projecting it.
    func clippedSegment(from start: SIMD3<Double>, to end: SIMD3<Double>)
        -> (from: SIMD3<Double>, to: SIMD3<Double>)? {
        let fromDistance = signedDistance(to: start)
        let toDistance = signedDistance(to: end)
        if fromDistance <= 0 && toDistance <= 0 { return (start, end) }
        if fromDistance > 0 && toDistance > 0 { return nil }
        let crossing = start + (end - start) * (fromDistance / (fromDistance - toDistance))
        return fromDistance <= 0 ? (start, crossing) : (crossing, end)
    }
}
