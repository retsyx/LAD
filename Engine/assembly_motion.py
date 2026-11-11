"""Validated rigid assembly definitions and exact native pose transforms.

The construction program owns the definition. Pose solving and playback belong
to the native app; this module never reconstructs or approximates CAD geometry.
"""
import math


MAX_CONNECTORS = 1024
MAX_JOINTS = 256
MAX_PARTS = 8192
MAX_GROUNDED = 4096
AXIS_TOLERANCE = 1e-6


class AssemblyMotionError(ValueError):
    pass


def _fail(message):
    raise AssemblyMotionError(message)


def _identifier(value, label):
    if (not isinstance(value, str) or not value.strip()
            or len(value.encode("utf-8")) > 1024
            or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)):
        _fail(f"The assembly {label} must be a nonempty identifier.")
    return value


def _number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(f"The assembly {label} must be finite.")
    try:
        result = float(value)
    except (OverflowError, ValueError):
        _fail(f"The assembly {label} must be finite.")
    if not math.isfinite(result):
        _fail(f"The assembly {label} must be finite.")
    return result


def _vector(value, label):
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        _fail(f"The assembly {label} must contain three finite numbers.")
    return [_number(component, label) for component in value]


def _unit(value, label):
    vector = _vector(value, label)
    length = math.hypot(*vector)
    if not math.isfinite(length) or abs(length - 1) > AXIS_TOLERANCE:
        _fail(f"The assembly {label} must be a unit vector.")
    return [component / length for component in vector]


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _cross(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def validate_motion(definition, parts):
    """Return a detached, normalized definition over physical leaf part IDs.

    Connector frames are expressed in the final built geometry's world space,
    including every CadQuery Assembly location. Closed joint loops are allowed;
    each participating component needs a grounded part. The app solves poses.
    """
    if not isinstance(definition, dict) or set(definition) != {"grounded", "connectors", "joints"}:
        _fail("Assembly motion requires grounded parts, connectors and joints.")
    physical, pending, count = set(), list(parts), 0
    while pending:
        part = pending.pop()
        count += 1
        if count > MAX_PARTS:
            _fail("The moving assembly contains too many parts.")
        if part.get("children") is None and len(part.get("solidIndices", [])) == 1:
            physical.add(part["id"])
        pending.extend(part.get("children") or [])
    grounded = definition["grounded"]
    if not isinstance(grounded, (list, tuple)) or len(grounded) > MAX_GROUNDED:
        _fail("The moving assembly grounded-part list is invalid or too large.")
    anchors = set()
    for part in grounded:
        _identifier(part, "grounded part")
        if part not in physical or part in anchors:
            _fail("Grounded assembly parts must be distinct physical part IDs.")
        anchors.add(part)

    connectors = definition["connectors"]
    if not isinstance(connectors, (list, tuple)) or len(connectors) > MAX_CONNECTORS:
        _fail("The assembly connector list is invalid or too large.")
    frames, normalized_connectors = {}, []
    for connector in connectors:
        if (not isinstance(connector, dict)
                or not {"id", "part", "origin"} <= set(connector)
                or set(connector) - {"id", "part", "origin", "xAxis", "zAxis"}):
            _fail("Each assembly connector requires an ID, a physical part and a coordinate frame.")
        identity = _identifier(connector["id"], "connector ID")
        part = _identifier(connector["part"], "connector part")
        if identity in frames or part not in physical:
            _fail("Assembly connector IDs must be unique and reference physical parts.")
        origin = _vector(connector["origin"], "connector origin")
        if any(abs(value) > 1e9 for value in origin):
            _fail("Assembly connector origins exceed the supported coordinate range.")
        x = _unit(connector.get("xAxis", [1, 0, 0]), "connector X axis")
        z = _unit(connector.get("zAxis", [0, 0, 1]), "connector Z axis")
        if abs(_dot(x, z)) > AXIS_TOLERANCE:
            _fail("Assembly connector X and Z axes must be perpendicular.")
        # Remove accepted floating-point drift while retaining a right-handed
        # X/Y/Z frame. This is coordinate metadata, never a geometric repair.
        y = _cross(z, x)
        length = math.hypot(*y)
        y = [component / length for component in y]
        x = _cross(y, z)
        normalized = {"id": identity, "part": part, "origin": origin, "xAxis": x, "zAxis": z}
        frames[identity] = normalized
        normalized_connectors.append(normalized)

    joints = definition["joints"]
    if not isinstance(joints, (list, tuple)) or len(joints) > MAX_JOINTS:
        _fail("The assembly joint list is invalid or exceeds 256 joints.")
    joint_ids, adjacency, normalized_joints = set(), {}, []
    for joint in joints:
        if (not isinstance(joint, dict) or not {"id", "type", "parent", "child"} <= set(joint)
                or set(joint) - {"id", "name", "type", "parent", "child", "position", "limits"}):
            _fail("Each assembly joint requires an ID, type and two connectors.")
        identity = _identifier(joint["id"], "joint ID")
        if identity in joint_ids:
            _fail("Assembly joint IDs must be unique.")
        joint_ids.add(identity)
        name = joint.get("name", identity)
        if (not isinstance(name, str) or not name.strip() or len(name) > 160
                or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in name)):
            _fail("Assembly joint names must contain between 1 and 160 visible characters.")
        kind = joint["type"]
        if kind not in ("fixed", "revolute", "slider"):
            _fail("Assembly joints support fixed, revolute and slider motion.")
        parent = _identifier(joint["parent"], "parent connector")
        child = _identifier(joint["child"], "child connector")
        if parent not in frames or child not in frames:
            _fail("Assembly joints must reference existing connectors.")
        a, b = frames[parent]["part"], frames[child]["part"]
        if a == b:
            _fail("An assembly joint must connect two different physical parts.")
        adjacency.setdefault(a, set()).add(b)
        adjacency.setdefault(b, set()).add(a)
        position = _number(joint.get("position", 0), "joint position")
        if abs(position) > 1e9:
            _fail("The assembly joint position exceeds the supported range.")
        normalized = {"id": identity, "name": name, "type": kind,
                      "parent": parent, "child": child, "position": position}
        if "limits" in joint:
            limits = joint["limits"]
            if not isinstance(limits, (list, tuple)) or len(limits) != 2:
                _fail("Assembly joint limits require a lower and upper value.")
            lower, upper = [_number(value, "joint limit") for value in limits]
            if max(abs(lower), abs(upper)) > 1e9 or lower > upper or not lower <= position <= upper:
                _fail("Assembly joint limits must contain the initial position.")
            normalized["limits"] = [lower, upper]
        if kind == "fixed" and (position != 0 or "limits" in joint):
            _fail("Fixed assembly joints cannot have a position or limits.")
        normalized_joints.append(normalized)

    visited = set()
    for part in adjacency:
        if part in visited:
            continue
        component, pending = set(), [part]
        while pending:
            current = pending.pop()
            if current not in component:
                component.add(current)
                pending.extend(adjacency[current] - component)
        if not component.intersection(anchors):
            _fail("Every moving assembly component requires a grounded physical part.")
        visited.update(component)
    return {"grounded": list(grounded), "connectors": normalized_connectors, "joints": normalized_joints}


def transformed_solids(solids, records, cq):
    """Apply validated world-space rigid deltas, preserving native topology order.

    Matrices are row-major 4x4, acting on column position vectors. Missing solid
    indices retain their built poses. Validate the complete request before
    touching native geometry; no scaling, reflections or affine shear is allowed.
    """
    if not isinstance(records, list) or len(records) > len(solids):
        _fail("Assembly poses require a list of uniquely indexed rigid transforms.")
    poses = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"solid", "matrix"}:
            _fail("Each assembly pose requires a solid index and a rigid matrix.")
        index = record["solid"]
        if (isinstance(index, bool) or not isinstance(index, int)
                or not 0 <= index < len(solids) or index in poses):
            _fail("Assembly poses contain invalid or duplicate solid indices.")
        matrix = record["matrix"]
        if not isinstance(matrix, list) or len(matrix) != 16:
            _fail("Assembly pose matrices require 16 row-major values.")
        matrix = [_number(value, "pose matrix") for value in matrix]
        if any(abs(value) > 1e9 for value in matrix):
            _fail("The assembly pose exceeds the supported coordinate range.")
        if any(abs(a - b) > 1e-9 for a, b in zip(matrix[12:], [0, 0, 0, 1])):
            _fail("Assembly pose matrices must be affine rigid transforms.")
        rows = [matrix[offset:offset + 3] for offset in (0, 4, 8)]
        if (any(abs(_dot(row, row) - 1) > AXIS_TOLERANCE for row in rows)
                or any(abs(_dot(rows[a], rows[b])) > AXIS_TOLERANCE for a, b in ((0, 1), (0, 2), (1, 2)))
                or abs(_dot(rows[0], _cross(rows[1], rows[2])) - 1) > AXIS_TOLERANCE):
            _fail("Assembly pose matrices must contain a proper rotation without scale, shear or reflection.")
        poses[index] = matrix
    if not poses:
        return list(solids)
    from OCP.gp import gp_Trsf
    result = list(solids)
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    for index, matrix in poses.items():
        if matrix == identity:
            continue
        transform = gp_Trsf()
        transform.SetValues(*matrix[:12])
        result[index] = solids[index].moved(cq.Location(transform))
    return result
