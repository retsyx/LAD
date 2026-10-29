import Foundation

struct ModelSpec: Codable, Sendable, Equatable {
    var title: String
    var summary: String
    var units: String
    var script: String
    /// Original exact geometry exposed to CadQuery programs as `imported_model`.
    var sourceSTEP: Data? = nil
    var sourceName: String? = nil
    /// Existing user placements may change only when explicitly requested.
    var reorganizePartIDs: [String]? = nil
    /// Portable inputs required by imported_assets in the saved CAD program.
    var inputAssets: [CADInputAsset]? = nil

    static let bracket = ModelSpec(
        title: "Mounting bracket",
        summary: "An 80 × 50 mm mounting bracket with a 40 mm upright, four 6 mm mounting holes, and a 16 mm cable opening. All dimensions are in millimeters.",
        units: "mm",
        script: """
        import cadquery as cq

        base = cq.Workplane("XY").box(80, 50, 6, centered=(True, True, False)).val()
        wall = cq.Workplane("XY").box(80, 6, 40, centered=(True, True, False)).val().translate((0, 22, 0))
        body = base.fuse(wall).clean()
        hole = cq.Solid.makeCylinder(3, 10)
        holes = [hole.translate(position) for position in [(-28, -14, -2), (28, -14, -2), (-28, 8, -2), (28, 8, -2)]]
        opening = cq.Solid.makeCylinder(8, 12).rotate((0, 0, 0), (1, 0, 0), 90).translate((0, 28, 25))
        result = body.cut(*holes, opening).clean()
        """
    )

    private enum CodingKeys: String, CodingKey {
        case title, summary, units, script, sourceSTEP, sourceName, reorganizePartIDs, inputAssets
    }
}

extension ModelSpec {
    init(from decoder: Decoder) throws {
        enum UnsupportedFields: String, CodingKey { case nodes, result }
        let unsupported = try decoder.container(keyedBy: UnsupportedFields.self)
        guard !unsupported.contains(.nodes), !unsupported.contains(.result) else {
            throw LADError.message("Feature graphs are unsupported. A design must contain a complete CadQuery program.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        summary = try values.decode(String.self, forKey: .summary)
        units = try values.decode(String.self, forKey: .units)
        script = try values.decode(String.self, forKey: .script)
        sourceSTEP = try values.decodeIfPresent(Data.self, forKey: .sourceSTEP)
        sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName)
        reorganizePartIDs = try values.decodeIfPresent([String].self, forKey: .reorganizePartIDs)
        inputAssets = try values.decodeIfPresent([CADInputAsset].self, forKey: .inputAssets)
    }
}

struct PartNode: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var solidIndices: [Int]
    var children: [PartNode]? = nil
    /// Opaque sRGB color for this node's own solids.
    var color: PartColor? = nil

    var isGroup: Bool { children != nil }
    var allSolidIndices: Set<Int> {
        Set(solidIndices).union((children ?? []).flatMap { $0.allSolidIndices })
    }
    var allNodeIDs: Set<String> { Set([id]).union((children ?? []).flatMap { $0.allNodeIDs }) }
    var flattened: [PartNode] { [self] + (children ?? []).flatMap(\.flattened) }
}

struct CADRuntime: Codable, Sendable, Equatable {
    var python: String
    var cadquery: String
    var ocp: String
}

struct PreviewMesh: Codable, Sendable {
    var vertices: [[Double]]
    var triangles: [[Int]]
    var edges: [[Double]]
    var bounds: [Double]
    var volume: Double
    var area: Double
    var solids: Int
    var faces: Int
    var buildSeconds: Double
    var threads: Int
    var stepPath: String
    var triangleSolids: [Int]? = nil
    var edgeSolids: [Int]? = nil
    var parts: [PartNode]? = nil
    /// Private session artifact used to export STEP without replaying a program.
    /// Never stored in a project archive.
    var brepPath: String? = nil
    var runtime: CADRuntime? = nil

    /// Session-only exact topology and render-element ownership for CAD picking.
    var topology: CADTopology? = nil
    /// Indices into topology.faces, one per preview triangle.
    var triangleFaces: [Int]? = nil
    /// Indices into topology.edges, one per sampled edge segment.
    var edgeFeatures: [Int]? = nil

    /// Exact oriented surface normals, parallel to vertices. Derived worker
    /// output only; project archives never retain display buffers. Synthetic
    /// previews may omit these when no native CAD surface is available.
    var normals: [[Double]]? = nil

    /// Keeps private native files alive across copies and history navigation.
    /// Decoding derived worker JSON never grants ownership of arbitrary paths.
    var buildArtifacts: EngineBuildArtifacts? = nil

    private enum CodingKeys: String, CodingKey {
        case vertices, triangles, edges, bounds, volume, area, solids, faces, buildSeconds, threads, stepPath
        case triangleSolids, edgeSolids, parts, brepPath, runtime, topology, triangleFaces, edgeFeatures, normals
    }

    var hasValidNormals: Bool {
        guard let normals, normals.count == vertices.count else { return false }
        return normals.allSatisfy { normal in
            guard normal.count == 3, normal.allSatisfy(\.isFinite) else { return false }
            let lengthSquared = normal.reduce(0) { $0 + $1 * $1 }
            return abs(lengthSquared - 1) <= 0.0001
        }
    }

    var size: [Double] {
        guard bounds.count == 6 else { return [0, 0, 0] }
        return (0..<3).map { bounds[$0 + 3] - bounds[$0] }
    }
}

struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var role: String
    var content: String
    var date = Date()
    var attachments: [SourceAttachment]? = nil
    /// Assistant updates, conversational replies, and validated CAD closeouts.
    var phase: String? = nil
    /// Immutable user selection captured when this request was submitted.
    var selection: ProjectSelectionContext? = nil
}

/// A submitted follow-up awaiting its own turn; distinct from sent chat history.
struct ProjectQueuedRequest: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var content: String
    var date = Date()
    var attachments: [SourceAttachment]? = nil
    /// Capture the choice at enqueue time without changing later composer choices.
    var codexSettings: CodexProjectSettings? = nil
    /// Exact user-reference paths already snapshotted, including aliases that
    /// may disappear or be retargeted before this request is dispatched.
    var capturedSourcePaths: [String]? = nil
    /// Retained while queued, edited or sent as same-turn information.
    var selection: ProjectSelectionContext? = nil
}

struct ProjectRevision: Codable, Sendable, Identifiable {
    var id = UUID()
    var model: ModelSpec
    var date = Date()
    var preview: PreviewMesh? = nil
    var stepData: Data? = nil
    var partLayout: PartLayout? = nil
    var hiddenSolids: [Int]? = nil
    /// Stable default hierarchy, independent of the regenerable display mesh.
    var parts: [PartNode]? = nil
    /// Versions used to validate the saved modeling instructions.
    var runtime: CADRuntime? = nil
    /// The successful conversation turn that produced this validated model.
    var userMessageID: UUID? = nil
    var responseMessageID: UUID? = nil
    /// User-selected opaque colors, addressed by stable individual part IDs.
    var partColors: [String: PartColor]? = nil
    /// Optional user label; unnamed revisions display their stable history position.
    var name: String? = nil
}

/// Revision labels are document metadata, not filenames or generated model titles.
enum ProjectRevisionNaming {
    static let maximumNameBytes = 512

    static func userName(_ entered: String) throws -> String? {
        guard entered.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }) else { throw LADError.message("Version names cannot contain line breaks or control characters.") }
        let name = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.utf8.count <= maximumNameBytes else {
            throw LADError.message("The version name is too long.")
        }
        return name.isEmpty ? nil : name
    }

    static func validateSavedName(_ name: String) throws {
        guard try userName(name) == name else {
            throw LADError.message("The saved version name is empty or contains surrounding whitespace.")
        }
    }
}

struct LADProject: Codable, Sendable {
    var formatVersion = 1
    var messages: [ChatMessage]
    var revisions: [ProjectRevision]
    var selectedRevisionID: UUID?
    /// Stable identity for autosave naming, independent of title and revisions.
    /// Identity remains stable across renames and model revisions.
    var projectID: UUID? = nil
    /// Model and reasoning choices travel with this document, not app settings.
    var codexSettings: CodexProjectSettings? = nil
    /// An explicit user name overrides generated design titles for this project.
    var projectName: String? = nil
    /// Grid visibility belongs to the project; absent values use the default.
    var showGrid: Bool? = nil
    /// Projection and surface rendering choices are local to this design.
    var projectionMode: ViewportProjectionMode? = nil
    var displayMode: ViewportDisplayMode? = nil
    /// Most recently chosen part colors, newest first, local to this design.
    var recentPartColors: [PartColor]? = nil
    /// Tool and command activity belongs to this project and survives reopening.
    var taskAudits: [ProjectTaskAudit]? = nil
    /// Pending turns and the current unsent composer travel with this project.
    var queuedRequests: [ProjectQueuedRequest]? = nil
    var draftPrompt: String? = nil
    var draftAttachments: [SourceAttachment]? = nil
    var queuePaused: Bool? = nil
    /// Preferred share of the sidebar height reserved for Parts, local to this project.
    var partsPaneFraction: Double = 0.75
    /// Session-only file baseline for conflict detection, including first save.
    var fileOrigin: ProjectFileOrigin? = nil

    private enum CodingKeys: String, CodingKey {
        case formatVersion, messages, revisions, selectedRevisionID, projectID, codexSettings, projectName
        case showGrid, projectionMode, displayMode, recentPartColors, taskAudits, queuedRequests
        case draftPrompt, draftAttachments, queuePaused, partsPaneFraction
    }
}

enum LADError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum ResourcePaths {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["LAD_ROOT"] { return URL(fileURLWithPath: path) }
        // Packaged app keeps its engine alongside the resource bundle.
        let packaged = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        if FileManager.default.fileExists(atPath: packaged.appendingPathComponent("Engine/worker.py").path) { return packaged }
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Engine/worker.py").path) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static func resource(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    }
}
