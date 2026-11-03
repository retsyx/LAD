"""Reversible program snapshots: staged validity is separate from completion."""
import ast
import copy
import hashlib
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import cadquery as cq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mesh_edits import compile_edit, EditError
import worker


CONTEXT = {'id': 'context-1', 'units': 'mm', 'max_deviation': 0.0}


def empty_revision(**state):
    return {'id': 'r0', 'script': None, 'state': {'body_ids': [], **state}}


def next_revision(plan, identity='r1'):
    return {'id': identity, 'script': plan['script'], 'state': copy.deepcopy(plan['state'])}


def box_create(**changes):
    value = {'kind': 'body', 'operation': 'create', 'body_id': 'body-main',
             'tool': {'family': 'box', 'geometry': {'origin': [0, 0, 0], 'size': [10, 10, 5]}}}
    value.update(changes)
    return value


def build(plan, *, step=False):
    # Trusted test fixtures execute through the same native construction entry
    # point. Production runs this entry point in the app's process sandbox.
    shape = worker.build_shape({'title': 'Staged design', 'summary': 'Reconstruction edit preview',
                                'units': 'mm', 'script': plan['script']})
    if step:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'candidate.step'
            cq.exporters.export(shape, str(path))
            worker.validate_step_roundtrip(shape, cq, path)
    return shape


def square_profile(size=10):
    return {'origin': [0, 0, 0], 'normal': [0, 0, 1], 'x_direction': [1, 0, 0],
            'loops': [{'closed': True, 'points': [[0, 0], [size, 0], [size, size], [0, size]]}]}


class ProgramEditTests(unittest.TestCase):
    def test_first_solid_is_valid_even_with_unbuilt_required_bore_and_zero_final_tolerance(self):
        obligation = {'id': 'future-bore', 'kind': 'bore', 'radius': 1}
        base = empty_revision(completion_obligations=[obligation])
        original = copy.deepcopy(base)
        plan = compile_edit(CONTEXT, base, box_create())
        self.assertEqual(base, original)
        self.assertEqual(plan['completion_obligations'], [obligation])
        self.assertFalse(plan['completion_gate_applied'])
        self.assertEqual(plan['final_acceptance'], 'not_evaluated')
        self.assertTrue(plan['requires_body_validation'])
        self.assertEqual(plan['invalidated_comparisons'], 'all')
        self.assertAlmostEqual(build(plan, step=True).Volume(), 500, places=8)
        self.assertNotIn('commit_eligible', plan, 'Compilation must not impersonate worker/policy validation')

    def test_fit_member_through_bore_uses_target_bounds_not_observed_wall_caps(self):
        base_plan = compile_edit(CONTEXT, empty_revision(), box_create())
        candidate = {'id': 'fit-counterbore', 'evidence_ids': ['wall-1'], 'dependency_fingerprint': 'source-only',
                     'members': [{'id': 'bore', 'family': 'cylinder',
                                  'geometry': {'origin': [5, 5, 2], 'axis': [0, 0, 4], 'radius': 1},
                                  'observed_extent': {'axial_interval': [-.1, .1]}},
                                 {'id': 'shoulder', 'family': 'plane',
                                  'geometry': {'origin': [5, 5, 2], 'normal': [0, 0, 1]}}]}
        resolve = mock.Mock(return_value=candidate)
        plan = compile_edit(CONTEXT, next_revision(base_plan),
                            {'kind': 'body', 'operation': 'cut', 'target_body': 'body-main', 'feature_id': 'bore',
                             'tool': {'fit_candidate': 'fit-counterbore', 'member_id': 'bore',
                                      'extent': {'mode': 'through_all'}}}, resolve)
        resolve.assert_called_once_with('fit-counterbore', 'bore')
        self.assertEqual(plan['dependencies'][0]['member_id'], 'bore')
        self.assertFalse(plan['normalized_edit']['realization']['construction_extent_is_evidence'])
        shape = build(plan, step=True)
        self.assertAlmostEqual(shape.Volume(), 500 - 5 * math.pi, places=7)
        self.assertFalse(shape.isInside(cq.Vector(5, 5, 2.5)))
        for tool in ({'fit_candidate': 'fit-counterbore', 'extent': {'mode': 'through_all'}},
                     {'fit_candidate': 'fit-counterbore', 'member_id': 'missing', 'extent': {'mode': 'through_all'}}):
            with self.assertRaises(EditError) as caught:
                compile_edit(CONTEXT, next_revision(base_plan),
                             {'kind': 'body', 'operation': 'cut', 'target_body': 'body-main', 'tool': tool}, resolve)
            self.assertEqual(caught.exception.code, 'AMBIGUOUS_REBIND')

    def test_atomic_create_fuse_and_cut_is_a_complete_replayable_program(self):
        plan = compile_edit(CONTEXT, empty_revision(),
                            {'operation': 'group', 'active_invariants': [{'id': 'one-body', 'kind': 'body_count', 'count': 1}],
                             'edits': [box_create(),
                                       {'kind': 'body', 'operation': 'fuse', 'target_body': 'body-main',
                                        'tool': {'family': 'cylinder',
                                                 'geometry': {'origin': [5, 5, 4], 'axis': [0, 0, 1], 'radius': 2},
                                                 'extent': {'mode': 'depth', 'depth': 4}}},
                                       {'kind': 'body', 'operation': 'cut', 'target_body': 'body-main',
                                        'tool': {'family': 'cylinder',
                                                 'geometry': {'origin': [5, 5, 0], 'axis': [0, 0, 1], 'radius': 1},
                                                 'extent': {'mode': 'through_all'}}}]})
        self.assertAlmostEqual(build(plan, step=True).Volume(), 500 + 4 * math.pi, places=7)
        self.assertEqual(len(plan['entity_evolution']), 3)
        self.assertEqual(plan['active_invariants'][0]['id'], 'one-body')
        self.assertEqual(plan['script'].count('# LAD complete reconstruction program'), 1)
        self.assertEqual(len([node for node in ast.parse(plan['script']).body if isinstance(node, ast.Assign)
                              and any(isinstance(t, ast.Name) and t.id == '_lad_recon_parameters' for t in node.targets)]), 1)

    def test_parameter_update_replays_all_downstream_operations_without_a_feature_graph(self):
        create = {'kind': 'body', 'operation': 'create', 'body_id': 'main',
                  'tool': {'family': 'cylinder', 'geometry': {'origin': [0, 0, 0], 'axis': [0, 0, 1],
                                                           'radius': {'parameter': 'outer-radius', 'value': 2, 'min': 1, 'max': 4}},
                           'extent': {'mode': 'depth', 'depth': 3}}}
        first = compile_edit(CONTEXT, empty_revision(), create)
        second = compile_edit(CONTEXT, next_revision(first),
                              {'kind': 'body', 'operation': 'cut', 'target_body': 'main',
                               'tool': {'family': 'cylinder', 'geometry': {'origin': [0, 0, 0], 'axis': [0, 0, 1], 'radius': .5},
                                        'extent': {'mode': 'through_all'}}})
        original_script = second['script']
        updated = compile_edit(CONTEXT, next_revision(second),
                               {'kind': 'body', 'operation': 'update_parameters', 'values': {'outer-radius': 3}})
        self.assertEqual(second['script'], original_script)
        self.assertAlmostEqual(build(second).Volume(), (4 - .25) * 3 * math.pi, places=7)
        self.assertAlmostEqual(build(updated, step=True).Volume(), (9 - .25) * 3 * math.pi, places=7)
        self.assertEqual(updated['body_ids'], ['main'])
        for values, code in (({'missing': 3}, 'UNKNOWN_PARAMETER'), ({'outer-radius': 0}, 'CONSTRAINT_CONFLICT'),
                             ({'outer-radius': 5}, 'CONSTRAINT_CONFLICT')):
            with self.assertRaises(EditError) as caught:
                compile_edit(CONTEXT, next_revision(second), {'kind': 'body', 'operation': 'update_parameters', 'values': values})
            self.assertEqual(caught.exception.code, code)

    def test_explicit_fixed_binding_cannot_be_changed(self):
        create = box_create()
        create['tool']['geometry']['size'][0] = {'parameter': 'width', 'value': 10, 'fixed': True}
        first = compile_edit(CONTEXT, empty_revision(), create)
        with self.assertRaises(EditError) as caught:
            compile_edit(CONTEXT, next_revision(first), {'kind': 'body', 'operation': 'update_parameters', 'values': {'width': 12}})
        self.assertEqual(caught.exception.code, 'CONSTRAINT_CONFLICT')

    def test_body_free_construction_is_not_a_fake_empty_solid(self):
        base = empty_revision()
        candidate = {'id': 'axis-fit', 'members': [{'id': 'axis-member', 'family': 'line',
                                                 'geometry': {'origin': [0, 0, 0], 'direction': [0, 0, 1]}}]}
        plan = compile_edit(CONTEXT, base, {'kind': 'construction', 'operation': 'add', 'construction_id': 'axis-main',
                                           'tool': {'fit_candidate': 'axis-fit'}}, lambda *args: candidate)
        self.assertIsNone(plan['script'])
        self.assertEqual(plan['body_ids'], [])
        self.assertFalse(plan['requires_body_validation'])
        self.assertTrue(plan['construction_changed'])
        self.assertEqual(plan['constructions']['axis-main']['family'], 'line')
        profile = square_profile()
        profile['loops'] = [{'closed': False, 'points': [[0, 0], [2, 0], [2, 1]]}]
        second = compile_edit(CONTEXT, next_revision(plan),
                              {'kind': 'construction', 'operation': 'add', 'construction_id': 'open-guide',
                               'tool': {'family': 'profile', 'geometry': profile}})
        self.assertIsNone(second['script'])
        self.assertFalse(second['constructions']['open-guide']['geometry']['loops'][0]['closed'])
        with self.assertRaises(EditError) as caught:
            compile_edit(CONTEXT, next_revision(second),
                         {'kind': 'body', 'operation': 'create', 'tool': {'family': 'extrusion', 'geometry': {'profile': profile},
                                                                        'extent': {'mode': 'depth', 'depth': 2}}})
        self.assertEqual(caught.exception.code, 'INVALID_PROFILE')

    def test_construction_does_not_rebuild_or_replace_an_existing_body(self):
        first = compile_edit(CONTEXT, empty_revision(), box_create())
        revision = next_revision(first)
        plan = compile_edit(CONTEXT, revision,
                            {'kind': 'construction', 'operation': 'add', 'construction_id': 'plane-top',
                             'tool': {'family': 'plane', 'geometry': {'origin': [0, 0, 5], 'normal': [0, 0, 1]}}})
        self.assertEqual(plan['script'], revision['script'])
        self.assertFalse(plan['requires_body_validation'])
        self.assertEqual(plan['body_ids'], ['body-main'])
        self.assertEqual(plan['invalidated_comparisons'], 'none')

    def test_construction_preserves_unwrapped_saved_program_before_later_typed_edit(self):
        revision = {'id': 'saved', 'script': 'result = cq.Solid.makeBox(10,10,5)\n',
                    'state': {'body_ids': ['body-main']}}
        construction = compile_edit(CONTEXT, revision,
                                    {'kind': 'construction', 'operation': 'add', 'construction_id': 'axis',
                                     'tool': {'family': 'line', 'geometry': {'origin': [0,0,0], 'direction': [0,0,1]}}})
        self.assertEqual(construction['script'], revision['script'])
        self.assertFalse(construction['state']['generated_program'])
        cut = compile_edit(CONTEXT, next_revision(construction),
                           {'kind': 'body', 'operation': 'cut', 'target_body': 'body-main',
                            'tool': {'family': 'cylinder', 'geometry': {'origin': [5,5,0], 'axis': [0,0,1], 'radius': 1},
                                     'extent': {'mode': 'through_all'}}})
        self.assertAlmostEqual(build(cut).Volume(), 500-5*math.pi, places=7)

    def test_fitted_profile_loop_roles_are_explicit_and_candidate_is_immutable(self):
        geometry = square_profile()
        geometry['loops'][0]['role'] = 'outer'
        geometry['loops'].append({'closed': True, 'role': 'unclassified_nested_or_disconnected',
                                  'points': [[4,4],[6,4],[6,6],[4,6]]})
        candidate = {'id': 'profile-fit', 'members': [{'id': 'outline', 'family': 'profile', 'geometry': geometry}]}
        original = copy.deepcopy(candidate)
        edit = {'kind': 'body', 'operation': 'create',
                'tool': {'fit_candidate': 'profile-fit', 'realization': 'extrusion',
                         'extent': {'mode': 'depth', 'depth': 2}}}
        with self.assertRaises(EditError) as caught:
            compile_edit(CONTEXT, empty_revision(), edit, lambda *args: candidate)
        self.assertEqual(caught.exception.code, 'AMBIGUOUS_REBIND')
        edit['tool']['loop_roles'] = ['outer', 'hole']
        plan = compile_edit(CONTEXT, empty_revision(), edit, lambda *args: candidate)
        self.assertAlmostEqual(build(plan, step=True).Volume(), 192, places=7)
        self.assertEqual(candidate, original)

    def test_fillet_requires_unique_geometric_adjacency_and_preserves_base_on_failure(self):
        first = compile_edit(CONTEXT, empty_revision(), box_create())
        revision = next_revision(first)
        saved = copy.deepcopy(revision)
        operation = {'kind': 'body', 'operation': 'fillet', 'target_body': 'body-main', 'radius': 1,
                     'edges': [{'point': [0, 0, 2.5], 'max_distance': .01, 'adjacent_surfaces': ['plane', 'plane']}]}
        good = compile_edit(CONTEXT, revision, operation)
        shape = build(good, step=True)
        self.assertGreater(shape.Volume(), 490)
        self.assertLess(shape.Volume(), 500)
        operation['edges'][0]['point'] = [0, 0, 0]
        failed = compile_edit(CONTEXT, revision, operation)
        with self.assertRaisesRegex(worker.ModelError, 'operation 0: fillet.*AMBIGUOUS_REBIND'):
            build(failed)
        self.assertEqual(revision, saved)
        self.assertAlmostEqual(build(first).Volume(), 500, places=7)

    def test_analytic_line_arc_profile_hole_extrudes_and_meridian_revolves(self):
        profile = square_profile()
        profile['loops'].append({'closed': True, 'segments': [
            {'kind': 'arc', 'start': [6, 5], 'mid': [5, 6], 'end': [4, 5]},
            {'kind': 'arc', 'start': [4, 5], 'mid': [5, 4], 'end': [6, 5]}]})
        plan = compile_edit(CONTEXT, empty_revision(),
                            {'kind': 'body', 'operation': 'create', 'tool': {'family': 'extrusion',
                             'geometry': {'profile': profile, 'direction': [0, 0, 1]}, 'extent': {'mode': 'depth', 'depth': 2}}})
        self.assertAlmostEqual(build(plan, step=True).Volume(), 200 - 2 * math.pi, places=7)
        radial = square_profile()
        radial['loops'] = [{'closed': True, 'points': [[1, 0], [2, 0], [2, 3], [1, 3]]}]
        geometry = {'profile': radial, 'origin': [0, 0, 0], 'axis': [0, 0, 1], 'x_direction': [1, 0, 0]}
        edit = {'kind': 'body', 'operation': 'create', 'tool': {'family': 'revolution', 'geometry': geometry, 'angle_degrees': 360}}
        plan = compile_edit(CONTEXT, empty_revision(), edit)
        self.assertAlmostEqual(build(plan, step=True).Volume(), 9 * math.pi, places=7)
        del edit['tool']['angle_degrees']
        with self.assertRaises(EditError) as caught:
            compile_edit(CONTEXT, empty_revision(), edit)
        self.assertEqual(caught.exception.code, 'INSUFFICIENT_EVIDENCE')

    def test_sphere_and_cone_apex_realizations_are_native_solids(self):
        sphere = compile_edit(CONTEXT, empty_revision(), {'kind': 'body', 'operation': 'create',
                              'tool': {'family': 'sphere', 'geometry': {'center': [1, 2, 3], 'radius': 2}}})
        self.assertAlmostEqual(build(sphere).Volume(), 32 * math.pi / 3, places=7)
        cone = compile_edit(CONTEXT, empty_revision(), {'kind': 'body', 'operation': 'create',
                            'tool': {'family': 'cone', 'geometry': {'origin': [0, 0, 0], 'axis': [0, 0, 1], 'radius': 0, 'slope': 1},
                                     'extent': {'mode': 'bounded', 'interval': [0, 3]}}})
        self.assertAlmostEqual(build(cone, step=True).Volume(), 9 * math.pi, places=7)

    def test_program_replace_keeps_complete_python_and_explicit_body_bindings(self):
        program = '"""Portable design source."""\nfrom __future__ import annotations\nimport cadquery as cq\nfirst = cq.Solid.makeBox(1,2,3)\nsecond = cq.Solid.makeSphere(1, (10,0,0), angleDegrees1=-90, angleDegrees2=90)\nresult = cq.Compound.makeCompound([first, second])\n'
        plan = compile_edit(CONTEXT, empty_revision(),
                            {'kind': 'body', 'operation': 'program_replace', 'program': program,
                             'body_ids': ['part-a', 'part-b'], 'body_bindings': {'part-a': 'first', 'part-b': 'second'}})
        shape = build(plan, step=True)
        self.assertEqual(len(shape.Solids()), 2)
        self.assertAlmostEqual(shape.Volume(), 6 + 4 * math.pi / 3, places=7)
        self.assertIn('second = cq.Solid.makeSphere', plan['script'])
        self.assertNotIn('source.brep', plan['script'])
        with self.assertRaises(EditError):
            compile_edit(CONTEXT, empty_revision(), {'kind': 'body', 'operation': 'program_replace', 'program': program,
                                                     'body_ids': ['part-a', 'part-b']})

    def test_compile_does_not_execute_and_parameter_ids_are_quoted_data(self):
        key = "radius']; raise RuntimeError('injected') #"
        edit = {'kind': 'body', 'operation': 'create',
                'tool': {'family': 'sphere', 'geometry': {'center': [0, 0, 0], 'radius': {'parameter': key, 'value': 2}}}}
        with mock.patch('builtins.exec', side_effect=AssertionError('compiler executed candidate code')):
            plan = compile_edit(CONTEXT, empty_revision(), edit)
        self.assertAlmostEqual(build(plan).Volume(), 32 * math.pi / 3, places=7)
        plan = compile_edit(CONTEXT, empty_revision(), {'kind': 'body', 'operation': 'program_replace',
                                                       'program': "raise RuntimeError('only worker may run this')\nresult = None"})
        with self.assertRaisesRegex(worker.ModelError, 'only worker may run this'):
            build(plan)

    def test_control_characters_cannot_escape_generated_operation_comments(self):
        for identity in ('body\nraise RuntimeError("injected")\n#', 'body\rreturn', 'body\tmain',
                         'body\x00main', 'body\u2028main', 'body\u200bmain'):
            with self.subTest(identity=repr(identity)):
                with self.assertRaises(EditError) as caught:
                    compile_edit(CONTEXT, empty_revision(), box_create(body_id=identity))
                self.assertEqual(caught.exception.code, 'INVALID_EDIT')
        edit = {'kind': 'body', 'operation': 'create', 'tool': {'family': 'sphere',
                'geometry': {'center': [0, 0, 0], 'radius': {'parameter': 'radius\n#', 'value': 2}}}}
        with self.assertRaises(EditError):
            compile_edit(CONTEXT, empty_revision(), edit)

    def test_ordinary_edit_omission_cannot_disable_existing_active_invariants(self):
        invariant = {'id': 'preserve-axis', 'kind': 'cylinder', 'radius': 2}
        base = empty_revision(active_invariants=[invariant], constraints=[{'id': 'fixed-width', 'kind': 'fixed', 'value': 10}])
        plan = compile_edit(CONTEXT, base, box_create())
        self.assertEqual(plan['active_invariants'], [invariant])
        self.assertEqual(plan['constraints'], base['state']['constraints'])
        edit = box_create(active_invariants=[dict(invariant, radius=1)])
        with self.assertRaises(EditError) as caught:
            compile_edit(CONTEXT, base, edit)
        self.assertEqual(caught.exception.code, 'CONSTRAINT_CONFLICT')

    def test_missing_targets_extents_unsupported_operations_and_source_budget_are_localized(self):
        for edit, code in [({'kind': 'body', 'operation': 'cut', 'target_body': 'missing', 'tool': {}}, 'UNKNOWN_ENTITY'),
                           ({'kind': 'body', 'operation': 'create', 'tool': {'family': 'cylinder', 'geometry': {'origin': [0,0,0], 'axis': [0,0,1], 'radius': 1}}}, 'INSUFFICIENT_EVIDENCE'),
                           ({'kind': 'body', 'operation': 'create', 'tool': {'family': 'mesh', 'geometry': {}}}, 'UNSUPPORTED_OPERATION'),
                           ({'kind': 'body', 'operation': 'program_replace', 'program': 'result = None\n' + '#' * 200001}, 'RESOURCE_LIMIT')]:
            with self.subTest(code=code):
                with self.assertRaises(EditError) as caught:
                    compile_edit(CONTEXT, empty_revision(), edit)
                self.assertEqual(caught.exception.code, code)
                self.assertEqual(caught.exception.details['operation_index'], 0)
        with self.assertRaises(EditError) as caught:
            compile_edit({'units': 'inch'}, empty_revision(), box_create())
        self.assertEqual(caught.exception.code, 'UNSUPPORTED_UNITS')

    def test_unrequested_body_split_is_not_named_by_native_enumeration(self):
        first = compile_edit(CONTEXT, empty_revision(), box_create())
        cutter = {'kind': 'body', 'operation': 'cut', 'target_body': 'body-main',
                  'tool': {'family': 'box', 'geometry': {'origin': [4, -1, -1], 'size': [2, 12, 7]}}}
        plan = compile_edit(CONTEXT, next_revision(first), cutter)
        with self.assertRaisesRegex(worker.ModelError, 'automatic split rebinding is unavailable'):
            build(plan)


if __name__ == '__main__':
    unittest.main()
