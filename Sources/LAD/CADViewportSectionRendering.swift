import AppKit
import SceneKit
import simd

@MainActor
enum CADViewportSectionRendering {
    private static let planeKey = "cadSectionPlane"
    private static let hatchAxisKey = "cadSectionHatchAxis"
    private static let clipping = """
    #pragma arguments
    float4 cadSectionPlane;
    #pragma body
    float4 cadWorldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    if (dot(cadSectionPlane, cadWorldPosition) > 0.0) {
        discard_fragment();
    }
    """

    private static let hatching = """
    #pragma arguments
    float4 cadSectionHatchAxis;
    #pragma body
    float4 cadWorldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float cadBand = dot(cadSectionHatchAxis, cadWorldPosition);
    float cadPhase = abs(fract(cadBand) - 0.5);
    float cadFeather = max(fwidth(cadBand), 0.01);
    float cadHatch = 1.0 - smoothstep(0.067, 0.067 + cadFeather, cadPhase);
    _output.color.rgb *= 1.0 - 0.50 * cadHatch * (1.0 - smoothstep(0.1, 0.6, cadFeather));
    """

    static func apply(_ plane: CADSectionPlane?, to material: SCNMaterial) {
        var modifiers = material.shaderModifiers ?? [:]
        if let plane {
            if modifiers[.surface] != clipping {
                modifiers[.surface] = clipping
                material.shaderModifiers = modifiers
            }
            bind(plane.equation, to: material, key: planeKey)
        } else if modifiers[.surface] == clipping {
            modifiers.removeValue(forKey: .surface)
            material.shaderModifiers = modifiers.isEmpty ? nil : modifiers
        }
    }

    static func hatch(_ axis: SIMD4<Float>, on material: SCNMaterial) {
        material.shaderModifiers = [.fragment: hatching]
        bind(axis, to: material, key: hatchAxisKey)
    }

    static func copyParameters(from source: SCNMaterial, to destination: SCNMaterial) {
        let modifiers = source.shaderModifiers
        if modifiers?[.surface] == clipping, let value = source.value(forKey: planeKey) {
            destination.setValue(value, forKey: planeKey)
        }
        if modifiers?[.fragment] == hatching, let value = source.value(forKey: hatchAxisKey) {
            destination.setValue(value, forKey: hatchAxisKey)
        }
    }

    private static func bind(_ value: SIMD4<Float>, to material: SCNMaterial, key: String) {
        material.setValue(NSValue(scnVector4: SCNVector4(value.x, value.y, value.z, value.w)), forKey: key)
    }
}

/// Visual section caps use the same display triangles as the clipped scene.
/// CPU tessellation is cancellable and the renderer prepares its own buffers
/// before the matching cap replaces the pending one.
@MainActor
final class CADViewportSectionCaps {
    let node = SCNNode()
    private var task: Task<Void, Never>?
    private var updateID = UUID()
    var isPreparing: Bool { task != nil }

    init() { node.categoryBitMask = CADViewportCategory.sectionCaps }

    deinit { task?.cancel() }

    func update(plane: CADSectionPlane?, mesh: CADViewportPreparedMesh?, transforms: [Int: simd_double4x4],
                hidden: Set<Int>, mode: ViewportDisplayMode, renderer: SCNRenderer?, redraw: @escaping @MainActor () -> Void) {
        task?.cancel()
        let id = UUID()
        updateID = id
        node.geometry = nil
        task = nil
        guard let plane, let mesh else { return }

        let wire = mode == .wireframe
        let worker = Task.detached(priority: .userInitiated) {
            try CADSectionCapMesh(mesh: mesh, plane: plane, transforms: transforms, hidden: hidden, wire: wire)
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler { try? await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, self?.updateID == id else { return }
            let geometry: SCNGeometry? = result.flatMap {
                $0.positions.isEmpty ? nil : Self.geometry($0, wire: wire)
            }
            let ready: Bool
            if let geometry, let renderer {
                ready = await withCheckedContinuation { continuation in
                    renderer.prepare([geometry]) { continuation.resume(returning: $0) }
                }
            } else {
                ready = geometry != nil
            }
            guard !Task.isCancelled, let self, self.updateID == id else { return }
            if ready { self.node.geometry = geometry }
            self.task = nil
            redraw()
        }
    }

    private static func geometry(_ cap: CADSectionCapMesh, wire: Bool) -> SCNGeometry {
        let positions = cap.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let indices = Array(UInt32(0)..<UInt32(cap.positions.count)).withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indices, primitiveType: wire ? .line : .triangles,
                                         primitiveCount: cap.positions.count / (wire ? 2 : 3),
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        let vertices = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: cap.positions.count,
                                        usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                        dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let geometry = SCNGeometry(sources: [vertices], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(srgbRed: 0.59, green: 0.61, blue: 0.64, alpha: 1)
        material.isDoubleSided = true
        material.readsFromDepthBuffer = !wire
        material.writesToDepthBuffer = !wire
        if !wire { CADViewportSectionRendering.hatch(cap.hatchAxis, on: material) }
        geometry.materials = [material]
        return geometry
    }
}

struct CADSectionCapMesh: Sendable {
    private(set) var positions = [SIMD3<Float>]()
    let hatchAxis: SIMD4<Float>

    private struct Segment {
        let start: SIMD2<Double>
        let end: SIMD2<Double>

        var minY: Double { min(start.y, end.y) }
        var maxY: Double { max(start.y, end.y) }

        func x(at y: Double) -> Double {
            start.x + (end.x - start.x) * ((y - start.y) / (end.y - start.y))
        }
    }

    /// The cap plane sees each solid independently. Pairing intersections
    /// across each slab fills material by odd/even coverage, including
    /// concave sections, separate islands and holes in one solid.
    init(mesh: CADViewportPreparedMesh, plane: CADSectionPlane,
         transforms: [Int: simd_double4x4], hidden: Set<Int>, wire: Bool) throws {
        let span = Self.span(mesh.mesh.bounds)
        let spacing = max(span / 55, 1e-7)
        let axis = (plane.horizontal + plane.vertical) / spacing
        hatchAxis = SIMD4(SIMD3<Float>(axis), Float(-simd_dot(axis, plane.origin)))
        let coordinateTolerance = max(1e-12, span * 1e-10)
        let maximumVertices = 600_000
        func snap(_ value: Double) -> Double {
            (value / coordinateTolerance).rounded() * coordinateTolerance
        }
        let worldPlane = SIMD4(plane.normal, -simd_dot(plane.normal, plane.origin))
        // Plane coordinates are centered near the geometry to preserve precision.
        let worldHorizontal = SIMD4(plane.horizontal, -simd_dot(plane.horizontal, plane.origin))
        let worldVertical = SIMD4(plane.vertical, -simd_dot(plane.vertical, plane.origin))

        for (solid, indices) in mesh.groups.sorted(by: { $0.key < $1.key }) where !hidden.contains(solid) {
            try Task.checkCancellation()
            let transform = simd_transpose(transforms[solid] ?? matrix_identity_double4x4)
            let localPlane = transform * worldPlane
            if let bounds = mesh.solidBounds[solid], !Self.intersects(bounds, plane: localPlane) { continue }
            let horizontal = transform * worldHorizontal
            let vertical = transform * worldVertical
            func project(_ p: SIMD4<Double>) -> SIMD2<Double> {
                SIMD2(snap(simd_dot(horizontal, p)), snap(simd_dot(vertical, p)))
            }
            func vertex(_ i: Int) -> SIMD4<Double> {
                SIMD4(SIMD3<Double>(mesh.mesh.position(Int(indices[i]))), 1)
            }
            func crossing(_ a: SIMD4<Double>, _ da: Double, _ b: SIMD4<Double>, _ db: Double) -> SIMD2<Double>? {
                // Always interpolate in retained-to-removed order so the
                // shared edge of adjacent triangles rounds identically.
                if da <= 0, db > 0 { return project(a + da / (da - db) * (b - a)) }
                if db <= 0, da > 0 { return project(b + db / (db - da) * (a - b)) }
                return nil
            }
            var segments = [Segment]()
            var retained = false
            for index in stride(from: 0, to: indices.count, by: 3) {
                if index.isMultiple(of: 768) { try Task.checkCancellation() }
                let a = vertex(index), b = vertex(index + 1), c = vertex(index + 2)
                let da = simd_dot(localPlane, a), db = simd_dot(localPlane, b), dc = simd_dot(localPlane, c)
                retained = retained || min(da, db, dc) < 0
                guard min(da, db, dc) <= 0, max(da, db, dc) > 0 else { continue }
                if let start = crossing(a, da, b, db) {
                    guard let end = crossing(b, db, c, dc) ?? crossing(c, dc, a, da), start != end else { continue }
                    segments.append(Segment(start: start, end: end))
                } else if let start = crossing(b, db, c, dc), let end = crossing(c, dc, a, da), start != end {
                    segments.append(Segment(start: start, end: end))
                }
            }
            guard retained else { continue }

            if wire {
                for (index, segment) in segments.enumerated() {
                    if index.isMultiple(of: 768) { try Task.checkCancellation() }
                    guard positions.count + 2 <= maximumVertices else { return }
                    append(segment.start, in: plane)
                    append(segment.end, in: plane)
                }
                continue
            }
            let sides = segments.filter { $0.minY < $0.maxY }.sorted { $0.minY < $1.minY }
            let ordinates = Set(sides.flatMap { [$0.minY, $0.maxY] }).sorted()
            var active = [Segment]()
            var start = 0
            let solidStart = positions.count
            var exceededBudget = false
            for (index, y) in ordinates.dropLast().enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                let topY = ordinates[index + 1]
                active.removeAll { $0.maxY <= y }
                while start < sides.count, sides[start].minY <= y {
                    active.append(sides[start])
                    start += 1
                }
                // An incomplete contour (for example an open synthetic
                // preview) should never close over a cavity by guessing.
                guard active.count.isMultiple(of: 2) else { continue }
                let midY = (y + topY) * 0.5
                let crossed = active.map { (x: $0.x(at: midY), edge: $0) }.sorted { $0.x < $1.x }
                for index in stride(from: 0, to: crossed.count, by: 2) {
                    let left = crossed[index], right = crossed[index + 1]
                    guard right.x - left.x > coordinateTolerance else { continue }
                    guard positions.count + 6 <= maximumVertices else { exceededBudget = true; break }
                    let a = SIMD2(left.edge.x(at: y), y), b = SIMD2(right.edge.x(at: y), y)
                    let c = SIMD2(right.edge.x(at: topY), topY), d = SIMD2(left.edge.x(at: topY), topY)
                    for point in [a, b, c, a, c, d] { append(point, in: plane) }
                }
                if exceededBudget { break }
            }
            if exceededBudget {
                positions.removeSubrange(solidStart...)
                return
            }
        }
    }

    private mutating func append(_ uv: SIMD2<Double>, in plane: CADSectionPlane) {
        positions.append(SIMD3<Float>(plane.origin + uv.x * plane.horizontal + uv.y * plane.vertical))
    }

    private static func span(_ bounds: [Double]) -> Double {
        guard bounds.count == 6 else { return 1 }
        return simd_length(SIMD3(bounds[3] - bounds[0], bounds[4] - bounds[1], bounds[5] - bounds[2]))
    }

    private static func intersects(_ bounds: [Double], plane: SIMD4<Double>) -> Bool {
        var minimum = plane.w
        var maximum = plane.w
        for axis in 0..<3 {
            let low = plane[axis] * bounds[axis], high = plane[axis] * bounds[axis + 3]
            minimum += min(low, high)
            maximum += max(low, high)
        }
        return minimum < 0 && maximum > 0
    }
}
