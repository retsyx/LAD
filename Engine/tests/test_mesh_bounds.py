"""The reconstruction verifier must prove real successes and fail closed.

These fixtures are independently tessellated test references.  A requested
meshing deflection is never passed to the verifier as a certificate.
"""
from pathlib import Path
import math
import sys
import unittest
from unittest import mock

import cadquery as cq
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mesh_bounds as verification


def triangles(shape, linear=0.03, angular=0.35):
    vertices, indices = shape.tessellate(linear, angular)
    return np.array([[vertices[i].toTuple() for i in tri] for tri in indices])


def cylinder_reference(radius=1.0, height=2.0, count=24):
    # Closed inscribed polygonal prism.  Its exact radial deficit at each
    # side's chord midpoint is r*(1-cos(pi/count)), independently of OCCT's
    # tessellator or its requested deflection.
    ring = np.array([(radius * math.cos(2 * math.pi * i / count),
                      radius * math.sin(2 * math.pi * i / count), 0.0)
                     for i in range(count)])
    out = []
    top_center, bottom_center = np.array([0, 0, height]), np.zeros(3)
    for i in range(count):
        a, b = ring[i], ring[(i + 1) % count]
        c, d = a + (0, 0, height), b + (0, 0, height)
        out.extend([(a, b, d), (a, d, c), (bottom_center, b, a),
                    (top_center, c, d)])
    return np.array(out)


class ConservativeMeshVerificationTests(unittest.TestCase):
    def assert_bounded_success(self, mesh, shape, tolerance, max_cells=30000):
        result = verification.verify(mesh, shape, tolerance, max_cells=max_cells)
        self.assertTrue(result['accepted'], result)
        self.assertEqual(result['issues'], [])
        for key in ('source_to_result_deviation', 'result_to_source_deviation'):
            deviation = result['report'][key]
            self.assertTrue(deviation['complete'])
            self.assertEqual(deviation['verification'], 'bounded')
            self.assertGreaterEqual(deviation['lower_bound'], 0)
            self.assertLessEqual(deviation['upper_bound'], tolerance)
        return result

    def test_box_success_is_a_bound_over_faces_not_a_sampling_result(self):
        box = cq.Solid.makeBox(2, 3, 4)
        result = self.assert_bounded_success(triangles(box), box, 1e-5)
        self.assertLess(result['report']['result_to_source_deviation']['upper_bound'], 1e-10)
        method = result['report']['error_verification_method']
        self.assertFalse(method['topology_and_material_verified'])
        self.assertIn('Taylor', method['arithmetic'])

    def test_located_and_rotated_box_keeps_coordinate_scale_and_placement(self):
        box = cq.Solid.makeBox(2, 3, 4).located(cq.Location(cq.Vector(20, -30, 40),
                                                        cq.Vector(1, 2, 3), 37))
        self.assert_bounded_success(triangles(box), box, 0.001)
        self.assert_bounded_success(triangles(box.scale(100)), box.scale(100), 0.1)

    def test_cylinder_positive_and_known_nonzero_chord_error(self):
        mesh = cylinder_reference()
        cylinder = cq.Solid.makeCylinder(1, 2)
        result = self.assert_bounded_success(mesh, cylinder, 0.12)
        sagitta = 1 - math.cos(math.pi / 24)
        for key in ('source_to_result_deviation', 'result_to_source_deviation'):
            self.assertGreaterEqual(result['report'][key]['upper_bound'], sagitta - 1e-14)
        # A much smaller allowance cannot certify this smooth cylinder
        # against the actual faceted reference, even if mesh vertices fit.
        result = verification.verify(mesh, cylinder, sagitta * 0.4, max_cells=1000)
        self.assertFalse(result['accepted'])
        self.assertTrue(result['issues'])

    def test_ten_mm_cylinder_at_thirty_microns_has_a_practical_trim_budget(self):
        cylinder = cq.Solid.makeCylinder(5, 10)
        faces = [verification._Face(face, 0.03) for face in cylinder.Faces()]
        caps = [face for face in faces if face.kind == 'plane']
        self.assertEqual(len(caps), 2)
        for cap in caps:
            self.assertLess(len(cap.boxes), 1000)
            # A capsule must cover the actual circular arc bulge, not just
            # the segment endpoints.  Check an independent sagitta value.
            for a, b, radius in cap.capsules:
                chord = math.hypot(b[0] - a[0], b[1] - a[1])
                if chord > 1e-4:
                    sagitta = 5 - math.sqrt(25 - (chord / 2) ** 2)
                    self.assertGreaterEqual(radius, sagitta)

    def test_drilled_plate_preserves_trimmed_holes_in_both_directions(self):
        plate = cq.Workplane('XY').box(3, 3, 1).faces('>Z').workplane().hole(1).val()
        self.assert_bounded_success(triangles(plate), plate, 0.2)
        # Filling the bore introduces unsupported boundary/material.  This
        # geometric check must not silently certify the changed solid.
        filled = cq.Workplane('XY').box(3, 3, 1).val()
        result = verification.verify(triangles(plate), filled, 0.04, max_cells=600)
        self.assertFalse(result['accepted'])

    def test_periodic_sphere_torus_and_cone_have_real_successes(self):
        shapes = [cq.Solid.makeSphere(1, angleDegrees1=-90, angleDegrees2=90),
                  cq.Solid.makeTorus(2, 0.5), cq.Solid.makeCone(1, 0.4, 2)]
        for shape in shapes:
            with self.subTest(shape=shape.Faces()[0].geomType()):
                self.assert_bounded_success(triangles(shape), shape, 0.2)

    def test_isolated_degenerate_outlier_remains_reference_evidence(self):
        box = cq.Solid.makeBox(2, 3, 4)
        mesh = np.concatenate((triangles(box), np.full((1, 3, 3), 100.0)))
        result = verification.verify(mesh, box, 0.03, max_cells=200)
        self.assertFalse(result['accepted'])
        self.assertFalse(result['report']['source_to_result_deviation']['complete'])

    def test_source_and_result_directions_catch_missing_and_added_boundary(self):
        box = cq.Solid.makeBox(2, 3, 4)
        mesh = triangles(box)
        for reference, result_shape in ((mesh, box.translate((0.3, 0, 0))),
                                         (mesh[:2], box)):
            with self.subTest(triangles=len(reference)):
                result = verification.verify(reference, result_shape, 0.02, max_cells=200)
                self.assertFalse(result['accepted'])
                self.assertEqual(result['issues'][0]['code'], 'INSUFFICIENT_VERIFICATION')

    def test_unsupported_parametric_surface_fails_without_a_faceted_or_sampled_fallback(self):
        from OCP.BRepAdaptor import BRepAdaptor_Curve
        from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
        from OCP.Geom import Geom_SurfaceOfLinearExtrusion
        from OCP.gp import gp_Dir
        edge = cq.Edge.makeSpline([cq.Vector(0, 0, 0), cq.Vector(1, 0, .5), cq.Vector(2, 0, 0)])
        curve = BRepAdaptor_Curve(edge.wrapped).BSpline()
        support = Geom_SurfaceOfLinearExtrusion(curve, gp_Dir(0, 1, 0))
        surface = cq.Face(BRepBuilderAPI_MakeFace(support, curve.FirstParameter(), curve.LastParameter(), 0, 2, 1e-9).Face())
        result = verification.verify(triangles(surface), surface, 0.1)
        self.assertFalse(result['accepted'])
        self.assertIn('Surface', result['issues'][0]['explanation'])
        self.assertIsNone(result['report']['result_to_source_deviation']['upper_bound'])

    def test_resource_limit_and_zero_deviation_are_explicit_incomplete_results(self):
        box = cq.Solid.makeBox(2, 3, 4)
        for allowance, budget in ((0.03, 1), (0.0, 1000)):
            result = verification.verify(triangles(box), box, allowance, max_cells=budget)
            self.assertFalse(result['accepted'])
            self.assertEqual(result['issues'][0]['code'], 'INSUFFICIENT_VERIFICATION')
        result = verification.verify(triangles(box), box, 0.001, arithmetic_margin=0.002)
        self.assertFalse(result['accepted'])

    def test_face_domain_cover_does_not_trust_a_truncated_uvbounds_estimate(self):
        from OCP.BRepTools import BRepTools
        box = cq.Solid.makeBox(2, 3, 4)
        mesh = triangles(box)
        with mock.patch.object(BRepTools, 'UVBounds_s', return_value=(0.1, 0.2, 0.1, 0.2)):
            self.assert_bounded_success(mesh, box, 1e-5)

    def test_outward_operations_enclose_exact_binary_rational_arithmetic(self):
        from fractions import Fraction as F
        values = [0.0, -0.0, 0.1, -0.3, 1.0, math.nextafter(1, 2),
                  1e-200, -1e-200, 1e100, -1e100,
                  float.fromhex('0x0.0000000000001p-1022')]
        for a in values:
            for b in values:
                operations = [(verification._I(a) + b, F(a) + F(b)),
                              (verification._I(a) * b, F(a) * F(b))]
                if b:
                    operations.append((verification._I(a) / b, F(a) / F(b)))
                for interval, exact in operations:
                    if math.isfinite(interval.lo):
                        self.assertLessEqual(F(interval.lo), exact)
                    if math.isfinite(interval.hi):
                        self.assertGreaterEqual(F(interval.hi), exact)
        for coordinates in ((0, 0, 0), (1, 1, 1), (1e-200, -1e-200, 1e-200),
                            (0.1, -0.3, math.nextafter(1, 2))):
            upper = verification._norm_upper(coordinates)
            self.assertGreaterEqual(F(upper) ** 2, sum((F(x) ** 2 for x in coordinates), F(0)))

    def test_trigonometric_enclosures_include_independent_libm_values(self):
        # This regression checks the implemented polynomial/remainder and
        # range reduction across quadrants.  The enclosure's justification
        # is the Taylor inequality, rather than assuming libm is exact.
        for t in np.linspace(-100, 100, 129):
            s, c = verification._sincos(float(t))
            self.assertLessEqual(s.lo, math.sin(t))
            self.assertGreaterEqual(s.hi, math.sin(t))
            self.assertLessEqual(c.lo, math.cos(t))
            self.assertGreaterEqual(c.hi, math.cos(t))


if __name__ == '__main__':
    unittest.main()
