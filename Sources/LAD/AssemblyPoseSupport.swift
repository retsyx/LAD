import Foundation
import simd

/// Stable wire/cache representation; native geometry always receives rigid deltas.
struct AssemblySolidTransform: Codable, Hashable, Sendable {
    var solid: Int
    var matrix: [Double]

    static func records(_ transforms: [Int: [Double]]) -> [Self] {
        transforms.keys.sorted().map { Self(solid: $0, matrix: transforms[$0]!) }
    }

    static func validatedRecords(_ transforms: [Int: [Double]], solidCount: Int) throws -> [Self] {
        guard transforms.count <= solidCount else { throw invalid() }
        return try records(transforms).map { record in
            let m = record.matrix
            guard (0..<solidCount).contains(record.solid), m.count == 16,
                  m.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }),
                  abs(m[12]) < 1e-9, abs(m[13]) < 1e-9, abs(m[14]) < 1e-9, abs(m[15] - 1) < 1e-9 else { throw invalid() }
            let x = SIMD3(m[0], m[4], m[8]), y = SIMD3(m[1], m[5], m[9]), z = SIMD3(m[2], m[6], m[10])
            guard abs(simd_length_squared(x) - 1) < 1e-6, abs(simd_length_squared(y) - 1) < 1e-6,
                  abs(simd_length_squared(z) - 1) < 1e-6,
                  abs(simd_dot(x, y)) < 1e-6, abs(simd_dot(x, z)) < 1e-6, abs(simd_dot(y, z)) < 1e-6,
                  abs(simd_dot(simd_cross(x, y), z) - 1) < 1e-6 else { throw invalid() }
            return record
        }
    }

    private static func invalid() -> LADError { .message("The design has an invalid assembly placement.") }

    static func point(_ point: [Double], by matrix: [Double], direction: Bool = false) -> [Double] {
        guard point.count == 3, matrix.count == 16 else { return point }
        return (0..<3).map { row in
            let offset = row * 4
            return matrix[offset] * point[0] + matrix[offset + 1] * point[1] + matrix[offset + 2] * point[2]
                + (direction ? 0 : matrix[offset + 3])
        }
    }
}
