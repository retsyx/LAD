import Foundation

/// The `request.json` a CAD worker reads. Each case is one operation
/// Engine/worker.py accepts and encodes exactly the fields it allows.
/// Reconstruction requests are built by `CADMeshSession`.
enum EngineWorkerRequest: Encodable, Sendable {
    /// An imported input staged beside the request as `path`.
    struct InputAsset: Encodable, Sendable {
        var id: String
        var name: String
        var format: String
        var path: String
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
        var arrangeFor3DPrinting = false
        /// One STEP file per group of solids, in order.
        var individualParts: [[Int]]?
    }

    /// Replay a CAD program. Imported geometry is staged beside the request.
    case build(title: String, summary: String, units: String, script: String, sourceAsset: String?, inputAssets: [InputAsset])
    case runtime
    case export(NativeSource, Export)
    /// One planar face as a 2D DXF drawing, seen from outside its solid.
    case faceDXF(NativeSource, face: CADFeatureID, solidTransforms: [AssemblySolidTransform])
    case measure(NativeSource, features: [CADFeatureID], solidIndices: [Int], solidTransforms: [AssemblySolidTransform]?)
    /// Exact clearance of each pair of solid groups at each pose.
    case clearance(NativeSource, pairs: [[[Int]]], poses: [[AssemblySolidTransform]])

    private enum Key: String, CodingKey {
        case operation, title, summary, units, script, sourceAsset, inputAssets, brepAsset, nativeIdentity, validatedNative,
             solidIndices, solidTransforms, solidColors, arrangeFor3DPrinting, individualParts, feature, features, pairs, poses
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
        case let .build(title, summary, units, script, sourceAsset, inputAssets):
            try values.encode(title, forKey: .title)
            try values.encode(summary, forKey: .summary)
            try values.encode(units, forKey: .units)
            try values.encode(script, forKey: .script)
            try values.encodeIfPresent(sourceAsset, forKey: .sourceAsset)
            if !inputAssets.isEmpty { try values.encode(inputAssets, forKey: .inputAssets) }
        case .runtime:
            try values.encode("runtime", forKey: .operation)
        case let .export(source, export):
            try encodeSource(source, operation: "export")
            try values.encodeIfPresent(export.solidIndices, forKey: .solidIndices)
            if !export.solidTransforms.isEmpty { try values.encode(export.solidTransforms, forKey: .solidTransforms) }
            if !export.solidColors.isEmpty { try values.encode(export.solidColors, forKey: .solidColors) }
            if export.arrangeFor3DPrinting { try values.encode(true, forKey: .arrangeFor3DPrinting) }
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
        }
    }

    func write(to folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
    }
}
