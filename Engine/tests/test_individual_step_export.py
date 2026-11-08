"""Batch STEP export preserves native parts, colors and shared print placement."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker
from test_step_colors import read_xde_parts


class IndividualSTEPExportTests(unittest.TestCase):
    def fixture(self):
        import cadquery as cq
        return [cq.Solid.makeBox(8, 14, 2).rotate((0, 0, 0), (1, 2, 3), 61).translate((30, -5, 17)),
                cq.Solid.makeBox(5, 7, 9).translate((20, 40, 33)),
                cq.Solid.makeCylinder(3, 17).rotate((0, 0, 0), (0, 1, 0), 90).translate((-9, 21, -4))]

    def export(self, folder, solids, **fields):
        import cadquery as cq
        from OCP import BRepMesh
        worker.write_brep(cq.Compound.makeCompound(solids), folder / 'source.brep')
        original = (folder / 'source.brep').read_bytes()
        request = folder / 'request.json'
        request.write_text(json.dumps({'operation': 'export', 'brepAsset': 'source.brep', **fields}))
        with (mock.patch.object(worker, 'read_brep', wraps=worker.read_brep) as read,
              mock.patch.object(worker, 'build_shape', side_effect=AssertionError('No replay')),
              mock.patch.object(worker, 'make_preview', side_effect=AssertionError('No preview')),
              mock.patch.object(BRepMesh, 'BRepMesh_IncrementalMesh', side_effect=AssertionError('No tessellation'))):
            report = worker.run(request, folder, 2)
        self.assertEqual(read.call_count, 1, 'All files must share one native load and validation')
        self.assertEqual(original, (folder / 'source.brep').read_bytes())
        return report

    def assert_same_geometry(self, actual, expected, placed=False):
        self.assertEqual(len(actual.Faces()), len(expected.Faces()))
        self.assertAlmostEqual(actual.Volume(), expected.Volume(), places=6)
        self.assertAlmostEqual(actual.Area(), expected.Area(), places=6)
        if not placed:
            for a, b in zip(worker.exact_bounds(actual), worker.exact_bounds(expected)):
                self.assertAlmostEqual(a, b, places=6)

    def test_individual_subset_and_grouping_preserve_output_order_and_exact_coordinates(self):
        import cadquery as cq
        solids = self.fixture()
        for selected, parts in [([0, 2], [[2], [0]]), ([0, 1, 2], [[2, 0], [1]])]:
            with self.subTest(parts=parts), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                report = self.export(folder, solids, solidIndices=selected, individualParts=parts)
                self.assertNotIn('stepPath', report)
                self.assertFalse((folder / 'model.step').exists())
                self.assertEqual(report['solids'], len(selected))
                for index, (record, expected_indices) in enumerate(zip(report['partFiles'], parts)):
                    self.assertEqual(record, {'path': f'part-{index:04d}.step', 'solidIndices': expected_indices})
                    actual = cq.importers.importStep(str(folder / record['path'])).val().Solids()
                    self.assertEqual(len(actual), len(expected_indices))
                    for shape, solid_index in zip(actual, expected_indices):
                        self.assert_same_geometry(shape, solids[solid_index])

    def test_individual_printing_files_share_one_selected_arrangement(self):
        import cadquery as cq
        solids = self.fixture()
        selected = [0, 2]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with mock.patch.object(worker, 'arrange_print_solids', wraps=worker.arrange_print_solids) as arrange:
                report = self.export(folder, solids, solidIndices=selected, individualParts=[[2], [0]],
                                     arrangeFor3DPrinting=True)
                self.assertEqual(arrange.call_count, 1, 'Packing and orientation must be shared across files')
            exported = {record['solidIndices'][0]: cq.importers.importStep(str(folder / record['path'])).val()
                        for record in report['partFiles']}
            combined = folder / 'combined'
            combined.mkdir()
            combined_report = self.export(combined, solids, solidIndices=selected, arrangeFor3DPrinting=True)
            restored = cq.importers.importStep(combined_report['stepPath']).val().Solids()
            for index, expected in zip(selected, restored):
                self.assert_same_geometry(exported[index], expected)
                self.assertAlmostEqual(worker.exact_bounds(exported[index])[2], 0, places=6)
            a, b = (worker.exact_bounds(exported[index]) for index in selected)
            clearance = max(b[0] - a[3], a[0] - b[3], b[1] - a[4], a[1] - b[4])
            self.assertGreaterEqual(clearance, 50 - 1e-6)

    def test_each_individual_file_keeps_its_original_index_color(self):
        solids = self.fixture()
        palette = {0: {'red': .8, 'green': .12, 'blue': .18},
                   1: {'red': .1, 'green': .75, 'blue': .2},
                   2: {'red': .15, 'green': .2, 'blue': .9}}
        colors = [{'solidIndex': index, 'color': color} for index, color in palette.items()]
        for arrange in (False, True):
            with self.subTest(arrange=arrange), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                report = self.export(folder, solids, solidIndices=[0, 2], individualParts=[[2], [0]],
                                     solidColors=colors, arrangeFor3DPrinting=arrange)
                for record in report['partFiles']:
                    index = record['solidIndices'][0]
                    restored = read_xde_parts(folder / record['path'])
                    self.assertEqual(len(restored), 1)
                    self.assert_same_geometry(restored[0]['shape'], solids[index], placed=arrange)
                    for actual, channel in zip(restored[0]['color'], ('red', 'green', 'blue')):
                        self.assertAlmostEqual(actual, palette[index][channel], places=6)

    def test_invalid_individual_partitions_fail_before_writing_any_step(self):
        solids = self.fixture()
        invalid = [None, [], {}, 'parts', [None], [[]], [[0], [0]], [[0, 0], [2]], [[0]],
                   [[0], [1]], [[0], [True]], [[0], [-1]], [[0], [3]], [[0], ['2']]]
        for parts in invalid:
            with self.subTest(parts=parts), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                with (mock.patch.object(worker, 'write_step', side_effect=AssertionError('No partial output')),
                      self.assertRaises(worker.ModelError)):
                    self.export(folder, solids, solidIndices=[0, 2], individualParts=parts)
                self.assertEqual(list(folder.glob('*.step')), [])


if __name__ == '__main__':
    unittest.main()
