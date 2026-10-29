"""Exact STEP assembly export with current opaque sRGB part colors."""
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import ModelError, run, write_brep


def read_xde_parts(path):
    """Read each placed STEP leaf and its actual XDE color, rather than STEP text."""
    import cadquery as cq
    from OCP.IFSelect import IFSelect_RetDone
    from OCP.Quantity import Quantity_Color, Quantity_TOC_sRGB
    from OCP.STEPCAFControl import STEPCAFControl_Reader
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.TDF import TDF_Label, TDF_LabelSequence
    from OCP.TDocStd import TDocStd_Document
    from OCP.TopLoc import TopLoc_Location
    from OCP.XCAFDoc import XCAFDoc_ColorTool, XCAFDoc_DocumentTool, XCAFDoc_ShapeTool, XCAFDoc_ColorType
    document = TDocStd_Document(TCollection_ExtendedString('STEP color test'))
    reader = STEPCAFControl_Reader()
    reader.SetColorMode(True)
    if reader.ReadFile(str(path)) != IFSelect_RetDone or not reader.Transfer(document):
        raise AssertionError('STEPCAF could not read the exported design')
    shapes = XCAFDoc_DocumentTool.ShapeTool_s(document.Main())
    colors = XCAFDoc_DocumentTool.ColorTool_s(document.Main())
    result = []

    def color_at(label):
        for kind in (XCAFDoc_ColorType.XCAFDoc_ColorSurf, XCAFDoc_ColorType.XCAFDoc_ColorGen):
            color = Quantity_Color()
            if XCAFDoc_ColorTool.GetColor_s(label, kind, color):
                return list(color.Values(Quantity_TOC_sRGB))
        return None

    def visit(label, parent_location, inherited=None):
        actual = label
        location = parent_location
        color = color_at(label) or inherited
        if XCAFDoc_ShapeTool.IsReference_s(label):
            actual = TDF_Label()
            if not XCAFDoc_ShapeTool.GetReferredShape_s(label, actual):
                raise AssertionError('Invalid STEP assembly reference')
            location = parent_location.Multiplied(XCAFDoc_ShapeTool.GetLocation_s(label))
            color = color_at(label) or color_at(actual) or inherited
        components = TDF_LabelSequence()
        if XCAFDoc_ShapeTool.GetComponents_s(actual, components):
            for index in range(1, components.Length() + 1):
                visit(components.Value(index), location, color)
        else:
            native = XCAFDoc_ShapeTool.GetShape_s(actual)
            placed = cq.Shape.cast(native.Moved(location))
            rgb = color or color_at(actual)
            if rgb is None:
                for kind in (XCAFDoc_ColorType.XCAFDoc_ColorSurf, XCAFDoc_ColorType.XCAFDoc_ColorGen):
                    value = Quantity_Color()
                    if colors.GetColor(native, kind, value):
                        rgb = list(value.Values(Quantity_TOC_sRGB))
                        break
            for solid in placed.Solids():
                result.append({'shape': solid, 'color': rgb})

    roots = TDF_LabelSequence()
    shapes.GetFreeShapes(roots)
    for index in range(1, roots.Length() + 1):
        visit(roots.Value(index), TopLoc_Location())
    return result


class STEPColorTests(unittest.TestCase):
    def fixture(self):
        import cadquery as cq
        shared = cq.Solid.makeBox(2, 3, 4)
        nested = cq.Assembly(name='Nested', loc=cq.Location((10, -5, 3), (0, 0, 1), 30))
        nested.add(shared, name='First', loc=cq.Location((0, 0, 0)))
        nested.add(shared, name='Second', loc=cq.Location((1, 0, 0)))
        root = cq.Assembly(name='Product', loc=cq.Location((20, -30, 40), (0, 1, 0), 25))
        root.add(nested)
        root.add(cq.Solid.makeCylinder(2, 5), name='Neutral', loc=cq.Location((30, 8, -3)))
        return root.toCompound()

    def colors(self):
        # Deliberately different from source-index order; mapping is explicit.
        return [{'solidIndex': 2, 'color': {'red': 0.65, 'green': 0.65, 'blue': 0.65}},
                {'solidIndex': 0, 'color': {'red': 0.2, 'green': 0.4, 'blue': 0.6}},
                {'solidIndex': 1, 'color': {'red': 0.9, 'green': 0.15, 'blue': 0.25}}]

    def export(self, folder, shape, **fields):
        write_brep(shape, folder / 'source.brep')
        request = folder / 'request.json'
        request.write_text(json.dumps({'operation': 'export', 'brepAsset': 'source.brep', **fields}))
        return run(request, folder, 2)

    def assert_geometry(self, actual, expected):
        self.assertEqual(len(actual.Faces()), len(expected.Faces()))
        self.assertAlmostEqual(actual.Volume(), expected.Volume(), places=6)
        for a, b in zip(actual.Center().toTuple(), expected.Center().toTuple()):
            self.assertAlmostEqual(a, b, places=6)
        a, b = actual.BoundingBox(), expected.BoundingBox()
        for axis in ('xmin', 'ymin', 'zmin', 'xmax', 'ymax', 'zmax'):
            self.assertAlmostEqual(getattr(a, axis), getattr(b, axis), places=6)

    def assert_colored_geometry(self, path, original, selected):
        import cadquery as cq
        expected = original.Solids()
        restored = cq.importers.importStep(str(path)).val().Solids()
        self.assertEqual(len(restored), len(selected))
        for solid, index in zip(restored, selected):
            self.assert_geometry(solid, expected[index])
        placed = read_xde_parts(path)
        self.assertEqual(len(placed), len(selected))
        colors = {record['solidIndex']: record['color'] for record in self.colors()}
        remaining = set(selected)
        for part in placed:
            center = part['shape'].Center()
            index = min(remaining, key=lambda i: center.sub(expected[i].Center()).Length)
            remaining.remove(index)
            self.assert_geometry(part['shape'], expected[index])
            self.assertIsNotNone(part['color'], 'Every requested color, including neutral, must survive STEPCAF')
            for actual, name in zip(part['color'], ('red', 'green', 'blue')):
                self.assertAlmostEqual(actual, colors[index][name], places=6)

    def test_full_export_roundtrips_current_srgb_colors_and_nested_original_placements(self):
        shape = self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with (mock.patch('worker.build_shape', side_effect=AssertionError('Export must not replay')),
                  mock.patch('worker.make_preview', side_effect=AssertionError('Export must not mesh'))):
                report = self.export(folder, shape, solidColors=self.colors())
            self.assertEqual(report['solids'], 3)
            self.assert_colored_geometry(report['stepPath'], shape, [0, 1, 2])
            # Overlapping assembly members must remain separate exact solids.
            self.assertEqual(sum(len(s.Faces()) for s in shape.Solids()), report['faces'])

    def test_subset_export_uses_original_indices_and_keeps_matching_colors_and_coordinates(self):
        shape = self.fixture()
        for selected in ([1], [0, 2], [2, 0]):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                report = self.export(folder, shape, solidIndices=selected, solidColors=self.colors())
                self.assertEqual(report['solids'], len(selected))
                self.assert_colored_geometry(report['stepPath'], shape, selected)

    def test_absent_empty_and_partial_color_maps_are_valid(self):
        import cadquery as cq
        shape = self.fixture()
        for fields in ({}, {'solidColors': []}, {'solidColors': [self.colors()[1]]}):
            with self.subTest(fields=fields), tempfile.TemporaryDirectory() as directory:
                report = self.export(Path(directory), shape, **fields)
                restored = cq.importers.importStep(report['stepPath']).val().Solids()
                self.assertEqual(len(restored), 3)
                for actual, expected in zip(restored, shape.Solids()):
                    self.assert_geometry(actual, expected)

    def test_invalid_color_payloads_fail_atomically_before_any_step_output(self):
        shape = self.fixture()
        valid = self.colors()[1]
        invalid = [None, {}, 'red', [None], [{'solidIndex': 0}], [{**valid, 'extra': 1}],
                   [valid, valid], self.colors() + [valid]]
        for index in (True, False, -1, 3, 0.0, '0', None):
            invalid.append([{**valid, 'solidIndex': index}])
        for color in (None, {}, 'red', {'red': 0.1, 'green': 0.2},
                      {'red': 0.1, 'green': 0.2, 'blue': 0.3, 'alpha': 1}):
            invalid.append([{**valid, 'color': color}])
        for value in (True, -0.1, 1.1, math.nan, math.inf, 10 ** 1000, '0.2'):
            invalid.append([{**valid, 'color': {'red': value, 'green': 0.2, 'blue': 0.3}}])
        for records in invalid:
            with self.subTest(records=records), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                with (mock.patch('cadquery.exporters.export', side_effect=AssertionError('No export on invalid metadata')),
                      mock.patch('cadquery.occ_impl.exporters.assembly.exportAssembly', side_effect=AssertionError('No export on invalid metadata')),
                      self.assertRaises(ModelError)):
                    self.export(folder, shape, solidColors=records)
                self.assertFalse((folder / 'model.step').exists())
        # Even an unselected solid's malformed metadata invalidates the whole request.
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with self.assertRaises(ModelError):
                self.export(folder, shape, solidIndices=[0], solidColors=[valid, {'solidIndex': 2, 'color': {'red': 2, 'green': 0, 'blue': 0}}])
            self.assertFalse((folder / 'model.step').exists())


if __name__ == '__main__':
    unittest.main()
