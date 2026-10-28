import AppKit
import SceneKit

/// Rasterize the native vertex center for the unoccluded highlight overlay.
/// The technique expands that pixel into a complete screen-space circle.
@MainActor
enum CADVertexSeedGeometry {
    private static let channels = """
    #pragma body
    // Opaque blue selects a vertex; opaque red previews a hovered vertex.
    // Write the mask channels explicitly so material opacity never changes
    // the alpha channel used to carry hover coverage.
    _output.color = float4(0.0, 0.0, _output.color.b, _output.color.r);
    """

    static func make(_ position: [Double]) -> SCNGeometry {
        let valid = position.count == 3 && position.allSatisfy { $0.isFinite && abs($0) < 1e12 }
        let vertices = valid ? [SCNVector3(position[0], position[1], position[2])] : []
        let element = SCNGeometryElement(indices: valid ? [Int32(0)] : [], primitiveType: .point)
        element.pointSize = 1
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 1
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        geometry.shaderModifiers = [.fragment: channels]
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.blue
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.blendMode = .add
        geometry.materials = [material]
        return geometry
    }
}
