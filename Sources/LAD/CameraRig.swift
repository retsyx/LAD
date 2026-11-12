import Foundation
import simd

/// Z-up orbit camera. All CAD-space arithmetic stays in Double precision.
struct CameraRig {
    var target = SIMD3<Double>(0, 0, 0)
    /// Fixed model-space pivot, independent of cursor zoom and view panning.
    var orbitCenter = SIMD3<Double>(0, 0, 0)
    var distance: Double = 180
    var radius: Double = 50
    var yaw: Double = -.pi / 4
    var elevation: Double = 0.6154797087
    var usesOrthographicProjection = false
    let fieldOfView: Double = 38

    var backward: SIMD3<Double> {
        SIMD3(cos(elevation) * cos(yaw), cos(elevation) * sin(yaw), sin(elevation))
    }
    var right: SIMD3<Double> { SIMD3(-sin(yaw), cos(yaw), 0) }
    var up: SIMD3<Double> { simd_cross(backward, right) }
    var position: SIMD3<Double> { target + backward * distance }
    var tangent: Double { tan(fieldOfView * .pi / 360) }
    /// Half the visible vertical extent, matching perspective at the target.
    var orthographicScale: Double { distance * tangent }

    mutating func fit(bounds: [Double], width: Double, height: Double) {
        guard bounds.count == 6, bounds.allSatisfy(\.isFinite) else { return }
        let low = SIMD3(bounds[0], bounds[1], bounds[2])
        let high = SIMD3(bounds[3], bounds[4], bounds[5])
        target = (low + high) / 2
        orbitCenter = target
        radius = max(simd_length(high - low) / 2, 0.001)
        let aspect = max(width, 1) / max(height, 1)
        let angle = atan(tangent * min(aspect, 1))
        distance = radius / sin(angle) * 1.12
    }

    /// Intersect a screen ray at design-center depth while it is ahead of the
    /// camera. Surface zoom can move `target` far behind the design;
    /// using that target's depth after a missed hit can zoom past the design.
    func planeAnchor(x: Double, y: Double, width: Double, height: Double) -> SIMD3<Double> {
        let centerOffset = simd_dot(orbitCenter - target, backward)
        // A close surface zoom can intentionally pass the design center.
        // Keep the fallback in front of the camera in that case.
        let depthOffset = distance > centerOffset ? centerOffset : 0
        let extent = usesOrthographicProjection ? orthographicScale : (distance - depthOffset) * tangent
        let units = 2 * extent / max(height, 1)
        return target + backward * depthOffset
            + right * ((x - width / 2) * units) + up * ((y - height / 2) * units)
    }

    /// Uniformly scales camera and orbit target around the world-space anchor.
    /// This preserves the anchor's projection in either camera mode.
    mutating func zoom(factor: Double, anchor: SIMD3<Double>) {
        guard factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite, anchor.z.isFinite else { return }
        let next = min(max(distance * factor, radius * 0.003), radius * 100_000)
        let actual = next / distance
        target = anchor + (target - anchor) * actual
        distance = next
    }

    mutating func pan(dx: Double, dy: Double, height: Double) {
        let units = 2 * orthographicScale / max(height, 1)
        target += right * (-dx * units) + up * (dy * units)
    }

    /// Rotate the entire camera pose about the center of the model's bounds, even
    /// after panning or cursor zoom has moved the view target away from it.
    mutating func orbitAroundCenter(dx: Double, dy: Double) {
        let yawDelta = -dx * 0.008
        let nextElevation = min(max(elevation + dy * 0.008, -.pi / 2 + 0.005), .pi / 2 - 0.005)
        let elevationDelta = nextElevation - elevation
        target = orbitCenter + simd_quatd(angle: yawDelta, axis: SIMD3<Double>(0, 0, 1)).act(target - orbitCenter)
        yaw += yawDelta
        target = orbitCenter + simd_quatd(angle: -elevationDelta, axis: right).act(target - orbitCenter)
        elevation = nextElevation
    }

    /// Pixel coordinates with a bottom-left origin, used to verify anchored zoom.
    func project(_ point: SIMD3<Double>, width: Double, height: Double) -> SIMD2<Double> {
        projection(width: width, height: height).project(point).screen
    }

    /// Snapshot of this pose's projection. Evaluating the trigonometric basis
    /// once keeps repeated projection of many points cheap.
    func projection(width: Double, height: Double) -> Projection {
        Projection(position: position, right: right, up: up, backward: backward, tangent: tangent,
                   orthographic: usesOrthographicProjection, orthographicScale: orthographicScale,
                   width: width, height: height)
    }

    struct Projection {
        let position: SIMD3<Double>
        let right: SIMD3<Double>
        let up: SIMD3<Double>
        let backward: SIMD3<Double>
        let tangent: Double
        let orthographic: Bool
        let orthographicScale: Double
        let width: Double
        let height: Double

        /// Pixel coordinates with a bottom-left origin, and the point's
        /// distance in front of the eye. Points at or behind the eye have a
        /// nonpositive depth and no meaningful perspective screen position.
        func project(_ point: SIMD3<Double>) -> (screen: SIMD2<Double>, depth: Double) {
            let delta = point - position
            let depth = -simd_dot(delta, backward)
            let extent = orthographic ? orthographicScale : depth * tangent
            let units = 2 * extent / max(height, 1)
            return (SIMD2(width / 2 + simd_dot(delta, right) / units,
                          height / 2 + simd_dot(delta, up) / units), depth)
        }
    }
}
