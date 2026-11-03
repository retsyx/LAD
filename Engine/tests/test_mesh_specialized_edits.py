"""Recognized surface evidence becomes solids only through explicit CAD edits."""
import copy
import math
from pathlib import Path
import sys
import tempfile
import unittest

import cadquery as cq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mesh_edits import compile_edit, EditError
import worker


CONTEXT = {'id': 'specialized-reference', 'units': 'mm', 'max_deviation': .03}


def empty_revision():
    return {'id': 'r0', 'script': None, 'state': {'body_ids': []}}


def revision(plan):
    return {'id': 'r1', 'script': plan['script'], 'state': copy.deepcopy(plan['state'])}


def create(family, geometry, **choices):
    return {'kind': 'body', 'operation': 'create', 'target_body': 'reference-part',
            'tool': {'family': family, 'geometry': geometry, **choices}}


def build(plan, step=False):
    shape = worker.build_shape({'title': 'Reconstruction', 'summary': 'Explicit specialized edit',
                                'units': 'mm', 'script': plan['script']})
    if step:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'part.step'
            cq.exporters.export(shape, str(path))
            worker.validate_step_roundtrip(shape, cq, path)
    return shape


def helix_geometry(**changes):
    geometry = {'kind': 'helical_sweep', 'origin': [14, -8, 5], 'axis': [1, 2, 3],
                'x_direction': [-2, 1, 0], 'pitch': 4, 'handedness': 'right', 'phase_degrees': 25,
                'profile': {'origin': [0, 0, 0], 'normal': [0, 0, 1], 'x_direction': [1, 0, 0],
                            'loops': [{'closed': True, 'points': [
                                [28.98494914, .5411508531], [31.22310103, 1.8333473969],
                                [31.22310103, 2.1666525946], [28.98494914, 3.4588491383]]}]}}
    geometry.update(changes)
    return geometry


def rounded_geometry():
    t = math.sqrt(.5)
    # A 6 x 4 profile with one-millimeter corners; endpoints close exactly.
    segments = [
        {'kind': 'line', 'start': [-2, -2], 'end': [2, -2]},
        {'kind': 'arc', 'start': [2, -2], 'mid': [2+t, -1-t], 'end': [3, -1]},
        {'kind': 'line', 'start': [3, -1], 'end': [3, 1]},
        {'kind': 'arc', 'start': [3, 1], 'mid': [2+t, 1+t], 'end': [2, 2]},
        {'kind': 'line', 'start': [2, 2], 'end': [-2, 2]},
        {'kind': 'arc', 'start': [-2, 2], 'mid': [-2-t, 1+t], 'end': [-3, 1]},
        {'kind': 'line', 'start': [-3, 1], 'end': [-3, -1]},
        {'kind': 'arc', 'start': [-3, -1], 'mid': [-2-t, -1-t], 'end': [-2, -2]}]
    return {'kind': 'rounded_rectangle_extrusion', 'direction': [0, 1, 1],
            'profile': {'origin': [10, 20, 30], 'normal': [0, 1, 1], 'x_direction': [1, 0, 0],
                        'loops': [{'closed': True, 'segments': segments}]},
            'observed_interval': [0, 3], 'dimensions': {'width': 6, 'height': 4, 'corner_radius': 1}}


class SpecializedEditTests(unittest.TestCase):
    def test_fitted_torus_requires_full_extent_and_replays_native_ring(self):
        geometry = {'kind': 'torus', 'center': [7, -3, 4], 'axis': [1, 2, 3],
                    'major_radius': 5, 'minor_radius': 1}
        candidate = {'id': 'torus-fit', 'evidence_ids': ['rim'], 'members': [
            {'id': 'torus-member', 'family': 'torus', 'geometry': geometry,
             'observed_extent': {'bounds': {'min': [0, 0, 0], 'max': [1, 1, 1]}}}]}
        original = copy.deepcopy(candidate)
        for extent in (None, {'mode': 'observed'}, {'mode': 'bounded', 'interval': [0, 1]}):
            tool = {'fit_candidate': 'torus-fit', **({'extent': extent} if extent else {})}
            with self.assertRaises(EditError):
                compile_edit(CONTEXT, empty_revision(), {'kind': 'body', 'operation': 'create', 'tool': tool},
                             lambda *_: candidate)
        plan = compile_edit(CONTEXT, empty_revision(), {'kind': 'body', 'operation': 'create',
                            'tool': {'fit_candidate': 'torus-fit', 'extent': {'mode': 'full'}}}, lambda *_: candidate)
        shape = build(plan, step=True)
        self.assertAlmostEqual(shape.Volume(), 2*math.pi**2*5, places=7)
        self.assertLess((shape.Center()-cq.Vector(7, -3, 4)).Length, 1e-8)
        self.assertEqual({f.geomType() for f in shape.Faces()}, {'TORUS'})
        self.assertEqual(candidate, original)
        self.assertEqual(plan['dependencies'][0]['member_id'], 'torus-member')

    def test_concentric_spheres_require_material_choice_and_preserve_cavity(self):
        geometry = {'kind': 'concentric_spherical_shell', 'center': [-3, 5, 7],
                    'outer_radius': 5, 'inner_radius': 4}
        with self.assertRaises(EditError):
            compile_edit(CONTEXT, empty_revision(), create('concentric_spherical_shell', geometry))
        plan = compile_edit(CONTEXT, empty_revision(), create('concentric_spherical_shell', geometry,
                            material='between_surfaces'))
        shape = build(plan, step=True)
        self.assertAlmostEqual(shape.Volume(), 4*math.pi*(125-64)/3, places=7)
        self.assertEqual(len(shape.Solids()), 1)
        self.assertEqual(len(shape.Shells()), 2)
        self.assertFalse(shape.isInside(cq.Vector(-3, 5, 7)))
        self.assertTrue(shape.isInside(cq.Vector(1.5, 5, 7)))
        self.assertEqual(plan['normalized_edit']['realization']['material'], 'between_surfaces')

    def test_rounded_fit_uses_analytic_profile_frame_and_explicit_observed_extent(self):
        geometry = rounded_geometry()
        with self.assertRaises(EditError):
            compile_edit(CONTEXT, empty_revision(), create('rounded_rectangle_extrusion', geometry))
        plan = compile_edit(CONTEXT, empty_revision(), create('rounded_rectangle_extrusion', geometry,
                            extent={'mode': 'observed'}))
        shape = build(plan, step=True)
        self.assertAlmostEqual(shape.Volume(), (20+math.pi)*3, places=7)
        expected = cq.Vector(10, 20, 30)+cq.Vector(0, 1, 1).normalized()*1.5
        self.assertLess((shape.Center()-expected).Length, 1e-8)
        self.assertEqual(sum(f.geomType() == 'CYLINDER' for f in shape.Faces()), 4)
        self.assertEqual(plan['normalized_edit']['realization']['extent'], {'mode': 'bounded', 'interval': [0., 3.]})

    def test_tilted_helix_keeps_handed_phase_at_positive_and_negative_nonintegral_clipping(self):
        for handedness, sign, phase, low, high in [('right', 1, 25, .35, 4.25),
                                                  ('left', -1, -37, -2.35, 2.25)]:
            with self.subTest(handedness=handedness):
                geometry = helix_geometry(handedness=handedness, phase_degrees=phase)
                original = copy.deepcopy(geometry)
                plan = compile_edit(CONTEXT, empty_revision(), create('helical_sweep', geometry,
                                    extent={'mode': 'bounded', 'interval': [low, high]}))
                shape = build(plan, step=True)
                frame = cq.Plane(origin=tuple(geometry['origin']), xDir=tuple(geometry['x_direction']),
                                 normal=tuple(geometry['axis']))
                local = shape.moved(frame.location.inverse)
                bounds = worker.exact_bounds(local)
                self.assertAlmostEqual(bounds[2], low, delta=1e-4)
                self.assertAlmostEqual(bounds[5], high, delta=1e-4)
                radius, theta = 30., 1.2
                flank = .5411508531+(radius-28.98494914)/math.sqrt(3)
                z = flank+sign*4*(theta-math.radians(phase))/(2*math.pi)
                z = next(z+4*k for k in range(-3, 4) if low+.1 < z+4*k < high-.1)
                point = frame.toWorldCoords((radius*math.cos(theta), radius*math.sin(theta), z))
                witness = cq.Vertex.makeVertex(*point.toTuple())
                self.assertLess(min(face.distance(witness) for face in shape.Faces()), 5e-5)
                self.assertEqual(geometry, original)
                self.assertNotIn('mesh_models', plan['script'])
                self.assertNotIn('importStep', plan['script'])

    def test_helix_observed_extent_is_explicit_and_source_program_stays_complete(self):
        geometry = helix_geometry(origin=[0, 0, 0], axis=[0, 0, 1], x_direction=[1, 0, 0])
        candidate = {'id': 'thread-fit', 'members': [{'id': 'thread-member', 'family': 'helical_sweep',
                     'geometry': geometry, 'observed_extent': {'axial_interval': [0, 4]}}]}
        edit = {'kind': 'body', 'operation': 'create', 'tool': {'fit_candidate': 'thread-fit',
                 'extent': {'mode': 'observed'}}}
        plan = compile_edit(CONTEXT, empty_revision(), edit, lambda *_: candidate)
        self.assertAlmostEqual(worker.exact_bounds(build(plan))[5], 4, delta=1e-4)
        original_source = plan['script']
        datum = compile_edit(CONTEXT, revision(plan), {'kind': 'construction', 'operation': 'add',
                    'construction_id': 'guide', 'tool': {'family': 'line',
                    'geometry': {'origin': [0, 0, 0], 'direction': [0, 0, 1]}}})
        self.assertEqual(datum['script'], original_source)
        self.assertEqual(plan['script'], original_source)
        self.assertEqual(plan['final_acceptance'], 'not_evaluated')

    def test_invalid_specialized_geometries_are_rejected_before_execution(self):
        invalid = [
            create('torus', {'center': [0, 0, 0], 'axis': [0, 0, 1], 'major_radius': 1, 'minor_radius': 2}, extent={'mode': 'full'}),
            create('concentric_spherical_shell', {'center': [0, 0, 0], 'outer_radius': 2, 'inner_radius': 2}, material='between_surfaces'),
            create('helical_sweep', helix_geometry(), extent={'mode': 'through_all'}),
            create('helical_sweep', helix_geometry(), extent={'mode': 'depth', 'depth': 600}),
            create('helical_sweep', helix_geometry(pitch=0), extent={'mode': 'depth', 'depth': 4}),
            create('helical_sweep', helix_geometry(pitch=2), extent={'mode': 'depth', 'depth': 4}),
            create('helical_sweep', helix_geometry(handedness='unknown'), extent={'mode': 'depth', 'depth': 4}),
            create('helical_sweep', helix_geometry(x_direction=[1, 2, 3]), extent={'mode': 'depth', 'depth': 4})]
        for change in ('radial', 'open', 'profile_frame'):
            geometry = helix_geometry()
            if change == 'radial':
                geometry['profile']['loops'][0]['points'][0][0] = 0
            elif change == 'open':
                geometry['profile']['loops'][0]['closed'] = False
            else:
                geometry['profile']['origin'] = [0, 0, 1]
            invalid.append(create('helical_sweep', geometry, extent={'mode': 'depth', 'depth': 4}))
        for edit in invalid:
            original = copy.deepcopy(edit)
            with self.subTest(edit=edit):
                with self.assertRaises(EditError):
                    compile_edit(CONTEXT, empty_revision(), edit)
                self.assertEqual(edit, original)

    def test_parameter_updates_recheck_specialized_relationships_during_replay(self):
        torus = create('torus', {'center': [0, 0, 0], 'axis': [0, 0, 1],
                       'major_radius': {'parameter': 'major', 'value': 5}, 'minor_radius': 1}, extent={'mode': 'full'})
        shell = create('concentric_spherical_shell', {'center': [0, 0, 0], 'outer_radius': 5,
                       'inner_radius': {'parameter': 'inner', 'value': 4}}, material='between_surfaces')
        helix = create('helical_sweep', helix_geometry(pitch={'parameter': 'pitch', 'value': 4}),
                       extent={'mode': 'depth', 'depth': 4})
        for edit, key, value, message in [(torus, 'major', .5, 'minor radius'),
                                         (shell, 'inner', 6, 'inner radius'),
                                         (helix, 'pitch', 2, 'axial span')]:
            with self.subTest(family=edit['tool']['family']):
                plan = compile_edit(CONTEXT, empty_revision(), edit)
                original = plan['script']
                changed = compile_edit(CONTEXT, revision(plan), {'kind': 'body', 'operation': 'update_parameters',
                                       'values': {key: value}})
                with self.assertRaisesRegex(worker.ModelError, message):
                    build(changed)
                self.assertEqual(plan['script'], original)
        first = compile_edit(CONTEXT, empty_revision(), torus)
        changed = compile_edit(CONTEXT, revision(first), {'kind': 'body', 'operation': 'update_parameters',
                               'values': {'major': 6}})
        self.assertAlmostEqual(build(changed, step=True).Volume(), 12*math.pi**2, places=7)


if __name__ == '__main__':
    unittest.main()
