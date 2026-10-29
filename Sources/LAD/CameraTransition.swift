import Foundation
import simd

/// A fitted camera move with stable framing even after extreme cursor zoom.
struct CameraTransition {
    var from: CameraRig
    var to: CameraRig

    func rig(at progress: Double) -> CameraRig {
        guard progress > 0 else { return from }
        guard progress < 1 else { return to }
        let amount = progress * progress * (3 - 2 * progress)
        var rig = to
        rig.yaw = from.yaw + atan2(sin(to.yaw - from.yaw), cos(to.yaw - from.yaw)) * amount
        rig.elevation = from.elevation + (to.elevation - from.elevation) * amount
        rig.distance = exp(log(from.distance) * (1 - amount) + log(to.distance) * amount)
        rig.orbitCenter = from.orbitCenter * (1 - amount) + to.orbitCenter * amount
        rig.radius = from.radius * (1 - amount) + to.radius * amount

        // World-space target interpolation leaves a heavily panned or
        // surface-zoomed target far away while the distance already shrinks.
        // Camera-local offsets scaled by distance retain the framing instead.
        func offset(_ camera: CameraRig) -> SIMD3<Double> {
            let delta = camera.target - camera.orbitCenter
            return SIMD3(simd_dot(delta, camera.right), simd_dot(delta, camera.up),
                         simd_dot(delta, camera.backward)) / camera.distance
        }
        let relative = offset(from) * (1 - amount) + offset(to) * amount
        rig.target = rig.orbitCenter + rig.distance
            * (rig.right * relative.x + rig.up * relative.y + rig.backward * relative.z)
        return rig
    }
}
