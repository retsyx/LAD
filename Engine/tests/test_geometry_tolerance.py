"""A fixed machining-scale tolerance changes metadata, never design geometry."""
from pathlib import Path
import copy
import re
import sys
import tempfile
import unittest
from unittest import mock

import cadquery as cq
from OCP.BRep import BRep_Builder, BRep_Tool
from OCP.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCP.Interface import Interface_Static
from OCP.STEPControl import STEPControl_Controller

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker
from test_step_colors import read_xde_parts


class GeometryToleranceTests(unittest.TestCase):
    def snapshot(self, shape):
        kinds = ('Vertex', 'Edge', 'Wire', 'Face', 'Shell', 'Solid')
        entities = {kind: worker._shape_entities(shape, kind) for kind in kinds}

        def placement(entity):
            transform = entity.wrapped.Location().Transformation()
            return tuple(transform.Value(row, column) for row in range(1, 4) for column in range(1, 5))

        curves = []
        for edge in entities['Edge']:
            curve = BRepAdaptor_Curve(edge.wrapped)
            first, last = curve.FirstParameter(), curve.LastParameter()
            curves.append([list(curve.Value(first + (last - first) * fraction).Coord())
                           for fraction in (.17, .53, .89)])
        surfaces = []
        for face in entities['Face']:
            surface = BRepAdaptor_Surface(face.wrapped)
            u = surface.FirstUParameter() * .4 + surface.LastUParameter() * .6
            v = surface.FirstVParameter() * .4 + surface.LastVParameter() * .6
            surfaces.append(list(surface.Value(u, v).Coord()))
        return {
            'identity': shape.hashCode(),
            'entities': {kind: [(entity.hashCode(), str(entity.wrapped.Orientation()), placement(entity))
                                for entity in values] for kind, values in entities.items()},
            'vertices': [list(vertex.Center().toTuple()) for vertex in entities['Vertex']],
            'curves': curves, 'surfaces': surfaces,
            'bounds': worker.exact_bounds(shape), 'volume': shape.Volume(), 'area': shape.Area(),
            'centroid': list(shape.Center().toTuple()),
            'parts': copy.deepcopy(getattr(shape, '_lad_parts', None)),
        }

    def tolerances(self, shape):
        return {kind: [BRep_Tool.Tolerance_s(entity.wrapped)
                       for entity in worker._shape_entities(shape, kind)]
                for kind in ('Vertex', 'Edge', 'Face')}

    def test_floor_is_idempotent_and_preserves_geometry_native_identity_and_parts(self):
        box = cq.Solid.makeBox(2, 3, 4).moved(cq.Location((12, -8, 5), (1, 2, 3), 34))
        cylinder = cq.Solid.makeCylinder(2, 5).moved(cq.Location((-6, 2, 11), (0, 1, 0), 22))
        shape = cq.Compound.makeCompound([box, cylinder]).moved(cq.Location((10, 20, -3)))
        shape._lad_parts = [
            {'id': 'box', 'name': 'Box', 'solidIndices': [0], 'children': None},
            {'id': 'cylinder', 'name': 'Cylinder', 'solidIndices': [1], 'children': None},
        ]
        builder = BRep_Builder()
        builder.UpdateVertex(worker._shape_entities(shape, 'Vertex')[0].wrapped, .0008)
        builder.UpdateEdge(worker._shape_entities(shape, 'Edge')[0].wrapped, .0003)
        builder.UpdateFace(worker._shape_entities(shape, 'Face')[0].wrapped, .00003)
        before, original_tolerances = self.snapshot(shape), self.tolerances(shape)
        parts = shape._lad_parts
        worker.apply_geometry_tolerance(shape)
        self.assertEqual(self.snapshot(shape), before)
        self.assertIs(shape._lad_parts, parts)
        after = self.tolerances(shape)
        self.assertEqual(after['Face'], original_tolerances['Face'], 'Face surfaces retain their own tolerances.')
        for kind in ('Vertex', 'Edge'):
            self.assertEqual(after[kind], [max(value, .0001) for value in original_tolerances[kind]])
        self.assertGreater(max(after['Vertex']), .0001)
        self.assertGreater(max(after['Edge']), .0001)
        worker.apply_geometry_tolerance(shape)
        self.assertEqual(self.snapshot(shape), before)
        self.assertEqual(self.tolerances(shape), after)

    def precision_values(self):
        return {direction: (Interface_Static.IVal_s(f'{direction}.precision.mode'),
                            Interface_Static.RVal_s(f'{direction}.precision.val'))
                for direction in ('read', 'write')}

    def set_precision_values(self, values):
        for direction, (mode, value) in values.items():
            self.assertTrue(Interface_Static.SetIVal_s(f'{direction}.precision.mode', mode))
            self.assertTrue(Interface_Static.SetRVal_s(f'{direction}.precision.val', value))

    def test_step_translation_precision_is_scoped_on_success_and_failure(self):
        STEPControl_Controller.Init_s()
        original = self.precision_values()
        inherited = {'read': (0, .000023), 'write': (-1, .000037)}
        try:
            self.set_precision_values(inherited)
            body = cq.Solid.makeBox(2, 3, 4)
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'candidate.step'
                from cadquery.occ_impl.exporters import assembly as assembly_export
                native_export = assembly_export.exportAssembly

                def export_with_policy(*args, **kwargs):
                    self.assertEqual(self.precision_values()['write'], (1, .0001))
                    return native_export(*args, **kwargs)

                with mock.patch.object(assembly_export, 'exportAssembly', side_effect=export_with_policy):
                    worker.write_step([body], path, cq)
                self.assertEqual(self.precision_values(), inherited)
                native_import = cq.importers.importStep

                def import_with_policy(*args, **kwargs):
                    self.assertEqual(self.precision_values()['read'], (1, .0001))
                    return native_import(*args, **kwargs)

                with mock.patch.object(cq.importers, 'importStep', side_effect=import_with_policy):
                    self.assertAlmostEqual(worker.import_step(path, cq).Volume(), 24, places=7)
                self.assertEqual(self.precision_values(), inherited)

                def failing_export(*args, **kwargs):
                    self.assertEqual(self.precision_values()['write'], (1, .0001))
                    raise ValueError('Controlled STEP writer failure')

                with mock.patch.object(assembly_export, 'exportAssembly', side_effect=failing_export):
                    with self.assertRaisesRegex(worker.ModelError, 'Controlled STEP writer failure'):
                        worker.write_step([body], path, cq)
                self.assertEqual(self.precision_values(), inherited)

                def failing_import(*args, **kwargs):
                    self.assertEqual(self.precision_values()['read'], (1, .0001))
                    raise ValueError('Controlled STEP reader failure')

                with mock.patch.object(cq.importers, 'importStep', side_effect=failing_import):
                    with self.assertRaisesRegex(ValueError, 'Controlled STEP reader failure'):
                        worker.import_step(path, cq)
                self.assertEqual(self.precision_values(), inherited)
        finally:
            self.set_precision_values(original)

    def test_step_uncertainty_colors_and_separate_solids_use_the_geometry_policy(self):
        first = cq.Solid.makeBox(2, 3, 4).translate((10, 20, 30))
        second = cq.Solid.makeCylinder(2, 5).translate((-8, 0, 3))
        colors = {0: {'red': .2, 'green': .4, 'blue': .6},
                  1: {'red': .8, 'green': .3, 'blue': .1}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'colored.step'
            worker.write_step([first, second], path, cq, colors=colors)
            uncertainties = [float(value) for value in re.findall(
                r'UNCERTAINTY_MEASURE_WITH_UNIT\(LENGTH_MEASURE\(([^)]+)', path.read_text())]
            self.assertTrue(uncertainties)
            self.assertTrue(all(value == .0001 for value in uncertainties), uncertainties)
            parts = read_xde_parts(path)
            self.assertEqual(len(parts), 2)
            parts.sort(key=lambda part: part['shape'].Center().x, reverse=True)
            for index, part in enumerate(parts):
                for actual, expected in zip(part['color'], colors[index].values()):
                    self.assertAlmostEqual(actual, expected, places=6)
            expected = cq.Compound.makeCompound([first, second])
            worker.validate_step_roundtrip(expected, cq, path)
            imported = worker.import_step(path, cq)
            self.assertEqual(len(worker._shape_entities(imported, 'Solid')), 2)
            self.assertEqual(worker.exact_bounds(imported), worker.exact_bounds(expected))


if __name__ == '__main__':
    unittest.main()
