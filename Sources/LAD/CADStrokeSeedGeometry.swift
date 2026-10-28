import AppKit
import SceneKit

/// Rasterize native edge centerlines for the unoccluded highlight overlay.
/// The screen-space technique supplies their constant core and halo widths.
@MainActor
enum CADStrokeSeedGeometry {
    static func make(_ segments: [[Double]]) -> SCNGeometry {
        var positions = [SCNVector3](), indices = [Int32]()
        positions.reserveCapacity(segments.count * 2)
        indices.reserveCapacity(segments.count * 2)
        for segment in segments {
            guard segment.count == 6, segment.allSatisfy({ $0.isFinite && abs($0) < 1e12 }),
                  positions.count <= Int(Int32.max) - 2 else { continue }
            let first = Int32(positions.count)
            positions.append(SCNVector3(segment[0], segment[1], segment[2]))
            positions.append(SCNVector3(segment[3], segment[4], segment[5]))
            indices.append(contentsOf: [first, first + 1])
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.red
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.blendMode = .add
        // RG carries edge coverage; BA is reserved for vertex centers.
        material.shaderModifiers = [.fragment: "#pragma body\n_output.color.a = 0.0;"]
        geometry.materials = [material]
        return geometry
    }
}
