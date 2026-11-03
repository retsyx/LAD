"""Scalable source audit: exact decisions, bounded actual work, source IDs."""
from fractions import Fraction
from pathlib import Path
import sys
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mesh_intersections import audit_self_intersections, _separated_filter


def grid(size=82):
    points = np.array([(x, y, 0) for y in range(size + 1) for x in range(size + 1)], float)
    triangles = []
    for y in range(size):
        for x in range(size):
            a = y * (size + 1) + x
            b, c, d = a + 1, a + size + 1, a + size + 2
            triangles.extend(((a, b, d), (a, d, c)))
    return points, np.array(triangles, dtype=np.int64)


def two_triangles(a, b):
    # Exact welding matches the source adjacency convention.
    points, inverse = np.unique(np.array([*a, *b], float), axis=0, return_inverse=True)
    return points, inverse.reshape(2, 3)


def _sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def _cross(a, b):
    return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])


def _dot(a, b):
    return sum(x*y for x, y in zip(a, b))


def _orient(a, b, c, d):
    return _dot(_cross(_sub(b, a), _sub(c, a)), _sub(d, a))


def _plane_cut(triangle, distances):
    points = [p for p, distance in zip(triangle, distances) if distance == 0]
    for i in range(3):
        j = (i + 1) % 3
        if distances[i] * distances[j] < 0:
            ratio = distances[i] / (distances[i] - distances[j])
            points.append(tuple(a + ratio*(b-a) for a, b in zip(triangle[i], triangle[j])))
    return list(dict.fromkeys(points))


def _cross2(a, b, c):
    return (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])


def _in_triangle2(point, triangle):
    signs = [_cross2(a, b, point) for a, b in zip(triangle, triangle[1:] + triangle[:1])]
    return all(v >= 0 for v in signs) or all(v <= 0 for v in signs)


def _coplanar_points(a, b, drop):
    project = lambda p: tuple(v for i, v in enumerate(p) if i != drop)
    pa, pb = [project(p) for p in a], [project(p) for p in b]
    points = [p for p in pa if _in_triangle2(p, pb)] + [p for p in pb if _in_triangle2(p, pa)]
    for u, v in zip(pa, pa[1:] + pa[:1]):
        for s, t in zip(pb, pb[1:] + pb[:1]):
            d1, d2 = _cross2(s, t, u), _cross2(s, t, v)
            e1, e2 = _cross2(u, v, s), _cross2(u, v, t)
            if d1*d2 < 0 and e1*e2 < 0:
                ratio = d1 / (d1 - d2)
                points.append(tuple(x + ratio*(y-x) for x, y in zip(u, v)))
            elif d1 == d2 == 0:
                for p in (u, v, s, t):
                    if all(min(x, y) <= z <= max(x, y) for x, y, z in zip(u, v, p)) and all(min(x, y) <= z <= max(x, y) for x, y, z in zip(s, t, p)):
                        points.append(p)
    return list(dict.fromkeys(points)), project


def _unexpected_intersection(a, b, shared):
    """Exact predicates on the rational numbers represented by input floats."""
    da = [_orient(*b, point) for point in a]
    db = [_orient(*a, point) for point in b]
    if all(v > 0 for v in da) or all(v < 0 for v in da) or all(v > 0 for v in db) or all(v < 0 for v in db):
        return False
    if all(v == 0 for v in da):
        normal = _cross(_sub(a[1], a[0]), _sub(a[2], a[0]))
        drop = max(range(3), key=lambda i: abs(normal[i]))
        points, project = _coplanar_points(a, b, drop)
        common = [project(p) for p in shared]
        if not points:
            return False
        if len(common) >= 3:
            return True  # Duplicate faces.
        if len(common) == 2:
            u, v = common
            return any(_cross2(u, v, p) != 0 or not all(min(x, y) <= z <= max(x, y) for x, y, z in zip(u, v, p)) for p in points)
        return any(p not in common for p in points)
    ca, cb = _plane_cut(a, da), _plane_cut(b, db)
    if not ca or not cb:
        return False
    line = _cross(_cross(_sub(a[1], a[0]), _sub(a[2], a[0])), _cross(_sub(b[1], b[0]), _sub(b[2], b[0])))
    axis = max(range(3), key=lambda i: abs(line[i]))
    low = max(min(p[axis] for p in ca), min(p[axis] for p in cb))
    high = min(max(p[axis] for p in ca), max(p[axis] for p in cb))
    if low > high:
        return False
    if not shared:
        return True
    return low < min(p[axis] for p in shared) or high > max(p[axis] for p in shared)


def brute_reference(points, triangles):
    # Construct rational intersection points independently of the production
    # integer interval predicate and BVH traversal.
    exact = [tuple(Fraction(float(v)) for v in point) for point in points]
    result = []
    for i in range(len(triangles)):
        a = tuple(exact[int(v)] for v in triangles[i])
        if _cross(_sub(a[1], a[0]), _sub(a[2], a[0])) == (0, 0, 0):
            continue
        for j in range(i + 1, len(triangles)):
            b = tuple(exact[int(v)] for v in triangles[j])
            if _cross(_sub(b[1], b[0]), _sub(b[2], b[0])) == (0, 0, 0):
                continue
            shared = set(map(int, triangles[i])) & set(map(int, triangles[j]))
            if _unexpected_intersection(a, b, [exact[v] for v in sorted(shared)]):
                result.append([i, j])
    return result


class MeshIntersectionTests(unittest.TestCase):
    def assert_audit(self, points, triangles, expected, **kwargs):
        result = audit_self_intersections(points, triangles, **kwargs)
        self.assertEqual(result['status'], 'complete', result)
        self.assertEqual(result['pairs'], expected, result)
        self.assertEqual(result['tested_pairs'], result['work']['candidate_pairs'])
        return result

    def test_more_than_twelve_thousand_triangles_get_a_complete_audit(self):
        points, triangles = grid()
        self.assertGreater(len(triangles), 12000)
        result = self.assert_audit(points, triangles, [])
        self.assertGreater(result['work']['exact_pairs'], len(triangles))
        self.assertLess(result['work']['candidate_pairs'], len(triangles) * 20)

    def test_shared_edges_adjacent_overlap_and_duplicates(self):
        a = [(0, 0, 0), (2, 0, 0), (0, 2, 0)]
        cases = [([(0, 0, 0), (2, 0, 0), (0, -2, 0)], []),
                 ([(0, 0, 0), (2, 0, 0), (0, 1, 1)], []),
                 ([(0, 0, 0), (2, 0, 0), (0.5, 1, 0)], [[0, 1]]),
                 (a, [[0, 1]]), (a[::-1], [[0, 1]])]
        for b, expected in cases:
            with self.subTest(b=b):
                self.assert_audit(*two_triangles(a, b), expected)

    def test_shared_vertex_is_allowed_only_for_exact_point_contact(self):
        a = [(0, 0, 0), (2, 0, 0), (0, 2, 0)]
        for b, expected in [([(0, 0, 0), (-2, 0, 0), (0, -2, 0)], []),
                            ([(0, 0, 0), (-1, -1, -1), (-1, -1, 1)], []),
                            ([(0, 0, 0), (1, 1, -1), (1, 1, 1)], [[0, 1]]),
                            ([(0, 0, 0), (1, 0, 0), (0, -1, 0)], [[0, 1]])]:
            with self.subTest(b=b):
                self.assert_audit(*two_triangles(a, b), expected)

    def test_nonadjacent_coplanar_and_transverse_intersections(self):
        a = [(0, 0, 0), (2, 0, 0), (0, 2, 0)]
        for b in ([(0.5, 0.5, 0), (2, 0.5, 0), (0.5, 2, 0)],
                  [(0.5, 0.5, -1), (0.5, 0.5, 1), (2, 2, 0)]):
            self.assert_audit(*two_triangles(a, b), [[0, 1]])

    def test_degenerate_evidence_and_original_triangle_ids_are_preserved(self):
        points = np.array([(0, 0, 0), (2, 0, 0), (0, 2, 0),
                           (0.5, 0.5, -1), (0.5, 0.5, 1), (2, 2, 0), (1, 0, 0)], float)
        triangles = np.array([[0, 6, 1], [0, 1, 2], [3, 4, 5], [0, 0, 1]])
        result = self.assert_audit(points, triangles, [[1, 2]])
        self.assertEqual(result['work']['skipped_degenerate_triangles'], 2)

    def test_exact_fallback_handles_subnormal_crossings_and_close_separation(self):
        tiny = float.fromhex('0x0.0000000000001p-1022')
        a = [(0, 0, 0), (2, 0, 0), (0, 2, 0)]
        result = self.assert_audit(*two_triangles(a, [(0.5, 0.5, -tiny),
                                                     (0.5, 0.5, tiny), (2, 2, 0)]), [[0, 1]])
        self.assertEqual(result['work']['filtered_pairs'], 0)
        self.assertEqual(result['work']['exact_pairs'], 1)
        self.assert_audit(*two_triangles(a, [(0, 0, tiny), (2, 0, tiny), (0, 2, tiny)]), [])

    def test_bvh_and_filter_match_independent_rational_reference(self):
        rng = np.random.default_rng(2401)
        for scale in (1.0, 1e-100, 1e100):
            for planar in (False, True):
                points = rng.integers(-6, 7, (36, 3)).astype(float) * scale
                if planar:
                    points[:, 2] = 0
                triangles = np.arange(36).reshape(-1, 3)
                expected = brute_reference(points, triangles)
                for leaf_size in (2, 8):
                    with self.subTest(scale=scale, planar=planar, leaf_size=leaf_size):
                        self.assert_audit(points, triangles, expected, leaf_size=leaf_size, max_issues=1000)

    def test_filter_never_discards_an_exactly_intersecting_pair(self):
        rng = np.random.default_rng(11)
        points = rng.normal(size=(120, 3))
        triangles = np.arange(120).reshape(-1, 3)
        reference = brute_reference(points, triangles)
        a = np.array([points[triangles[i]] for i, j in reference])
        b = np.array([points[triangles[j]] for i, j in reference])
        self.assertGreater(len(a), 20)
        self.assertFalse(_separated_filter(a, b).any())

    def test_actual_work_exhaustion_is_explicit_and_deterministic(self):
        points, triangles = grid(6)
        for kwargs, reason in (({'max_node_pairs': 1}, 'bvh_traversal_budget'),
                               ({'max_candidate_pairs': 1}, 'candidate_pair_budget'),
                               ({'max_exact_pairs': 1}, 'exact_predicate_budget')):
            with self.subTest(kwargs=kwargs):
                first = audit_self_intersections(points, triangles, **kwargs)
                second = audit_self_intersections(points, triangles, **kwargs)
                self.assertEqual(first, second)
                self.assertEqual(first['status'], 'incomplete')
                self.assertEqual(first['reason'], reason)
                self.assertEqual(first['tested_pairs'], first['work']['filtered_pairs'] + first['work']['exact_pairs'])
        a = [(0, 0, 0), (2, 0, 0), (0, 2, 0)]
        result = audit_self_intersections(*two_triangles(a, a), max_issues=1)
        self.assertEqual(result['status'], 'incomplete')
        self.assertEqual(result['pairs'], [[0, 1]])
        self.assertEqual(result['reason'], 'issue_budget')

    def test_invalid_indices_and_work_policies_are_rejected(self):
        points = np.eye(3)
        for triangles in ([[0.0, 1.0, 2.0]], [[-1, 1, 2]], [[0, 1, 3]]):
            with self.assertRaises(ValueError):
                audit_self_intersections(points, triangles)
        for kwargs in ({'max_candidate_pairs': 0}, {'leaf_size': True}, {'max_exact_pairs': -1}):
            with self.assertRaises(ValueError):
                audit_self_intersections(points, [[0, 1, 2]], **kwargs)


if __name__ == '__main__':
    unittest.main()
