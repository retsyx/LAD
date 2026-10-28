import Foundation

enum CADFeatureKind: String, Codable, CaseIterable, Sendable {
    case vertex, edge, face

    var title: String { rawValue.capitalized }
}

/// Session-local topology identity. Indices use the same native solid and
/// subshape ordering for picking, measurements, and selected STEP export.
struct CADFeatureID: Codable, Hashable, Sendable, Identifiable {
    var kind: CADFeatureKind
    var solidIndex: Int
    var localIndex: Int
    var id: String { "\(kind.rawValue):\(solidIndex):\(localIndex)" }
    var title: String { "\(kind.title) \(localIndex + 1)" }
}

struct CADVertex: Codable, Sendable {
    var id: CADFeatureID
    var position: [Double]
}

struct CADEdge: Codable, Sendable {
    var id: CADFeatureID
    var type: String
    var length: Double
    var polyline: [[Double]]
    var radius: Double? = nil
    var diameter: Double? = nil
    var center: [Double]? = nil
    var axis: [Double]? = nil
    /// A unit direction exists for straight edges only.
    var direction: [Double]? = nil
    var majorRadius: Double? = nil
    var minorRadius: Double? = nil
    var startPoint: [Double]? = nil
    var endPoint: [Double]? = nil
    var sweepDegrees: Double? = nil
    var closed: Bool? = nil
}

struct CADFace: Codable, Sendable {
    var id: CADFeatureID
    var type: String
    var area: Double
    /// Exact surface-area centroid, rather than the bounding-box midpoint.
    var center: [Double]
    /// Constant, oriented plane normal. Curved surfaces have no single normal.
    var normal: [Double]? = nil
    var axis: [Double]? = nil
    var radius: Double? = nil
    var majorRadius: Double? = nil
    var minorRadius: Double? = nil
    var perimeter: Double? = nil
    var diameter: Double? = nil
    var semiAngleDegrees: Double? = nil
}

struct CADPart: Codable, Sendable {
    var solidIndex: Int
    var area: Double
    var volume: Double
    var bounds: [Double]
    var centroid: [Double]
}

/// Derived session data only. Project archives retain programs and input
/// assets, never this topology metadata or the tessellation it accompanies.
struct CADTopology: Codable, Sendable {
    var vertices: [CADVertex]
    var edges: [CADEdge]
    var faces: [CADFace]
    var parts: [CADPart]

    func vertex(for id: CADFeatureID) -> CADVertex? { vertices.first { $0.id == id } }
    func edge(for id: CADFeatureID) -> CADEdge? { edges.first { $0.id == id } }
    func face(for id: CADFeatureID) -> CADFace? { faces.first { $0.id == id } }
    func contains(_ id: CADFeatureID) -> Bool {
        switch id.kind {
        case .vertex: return vertex(for: id) != nil
        case .edge: return edge(for: id) != nil
        case .face: return face(for: id) != nil
        }
    }
}

enum CADMeasurementUnit: String, Codable, Sendable {
    case length = "mm"
    case area = "mm²"
    case volume = "mm³"
    case angle = "°"
    case scalar = ""
}

struct CADMeasurementMetric: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var values: [Double]
    var unit: CADMeasurementUnit

    var formattedValue: String {
        let number = values.map { value in
            (abs(value) < 0.0000005 ? 0 : value).formatted(.number.precision(.fractionLength(0...6)))
        }.joined(separator: ", ")
        return number + (unit == .scalar ? "" : unit == .angle ? unit.rawValue : " " + unit.rawValue)
    }
}

struct CADMeasurementReport: Codable, Sendable {
    var title: String
    var metrics: [CADMeasurementMetric]
    var features: [CADFeatureID]
    var solidIndices: [Int]
    var closestPoints: [[Double]]? = nil
}

enum CADMeasurements {
    /// Validate the app/worker contract before any picking code indexes these
    /// arrays. Complete topology ownership is required when metadata is present.
    static func validateTopology(_ preview: PreviewMesh) throws {
        guard let topology = preview.topology else {
            guard preview.triangleFaces == nil, preview.edgeFeatures == nil else {
                throw LADError.message("The CAD preview is missing its topology metadata.")
            }
            return
        }
        func point(_ values: [Double]) -> Bool { values.count == 3 && values.allSatisfy { $0.isFinite && abs($0) <= 1_000_000.1 } }
        func optionalPoint(_ values: [Double]?) -> Bool { values.map(point) ?? true }
        func positive(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 > 0 } ?? true }
        // Curved edge polygons share the surface mesher's boundary nodes.
        // Bound their total by the existing preview segment budget instead of
        // truncating individual curves and moving their chords into the solid.
        var remainingEdgeSegments = 250_000
        func polyline(_ points: [[Double]]) -> Bool {
            let segments = max(0, points.count - 1)
            guard segments <= remainingEdgeSegments, points.allSatisfy(point) else { return false }
            remainingEdgeSegments -= segments
            return true
        }
        func identities(_ ids: [CADFeatureID], kind: CADFeatureKind) -> Bool {
            var next: [Int: Int] = [:]
            for id in ids {
                guard id.kind == kind, id.solidIndex >= 0, id.solidIndex < preview.solids,
                      id.localIndex == next[id.solidIndex, default: 0] else { return false }
                next[id.solidIndex, default: 0] += 1
            }
            return true
        }
        guard topology.vertices.count <= 1_000_000, topology.edges.count <= 250_000, topology.faces.count <= 80_000,
              identities(topology.vertices.map(\.id), kind: .vertex), identities(topology.edges.map(\.id), kind: .edge),
              identities(topology.faces.map(\.id), kind: .face),
              topology.vertices.allSatisfy({ point($0.position) }),
              topology.edges.allSatisfy({ edge in
                  !edge.type.isEmpty && edge.type.count <= 32 && edge.length.isFinite && edge.length >= 0 &&
                  polyline(edge.polyline) && positive(edge.radius) && positive(edge.diameter) &&
                  positive(edge.majorRadius) && positive(edge.minorRadius) && optionalPoint(edge.center) && optionalPoint(edge.axis) &&
                  optionalPoint(edge.direction) && optionalPoint(edge.startPoint) && optionalPoint(edge.endPoint) &&
                  (edge.sweepDegrees.map { $0.isFinite && $0 >= 0 && $0 <= 360.0001 } ?? true)
              }),
              topology.faces.allSatisfy({ face in
                  !face.type.isEmpty && face.type.count <= 32 && face.area.isFinite && face.area > 0 && point(face.center) &&
                  optionalPoint(face.normal) && optionalPoint(face.axis) && positive(face.radius) && positive(face.diameter) &&
                  positive(face.majorRadius) && positive(face.minorRadius) &&
                  (face.perimeter.map { $0.isFinite && $0 >= 0 } ?? true) &&
                  (face.semiAngleDegrees.map { $0.isFinite && $0 >= 0 && $0 <= 90 } ?? true)
              }),
              topology.parts.count == preview.solids, Set(topology.parts.map(\.solidIndex)) == Set(0..<preview.solids),
              topology.parts.allSatisfy({ part in
                  part.area.isFinite && part.area > 0 && part.volume.isFinite && part.volume > 0 &&
                  part.bounds.count == 6 && part.bounds.allSatisfy(\.isFinite) &&
                  (0..<3).allSatisfy({ part.bounds[$0] <= part.bounds[$0 + 3] }) && point(part.centroid)
              }),
              let faces = preview.triangleFaces, faces.count == preview.triangles.count,
              faces.allSatisfy({ topology.faces.indices.contains($0) }),
              let edges = preview.edgeFeatures, edges.count == preview.edges.count,
              edges.allSatisfy({ topology.edges.indices.contains($0) }) else {
            throw LADError.message("The CAD preview contains invalid topology metadata.")
        }
        if let owners = preview.triangleSolids {
            guard zip(faces, owners).allSatisfy({ topology.faces[$0.0].id.solidIndex == $0.1 }) else {
                throw LADError.message("The CAD preview face ownership does not match its parts.")
            }
        }
        if let owners = preview.edgeSolids {
            guard zip(edges, owners).allSatisfy({ topology.edges[$0.0].id.solidIndex == $0.1 }) else {
                throw LADError.message("The CAD preview edge ownership does not match its parts.")
            }
        }
    }

    /// Single-item and aggregate metrics already come from exact native
    /// geometry. Computing these locally avoids a Python startup for each pick.
    static func report(_ preview: PreviewMesh, features: [CADFeatureID], solids: Set<Int>) throws -> CADMeasurementReport {
        guard let topology = preview.topology else {
            throw LADError.message("Rebuild the design to enable precise measurements.")
        }
        var seen = Set<CADFeatureID>()
        let features = features.filter { seen.insert($0).inserted }
        guard features.allSatisfy(topology.contains), solids.allSatisfy({ $0 >= 0 && $0 < preview.solids }),
              !features.isEmpty || !solids.isEmpty else {
            throw LADError.message("Select a part, face, edge, or vertex to measure.")
        }
        var metrics: [CADMeasurementMetric] = []
        func add(_ id: String, _ label: String, _ values: [Double], _ unit: CADMeasurementUnit) {
            metrics.append(CADMeasurementMetric(id: id, label: label, values: values, unit: unit))
        }
        for (index, id) in features.enumerated() {
            let prefix = features.count > 1 || !solids.isEmpty ? "\(id.kind.title) \(index + 1) · " : ""
            func value(_ key: String, _ label: String, _ values: [Double], _ unit: CADMeasurementUnit) {
                add(id.id + ":" + key, prefix + label, values, unit)
            }
            switch id.kind {
            case .vertex:
                value("position", "Coordinates X, Y, Z", topology.vertex(for: id)!.position, .length)
            case .edge:
                let edge = topology.edge(for: id)!
                value("length", edge.type == "CIRCLE" ? (edge.closed == true ? "Circumference" : "Arc length") : "Length", [edge.length], .length)
                if let radius = edge.radius { value("radius", "Radius", [radius], .length) }
                if let diameter = edge.diameter { value("diameter", "Diameter", [diameter], .length) }
                if let center = edge.center { value("center", "Center", center, .length) }
                if let radius = edge.majorRadius { value("majorRadius", "Major radius", [radius], .length) }
                if let radius = edge.minorRadius { value("minorRadius", "Minor radius", [radius], .length) }
                if let axis = edge.axis { value("axis", "Axis direction", axis, .scalar) }
                if let direction = edge.direction { value("direction", "Line direction", direction, .scalar) }
                if let angle = edge.sweepDegrees { value("sweep", "Sweep angle", [angle], .angle) }
                if let start = edge.startPoint, let end = edge.endPoint {
                    value("start", "Start X, Y, Z", start, .length)
                    value("end", "End X, Y, Z", end, .length)
                    if edge.closed != true { value("chord", "Chord length", [distance(start, end)], .length) }
                }
            case .face:
                let face = topology.face(for: id)!
                value("area", "Area", [face.area], .area)
                if let perimeter = face.perimeter { value("perimeter", "Perimeter", [perimeter], .length) }
                value("center", "Surface centroid", face.center, .length)
                if let normal = face.normal { value("normal", "Plane normal", normal, .scalar) }
                if let radius = face.radius { value("radius", "Radius", [radius], .length) }
                if let radius = face.majorRadius { value("majorRadius", "Major radius", [radius], .length) }
                if let radius = face.minorRadius { value("minorRadius", "Minor radius", [radius], .length) }
                if let diameter = face.diameter { value("diameter", "Diameter", [diameter], .length) }
                if let axis = face.axis { value("axis", "Axis direction", axis, .scalar) }
                if let angle = face.semiAngleDegrees { value("semiAngle", "Cone half-angle", [angle], .angle) }
            }
        }
        if !solids.isEmpty {
            let parts = topology.parts.filter { solids.contains($0.solidIndex) }
            guard parts.count == solids.count, parts.allSatisfy({ $0.volume.isFinite && $0.volume > 0 && $0.area.isFinite && $0.area > 0 && $0.bounds.count == 6 && $0.centroid.count == 3 }) else {
                throw LADError.message("The selected parts are no longer available. Select them again.")
            }
            let volume = parts.reduce(0) { $0 + $1.volume }
            let area = parts.reduce(0) { $0 + $1.area }
            guard volume.isFinite, volume > 0, area.isFinite else { throw LADError.message("The selected parts have invalid measurement metadata.") }
            let minimum = (0..<3).map { axis in parts.map { $0.bounds[axis] }.min()! }
            let maximum = (0..<3).map { axis in parts.map { $0.bounds[axis + 3] }.max()! }
            let centroid = (0..<3).map { axis in parts.reduce(0) { $0 + $1.centroid[axis] * $1.volume } / volume }
            add("parts:count", "Parts", [Double(parts.count)], .scalar)
            add("parts:volume", "Volume", [volume], .volume)
            add("parts:area", "Surface area", [area], .area)
            add("parts:size", "Size X, Y, Z", zip(maximum, minimum).map(-), .length)
            add("parts:minimum", "Minimum X, Y, Z", minimum, .length)
            add("parts:maximum", "Maximum X, Y, Z", maximum, .length)
            add("parts:centroid", "Volume centroid", centroid, .length)
        }
        let selectedEdges = features.filter { $0.kind == .edge }.compactMap { topology.edge(for: $0) }
        if selectedEdges.count > 1 { add("edges:totalLength", "Total edge length", [selectedEdges.reduce(0) { $0 + $1.length }], .length) }
        let selectedFaces = features.filter { $0.kind == .face }.compactMap { topology.face(for: $0) }
        if selectedFaces.count > 1 {
            add("faces:totalArea", "Total face area", [selectedFaces.reduce(0) { $0 + $1.area }], .area)
            if selectedFaces.allSatisfy({ $0.perimeter != nil }) {
                add("faces:totalPerimeter", "Total face perimeter", [selectedFaces.reduce(0) { $0 + $1.perimeter! }], .length)
            }
        }
        var closestPoints: [[Double]]?
        if features.count == 2, solids.isEmpty, features.allSatisfy({ $0.kind == .vertex }) {
            let first = topology.vertex(for: features[0])!.position, second = topology.vertex(for: features[1])!.position
            add("pair:distance", "Distance", [distance(first, second)], .length)
            add("pair:delta", "Delta X, Y, Z", subtract(second, first), .length)
            closestPoints = [first, second]
        }
        if features.count == 3, solids.isEmpty, features.allSatisfy({ $0.kind == .vertex }) {
            let points = features.map { topology.vertex(for: $0)!.position }
            let a = subtract(points[0], points[1]), b = subtract(points[2], points[1])
            let lengths = [distance(points[0], points[1]), distance(points[1], points[2]), distance(points[2], points[0])]
            if lengths[0] > 1e-12, lengths[1] > 1e-12 {
                add("triangle:angle", "Angle at second vertex", [acos(max(-1, min(1, dot(a, b) / (lengths[0] * lengths[1])))) * 180 / .pi], .angle)
            }
            let cross = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
            add("triangle:area", "Triangle area", [sqrt(dot(cross, cross)) / 2], .area)
            add("triangle:perimeter", "Triangle perimeter", [lengths.reduce(0, +)], .length)
            add("triangle:sides", "Triangle sides", lengths, .length)
        }
        let title: String
        if features.count == 1 && solids.isEmpty {
            let id = features[0]
            switch id.kind {
            case .vertex: title = "Vertex"
            case .edge: title = topology.edge(for: id)!.type.lowercased().capitalized + " edge"
            case .face: title = topology.face(for: id)!.type.lowercased().capitalized + " face"
            }
        } else { title = "Measurements" }
        return CADMeasurementReport(title: title, metrics: metrics, features: features, solidIndices: solids.sorted(), closestPoints: closestPoints)
    }

    private static func subtract(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map(-) }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func distance(_ a: [Double], _ b: [Double]) -> Double { let delta = subtract(a, b); return sqrt(dot(delta, delta)) }
}
