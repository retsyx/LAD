import Foundation

/// The `request.json` a CAD worker reads. Each case is one operation
/// Engine/worker.py accepts and encodes exactly the fields it allows.
/// Reconstruction requests are built by `CADMeshSession`.
enum EngineWorkerRequest: Encodable, Sendable {
    /// An imported input staged beside the request as `path`, with the
    /// worker's validated copy from an earlier build when one is staged.
    struct InputAsset: Encodable, Sendable {
        var id: String
        var name: String
        var format: String
        var path: String
        var validatedBREP: String? = nil
    }

    /// A build's native solid staged beside the request as `source.brep`. The
    /// identity lets the long-lived worker reuse the solid it already read; a
    /// solid it validated when building is not checked again.
    struct NativeSource: Sendable {
        var identity: String
        var validated: Bool
    }

    struct SolidColor: Encodable, Sendable {
        var solidIndex: Int
        var color: PartColor
    }

    struct Export: Sendable {
        /// Nil exports every solid.
        var solidIndices: [Int]?
        var solidTransforms: [AssemblySolidTransform] = []
        var solidColors: [SolidColor] = []
        /// One STEP file per group of solids, in order.
        var individualParts: [[Int]]?
    }

    /// Replay a CAD program. Imported geometry is staged beside the request.
    /// `print` builds the program's 3D printing version.
    case build(title: String, summary: String, units: String, script: String, sourceAsset: String?, inputAssets: [InputAsset],
               print: Bool = false, sourceValidatedBREP: String? = nil)
    case runtime
    case export(NativeSource, Export)
    /// One planar face as a 2D DXF drawing, seen from outside its solid.
    case faceDXF(NativeSource, face: CADFeatureID, solidTransforms: [AssemblySolidTransform])
    case measure(NativeSource, features: [CADFeatureID], solidIndices: [Int], solidTransforms: [AssemblySolidTransform]?)
    /// Exact clearance of each pair of solid groups at each pose.
    case clearance(NativeSource, pairs: [[[Int]]], poses: [[AssemblySolidTransform]])
    /// Printing orientations of the selected solids; nil selects every solid.
    case printOrientations(NativeSource, solidIndices: [Int]?, printDown: [PrintDownPin])
    /// The exact checks and STEP verification a preview build deferred.
    case verify(NativeSource)

    private enum Key: String, CodingKey {
        case operation, title, summary, units, script, sourceAsset, sourceValidatedBREP, inputAssets, print, brepAsset,
             nativeIdentity, validatedNative,
             solidIndices, solidTransforms, solidColors, individualParts, feature, features, pairs, poses, printDown
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        func encodeSource(_ source: NativeSource, operation: String) throws {
            try values.encode(operation, forKey: .operation)
            try values.encode("source.brep", forKey: .brepAsset)
            try values.encode(source.identity, forKey: .nativeIdentity)
            try values.encode(source.validated, forKey: .validatedNative)
        }
        switch self {
        case let .build(title, summary, units, script, sourceAsset, inputAssets, print, sourceValidatedBREP):
            try values.encode(title, forKey: .title)
            try values.encode(summary, forKey: .summary)
            try values.encode(units, forKey: .units)
            try values.encode(script, forKey: .script)
            try values.encodeIfPresent(sourceAsset, forKey: .sourceAsset)
            try values.encodeIfPresent(sourceValidatedBREP, forKey: .sourceValidatedBREP)
            if !inputAssets.isEmpty { try values.encode(inputAssets, forKey: .inputAssets) }
            if print { try values.encode(true, forKey: .print) }
        case .runtime:
            try values.encode("runtime", forKey: .operation)
        case let .export(source, export):
            try encodeSource(source, operation: "export")
            try values.encodeIfPresent(export.solidIndices, forKey: .solidIndices)
            if !export.solidTransforms.isEmpty { try values.encode(export.solidTransforms, forKey: .solidTransforms) }
            if !export.solidColors.isEmpty { try values.encode(export.solidColors, forKey: .solidColors) }
            try values.encodeIfPresent(export.individualParts, forKey: .individualParts)
        case let .faceDXF(source, face, solidTransforms):
            try encodeSource(source, operation: "dxf")
            try values.encode(face, forKey: .feature)
            if !solidTransforms.isEmpty { try values.encode(solidTransforms, forKey: .solidTransforms) }
        case let .measure(source, features, solidIndices, solidTransforms):
            try encodeSource(source, operation: "measure")
            try values.encode(features, forKey: .features)
            try values.encode(solidIndices, forKey: .solidIndices)
            try values.encodeIfPresent(solidTransforms, forKey: .solidTransforms)
        case let .clearance(source, pairs, poses):
            try encodeSource(source, operation: "clearance")
            try values.encode(pairs, forKey: .pairs)
            try values.encode(poses, forKey: .poses)
        case let .printOrientations(source, solidIndices, printDown):
            try encodeSource(source, operation: "print_orient")
            try values.encodeIfPresent(solidIndices, forKey: .solidIndices)
            if !printDown.isEmpty { try values.encode(printDown, forKey: .printDown) }
        case let .verify(source):
            try encodeSource(source, operation: "verify")
        }
    }

    func write(to folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
    }
}
