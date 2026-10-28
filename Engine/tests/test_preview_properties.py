"""Exact preview measurements reuse native integrals without losing semantics."""
import math
from pathlib import Path
import sys
import unittest

import cadquery as cq
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.TopAbs import TopAbs_EDGE
from OCP.TopExp import TopExp_Explorer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import _shape_measurements, _wire_length, face_metadata, part_metadata


class PreviewPropertyTests(unittest.TestCase):
    @staticmethod
    def solids():
        hollow = cq.Workplane("XY").rect(8, 6).circle(1).extrude(3).val()
        curved = cq.Workplane("XY").box(8, 6, 4).edges().fillet(0.6).val().toNURBS()
        rotated = cq.Solid.makeCylinder(3, 5).located(cq.Location((12, -7, 4), (1, 2, 0), 37))
        return [hollow, curved, rotated, cq.Solid.makeTorus(5, 1),
                cq.Solid.makeSphere(3, angleDegrees1=-90, angleDegrees2=90)]

    def assert_point_equal(self, actual, expected):
        self.assertEqual(len(actual), 3)
        for value, reference in zip(actual, expected):
            self.assertTrue(math.isclose(value, reference, rel_tol=1e-12, abs_tol=1e-12),
                            f"Exact centroid changed: {actual} != {expected}")

    def test_face_area_and_centroid_match_cadquery_for_curves_holes_locations_and_reversals(self):
        types = set()
        for owner, solid in enumerate(self.solids()):
            for local, face in enumerate(solid.Faces()):
                types.add(face.geomType())
                for candidate in [face, cq.Face(face.wrapped.Reversed())]:
                    with self.subTest(owner=owner, face=local, type=candidate.geomType()):
                        metadata = face_metadata(candidate, owner, local)
                        self.assertEqual(metadata["area"], candidate.Area())
                        self.assert_point_equal(metadata["center"], candidate.Center().toTuple())
                        self.assertEqual(metadata["perimeter"], sum(wire.Length() for wire in candidate.Wires()))
                        self.assertEqual(metadata["id"], {"kind": "face", "solidIndex": owner, "localIndex": local})
        self.assertTrue({"PLANE", "CYLINDER", "BSPLINE", "TORUS", "SPHERE"} <= types)

    def test_part_volume_and_centroid_match_cadquery_with_cavities_and_located_solids(self):
        for index, solid in enumerate(self.solids()):
            with self.subTest(part=index):
                metadata = part_metadata(solid, index)
                self.assertEqual(metadata["solidIndex"], index)
                self.assertEqual(metadata["volume"], solid.Volume())
                self.assertEqual(metadata["area"], solid.Area())
                self.assert_point_equal(metadata["centroid"], solid.Center().toTuple())
                self.assertEqual(len(metadata["bounds"]), 6)
        hollow = self.solids()[0]
        volume, centroid = _shape_measurements(hollow, volume=True)
        self.assertAlmostEqual(volume, (8 * 6 - math.pi) * 3, places=10)
        self.assert_point_equal(centroid, [0, 0, 1.5])

    def test_coarse_display_triangulation_does_not_approximate_measurements(self):
        for solid in self.solids():
            expected_volume = solid.Volume()
            expected_center = solid.Center().toTuple()
            expected_faces = [(face.Area(), face.Center().toTuple()) for face in solid.Faces()]
            mesher = BRepMesh_IncrementalMesh(solid.wrapped, 0.6, False, 0.8, True)
            self.assertTrue(mesher.IsDone())
            actual_volume, actual_center = _shape_measurements(solid, volume=True)
            self.assertEqual(actual_volume, expected_volume)
            self.assert_point_equal(actual_center, expected_center)
            for face, (area, center) in zip(solid.Faces(), expected_faces):
                actual_area, actual_center = _shape_measurements(face)
                self.assertEqual(actual_area, area)
                self.assert_point_equal(actual_center, center)

    def test_wire_integrals_retain_single_curves_closed_seams_holes_and_composite_boundaries(self):
        annulus = cq.Workplane("XY").circle(5).circle(2).extrude(1).val()
        cylinder = cq.Solid.makeCylinder(3, 5)
        side = next(face for face in cylinder.Faces() if face.geomType() == "CYLINDER")
        seam_wire = side.Wires()[0]
        explorer = TopExp_Explorer(seam_wire.wrapped, TopAbs_EDGE)
        occurrences = []
        while explorer.More():
            occurrences.append(explorer.Current())
            explorer.Next()
        self.assertTrue(any(first.IsSame(second) for index, first in enumerate(occurrences)
                            for second in occurrences[index + 1:]),
                        "The cylindrical face fixture must retain both occurrences of its seam.")
        annular_face = next(face for face in annulus.Faces() if len(face.Wires()) == 2)
        self.assertEqual(face_metadata(annular_face, 0, 0)["perimeter"],
                         sum(wire.Length() for wire in annular_face.Wires()))
        wires = [cq.Wire.assembleEdges([cq.Edge.makeCircle(3)]),
                 cq.Wire.assembleEdges([cq.Edge.makeCircle(3, angle1=20, angle2=160)]), seam_wire]
        for solid in self.solids() + [annulus]:
            wires.extend(wire for face in solid.Faces() for wire in face.Wires())
        for index, wire in enumerate(wires):
            with self.subTest(wire=index):
                self.assertEqual(_wire_length(wire), wire.Length(),
                                 "Use the same native integration path, not a sum of separately integrated edges.")


if __name__ == "__main__":
    unittest.main()
