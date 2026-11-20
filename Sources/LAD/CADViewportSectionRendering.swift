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
    // A face that seeds the cut lies on its boundary. Allow roundoff from
    // reconstructing the world position as well as from the plane equation.
    float3 cadScale = abs(cadWorldPosition.xyz) + abs(_surface.position);
    float cadMagnitude = max(max(cadScale.x, cadScale.y), max(cadScale.z, abs(cadSectionPlane.w)));
    if (dot(cadSectionPlane, cadWorldPosition) > \(CADSectionPlane.renderRoundoff) * max(1.0, cadMagnitude)) {
        discard_fragment();
    }
    """

    private static let hatchPattern = """
    #pragma arguments
    float4 cadSectionHatchAxis;
    #pragma body
    float4 cadWorldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float cadBand = dot(cadSectionHatchAxis, cadWorldPosition);
    float cadPhase = abs(fract(cadBand) - 0.5);
    float cadFeather = max(fwidth(cadBand), 0.01);
    float cadHatch = 1.0 - smoothstep(0.067, 0.067 + cadFeather, cadPhase);

    """
    private static let hatching = hatchPattern
        + "_output.color.rgb *= 1.0 - 0.50 * cadHatch * (1.0 - smoothstep(0.1, 0.6, cadFeather));"
    private static let hatchLines = hatchPattern
        + "if (cadHatch < 0.5 && cadFeather < 0.6) { discard_fragment(); }"

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

    static func hatch(_ axis: SIMD4<Float>, on material: SCNMaterial, linesOnly: Bool = false) {
        material.shaderModifiers = [.fragment: linesOnly ? hatchLines : hatching]
        bind(axis, to: material, key: hatchAxisKey)
    }

    static func copyParameters(from source: SCNMaterial, to destination: SCNMaterial) {
        let modifiers = source.shaderModifiers
        if modifiers?[.surface] == clipping, let value = source.value(forKey: planeKey) {
            destination.setValue(value, forKey: planeKey)
        }
        let fragment = modifiers?[.fragment]
        if fragment == hatching || fragment == hatchLines, let value = source.value(forKey: hatchAxisKey) {
            destination.setValue(value, forKey: hatchAxisKey)
        }
    }

    private static func bind(_ value: SIMD4<Float>, to material: SCNMaterial, key: String) {
        material.setValue(NSValue(scnVector4: SCNVector4(value.x, value.y, value.z, value.w)), forKey: key)
    }
}

/// Visual section caps use the same display triangles as the clipped scene.
/// Preparation keeps one cut in flight and coalesces later edits to the most
/// recent request. The caller installs its plane and cap in the same scene update.
@MainActor
final class CADViewportSectionCaps {
    private struct Request {
        let plane: CADSectionPlane
        let mesh: CADViewportPreparedMesh
        let transforms: [Int: simd_double4x4]
        let hidden: Set<Int>
        let partOwners: [Int: Int]
        let wire: Bool
        let renderer: SCNRenderer?
        let present: @MainActor (CADSectionPlane?, SCNGeometry?) -> Void
    }

    let node = SCNNode()
    private var task: Task<Void, Never>?
    private var pending: Request?
    var isPreparing: Bool { task != nil }

    init() { node.categoryBitMask = CADViewportCategory.sectionCaps }

    deinit { task?.cancel() }

    func update(plane: CADSectionPlane?, mesh: CADViewportPreparedMesh?, transforms: [Int: simd_double4x4],
                hidden: Set<Int>, partOwners: [Int: Int] = [:], mode: ViewportDisplayMode, renderer: SCNRenderer?,
                replacingInputs: Bool = false,
                present: @escaping @MainActor (CADSectionPlane?, SCNGeometry?) -> Void) {
        if replacingInputs || plane == nil || mesh == nil {
            task?.cancel()
            task = nil
            pending = nil
        }
        guard let plane, let mesh else { present(nil, nil); return }
        pending = Request(plane: plane, mesh: mesh, transforms: transforms, hidden: hidden, partOwners: partOwners,
                          wire: mode == .wireframe, renderer: renderer, present: present)
        startNext()
        if replacingInputs { present(nil, nil) }
    }

    private func startNext() {
        guard task == nil, let request = pending else { return }
        pending = nil
        let worker = Task.detached(priority: .userInitiated) { [mesh = request.mesh, plane = request.plane,
                transforms = request.transforms, hidden = request.hidden, partOwners = request.partOwners, wire = request.wire] in
            try CADSectionCapMesh(mesh: mesh, plane: plane, transforms: transforms, hidden: hidden, partOwners: partOwners, wire: wire)
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler { try? await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            let geometry: SCNGeometry? = result.flatMap {
                $0.positions.isEmpty && $0.interferencePositions.isEmpty ? nil : Self.geometry($0, wire: request.wire)
            }
            let ready: Bool
            if let geometry, let renderer = request.renderer {
                ready = await withCheckedContinuation { continuation in
                    renderer.prepare([geometry]) { continuation.resume(returning: $0) }
                }
            } else {
                ready = geometry != nil
            }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.startNext()
            request.present(request.plane, ready ? geometry : nil)
        }
    }

    private static func geometry(_ cap: CADSectionCapMesh, wire: Bool) -> SCNGeometry {
        let points = cap.interferencePositions.isEmpty ? cap.positions : cap.positions + cap.interferencePositions
        let positions = points.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertices = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: points.count,
                                        usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                        dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        var elements = [SCNGeometryElement]()
        var materials = [SCNMaterial]()

        func appendElement(_ range: Range<Int>, lines: Bool, color: NSColor, hatched: Bool) {
            let indices = Array(UInt32(range.lowerBound)..<UInt32(range.upperBound)).withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(SCNGeometryElement(data: indices, primitiveType: lines ? .line : .triangles,
                                               primitiveCount: range.count / (lines ? 2 : 3), bytesPerIndex: MemoryLayout<UInt32>.size))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.isDoubleSided = true
            material.readsFromDepthBuffer = !wire
            material.writesToDepthBuffer = !wire
            if hatched { CADViewportSectionRendering.hatch(cap.hatchAxis, on: material, linesOnly: wire) }
            materials.append(material)
        }

        if !cap.positions.isEmpty {
            appendElement(0..<cap.positions.count, lines: wire, color: NSColor(srgbRed: 0.59, green: 0.61, blue: 0.64, alpha: 1),
                          hatched: !wire)
        }
        if !cap.interferencePositions.isEmpty {
            appendElement(cap.positions.count..<points.count, lines: false,
                          color: NSColor(srgbRed: 0.92, green: 0.22, blue: 0.23, alpha: 1), hatched: true)
        }
        let geometry = SCNGeometry(sources: [vertices], elements: elements)
        geometry.materials = materials
        return geometry
    }
}

struct CADSectionCapMesh: Sendable {
    private(set) var positions = [SIMD3<Float>]()
    private(set) var interferencePositions = [SIMD3<Float>]()
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
         transforms: [Int: simd_double4x4], hidden: Set<Int>, partOwners: [Int: Int], wire: Bool) throws {
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

        let sections = mesh.groups.sorted { $0.key < $1.key }.compactMap { solid, indices
            -> (solid: Int, indices: [Int32], transform: simd_double4x4, plane: SIMD4<Double>)? in
            guard !hidden.contains(solid) else { return nil }
            let transform = simd_transpose(transforms[solid] ?? matrix_identity_double4x4)
            let localPlane = transform * worldPlane
            if let bounds = mesh.solidBounds[solid], !Self.intersects(bounds, plane: localPlane) { return nil }
            return (solid, indices, transform, localPlane)
        }
        var trapezoids = [CADSectionInterference.Trapezoid]()
        var collectInterference = Set(sections.map { partOwners[$0.solid] ?? $0.solid }).count > 1

        for (solid, indices, transform, localPlane) in sections {
            try Task.checkCancellation()
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
                if !collectInterference { continue }
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
                    if !wire, positions.count + 6 > maximumVertices {
                        exceededBudget = true
                        break
                    }
                    let a = SIMD2(left.edge.x(at: y), y), b = SIMD2(right.edge.x(at: y), y)
                    let c = SIMD2(right.edge.x(at: topY), topY), d = SIMD2(left.edge.x(at: topY), topY)
                    if !wire {
                        for point in [a, b, c, a, c, d] { append(point, in: plane) }
                    }
                    if collectInterference {
                        if trapezoids.count < maximumVertices / 6 {
                            trapezoids.append(.init(owner: partOwners[solid] ?? solid, bottomLeft: a, bottomRight: b, topRight: c, topLeft: d))
                        } else {
                            // Ignore incomplete overlap candidates while retaining the ordinary wire contours.
                            trapezoids.removeAll()
                            collectInterference = false
                        }
                    }
                }
                if exceededBudget || (wire && !collectInterference) { break }
            }
            if exceededBudget {
                positions.removeSubrange(solidStart...)
                return
            }
        }
        let availableVertices = wire ? maximumVertices - positions.count : maximumVertices
        if collectInterference, let overlap = try CADSectionInterference.triangulate(
            trapezoids, tolerance: coordinateTolerance, maximumVertices: availableVertices, includesNormal: !wire
        ) {
            if !wire { positions = overlap.normal.map { Self.world($0, in: plane) } }
            interferencePositions = overlap.interfering.map { Self.world($0, in: plane) }
        }
    }

    private mutating func append(_ uv: SIMD2<Double>, in plane: CADSectionPlane) {
        positions.append(Self.world(uv, in: plane))
    }

    private static func world(_ uv: SIMD2<Double>, in plane: CADSectionPlane) -> SIMD3<Float> {
        SIMD3<Float>(plane.origin + uv.x * plane.horizontal + uv.y * plane.vertical)
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
