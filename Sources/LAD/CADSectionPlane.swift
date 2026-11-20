import Foundation
import simd

enum CADSectionHandle: CaseIterable, Hashable {
    case offset, vertical, horizontal
}

/// A viewport-only cut in world CAD coordinates. The normal points into the
/// removed half-space. Angles are relative to the initial centered YZ cut.
struct CADSectionPlane: Equatable, Sendable {
    let center: SIMD3<Double>
    let normal: SIMD3<Double>
    let horizontal: SIMD3<Double>
    let vertical: SIMD3<Double>

    private let initialSide: Double
    private let offset: Double
    private let tilt: Double
    private let swing: Double

    var origin: SIMD3<Double> { center + normal * offset }
    var equation: SIMD4<Float> {
        SIMD4(SIMD3<Float>(normal), Float(-simd_dot(center, normal) - offset))
    }

    init?(bounds: [Double], toward cameraBackward: SIMD3<Double>) {
        guard bounds.count == 6, bounds.allSatisfy({ Float($0).isFinite }),
              bounds[0] <= bounds[3], bounds[1] <= bounds[4], bounds[2] <= bounds[5],
              cameraBackward.x.isFinite else { return nil }
        let low = SIMD3(bounds[0], bounds[1], bounds[2])
        let high = SIMD3(bounds[3], bounds[4], bounds[5])
        self.init(center: (low + high) / 2, initialSide: cameraBackward.x < 0 ? -1 : 1,
                  offset: 0, tilt: 0, swing: 0)
    }

    private init(center: SIMD3<Double>, initialSide: Double, offset: Double, tilt: Double, swing: Double) {
        self.center = center
        self.initialSide = initialSide
        self.offset = offset
        self.tilt = tilt
        self.swing = swing

        let pitch = tilt.remainder(dividingBy: 360) * .pi / 180
        let yaw = swing.remainder(dividingBy: 360) * .pi / 180
        let baseline = SIMD3(cos(yaw) * initialSide, sin(yaw) * initialSide, 0)
        normal = baseline * cos(pitch) + SIMD3(0, 0, sin(pitch))
        horizontal = SIMD3(-baseline.y, baseline.x, 0)
        vertical = simd_cross(normal, horizontal)
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
        let plane = CADSectionPlane(center: center, initialSide: initialSide,
                                    offset: handle == .offset ? value : offset,
                                    tilt: handle == .vertical ? value : tilt,
                                    swing: handle == .horizontal ? value : swing)
        return plane.equation.w.isFinite ? plane : nil
    }

    func signedDistance(to point: SIMD3<Double>) -> Double {
        simd_dot(point - center, normal) - offset
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
