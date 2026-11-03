"""Compile reversible reconstruction edits into complete ordinary CAD programs.

This module never executes a candidate or imports CadQuery.  The caller runs
``script`` in LAD's normal isolated worker, applies native/STEP validity gates,
then stores the resulting immutable preview.  A complete Python source snapshot
is the construction record.  There is no feature-node graph interpreter or
serialized geometry cache.  Fitted geometry is realized only by explicit typed
append operations; completion and final distance acceptance are separate.
"""
from __future__ import annotations

import ast
import copy
import inspect
import math


VERSION = 'program-edits-1'
_PARAMETER_NAME = '_lad_recon_parameters'
_MARKER = '# LAD complete reconstruction program: program-edits-1'
_MAX_SCRIPT_BYTES = 200_000  # Same complete-source limit as worker.validate_spec.


class EditError(ValueError):
    def __init__(self, code, message, **details):
        super().__init__(message)
        self.code, self.details = code, details


def _fail(code, message, **details):
    raise EditError(code, message, **details)


def _identity(value, name):
    if (not isinstance(value, str) or not 1 <= len(value) <= 200 or
            any(not character.isprintable() for character in value)):
        _fail('INVALID_EDIT', f'{name} must be a printable semantic ID of at most 200 characters')
    return value


def _plain_number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        _fail('INVALID_EDIT', f'{name} must be finite')
    return float(value)


def _resolved(value, state):
    if isinstance(value, dict) and set(value) == {'parameter'}:
        return state['parameter_bindings'][value['parameter']]['value']
    return value


def _number(value, name, state, *, positive=False, nonnegative=False):
    if isinstance(value, dict):
        if set(value) - {'parameter', 'value', 'min', 'max', 'fixed'} or 'parameter' not in value:
            _fail('INVALID_EDIT', f'{name} has an invalid explicit parameter binding')
        key = _identity(value['parameter'], 'parameter')
        bindings = state['parameter_bindings']
        if key not in bindings:
            if 'value' not in value:
                _fail('UNKNOWN_PARAMETER', 'A new parameter binding requires its initial value', parameter=key)
            entry = {'value': _plain_number(value['value'], name), 'requirements': [], 'fixed': value.get('fixed', False)}
            if not isinstance(entry['fixed'], bool):
                _fail('INVALID_EDIT', 'Parameter fixed flag must be boolean', parameter=key)
            for bound in ('min', 'max'):
                if bound in value:
                    entry[bound] = _plain_number(value[bound], bound)
            bindings[key] = entry
        entry = bindings[key]
        for field in ('value', 'min', 'max', 'fixed'):
            if field in value and value[field] != entry.get(field):
                _fail('STALE_PARAMETER', 'Use update_parameters to change an existing explicit binding', parameter=key)
        requirement = 'positive' if positive else 'nonnegative' if nonnegative else 'finite'
        if requirement not in entry['requirements']:
            entry['requirements'].append(requirement)
        _check_parameter(key, entry)
        return {'parameter': key}
    result = _plain_number(value, name)
    if positive and result <= 0 or nonnegative and result < 0:
        _fail('INVALID_EDIT', f'{name} has an invalid magnitude')
    return result


def _check_parameter(key, entry):
    value = _plain_number(entry['value'], key)
    if ('positive' in entry['requirements'] and value <= 0 or
            'nonnegative' in entry['requirements'] and value < 0 or
            'min' in entry and value < entry['min'] or
            'max' in entry and value > entry['max'] or
            'min' in entry and 'max' in entry and entry['min'] > entry['max']):
        _fail('CONSTRAINT_CONFLICT', 'Parameter violates its explicit domain', parameter=key)


def _vector(value, name, state, *, count=3, direction=False):
    if not isinstance(value, (list, tuple)) or len(value) != count:
        _fail('INVALID_EDIT', f'{name} must contain {count} coordinates')
    result = [_number(v, name, state) for v in value]
    if direction and sum(_resolved(v, state)**2 for v in result) <= 1e-24:
        _fail('INVALID_EDIT', f'{name} must be nonzero')
    return result


def _frame_check(x, z, state):
    x, z = [[_resolved(v, state) for v in vector] for vector in (x, z)]
    cross = [x[1]*z[2]-x[2]*z[1], x[2]*z[0]-x[0]*z[2], x[0]*z[1]-x[1]*z[0]]
    if sum(v*v for v in cross) <= 1e-20 * sum(v*v for v in x) * sum(v*v for v in z):
        _fail('INVALID_EDIT', 'Frame directions must be independent')


def _py(value):
    """Generate expressions from normalized data, never from caller text."""
    if isinstance(value, dict) and set(value) == {'parameter'}:
        return f'{_PARAMETER_NAME}[{value["parameter"]!r}]'
    if isinstance(value, dict):
        return '{' + ', '.join(f'{k!r}: {_py(v)}' for k, v in value.items()) + '}'
    if isinstance(value, (list, tuple)):
        return '[' + ', '.join(_py(v) for v in value) + ']'
    return repr(value)


def _lad_recon_shape(value):
    from OCP.TopoDS import TopoDS_Shape
    if isinstance(value, TopoDS_Shape):
        return cq.Shape.cast(value)
    if isinstance(value, cq.Assembly):
        return value.toCompound()
    if isinstance(value, cq.Workplane):
        values = value.vals()
        if not values or any(not isinstance(item, cq.Shape) for item in values):
            raise ValueError('[INVALID_BODY] Workplane must contain CAD shapes')
        return values[0] if len(values) == 1 else cq.Compound.makeCompound(values)
    if not isinstance(value, cq.Shape):
        raise ValueError('[INVALID_BODY] Expected a CadQuery/OCP shape')
    return value


def _lad_recon_one(value, body_id):
    from OCP.TopAbs import TopAbs_COMPOUND, TopAbs_COMPSOLID, TopAbs_SOLID
    from OCP.TopoDS import TopoDS_Iterator
    shape = _lad_recon_shape(value)
    def only_solids(native):
        if native.ShapeType() == TopAbs_SOLID:
            return True
        if native.ShapeType() not in (TopAbs_COMPOUND, TopAbs_COMPSOLID):
            return False
        children = TopoDS_Iterator(native)
        found = False
        while children.More():
            found = True
            if not only_solids(children.Value()):
                return False
            children.Next()
        return found
    if shape.isNull() or not only_solids(shape.wrapped) or len(shape.Solids()) != 1:
        raise ValueError(f'[INVALID_BODY] {body_id}: operation must produce one closed physical solid; automatic split rebinding is unavailable')
    return shape.Solids()[0]


def _lad_recon_axis(axis):
    vector = cq.Vector(*axis)
    if not all(math.isfinite(v) for v in axis) or vector.Length <= 1e-12:
        raise ValueError('[INVALID_EDIT] Invalid direction after parameter regeneration')
    return vector.normalized()


def _lad_recon_interval(origin, axis, extent, target=None):
    mode = extent['mode']
    if mode == 'bounded':
        low, high = extent['interval']
    elif mode == 'depth':
        low = extent.get('start', 0)
        high = low + extent['depth']
    elif mode == 'through_all':
        if target is None:
            raise ValueError('[INVALID_EDIT] through_all requires a target body')
        from OCP.Bnd import Bnd_Box
        from OCP.BRepBndLib import BRepBndLib
        box = Bnd_Box()
        BRepBndLib.AddOptimal_s(target.wrapped, box, False, True)
        x0, y0, z0, x1, y1, z1 = box.Get()
        o, a = cq.Vector(*origin), _lad_recon_axis(axis)
        projections = [(cq.Vector(x, y, z)-o).dot(a)
                       for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]
        diagonal = math.sqrt((x1-x0)**2+(y1-y0)**2+(z1-z0)**2)
        margin = extent.get('margin', max(1e-5, diagonal * 1e-5))
        if not math.isfinite(margin) or margin <= 0:
            raise ValueError('[INVALID_EDIT] through_all margin must be positive')
        low, high = min(projections)-margin, max(projections)+margin
    else:
        raise ValueError('[UNSUPPORTED_OPERATION] Unsupported finite extent')
    if not all(math.isfinite(v) for v in (low, high)) or high <= low:
        raise ValueError('[INVALID_EDIT] Finite extent is empty or reversed')
    return low, high


def _lad_recon_cylinder(origin, axis, radius, extent, target=None):
    low, high = _lad_recon_interval(origin, axis, extent, target)
    direction = _lad_recon_axis(axis)
    return cq.Solid.makeCylinder(radius, high-low, cq.Vector(*origin)+direction*low, direction)


def _lad_recon_cone(origin, axis, radius, slope, extent, target=None):
    low, high = _lad_recon_interval(origin, axis, extent, target)
    r0, r1 = radius+slope*low, radius+slope*high
    if min(r0, r1) < 0 or max(r0, r1) <= 0:
        raise ValueError('[INVALID_EDIT] Cone extent crosses an unsupported nappe/apex')
    direction = _lad_recon_axis(axis)
    return cq.Solid.makeCone(r0, r1, high-low, cq.Vector(*origin)+direction*low, direction)


def _lad_recon_box(origin, x_direction, z_direction, size):
    if min(size) <= 0:
        raise ValueError('[INVALID_EDIT] Box dimensions must remain positive')
    plane = cq.Plane(origin=tuple(origin), xDir=tuple(x_direction), normal=tuple(z_direction))
    return cq.Solid.makeBox(*size).located(plane.location)


def _lad_recon_torus(center, axis, major_radius, minor_radius):
    if (not all(math.isfinite(v) for v in (major_radius, minor_radius)) or
            not 0 < minor_radius < major_radius):
        raise ValueError('[INVALID_EDIT] Ring torus requires 0 < minor radius < major radius')
    return cq.Solid.makeTorus(major_radius, minor_radius, cq.Vector(*center), _lad_recon_axis(axis))


def _lad_recon_spherical_shell(center, outer_radius, inner_radius):
    if (not all(math.isfinite(v) for v in (outer_radius, inner_radius)) or
            not 0 < inner_radius < outer_radius):
        raise ValueError('[INVALID_EDIT] Spherical shell requires 0 < inner radius < outer radius')
    origin = cq.Vector(*center)
    outer = cq.Solid.makeSphere(outer_radius, origin, angleDegrees1=-90, angleDegrees2=90)
    inner = cq.Solid.makeSphere(inner_radius, origin, angleDegrees1=-90, angleDegrees2=90)
    return outer.cut(inner)


def _lad_recon_wire(loop, plane):
    def point(values):
        return plane.toWorldCoords(tuple(values))
    if 'points' in loop:
        return cq.Wire.makePolygon([point(p) for p in loop['points']], close=True)
    edges = []
    for segment in loop['segments']:
        a, b = point(segment['start']), point(segment['end'])
        if segment['kind'] == 'line':
            edges.append(cq.Edge.makeLine(a, b))
        else:
            edges.append(cq.Edge.makeThreePointArc(a, point(segment['mid']), b))
    return cq.Wire.assembleEdges(edges)


def _lad_recon_extrude(profile, direction, extent, target=None):
    plane = cq.Plane(origin=tuple(profile['origin']), xDir=tuple(profile['x_direction']), normal=tuple(profile['normal']))
    axis = _lad_recon_axis(direction)
    if abs(axis.dot(plane.zDir)) <= 1e-12:
        raise ValueError('[INVALID_PROFILE] Extrusion direction lies in the profile plane')
    low, high = _lad_recon_interval(profile['origin'], direction, extent, target)
    wires = [_lad_recon_wire(loop, plane).translate(axis*low) for loop in profile['loops']]
    return cq.Solid.extrudeLinear(wires[0], wires[1:], axis*(high-low))


def _lad_recon_revolve(profile, origin, axis, x_direction, angle):
    if not math.isfinite(angle) or not 0 < angle <= 360:
        raise ValueError('[INVALID_EDIT] Revolution angle must lie in (0,360]')
    direction = _lad_recon_axis(axis)
    x = cq.Vector(*x_direction)
    plane = cq.Plane(origin=tuple(origin), xDir=x.toTuple(), normal=x.cross(direction).toTuple())
    wires = [_lad_recon_wire(loop, plane) for loop in profile['loops']]
    start = cq.Vector(*origin)
    return cq.Solid.revolve(wires[0], wires[1:], angle, start, start+direction)


def _lad_recon_helical_sweep(origin, axis, x_direction, pitch, handedness, phase_degrees, profile, extent):
    if extent.get('mode') not in ('bounded', 'depth'):
        raise ValueError('[INVALID_EDIT] Helical sweep requires an explicit finite extent')
    if not math.isfinite(pitch) or pitch <= 0 or not math.isfinite(phase_degrees):
        raise ValueError('[INVALID_EDIT] Helical pitch must remain positive and phase finite')
    if handedness not in ('left', 'right'):
        raise ValueError('[INVALID_EDIT] Helical handedness must be left or right')
    if (profile['origin'] != [0, 0, 0] or profile['normal'] != [0, 0, 1] or
            profile['x_direction'] != [1, 0, 0] or len(profile['loops']) != 1 or
            'points' not in profile['loops'][0] or not profile['loops'][0]['closed']):
        raise ValueError('[INVALID_PROFILE] Helical profile must be one closed polygon in radius/axial-phase coordinates')
    points = profile['loops'][0]['points']
    radial = [p[0] for p in points]
    axial = [p[1] for p in points]
    if (not all(math.isfinite(v) for p in points for v in p) or min(radial) <= 0 or
            max(axial)-min(axial) >= pitch):
        raise ValueError('[INVALID_PROFILE] Helical profile requires positive radii and axial span below one pitch')
    low, high = _lad_recon_interval(origin, axis, extent)
    # Keep the screw phase anchored at the original datum. Translating a
    # zero-based sweep to a nonintegral low coordinate rotates the flank.
    first_turn = (low-max(axial)-pitch)/pitch
    last_turn = (high-min(axial)+pitch)/pitch
    if (not all(math.isfinite(v) for v in (first_turn, last_turn)) or
            math.ceil(last_turn)-math.floor(first_turn) > 128):
        raise ValueError('[RESOURCE_LIMIT] Helical sweep exceeds 128 generated turns including clipping overrun')
    start, stop = math.floor(first_turn)*pitch, math.ceil(last_turn)*pitch
    if not all(math.isfinite(v) for v in (start, stop)) or stop <= start:
        raise ValueError('[INVALID_EDIT] Helical sweep interval is unresolved at the working precision')
    radius = (min(radial)+max(radial))/2
    path = cq.Wire.makeHelix(pitch, stop-start, radius, center=(0, 0, start), lefthand=handedness == 'left')
    plane = cq.Plane(origin=(0, 0, start), xDir=(1, 0, 0), normal=(0, -1, 0))
    wire = cq.Wire.makePolygon([plane.toWorldCoords(tuple(p)) for p in points], close=True)
    swept = cq.Solid.sweep(wire, [], path, makeSolid=True, isFrenet=True)
    bound = max(radial)+pitch+high-low
    slab = cq.Solid.makeBox(2*bound, 2*bound, high-low, (-bound, -bound, low))
    result = swept.intersect(slab)
    if phase_degrees:
        result = result.rotate((0, 0, 0), (0, 0, 1), phase_degrees)
    frame = cq.Plane(origin=tuple(origin), xDir=tuple(x_direction), normal=_lad_recon_axis(axis).toTuple())
    result = result.located(frame.location)
    # Rebuild coherent curve/pcurve parameterizations after the native pipe
    # and trim operations. No edge tolerance is manually enlarged.
    from OCP.BRepLib import BRepLib
    BRepLib.SameParameter_s(result.wrapped, 1e-7, True)
    return result


def _lad_recon_fillet(shape, radius, anchors, body_id):
    solid = _lad_recon_one(shape, body_id)
    edges, chosen = solid.Edges(), []
    for anchor in anchors:
        point = cq.Vertex.makeVertex(*anchor['point'])
        candidates = []
        for edge in edges:
            if edge.distance(point) > anchor['max_distance']:
                continue
            required = anchor.get('adjacent_surfaces')
            if required:
                actual = sorted(face.geomType().lower() for face in solid.Faces()
                                if any(edge.isSame(fe) for fe in face.Edges()))
                if actual != sorted(required):
                    continue
            candidates.append(edge)
        if len(candidates) != 1:
            raise ValueError('[AMBIGUOUS_REBIND] Fillet anchor must resolve exactly one edge; refine location/adjacency')
        if not any(candidates[0].isSame(edge) for edge in chosen):
            chosen.append(candidates[0])
    return solid.fillet(radius, chosen)


def _lad_recon_result(bodies):
    assembly = cq.Assembly(name='Reconstruction')
    for body_id, shape in bodies.items():
        assembly.add(_lad_recon_one(shape, body_id), name=body_id, metadata={'lad_id': body_id})
    return assembly


_HELPERS = (_lad_recon_shape, _lad_recon_one, _lad_recon_axis, _lad_recon_interval,
            _lad_recon_cylinder, _lad_recon_cone, _lad_recon_box, _lad_recon_torus,
            _lad_recon_spherical_shell, _lad_recon_wire, _lad_recon_extrude,
            _lad_recon_revolve, _lad_recon_helical_sweep, _lad_recon_fillet, _lad_recon_result)


def _header(state):
    values = {key: entry['value'] for key, entry in state['parameter_bindings'].items()}
    return (_MARKER + '\nimport cadquery as cq\nimport math\n' +
            f'{_PARAMETER_NAME} = {values!r}\n\n' +
            '\n\n'.join(inspect.getsource(fn) for fn in _HELPERS) +
            '\n\n_lad_recon_bodies = {}\n')


def _seed(program, state):
    values = {key: entry['value'] for key, entry in state['parameter_bindings'].items()}
    try:
        tree = ast.parse(program)
    except SyntaxError as error:
        _fail('INVALID_PROGRAM', 'Complete CAD program is not valid Python', line=error.lineno)
    nodes = [node for node in tree.body if isinstance(node, ast.Assign) and
             any(isinstance(target, ast.Name) and target.id == _PARAMETER_NAME for target in node.targets)]
    if len(nodes) != 1:
        _fail('STALE_DEPENDENCY', 'Explicit generated parameter seed is missing or ambiguous')
    node = nodes[0]
    lines = program.splitlines(keepends=True)
    lines[node.lineno-1:node.end_lineno] = [f'{_PARAMETER_NAME} = {values!r}\n']
    return ''.join(lines)


def _state(revision):
    raw = revision.get('state', revision)
    ids = raw.get('body_ids')
    if ids is None:
        bodies = raw.get('bodies', [])
        ids = list(bodies) if isinstance(bodies, dict) else [b.get('id') if isinstance(b, dict) else b for b in bodies]
    ids = [_identity(v, 'body ID') for v in ids]
    if len(ids) != len(set(ids)):
        _fail('AMBIGUOUS_ENTITY', 'Base body IDs are duplicated')
    return {'body_ids': ids, 'constructions': copy.deepcopy(raw.get('constructions', {})),
            'parameter_bindings': copy.deepcopy(raw.get('parameter_bindings', {})),
            'constraints': copy.deepcopy(raw.get('constraints', [])),
            'active_invariants': copy.deepcopy(raw.get('active_invariants', [])),
            'completion_obligations': copy.deepcopy(raw.get('completion_obligations', [])),
            'features': copy.deepcopy(raw.get('features', {})),
            'generated_program': bool(raw.get('generated_program', False))}


def _profile(value, state, *, radial=False, allow_open=False):
    if not isinstance(value, dict):
        _fail('INVALID_PROFILE', 'A profile requires an explicit frame and closed loops')
    result = {'origin': _vector(value.get('origin', [0, 0, 0]), 'profile origin', state),
              'normal': _vector(value.get('normal', [0, 0, 1]), 'profile normal', state, direction=True),
              'x_direction': _vector(value.get('x_direction', [1, 0, 0]), 'profile x direction', state, direction=True)}
    _frame_check(result['x_direction'], result['normal'], state)
    loops = value.get('loops')
    if not isinstance(loops, list) or not 1 <= len(loops) <= 64:
        _fail('INVALID_PROFILE', 'A profile requires one outer loop and up to 63 holes')
    if not allow_open and len(loops) > 1 and any(isinstance(loop, dict) and 'role' in loop for loop in loops):
        if any(not isinstance(loop, dict) or loop.get('role') not in ('outer', 'hole') for loop in loops):
            _fail('AMBIGUOUS_REBIND', 'Choose outer/hole roles for every profile loop before solid realization')
        if sum(loop['role'] == 'outer' for loop in loops) != 1:
            _fail('AMBIGUOUS_REBIND', 'One solid profile requires exactly one outer loop')
        loops = sorted(loops, key=lambda loop: loop['role'] != 'outer')
    result['loops'] = []
    for index, loop in enumerate(loops):
        if (not isinstance(loop, dict) or not isinstance(loop.get('closed'), bool) or
                not allow_open and loop['closed'] is not True):
            _fail('INVALID_PROFILE', 'Open evidence cannot silently become a closed profile', loop=index)
        if 'points' in loop:
            if not isinstance(loop['points'], list) or not (3 if loop['closed'] else 2) <= len(loop['points']) <= 1024:
                _fail('INVALID_PROFILE', 'Polygon profile point budget exceeded or insufficient')
            points = [_vector(p, 'profile point', state, count=2) for p in loop['points']]
            item = {'closed': loop['closed'], 'points': points}
        else:
            segments = loop.get('segments')
            if not isinstance(segments, list) or not 1 <= len(segments) <= 1024:
                _fail('INVALID_PROFILE', 'Profile requires bounded line/arc segments')
            normalized = []
            for segment in segments:
                if not isinstance(segment, dict) or segment.get('kind') not in ('line', 'arc'):
                    _fail('UNSUPPORTED_OPERATION', 'Only analytic line/arc profiles are supported')
                kind = segment['kind']
                item = {'kind': kind}
                for key in ('start', 'end', *(['mid'] if kind == 'arc' else [])):
                    item[key] = _vector(segment.get(key), 'profile '+key, state, count=2)
                normalized.append(item)
            following = normalized[1:] + (normalized[:1] if loop['closed'] else [])
            for a, b in zip(normalized, following):
                if [_resolved(v, state) for v in a['end']] != [_resolved(v, state) for v in b['start']]:
                    _fail('INVALID_PROFILE', 'Profile segment endpoints do not close exactly')
            points = [p for segment in normalized for p in (segment['start'], segment['end'], *([segment['mid']] if segment['kind'] == 'arc' else []))]
            item = {'closed': loop['closed'], 'segments': normalized}
        if radial and any(_resolved(p[0], state) < 0 for p in points):
            _fail('INVALID_PROFILE', 'Revolution profile cannot cross the axis')
        if 'role' in loop:
            item['role'] = loop['role']
        result['loops'].append(item)
    return result


def _fit_tool(tool, resolve_fit):
    if not isinstance(tool, dict):
        _fail('INVALID_EDIT', 'An explicit construction tool is required')
    if 'fit_candidate' not in tool:
        geometry = tool.get('geometry')
        family = tool.get('family', tool.get('realization'))
        if not isinstance(geometry, dict) or not isinstance(family, str):
            _fail('INVALID_EDIT', 'Tool requires family and geometry, or a fitted candidate reference')
        return family, copy.deepcopy(geometry), None, []
    identity = _identity(tool['fit_candidate'], 'fit candidate')
    member_id = tool.get('member_id')
    if member_id is not None:
        _identity(member_id, 'fit member')
    if resolve_fit is None:
        _fail('STALE_DEPENDENCY', 'Fit candidate resolver is unavailable', fit_candidate=identity)
    candidate = resolve_fit(identity, member_id)
    if not isinstance(candidate, dict):
        _fail('STALE_DEPENDENCY', 'Fit resolver returned no immutable candidate', fit_candidate=identity)
    if 'members' in candidate:
        if candidate.get('id') != identity:
            _fail('STALE_DEPENDENCY', 'Fit resolver returned a different candidate identity')
        members = candidate['members']
        matches = [m for m in members if member_id is None or m.get('id') == member_id]
        if len(matches) != 1:
            _fail('AMBIGUOUS_REBIND', 'A joint candidate requires a unique explicit member', fit_candidate=identity)
        member = matches[0]
    else:
        member = candidate
        if member_id is not None and member.get('id') != member_id:
            _fail('STALE_DEPENDENCY', 'Fit resolver returned a different member identity')
    family = member.get('family', candidate.get('family'))
    geometry = member.get('geometry')
    if not isinstance(geometry, dict) or not isinstance(family, str):
        _fail('INVALID_EDIT', 'Fitted member has no supported geometry')
    provenance = {'fit_candidate': identity, 'member_id': member.get('id'),
                  'evidence_ids': copy.deepcopy(candidate.get('evidence_ids', [])),
                  'dependency_fingerprint': candidate.get('dependency_fingerprint')}
    return family, copy.deepcopy(geometry), provenance, copy.deepcopy(member.get('observed_extent', candidate.get('observed_extent')) or [])


def _extent(tool, geometry, observed, state, *, through_allowed):
    extent = copy.deepcopy(tool.get('extent'))
    if extent is None and 'height' in geometry:
        extent = {'mode': 'depth', 'depth': geometry['height']}
    if not isinstance(extent, dict):
        _fail('INSUFFICIENT_EVIDENCE', 'Choose an explicit bounded, depth, observed, or through_all construction extent')
    mode = extent.get('mode')
    if mode == 'observed':
        interval = observed.get('axial_interval', observed.get('interval')) if isinstance(observed, dict) else observed
        if not isinstance(interval, (list, tuple)) or len(interval) != 2:
            interval = geometry.get('observed_interval')
        if not isinstance(interval, (list, tuple)) or len(interval) != 2:
            _fail('INSUFFICIENT_EVIDENCE', 'The selected fit has no finite observed axial interval')
        extent = {'mode': 'bounded', 'interval': interval}
        mode = 'bounded'
    if mode == 'bounded':
        interval = extent.get('interval')
        if not isinstance(interval, (list, tuple)) or len(interval) != 2:
            _fail('INVALID_EDIT', 'Bounded extent requires two axial coordinates')
        values = [_number(v, 'extent', state) for v in interval]
        if _resolved(values[1], state) <= _resolved(values[0], state):
            _fail('INVALID_EDIT', 'Bounded extent must be increasing')
        return {'mode': 'bounded', 'interval': values}
    if mode == 'depth':
        return {'mode': 'depth', 'start': _number(extent.get('start', 0), 'extent start', state),
                'depth': _number(extent.get('depth'), 'extent depth', state, positive=True)}
    if mode == 'through_all':
        if not through_allowed:
            _fail('INVALID_EDIT', 'through_all requires an existing cut/intersection target')
        result = {'mode': 'through_all'}
        if 'margin' in extent:
            result['margin'] = _number(extent['margin'], 'construction margin', state, positive=True)
        return result
    _fail('UNSUPPORTED_OPERATION', 'Unsupported construction extent', mode=mode)


def _operand(tool, state, resolve_fit, target, operation):
    family, geometry, provenance, observed = _fit_tool(tool, resolve_fit)
    family = tool.get('realization', family).lower()
    if 'loop_roles' in tool:
        profile_geometry = geometry.get('profile', geometry)
        loops = profile_geometry.get('loops')
        roles = tool['loop_roles']
        if (not isinstance(loops, list) or not isinstance(roles, list) or len(roles) != len(loops) or
                any(role not in ('outer', 'hole') for role in roles) or roles.count('outer') != 1):
            _fail('INVALID_PROFILE', 'Explicit loop_roles must identify one outer loop and remaining holes')
        for loop, role in zip(loops, roles):
            loop['role'] = role
    target_expr = f'_lad_recon_bodies[{target!r}]' if target else 'None'
    through = operation in ('cut', 'intersect') and target is not None
    vec = lambda key, default=None, direction=False: _vector(geometry.get(key, default), key, state, direction=direction)
    num = lambda key, positive=True: _number(geometry.get(key), key, state, positive=positive)
    extent = None
    if family == 'box':
        args = [vec('origin', [0, 0, 0]), vec('x_direction', [1, 0, 0], True), vec('z_direction', [0, 0, 1], True), _vector(geometry.get('size'), 'size', state)]
        if any(_resolved(v, state) <= 0 for v in args[-1]):
            _fail('INVALID_EDIT', 'Box dimensions must be positive')
        _frame_check(args[1], args[2], state)
        expression = '_lad_recon_box(' + ', '.join(_py(v) for v in args) + ')'
    elif family in ('cylinder', 'cone'):
        origin, axis = vec('origin'), vec('axis', direction=True)
        radius = _number(geometry.get('radius'), 'radius', state,
                         positive=family == 'cylinder', nonnegative=family == 'cone')
        extent = _extent(tool, geometry, observed, state, through_allowed=through)
        args = [origin, axis, radius]
        if family == 'cone':
            if 'slope' not in geometry:
                _fail('INVALID_EDIT', 'Cone realization requires its explicit fitted radial slope')
            args.append(num('slope', False))
        args.append(extent)
        expression = f'_lad_recon_{family}(' + ', '.join(_py(v) for v in args) + ', ' + target_expr + ')'
    elif family == 'sphere':
        expression = f'cq.Solid.makeSphere({_py(num("radius"))}, cq.Vector(*{_py(vec("center"))}), angleDegrees1=-90, angleDegrees2=90)'
    elif family == 'torus':
        if tool.get('extent') != {'mode': 'full'}:
            _fail('INSUFFICIENT_EVIDENCE', 'Choose extent mode full explicitly; observed torus support does not establish a complete ring')
        center, axis = vec('center'), vec('axis', direction=True)
        major, minor = num('major_radius'), num('minor_radius')
        if _resolved(minor, state) >= _resolved(major, state):
            _fail('INVALID_EDIT', 'Ring torus requires minor radius below major radius')
        extent = {'mode': 'full'}
        expression = f'_lad_recon_torus({_py(center)}, {_py(axis)}, {_py(major)}, {_py(minor)})'
    elif family == 'concentric_spherical_shell':
        if tool.get('material') != 'between_surfaces':
            _fail('INSUFFICIENT_EVIDENCE', 'Choose material between_surfaces explicitly before constructing the spherical shell')
        center = vec('center')
        outer, inner = num('outer_radius'), num('inner_radius')
        if _resolved(inner, state) >= _resolved(outer, state):
            _fail('INVALID_EDIT', 'Spherical shell requires inner radius below outer radius')
        expression = f'_lad_recon_spherical_shell({_py(center)}, {_py(outer)}, {_py(inner)})'
    elif family == 'helical_sweep':
        if 'extent' not in tool:
            _fail('INSUFFICIENT_EVIDENCE', 'Choose an explicit finite helical sweep extent')
        extent = _extent(tool, geometry, observed, state, through_allowed=False)
        origin, axis = vec('origin'), vec('axis', direction=True)
        x_direction = vec('x_direction', [1, 0, 0], True)
        _frame_check(x_direction, axis, state)
        pitch = num('pitch')
        handedness = geometry.get('handedness')
        if handedness not in ('left', 'right'):
            _fail('INVALID_EDIT', 'Helical handedness must be left or right')
        phase = _number(geometry.get('phase_degrees', 0), 'helical phase', state)
        profile = _profile(geometry.get('profile'), state, radial=True)
        if ([_resolved(v, state) for v in profile['origin']] != [0, 0, 0] or
                [_resolved(v, state) for v in profile['normal']] != [0, 0, 1] or
                [_resolved(v, state) for v in profile['x_direction']] != [1, 0, 0] or
                len(profile['loops']) != 1 or 'points' not in profile['loops'][0]):
            _fail('INVALID_PROFILE', 'Helical profile must be one closed polygon in radius/axial-phase coordinates')
        points = [[_resolved(v, state) for v in p] for p in profile['loops'][0]['points']]
        radial, axial = [p[0] for p in points], [p[1] for p in points]
        resolved_pitch = _resolved(pitch, state)
        if min(radial) <= 0 or max(axial)-min(axial) >= resolved_pitch:
            _fail('INVALID_PROFILE', 'Helical profile requires positive radii and axial span below one pitch')
        if extent['mode'] == 'bounded':
            low, high = [_resolved(v, state) for v in extent['interval']]
        else:
            low = _resolved(extent['start'], state)
            high = low+_resolved(extent['depth'], state)
        first, last = (low-max(axial)-resolved_pitch)/resolved_pitch, (high-min(axial)+resolved_pitch)/resolved_pitch
        if (not all(math.isfinite(v) for v in (first, last)) or math.ceil(last)-math.floor(first) > 128):
            _fail('RESOURCE_LIMIT', 'Helical sweep exceeds 128 generated turns including clipping overrun')
        expression = ('_lad_recon_helical_sweep(' + ', '.join(_py(v) for v in
                      (origin, axis, x_direction, pitch, handedness, phase, profile, extent)) + ')')
    elif family in ('profile', 'extrusion', 'rounded_rectangle_extrusion'):
        if family == 'rounded_rectangle_extrusion' and 'extent' not in tool:
            _fail('INSUFFICIENT_EVIDENCE', 'Choose an explicit rounded-profile construction extent')
        profile = _profile(geometry.get('profile', geometry), state)
        direction = _vector(geometry.get('direction', profile['normal']), 'extrusion direction', state, direction=True)
        extent = _extent(tool, geometry, observed, state, through_allowed=through)
        expression = f'_lad_recon_extrude({_py(profile)}, {_py(direction)}, {_py(extent)}, {target_expr})'
    elif family == 'revolution':
        profile = _profile(geometry.get('profile'), state, radial=True)
        angle = tool.get('angle_degrees', geometry.get('angle_degrees'))
        if angle is None:
            _fail('INSUFFICIENT_EVIDENCE', 'Choose an explicit revolution angle; angular support alone is not a full revolution')
        angle = _number(angle, 'revolution angle', state, positive=True)
        if _resolved(angle, state) > 360:
            _fail('INVALID_EDIT', 'Revolution angle must be at most 360 degrees')
        expression = f'_lad_recon_revolve({_py(profile)}, {_py(vec("origin"))}, {_py(vec("axis", direction=True))}, {_py(vec("x_direction", [1, 0, 0], True))}, {_py(angle)})'
    else:
        _fail('UNSUPPORTED_OPERATION', 'This fitted family has no implemented solid realization', family=family)
    def bindings_only(value):
        if isinstance(value, dict):
            if 'parameter' in value:
                return {'parameter': value['parameter']}
            return {key: bindings_only(item) for key, item in value.items()}
        if isinstance(value, list):
            return [bindings_only(item) for item in value]
        return value
    realization = {'family': family, 'geometry': bindings_only(geometry), 'extent': extent,
                   'fit': provenance, 'observed_extent': observed,
                   'construction_extent_is_evidence': False}
    if family == 'concentric_spherical_shell':
        realization['material'] = 'between_surfaces'
    return expression, realization


def _merge_requirements(state, edit):
    # Omission never disables an established obligation or invariant.  The
    # initial vocabulary only adds/replaces records by an explicit stable ID.
    for name in ('constraints', 'active_invariants', 'completion_obligations'):
        if name not in edit:
            continue
        incoming = edit[name]
        if not isinstance(incoming, list):
            _fail('INVALID_EDIT', name + ' must be a list of identified records')
        old = state[name]
        for record in incoming:
            if isinstance(record, str):
                identity = _identity(record, name)
                existing = [v for v in old if (v if isinstance(v, str) else v.get('id')) == identity]
                if not existing:
                    old.append(record)
                continue
            if not isinstance(record, dict):
                _fail('INVALID_EDIT', name + ' records require stable IDs')
            identity = _identity(record.get('id'), name + ' ID')
            matches = [i for i, value in enumerate(old) if (value if isinstance(value, str) else value.get('id')) == identity]
            if matches and old[matches[0]] != record:
                _fail('CONSTRAINT_CONFLICT', 'Existing requirement cannot be weakened by an ordinary edit', requirement=identity)
            if not matches:
                old.append(copy.deepcopy(record))


def _custom_program(program, body_ids, bindings, state):
    if not isinstance(program, str) or not program.strip():
        _fail('INVALID_PROGRAM', 'program_replace requires a complete source snapshot')
    if len(program.encode('utf-8')) > _MAX_SCRIPT_BYTES:
        _fail('RESOURCE_LIMIT', 'Complete source exceeds the worker budget; source was not truncated')
    try:
        tree = ast.parse(program)
    except SyntaxError as error:
        _fail('INVALID_PROGRAM', 'Complete CAD program is not valid Python', line=error.lineno)
    if bindings is None:
        if len(body_ids) != 1:
            _fail('AMBIGUOUS_REBIND', 'Multiple bodies require explicit semantic-to-Python-variable bindings')
        bindings = {body_ids[0]: 'result'}
    if not isinstance(bindings, dict) or set(bindings) != set(body_ids):
        _fail('INVALID_EDIT', 'Body bindings must cover exactly the declared body IDs')
    for symbol in bindings.values():
        if not isinstance(symbol, str) or not symbol.isidentifier():
            _fail('INVALID_EDIT', 'Body bindings must be Python identifiers, not executable expressions')
    # Python requires future imports ahead of ordinary imports. Retain their
    # complete original prefix instead of making a valid saved program fail
    # merely because this snapshot adds modeling helpers.
    prefix_end = 0
    for node in tree.body:
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str) and prefix_end == 0:
            prefix_end = node.end_lineno
        elif isinstance(node, ast.ImportFrom) and node.module == '__future__':
            prefix_end = node.end_lineno
        else:
            break
    lines = program.splitlines(keepends=True)
    source = ''.join(lines[:prefix_end])
    if source and not source.endswith('\n'):
        source += '\n'
    source += _header(state) + '\n# Complete caller-authored CAD program\n' + ''.join(lines[prefix_end:]).rstrip() + '\n'
    source += '\n_lad_recon_bodies = {' + ', '.join(f'{identity!r}: _lad_recon_one({symbol}, {identity!r})' for identity, symbol in bindings.items()) + '}\n'
    source += 'result = _lad_recon_result(_lad_recon_bodies)\n'
    return source


def compile_edit(context, revision, edit, resolve_fit=None):
    """Normalize one edit/atomic group without mutating or executing the base.

    The returned state and complete source are a *plan*, not a successful
    preview.  The orchestrator must execute the source in its worker sandbox,
    enforce mandatory validity/constraint/invariant gates, and only then mark a
    preview commit eligible.  Final tolerance/completion checks are separate.
    """
    if not isinstance(context, dict) or not isinstance(revision, dict) or not isinstance(edit, dict):
        _fail('INVALID_EDIT', 'Context, revision and edit must be objects')
    if context.get('units', 'mm') != 'mm':
        _fail('UNSUPPORTED_UNITS', 'Normalize source, fits and edit coordinates to millimeters before CAD construction')
    state = _state(revision)
    program = revision.get('script') or ''
    if not isinstance(program, str):
        _fail('INVALID_PROGRAM', 'Base revision must retain its complete source snapshot')
    if len(program.encode('utf-8')) > _MAX_SCRIPT_BYTES:
        _fail('RESOURCE_LIMIT', 'Base complete source exceeds the worker budget; source was not truncated')
    dependencies, evolution, normalized, changes = [], [], [], {'body': False, 'construction': False}
    if edit.get('operation') == 'group':
        _merge_requirements(state, edit)
    edits = edit.get('edits') if edit.get('operation') == 'group' else [edit]
    if not isinstance(edits, list) or not 1 <= len(edits) <= 64:
        _fail('RESOURCE_LIMIT', 'Atomic edit group must contain 1 to 64 operations')
    for index, operation in enumerate(edits):
        if not isinstance(operation, dict):
            _fail('INVALID_EDIT', 'Each atomic edit must be an object', operation_index=index)
        try:
            _merge_requirements(state, operation)
            kind, action = operation.get('kind'), operation.get('operation')
            if kind not in ('body', 'construction'):
                _fail('INVALID_EDIT', 'Edit kind must be body or construction')
            if kind == 'construction':
                if action not in ('add', 'create'):
                    _fail('UNSUPPORTED_OPERATION', 'Construction edits currently add explicit immutable datums/profiles')
                identity = _identity(operation.get('construction_id'), 'construction ID')
                if identity in state['constructions']:
                    _fail('AMBIGUOUS_ENTITY', 'Construction ID already exists', entity=identity)
                family, geometry, provenance, observed = _fit_tool(operation.get('tool'), resolve_fit)
                # Validate datums/curves without inventing a finite body.
                if family == 'plane':
                    geometry = {'origin': _vector(geometry.get('origin'), 'plane origin', state),
                                'normal': _vector(geometry.get('normal'), 'plane normal', state, direction=True),
                                'x_direction': _vector(geometry.get('x_direction', [1, 0, 0]), 'plane x direction', state, direction=True)}
                    _frame_check(geometry['x_direction'], geometry['normal'], state)
                elif family in ('axis', 'line'):
                    geometry = {'origin': _vector(geometry.get('origin'), 'axis origin', state),
                                'direction': _vector(geometry.get('direction', geometry.get('axis')), 'axis direction', state, direction=True)}
                elif family == 'circle':
                    geometry = {'center': _vector(geometry.get('center'), 'circle center', state),
                                'normal': _vector(geometry.get('normal'), 'circle normal', state, direction=True),
                                'radius': _number(geometry.get('radius'), 'circle radius', state, positive=True)}
                elif family == 'profile':
                    geometry = _profile(geometry, state, allow_open=True)
                elif family in ('cylinder', 'cone'):
                    normalized_geometry = {'origin': _vector(geometry.get('origin'), family+' origin', state),
                                           'axis': _vector(geometry.get('axis'), family+' axis', state, direction=True),
                                           'radius': _number(geometry.get('radius'), family+' radius', state,
                                                             positive=family == 'cylinder', nonnegative=family == 'cone')}
                    if family == 'cone':
                        normalized_geometry['slope'] = _number(geometry.get('slope'), 'cone slope', state)
                    geometry = normalized_geometry
                elif family == 'sphere':
                    geometry = {'center': _vector(geometry.get('center'), 'sphere center', state),
                                'radius': _number(geometry.get('radius'), 'sphere radius', state, positive=True)}
                else:
                    _fail('UNSUPPORTED_OPERATION', 'Construction-only family is unavailable', family=family)
                state['constructions'][identity] = {'id': identity, 'family': family, 'geometry': geometry,
                                                     'observed_extent': observed, 'fit': provenance}
                if provenance:
                    dependencies.append(provenance)
                changes['construction'] = True
                normalized.append({'kind': kind, 'operation': action, 'construction_id': identity})
                evolution.append({'entity': identity, 'relationship': 'generated', 'category': 'construction'})
                continue
            if action == 'program_replace':
                ids = operation.get('body_ids', ['body-main'])
                if not isinstance(ids, list) or not ids or len(ids) > 256:
                    _fail('INVALID_EDIT', 'program_replace requires bounded semantic body IDs')
                ids = [_identity(value, 'body ID') for value in ids]
                if len(set(ids)) != len(ids):
                    _fail('AMBIGUOUS_ENTITY', 'Body IDs must be unique')
                program = _custom_program(operation.get('program'), ids, operation.get('body_bindings'), state)
                state['body_ids'], state['generated_program'] = ids, True
                changes['body'] = True
                evolution.extend({'entity': identity, 'relationship': 'modified' if identity in _state(revision)['body_ids'] else 'generated', 'category': 'body'} for identity in ids)
                normalized.append({'kind': kind, 'operation': action, 'body_ids': ids})
                continue
            if action == 'update_parameters':
                values = operation.get('values')
                if not isinstance(values, dict) or not values:
                    _fail('INVALID_EDIT', 'update_parameters requires explicit bound parameter values')
                if not state['generated_program'] or not program:
                    _fail('UNSUPPORTED_OPERATION', 'Program has no explicit generated parameter bindings; replace its complete source instead')
                for key, value in values.items():
                    if key not in state['parameter_bindings']:
                        _fail('UNKNOWN_PARAMETER', 'Cannot edit an undeclared program parameter', parameter=key)
                    binding = state['parameter_bindings'][key]
                    if binding.get('fixed'):
                        _fail('CONSTRAINT_CONFLICT', 'Parameter is fixed', parameter=key)
                    binding['value'] = _plain_number(value, key)
                    _check_parameter(key, binding)
                program = _seed(program, state)
                changes['body'] = bool(state['body_ids'])
                evolution.extend({'entity': identity, 'relationship': 'modified', 'category': 'body', 'reason': 'complete program regeneration'} for identity in state['body_ids'])
                normalized.append({'kind': kind, 'operation': action, 'values': copy.deepcopy(values)})
                continue
            target = operation.get('target_body', operation.get('body_id', 'body-main' if action == 'create' else None))
            target = _identity(target, 'target body')
            if action == 'create':
                if target in state['body_ids']:
                    _fail('AMBIGUOUS_ENTITY', 'Body ID already exists', entity=target)
            elif target not in state['body_ids']:
                _fail('UNKNOWN_ENTITY', 'Target body does not exist in the selected revision', entity=target)
            if not program:
                program = _header(state)
                state['generated_program'] = True
            elif not state['generated_program'] and state['body_ids']:
                program = _custom_program(program, state['body_ids'], None, state)
                state['generated_program'] = True
            if not state['generated_program']:
                _fail('STALE_DEPENDENCY', 'Base body program has no semantic body bindings')
            label = f'operation {index}: {action} {target}'
            prefix = f'\n# {label}\n'
            if action == 'fillet':
                radius = _number(operation.get('radius'), 'fillet radius', state, positive=True)
                anchors = operation.get('edges', operation.get('edge_anchors'))
                if not isinstance(anchors, list) or not 1 <= len(anchors) <= 256:
                    _fail('INVALID_EDIT', 'Fillet requires bounded semantic geometric edge anchors')
                selected = []
                for anchor in anchors:
                    if not isinstance(anchor, dict):
                        _fail('INVALID_EDIT', 'Fillet anchor must be an object')
                    item = {'point': _vector(anchor.get('point'), 'edge anchor', state),
                            'max_distance': _number(anchor.get('max_distance'), 'anchor bound', state, positive=True)}
                    if 'adjacent_surfaces' in anchor:
                        families = anchor['adjacent_surfaces']
                        if not isinstance(families, list) or not 1 <= len(families) <= 2 or any(not isinstance(v, str) for v in families):
                            _fail('INVALID_EDIT', 'Edge adjacency must identify one or two surface families')
                        item['adjacent_surfaces'] = [v.lower() for v in families]
                    selected.append(item)
                expression = f'_lad_recon_fillet(_lad_recon_bodies[{target!r}], {_py(radius)}, {_py(selected)}, {target!r})'
                realized = {'family': 'fillet', 'radius': radius, 'edge_anchors': selected}
            elif action in ('create', 'fuse', 'cut', 'intersect'):
                expression, realized = _operand(operation.get('tool'), state, resolve_fit,
                                                None if action == 'create' else target, action)
                if action != 'create':
                    method = {'fuse': 'fuse', 'cut': 'cut', 'intersect': 'intersect'}[action]
                    expression = f'_lad_recon_bodies[{target!r}].{method}({expression})'
                if realized.get('fit'):
                    dependencies.append(realized['fit'])
            else:
                _fail('UNSUPPORTED_OPERATION', 'Unsupported typed body operation', operation=action)
            prefix += 'try:\n'
            prefix += f'    _lad_recon_bodies[{target!r}] = _lad_recon_one({expression}, {target!r})\n'
            prefix += f'except Exception as _lad_recon_error:\n    raise ValueError({label!r} + ": " + str(_lad_recon_error)) from _lad_recon_error\n'
            prefix += 'result = _lad_recon_result(_lad_recon_bodies)\n'
            program += prefix
            program = _seed(program, state)
            if action == 'create':
                state['body_ids'].append(target)
            feature = operation.get('feature_id')
            if feature is not None:
                feature = _identity(feature, 'feature ID')
                if feature in state['features']:
                    _fail('AMBIGUOUS_ENTITY', 'Feature ID already exists', entity=feature)
                state['features'][feature] = {'id': feature, 'body_id': target, 'operation': action,
                                               'realization': realized,
                                               'construction_intent_only': True}
            normalized.append({'kind': kind, 'operation': action, 'target_body': target,
                               'feature_id': feature, 'realization': realized})
            evolution.append({'entity': target, 'relationship': 'generated' if action == 'create' else 'modified',
                              'category': 'body', 'generated_feature': feature,
                              'native_feature_rebinding': 'not_assumed'})
            changes['body'] = True
        except EditError as error:
            error.details.setdefault('operation_index', index)
            raise
    if program and len(program.encode('utf-8')) > _MAX_SCRIPT_BYTES:
        _fail('RESOURCE_LIMIT', 'Complete replay program exceeds the worker source budget; source was not truncated')
    # A construction-only edit preserves the existing complete program verbatim.
    if not changes['body']:
        program = revision.get('script') or None
    result = {'script': program, **copy.deepcopy(state), 'state': copy.deepcopy(state),
              'normalized_edit': normalized[0] if len(normalized) == 1 else {'operation': 'group', 'edits': normalized},
              'dependencies': dependencies, 'entity_evolution': evolution,
              'body_changed': changes['body'], 'construction_changed': changes['construction'],
              'requires_body_validation': bool(state['body_ids']) and changes['body'],
              'invalidated_comparisons': 'all' if changes['body'] else 'none',
              'diagnostics': [], 'algorithm_version': VERSION,
              'final_acceptance': 'not_evaluated', 'completion_gate_applied': False}
    return result
