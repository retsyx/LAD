"""Lighting follows exact CAD surfaces, independently of mesh facet layout."""
import math
from pathlib import Path
import sys
import unittest

import cadquery as cq
from OCP.BRep import BRep_Tool
from OCP.BRepGProp import BRepGProp_Face
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.TopAbs import TopAbs_Orientation
from OCP.TopLoc import TopLoc_Location
from OCP.gp import gp_Dir, gp_Pnt, gp_Vec

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import _preview_face_normals, make_preview, mesh_to_solid


class PreviewNormalTests(unittest.TestCase):
    def test_sphere_seam_and_both_singular_poles_have_exact_radial_normals(self):
        preview = make_preview(cq.Solid.makeSphere(3, angleDegrees1=-90, angleDegrees2=90))
        self.assert_unit_normals(preview)
        poles = set()
        for point, normal in zip(preview["vertices"], preview["normals"]):
            self.assert_direction(normal, self.unit(point))
            if abs(abs(point[2]) - 3) < 1e-8:
                poles.add(round(point[2]))
        self.assertEqual(poles, {-3, 3}, "The fixture must include both singular surface poles.")

    def test_cylinder_curvature_is_exact_and_cap_rims_retain_hard_normals(self):
        shape = cq.Solid.makeCylinder(3, 4)
        preview = make_preview(shape)
        self.assert_unit_normals(preview)
        shared = {}
        for face, offset, poly, _ in self.face_chunks(shape):
            for index in range(poly.NbNodes()):
                point = preview["vertices"][offset + index]
                normal = preview["normals"][offset + index]
                expected = self.unit([point[0], point[1], 0]) if face.geomType() == "CYLINDER" else [0, 0, -1 if point[2] < 2 else 1]
                self.assert_direction(normal, expected)
                shared.setdefault(tuple(round(value, 7) for value in point), []).append(normal)
        hard_seams = [values for values in shared.values() if len(values) > 1
                      and any(abs(self.dot(values[0], other)) < 0.1 for other in values[1:])]
        self.assertGreater(len(hard_seams), 20, "Cap and side normals must stay separate at the same rim positions.")

    def test_torus_inner_and_outer_surfaces_follow_the_analytic_normal(self):
        preview = make_preview(cq.Solid.makeTorus(5, 1))
        self.assert_unit_normals(preview)
        inner, outer = False, False
        for point, normal in zip(preview["vertices"], preview["normals"]):
            radius = math.hypot(point[0], point[1])
            expected = self.unit([(radius - 5) * point[0] / radius,
                                  (radius - 5) * point[1] / radius, point[2]])
            self.assert_direction(normal, expected)
            inner |= radius < 4.1
            outer |= radius > 5.9
        self.assertTrue(inner and outer)

    def test_bspline_fillets_match_surface_derivatives_not_triangle_averages(self):
        # NURBS conversion retains the rounded box exactly while representing
        # its planes, cylindrical blends and spherical corners as B-splines.
        shape = cq.Workplane("XY").box(8, 6, 4).edges().fillet(0.6).val().toNURBS()
        self.assertEqual({face.geomType() for face in shape.Faces()}, {"BSPLINE"})
        preview = make_preview(shape)
        self.assert_unit_normals(preview)
        worst_old_error = 0
        for face, offset, poly, _ in self.face_chunks(shape):
            old = self.old_averaged_normals(preview, offset, poly.NbNodes())
            for index in range(poly.NbNodes()):
                uv = poly.UVNode(index + 1)
                point, expected = gp_Pnt(), gp_Vec()
                BRepGProp_Face(face.wrapped).Normal(uv.X(), uv.Y(), point, expected)
                if expected.Magnitude() <= 1e-10:
                    continue  # A singular pole is covered analytically above.
                exact = list(expected.Normalized().Coord())
                self.assert_direction(preview["normals"][offset + index], exact)
                if old[index] is not None:
                    worst_old_error = max(worst_old_error, self.angle(old[index], exact))
        self.assertGreater(worst_old_error, 0.5,
                           "The fixture must expose the visibly wrong polygon-derived lighting normals.")

    def test_locations_and_reversed_face_orientation_are_applied_once(self):
        shape = cq.Solid.makeCylinder(3, 4).located(cq.Location((12, -7, 4), (1, 2, 0), 37))
        preview = make_preview(shape)
        self.assert_unit_normals(preview)
        saw_reversed = False
        for face, offset, poly, location in self.face_chunks(shape):
            saw_reversed |= face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED
            for index in range(poly.NbNodes()):
                uv = poly.UVNode(index + 1)
                point, vector = gp_Pnt(), gp_Vec()
                BRepGProp_Face(face.wrapped).Normal(uv.X(), uv.Y(), point, vector)
                self.assert_direction(preview["normals"][offset + index], self.unit(vector.Coord()))
            opposite = cq.Face(face.wrapped.Reversed())
            reversed_normals = _preview_face_normals(opposite, poly, location)
            for index, normal in enumerate(reversed_normals):
                self.assert_direction(normal, [-value for value in preview["normals"][offset + index]])
        self.assertTrue(saw_reversed, "The solid's bottom cap must exercise a naturally reversed face.")

    def test_existing_averaged_normals_are_replaced_without_changing_geometry(self):
        shape = cq.Solid.makeCylinder(3, 4)
        BRepMesh_IncrementalMesh(shape.wrapped, 0.01, False, 0.15, True)
        side = next(face for face in shape.Faces() if face.geomType() == "CYLINDER")
        location = TopLoc_Location()
        poly = BRep_Tool.Triangulation_s(side.wrapped, location)
        before = self.poly_geometry(poly)
        poly.AddNormals()
        for index in range(1, poly.NbNodes() + 1):
            poly.SetNormal(index, gp_Dir(0, 0, 1))
        normals = _preview_face_normals(side, poly, location)
        self.assertEqual(self.poly_geometry(poly), before)
        for index, normal in enumerate(normals):
            point = poly.Node(index + 1).Coord()
            self.assert_direction(normal, self.unit([point[0], point[1], 0]))

    def test_missing_uvs_project_only_that_face_to_the_exact_located_surface(self):
        shape = cq.Solid.makeCylinder(3, 4).located(cq.Location((12, -7, 4), (0, 1, 0), 37))
        BRepMesh_IncrementalMesh(shape.wrapped, 0.01, False, 0.15, True)
        side = next(face for face in shape.Faces() if face.geomType() == "CYLINDER")
        location = TopLoc_Location()
        poly = BRep_Tool.Triangulation_s(side.wrapped, location)
        exact = _preview_face_normals(side, poly, location)
        before = self.poly_geometry(poly)
        poly.RemoveUVNodes()
        recovered = _preview_face_normals(side, poly, location)
        self.assertEqual(self.poly_geometry(poly), before)
        for actual, expected in zip(recovered, exact):
            self.assert_direction(actual, expected)

    def test_cone_apex_stays_finite_and_planar_mesh_imports_stay_faceted(self):
        cone = make_preview(cq.Solid.makeCone(3, 0, 4))
        self.assert_unit_normals(cone)
        self.assertTrue(any(abs(point[2] - 4) < 1e-8 for point in cone["vertices"]))
        a, b, c, d = (0, 0, 0), (3, 0, 0), (0, 3, 0), (0, 0, 3)
        imported = mesh_to_solid([[a, c, b], [a, b, d], [b, c, d], [c, a, d]], cq)
        preview = make_preview(imported)
        self.assert_unit_normals(preview)
        centroid = imported.Center().toTuple()
        for face, offset, poly, _ in self.face_chunks(imported):
            self.assertEqual(face.geomType(), "PLANE")
            normals = preview["normals"][offset:offset + poly.NbNodes()]
            for index, normal in enumerate(normals):
                self.assert_direction(normal, normals[0])
                outward = [preview["vertices"][offset + index][axis] - centroid[axis] for axis in range(3)]
                self.assertGreater(self.dot(normal, outward), 0,
                                   "Each imported planar face must retain its own outward normal.")

    def face_chunks(self, shape):
        offset = 0
        for solid in shape.Solids():
            for face in solid.Faces():
                location = TopLoc_Location()
                poly = BRep_Tool.Triangulation_s(face.wrapped, location)
                if poly is not None:
                    yield face, offset, poly, location
                    offset += poly.NbNodes()

    def assert_unit_normals(self, preview):
        self.assertEqual(len(preview["normals"]), len(preview["vertices"]))
        for normal in preview["normals"]:
            self.assertEqual(len(normal), 3)
            self.assertTrue(all(math.isfinite(value) for value in normal))
            self.assertAlmostEqual(self.dot(normal, normal), 1, places=7)

    def assert_direction(self, actual, expected):
        self.assertGreater(self.dot(actual, expected), 1 - 1e-11)

    @staticmethod
    def unit(vector):
        length = math.hypot(*vector)
        return [value / length for value in vector]

    @staticmethod
    def dot(first, second):
        return sum(a * b for a, b in zip(first, second))

    def angle(self, first, second):
        return math.degrees(math.acos(max(-1, min(1, self.dot(first, second)))))

    @staticmethod
    def poly_geometry(poly):
        return ([poly.Node(index).Coord() for index in range(1, poly.NbNodes() + 1)],
                [poly.Triangle(index).Get() for index in range(1, poly.NbTriangles() + 1)])

    def old_averaged_normals(self, preview, offset, count):
        sums = [[0, 0, 0] for _ in range(count)]
        for triangle in preview["triangles"]:
            if not all(offset <= index < offset + count for index in triangle):
                continue
            a, b, c = [preview["vertices"][index] for index in triangle]
            ab, ac = [[end[axis] - a[axis] for axis in range(3)] for end in (b, c)]
            cross = [ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0]]
            for index in triangle:
                sums[index - offset] = [left + right for left, right in zip(sums[index - offset], cross)]
        return [self.unit(vector) if math.hypot(*vector) > 1e-24 else None for vector in sums]


if __name__ == "__main__":
    unittest.main()
