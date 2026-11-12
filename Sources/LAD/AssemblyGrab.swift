import Foundation
import simd

/// A gesture retains the camera projection it started with. Screen targets use
/// bottom-left viewport points, independent of display backing scale.
struct AssemblyGrabProjection: Sendable, Equatable {
    var worldToClip: [Double]
    var viewportSize: [Double]

    func validate() throws {
        guard worldToClip.count == 16, worldToClip.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }),
              viewportSize.count == 2, viewportSize.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1e6 }),
              worldToClip[12...15].contains(where: { abs($0) > 1e-15 }) else {
            throw LADError.message("The design viewport is not ready for moving parts.")
        }
    }

    func project(_ point: [Double]) -> [Double]? {
        guard point.count == 3, let screen = screen(SIMD3(point[0], point[1], point[2])) else { return nil }
        return [screen.x, screen.y]
    }

    func screen(_ point: SIMD3<Double>) -> SIMD2<Double>? {
        guard worldToClip.count == 16, viewportSize.count == 2 else { return nil }
        let clipped = clip(point)
        guard clipped.w.isFinite, clipped.w > 1e-12 else { return nil }
        let result = SIMD2((clipped.x / clipped.w + 1) * viewportSize[0] / 2,
                           (clipped.y / clipped.w + 1) * viewportSize[1] / 2)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    /// Homogeneous clip X, Y and W of a world point; the caller checks that
    /// the matrix has 16 entries. W is not positive at or behind the eye.
    func clip(_ point: SIMD3<Double>) -> (x: Double, y: Double, w: Double) {
        func row(_ offset: Int) -> Double {
            worldToClip[offset] * point.x + worldToClip[offset + 1] * point.y
                + worldToClip[offset + 2] * point.z + worldToClip[offset + 3]
        }
        return (row(0), row(4), row(12))
    }
}
