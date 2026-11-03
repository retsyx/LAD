"""Trimmed curved faces retain complete, outward display coverage."""
from collections import Counter
import copy
from pathlib import Path
import sys
import unittest
from unittest import mock

import cadquery as cq
import numpy as np
from scipy.spatial import cKDTree
from OCP.BRep import BRep_Tool
from OCP.BRepGProp import BRepGProp_Face
from OCP.Poly import Poly_Triangulation, Poly_Triangle
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS
from OCP.gp import gp_Pnt, gp_Vec

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker
import test_geometry_tolerance as geometry_tolerance


def trimmed_shell(radius=3, reduced=False):
    """The pole-adjacent rear opening that exposed incomplete OCCT meshes."""
    worker.configure_threads(2)
    axis = cq.Vector(0, np.sin(np.radians(55)), np.cos(np.radians(55)))
    sphere = cq.Solid.makeSphere(50, angleDegrees1=-90, angleDegrees2=90)
    lower = sphere.intersect(cq.Solid.makeBox(120, 120, 15, cq.Vector(-60, -60, -40)))
    upper = sphere.rotate((0, 0, 0), (1, 0, 0), -55).intersect(
        cq.Solid.makeBox(120, 120, 85, cq.Vector(-60, -60, -25)))
    upper = upper.cut(cq.Solid.makeCylinder(28.18, 40, axis.multiply(36), axis))
    body = lower.fuse(cq.Solid.makeCylinder(35, 6, cq.Vector(0, 0, -40))).fuse(upper)
    bottom = [face for face in body.Faces()
              if face.geomType() == 'PLANE' and abs(face.Center().z + 40) < .001]
    body = body.hollow(bottom, -2).Solids()[0]
    if not reduced:
        ring = cq.Solid.makeCylinder(34, 2, cq.Vector(0, 0, -40)).cut(
            cq.Solid.makeCylinder(30, 4, cq.Vector(0, 0, -41)))
        body = body.fuse(ring).cut(cq.Solid.makeCylinder(22.5, 12, axis.multiply(28), axis))
    slot = cq.Workplane('XY').box(15, 200, 8.5).edges('|Y').fillet(radius).val()
    body = body.cut(slot.translate((0, -100, -19.75))).clean()
    worker.validate_shape(body)
    body._lad_parts = [{'id': 'holder', 'name': 'Holder', 'solidIndices': [0], 'children': None}]
    return body


class PreviewTrimmedSurfaceTests(unittest.TestCase):
    def assert_complete_native_coverage(self, shape, preview):
        points, normals = np.asarray(preview['vertices']), np.asarray(preview['normals'])
        triangles = np.asarray(preview['triangles'])
        face_ids = np.asarray(preview['triangleFaces'])
        self.assertTrue(np.all(np.isfinite(normals)))
        self.assertTrue(np.allclose(np.linalg.norm(normals, axis=1), 1, atol=1e-6))
        offset, face_index, edge_paths = 0, 0, {}
        for solid in worker._shape_entities(shape, 'Solid'):
            edges = worker._shape_entities(solid, 'Edge')
            for face in worker._shape_entities(solid, 'Face'):
                location = TopLoc_Location()
                poly = BRep_Tool.Triangulation_s(face.wrapped, location)
                self.assertIsNotNone(poly, 'Every physical native face needs display triangles.')
                count = poly.NbNodes()
                native = np.asarray([poly.Node(i).Transformed(location.Transformation()).Coord()
                                     for i in range(1, count + 1)])
                np.testing.assert_array_equal(points[offset:offset + count], native)
                local = triangles[face_ids == face_index] - offset
                self.assertGreater(len(local), 0)
                self.assertTrue(np.all((local >= 0) & (local < count)))

                # Independently compare lighting and winding to exact surface
                # derivatives, rather than accepting the supplied normals.
                exact = []
                surface = BRepGProp_Face(face.wrapped)
                for node in range(1, count + 1):
                    uv, point, vector = poly.UVNode(node), gp_Pnt(), gp_Vec()
                    surface.Normal(uv.X(), uv.Y(), point, vector)
                    if vector.Magnitude() > 1e-12:
                        expected = np.asarray(vector.Normalized().Coord())
                        actual = normals[offset + node - 1]
                        self.assertGreater(np.dot(expected, actual) / np.linalg.norm(actual), 1 - 1e-10)
                    else:
                        expected = normals[offset + node - 1]
                    exact.append(expected)
                exact = np.asarray(exact)
                corners = native[local]
                planes = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
                length = np.linalg.norm(planes, axis=1)
                direction = (planes * exact[local].sum(axis=1)).sum(axis=1)
                self.assertTrue(np.all(direction[length > 1e-12] >= -length[length > 1e-12] * 1e-8))

                # Coincident poles/seams have separate UV nodes. Compare their
                # physical boundaries without rounding or moving coordinates.
                parent = list(range(count))

                def root(index):
                    while parent[index] != index:
                        parent[index] = parent[parent[index]]
                        index = parent[index]
                    return index

                for a, b in cKDTree(native).query_pairs(1e-12):
                    parent[root(b)] = root(a)

                def edge_key(a, b):
                    return tuple(sorted((root(int(a)), root(int(b)))))

                incidence = Counter()
                for triangle in local:
                    if len({root(int(i)) for i in triangle}) < 3:
                        continue
                    for a, b in zip(triangle, np.roll(triangle, -1)):
                        if root(int(a)) != root(int(b)):
                            incidence[edge_key(a, b)] += 1
                native_boundary = set()
                for edge in worker._shape_entities(face, 'Edge'):
                    edge_index = next(i for i, candidate in enumerate(edges) if edge.isSame(candidate))
                    for native_edge in (edge.wrapped, TopoDS.Edge(edge.wrapped.Reversed())):
                        polygon = BRep_Tool.PolygonOnTriangulation_s(native_edge, poly, location)
                        if polygon is None:
                            continue
                        indices = polygon.Nodes()
                        ids = [indices.Value(i) - 1 for i in range(indices.Lower(), indices.Upper() + 1)]
                        for a, b in zip(ids, ids[1:]):
                            if root(a) != root(b):
                                native_boundary.add(edge_key(a, b))
                        path = [tuple(native[i]) for i in ids]
                        if edge.IsClosed() and path[-1] != path[0]:
                            path.append(path[0])
                        edge_paths.setdefault(edge_index, []).append(path)
                self.assertTrue(all(count <= 2 for count in incidence.values()))
                self.assertTrue(native_boundary <= incidence.keys(), 'A native trim segment disappeared.')
                self.assertTrue({edge for edge, count in incidence.items() if count == 1} <= native_boundary,
                                'A curved face contains an artificial interior crack.')
                offset += count
                face_index += 1
        self.assertEqual(offset, len(points))
        for edge_index, edge in enumerate(preview['topology']['edges']):
            displayed = [tuple(point) for point in edge['polyline']]
            self.assertTrue(any(displayed == path or displayed == path[::-1]
                                for path in edge_paths[edge_index]), 'CAD strokes must reuse native boundary nodes.')

    def test_full_three_millimeter_slot_is_complete_at_different_placements_and_scales(self):
        snapshot = geometry_tolerance.GeometryToleranceTests().snapshot
        for label, scale, located in [('original', 1, False), ('half', .5, False),
                                      ('double', 2, False), ('located', 1, True)]:
            with self.subTest(label=label):
                shape = trimmed_shell()
                parts = copy.deepcopy(shape._lad_parts)
                if scale != 1:
                    shape = shape.scale(scale)
                if located:
                    shape = shape.moved(cq.Location((13, -8, 21), (1, 2, 3), 37))
                shape._lad_parts = parts
                before = snapshot(shape)
                preview = worker.make_preview(shape)
                self.assertEqual(snapshot(shape), before, 'Meshing must not alter canonical CAD geometry or identities.')
                self.assertEqual(preview['parts'], parts)
                self.assert_complete_native_coverage(shape, preview)

    def test_one_millimeter_slot_and_reduced_three_millimeter_fixture_remain_complete(self):
        for radius, reduced in [(1, False), (3, True)]:
            with self.subTest(radius=radius, reduced=reduced):
                shape = trimmed_shell(radius, reduced)
                self.assert_complete_native_coverage(shape, worker.make_preview(shape))

    def test_inward_native_candidates_fail_with_a_scoped_face_diagnostic(self):
        shape = cq.Solid.makeBox(2, 3, 4)
        audit = worker._preview_face_triangles

        def poisoned(face, poly, location, points, normals, edges, *configuration):
            bad = Poly_Triangulation(poly)
            for index in range(1, bad.NbTriangles() + 1):
                a, b, c = bad.Triangle(index).Get()
                bad.SetTriangle(index, Poly_Triangle(a, c, b))
            return audit(face, bad, location, points, normals, edges, *configuration)

        with mock.patch.object(worker, '_preview_face_triangles', side_effect=poisoned) as candidates:
            with self.assertRaises(worker.ModelError) as caught:
                worker.make_preview(shape)
        self.assertGreater(candidates.call_count, 1, 'A failed display candidate must permit a bounded native retry.')
        self.assertEqual(caught.exception.diagnostic['stage'], 'preview_meshing')
        self.assertEqual(caught.exception.diagnostic['geometryScope'], 'native_candidate')
        self.assertEqual(caught.exception.diagnostic['feature'],
                         {'kind': 'face', 'solidIndex': 0, 'localIndex': 0})
        self.assertIn('face', str(caught.exception))
        self.assertIn('inward surface triangles', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
