import AppKit
import SceneKit
import simd

/// Metal line primitives are one physical pixel wide. Expand cached indexed
/// quads on the GPU so CAD edges have a stable width in screen points at every
/// camera distance and in both the viewport and independent image renders.
@MainActor
enum CADStrokeGeometry {
    static let viewportHeightKey = "cadEdgeViewportHeight"
    static let normalWidth: CGFloat = 1.6

    private static let modifier = """
    #pragma arguments
    float cadEdgeViewportHeight;
    #pragma body
    float cadEdgeWidth = \(Float(normalWidth));
    float4 cadViewPosition = scn_node.modelViewTransform * _geometry.position;
    float4 cadClip = scn_node.modelViewProjectionTransform * _geometry.position;
    float4 cadDirection = scn_node.modelViewProjectionTransform * float4(_geometry.normal, 0.0);
    float2 cadPixels = (cadDirection.xy * cadClip.w - cadClip.xy * cadDirection.w) * scn_frame.viewportSize.xy;
    float cadLengthSquared = dot(cadPixels, cadPixels);
    if (cadLengthSquared > 1e-18 && abs(cadClip.w) > 1e-8) {
        float2 cadAlong = cadPixels * rsqrt(cadLengthSquared);
        float2 cadAcross = float2(-cadAlong.y, cadAlong.x);
        float cadScale = scn_frame.viewportSize.y / max(cadEdgeViewportHeight, 1.0);
        // Square caps extend the endpoint along the projected edge. Extend
        // its depth by the same tangent, otherwise every curved-edge joint
        // cuts into the surface and leaves a tooth in the expanded stroke.
        float cadDepthTangent = (cadDirection.z * cadClip.w - cadClip.z * cadDirection.w) * rsqrt(cadLengthSquared);
        float cadCapDepth = cadEdgeWidth * cadScale * cadDepthTangent * cadClip.w;
        // A nearly view-aligned edge has an unbounded depth tangent. Shrink
        // the cap along that same tangent before it can project hidden edges
        // through a solid face. Bound it to eight times its view-space width,
        // matching the adjacent-plane slope limit below. Retain the full
        // across-edge width and the cap's actual depth direction.
        float cadCapDepthGradient = (scn_frame.projectionTransform[2][2] * cadClip.w
            - scn_frame.projectionTransform[2][3] * cadClip.z) / cadClip.w;
        float cadCapFootprint = abs(cadClip.w) * cadEdgeWidth * cadScale * scn_frame.inverseResolution.y
            / max(abs(scn_frame.projectionTransform[1][1]), 1e-8);
        float cadCapDepthLimit = 8.0 * cadCapFootprint * abs(cadCapDepthGradient);
        float cadCapWeight = abs(cadCapDepth) > cadCapDepthLimit
            ? cadCapDepthLimit / abs(cadCapDepth) : 1.0;
        float cadBoundedCapDepth = clamp(cadCapDepth, -cadCapDepthLimit, cadCapDepthLimit);
        float cadCap = _geometry.texcoords[0].y * cadCapWeight;
        float2 cadOffset = cadAcross * _geometry.texcoords[0].x + cadAlong * cadCap;
        float2 cadClipOffset = cadOffset * cadEdgeWidth * cadScale * scn_frame.inverseResolution * cadClip.w;
        float cadDepthOffset = _geometry.texcoords[0].y * cadBoundedCapDepth;
        // Match the actual adjacent triangle planes across the complete width
        // too. Keeping a wide ribbon at centerline depth lets curved faces
        // cut repeated teeth into its inner edge. These cached planes use the
        // geometric mesh normals, rather than smoothed lighting normals.
        float3 cadSurfaceNormals[2] = {
            float3(_geometry.texcoords[1], _geometry.texcoords[2].x),
            float3(_geometry.texcoords[2].y, _geometry.texcoords[3])
        };
        float3 cadEye = scn_frame.projectionTransform[3][3] == 0.0
            ? normalize(-cadViewPosition.xyz) : float3(0.0, 0.0, 1.0);
        bool cadHasSurface = false;
        for (int cadFace = 0; cadFace < 2; ++cadFace) {
            float3 cadNormal = cadSurfaceNormals[cadFace];
            if (dot(cadNormal, cadNormal) < 0.5) { continue; }
            float3 cadViewNormal = normalize((scn_node.normalTransform * float4(cadNormal, 0.0)).xyz);
            // An edge-on plane has an unbounded screen-depth slope. Use its
            // other visible neighbor or the tangent fallback at silhouettes.
            // This also bounds the local depth slope to about eight times
            // the ribbon's view-space footprint, independent of scene units.
            float cadFacing = dot(cadViewNormal, cadEye);
            if (cadFacing < 0.125) { continue; }
            float4 cadPlane = float4(cadNormal, -dot(cadNormal, _geometry.position.xyz));
            float4 cadClipPlane = transpose(scn_node.inverseModelViewProjectionTransform) * cadPlane;
            if (abs(cadClipPlane.z) < 1e-5 * length(cadClipPlane.xyz)) { continue; }
            float cadSurfaceDepth = -dot(cadClipPlane.xy, cadClipOffset) / cadClipPlane.z;
            if (isfinite(cadSurfaceDepth)) {
                // Ease back to the conservative centerline at silhouettes;
                // switching the full correction on abruptly makes a notch.
                float cadWeight = smoothstep(0.125, 0.25, cadFacing);
                float cadFallback = _geometry.texcoords[0].y * cadBoundedCapDepth;
                cadSurfaceDepth = mix(cadFallback, cadSurfaceDepth, cadWeight);
                cadDepthOffset = cadHasSurface ? max(cadDepthOffset, cadSurfaceDepth) : cadSurfaceDepth;
                cadHasSurface = true;
            }
        }
        cadClip.z += cadDepthOffset;
        cadClip.xy += cadClipOffset;
        // Bound the precision allowance in view space. A constant normalized
        // depth offset grows quadratically with distance under reverse-Z
        // perspective and can pull hidden edges through a smooth front face.
        // Convert a small relative view-depth allowance through the projection
        // derivative, retaining the projection's actual depth direction.
        float cadDepthGradient = (scn_frame.projectionTransform[2][2] * cadClip.w
            - scn_frame.projectionTransform[2][3] * cadClip.z) / cadClip.w;
        cadClip.z += 2e-6 * abs(cadViewPosition.z) * cadDepthGradient;
        _geometry.position = scn_node.inverseModelViewProjectionTransform * cadClip;
    }
    """

    /// CPU buffers cross the preparation boundary without any SceneKit or
    /// AppKit objects. Float components match SceneKit's uploaded attributes;
    /// positions, directions and surface normals are still calculated in Double.
    struct Prepared: Sendable {
        let vertices: Data
        let directions: Data
        let coordinates: Data
        let firstNormalXY: Data
        let middleNormals: Data
        let secondNormalYZ: Data
        let indices: Data
        let vertexCount: Int
        let indexCount: Int
    }

    /// `segments` are indices into `points`, which holds six Float32 values
    /// (start xyz, end xyz) per segment. `surfaces`, when present, is indexed
    /// by the same segment indices.
    nonisolated static func prepare(points: [Float], segments: [Int], surfaces: [CADStrokeSurface]? = nil) throws -> Prepared {
        try Task.checkCancellation()
        // Keep finite, nondegenerate segments first, so each attribute buffer is
        // allocated once at its final size and written in place.
        func endpoints(_ segment: Int) -> (SIMD3<Double>, SIMD3<Double>)? {
            let base = segment * 6
            guard segment >= 0, base + 6 <= points.count else { return nil }
            let a = SIMD3<Double>(Double(points[base]), Double(points[base + 1]), Double(points[base + 2]))
            let b = SIMD3<Double>(Double(points[base + 3]), Double(points[base + 4]), Double(points[base + 5]))
            func valid(_ point: SIMD3<Double>) -> Bool {
                point.x.isFinite && point.y.isFinite && point.z.isFinite && abs(point.x) < 1e12 && abs(point.y) < 1e12 && abs(point.z) < 1e12
            }
            guard valid(a), valid(b), simd_length_squared(b - a) > 1e-24 else { return nil }
            return (a, b)
        }
        var accepted = [Int]()
        accepted.reserveCapacity(segments.count)
        for (position, segment) in segments.enumerated() {
            if position.isMultiple(of: 256) { try Task.checkCancellation() }
            guard accepted.count < (Int(Int32.max) - 4) / 4, endpoints(segment) != nil else { continue }
            accepted.append(segment)
        }
        func finiteNormal(_ normal: SIMD3<Double>) -> SIMD3<Double> {
            guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite,
                  simd_length_squared(normal) > 1e-20, simd_length_squared(normal).isFinite else { return .zero }
            return simd_normalize(normal)
        }
        func surface(_ segment: Int) -> (SIMD3<Double>, SIMD3<Double>) {
            let value = surfaces.flatMap { $0.indices.contains(segment) ? $0[segment] : nil } ?? CADStrokeSurface()
            return (finiteNormal(value.first), finiteNormal(value.second))
        }
        // Four ribbon corners per segment: start twice, then end twice.
        func perCorner3(_ value: (Int, Int) -> SIMD3<Float>) throws -> Data {
            try packed(count: accepted.count * 12) { (buffer: UnsafeMutableBufferPointer<Float>) in
                for (index, segment) in accepted.enumerated() {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    for corner in 0..<4 {
                        let item = value(segment, corner), base = (index * 4 + corner) * 3
                        buffer[base] = item.x; buffer[base + 1] = item.y; buffer[base + 2] = item.z
                    }
                }
            }
        }
        func perCorner2(_ value: (Int, Int) -> SIMD2<Float>) throws -> Data {
            try packed(count: accepted.count * 8) { (buffer: UnsafeMutableBufferPointer<Float>) in
                for (index, segment) in accepted.enumerated() {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    for corner in 0..<4 {
                        let item = value(segment, corner), base = (index * 4 + corner) * 2
                        buffer[base] = item.x; buffer[base + 1] = item.y
                    }
                }
            }
        }
        let vertices = try perCorner3 { segment, corner in
            let (a, b) = endpoints(segment)!
            return SIMD3<Float>(corner < 2 ? a : b)
        }
        // Direction, rather than a second point, remains valid if SceneKit
        // normalizes this attribute before the geometry entry point.
        let directions = try perCorner3 { segment, _ in
            let (a, b) = endpoints(segment)!
            return SIMD3<Float>(simd_normalize(b - a))
        }
        let coordinates = try perCorner2 { _, corner in SIMD2(corner.isMultiple(of: 2) ? -1 : 1, corner < 2 ? -1 : 1) }
        let firstNormalXY = try perCorner2 { segment, _ in
            let (n0, _) = surface(segment)
            return SIMD2(Float(n0.x), Float(n0.y))
        }
        let middleNormals = try perCorner2 { segment, _ in
            let (n0, n1) = surface(segment)
            return SIMD2(Float(n0.z), Float(n1.x))
        }
        let secondNormalYZ = try perCorner2 { segment, _ in
            let (_, n1) = surface(segment)
            return SIMD2(Float(n1.y), Float(n1.z))
        }
        let indices: Data = try packed(count: accepted.count * 6) { (buffer: UnsafeMutableBufferPointer<Int32>) in
            for index in accepted.indices {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let first = Int32(index * 4), base = index * 6
                buffer[base] = first; buffer[base + 1] = first + 1; buffer[base + 2] = first + 2
                buffer[base + 3] = first + 2; buffer[base + 4] = first + 1; buffer[base + 5] = first + 3
            }
        }
        try Task.checkCancellation()
        return Prepared(vertices: vertices, directions: directions, coordinates: coordinates,
                        firstNormalXY: firstNormalXY, middleNormals: middleNormals, secondNormalYZ: secondNormalYZ,
                        indices: indices, vertexCount: accepted.count * 4, indexCount: accepted.count * 6)
    }

    nonisolated private static func packed<T>(count: Int, _ fill: (UnsafeMutableBufferPointer<T>) throws -> Void) rethrows -> Data {
        var data = Data(count: count * MemoryLayout<T>.stride)
        try data.withUnsafeMutableBytes { raw in try fill(raw.bindMemory(to: T.self)) }
        return data
    }

    static func make(_ prepared: Prepared, color: NSColor, viewportHeight: CGFloat) -> SCNGeometry {
        func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: semantic, vectorCount: prepared.vertexCount,
                              usesFloatComponents: true, componentsPerVector: components,
                              bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                              dataStride: components * MemoryLayout<Float>.size)
        }
        let geometry = SCNGeometry(sources: [source(prepared.vertices, .vertex, components: 3),
                                             source(prepared.directions, .normal, components: 3),
                                             source(prepared.coordinates, .texcoord, components: 2),
                                             source(prepared.firstNormalXY, .texcoord, components: 2),
                                             source(prepared.middleNormals, .texcoord, components: 2),
                                             source(prepared.secondNormalYZ, .texcoord, components: 2)],
                                   elements: [SCNGeometryElement(data: prepared.indices, primitiveType: .triangles,
                                                                 primitiveCount: prepared.indexCount / 3,
                                                                 bytesPerIndex: MemoryLayout<Int32>.size)])
        geometry.shaderModifiers = [.geometry: modifier]
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

    static func setViewportHeight(_ height: CGFloat, on geometry: SCNGeometry) {
        geometry.setValue(NSNumber(value: Double(height.isFinite ? max(1, height) : 1)), forKey: viewportHeightKey)
    }

    static func copyParameters(from source: SCNGeometry, to destination: SCNGeometry) {
        guard source.shaderModifiers?[.geometry] == modifier else { return }
        if let value = source.value(forKey: viewportHeightKey) { destination.setValue(value, forKey: viewportHeightKey) }
    }
}
