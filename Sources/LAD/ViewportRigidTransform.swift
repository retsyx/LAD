import simd

/// The viewport accepts only proper rigid world-delta transforms. Keeping this
/// boundary separate prevents corrupt pose data from reaching Metal or picking.
enum ViewportRigidTransform {
    static func matrix(_ values: [Double]) -> simd_double4x4? {
        guard values.count == 16, values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }),
              abs(values[12]) < 1e-8, abs(values[13]) < 1e-8,
              abs(values[14]) < 1e-8, abs(values[15] - 1) < 1e-8 else { return nil }
        let x = SIMD3(values[0], values[4], values[8])
        let y = SIMD3(values[1], values[5], values[9])
        let z = SIMD3(values[2], values[6], values[10])
        guard abs(simd_length_squared(x) - 1) < 1e-6,
              abs(simd_length_squared(y) - 1) < 1e-6,
              abs(simd_length_squared(z) - 1) < 1e-6,
              abs(simd_dot(x, y)) < 1e-6, abs(simd_dot(x, z)) < 1e-6,
              abs(simd_dot(y, z)) < 1e-6, simd_dot(simd_cross(x, y), z) > 0.999999 else { return nil }
        return simd_double4x4(columns: (
            SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(values[3], values[7], values[11], 1)))
    }

    static func sceneMatrix(_ matrix: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(matrix.columns.0), SIMD4<Float>(matrix.columns.1),
                               SIMD4<Float>(matrix.columns.2), SIMD4<Float>(matrix.columns.3)))
    }

    static func bounds(_ source: [Double], matrix: simd_double4x4) -> [Double] {
        let corners = (0..<8).map { corner -> SIMD4<Double> in
            matrix * SIMD4(source[corner & 1 == 0 ? 0 : 3],
                           source[corner & 2 == 0 ? 1 : 4],
                           source[corner & 4 == 0 ? 2 : 5], 1)
        }
        return (0..<3).map { axis in corners.map { $0[axis] }.min()! }
            + (0..<3).map { axis in corners.map { $0[axis] }.max()! }
    }
}
