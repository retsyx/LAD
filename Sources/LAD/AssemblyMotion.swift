import Foundation
import simd

/// Mate frames are expressed in the design coordinates of the replayed geometry.
/// Solved transforms are world-space deltas, so the same pose applies to native
/// solids, display buffers, picking and measurements without replaying a program.
struct AssemblyConnector: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var part: String
    var origin: [Double]
    var xAxis: [Double] = [1, 0, 0]
    var zAxis: [Double] = [0, 0, 1]

    private enum CodingKeys: String, CodingKey { case id, part, origin, xAxis, zAxis }

    init(id: String, part: String, origin: [Double], xAxis: [Double] = [1, 0, 0], zAxis: [Double] = [0, 0, 1]) {
        self.id = id; self.part = part; self.origin = origin; self.xAxis = xAxis; self.zAxis = zAxis
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        part = try values.decode(String.self, forKey: .part)
        origin = try values.decode([Double].self, forKey: .origin)
        xAxis = try values.decodeIfPresent([Double].self, forKey: .xAxis) ?? [1, 0, 0]
        zAxis = try values.decodeIfPresent([Double].self, forKey: .zAxis) ?? [0, 0, 1]
    }

    fileprivate func frame() throws -> simd_double4x4 {
        guard origin.count == 3, xAxis.count == 3, zAxis.count == 3,
              (origin + xAxis + zAxis).allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else {
            throw LADError.message("The design has an invalid mate connector: \(id).")
        }
        let x = SIMD3<Double>(xAxis[0], xAxis[1], xAxis[2])
        let z = SIMD3<Double>(zAxis[0], zAxis[1], zAxis[2])
        guard abs(simd_length(x) - 1) <= 1e-6, abs(simd_length(z) - 1) <= 1e-6 else {
            throw LADError.message("The mate connector \(id) needs two perpendicular unit axes.")
        }
        let ux = simd_normalize(x), uz = simd_normalize(z)
        guard abs(simd_dot(ux, uz)) <= 1e-6 else {
            throw LADError.message("The mate connector \(id) needs two perpendicular axes.")
        }
        let uy = simd_normalize(simd_cross(uz, ux)), exactX = simd_cross(uy, uz)
        return simd_double4x4(columns: (SIMD4(exactX, 0), SIMD4(uy, 0), SIMD4(uz, 0),
                                       SIMD4(origin[0], origin[1], origin[2], 1)))
    }
}

struct AssemblyJoint: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case fixed, revolute, slider
    }
    var id: String
    var name: String
    var type: Kind
    var parent: String
    var child: String
    /// Degrees for revolute joints; millimeters for sliders.
    var position: Double = 0
    var limits: [Double]? = nil

    var isMovable: Bool { type != .fixed }
    var unit: String { type == .revolute ? "°" : "mm" }

    private enum CodingKeys: String, CodingKey { case id, name, type, parent, child, position, limits }

    init(id: String, name: String? = nil, type: Kind, parent: String, child: String,
         position: Double = 0, limits: [Double]? = nil) {
        self.id = id; self.name = name ?? id; self.type = type; self.parent = parent; self.child = child
        self.position = position; self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
        type = try values.decode(Kind.self, forKey: .type)
        parent = try values.decode(String.self, forKey: .parent)
        child = try values.decode(String.self, forKey: .child)
        position = try values.decodeIfPresent(Double.self, forKey: .position) ?? 0
        limits = try values.decodeIfPresent([Double].self, forKey: .limits)
    }

    fileprivate func movement(_ value: Double) -> simd_double4x4 {
        switch type {
        case .fixed: return matrix_identity_double4x4
        case .revolute:
            return simd_double4x4(simd_quatd(angle: value * .pi / 180, axis: SIMD3(0, 0, 1)))
        case .slider:
            var matrix = matrix_identity_double4x4
            matrix.columns.3.z = value
            return matrix
        }
    }
}

/// A follower joint's coordinate as a function of its driver joint's coordinate.
/// Linear relations cover gears, belts, racks and screws; sampled tables cover
/// cams and intermittent indexing. Followers are never free solver variables,
/// so a higher pair such as a Geneva pin and slot needs no contact model.
struct AssemblyCoupling: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case linear, table }
    var id: String
    var type: Kind
    var driver: String
    var follower: String
    /// Follower units per driver unit, plus a follower offset (linear only).
    var ratio: Double? = nil
    var offset: Double? = nil
    /// `[driver, follower]` pairs with strictly increasing driver values (table only).
    var samples: [[Double]]? = nil
    /// A periodic table repeats every `period` driver units, adding `advance`.
    var period: Double? = nil
    var advance: Double? = nil

    static func linear(id: String, driver: String, follower: String, ratio: Double, offset: Double = 0) -> Self {
        Self(id: id, type: .linear, driver: driver, follower: follower, ratio: ratio, offset: offset)
    }

    static func table(id: String, driver: String, follower: String, samples: [[Double]],
                      period: Double? = nil, advance: Double? = nil) -> Self {
        Self(id: id, type: .table, driver: driver, follower: follower, samples: samples, period: period, advance: advance)
    }
}

/// Validated evaluation form of the worker's `coupled_position`, which derives
/// follower positions when a build is validated. Both test suites check the
/// golden cases in Engine/tests/assembly-coupling-cases.json.
/// A periodic table's samples already include the closing point of its period.
fileprivate struct CouplingLaw: Sendable {
    var driver: Int
    var follower: Int
    var ratio = 1.0, offset = 0.0
    var xs = [Double](), ys = [Double]()
    var period: Double?
    var advance = 0.0
    var isLinear: Bool

    func value(_ input: Double) -> Double {
        if isLinear { return ratio * input + offset }
        var x = input, shift = 0.0
        if let period {
            let turns = ((input - xs[0]) / period).rounded(.down)
            x -= turns * period
            shift = turns * advance
        }
        x = min(max(x, xs[0]), xs[xs.count - 1])
        var low = 0, high = xs.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if xs[middle] <= x { low = middle } else { high = middle }
        }
        let span = xs[high] - xs[low]
        let fraction = span > 0 ? min(max((x - xs[low]) / span, 0), 1) : 0
        return ys[low] + fraction * (ys[high] - ys[low]) + shift
    }
}

struct AssemblyPose: Sendable, Equatable {
    var positions: [String: Double]
    /// Row-major homogeneous rigid transforms, relative to replayed geometry.
    var solidTransforms: [Int: [Double]]

    static let identityTransform: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    fileprivate static func rows(_ matrix: simd_double4x4) -> [Double] {
        (0..<16).map { matrix[$0 % 4][$0 / 4] }
    }
}

struct AssemblyMotion: Codable, Sendable, Equatable {
    var grounded: [String] = []
    var connectors: [AssemblyConnector]
    var joints: [AssemblyJoint]
    var couplings: [AssemblyCoupling] = []

    private enum CodingKeys: String, CodingKey { case grounded, connectors, joints, couplings }

    init(grounded: [String] = [], connectors: [AssemblyConnector], joints: [AssemblyJoint],
         couplings: [AssemblyCoupling] = []) {
        self.grounded = grounded; self.connectors = connectors; self.joints = joints; self.couplings = couplings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grounded = try values.decodeIfPresent([String].self, forKey: .grounded) ?? []
        connectors = try values.decode([AssemblyConnector].self, forKey: .connectors)
        joints = try values.decode([AssemblyJoint].self, forKey: .joints)
        couplings = try values.decodeIfPresent([AssemblyCoupling].self, forKey: .couplings) ?? []
    }

    func validate(parts: [PartNode]) throws { _ = try graph(parts: parts) }

    /// The joint that determines a follower's coordinate, or nil for an independent joint.
    func driver(of jointID: String) -> AssemblyJoint? {
        guard let coupling = couplings.first(where: { $0.follower == jointID }) else { return nil }
        return joints.first { $0.id == coupling.driver }
    }

    /// Followers take their positions from their drivers; only independent
    /// joints can be positioned directly.
    func requireIndependent(_ jointID: String) throws {
        if let driver = driver(of: jointID), let joint = joints.first(where: { $0.id == jointID }) {
            throw LADError.message("\(joint.name) follows \(driver.name) through a coupling. Position \(driver.name) instead.")
        }
    }

    /// The named driving joint keeps its requested position. Other joints in a
    /// closed mechanism may move to satisfy closure, using the supplied pose as
    /// a continuity hint. A failed solve never publishes a partial pose.
    func solve(parts: [PartNode], positions: [String: Double] = [:], driving: String? = nil) throws -> AssemblyPose {
        try Task.checkCancellation()
        let graph = try graph(parts: parts)
        return try solve(graph: graph, positions: positions, driving: driving)
    }

    private func solve(graph: Graph, positions: [String: Double], driving: String? = nil,
                       allowedFree: Set<Int>? = nil) throws -> AssemblyPose {
        try Task.checkCancellation()
        let byID = Dictionary(uniqueKeysWithValues: joints.enumerated().map { ($0.element.id, $0.offset) })
        guard positions.keys.allSatisfy({ byID[$0] != nil }),
              driving == nil || byID[driving!].map({ joints[$0].isMovable }) == true else {
            throw LADError.message("The design's assembly pose refers to an unknown or fixed joint.")
        }
        if let driving { try requireIndependent(driving) }
        // Supplied follower coordinates are stale continuity data; their
        // drivers determine them before any limit check or closure solve.
        let supplied = joints.map { positions[$0.id] ?? $0.position }
        guard supplied.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else {
            throw LADError.message("The design's assembly pose contains an invalid joint position.")
        }
        var values = graph.resolve(supplied)
        try checkLimits(values)
        let free = joints.indices.filter {
            joints[$0].isMovable && joints[$0].id != driving && graph.closureVariables.contains($0)
                && graph.drivers[$0] == nil && (allowedFree?.contains($0) ?? true)
                && !(joints[$0].limits.map { $0[0] == $0[1] } ?? false)
        }
        let factors = free.map { joints[$0].type == .revolute ? 180 / Double.pi : graph.scale }
        var x = zip(free, factors).map { values[$0.0] / $0.1 }
        let lower = zip(free, factors).map { index, factor in (joints[index].limits?[0] ?? -1e9) / factor }
        let upper = zip(free, factors).map { index, factor in (joints[index].limits?[1] ?? 1e9) / factor }

        func evaluate(_ parameters: [Double]) -> (poses: [String: simd_double4x4], residual: [Double]) {
            var candidate = values
            for index in free.indices { candidate[free[index]] = parameters[index] * factors[index] }
            return graph.evaluate(joints: joints, positions: candidate)
        }

        var evaluated = evaluate(x)
        var damping = 1e-4
        // Tree assemblies require only propagation. Closure adds a small
        // bounded least-squares solve in joint coordinates, not body geometry.
        if !graph.closures.isEmpty && !Self.isClosed(evaluated.residual, scale: graph.scale) {
            guard !free.isEmpty else { throw closureError(driving) }
            for _ in 0..<120 {
                try Task.checkCancellation()
                if Self.isClosed(evaluated.residual, scale: graph.scale) { break }
                let residual = evaluated.residual, count = x.count
                var columns = [[Double]]()
                for index in x.indices {
                    try Task.checkCancellation()
                    var plus = x, minus = x
                    let step = 1e-5 * max(1, abs(x[index]))
                    plus[index] = min(upper[index], x[index] + step)
                    minus[index] = max(lower[index], x[index] - step)
                    let span = plus[index] - minus[index]
                    if span <= 1e-15 { columns.append(Array(repeating: 0, count: residual.count)); continue }
                    let high = evaluate(plus).residual, low = evaluate(minus).residual
                    columns.append(zip(high, low).map { ($0 - $1) / span })
                }
                var normal = Array(repeating: Array(repeating: 0.0, count: count), count: count)
                var rhs = Array(repeating: 0.0, count: count)
                for row in 0..<count {
                    try Task.checkCancellation()
                    rhs[row] = -zip(columns[row], residual).reduce(0) { $0 + $1.0 * $1.1 }
                    for column in 0...row {
                        let dot = zip(columns[row], columns[column]).reduce(0) { $0 + $1.0 * $1.1 }
                        normal[row][column] = dot; normal[column][row] = dot
                    }
                }
                let previousCost = Self.cost(residual)
                var accepted = false
                for _ in 0..<10 {
                    try Task.checkCancellation()
                    var damped = normal
                    for index in 0..<count { damped[index][index] += damping * max(1, normal[index][index]) }
                    guard let delta = try Self.linearSolve(damped, rhs) else { damping *= 10; continue }
                    let trial = x.indices.map { index in
                        min(upper[index], max(lower[index], x[index] + min(0.5, max(-0.5, delta[index]))))
                    }
                    let next = evaluate(trial)
                    if Self.cost(next.residual) < previousCost {
                        x = trial; evaluated = next; damping = max(1e-12, damping / 3); accepted = true; break
                    }
                    damping *= 10
                }
                if !accepted { break }
            }
            guard Self.isClosed(evaluated.residual, scale: graph.scale) else { throw closureError(driving) }
        }
        for index in free.indices { values[free[index]] = x[index] * factors[index] }
        if !graph.couplings.isEmpty {
            values = graph.resolve(values)
            do { try checkLimits(values) } catch { throw closureError(driving) }
        }
        var transforms = [Int: [Double]]()
        for (part, matrix) in evaluated.poses {
            let rows = AssemblyPose.rows(matrix)
            guard rows.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else { throw closureError(driving) }
            if zip(rows, AssemblyPose.identityTransform).allSatisfy({ abs($0 - $1) <= 1e-12 }) { continue }
            for solid in graph.solids[part] ?? [] { transforms[solid] = rows }
        }
        return AssemblyPose(positions: Dictionary(uniqueKeysWithValues: joints.indices.map { (joints[$0].id, values[$0]) }),
                            solidTransforms: transforms)
    }

    func canGrab(solidIndex: Int, parts: [PartNode]) -> Bool {
        guard let graph = try? graph(parts: parts) else { return false }
        return grabCoordinates(graph: graph, solidIndex: solidIndex) != nil
    }

    /// Cache native identities, ancestor paths and closure dependencies once at
    /// mouse-down. The point stays in the original replayed geometry's space.
    func prepareGrab(parts: [PartNode], positions: [String: Double] = [:], solidIndex: Int,
                     point: [Double], projection: AssemblyGrabProjection) throws -> AssemblyGrabContext? {
        try Task.checkCancellation()
        try projection.validate()
        guard point.count == 3, point.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else {
            throw LADError.message("The grabbed design point is invalid.")
        }
        let graph = try graph(parts: parts)
        guard let coordinates = grabCoordinates(graph: graph, solidIndex: solidIndex) else { return nil }
        let pose = try solve(graph: graph, positions: positions)
        let builtPoint = SIMD3(point[0], point[1], point[2])
        let values = joints.map { pose.positions[$0.id] ?? $0.position }
        let evaluated = graph.evaluate(joints: joints, positions: values)
        let world = evaluated.poses[coordinates.part]! * SIMD4(builtPoint, 1)
        guard projection.screen(SIMD3(world.x, world.y, world.z)) != nil else { return nil }
        return AssemblyGrabContext(solidIndex: solidIndex, point: point, projection: projection,
            motion: self, graph: graph, part: coordinates.part, coordinates: coordinates.indices,
            initialPositions: pose.positions)
    }

    func solveGrab(parts: [PartNode], positions: [String: Double] = [:], solidIndex: Int,
                   point: [Double], screenPoint: [Double], projection: AssemblyGrabProjection) throws -> AssemblyPose {
        guard let context = try prepareGrab(parts: parts, positions: positions, solidIndex: solidIndex,
                                            point: point, projection: projection) else {
            return try solve(parts: parts, positions: positions)
        }
        return try context.solve(positions: positions, screenPoint: screenPoint)
    }

    private func grabCoordinates(graph: Graph, solidIndex: Int) -> (part: String, indices: [Int])? {
        guard let part = graph.solids.first(where: { $0.value.contains(solidIndex) })?.key else { return nil }
        // A coupled follower moves only through its independent root driver.
        var involved = Set((graph.paths[part] ?? []).map { graph.roots[$0] })
        var expanded = true
        while expanded {
            let previous = involved.count
            for path in graph.closurePaths where !path.isDisjoint(with: involved) { involved.formUnion(path) }
            expanded = involved.count != previous
        }
        let indices = involved.sorted().filter {
            joints[$0].isMovable && !(joints[$0].limits.map { $0[0] == $0[1] } ?? false)
        }
        return indices.isEmpty ? nil : (part, indices)
    }

    fileprivate func solveGrab(context: AssemblyGrabContext, positions: [String: Double],
                               screenPoint: [Double]) throws -> AssemblyPose {
        try Task.checkCancellation()
        guard screenPoint.count == 2, screenPoint.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else {
            throw LADError.message("The assembly drag target is invalid.")
        }
        let graph = context.graph, active = context.coordinates, allowed = Set(active)
        let requested = context.initialPositions.merging(positions) { _, current in current }
        var pose = try solve(graph: graph, positions: requested, allowedFree: allowed)
        let target = SIMD2(screenPoint[0], screenPoint[1])
        let point = SIMD4(context.point[0], context.point[1], context.point[2], 1)
        let factors = active.map { joints[$0].type == .revolute ? 180 / Double.pi : graph.scale }
        let lower = zip(active, factors).map { index, factor in (joints[index].limits?[0] ?? -1e9) / factor }
        let upper = zip(active, factors).map { index, factor in (joints[index].limits?[1] ?? 1e9) / factor }
        let screenScale = max(64, min(context.projection.viewportSize[0], context.projection.viewportSize[1]))
        let closureWeight = 100.0
        var values = joints.map { pose.positions[$0.id] ?? $0.position }

        func evaluate(_ candidate: [Double]) -> (screen: SIMD2<Double>, residual: [Double])? {
            let result = graph.evaluate(joints: joints, positions: candidate)
            let world = result.poses[context.part]! * point
            guard let screen = context.projection.screen(SIMD3(world.x, world.y, world.z)) else { return nil }
            let error = (screen - target) / screenScale
            return (screen, result.residual.map { $0 * closureWeight } + [error.x, error.y])
        }
        func valuesAt(_ parameters: [Double], base: [Double]) -> [Double] {
            var candidate = base
            for index in active.indices { candidate[active[index]] = parameters[index] * factors[index] }
            return candidate
        }
        func projected(_ parameters: [Double], base: [Double]) throws -> AssemblyPose? {
            let candidate = valuesAt(parameters, base: base)
            let coordinates = Dictionary(uniqueKeysWithValues: joints.indices.map { (joints[$0].id, candidate[$0]) })
            do { return try solve(graph: graph, positions: coordinates, allowedFree: allowed) }
            catch is CancellationError { throw CancellationError() }
            catch { return nil }
        }
        guard var current = evaluate(values) else { return pose }
        var distance = simd_length_squared(current.screen - target)
        var damping = 1e-5
        for _ in 0..<16 {
            try Task.checkCancellation()
            if distance <= 0.15 * 0.15 { break }
            let x = zip(active, factors).map { values[$0.0] / $0.1 }
            var columns = [[Double]]()
            for index in active.indices {
                try Task.checkCancellation()
                var plus = x, minus = x
                plus[index] = min(upper[index], x[index] + 1e-5)
                minus[index] = max(lower[index], x[index] - 1e-5)
                let span = plus[index] - minus[index]
                guard span > 1e-15,
                      let high = evaluate(valuesAt(plus, base: values)),
                      let low = evaluate(valuesAt(minus, base: values)) else {
                    columns.append(Array(repeating: 0, count: current.residual.count)); continue
                }
                columns.append(zip(high.residual, low.residual).map { ($0 - $1) / span })
            }
            var normal = Array(repeating: Array(repeating: 0.0, count: active.count), count: active.count)
            var rhs = Array(repeating: 0.0, count: active.count)
            for row in active.indices {
                try Task.checkCancellation()
                rhs[row] = -zip(columns[row], current.residual).reduce(0) { $0 + $1.0 * $1.1 }
                for column in 0...row {
                    let value = zip(columns[row], columns[column]).reduce(0) { $0 + $1.0 * $1.1 }
                    normal[row][column] = value; normal[column][row] = value
                }
                normal[row][row] += damping
            }
            var accepted = false
            if let delta = try Self.linearSolve(normal, rhs) {
                // A uniform trust step preserves the closure tangent direction.
                let trust = active.indices.reduce(1.0) { fraction, index in
                    joints[active[index]].type == .revolute
                        ? min(fraction, 0.4 / max(1e-12, abs(delta[index]))) : fraction
                }
                for backtrack in 0..<7 {
                    try Task.checkCancellation()
                    let fraction = trust * pow(0.5, Double(backtrack))
                    let trial = active.indices.map { min(upper[$0], max(lower[$0], x[$0] + delta[$0] * fraction)) }
                    guard let candidate = try projected(trial, base: values) else { continue }
                    let candidateValues = joints.map { candidate.positions[$0.id] ?? $0.position }
                    guard let result = evaluate(candidateValues) else { continue }
                    let cost = simd_length_squared(result.screen - target)
                    if cost + max(1e-8, distance * 1e-12) < distance {
                        pose = candidate; values = candidateValues; current = result; distance = cost; accepted = true; break
                    }
                }
            }
            if !accepted {
                // At a projected turning point, the tangent can vanish while
                // a nearby valid position still improves the grab. Probe only
                // the strongest few screen coordinates, with a bounded step.
                let ranked = active.indices.sorted {
                    Self.cost(Array(columns[$0].suffix(2))) > Self.cost(Array(columns[$1].suffix(2)))
                }.prefix(6)
                var best: (AssemblyPose, [Double], SIMD2<Double>, [Double], Double)?
                for index in ranked {
                    for sign in [-1.0, 1.0] {
                        try Task.checkCancellation()
                        var trial = x
                        trial[index] = min(upper[index], max(lower[index], x[index] + sign * 0.12))
                        guard let candidate = try projected(trial, base: values) else { continue }
                        let candidateValues = joints.map { candidate.positions[$0.id] ?? $0.position }
                        guard let result = evaluate(candidateValues) else { continue }
                        let cost = simd_length_squared(result.screen - target)
                        if cost + max(1e-8, distance * 1e-12) < (best?.4 ?? distance) {
                            best = (candidate, candidateValues, result.screen, result.residual, cost)
                        }
                    }
                }
                if let best {
                    pose = best.0; values = best.1; current = (best.2, best.3); distance = best.4; accepted = true
                }
            }
            if !accepted { break }
            damping = max(1e-10, damping / 3)
        }
        try Task.checkCancellation()
        return pose
    }

    private func checkLimits(_ values: [Double]) throws {
        for (index, joint) in joints.enumerated() {
            guard values[index].isFinite, abs(values[index]) <= 1e9,
                  joint.type != .fixed || abs(values[index]) <= 1e-12,
                  joint.limits.map({ values[index] >= $0[0] && values[index] <= $0[1] }) ?? true else {
                throw LADError.message("The position of \(joint.name) is outside its motion limits.")
            }
        }
    }

    private func closureError(_ driving: String?) -> LADError {
        let joint = driving.flatMap { id in joints.first { $0.id == id } }
        return .message(joint.map { "The design cannot reach this position of \($0.name) within its joint constraints and motion limits." }
            ?? "The design's assembly constraints cannot be satisfied within its motion limits.")
    }

    fileprivate struct Arc: Sendable {
        var joint: Int
        var from: String
        var to: String
        var forward: Bool
    }

    fileprivate struct Graph: Sendable {
        var solids: [String: Set<Int>]
        var frames: [String: simd_double4x4]
        var connectorParts: [String: String]
        var anchors: [String]
        var tree: [Arc]
        var closures: [Int]
        /// Only joints on closure paths can affect the nonlinear residual.
        var closureVariables: Set<Int>
        var paths: [String: Set<Int>]
        /// Root-mapped joints whose coordinates affect each closure residual.
        var closurePaths: [Set<Int>]
        var scale: Double
        /// Couplings in dependency order, each follower's driver, and each
        /// joint's independent root (itself when it follows no coupling).
        var couplings: [CouplingLaw]
        var drivers: [Int: Int]
        var roots: [Int]

        func resolve(_ positions: [Double]) -> [Double] {
            guard !couplings.isEmpty else { return positions }
            var resolved = positions
            for law in couplings { resolved[law.follower] = law.value(resolved[law.driver]) }
            return resolved
        }

        func evaluate(joints: [AssemblyJoint], positions supplied: [Double]) -> (poses: [String: simd_double4x4], residual: [Double]) {
            let positions = resolve(supplied)
            var poses = Dictionary(uniqueKeysWithValues: anchors.map { ($0, matrix_identity_double4x4) })
            for arc in tree {
                let joint = joints[arc.joint]
                let parent = frames[joint.parent]!, child = frames[joint.child]!
                let relation = parent * joint.movement(positions[arc.joint]) * child.inverse
                poses[arc.to] = poses[arc.from]! * (arc.forward ? relation : relation.inverse)
            }
            var residual = [Double]()
            for index in closures {
                let joint = joints[index]
                let expected = poses[connectorParts[joint.parent]!]! * frames[joint.parent]! * joint.movement(positions[index])
                let actual = poses[connectorParts[joint.child]!]! * frames[joint.child]!
                let error = actual.inverse * expected
                residual.append(contentsOf: [error.columns.3.x / scale, error.columns.3.y / scale, error.columns.3.z / scale])
                var rotation = simd_quatd(error)
                if rotation.real < 0 { rotation = simd_quatd(vector: -rotation.vector) }
                let length = simd_length(rotation.imag)
                let vector = length > 1e-12 ? rotation.imag * (2 * atan2(length, rotation.real) / length) : rotation.imag * 2
                residual.append(contentsOf: [vector.x, vector.y, vector.z])
            }
            return (poses, residual)
        }
    }

    private func graph(parts: [PartNode]) throws -> Graph {
        func visible(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        func validID(_ id: String) -> Bool { visible(id) && id.utf8.count <= 1024 }
        guard connectors.count <= 1024, joints.count <= 256, grounded.count <= 4096,
              Set(connectors.map(\.id)).count == connectors.count,
              Set(joints.map(\.id)).count == joints.count,
              Set(grounded).count == grounded.count,
              connectors.allSatisfy({ validID($0.id) && validID($0.part) }),
              joints.allSatisfy({ validID($0.id) && visible($0.name) && $0.name.unicodeScalars.count <= 160 }),
              grounded.allSatisfy(validID) else {
            throw LADError.message("The design has invalid or duplicate assembly connectors or joints.")
        }
        let flattened = parts.flatMap(\.flattened)
        guard Set(flattened.map(\.id)).count == flattened.count else {
            throw LADError.message("The design's assembly parts have duplicate identities.")
        }
        let owners = Dictionary(uniqueKeysWithValues: flattened.map { ($0.id, $0) })
        let referenced = Set(connectors.map(\.part)).union(grounded)
        var solids = [String: Set<Int>](), claimed = Set<Int>()
        for part in referenced.sorted() {
            guard let owner = owners[part], owner.children == nil, owner.solidIndices.count == 1,
                  let solid = owner.solidIndices.first, solid >= 0 else {
                throw LADError.message("Assembly connectors must refer to separate existing rigid parts: \(part).")
            }
            let indices = Set(owner.solidIndices)
            guard claimed.isDisjoint(with: indices) else {
                throw LADError.message("Assembly connectors must refer to separate existing rigid parts: \(part).")
            }
            solids[part] = indices; claimed.formUnion(indices)
        }
        var frames = [String: simd_double4x4](), connectorParts = [String: String]()
        for connector in connectors {
            frames[connector.id] = try connector.frame(); connectorParts[connector.id] = connector.part
        }
        var adjacency = [String: [Arc]]()
        for (index, joint) in joints.enumerated() {
            guard let parent = connectorParts[joint.parent], let child = connectorParts[joint.child], parent != child,
                  joint.position.isFinite, abs(joint.position) <= 1e9,
                  joint.type != .fixed || (joint.position == 0 && joint.limits == nil) else {
                throw LADError.message("The design has an invalid joint: \(joint.name).")
            }
            if let limits = joint.limits {
                guard limits.count == 2, limits.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }),
                      limits[0] <= limits[1], joint.position >= limits[0], joint.position <= limits[1] else {
                    throw LADError.message("The motion limits for \(joint.name) are invalid.")
                }
            }
            adjacency[parent, default: []].append(Arc(joint: index, from: parent, to: child, forward: true))
            adjacency[child, default: []].append(Arc(joint: index, from: child, to: parent, forward: false))
        }
        // Multi-source propagation keeps every explicitly grounded body fixed.
        // Connector-only parts stay stationary; joint-connected components
        // require an explicit anchor rather than guessing which part is fixed.
        var anchors = grounded.sorted(), visited = Set(anchors), tree = [Arc](), treeJoints = Set<Int>()
        var queue = anchors, offset = 0
        for candidate in referenced.sorted() {
            while offset < queue.count {
                let part = queue[offset]; offset += 1
                for arc in adjacency[part] ?? [] where !visited.contains(arc.to) {
                    visited.insert(arc.to); queue.append(arc.to); tree.append(arc); treeJoints.insert(arc.joint)
                }
            }
            if !visited.contains(candidate) {
                guard adjacency[candidate] == nil else {
                    throw LADError.message("Every moving assembly component needs a grounded part.")
                }
                anchors.append(candidate); visited.insert(candidate); queue.append(candidate)
            }
        }
        while offset < queue.count {
            let part = queue[offset]; offset += 1
            for arc in adjacency[part] ?? [] where !visited.contains(arc.to) {
                visited.insert(arc.to); queue.append(arc.to); tree.append(arc); treeJoints.insert(arc.joint)
            }
        }
        let origins = connectors.map { SIMD3($0.origin[0], $0.origin[1], $0.origin[2]) }
        let base = origins.first ?? .zero
        let scale = max(1, origins.map { simd_length($0 - base) }.max() ?? 1)
        let closures = joints.indices.filter { !treeJoints.contains($0) }
        var paths = Dictionary(uniqueKeysWithValues: anchors.map { ($0, Set<Int>()) })
        for arc in tree { paths[arc.to] = (paths[arc.from] ?? []).union([arc.joint]) }
        let (laws, drivers, roots) = try couplingLaws()
        var closureVariables = Set<Int>()
        var closurePaths = [Set<Int>]()
        for index in closures {
            let joint = joints[index]
            let a = paths[connectorParts[joint.parent]!] ?? [], b = paths[connectorParts[joint.child]!] ?? []
            // A common prefix moves the entire loop rigidly and cancels from
            // the closure equation. Unrelated open chains also remain direct.
            let variables = Set(a.symmetricDifference(b).union([index]).map { roots[$0] })
            closurePaths.append(variables)
            closureVariables.formUnion(variables)
        }
        return Graph(solids: solids, frames: frames, connectorParts: connectorParts, anchors: anchors, tree: tree,
                     closures: closures, closureVariables: closureVariables, paths: paths,
                     closurePaths: closurePaths, scale: scale, couplings: laws, drivers: drivers, roots: roots)
    }

    /// Validates couplings and orders them so every driver resolves before its followers.
    private func couplingLaws() throws -> (laws: [CouplingLaw], drivers: [Int: Int], roots: [Int]) {
        let byID = Dictionary(uniqueKeysWithValues: joints.enumerated().map { ($0.element.id, $0.offset) })
        guard couplings.count <= 256, Set(couplings.map(\.id)).count == couplings.count,
              couplings.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 1024 }) else {
            throw LADError.message("The design has invalid or duplicate assembly couplings.")
        }
        var drivers = [Int: Int](), unordered = [CouplingLaw](), totalSamples = 0
        for coupling in couplings {
            func invalid(_ reason: String) -> LADError { .message("The assembly coupling \(coupling.id) \(reason).") }
            guard let driver = byID[coupling.driver], let follower = byID[coupling.follower], driver != follower,
                  joints[driver].isMovable, joints[follower].isMovable else {
                throw invalid("must relate two different movable joints")
            }
            guard drivers[follower] == nil else { throw invalid("names a follower that already follows another coupling") }
            drivers[follower] = driver
            var law = CouplingLaw(driver: driver, follower: follower, isLinear: coupling.type == .linear)
            switch coupling.type {
            case .linear:
                guard let ratio = coupling.ratio, ratio.isFinite, ratio != 0, abs(ratio) <= 1e9,
                      (coupling.offset ?? 0).isFinite, abs(coupling.offset ?? 0) <= 1e9,
                      coupling.samples == nil, coupling.period == nil, coupling.advance == nil else {
                    throw invalid("needs only a nonzero finite ratio and an optional offset")
                }
                law.ratio = ratio; law.offset = coupling.offset ?? 0
            case .table:
                guard coupling.ratio == nil, coupling.offset == nil, let samples = coupling.samples,
                      (2...4096).contains(samples.count),
                      samples.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) <= 1e9 } }) else {
                    throw invalid("needs between 2 and 4,096 finite [driver, follower] samples")
                }
                totalSamples += samples.count
                guard totalSamples <= 65_536 else {
                    throw LADError.message("The design's assembly couplings exceed 65,536 samples in total.")
                }
                law.xs = samples.map { $0[0] }; law.ys = samples.map { $0[1] }
                guard zip(law.xs, law.xs.dropFirst()).allSatisfy({ $0 < $1 }) else {
                    throw invalid("needs strictly increasing driver samples")
                }
                let span = law.xs[law.xs.count - 1] - law.xs[0]
                if let period = coupling.period {
                    let advance = coupling.advance ?? 0, tolerance = 1e-9 * max(1, period)
                    let closing = law.ys[0] + advance
                    guard period.isFinite, period > 0, period <= 1e9, advance.isFinite, abs(advance) <= 1e9,
                          span <= period + tolerance,
                          span < period - tolerance || abs(law.ys[law.ys.count - 1] - closing) <= 1e-6 * max(1, abs(closing)) else {
                        throw invalid("needs samples within one positive period that close with its advance")
                    }
                    law.period = period; law.advance = advance
                    if law.xs[law.xs.count - 1] < law.xs[0] + period {
                        law.xs.append(law.xs[0] + period); law.ys.append(closing)
                    }
                } else {
                    guard coupling.advance == nil, let limits = joints[driver].limits,
                          limits[0] >= law.xs[0], limits[1] <= law.xs[law.xs.count - 1] else {
                        throw invalid("needs a driver with motion limits within its sample range")
                    }
                }
            }
            unordered.append(law)
        }
        var roots = Array(joints.indices)
        var depth = [Int: Int]()
        for follower in drivers.keys {
            var visited: Set<Int> = [follower], current = follower, steps = 0
            while let next = drivers[current] {
                guard visited.insert(next).inserted else {
                    throw LADError.message("The design's assembly couplings form a cycle.")
                }
                current = next; steps += 1
            }
            roots[follower] = current; depth[follower] = steps
        }
        let laws = unordered.sorted { depth[$0.follower]! < depth[$1.follower]! }
        return (laws, drivers, roots)
    }

    private static func isClosed(_ residual: [Double], scale: Double) -> Bool {
        residual.enumerated().allSatisfy { index, value in
            let tolerance = index % 6 < 3 ? 1e-7 / scale + 1e-12 : 1e-8
            return value.isFinite && abs(value) <= tolerance
        }
    }
    private static func cost(_ values: [Double]) -> Double { values.reduce(0) { $0 + $1 * $1 } }

    /// Partial pivoting is sufficient for the damped positive definite normal
    /// system and keeps this small joint solver independent of extra runtimes.
    private static func linearSolve(_ input: [[Double]], _ inputRHS: [Double]) throws -> [Double]? {
        var matrix = input, rhs = inputRHS
        let count = rhs.count
        for column in 0..<count {
            try Task.checkCancellation()
            guard let pivot = (column..<count).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 1e-18 else { return nil }
            if pivot != column { matrix.swapAt(pivot, column); rhs.swapAt(pivot, column) }
            if column + 1 < count {
                for row in (column + 1)..<count {
                    let factor = matrix[row][column] / matrix[column][column]
                    for index in column..<count { matrix[row][index] -= factor * matrix[column][index] }
                    rhs[row] -= factor * rhs[column]
                }
            }
        }
        var result = Array(repeating: 0.0, count: count)
        for row in stride(from: count - 1, through: 0, by: -1) {
            var value = rhs[row]
            if row + 1 < count { for column in (row + 1)..<count { value -= matrix[row][column] * result[column] } }
            result[row] = value / matrix[row][row]
        }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}

/// Immutable per-gesture setup can safely cross to a detached solve task.
struct AssemblyGrabContext: Sendable {
    let solidIndex: Int
    let point: [Double]
    let projection: AssemblyGrabProjection
    fileprivate let motion: AssemblyMotion
    fileprivate let graph: AssemblyMotion.Graph
    fileprivate let part: String
    fileprivate let coordinates: [Int]
    fileprivate let initialPositions: [String: Double]

    func solve(positions: [String: Double] = [:], screenPoint: [Double]) throws -> AssemblyPose {
        try motion.solveGrab(context: self, positions: positions, screenPoint: screenPoint)
    }
}
