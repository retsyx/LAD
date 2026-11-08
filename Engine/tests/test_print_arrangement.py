"""Mesh-free printing placement, checked against exact exported CAD solids."""
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


def bounds(shape):
    from OCP.BRepBndLib import BRepBndLib
    from OCP.Bnd import Bnd_Box
    box = Bnd_Box()
    BRepBndLib.AddOptimal_s(shape.wrapped, box, False, False)
    return box.Get()


class PrintArrangementTests(unittest.TestCase):
    def rounded_enclosure(self, depth):
        import cadquery as cq
        outer = cq.Workplane('XY').box(59, 33.6, depth).edges('|Z').fillet(4).val()
        inner = (cq.Workplane('XY').box(56.6, 31.2, depth + 2).edges('|Z').fillet(2.8)
                 .translate((0, 0, 2.2)).val())
        shape = outer.cut(inner).cut(cq.Solid.makeBox(14, 8, 6, cq.Vector(-7, -20, -1)))
        for x in (-21, 21):
            for y in (-10, 10):
                boss = cq.Solid.makeCylinder(2.8, depth - 1.2, cq.Vector(x, y, -depth / 2 + 1.2))
                bore = cq.Solid.makeCylinder(1.2, depth + 2, cq.Vector(x, y, -depth / 2))
                shape = shape.fuse(boss).cut(bore)
        return shape.clean().Solids()[0]

    def assert_grounded_and_separate(self, solids):
        boxes = [bounds(solid) for solid in solids]
        for box in boxes:
            self.assertAlmostEqual(box[2], 0, places=6)
        for index, a in enumerate(boxes):
            for b in boxes[index + 1:]:
                clearance = max(b[0] - a[3], a[0] - b[3], b[1] - a[4], a[1] - b[4])
                self.assertGreaterEqual(clearance, 50 - 1e-6)

    def native_export(self, folder, shape, **options):
        import cadquery as cq
        from OCP import BRepMesh
        worker.write_brep(shape, folder / 'source.brep')
        request = folder / 'request.json'
        request.write_text(json.dumps({'operation': 'export', 'brepAsset': 'source.brep', **options}))
        with (mock.patch.object(worker, 'build_shape', side_effect=AssertionError('No program replay')),
              mock.patch.object(worker, 'make_preview', side_effect=AssertionError('No display meshing')),
              mock.patch.object(BRepMesh, 'BRepMesh_IncrementalMesh', side_effect=AssertionError('No tessellation'))):
            report = worker.run(request, folder, 2)
        return cq.importers.importStep(report['stepPath']).val().Solids()

    def test_places_each_exact_solid_on_bed_without_mutating_inputs(self):
        import cadquery as cq
        originals = [
            cq.Solid.makeBox(8, 18, 2).rotate((0, 0, 0), (1, 2, 1), 61).translate((30, -5, 17)),
            cq.Solid.makeCylinder(3, 14).rotate((0, 0, 0), (0, 1, 0), 90).translate((-9, 21, -4)),
            cq.Solid.makeBox(5, 7, 9).translate((18, 20, 33)),
            cq.Solid.makeSphere(4, angleDegrees1=-90).translate((80, 60, 20)),
        ]
        before = [(bounds(solid), solid.Center().toTuple()) for solid in originals]
        arranged = worker.arrange_print_solids(originals, cq)
        self.assertEqual(len(arranged), len(originals))
        self.assert_grounded_and_separate(arranged)
        for original, placed in zip(originals, arranged):
            self.assertAlmostEqual(placed.Volume(), original.Volume(), places=6)
            self.assertAlmostEqual(placed.Area(), original.Area(), places=6)
            self.assertEqual(len(placed.Faces()), len(original.Faces()))
            self.assertTrue(placed.isValid())
        self.assertEqual(before, [(bounds(solid), solid.Center().toTuple()) for solid in originals])

    def test_translated_native_instances_share_orientation_only_within_one_export(self):
        import cadquery as cq
        part = cq.Solid.makeBox(8, 15, 2)
        copies = [part.moved(cq.Location((index * 30, index * -4, 10 + index))) for index in range(4)]
        rotated = part.moved(cq.Location((50, 20, 30), (1, 2, 3), 37))
        copies += [rotated, rotated.moved(cq.Location((100, -20, 40)))]
        self.assertTrue(all(solid.wrapped.IsPartner(part.wrapped) for solid in copies))
        with mock.patch.object(worker, 'print_orientation', wraps=worker.print_orientation) as orient:
            arranged = worker.arrange_print_solids(copies, cq)
            self.assertEqual(orient.call_count, 2, 'Translation shares work; a distinct rotation is scored independently')
            worker.arrange_print_solids(copies, cq)
            self.assertEqual(orient.call_count, 4, 'Orientation statistics must not survive an export')
        self.assert_grounded_and_separate(arranged)
        for original, placed in zip(copies, arranged):
            self.assertTrue(placed.wrapped.IsPartner(original.wrapped))
            self.assertEqual(len(placed.Faces()), len(original.Faces()))
            self.assertAlmostEqual(placed.Volume(), original.Volume(), places=6)

    def test_splitting_planar_faces_does_not_change_candidate_directions(self):
        import cadquery as cq
        whole = cq.Solid.makeBox(10, 12, 3)
        split = cq.Solid.makeBox(5, 12, 3).fuse(cq.Solid.makeBox(5, 12, 3, cq.Vector(5, 0, 0))).Solids()[0]
        self.assertGreater(len(split.Faces()), len(whole.Faces()))
        candidates = []
        for solid in (whole, split):
            _, _, weights, planes, axes = worker._print_surface_samples(solid)
            self.assertAlmostEqual(sum(weights), solid.Area(), places=6)
            directions = worker._print_candidates(solid, planes, axes)
            candidates.append({tuple(round(float(value), 6) for value in direction) for direction in directions})
        self.assertEqual(candidates[0], candidates[1])
        placed = worker.arrange_print_solids([whole, split], cq)
        for solid in placed:
            self.assertAlmostEqual(bounds(solid)[5], 3, places=6)

    def test_trimmed_freeform_surface_samples_stay_on_native_boundary(self):
        import cadquery as cq
        from OCP import BRepMesh
        from OCP.BRepClass3d import BRepClass3d_SolidClassifier
        from OCP.TopAbs import TopAbs_ON
        from OCP.gp import gp_Pnt
        loft = cq.Workplane('XY').ellipse(7, 5).workplane(offset=4).ellipse(5, 7).workplane(offset=5).ellipse(4, 3).loft(combine=False).val()
        solid = loft.cut(cq.Solid.makeCylinder(2, 20, cq.Vector(4, 0, -5))).Solids()[0]
        self.assertTrue(any(face.geomType() == 'BSPLINE' for face in solid.Faces()))
        with mock.patch.object(BRepMesh, 'BRepMesh_IncrementalMesh', side_effect=AssertionError('No tessellation')):
            normals, points, weights, planes, _ = worker._print_surface_samples(solid)
            placed = worker.arrange_print_solids([solid], cq)[0]
        self.assertGreater(len(normals), len(planes) + 10)
        self.assertAlmostEqual(sum(weights), solid.Area(), places=6)
        for normal, point, weight in zip(normals, points, weights):
            self.assertTrue(all(math.isfinite(value) for value in (*normal, *point, weight)))
            self.assertAlmostEqual(sum(value * value for value in normal), 1, places=6)
            self.assertGreater(weight, 0)
            self.assertEqual(BRepClass3d_SolidClassifier(solid.wrapped, gp_Pnt(*point), 1e-6).State(), TopAbs_ON)
        self.assertAlmostEqual(bounds(placed)[2], 0, places=6)
        self.assertAlmostEqual(placed.Volume(), solid.Volume(), places=6)

    def test_rotated_cylinder_and_trimmed_bore_print_along_their_axes(self):
        import cadquery as cq
        cylinder = cq.Solid.makeCylinder(3, 17)
        tube = cq.Solid.makeCylinder(5, 19).cut(cq.Solid.makeCylinder(4, 19)).Solids()[0]
        for solid, height, diameter in [(cylinder, 17, 6), (tube, 19, 10)]:
            with self.subTest(height=height):
                rotated = solid.rotate((0, 0, 0), (1, 2, 3), 73).translate((10, 20, 30))
                placed = worker.arrange_print_solids([rotated], cq)[0]
                box = bounds(placed)
                self.assertAlmostEqual(box[5] - box[2], height, places=5)
                self.assertAlmostEqual(box[3] - box[0], diameter, places=5)
                self.assertAlmostEqual(box[4] - box[1], diameter, places=5)
                self.assertAlmostEqual(box[2], 0, places=6)
                self.assertAlmostEqual(placed.Volume(), solid.Volume(), places=6)

    def test_recess_floor_is_not_mistaken_for_bed_contact(self):
        import cadquery as cq
        tray = cq.Solid.makeBox(30, 25, 8).cut(cq.Solid.makeBox(26, 21, 6, cq.Vector(2, 2, 2))).Solids()[0]
        tray = tray.rotate((0, 0, 0), (1, 0, 0), 180).translate((10, 30, 40))
        placed = worker.arrange_print_solids([tray], cq)[0]
        floor = next(face for face in placed.Faces() if math.isclose(face.Area(), 546, abs_tol=1e-6))
        self.assertGreater(floor.normalAt().z, .99999)
        self.assertAlmostEqual(floor.Center().z, 2, places=5)
        self.assertAlmostEqual(bounds(placed)[2], 0, places=6)

    def test_rounded_enclosure_halves_rest_on_exterior_bases(self):
        import cadquery as cq
        from OCP import BRepMesh
        originals = [self.rounded_enclosure(14).rotate((0, 0, 0), (1, 2, 3), 73),
                     self.rounded_enclosure(8).rotate((0, 0, 0), (0, 1, 0), 180)]
        before = [(bounds(solid), solid.Center().toTuple()) for solid in originals]
        with mock.patch.object(BRepMesh, 'BRepMesh_IncrementalMesh', side_effect=AssertionError('No tessellation')):
            placed = worker.arrange_print_solids(originals, cq)
        self.assert_grounded_and_separate(placed)
        for original, actual, depth in zip(originals, placed, (14, 8)):
            planes = [face for face in actual.Faces() if face.geomType() == 'PLANE']
            exterior = max(planes, key=lambda face: face.Area())
            floor = sorted(planes, key=lambda face: -face.Area())[1]
            self.assertLess(exterior.normalAt().z, -.99999, 'The enclosure must not balance on a tilted edge')
            self.assertAlmostEqual(exterior.Center().z, 0, places=6)
            self.assertGreater(floor.normalAt().z, .99999)
            self.assertAlmostEqual(floor.Center().z, 1.2, places=6)
            self.assertAlmostEqual(bounds(actual)[5], depth, places=5)
            self.assertAlmostEqual(actual.Volume(), original.Volume(), places=6)
            self.assertAlmostEqual(actual.Area(), original.Area(), places=6)
            self.assertTrue(actual.wrapped.IsPartner(original.wrapped))
        self.assertEqual(before, [(bounds(solid), solid.Center().toTuple()) for solid in originals])

    def test_contact_stability_uses_boundary_support_with_holes_and_islands(self):
        import cadquery as cq
        from OCP.gp import gp_Dir
        disk = cq.Solid.makeCylinder(5, 4)
        ring = disk.cut(cq.Solid.makeCylinder(3, 4)).Solids()[0]
        bridge = (cq.Solid.makeBox(3, 6, 6, cq.Vector(-12, -3, 0))
                  .fuse(cq.Solid.makeBox(3, 6, 6, cq.Vector(9, -3, 0)))
                  .fuse(cq.Solid.makeBox(24, 6, 2, cq.Vector(-12, -3, 4))).clean().Solids()[0])
        location = cq.Location((17, -12, 20), (1, 2, 3), 67)
        direction = gp_Dir(0, 0, 1).Transformed(location.wrapped.Transformation()).Coord()
        for name, solid in [('disk', disk), ('ring', ring), ('separate feet', bridge)]:
            with self.subTest(contact=name):
                faces = [face for face in solid.Faces() if face.geomType() == 'PLANE'
                         and face.normalAt().z < -.99999 and abs(face.Center().z) < 1e-6]
                self.assertTrue(worker._print_contact_is_stable(faces, (0, 0, 1), solid.Center().toTuple()))
                rotated = solid.moved(location)
                self.assertTrue(worker._print_contact_is_stable([face.moved(location) for face in faces],
                                                                direction, rotated.Center().toTuple()))
                self.assertFalse(worker._print_contact_is_stable(faces, (0, 0, 1), (100, 0, 2)))

    def test_contact_stability_rejects_an_eccentric_pad(self):
        import cadquery as cq
        solid = (cq.Solid.makeBox(2, 2, 2, cq.Vector(-10, -1, 0))
                 .fuse(cq.Solid.makeBox(24, 4, 2, cq.Vector(-10, -2, 2))).clean().Solids()[0])
        centroid = solid.Center().toTuple()
        bottom = [face for face in solid.Faces() if face.geomType() == 'PLANE'
                  and face.normalAt().z < -.99999 and abs(face.Center().z) < 1e-6]
        top = [face for face in solid.Faces() if face.geomType() == 'PLANE'
               and face.normalAt().z > .99999 and abs(face.Center().z - 4) < 1e-6]
        self.assertGreater(centroid[0], -8, 'The volume centroid lies outside the actual support pad')
        self.assertFalse(worker._print_contact_is_stable(bottom, (0, 0, 1), centroid))
        self.assertTrue(worker._print_contact_is_stable(top, (0, 0, -1), centroid))

    def test_steep_cone_uses_curved_normals_to_avoid_downward_overhang(self):
        import cadquery as cq
        cone = cq.Solid.makeCone(10, 1, 4).rotate((0, 0, 0), (1, 2, 3), 151)
        placed = worker.arrange_print_solids([cone], cq)[0]
        base = max((face for face in placed.Faces() if face.geomType() == 'PLANE'), key=lambda face: face.Area())
        self.assertLess(base.normalAt().z, -.99999)
        self.assertAlmostEqual(base.Center().z, 0, places=6)
        self.assertAlmostEqual(bounds(placed)[5], 4, places=5)

    def test_bracket_avoids_unsupported_planar_undersides(self):
        import cadquery as cq
        bracket = cq.Solid.makeBox(20, 14, 2).fuse(cq.Solid.makeBox(2, 14, 16)).clean().Solids()[0]
        bracket = bracket.rotate((0, 0, 0), (0, 1, 0), 180)
        placed = worker.arrange_print_solids([bracket], cq)[0]
        unsupported_area = sum(face.Area() for face in placed.Faces()
                               if face.normalAt().z < -math.sqrt(.5) and face.Center().z > 1e-5)
        self.assertAlmostEqual(unsupported_area, 0, places=6)

    def test_native_selected_export_is_arranged_and_default_export_preserves_coordinates(self):
        import cadquery as cq
        solids = [cq.Solid.makeBox(4, 8, 2).translate((80, 12, 10)),
                  cq.Solid.makeCylinder(3, 12).rotate((0, 0, 0), (1, 0, 0), 90).translate((-20, 30, 20)),
                  cq.Solid.makeBox(3, 4, 5).translate((12, -40, 70))]
        shape = cq.Compound.makeCompound(solids)
        with tempfile.TemporaryDirectory() as directory:
            original = self.native_export(Path(directory), shape, solidIndices=[1, 2])
            for actual, expected in zip(original, solids[1:]):
                for coordinate, value in zip(actual.Center().toTuple(), expected.Center().toTuple()):
                    self.assertAlmostEqual(coordinate, value, places=6)
        with tempfile.TemporaryDirectory() as directory:
            placed = self.native_export(Path(directory), shape, solidIndices=[1, 2], arrangeFor3DPrinting=True)
            self.assertEqual(len(placed), 2)
            self.assert_grounded_and_separate(placed)
            for actual, expected in zip(placed, solids[1:]):
                self.assertAlmostEqual(actual.Volume(), expected.Volume(), places=6)
                self.assertAlmostEqual(actual.Area(), expected.Area(), places=6)

    def test_arrangement_option_requires_boolean(self):
        import cadquery as cq
        for value in (1, 'true', [], None):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(worker.ModelError):
                    self.native_export(Path(directory), cq.Solid.makeBox(1, 2, 3), arrangeFor3DPrinting=value)
                self.assertFalse((Path(directory) / 'model.step').exists())


if __name__ == '__main__':
    unittest.main()
