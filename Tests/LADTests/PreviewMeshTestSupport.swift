import AppKit
import SceneKit
import XCTest
@testable import LAD

/// Nested-array views of packed preview geometry, for readable test fixtures.
/// Production code reads the packed arrays directly.
extension PreviewMesh {
    init(vertices: [[Double]], triangles: [[Int]], edges: [[Double]], bounds: [Double], volume: Double, area: Double,
         solids: Int, faces: Int, buildSeconds: Double, threads: Int, stepPath: String,
         triangleSolids: [Int]? = nil, edgeSolids: [Int]? = nil, parts: [PartNode]? = nil, brepPath: String? = nil,
         runtime: CADRuntime? = nil, topology: CADTopology? = nil, triangleFaces: [Int]? = nil,
         edgeFeatures: [Int]? = nil, normals: [[Double]]? = nil, validatedHash: String? = nil,
         assemblyMotion: AssemblyMotion? = nil, assemblyPose: AssemblyPose? = nil,
         buildArtifacts: EngineBuildArtifacts? = nil) {
        self.init(bounds: bounds, volume: volume, area: area, solids: solids, faces: faces, buildSeconds: buildSeconds,
                  threads: threads, stepPath: stepPath, triangleSolids: triangleSolids, edgeSolids: edgeSolids,
                  parts: parts, brepPath: brepPath, runtime: runtime, topology: topology, triangleFaces: triangleFaces,
                  edgeFeatures: edgeFeatures, validatedHash: validatedHash, assemblyMotion: assemblyMotion,
                  assemblyPose: assemblyPose, buildArtifacts: buildArtifacts)
        self.vertices = vertices
        self.triangles = triangles
        self.edges = edges
        self.normals = normals
    }

    var vertices: [[Double]] {
        get { Self.unpacked(positions, width: 3) }
        set { positions = Self.packed(newValue) }
    }

    var triangles: [[Int]] {
        get { stride(from: 0, to: triangleIndices.count, by: 3).map { start in (0..<3).map { Int(triangleIndices[start + $0]) } } }
        set { triangleIndices = newValue.flatMap { $0.map { UInt32(truncatingIfNeeded: $0) } } }
    }

    var edges: [[Double]] {
        get { Self.unpacked(edgePoints, width: 6) }
        set { edgePoints = Self.packed(newValue) }
    }

    var normals: [[Double]]? {
        get { vertexNormals.map { Self.unpacked($0, width: 3) } }
        set { vertexNormals = newValue.map(Self.packed) }
    }

    private static func unpacked(_ values: [Float], width: Int) -> [[Double]] {
        stride(from: 0, to: values.count, by: width).map { start in values[start..<min(start + width, values.count)].map(Double.init) }
    }

    private static func packed(_ rows: [[Double]]) -> [Float] { rows.flatMap { $0.map(Float.init) } }

    /// Write this preview in the worker's format: JSON metadata plus mesh.bin.
    /// `sections` replaces or adds raw sections, for malformed-input tests.
    func writeWorkerResult(to folder: URL, sections overrides: [String: [Float]] = [:]) throws -> URL {
        var sections: [String: [String: Int]] = [:], data = Data()
        func append<T>(_ name: String, _ values: [T]?) {
            guard let values else { return }
            sections[name] = ["offset": data.count, "count": values.count]
            values.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        var floats: [String: [Float]] = ["positions": positions, "edges": edgePoints]
        if let vertexNormals { floats["normals"] = vertexNormals }
        floats.merge(overrides) { $1 }
        for (name, values) in floats.sorted(by: { $0.key < $1.key }) { append(name, values) }
        append("triangles", triangleIndices)
        append("triangleSolids", triangleSolids?.map(Int32.init))
        append("triangleFaces", triangleFaces?.map(Int32.init))
        append("edgeSolids", edgeSolids?.map(Int32.init))
        append("edgeFeatures", edgeFeatures?.map(Int32.init))
        try data.write(to: folder.appendingPathComponent(PreviewMeshBuffers.fileName))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any])
        object["meshBuffers"] = ["path": PreviewMeshBuffers.fileName, "sections": sections]
        let url = folder.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    /// Decode a worker result file, reading its packed sidecar beside it.
    static func loadResult(at url: URL) throws -> PreviewMesh {
        let data = try Data(contentsOf: url)
        var mesh = try JSONDecoder().decode(PreviewMesh.self, from: data)
        if let manifest = try PreviewMeshBuffers.manifest(in: data) {
            let folder = try EngineArtifact.canonicalDirectory(url.deletingLastPathComponent())
            try PreviewMeshBuffers.read(manifest, in: folder, into: &mesh)
        }
        return mesh
    }
}

extension CADStrokeGeometry {
    /// Nested segments, six coordinates each, for compact test fixtures.
    nonisolated static func prepare(_ segments: [[Double]], surfaces: [CADStrokeSurface]? = nil) throws -> Prepared {
        try prepare(points: segments.flatMap { $0.count == 6 ? $0.map(Float.init) : Array(repeating: Float.nan, count: 6) },
                    segments: Array(segments.indices), surfaces: surfaces)
    }

    static func make(_ segments: [[Double]], color: NSColor, viewportHeight: CGFloat,
                     surfaces: [CADStrokeSurface]? = nil) -> SCNGeometry {
        make(try! prepare(segments, surfaces: surfaces), color: color, viewportHeight: viewportHeight)
    }
}

extension CADStrokeSurface {
    /// Fixtures are never canceled.
    static func matching(_ mesh: PreviewMesh) -> [CADStrokeSurface] { try! matchingCancellable(mesh) }
}

extension EngineService {
    /// Re-import STEP output for verification, without a generated program.
    func previewSTEP(_ stepData: Data, parts: [PartNode]?, python: String, threads: Int) async throws -> PreviewMesh {
        let output = try await run(python: python, threads: threads, scriptMode: false, action: "regenerate this design’s preview") { folder in
            try Self.validateSTEP(stepData)
            try stepData.write(to: folder.appendingPathComponent("preview.step"), options: .atomic)
            var payload: [String: Any] = ["operation": "preview", "stepAsset": "preview.step"]
            if let parts {
                payload["parts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parts))
            }
            try JSONSerialization.data(withJSONObject: payload).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        }
        return try await readPreview(output, deferSTEP: false)
    }
}
