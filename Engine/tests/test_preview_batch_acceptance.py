"""Batch acceptance of healthy faces matches the per-face audit exactly."""
from collections import Counter
from pathlib import Path
import math
import sys
import unittest
from unittest import mock

import cadquery as cq
import numpy as np
from OCP.BRep import BRep_Tool
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.TopLoc import TopLoc_Location
from OCP.TopAbs import TopAbs_Orientation
from OCP.gp import gp_TrsfForm

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


def located_parts():
    """Identity, translated and rotated placements of shared solids."""
    box = cq.Solid.makeBox(2, 3, 4)
    turned = cq.Location(cq.Vector(0, 9, 0), cq.Vector(1, 1, 0), 35)
    return cq.Compound.makeCompound([box, box.moved(cq.Location((5, 0, 0))), box.moved(turned)])


def curved_parts():
    """Pole, apex and seam boundaries, including collapsed native edges."""
    block = cq.Solid.makeBox(4, 4, 4, cq.Vector(40, 0, 0))
    return cq.Compound.makeCompound([
        cq.Solid.makeSphere(3),
        cq.Solid.makeCone(3, 0, 5, cq.Vector(10, 0, 0)),
        cq.Solid.makeCylinder(2, 5, cq.Vector(20, 0, 0)),
        cq.Solid.makeTorus(4, 1, cq.Vector(32, 0, 0)),
        block.fillet(1, block.Edges()),
    ])


class PreviewBatchAcceptanceTests(unittest.TestCase):
    def setUp(self):
        worker.configure_threads(2)

    def test_batch_acceptance_matches_the_per_face_audit(self):
        for build in (located_parts, curved_parts):
            with self.subTest(build.__name__):
                audit = worker._preview_face_triangles
                with mock.patch.object(worker, "_preview_face_triangles", side_effect=audit) as audited:
                    batched = worker.make_preview(build())
                faces = len(batched["topology"]["faces"])
                self.assertLess(audited.call_count, faces, "Healthy faces are accepted without the per-face audit.")
                with mock.patch.object(worker, "_preview_accept_faces", return_value={}):
                    per_face = worker.make_preview(build())
                self.assertEqual(batched, per_face)

    def test_node_and_normal_reads_match_per_node_transforms(self):
        shape = located_parts()
        BRepMesh_IncrementalMesh(shape.wrapped, 0.05, False, 0.3, True)
        forms = Counter()
        for face in worker._shape_entities(shape, "Face"):
            location = TopLoc_Location()
            poly = BRep_Tool.Triangulation_s(face.wrapped, location)
            transform = location.Transformation()
            form = transform.Form()
            forms[form] += 1
            nodes = range(1, poly.NbNodes() + 1)
            self.assertEqual(worker._preview_face_points(poly, location),
                             [list(poly.Node(index).Transformed(transform).Coord()) for index in nodes])
            worker._preview_face_normals(face, poly, location)
            reverse = face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED
            fast = worker._preview_native_normals(poly, transform, reverse)
            if form not in (gp_TrsfForm.gp_Identity, gp_TrsfForm.gp_Translation):
                self.assertIsNone(fast, "Other placements transform each normal natively.")
                continue
            expected = []
            for index in nodes:
                coordinates = list(poly.Normal(index).Transformed(transform).Coord())
                expected.append(([-value for value in coordinates] if reverse else coordinates)
                                if all(math.isfinite(value) for value in coordinates) else None)
            self.assertEqual(fast, expected)
        self.assertEqual(len(forms), 3, "Identity, translated and rotated placements are all covered.")

    def test_batched_uv_midpoints_match_numpy_mean(self):
        uv = np.random.default_rng(7).normal(scale=1e3, size=(64, 2))
        for nodes in ((3, 17), (2, 40, 63), (0, 1), (5, 6, 7)):
            total = uv[nodes[0]]
            for node in nodes[1:]:
                total = total + uv[node]
            np.testing.assert_array_equal(total / len(nodes), uv[list(nodes)].mean(axis=0))


if __name__ == "__main__":
    unittest.main()
