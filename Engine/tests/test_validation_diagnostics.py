"""Validation failures retain actual OCCT statuses and scoped geometry pointers."""
from pathlib import Path
import json
import math
import subprocess
import sys
import tempfile
import unittest

import cadquery as cq
from OCP.BRepCheck import BRepCheck_Analyzer, BRepCheck_NoError
from OCP.TopAbs import (TopAbs_VERTEX, TopAbs_EDGE, TopAbs_WIRE, TopAbs_FACE,
                        TopAbs_SHELL, TopAbs_SOLID)
from OCP.TopExp import TopExp
from OCP.TopTools import TopTools_IndexedMapOfShape

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE))
import worker
import test_candidate_validation as candidate_validation


def slot_program(radius):
    # A minimal version of the reported center-plane rear-cutout request. The
    # nominally simple 3 mm corners fail STEP readback in the pinned runtime;
    # 1 mm corners pass. Keep exact validation enabled for both paths.
    return f"""import cadquery as cq
sphere = cq.Solid.makeSphere(50, angleDegrees1=-90, angleDegrees2=90)
sphere = sphere.rotate((0, 0, 0), (1, 0, 0), -55)
cutter = (cq.Workplane('XZ').center(0, -19.75).sketch()
          .rect(15, 8.5).vertices().fillet({radius}).finalize().extrude(200).val())
result = sphere.cut(cutter).clean()
"""


def slot_shape(radius):
    namespace = {}
    exec(slot_program(radius), namespace, namespace)
    return namespace['result']


class ValidationDiagnosticTests(unittest.TestCase):
    def reference_maps(self, shape):
        maps = {}
        for kind, native_kind in [
            ('vertex', TopAbs_VERTEX), ('edge', TopAbs_EDGE), ('wire', TopAbs_WIRE),
            ('face', TopAbs_FACE), ('shell', TopAbs_SHELL), ('solid', TopAbs_SOLID),
        ]:
            native_map = TopTools_IndexedMapOfShape()
            TopExp.MapShapes_s(shape.wrapped, native_kind, native_map)
            maps[kind] = native_map
        return maps

    def assert_references_match_native_statuses(self, shape, diagnostic):
        """Check real topology and native statuses, without assuming face order."""
        maps = self.reference_maps(shape)
        solids = worker._shape_entities(shape, 'Solid')
        analyzer = BRepCheck_Analyzer(shape.wrapped, True, False, True)
        self.assertFalse(analyzer.IsValid())

        def resolve(reference):
            native_map = maps[reference['kind']]
            index = reference['index']
            self.assertGreaterEqual(index, 0)
            self.assertLess(index, native_map.Extent())
            native = native_map.FindKey(index + 1)
            for owner in reference.get('owners', []):
                self.assertLess(owner['solidIndex'], len(solids))
                entities = worker._shape_entities(solids[owner['solidIndex']], reference['kind'].capitalize())
                self.assertGreaterEqual(owner['localIndex'], 0)
                self.assertLess(owner['localIndex'], len(entities))
                self.assertTrue(native.IsSame(entities[owner['localIndex']].wrapped))
            return native

        for failure in diagnostic['failures']:
            native = resolve(failure['entity'])
            result = analyzer.Result(native)
            self.assertIsNotNone(result)
            if 'context' in failure:
                context = resolve(failure['context'])
                statuses = []
                result.InitContextIterator()
                while result.MoreShapeInContext():
                    if result.ContextualShape().IsSame(context):
                        statuses.extend(result.StatusOnShape())
                    result.NextShapeInContext()
            else:
                statuses = list(result.Status())
            actual_names = {status.name for status in statuses if status != BRepCheck_NoError}
            self.assertIn(failure['status'], actual_names)
            if 'bounds' in failure:
                self.assertEqual(len(failure['bounds']), 6)
                self.assertTrue(all(math.isfinite(value) for value in failure['bounds']))
                self.assertTrue(all(failure['bounds'][axis] <= failure['bounds'][axis + 3]
                                    for axis in range(3)))

    def test_native_error_identifies_unorientable_faces_without_guessing_curve_failure(self):
        shape = candidate_validation.CandidateNativeValidationTests.offset_curve_solid()
        self.assertTrue(shape.isValid(), 'This fixture passes CadQuery sampled checks.')
        with self.assertRaises(worker.ModelError) as caught:
            worker.validate_shape(shape)
        error = caught.exception
        diagnostic = error.diagnostic
        self.assertEqual(diagnostic['stage'], 'native_validation')
        self.assertEqual(diagnostic['geometryScope'], 'native_candidate')
        self.assertNotIn('collectionError', diagnostic)
        self.assertTrue(diagnostic['failures'])
        self.assertTrue(all(failure['entity']['kind'] == 'face' for failure in diagnostic['failures']))
        self.assertEqual({failure['status'] for failure in diagnostic['failures']},
                         {'BRepCheck_UnorientableShape'})
        self.assertIn('BRepCheck_UnorientableShape', str(error))
        self.assertNotIn('exact curve-on-surface validation failed', str(error))
        self.assert_references_match_native_statuses(shape, diagnostic)

    def test_slot_radius_pair_reports_step_edge_face_context_and_resets_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for radius in (1, 3):
                with self.subTest(radius=radius):
                    shape = slot_shape(radius)
                    worker.validate_shape(shape)
                    step = folder / f'radius-{radius}.step'
                    worker.write_step(worker._shape_entities(shape, 'Solid'), step, cq)
                    if radius == 1:
                        worker.validate_step_roundtrip(shape, cq, step)
                    else:
                        with self.assertRaises(worker.ModelError) as caught:
                            worker.validate_step_roundtrip(shape, cq, step)
                        diagnostic = caught.exception.diagnostic
                        self.assertEqual(diagnostic['stage'], 'step_readback_validation')
                        self.assertEqual(diagnostic['geometryScope'], 'step_readback')
                        self.assertNotIn('collectionError', diagnostic)
                        edge_failures = [failure for failure in diagnostic['failures']
                                         if failure['entity']['kind'] == 'edge']
                        self.assertTrue(edge_failures)
                        self.assertTrue({'BRepCheck_InvalidCurveOnSurface', 'BRepCheck_InvalidSameParameterFlag'}
                                        <= {failure['status'] for failure in edge_failures})
                        self.assertTrue(all(failure['context']['kind'] == 'face' for failure in edge_failures))
                        for failure in edge_failures:
                            self.assertGreater(failure['tolerance'], 0)
                            self.assertTrue(math.isfinite(failure['maxDeviation']))
                            self.assertGreaterEqual(failure['maxDeviation'], 0)
                            self.assertEqual(len(failure['maxDeviationPoint']), 3)
                            self.assertTrue(all(math.isfinite(value) for value in failure['maxDeviationPoint']))
                        self.assertTrue(any(failure['maxDeviation'] > failure['tolerance']
                                            for failure in edge_failures))
                        self.assertIn('STEP readback indices must not be used as selections', str(caught.exception))
                        readback = cq.importers.importStep(str(step)).val()
                        self.assert_references_match_native_statuses(readback, diagnostic)
                    self.assertEqual(worker._validation_scope.get(), 'native_candidate')
            # A subsequent unrelated failure must not inherit STEP identity.
            with self.assertRaises(worker.ModelError) as caught:
                worker.validate_shape(candidate_validation.CandidateNativeValidationTests.offset_curve_solid())
            self.assertEqual(caught.exception.diagnostic['geometryScope'], 'native_candidate')

    def test_invalid_reference_input_identifies_its_asset_without_leaking_scope(self):
        invalid = candidate_validation.CandidateNativeValidationTests.offset_curve_solid()
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            path = folder / 'input-000.brep'
            worker.write_brep(invalid, path)
            readback = cq.Shape.importBrep(str(path))
            with self.assertRaises(worker.ModelError) as direct:
                worker.import_input_asset(path, 'brep', cq)
            diagnostic = direct.exception.diagnostic
            self.assertEqual(diagnostic['stage'], 'input_validation')
            self.assertEqual(diagnostic['geometryScope'], 'input_asset')
            self.assertEqual(diagnostic['inputAsset'], {'name': path.name, 'format': 'brep'})
            self.assertIn('Geometry scope: input_asset', str(direct.exception))
            self.assert_references_match_native_statuses(readback, diagnostic)
            self.assertEqual(worker._validation_scope.get(), 'native_candidate')
            self.assertIsNone(worker._validation_input.get())

            asset = {'id': 'external-reference', 'name': 'External reference.brep',
                     'format': 'brep', 'path': path.name}
            spec = {'title': 'Reference scope', 'summary': 'An invalid imported reference.', 'units': 'mm',
                    'script': "raise AssertionError('Candidate program must not execute')", 'inputAssets': [asset]}
            with self.assertRaises(worker.ModelError) as staged:
                worker.build_shape(spec, 2, folder)
            diagnostic = staged.exception.diagnostic
            self.assertEqual(diagnostic['stage'], 'input_validation')
            self.assertEqual(diagnostic['geometryScope'], 'input_asset')
            self.assertEqual(diagnostic['inputAsset'], {key: asset[key] for key in ('id', 'name', 'format')})
            self.assertIn(asset['id'], str(staged.exception))
            self.assertNotIn('Candidate program must not execute', str(staged.exception))
            self.assert_references_match_native_statuses(readback, diagnostic)
            self.assertEqual(worker._validation_scope.get(), 'native_candidate')
            self.assertIsNone(worker._validation_input.get())

            with self.assertRaises(worker.ModelError) as native:
                worker.validate_shape(invalid)
            self.assertEqual(native.exception.diagnostic['geometryScope'], 'native_candidate')
            self.assertNotIn('inputAsset', native.exception.diagnostic)
            shape = slot_shape(3)
            step = folder / 'candidate.step'
            worker.write_step(worker._shape_entities(shape, 'Solid'), step, cq)
            with self.assertRaises(worker.ModelError) as transferred:
                worker.validate_step_roundtrip(shape, cq, step)
            self.assertEqual(transferred.exception.diagnostic['geometryScope'], 'step_readback')
            self.assertNotIn('inputAsset', transferred.exception.diagnostic)
            self.assertEqual(worker._validation_scope.get(), 'native_candidate')
            self.assertIsNone(worker._validation_input.get())

    def test_many_real_native_failures_are_bounded_and_count_omitted_statuses(self):
        invalid = candidate_validation.CandidateNativeValidationTests.offset_curve_solid()
        compound = cq.Compound.makeCompound([invalid.translate((index * 100, 0, 0)) for index in range(16)])
        with self.assertRaises(worker.ModelError) as caught:
            worker.validate_shape(compound)
        diagnostic = caught.exception.diagnostic
        self.assertEqual(len(diagnostic['failures']), worker.MAX_VALIDATION_FAILURES)
        self.assertGreater(diagnostic['omittedFailures'], 0)
        self.assertNotIn('collectionError', diagnostic)
        self.assert_references_match_native_statuses(compound, diagnostic)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            worker.write_error_report(caught.exception, folder)
            payload = (folder / 'error.json').read_bytes()
            self.assertLessEqual(len(payload), 65_536)
            self.assertEqual(json.loads(payload)['omittedFailures'], diagnostic['omittedFailures'])

    def test_error_report_bounds_multibyte_messages_after_json_encoding(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for character in ('é', '\0'):
                with self.subTest(character=repr(character)):
                    worker.write_error_report(worker.ModelError(character * 40_000), folder)
                    payload = (folder / 'error.json').read_bytes()
                    self.assertLessEqual(len(payload), 65_536)
                    report = json.loads(payload)
                    self.assertEqual(report['formatVersion'], 1)
                    self.assertEqual(report['stage'], 'worker')
                    self.assertTrue(report['message'])
                    self.assertEqual(set(report['message']), {character})
                    self.assertEqual(list(folder.glob('.error-*')), [])

    def test_cli_publishes_complete_step_failure_report_without_a_success_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            request = folder / 'request.json'
            request.write_text(json.dumps({'title': 'Rear cutout', 'summary': 'Center-plane extrusion',
                                           'units': 'mm', 'script': slot_program(3)}))
            output = folder / 'output'
            process = subprocess.run([sys.executable, str(ENGINE / 'worker.py'), '--request', str(request),
                                      '--output', str(output), '--threads', '2', '--defer-step'],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(process.returncode, 1, process.stdout)
            self.assertNotIn('"status": "complete"', process.stdout)
            payload = (output / 'error.json').read_bytes()
            self.assertLessEqual(len(payload), 65_536)
            report = json.loads(payload)
            self.assertEqual(report['formatVersion'], 1)
            self.assertEqual(report['stage'], 'step_readback_validation')
            self.assertEqual(report['geometryScope'], 'step_readback')
            self.assertTrue(report['failures'])
            self.assertTrue(any(failure['status'] == 'BRepCheck_InvalidCurveOnSurface'
                                for failure in report['failures']))
            self.assertIn('Design failed STEP verification before acceptance', report['message'])
            for failure in report['failures']:
                self.assertIn(failure['status'], report['message'])
                self.assertIn(failure['status'], process.stderr)
            for name in ('result.json', 'model.brep', 'model.step'):
                self.assertFalse((output / name).exists(), 'A rejected candidate must not appear completed.')
            self.assertEqual(list(output.glob('.error-*')), [])
            self.assertEqual(list(output.glob('.step-validation-*')), [])


if __name__ == '__main__':
    unittest.main()
