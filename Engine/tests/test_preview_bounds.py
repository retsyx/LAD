"""Display tessellation never determines exact design dimensions or detail."""
import math
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import cadquery as cq
from OCP import BRepMesh

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


class PreviewBoundsTests(unittest.TestCase):
    @staticmethod
    def fresh_assembly():
        return cq.Compound.makeCompound([
            cq.Solid.makeBox(2, 3, 4).translate((-8, 2, -1)),
            cq.Solid.makeCylinder(3, 5).located(cq.Location((12, -7, 4), (1, 2, 0), 37)),
            cq.Solid.makeSphere(3, angleDegrees1=-90, angleDegrees2=90).translate((2, 8, 1)),
        ])

    @staticmethod
    def native_box(shape):
        box = shape.BoundingBox()
        return [box.xmin, box.ymin, box.zmin, box.xmax, box.ymax, box.zmax]

    def preview_with_deflection(self, shape):
        original = BRepMesh.BRepMesh_IncrementalMesh
        calls = []

        def capture(native, deflection, relative, angular, parallel):
            calls.append((deflection, relative, angular, parallel))
            return original(native, deflection, relative, angular, parallel)

        with patch.object(BRepMesh, "BRepMesh_IncrementalMesh", side_effect=capture):
            preview = worker.make_preview(shape)
        self.assertEqual(len(calls), 1)
        return preview, calls[0]

    def test_existing_coarse_mesh_does_not_change_bounds_or_requested_display_detail(self):
        clean = self.fresh_assembly()
        expected_bounds = worker.exact_bounds(clean)
        coarse = self.fresh_assembly()
        BRepMesh.BRepMesh_IncrementalMesh(coarse.wrapped, 0.8, False, 0.8, True)
        self.assertGreater(max(abs(a - b) for a, b in zip(self.native_box(coarse), expected_bounds)), 0.01,
                           "The fixture must expose triangulation-dependent bounding boxes.")
        fresh_preview, fresh_detail = self.preview_with_deflection(clean)
        coarse_preview, coarse_detail = self.preview_with_deflection(coarse)
        self.assertEqual(fresh_preview["bounds"], expected_bounds)
        self.assertEqual(coarse_preview["bounds"], expected_bounds)
        self.assertEqual(fresh_detail, coarse_detail,
                         "The same geometry must request the same display detail regardless of a previous coarse mesh.")
        self.assertEqual(fresh_preview["topology"]["parts"], coarse_preview["topology"]["parts"])
        for preview in [fresh_preview, coarse_preview]:
            for point in preview["vertices"]:
                for axis in range(3):
                    self.assertGreaterEqual(point[axis], expected_bounds[axis] - 1e-6)
                    self.assertLessEqual(point[axis], expected_bounds[axis + 3] + 1e-6)

    def test_native_positions_and_bounds_are_reused_once_for_each_located_part(self):
        shape = self.fresh_assembly()
        expected_parts = [worker.exact_bounds(solid) for solid in shape.Solids()]
        original = worker.exact_bounds
        with patch.object(worker, "exact_bounds", wraps=original) as measured:
            preview = worker.make_preview(shape)
        self.assertEqual(measured.call_count, preview["solids"],
                         "Preview preparation must not repeat exact bounds for global dimensions and part measurements.")
        self.assertEqual([part["bounds"] for part in preview["topology"]["parts"]], expected_parts)
        expected_global = [min(part[axis] for part in expected_parts) for axis in range(3)] + [
            max(part[axis] for part in expected_parts) for axis in range(3, 6)]
        self.assertEqual(preview["bounds"], expected_global)
        expected_vertices = [tuple(vertex.toTuple()) for solid in shape.Solids() for vertex in solid.Vertices()]
        self.assertEqual([tuple(vertex["position"]) for vertex in preview["topology"]["vertices"]], expected_vertices)

    def test_absolute_meshing_deflection_keeps_lower_and_upper_limits(self):
        for size, expected in [(0.1, 0.005), (10, math.sqrt(3) / 100), (1000, 0.25)]:
            with self.subTest(size=size):
                preview, (deflection, relative, angular, parallel) = self.preview_with_deflection(cq.Solid.makeBox(size, size, size))
                self.assertAlmostEqual(deflection, expected, places=14)
                self.assertFalse(relative)
                self.assertEqual(angular, 0.15)
                self.assertTrue(parallel)
                for actual, target in zip(preview["bounds"], [0, 0, 0, size, size, size]):
                    self.assertAlmostEqual(actual, target, places=6)


if __name__ == "__main__":
    unittest.main()
