import AppKit
import SceneKit

/// Visibility is rasterized on the actual native edge, before its highlight
/// is expanded in screen space. Curved faces cannot trim the expanded width.
@MainActor
enum CADStrokeSeedGeometry {
    private static let modifier = """
    #pragma body
    float4 cadClip = scn_node.modelViewProjectionTransform * _geometry.position;
    cadClip.z += 2e-6 * cadClip.w;
    _geometry.position = scn_node.inverseModelViewProjectionTransform * cadClip;
    """

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
        geometry.shaderModifiers = [.geometry: modifier]
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.red
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        material.blendMode = .add
        // RG carries edge visibility; BA is reserved for vertex centers.
        material.shaderModifiers = [.fragment: "#pragma body\n_output.color.a = 0.0;"]
        geometry.materials = [material]
        return geometry
    }
}
