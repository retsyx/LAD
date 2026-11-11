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
        let v = SIMD4(point, 1)
        func row(_ offset: Int) -> Double {
            worldToClip[offset] * v.x + worldToClip[offset + 1] * v.y
                + worldToClip[offset + 2] * v.z + worldToClip[offset + 3]
        }
        let w = row(12)
        guard w.isFinite, w > 1e-12 else { return nil }
        let result = SIMD2((row(0) / w + 1) * viewportSize[0] / 2,
                           (row(4) / w + 1) * viewportSize[1] / 2)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }
}
