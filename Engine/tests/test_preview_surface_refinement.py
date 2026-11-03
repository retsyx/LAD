"""Independent surface checks for the bounded native meshing fallback."""
from collections import Counter
import copy
import math
from pathlib import Path
import sys
import unittest
from unittest import mock

import cadquery as cq
import numpy as np
from OCP.BRep import BRep_Tool
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
from OCP.BRepGProp import BRepGProp_Face
from OCP.Geom import Geom_BezierSurface
from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
from OCP.Poly import Poly_Triangle, Poly_Triangulation
from OCP.TColgp import TColgp_Array2OfPnt
from OCP.TopLoc import TopLoc_Location
from OCP.gp import gp_Pnt, gp_Pnt2d, gp_Vec

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


class PreviewSurfaceRefinementTests(unittest.TestCase):
    def bump(self, located=False):
        poles = TColgp_Array2OfPnt(1, 3, 1, 3)
        for u in range(1, 4):
            for v in range(1, 4):
                poles.SetValue(u, v, gp_Pnt((u - 1) / 2, (v - 1) / 2,
                                           1.2 if u == v == 2 else 0))
        surface = Geom_BezierSurface(poles)
        face = cq.Face(BRepBuilderAPI_MakeFace(surface, 1e-9).Face())
        location = (cq.Location((12, -8, 5), (1, 2, 3), 37).wrapped
                    if located else TopLoc_Location())
        face = cq.Face(face.wrapped.Moved(location))
        poly = Poly_Triangulation(4, 2, True)
        for index, (u, v) in enumerate([(0, 0), (1, 0), (1, 1), (0, 1)], 1):
            poly.SetNode(index, surface.Value(u, v))
            poly.SetUVNode(index, gp_Pnt2d(u, v))
        triangles = [[0, 1, 2], [0, 2, 3]]
        for index, triangle in enumerate(triangles, 1):
            poly.SetTriangle(index, Poly_Triangle(*(node + 1 for node in triangle)))
        points = [list(poly.Node(index).Transformed(location.Transformation()).Coord())
                  for index in range(1, 5)]
        normals = worker._preview_face_normals(face, poly, location)
        boundary = {(0, 1), (1, 2), (2, 3), (0, 3)}
        return face, poly, location, points, normals, triangles, boundary

    def snapshot(self, poly, points, normals):
        return copy.deepcopy((points, normals,
                              [poly.Node(index).Coord() for index in range(1, poly.NbNodes() + 1)],
                              [poly.UVNode(index).Coord() for index in range(1, poly.NbNodes() + 1)],
                              [poly.Triangle(index).Get() for index in range(1, poly.NbTriangles() + 1)]))

    def test_exhausted_refinement_budget_does_not_publish_partial_nodes(self):
        face, poly, location, points, normals, triangles, boundary = self.bump()
        before = self.snapshot(poly, points, normals)
        with mock.patch.object(worker, 'MAX_PREVIEW_REFINEMENT_NODES', 0):
            with self.assertRaises(worker._PreviewMeshError):
                worker._preview_refine_face(face, poly, location, points, normals,
                                            triangles, boundary, .01)
        self.assertEqual(self.snapshot(poly, points, normals), before)

    def test_refinement_rejects_reversed_native_parameter_winding(self):
        face, poly, location, points, normals, triangles, boundary = self.bump()
        before = self.snapshot(poly, points, normals)
        with self.assertRaises(worker._PreviewMeshError):
            worker._preview_refine_face(face, poly, location, points, normals,
                                        [triangle[::-1] for triangle in triangles], boundary, .01)
        self.assertEqual(self.snapshot(poly, points, normals), before)

    def test_collapsed_spatial_cells_cannot_hide_a_nonzero_surface_patch(self):
        face, poly, location, points, normals, triangles, boundary = self.bump()
        for index in range(4):
            points[index] = [0., 0., 0.]
            poly.SetNode(index + 1, gp_Pnt(0, 0, 0))
        before = self.snapshot(poly, points, normals)
        with self.assertRaises(worker._PreviewMeshError):
            worker._preview_refine_face(face, poly, location, points, normals,
                                        triangles, boundary, .01)
        self.assertEqual(self.snapshot(poly, points, normals), before)

    def test_refinement_preserves_native_boundary_and_exact_surface_normals(self):
        for located in (False, True):
            with self.subTest(located=located):
                face, poly, location, points, normals, triangles, boundary = self.bump(located)
                original = copy.deepcopy((points, normals))
                original_uv = [poly.UVNode(index).Coord() for index in range(1, 5)]
                tolerance = .01
                result = worker._preview_refine_face(face, poly, location, points, normals,
                                                      triangles, boundary, tolerance)
                self.assertGreater(len(points), 4, 'Outward facets can still need deflection refinement.')
                self.assertEqual(points[:4], original[0])
                self.assertEqual(normals[:4], original[1])
                self.assertEqual([poly.UVNode(index).Coord() for index in range(1, 5)], original_uv)
                self.assertEqual(poly.NbNodes(), len(points))
                self.assertEqual(len(normals), len(points))

                incidence = Counter(tuple(sorted((a, b))) for triangle in result
                                    for a, b in zip(triangle, triangle[1:] + triangle[:1]))
                self.assertEqual({edge for edge, count in incidence.items() if count == 1}, boundary)
                self.assertTrue(all(count <= 2 for count in incidence.values()))
                exact = BRepGProp_Face(face.wrapped)
                for index, (point, normal) in enumerate(zip(points, normals), 1):
                    self.assertTrue(all(math.isfinite(value) for value in [*point, *normal]))
                    self.assertAlmostEqual(math.hypot(*normal), 1, places=7)
                    uv = poly.UVNode(index)
                    expected_point, expected_normal = gp_Pnt(), gp_Vec()
                    exact.Normal(uv.X(), uv.Y(), expected_point, expected_normal)
                    np.testing.assert_allclose(point, expected_point.Coord(), atol=1e-12)
                    self.assertGreater(np.dot(normal, expected_normal.Normalized().Coord()), 1 - 1e-10)
                # Independently sample more densely than the refinement's
                # lattice and check distance to the exact underlying surface.
                exact_surface = BRep_Tool.Surface_s(face.wrapped)
                for triangle in result:
                    corners = np.asarray([points[index] for index in triangle])
                    uv = np.asarray([poly.UVNode(index + 1).Coord() for index in triangle])
                    for first in range(9):
                        for second in range(9 - first):
                            weights = np.asarray([first / 8, second / 8, (8 - first - second) / 8])
                            u, v = weights @ uv
                            expected, normal = gp_Pnt(), gp_Vec()
                            exact.Normal(float(u), float(v), expected, normal)
                            sample = weights @ corners
                            if math.dist(sample, expected.Coord()) > tolerance:
                                projection = GeomAPI_ProjectPointOnSurf(gp_Pnt(*sample), exact_surface)
                                self.assertGreater(projection.NbPoints(), 0)
                                self.assertLessEqual(projection.LowerDistance(), tolerance * 1.001)


if __name__ == '__main__':
    unittest.main()
