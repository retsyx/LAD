import Darwin
import Foundation

/// Packed display arrays the CAD worker publishes beside `result.json`.
/// Each section is little-endian 4-byte values: Float32 coordinates, UInt32
/// triangle indices and Int32 owner indices. Reading copies each section
/// straight into its array, without an intermediate text or byte buffer.
enum PreviewMeshBuffers {
    static let fileName = "mesh.bin"
    static let maximumBytes = 256_000_000

    struct Section: Decodable {
        let offset: Int
        let count: Int
    }

    struct Manifest: Decodable {
        let path: String
        let sections: [String: Section]
    }

    /// The worker's result JSON carries the manifest under `meshBuffers`.
    private struct Envelope: Decodable {
        let meshBuffers: Manifest?
    }

    static func manifest(in resultJSON: Data) throws -> Manifest? {
        try JSONDecoder().decode(Envelope.self, from: resultJSON).meshBuffers
    }

    /// Fill a decoded preview's display arrays from the worker's sidecar file.
    /// Values are validated afterwards with the rest of the preview.
    static func read(_ manifest: Manifest, in folder: URL, into mesh: inout PreviewMesh) throws {
        guard manifest.path == fileName,
              Set(manifest.sections.keys).isSubset(of: ["positions", "normals", "triangles", "edges", "triangleSolids",
                                                         "triangleFaces", "edgeSolids", "edgeFeatures"]) else {
            throw LADError.message("The CAD engine returned an unexpected design preview layout.")
        }
        let (file, size) = try EngineArtifact.openRegular(folder.appendingPathComponent(fileName), in: folder)
        defer { try? file.close() }
        guard size <= maximumBytes else { throw LADError.message("The CAD engine design preview exceeds its size limit.") }
        func section<T>(_ name: String, as type: T.Type) throws -> [T]? {
            guard let section = manifest.sections[name] else { return nil }
            let width = MemoryLayout<T>.size
            guard width == 4, section.offset >= 0, section.count >= 0, section.offset % width == 0,
                  section.count <= (Int(size) - section.offset) / width else {
                throw LADError.message("The CAD engine returned an invalid design preview section.")
            }
            return try [T](unsafeUninitializedCapacity: section.count) { buffer, initialized in
                let bytes = UnsafeMutableRawBufferPointer(buffer)
                var done = 0
                while done < bytes.count {
                    let count = Darwin.pread(file.fileDescriptor, bytes.baseAddress! + done, bytes.count - done,
                                             off_t(section.offset + done))
                    guard count > 0 else { throw LADError.message("The CAD engine design preview could not be read.") }
                    done += count
                }
                initialized = section.count
            }
        }
        func owners(_ name: String) throws -> [Int]? { try section(name, as: Int32.self).map { $0.map(Int.init) } }
        mesh.positions = try section("positions", as: Float.self) ?? []
        mesh.vertexNormals = try section("normals", as: Float.self)
        mesh.triangleIndices = try section("triangles", as: UInt32.self) ?? []
        mesh.edgePoints = try section("edges", as: Float.self) ?? []
        mesh.triangleSolids = try owners("triangleSolids")
        mesh.triangleFaces = try owners("triangleFaces")
        mesh.edgeSolids = try owners("edgeSolids")
        mesh.edgeFeatures = try owners("edgeFeatures")
    }
}
