import Foundation

/// A program-pinned printing direction: the outward direction, in the built
/// design's world coordinates, that faces the build plate.
struct PrintDownPin: Codable, Sendable, Equatable {
    var solid: Int
    var direction: [Double]
}

/// One solid's printing orientation from the CAD worker: a rigid world delta
/// from the built solid, and the oriented solid's exact bounds.
struct PrintOrientation: Codable, Sendable, Equatable {
    var solid: Int
    var matrix: [Double]
    var bounds: [Double]
}

/// The 3D printing geometry pipeline shared by the viewport and STEP export.
/// The worker orients each solid once; packing on the bed is a translation
/// of those orientations, so any subset can be packed again cheaply.
enum PrintLayout {
    static let gap = 50.0

    /// Shelf-pack the oriented solids on z = 0 with `gap` millimetres between
    /// footprints, returning each solid's complete rigid world delta.
    static func transforms(for solids: Set<Int>, orientations: [Int: PrintOrientation]) -> [Int: [Double]] {
        let placed = solids.sorted().compactMap { orientations[$0] }
        guard !placed.isEmpty else { return [:] }
        func size(_ item: PrintOrientation) -> (width: Double, depth: Double) {
            (item.bounds[3] - item.bounds[0], item.bounds[4] - item.bounds[1])
        }
        let target = max(placed.map { size($0).width }.max() ?? 0,
                         placed.map { (size($0).width + gap) * (size($0).depth + gap) }.reduce(0, +).squareRoot())
        let order = placed.sorted {
            let a = size($0), b = size($1)
            if a.depth != b.depth { return a.depth > b.depth }
            if a.width != b.width { return a.width > b.width }
            return $0.solid < $1.solid
        }
        var result: [Int: [Double]] = [:]
        var x = 0.0, y = 0.0, rowDepth = 0.0
        for item in order {
            let (width, depth) = size(item)
            if x > 0, x + width > target { x = 0; y += rowDepth + gap; rowDepth = 0 }
            var matrix = item.matrix
            matrix[3] += x - item.bounds[0]
            matrix[7] += y - item.bounds[1]
            matrix[11] -= item.bounds[2]
            result[item.solid] = matrix
            x += width + gap
            rowDepth = max(rowDepth, depth)
        }
        return result
    }

    static func validatePins(_ preview: PreviewMesh) throws {
        guard let pins = preview.printDown else { return }
        guard pins.count <= preview.solids, Set(pins.map(\.solid)).count == pins.count,
              pins.allSatisfy({ pin in
                  (0..<preview.solids).contains(pin.solid) && pin.direction.count == 3
                      && pin.direction.allSatisfy(\.isFinite)
                      && abs(pin.direction.reduce(0) { $0 + $1 * $1 } - 1) < 1e-6
              }) else { throw LADError.message("The CAD engine returned invalid printing directions.") }
    }

    /// Validate worker orientations for exactly the requested solids.
    static func validatedOrientations(_ records: [PrintOrientation], requested: [Int],
                                      solidCount: Int) throws -> [Int: PrintOrientation] {
        let invalid = LADError.message("The CAD engine returned invalid printing orientations.")
        guard records.map(\.solid) == requested else { throw invalid }
        _ = try AssemblySolidTransform.validatedRecords(
            Dictionary(uniqueKeysWithValues: records.map { ($0.solid, $0.matrix) }), solidCount: solidCount)
        guard records.allSatisfy({ record in
            record.bounds.count == 6 && record.bounds.allSatisfy { $0.isFinite && abs($0) <= 1e9 }
                && (0..<3).allSatisfy { record.bounds[$0] <= record.bounds[$0 + 3] }
        }) else { throw invalid }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.solid, $0) })
    }

    /// The 3D printing version replaces geometry within parts. Colors,
    /// visibility, hierarchy and selections are keyed by solid, so it must
    /// keep the design's physical parts and their solids.
    static func validateParts(of print: PreviewMesh, matching design: PreviewMesh) throws {
        func owners(_ preview: PreviewMesh) -> [String: [Int]] {
            guard let parts = preview.parts else {
                return Dictionary(uniqueKeysWithValues: (0..<preview.solids).map { ("solid/\($0)", [$0]) })
            }
            return Dictionary(parts.flatMap(\.flattened).filter { !$0.solidIndices.isEmpty }.map { ($0.id, $0.solidIndices) },
                              uniquingKeysWith: { first, _ in first })
        }
        let expected = owners(design), actual = owners(print)
        guard print.solids == design.solids, expected == actual else {
            let missing = Set(expected.keys).subtracting(actual.keys).sorted()
            let added = Set(actual.keys).subtracting(expected.keys).sorted()
            let changed = Set(expected.keys).intersection(actual.keys).filter { expected[$0] != actual[$0] }.sorted()
            var details = ["The design has \(design.solids) solids and its lad.print version has \(print.solids)."]
            if !missing.isEmpty { details.append("Missing lad_id values: \(missing.prefix(20).joined(separator: ", ")).") }
            if !added.isEmpty { details.append("Added lad_id values: \(added.prefix(20).joined(separator: ", ")).") }
            if !changed.isEmpty { details.append("Parts with different solids: \(changed.prefix(20).joined(separator: ", ")).") }
            throw EngineBuildFailure(kind: .design,
                message: "The 3D printing version of this design has different parts. It must keep the same parts as the design.",
                report: "The lad.print = True build must produce the same physical parts as the ordinary build: identical lad_id values, each owning the same number of solids in the same order. Express printing changes within each part's geometry. " + details.joined(separator: " "))
        }
    }
}
