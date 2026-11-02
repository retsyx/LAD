"""Bounded, exact-complete triangle self-intersection audit.

The BVH only discards pairs with disjoint closed coordinate intervals.  A
floating-point orientation filter discards strictly plane-separated pairs when
its error bound establishes the signs.  All remaining decisions use the exact
integers obtained by scaling the represented binary64 coordinates by powers of
two, independently on each axis.  This invertible diagonal affine transform
preserves intersections; no welding, epsilon separation, or decimation occurs.

An audit may stop at an actual traversal/predicate/issue budget.  Such a result
is explicitly incomplete, including any defects already established.  Input
size alone never makes a geometrically well-behaved mesh unauditable.
"""
from __future__ import annotations

from fractions import Fraction
import math

import numpy as np


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross2(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _inside2(point, triangle):
    values = [_cross2(triangle[i], triangle[(i + 1) % 3], point) for i in range(3)]
    return min(values) >= 0 or max(values) <= 0


def _on_segment2(p, a, b):
    return (_cross2(a, b, p) == 0 and
            min(a[0], b[0]) <= p[0] <= max(a[0], b[0]) and
            min(a[1], b[1]) <= p[1] <= max(a[1], b[1]))


def _coplanar_unexpected(a, b, shared, normal):
    drop = max(range(3), key=lambda i: abs(normal[i]))
    axes = [i for i in range(3) if i != drop]
    project = lambda p: (p[axes[0]], p[axes[1]])
    a, b, common = tuple(map(project, a)), tuple(map(project, b)), set(map(project, shared))
    if len(common) >= 3:
        return True
    if len(common) == 2:
        u, v = sorted(common)
        apex_a = next(p for p in a if p not in common)
        apex_b = next(p for p in b if p not in common)
        # Nondegenerate triangles sharing an edge overlap beyond it exactly
        # when their two opposite vertices lie on the same side.
        return _cross2(u, v, apex_a) * _cross2(u, v, apex_b) > 0
    for p in a:
        if p not in common and _inside2(p, b):
            return True
    for p in b:
        if p not in common and _inside2(p, a):
            return True
    for i in range(3):
        u, v = a[i], a[(i + 1) % 3]
        for j in range(3):
            s, t = b[j], b[(j + 1) % 3]
            d1, d2, e1, e2 = _cross2(s, t, u), _cross2(s, t, v), _cross2(u, v, s), _cross2(u, v, t)
            if d1 * d2 < 0 and e1 * e2 < 0:
                return True
            # Endpoint/collinear contacts are real intersections too, except
            # for precisely the vertices/edge shared by the source topology.
            if any(p not in common and _on_segment2(p, x, y)
                   for p, x, y in ((u, s, t), (v, s, t), (s, u, v), (t, u, v))):
                return True
    return False


def _cut_interval(triangle, distances, axis):
    values = [p[axis] for p, distance in zip(triangle, distances) if distance == 0]
    for i in range(3):
        j = (i + 1) % 3
        di, dj = distances[i], distances[j]
        if di * dj < 0:
            # The only rational divisions needed by the 3D predicate.
            values.append(Fraction(triangle[i][axis] * dj - triangle[j][axis] * di, dj - di))
    return (min(values), max(values)) if values else None


def _exact_unexpected(a, b, shared, na, nb):
    da = [_dot(nb, _sub(p, b[0])) for p in a]
    db = [_dot(na, _sub(p, a[0])) for p in b]
    if min(da) > 0 or max(da) < 0 or min(db) > 0 or max(db) < 0:
        return False
    if not any(da):
        return _coplanar_unexpected(a, b, shared, na)
    if len(shared) >= 2:
        return False  # Two distinct support planes meet only on this edge.
    if len(shared) == 1:
        # If just the shared vertex is on one support plane, the triangles
        # cannot meet anywhere else.  This is common in manifold vertex fans.
        remaining_a = [distance for p, distance in zip(a, da) if p != shared[0]]
        remaining_b = [distance for p, distance in zip(b, db) if p != shared[0]]
        if ((min(remaining_a) > 0 or max(remaining_a) < 0) or
                (min(remaining_b) > 0 or max(remaining_b) < 0)):
            return False
    line = _cross(na, nb)
    axis = max(range(3), key=lambda i: abs(line[i]))
    ca, cb = _cut_interval(a, da, axis), _cut_interval(b, db, axis)
    if ca is None or cb is None:
        return False
    low, high = max(ca[0], cb[0]), min(ca[1], cb[1])
    if low > high:
        return False
    if not shared:
        return True
    return low < min(p[axis] for p in shared) or high > max(p[axis] for p in shared)


def _integer_points(points):
    exponents = [0, 0, 0]
    for point in points:
        for axis, value in enumerate(point):
            denominator = float(value).as_integer_ratio()[1]
            exponents[axis] = max(exponents[axis], denominator.bit_length() - 1)
    result = []
    for point in points:
        converted = []
        for axis, value in enumerate(point):
            numerator, denominator = float(value).as_integer_ratio()
            converted.append(numerator << (exponents[axis] - (denominator.bit_length() - 1)))
        result.append(tuple(converted))
    return result


def _separated_filter(a, b):
    """Strict plane separation using a widened orient3d roundoff filter.

    The permanent error bound is the standard first-stage orient3d filter,
    widened from (7+56u)u to 16u.  Unsafe arithmetic ranges, cancellation and
    zero determinants always fall through to exact integer predicates.
    """
    def one_side(triangle, queries):
        ad = triangle[:, None, 0] - queries
        bd = triangle[:, None, 1] - queries
        cd = triangle[:, None, 2] - queries
        with np.errstate(over='ignore', under='ignore', invalid='ignore'):
            bdx_cdy, cdx_bdy = bd[..., 0] * cd[..., 1], cd[..., 0] * bd[..., 1]
            cdx_ady, adx_cdy = cd[..., 0] * ad[..., 1], ad[..., 0] * cd[..., 1]
            adx_bdy, bdx_ady = ad[..., 0] * bd[..., 1], bd[..., 0] * ad[..., 1]
            det = (ad[..., 2] * (bdx_cdy - cdx_bdy) +
                   bd[..., 2] * (cdx_ady - adx_cdy) +
                   cd[..., 2] * (adx_bdy - bdx_ady))
            permanent = ((np.abs(bdx_cdy) + np.abs(cdx_bdy)) * np.abs(ad[..., 2]) +
                         (np.abs(cdx_ady) + np.abs(adx_cdy)) * np.abs(bd[..., 2]) +
                         (np.abs(adx_bdy) + np.abs(bdx_ady)) * np.abs(cd[..., 2]))
            error = np.nextafter((16 * 2.0 ** -53) * permanent, np.inf)
        safe = np.ones(len(triangle), dtype=bool)
        for differences in (ad, bd, cd):
            magnitude = np.abs(differences)
            safe &= np.all((magnitude == 0) | ((magnitude >= 1e-80) & (magnitude <= 1e80)), axis=(1, 2))
        return safe & (np.all(det > error, axis=1) | np.all(det < -error, axis=1))
    return one_side(a, b) | one_side(b, a)


class _BVH:
    def __init__(self, low, high, leaf_size):
        self.low, self.high = low, high
        self.nodes = []
        centers = low * 0.5 + high * 0.5
        def build(indices):
            node_id = len(self.nodes)
            lo, hi = low[indices].min(axis=0), high[indices].max(axis=0)
            self.nodes.append(None)
            if len(indices) <= leaf_size:
                self.nodes[node_id] = (lo, hi, -1, -1, indices)
            else:
                axis = int(np.argmax(np.ptp(centers[indices], axis=0)))
                ordered = indices[np.argsort(centers[indices, axis], kind='stable')]
                mid = len(ordered) // 2
                left, right = build(ordered[:mid]), build(ordered[mid:])
                self.nodes[node_id] = (lo, hi, left, right, None)
            return node_id
        build(np.arange(len(low), dtype=np.int64))


def audit_self_intersections(points, triangles, *, max_node_pairs=4_000_000,
                             max_candidate_pairs=2_000_000,
                             max_exact_pairs=2_000_000, max_issues=100,
                             leaf_size=8, batch_size=4096):
    """Return complete/incomplete audit and original zero-based triangle pairs.

    Points and indices should be exactly welded by the caller when source
    adjacency is to be recognized.  Degenerate triangles are retained by the
    source context's separate defect ledger and excluded from surface-surface
    intersection tests, matching the analysis contract.
    """
    points = np.asarray(points, dtype=np.float64)
    raw = np.asarray(triangles)
    if points.ndim != 2 or points.shape[1:] != (3,) or not np.isfinite(points).all():
        raise ValueError('points must be finite [N,3] coordinates')
    if raw.ndim != 2 or raw.shape[1:] != (3,) or raw.dtype.kind not in 'iu':
        raise ValueError('triangles must be integer [N,3] indices')
    triangles = raw.astype(np.int64)
    if len(triangles) and (triangles.min() < 0 or triangles.max() >= len(points)):
        raise ValueError('triangle index outside the point array')
    for name, value in (('max_node_pairs', max_node_pairs), ('max_candidate_pairs', max_candidate_pairs),
                        ('max_exact_pairs', max_exact_pairs), ('max_issues', max_issues),
                        ('leaf_size', leaf_size), ('batch_size', batch_size)):
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            raise ValueError(name + ' must be a positive integer')
    pairs = []
    stats = {'visited_node_pairs': 0, 'candidate_pairs': 0, 'filtered_pairs': 0,
             'exact_pairs': 0, 'skipped_degenerate_triangles': 0}
    def result(reason=None):
        return {'status': 'incomplete' if reason else 'complete',
                'pairs': sorted(pairs), 'tested_pairs': stats['filtered_pairs'] + stats['exact_pairs'],
                'method': 'filtered_exact_dyadic_bvh_triangle_intersections',
                'work': dict(stats), **({'reason': reason} if reason else {})}
    if not len(triangles):
        return result()
    exact_points = _integer_points(points)
    exact_geometry, normals, active_ids = [], [], []
    for tid, indices in enumerate(triangles):
        vertices = tuple(exact_points[int(i)] for i in indices)
        normal = _cross(_sub(vertices[1], vertices[0]), _sub(vertices[2], vertices[0]))
        if not any(normal):
            stats['skipped_degenerate_triangles'] += 1
            continue
        active_ids.append(tid)
        exact_geometry.append(vertices)
        normals.append(normal)
    if not active_ids:
        return result()
    source_ids = np.asarray(active_ids, dtype=np.int64)
    active_triangles = triangles[source_ids]
    geometry = points[active_triangles]
    low, high = geometry.min(axis=1), geometry.max(axis=1)
    tree = _BVH(low, high, leaf_size)
    pending = []

    def flush():
        if not pending:
            return None
        selected = np.asarray(pending, dtype=np.int64)
        pending.clear()
        rejected = _separated_filter(geometry[selected[:, 0]], geometry[selected[:, 1]])
        stats['filtered_pairs'] += int(np.count_nonzero(rejected))
        for ai, bi in selected[~rejected]:
            if stats['exact_pairs'] >= max_exact_pairs:
                return 'exact_predicate_budget'
            stats['exact_pairs'] += 1
            ai, bi = int(ai), int(bi)
            ids_a, ids_b = active_triangles[ai], active_triangles[bi]
            shared_ids = set(map(int, ids_a)) & set(map(int, ids_b))
            shared = [exact_points[i] for i in sorted(shared_ids)]
            if _exact_unexpected(exact_geometry[ai], exact_geometry[bi], shared, normals[ai], normals[bi]):
                first, second = sorted((int(source_ids[ai]), int(source_ids[bi])))
                pairs.append([first, second])
                if len(pairs) >= max_issues:
                    return 'issue_budget'
        return None

    stack = [(0, 0)]
    while stack:
        if stats['visited_node_pairs'] >= max_node_pairs:
            reason = flush()
            return result(reason or 'bvh_traversal_budget')
        ni, nj = stack.pop()
        stats['visited_node_pairs'] += 1
        a, b = tree.nodes[ni], tree.nodes[nj]
        if np.any(a[1] < b[0]) or np.any(b[1] < a[0]):
            continue
        if ni == nj and a[2] != -1:
            # Disjoint pair partitions: no pair is omitted or visited twice.
            stack.extend(((a[3], a[3]), (a[2], a[3]), (a[2], a[2])))
            continue
        if a[2] == -1 and b[2] == -1:
            ia, ib = a[4], b[4]
            overlap = np.all(high[ia, None] >= low[ib][None], axis=2) & np.all(high[ib][None] >= low[ia, None], axis=2)
            if ni == nj:
                overlap &= np.triu(np.ones(overlap.shape, dtype=bool), 1)
            for li, lj in np.argwhere(overlap):
                if stats['candidate_pairs'] >= max_candidate_pairs:
                    reason = flush()
                    return result(reason or 'candidate_pair_budget')
                stats['candidate_pairs'] += 1
                pending.append((int(ia[li]), int(ib[lj])))
                if len(pending) >= batch_size:
                    reason = flush()
                    if reason:
                        return result(reason)
            continue
        if b[2] == -1 or (a[2] != -1 and np.max(a[1] - a[0]) >= np.max(b[1] - b[0])):
            stack.extend(((a[3], nj), (a[2], nj)))
        else:
            stack.extend(((ni, b[3]), (ni, b[2])))
    reason = flush()
    return result(reason)
