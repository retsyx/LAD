"""Malformed native tessellations must not become plausible but incomplete previews."""
import copy
import math
from pathlib import Path
import sys
import unittest
from unittest import mock

import cadquery as cq
from OCP.BRep import BRep_Tool
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
from OCP.BRepGProp import BRepGProp_Face
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.Geom import Geom_BezierSurface
from OCP.Poly import Poly_Triangle, Poly_Triangulation
from OCP.TColgp import TColgp_Array2OfPnt
from OCP.TopLoc import TopLoc_Location
from OCP.gp import gp_Pnt, gp_Pnt2d, gp_Vec

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

    def curved_triangle(self, amplitude, centroid_inward=False):
        # An extruded Bezier graph has no inverted UV mapping, even when its
        # small waves reverse the corner normals relative to a display chord.
        # The cubic's centroid faces the chord; the quartic's faces away.
        heights = [0, -2.5, -97 / 6, 3.5, 1] if centroid_inward else [0, -10 / 3, 13 / 3, 1]
        poles = TColgp_Array2OfPnt(1, 2, 1, len(heights))
        for u in range(1, 3):
            for v, height in enumerate(heights, 1):
                poles.SetValue(u, v, gp_Pnt(u - 1, amplitude * (v - 1) / (len(heights) - 1),
                                          amplitude * height))
        surface = Geom_BezierSurface(poles)
        face = cq.Face(BRepBuilderAPI_MakeFace(surface, 1e-9).Face())
        poly = Poly_Triangulation(3, 1, True)
        for index, (u, v) in enumerate([(0, 0), (1, 0), (0, 1)], 1):
            poly.SetNode(index, surface.Value(u, v))
            poly.SetUVNode(index, gp_Pnt2d(u, v))
        poly.SetTriangle(1, Poly_Triangle(1, 2, 3))
        points = [list(poly.Node(index).Coord()) for index in range(1, 4)]
        normals = worker._preview_face_normals(face, poly, TopLoc_Location())
        return face, poly, points, normals

    def triangle_plane(self, points):
        a, b, c = points
        ab = [b[axis] - a[axis] for axis in range(3)]
        ac = [c[axis] - a[axis] for axis in range(3)]
        return [ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2],
                ab[0] * ac[1] - ab[1] * ac[0]]

    def audit_curved_triangle(self, face, poly, points, normals):
        return worker._preview_retriangulate_face(face, poly, points, normals, [[0, 1, 2]],
                                                  lambda: {(0, 1), (0, 2), (1, 2)}, .01)

    def triangle_state(self, poly, points, normals):
        return copy.deepcopy((points, normals,
                              [poly.Node(index).Coord() for index in range(1, poly.NbNodes() + 1)],
                              [poly.UVNode(index).Coord() for index in range(1, poly.NbNodes() + 1)],
                              [poly.Triangle(index).Get() for index in range(1, poly.NbTriangles() + 1)]))

    def test_exact_centroid_normal_resolves_misleading_corner_normal_average(self):
        face, poly, points, normals = self.curved_triangle(1e-5)
        plane = self.triangle_plane(points)
        plane = [value / math.hypot(*plane) for value in plane]
        average = [sum(normal[axis] for normal in normals) / 3 for axis in range(3)]
        self.assertLess(sum(a * b for a, b in zip(plane, average)), -.6)
        point, normal = gp_Pnt(), gp_Vec()
        BRepGProp_Face(face.wrapped).Normal(1 / 3, 1 / 3, point, normal)
        self.assertGreater(sum(a * b for a, b in zip(plane, normal.Normalized().Coord())), .8)
        before = self.triangle_state(poly, points, normals)
        self.assertEqual(self.audit_curved_triangle(face, poly, points, normals), [[0, 1, 2]])
        self.assertEqual(self.triangle_state(poly, points, normals), before,
                         'Orientation auditing must preserve exact lighting normals and native nodes.')

    def test_kernel_sized_surface_wrinkle_preserves_existing_chord_and_normals(self):
        face, poly, points, normals = self.curved_triangle(1e-6, centroid_inward=True)
        plane = self.triangle_plane(points)
        longest = max(math.dist(a, b) for a, b in zip(points, points[1:] + points[:1]))
        self.assertLess(math.hypot(*plane) / longest, worker.GEOMETRY_TOLERANCE_MM)
        point, normal = gp_Pnt(), gp_Vec()
        BRepGProp_Face(face.wrapped).Normal(1 / 3, 1 / 3, point, normal)
        self.assertLess(sum(a * b for a, b in zip(plane, normal.Coord())), 0)
        centroid = [sum(point[axis] for point in points) / 3 for axis in range(3)]
        self.assertLess(math.dist(centroid, point.Coord()), worker.GEOMETRY_TOLERANCE_MM)
        before = self.triangle_state(poly, points, normals)
        self.assertEqual(self.audit_curved_triangle(face, poly, points, normals), [[0, 1, 2]])
        self.assertEqual(self.triangle_state(poly, points, normals), before)

    def test_above_tolerance_curved_fold_remains_rejected(self):
        face, poly, points, normals = self.curved_triangle(1e-3, centroid_inward=True)
        plane = self.triangle_plane(points)
        longest = max(math.dist(a, b) for a, b in zip(points, points[1:] + points[:1]))
        self.assertGreater(math.hypot(*plane) / longest, worker.GEOMETRY_TOLERANCE_MM)
        with self.assertRaises(worker._PreviewMeshError):
            self.audit_curved_triangle(face, poly, points, normals)

    def test_centroid_normal_does_not_hide_large_display_surface_deflection(self):
        face, poly, points, normals = self.curved_triangle(1)
        plane = self.triangle_plane(points)
        point, normal = gp_Pnt(), gp_Vec()
        BRepGProp_Face(face.wrapped).Normal(1 / 3, 1 / 3, point, normal)
        self.assertGreater(sum(a * b for a, b in zip(plane, normal.Coord())), 0)
        centroid = [sum(point[axis] for point in points) / 3 for axis in range(3)]
        self.assertGreater(math.dist(centroid, point.Coord()), .01)
        with self.assertRaises(worker._PreviewMeshError):
            self.audit_curved_triangle(face, poly, points, normals)

    def test_reversed_uv_winding_is_rejected_even_for_a_kernel_sized_sliver(self):
        face, poly, location = self.native_triangle()
        points = [[0., 0., 0.], [1., 0., 0.], [0., 1e-6, 0.]]
        for index, point in enumerate(points, 1):
            poly.SetNode(index, gp_Pnt(*point))
            poly.SetUVNode(index, gp_Pnt2d(point[0], point[1]))
        normals = [list(face.normalAt().toTuple()) for _ in points]
        with self.assertRaises(worker._PreviewMeshError):
            worker._preview_retriangulate_face(face, poly, points, normals, [[0, 2, 1]], lambda: set(), .01)

    def test_narrow_chord_displaced_from_exact_surface_is_rejected(self):
        face, poly, points, normals = self.curved_triangle(1e-6, centroid_inward=True)
        for index, point in enumerate(points, 1):
            point[2] += .001
            poly.SetNode(index, gp_Pnt(*point))
        plane = self.triangle_plane(points)
        longest = max(math.dist(a, b) for a, b in zip(points, points[1:] + points[:1]))
        self.assertLess(math.hypot(*plane) / longest, worker.GEOMETRY_TOLERANCE_MM)
        with self.assertRaises(worker._PreviewMeshError):
            self.audit_curved_triangle(face, poly, points, normals)

    def test_grossly_folded_candidate_bounds_native_orientation_work(self):
        face, seed, points, normals = self.curved_triangle(1e-3, centroid_inward=True)
        count = worker.MAX_PREVIEW_EXACT_ORIENTATION_CELLS + 1
        poly = Poly_Triangulation(count * 3, count, True)
        triangles = []
        for cell in range(count):
            triangle = [cell * 3 + index for index in range(3)]
            triangles.append(triangle)
            for index in range(3):
                poly.SetNode(triangle[index] + 1, seed.Node(index + 1))
                poly.SetUVNode(triangle[index] + 1, seed.UVNode(index + 1))
            poly.SetTriangle(cell + 1, Poly_Triangle(*(node + 1 for node in triangle)))
        # A failed native candidate can contain widespread folds. Retrying
        # another mesher must not first project every cell onto the surface.
        with mock.patch('OCP.BRepGProp.BRepGProp_Face') as native_surface:
            with self.assertRaisesRegex(worker._PreviewMeshError, 'bounded.*budget'):
                worker._preview_retriangulate_face(face, poly, points * count, normals * count,
                                                   triangles, lambda: set(), .01)
            native_surface.assert_not_called()

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
