"""Final validation shares exact measurements with only its matching preview."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import cadquery as cq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


class PreviewValidatedStatsTests(unittest.TestCase):
    @staticmethod
    def fresh_shape():
        return cq.Compound.makeCompound([
            cq.Workplane("XY").box(8, 6, 4).edges().fillet(0.6).val().toNURBS(),
            cq.Solid.makeCylinder(2, 3).located(cq.Location((12, -7, 4), (0, 1, 0), 37)),
            cq.Workplane("XY").rect(8, 6).circle(1).extrude(3).val().translate((-10, 0, 0)),
        ])

    def test_validated_handoff_matches_complete_direct_preview(self):
        expected = worker.make_preview(self.fresh_shape())
        shape = self.fresh_shape()
        stats = {}
        self.assertIs(worker.validate_shape(shape, preview_stats=stats), shape)
        actual = worker.make_preview(shape, preview_stats=stats)
        self.assertEqual(actual, expected,
                         "Sharing validated measurements must preserve the complete preview and exact feature metadata.")
        self.assertEqual(stats, {}, "A handoff must be consumed rather than becoming reusable geometry state.")

    def test_consumed_measurements_cannot_be_used_for_another_preview(self):
        shape = cq.Solid.makeBox(2, 3, 4)
        stats = {}
        worker.validate_shape(shape, preview_stats=stats)
        worker.make_preview(shape, preview_stats=stats)
        with self.assertRaisesRegex(worker.ModelError, "already consumed"):
            worker.make_preview(shape, preview_stats=stats)

    def test_same_native_shape_in_a_different_wrapper_rejects_old_measurements(self):
        shape = cq.Solid.makeBox(2, 3, 4)
        another = cq.Solid(shape.wrapped)
        self.assertIsNot(shape, another)
        self.assertTrue(shape.isEqual(another))
        stats = {}
        worker.validate_shape(shape, preview_stats=stats)
        with self.assertRaisesRegex(worker.ModelError, "different"):
            worker.make_preview(another, preview_stats=stats)
        self.assertEqual(stats, {}, "Rejected measurements must not remain available for a later build.")

    def test_repeated_solid_occurrences_keep_native_global_measures(self):
        solid = cq.Solid.makeBox(2, 3, 4)
        shape = cq.Compound.makeCompound([solid, solid])
        native_volume, native_area = shape.Volume(), shape.Area()
        self.assertEqual(len(shape.Solids()), 1,
                         "The fixture must contain repeated occurrences of one indexed native solid.")
        self.assertAlmostEqual(native_volume, 2 * solid.Volume())
        self.assertAlmostEqual(native_area, 2 * solid.Area())
        stats = {}
        worker.validate_shape(shape, preview_stats=stats)
        preview = worker.make_preview(shape, preview_stats=stats)
        self.assertEqual(preview["volume"], native_volume)
        self.assertEqual(preview["area"], native_area)
        self.assertNotEqual(preview["volume"], sum(part["volume"] for part in preview["topology"]["parts"]))
        self.assertNotEqual(preview["area"], sum(part["area"] for part in preview["topology"]["parts"]),
                            "Unique selectable part totals cannot replace native whole-shape measures.")

    def test_exact_bounds_are_computed_once_per_part_across_validation_and_display(self):
        shape = self.fresh_shape()
        stats = {}
        original = worker.exact_bounds
        with patch.object(worker, "exact_bounds", wraps=original) as measured:
            worker.validate_shape(shape, preview_stats=stats)
            preview = worker.make_preview(shape, preview_stats=stats)
        self.assertEqual(measured.call_count, preview["solids"],
                         "Final validation and preview extraction must reuse each part's exact bounds.")

    def test_failed_validation_cannot_leave_measurements_from_a_previous_build(self):
        shape = cq.Solid.makeBox(2, 3, 4)
        stats = {}
        worker.validate_shape(shape, preview_stats=stats)
        with self.assertRaises(worker.ModelError):
            worker.validate_shape(cq.Compound.makeCompound([]), preview_stats=stats)
        self.assertEqual(stats, {})
        with self.assertRaisesRegex(worker.ModelError, "already consumed"):
            worker.make_preview(shape, preview_stats=stats)


if __name__ == "__main__":
    unittest.main()
