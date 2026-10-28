import Foundation
import simd

/// Camera overrides for an independent agent render. Angles are degrees and
/// points use the design's absolute, Z-up millimetre coordinate system.
struct CADAgentCamera: Sendable {
    var yawDegrees: Double? = nil
    var elevationDegrees: Double? = nil
    /// Positive roll turns the resulting image counterclockwise.
    var rollDegrees: Double = 0
    var position: [Double]? = nil
    var target: [Double]? = nil
    /// Magnification relative to automatic fit, or the explicitly supplied eye.
    /// Perspective dollies; orthographic keeps the eye and changes its scale.
    var zoom: Double = 1

    static let minimumZoom = 0.000001
    static let maximumZoom = 1_000_000.0
    static let maximumCoordinate = 1_000_000.0

    var isCustom: Bool {
        yawDegrees != nil || elevationDegrees != nil || rollDegrees != 0 ||
            position != nil || target != nil || zoom != 1
    }

    func validate() throws {
        guard yawDegrees.map(\.isFinite) ?? true,
              elevationDegrees.map({ $0.isFinite && (-90...90).contains($0) }) ?? true,
              rollDegrees.isFinite else {
            throw LADError.message("Camera angles must be finite degrees, with elevation between −90 and 90.")
        }
        guard zoom.isFinite, (Self.minimumZoom...Self.maximumZoom).contains(zoom) else {
            throw LADError.message("Camera zoom must be between 0.000001 and 1,000,000; 1 uses the automatic fit or explicit camera position.")
        }
        for point in [position, target].compactMap({ $0 }) {
            guard point.count == 3, point.allSatisfy({ $0.isFinite && abs($0) <= Self.maximumCoordinate }) else {
                throw LADError.message("Camera positions and targets must contain three finite millimetre coordinates between −1,000,000 and 1,000,000.")
            }
        }
        guard position == nil || (yawDegrees == nil && elevationDegrees == nil) else {
            throw LADError.message("Choose either a camera position or yaw/elevation angles for the design image.")
        }
        if let position, let target {
            guard simd_length(vector(position) - vector(target)) > 0.000000001 else {
                throw LADError.message("The camera position and target must be distinct.")
            }
        }
    }

    /// Starts from the existing fit and preset conventions. This calculation
    /// does not mutate the user's camera, geometry, or display preferences.
    func resolved(view: String, bounds: [Double], width: Double, height: Double,
                  orthographic: Bool) throws -> CADAgentCameraPose {
        try validate()
        guard bounds.count == 6, bounds.allSatisfy(\.isFinite),
              (0..<3).allSatisfy({ bounds[$0] <= bounds[$0 + 3] }),
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw LADError.message("A design image needs finite bounds and a nonempty image size.")
        }
        var rig = CameraRig()
        rig.usesOrthographicProjection = orthographic
        switch view {
        case "isometric": rig.yaw = -.pi / 4; rig.elevation = 0.6154797087
        case "front": rig.yaw = -.pi / 2; rig.elevation = 0
        case "back": rig.yaw = .pi / 2; rig.elevation = 0
        case "left": rig.yaw = .pi; rig.elevation = 0
        case "right": rig.yaw = 0; rig.elevation = 0
        case "top": rig.yaw = -.pi / 2; rig.elevation = .pi / 2 - 0.00001
        case "bottom": rig.yaw = -.pi / 2; rig.elevation = -.pi / 2 + 0.00001
        default:
            throw LADError.message("Choose isometric, front, back, left, right, top, or bottom for the design image.")
        }
        rig.fit(bounds: bounds, width: width, height: height)
        let automaticDistance = rig.distance
        if let target { rig.target = vector(target) }

        let backward: SIMD3<Double>
        let baseDistance: Double
        if let position {
            let offset = vector(position) - rig.target
            baseDistance = simd_length(offset)
            guard baseDistance.isFinite, baseDistance > 0.000000001 else {
                throw LADError.message("The camera position and target must be distinct.")
            }
            backward = offset / baseDistance
            rig.yaw = atan2(backward.y, backward.x)
            rig.elevation = atan2(backward.z, hypot(backward.x, backward.y))
        } else {
            if let yawDegrees { rig.yaw = radians(yawDegrees) }
            if let elevationDegrees { rig.elevation = elevationDegrees * .pi / 180 }
            backward = rig.backward
            baseDistance = automaticDistance
        }
        // Orthographic zoom changes magnification without moving the eye into
        // the design. Perspective zoom dollies along the viewing direction.
        rig.distance = orthographic ? baseDistance : baseDistance / zoom
        let orthographicScale = baseDistance * rig.tangent / zoom
        let position = rig.target + backward * rig.distance
        let unrolledRight = SIMD3<Double>(-sin(rig.yaw), cos(rig.yaw), 0)
        let unrolledUp = simd_cross(backward, unrolledRight)
        let roll = radians(rollDegrees)
        let right = unrolledRight * cos(roll) - unrolledUp * sin(roll)
        let up = unrolledUp * cos(roll) + unrolledRight * sin(roll)
        let floatPosition = SIMD3<Float>(position)
        let floatTarget = SIMD3<Float>(rig.target)
        guard rig.distance.isFinite, rig.distance > 0,
              orthographicScale.isFinite, orthographicScale > 0,
              position.x.isFinite, position.y.isFinite, position.z.isFinite,
              floatPosition.x.isFinite, floatPosition.y.isFinite, floatPosition.z.isFinite,
              floatPosition != floatTarget else {
            throw LADError.message("The requested camera is too close or too far for rendering precision. Reduce the zoom or choose another camera position.")
        }
        return CADAgentCameraPose(rig: rig, right: right, up: up, backward: backward,
                                  position: position, automaticDistance: automaticDistance, baseDistance: baseDistance,
                                  orthographicScale: orthographicScale)
    }

    private func radians(_ value: Double) -> Double {
        value.truncatingRemainder(dividingBy: 360) * .pi / 180
    }

    private func vector(_ values: [Double]) -> SIMD3<Double> { SIMD3(values[0], values[1], values[2]) }
}

struct CADAgentCameraPose: Sendable {
    var rig: CameraRig
    var right: SIMD3<Double>
    var up: SIMD3<Double>
    var backward: SIMD3<Double>
    var position: SIMD3<Double>
    var automaticDistance: Double
    var baseDistance: Double
    var orthographicScale: Double

    var target: SIMD3<Double> { rig.target }
    var distance: Double { rig.distance }
}
