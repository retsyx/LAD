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

    private enum CodingKeys: String, CodingKey { case grounded, connectors, joints }

    init(grounded: [String] = [], connectors: [AssemblyConnector], joints: [AssemblyJoint]) {
        self.grounded = grounded; self.connectors = connectors; self.joints = joints
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grounded = try values.decodeIfPresent([String].self, forKey: .grounded) ?? []
        connectors = try values.decode([AssemblyConnector].self, forKey: .connectors)
        joints = try values.decode([AssemblyJoint].self, forKey: .joints)
    }

    func validate(parts: [PartNode]) throws { _ = try graph(parts: parts) }

    /// The named driving joint keeps its requested position. Other joints in a
    /// closed mechanism may move to satisfy closure, using the supplied pose as
    /// a continuity hint. A failed solve never publishes a partial pose.
    func solve(parts: [PartNode], positions: [String: Double] = [:], driving: String? = nil) throws -> AssemblyPose {
        try Task.checkCancellation()
        let graph = try graph(parts: parts)
        let byID = Dictionary(uniqueKeysWithValues: joints.enumerated().map { ($0.element.id, $0.offset) })
        guard positions.keys.allSatisfy({ byID[$0] != nil }),
              driving == nil || byID[driving!].map({ joints[$0].isMovable }) == true else {
            throw LADError.message("The design's assembly pose refers to an unknown or fixed joint.")
        }
        var values = joints.map { positions[$0.id] ?? $0.position }
        for (index, joint) in joints.enumerated() {
            guard values[index].isFinite, abs(values[index]) <= 1e9,
                  joint.type != .fixed || abs(values[index]) <= 1e-12,
                  joint.limits.map({ values[index] >= $0[0] && values[index] <= $0[1] }) ?? true else {
                throw LADError.message("The position of \(joint.name) is outside its motion limits.")
            }
        }
        let free = joints.indices.filter {
            joints[$0].isMovable && joints[$0].id != driving && graph.closureVariables.contains($0)
                && !(joints[$0].limits.map { $0[0] == $0[1] } ?? false)
        }
        let factors = free.map { joints[$0].type == .revolute ? 180 / Double.pi : graph.scale }
        var x = zip(free, factors).map { values[$0.0] / $0.1 }
        let lower = zip(free, factors).map { index, factor in joints[index].limits.map { $0[0] / factor } ?? -.infinity }
        let upper = zip(free, factors).map { index, factor in joints[index].limits.map { $0[1] / factor } ?? .infinity }

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

    private func closureError(_ driving: String?) -> LADError {
        let joint = driving.flatMap { id in joints.first { $0.id == id } }
        return .message(joint.map { "The design cannot reach this position of \($0.name) within its joint constraints and motion limits." }
            ?? "The design's assembly constraints cannot be satisfied within its motion limits.")
    }

    private struct Arc {
        var joint: Int
        var from: String
        var to: String
        var forward: Bool
    }

    private struct Graph {
        var solids: [String: Set<Int>]
        var frames: [String: simd_double4x4]
        var connectorParts: [String: String]
        var anchors: [String]
        var tree: [Arc]
        var closures: [Int]
        /// Only joints on closure paths can affect the nonlinear residual.
        var closureVariables: Set<Int>
        var scale: Double

        func evaluate(joints: [AssemblyJoint], positions: [Double]) -> (poses: [String: simd_double4x4], residual: [Double]) {
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
        var closureVariables = Set<Int>()
        for index in closures {
            let joint = joints[index]
            let a = paths[connectorParts[joint.parent]!] ?? [], b = paths[connectorParts[joint.child]!] ?? []
            // A common prefix moves the entire loop rigidly and cancels from
            // the closure equation. Unrelated open chains also remain direct.
            closureVariables.formUnion(a.symmetricDifference(b))
            closureVariables.insert(index)
        }
        return Graph(solids: solids, frames: frames, connectorParts: connectorParts, anchors: anchors, tree: tree,
                     closures: closures, closureVariables: closureVariables, scale: scale)
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
