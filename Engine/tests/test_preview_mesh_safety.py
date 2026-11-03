"""Malformed native tessellations must not become plausible but incomplete previews."""
import copy
import math
from pathlib import Path
import sys
import unittest

import cadquery as cq
from OCP.BRep import BRep_Tool
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.Poly import Poly_Triangle
from OCP.TopLoc import TopLoc_Location
from OCP.gp import gp_Pnt, gp_Vec

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


class PreviewMeshSafetyTests(unittest.TestCase):
    def native_triangle(self):
        face = cq.Face.makeFromWires(cq.Wire.makePolygon([
            cq.Vector(0, 0, 0), cq.Vector(1, 0, 0), cq.Vector(0, 1, 0)], close=True))
        BRepMesh_IncrementalMesh(face.wrapped, .01, False, .15, False)
        location = TopLoc_Location()
        poly = BRep_Tool.Triangulation_s(face.wrapped, location)
        self.assertEqual(poly.NbNodes(), 3)
        self.assertEqual(poly.NbTriangles(), 1)
        return face, poly, location

    def audit_face(self, face, poly, location, normals=None):
        points = [list(poly.Node(index).Transformed(location.Transformation()).Coord())
                  for index in range(1, poly.NbNodes() + 1)]
        normals = normals or worker._preview_face_normals(face, poly, location)
        return worker._preview_face_triangles(face, poly, location, points, normals,
                                              worker._shape_entities(face, 'Edge'), .01)

    def test_duplicate_outward_triangles_are_rejected(self):
        face, poly, location = self.native_triangle()
        original = poly.Triangle(1).Get()
        poly.ResizeTriangles(2, True)
        poly.SetTriangle(2, Poly_Triangle(*original))
        with self.assertRaisesRegex(worker._PreviewMeshError, 'overlapping|nonmanifold'):
            self.audit_face(face, poly, location)

    def test_nearby_unrelated_node_ids_do_not_replace_native_trim_nodes(self):
        face, poly, location = self.native_triangle()
        original = poly.Triangle(1).Get()
        points = [poly.Node(index).Coord() for index in range(1, 4)]
        poly.ResizeNodes(6, True)
        for index, (x, y, z) in enumerate(points, start=4):
            poly.SetNode(index, gp_Pnt(x + 2e-8, y, z))
        # The triangles use a nearby second set of IDs while the native edge
        # polygons still require the original IDs. Rounding XYZ to seven
        # decimal places would hide every missing native boundary segment.
        poly.SetTriangle(1, Poly_Triangle(*(index + 3 for index in original)))
        normal = list(face.normalAt().toTuple())
        with self.assertRaises(worker._PreviewMeshError):
            self.audit_face(face, poly, location, [normal[:] for _ in range(6)])

    def sphere_patch(self, span, location=None):
        radius = 1000.
        z = math.sqrt(radius * radius - span * span)
        points = [[span, 0, z], [0, span, z], [-span, 0, z]]
        normals = [[value / radius for value in point] for point in points]
        sphere = cq.Solid.makeSphere(radius, angleDegrees1=-90, angleDegrees2=90)
        if location is not None:
            sphere = sphere.located(location)
            transform = location.wrapped.Transformation()
            points = [list(gp_Pnt(*point).Transformed(transform).Coord()) for point in points]
            normals = [list(gp_Vec(*normal).Transformed(transform).Coord()) for normal in normals]
        return worker._shape_entities(sphere, 'Face')[0], points, normals

    def test_large_gently_curved_patch_still_obeys_absolute_surface_deflection(self):
        face, points, normals = self.sphere_patch(100)
        before = copy.deepcopy((points, normals))
        centroid = [sum(point[axis] for point in points) / 3 for axis in range(3)]
        self.assertGreater(1000 - math.hypot(*centroid), 4)
        with self.assertRaisesRegex(worker._PreviewMeshError, 'deflection'):
            worker._preview_patch_triangles([0, 1, 2], points, normals, face, .25)
        self.assertEqual((points, normals), before)

    def test_small_located_patch_retains_existing_node_positions_and_indices(self):
        face, points, normals = self.sphere_patch(5, cq.Location((12, -7, 3), (1, 2, 0), 37))
        before = copy.deepcopy((points, normals))
        triangles = worker._preview_patch_triangles([0, 1, 2], points, normals, face, .25)
        self.assertEqual(len(triangles), 1)
        self.assertEqual(set(triangles[0]), {0, 1, 2})
        self.assertEqual((points, normals), before)

    def test_crossing_patch_boundary_is_rejected(self):
        face, _, _ = self.native_triangle()
        points = [[0., 0., 0.], [3., 0., 0.], [0., 2., 0.], [3., 2., 0.], [1., 3., 0.]]
        normals = [[0., 0., 1.] for _ in points]
        with self.assertRaisesRegex(worker._PreviewMeshError, 'crossing'):
            worker._preview_patch_triangles(list(range(5)), points, normals, face, .01)


if __name__ == '__main__':
    unittest.main()
