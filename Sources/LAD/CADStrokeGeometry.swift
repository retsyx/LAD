import AppKit
import SceneKit
import simd

/// Metal line primitives are one physical pixel wide. Expand cached indexed
/// quads on the GPU so CAD edges have a stable width in screen points at every
/// camera distance and in both the viewport and independent image renders.
@MainActor
enum CADStrokeGeometry {
    static let viewportHeightKey = "cadEdgeViewportHeight"
    private static let joinsEnabledKey = "cadEdgeJoinsEnabled"
    static let normalWidth: CGFloat = 1.6

    private static let modifier = """
    #pragma arguments
    float cadEdgeViewportHeight;
    float cadEdgeJoinsEnabled;
    #pragma body
    float cadEdgeWidth = \(Float(normalWidth));
    // At a polyline joint the stroke can reach other triangles of its own
    // face. Clip those actual triangles to the local stroke rectangle.
    if (_geometry.texcoords[0].y >= 2.0) {
        if (cadEdgeJoinsEnabled > 0.5) {
            float3 cadFirst = float3(_geometry.texcoords[1], _geometry.texcoords[2].x);
            float3 cadSecond = float3(_geometry.texcoords[2].y, _geometry.texcoords[3]);
            float4 cadA = scn_node.modelViewProjectionTransform * _geometry.position;
            float4 cadB = cadA + scn_node.modelViewProjectionTransform * float4(cadFirst, 0.0);
            float4 cadC = cadA + scn_node.modelViewProjectionTransform * float4(cadSecond, 0.0);
            float4 cadNeighbor = cadA + scn_node.modelViewProjectionTransform
                * float4(_geometry.normal * _geometry.texcoords[0].x, 0.0);
            if (min(min(cadA.w, cadB.w), min(cadC.w, cadNeighbor.w)) > 1e-8) {
                float2 cadViewport = scn_frame.viewportSize.xy * 0.5;
                float3 cadAnchor = cadA.xyz / cadA.w;
                float3 cadU = cadB.xyz / cadB.w;
                float3 cadV = cadC.xyz / cadC.w;
                cadU.xy = (cadU.xy - cadAnchor.xy) * cadViewport;
                cadV.xy = (cadV.xy - cadAnchor.xy) * cadViewport;
                float2 cadStroke = (cadNeighbor.xy / cadNeighbor.w - cadAnchor.xy) * cadViewport;
                float cadLength = length(cadStroke);
                float cadArea = cadU.x * cadV.y - cadU.y * cadV.x;
                if (cadArea > 1e-6 && cadLength > 1e-4) {
                    float cadRadius = 0.5 * cadEdgeWidth * scn_frame.viewportSize.y
                        / max(cadEdgeViewportHeight, 1.0);
                    float2 cadAlong = cadStroke / cadLength;
                    float2 cadAcross = float2(-cadAlong.y, cadAlong.x);
                    float cadLimit = min(cadLength + cadRadius, 4.0 * cadRadius);
                    float3 cadPolygon[7] = {
                        float3(0.0, 0.0, cadAnchor.z),
                        float3(dot(cadU.xy, cadAlong), dot(cadU.xy, cadAcross), cadU.z),
                        float3(dot(cadV.xy, cadAlong), dot(cadV.xy, cadAcross), cadV.z)
                    };
                    // Screen-space depth is affine on the projected plane.
                    // Hardware rasterizes the resulting polygon at the same
                    // MSAA samples as the other strokes and faces.
                    float4 cadLimits = float4(cadRadius, cadLimit, cadRadius, cadRadius);
                    int cadCount = 3;
                    for (int cadSide = 0; cadSide < 4 && cadCount > 0; ++cadSide) {
                        int cadAxis = cadSide / 2;
                        float cadSign = cadSide % 2 == 0 ? 1.0 : -1.0;
                        float cadBound = cadLimits[cadSide];
                        float3 cadClipped[7];
                        int cadNewCount = 0;
                        float3 cadPrevious = cadPolygon[cadCount - 1];
                        float cadPreviousDistance = cadSign * cadPrevious[cadAxis] + cadBound;
                        for (int cadIndex = 0; cadIndex < cadCount; ++cadIndex) {
                            float3 cadCurrent = cadPolygon[cadIndex];
                            float cadDistance = cadSign * cadCurrent[cadAxis] + cadBound;
                            if ((cadPreviousDistance < 0.0 && cadDistance > 0.0)
                                    || (cadPreviousDistance > 0.0 && cadDistance < 0.0)) {
                                float cadT = cadPreviousDistance / (cadPreviousDistance - cadDistance);
                                cadClipped[cadNewCount++] = mix(cadPrevious, cadCurrent, cadT);
                            }
                            if (cadDistance >= 0.0) { cadClipped[cadNewCount++] = cadCurrent; }
                            cadPrevious = cadCurrent;
                            cadPreviousDistance = cadDistance;
                        }
                        cadCount = cadNewCount;
                        for (int cadIndex = 0; cadIndex < cadCount; ++cadIndex) {
                            cadPolygon[cadIndex] = cadClipped[cadIndex];
                        }
                    }
                    if (cadCount >= 3) {
                        int cadCorner = int(_geometry.texcoords[0].y) - 2;
                        float3 cadVertex = cadPolygon[min(cadCorner, cadCount - 1)];
                        float2 cadOffset = cadVertex.x * cadAlong + cadVertex.y * cadAcross;
                        float4 cadClip = float4(cadAnchor.xy + cadOffset / cadViewport, cadVertex.z, 1.0);
                        float4 cadPosition = scn_node.inverseModelViewProjectionTransform * cadClip;
                        if (abs(cadPosition.w) > 1e-8) {
                            cadPosition /= cadPosition.w;
                            cadClip = scn_node.modelViewProjectionTransform * cadPosition;
                            float4 cadViewPosition = scn_node.modelViewTransform * cadPosition;
                            float cadDepthGradient = (scn_frame.projectionTransform[2][2] * cadClip.w
                                - scn_frame.projectionTransform[2][3] * cadClip.z) / cadClip.w;
                            cadClip.z += 2e-6 * abs(cadViewPosition.z) * cadDepthGradient;
                            _geometry.position = scn_node.inverseModelViewProjectionTransform * cadClip;
                        }
                    }
                }
            }
        }
    } else {
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
            float cadFallback = _geometry.texcoords[0].y * cadBoundedCapDepth;
            float cadDepthOffset = cadFallback;
            // Match the actual adjacent triangle planes across the complete width
            // too. Keeping a wide ribbon at centerline depth lets curved faces
            // cut repeated teeth into its inner edge. These cached planes use the
            // geometric mesh normals, rather than smoothed lighting normals.
            float3 cadSurfaceNormals[2] = {
                float3(_geometry.texcoords[1], _geometry.texcoords[2].x),
                float3(_geometry.texcoords[2].y, _geometry.texcoords[3])
            };
            bool cadIsCrease = dot(cadSurfaceNormals[0], cadSurfaceNormals[0]) >= 0.5
                && dot(cadSurfaceNormals[1], cadSurfaceNormals[1]) >= 0.5;
            float3 cadEye = scn_frame.projectionTransform[3][3] == 0.0
                ? normalize(-cadViewPosition.xyz) : float3(0.0, 0.0, 1.0);
            bool cadHasSurface = false;
            bool cadHasFrontFace = false;
            for (int cadFace = 0; cadFace < 2; ++cadFace) {
                float3 cadNormal = cadSurfaceNormals[cadFace];
                if (dot(cadNormal, cadNormal) < 0.5) { continue; }
                float3 cadViewNormal = normalize((scn_node.normalTransform * float4(cadNormal, 0.0)).xyz);
                // Either winding gives the same plane depth. At a contact rim
                // the cylinder's underside supplies the plane on the plate side.
                float cadIncidence = dot(cadViewNormal, cadEye);
                cadHasFrontFace = cadHasFrontFace || cadIncidence > 0.0;
                // Bound the depth change near edge-on planes to eight times
                // the ribbon's view-space footprint.
                float cadFacing = abs(cadIncidence);
                if (cadFacing < 0.125) { continue; }
                float4 cadPlane = float4(cadNormal, -dot(cadNormal, _geometry.position.xyz));
                float4 cadClipPlane = transpose(scn_node.inverseModelViewProjectionTransform) * cadPlane;
                if (abs(cadClipPlane.z) < 1e-5 * length(cadClipPlane.xyz)) { continue; }
                float2 cadDepthSlope = -cadClipPlane.xy / cadClipPlane.z;
                float cadSurfaceDepth = dot(cadDepthSlope, cadClipOffset);
                if (cadIsCrease) {
                    // A crease's two half-ribbons rasterize independently of the
                    // faces they lie on. Convert 1/128 of a physical pixel of XY
                    // rounding into depth (zero for a screen-parallel plane).
                    float cadRoundingDepth = dot(abs(cadDepthSlope), scn_frame.inverseResolution)
                        * (2.0 / 128.0) * abs(cadClip.w);
                    cadSurfaceDepth += copysign(cadRoundingDepth, cadCapDepthGradient);
                }
                if (isfinite(cadSurfaceDepth)) {
                    // Ease back to the conservative centerline at silhouettes;
                    // switching the full correction on abruptly makes a notch.
                    float cadWeight = smoothstep(0.125, 0.25, cadFacing);
                    cadSurfaceDepth = mix(cadFallback, cadSurfaceDepth, cadWeight);
                    cadDepthOffset = cadHasSurface ? max(cadDepthOffset, cadSurfaceDepth) : cadSurfaceDepth;
                    cadHasSurface = true;
                }
            }
            cadClip.z += cadHasFrontFace ? cadDepthOffset : cadFallback;
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
    nonisolated static func prepare(points: [Float], segments: [Int], surfaces: [CADStrokeSurface]? = nil,
                                    joins: [CADStrokeSurface.Join] = []) throws -> Prepared {
        try Task.checkCancellation()
        // Keep finite, nondegenerate segments first, so each attribute buffer is
        // allocated once at its final size and written in place.
        func endpoints(_ segment: Int) -> (SIMD3<Double>, SIMD3<Double>)? {
            guard segment >= 0, segment < points.count / 6 else { return nil }
            let base = segment * 6
            let a = SIMD3<Double>(Double(points[base]), Double(points[base + 1]), Double(points[base + 2]))
            let b = SIMD3<Double>(Double(points[base + 3]), Double(points[base + 4]), Double(points[base + 5]))
            func valid(_ point: SIMD3<Double>) -> Bool {
                point.x.isFinite && point.y.isFinite && point.z.isFinite && abs(point.x) < 1e12 && abs(point.y) < 1e12 && abs(point.z) < 1e12
            }
            guard valid(a), valid(b), simd_length_squared(b - a) > 1e-24 else { return nil }
            return (a, b)
        }
        struct Ribbon {
            let start, end, direction: SIMD3<Float>
            let firstNormal, secondNormal: SIMD3<Float>

            // Two adjacent planes can have different screen-depth slopes.
            // Give the two half-widths a shared vertex at the actual edge depth.
            var columns: Int { firstNormal != .zero && secondNormal != .zero ? 3 : 2 }
        }
        func finiteNormal(_ normal: SIMD3<Double>) -> SIMD3<Float> {
            let lengthSquared = simd_length_squared(normal)
            guard lengthSquared.isFinite, lengthSquared > 1e-20 else { return .zero }
            return SIMD3<Float>(simd_normalize(normal))
        }
        var ribbons = [Ribbon]()
        ribbons.reserveCapacity(segments.count)
        var vertexCount = 0, indexCount = 0
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let (a, b) = endpoints(segment) else { continue }
            let surface = surfaces.flatMap { $0.indices.contains(segment) ? $0[segment] : nil } ?? CADStrokeSurface()
            let ribbon = Ribbon(start: SIMD3<Float>(a), end: SIMD3<Float>(b),
                                direction: SIMD3<Float>(simd_normalize(b - a)),
                                firstNormal: finiteNormal(surface.first), secondNormal: finiteNormal(surface.second))
            guard vertexCount <= Int(Int32.max) - 2 * ribbon.columns else { break }
            ribbons.append(ribbon)
            vertexCount += 2 * ribbon.columns
            indexCount += 6 * (ribbon.columns - 1)
        }

        struct JoinPatch {
            let origin, first, second, direction: SIMD3<Float>
            let length: Float
        }
        var patches = [JoinPatch]()
        patches.reserveCapacity(joins.count)
        for (index, join) in joins.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let displacement = join.neighbor - join.origin
            let length = simd_length(displacement)
            guard length.isFinite, length > 1e-10, vertexCount <= Int(Int32.max) - 7 else { continue }
            patches.append(JoinPatch(origin: join.origin, first: join.first - join.origin,
                                     second: join.second - join.origin, direction: displacement / length,
                                     length: length))
            vertexCount += 7
            indexCount += 15
        }

        func attribute<V: SIMD>(_ value: (Ribbon, Int, Int) -> V,
                                join: (JoinPatch, Int) -> V) throws -> Data where V.Scalar == Float {
            try packed(count: vertexCount * V.scalarCount) { (buffer: UnsafeMutableBufferPointer<Float>) in
                var offset = 0
                for (index, ribbon) in ribbons.enumerated() {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    for endpoint in 0..<2 {
                        for column in 0..<ribbon.columns {
                            let vector = value(ribbon, endpoint, column)
                            for component in 0..<V.scalarCount {
                                buffer[offset] = vector[component]
                                offset += 1
                            }
                        }
                    }
                }
                for (index, patch) in patches.enumerated() {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    for corner in 0..<7 {
                        let vector = join(patch, corner)
                        for component in 0..<V.scalarCount {
                            buffer[offset] = vector[component]
                            offset += 1
                        }
                    }
                }
            }
        }
        let vertices = try attribute({ ribbon, endpoint, _ in endpoint == 0 ? ribbon.start : ribbon.end },
                                     join: { patch, _ in patch.origin })
        let directions = try attribute({ ribbon, _, _ in ribbon.direction },
                                        join: { patch, _ in patch.direction })
        let coordinates = try attribute({ ribbon, endpoint, column in
            let across = 2 * Float(column) / Float(ribbon.columns - 1) - 1
            return SIMD2<Float>(across, endpoint == 0 ? -1 : 1)
        }, join: { patch, corner in SIMD2(patch.length, Float(corner + 2)) })
        let firstNormalXY = try attribute({ ribbon, _, _ in SIMD2(ribbon.firstNormal.x, ribbon.firstNormal.y) },
                                          join: { patch, _ in SIMD2(patch.first.x, patch.first.y) })
        let middleNormals = try attribute({ ribbon, _, _ in SIMD2(ribbon.firstNormal.z, ribbon.secondNormal.x) },
                                          join: { patch, _ in SIMD2(patch.first.z, patch.second.x) })
        let secondNormalYZ = try attribute({ ribbon, _, _ in SIMD2(ribbon.secondNormal.y, ribbon.secondNormal.z) },
                                           join: { patch, _ in SIMD2(patch.second.y, patch.second.z) })
        let indices: Data = try packed(count: indexCount) { (buffer: UnsafeMutableBufferPointer<Int32>) in
            var first: Int32 = 0, offset = 0
            for (index, ribbon) in ribbons.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                for column in 0..<(ribbon.columns - 1) {
                    let a = first + Int32(column), b = a + Int32(ribbon.columns)
                    buffer[offset] = a; buffer[offset + 1] = a + 1; buffer[offset + 2] = b
                    buffer[offset + 3] = b; buffer[offset + 4] = a + 1; buffer[offset + 5] = b + 1
                    offset += 6
                }
                first += Int32(2 * ribbon.columns)
            }
            for index in patches.indices {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                for corner in 1..<6 {
                    buffer[offset] = first
                    buffer[offset + 1] = first + Int32(corner)
                    buffer[offset + 2] = first + Int32(corner + 1)
                    offset += 3
                }
                first += 7
            }
        }
        try Task.checkCancellation()
        return Prepared(vertices: vertices, directions: directions, coordinates: coordinates,
                        firstNormalXY: firstNormalXY, middleNormals: middleNormals, secondNormalYZ: secondNormalYZ,
                        indices: indices, vertexCount: vertexCount, indexCount: indexCount)
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
        setJoinsEnabled(true, on: geometry)
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

    static func setJoinsEnabled(_ enabled: Bool, on geometry: SCNGeometry) {
        geometry.setValue(NSNumber(value: enabled ? 1.0 : 0.0), forKey: joinsEnabledKey)
    }

    static func copyParameters(from source: SCNGeometry, to destination: SCNGeometry) {
        guard source.shaderModifiers?[.geometry] == modifier else { return }
        for key in [viewportHeightKey, joinsEnabledKey] {
            if let value = source.value(forKey: key) { destination.setValue(value, forKey: key) }
        }
    }
}
