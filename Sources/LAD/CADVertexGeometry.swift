import AppKit
import SceneKit

/// Cached discs expand on the GPU in screen points, so native CAD vertices
/// retain their size through zoom, projection, Retina and image capture.
@MainActor
enum CADVertexGeometry {
    static let diameterKey = "cadVertexDiameter"
    static let viewportHeightKey = "cadVertexViewportHeight"
    static let hoverDiameter: CGFloat = 7
    static let selectedDiameter: CGFloat = 9
    static let hoverHaloDiameter: CGFloat = 11
    static let selectedHaloDiameter: CGFloat = 12

    private static let segments = 48
    private static let modifier = """
    #pragma arguments
    float cadVertexDiameter;
    float cadVertexViewportHeight;
    #pragma body
    float4 cadClip = scn_node.modelViewProjectionTransform * _geometry.position;
    if (abs(cadClip.w) > 1e-8) {
        float cadScale = scn_frame.viewportSize.y / max(cadVertexViewportHeight, 1.0);
        cadClip.xy += _geometry.texcoords[0] * cadVertexDiameter * cadScale * scn_frame.inverseResolution * cadClip.w;
        // SceneKit's Metal renderer uses reverse Z. Match CAD edge bias while
        // retaining occlusion by surfaces nearer than the source vertex.
        cadClip.z += 2e-6 * cadClip.w;
        _geometry.position = scn_node.inverseModelViewProjectionTransform * cadClip;
    }
    """

    static func make(_ position: [Double], color: NSColor, diameter: CGFloat, viewportHeight: CGFloat) -> SCNGeometry {
        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        var coordinates = [CGPoint]()
        var indices = [Int32]()
        if position.count == 3, position.allSatisfy({ $0.isFinite && abs($0) < 1e12 }) {
            let center = SCNVector3(position[0], position[1], position[2])
            vertices = Array(repeating: center, count: segments + 1)
            // The unexpanded fan is coincident. Supply finite normals rather
            // than asking SceneKit to infer them from degenerate triangles.
            normals = Array(repeating: SCNVector3(0, 0, 1), count: segments + 1)
            coordinates = [.zero]
            coordinates.reserveCapacity(segments + 1)
            indices.reserveCapacity(segments * 3)
            for index in 0..<segments {
                let angle = Double(index) * 2 * Double.pi / Double(segments)
                coordinates.append(CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle))))
                indices.append(contentsOf: [0, Int32(index + 1), Int32((index + 1) % segments + 1)])
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                             SCNGeometrySource(textureCoordinates: coordinates)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.shaderModifiers = [.geometry: modifier]
        setDiameter(diameter, on: geometry)
        setViewportHeight(viewportHeight, on: geometry)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    static func setDiameter(_ diameter: CGFloat, on geometry: SCNGeometry) {
        geometry.setValue(NSNumber(value: Double(diameter.isFinite ? max(0.1, min(80, diameter)) : hoverDiameter)), forKey: diameterKey)
    }

    static func setViewportHeight(_ height: CGFloat, on geometry: SCNGeometry) {
        geometry.setValue(NSNumber(value: Double(height.isFinite ? max(1, height) : 1)), forKey: viewportHeightKey)
    }

    static func copyParameters(from source: SCNGeometry, to destination: SCNGeometry) {
        guard source.shaderModifiers?[.geometry] == modifier else { return }
        for key in [diameterKey, viewportHeightKey] {
            if let value = source.value(forKey: key) { destination.setValue(value, forKey: key) }
        }
    }
}
