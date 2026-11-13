import Foundation

/// Default naming for a single face's DXF drawing.
enum FaceDXFExport {
    /// "<design> - <part>.dxf", without path separators or hidden-file prefixes.
    static func fileName(design: String, part: String) -> String {
        "\(STEPIndividualExport.filenameStem("\(design) - \(part)", fallback: "Design")).dxf"
    }

    /// The tree name of the part that owns a solid, as in request selection
    /// context, or its numbered fallback.
    static func partName(for solidIndex: Int, in nodes: [PartNode]) -> String {
        nodes.flatMap(\.flattened).last { $0.solidIndices.contains(solidIndex) }?.name ?? "Part \(solidIndex + 1)"
    }
}
