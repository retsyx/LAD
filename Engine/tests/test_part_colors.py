"""Opaque sRGB colors remain semantic part metadata."""
import copy
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import ModelError, assembly_part_color, build_shape, run, validate_parts


def spec(script):
    return {"title": "Colored assembly", "summary": "Assembly colors", "units": "mm", "script": script}


def flatten(parts):
    return [node for part in parts for node in [part, *flatten(part.get("children") or [])]]


class PartColorTests(unittest.TestCase):
    def assert_color(self, node, expected):
        self.assertEqual(set(node["color"]), {"red", "green", "blue"})
        for channel, value in zip(("red", "green", "blue"), expected):
            self.assertAlmostEqual(node["color"][channel], value, places=6)

    def test_parent_inheritance_child_override_and_split_bodies_keep_native_ownership(self):
        source = """
result = cq.Assembly(cq.Solid.makeBox(2,3,4), name='Product', color=cq.Color(0.2,0.4,0.6), metadata={'lad_id':'product'})
group = cq.Assembly(name='Case', color=cq.Color(0.7,0.3,0.1), metadata={'lad_id':'case'})
compound = cq.Compound.makeCompound([cq.Solid.makeBox(1,2,3).translate((10,0,0)), cq.Solid.makeBox(3,2,1).translate((20,0,0))])
group.add(compound, name='Pair', metadata={'lad_id':'pair'})
group.add(cq.Solid.makeBox(2,2,2), name='Lid', loc=cq.Location((0,20,0)), color=cq.Color(0.8,0.1,0.4), metadata={'lad_id':'lid'})
result.add(group)
result.add(cq.Solid.makeBox(1,1,1), name='Post', loc=cq.Location((0,0,20)), metadata={'lad_id':'post'})
"""
        colored = build_shape(spec(source), 2)
        nodes = {node["id"]: node for node in flatten(colored._lad_parts)}
        self.assertEqual([nodes[key]["solidIndices"] for key in
                          ['body:["product",0]', 'body:["pair",0]', 'body:["pair",1]', 'lid', 'post']],
                         [[0], [1], [2], [3], [4]])
        self.assert_color(nodes['body:["product",0]'], (0.2, 0.4, 0.6))
        self.assert_color(nodes['body:["pair",0]'], (0.7, 0.3, 0.1))
        self.assert_color(nodes['body:["pair",1]'], (0.7, 0.3, 0.1))
        self.assert_color(nodes['lid'], (0.8, 0.1, 0.4))
        self.assert_color(nodes['post'], (0.2, 0.4, 0.6))
        for key in ('product', 'case', 'pair'):
            self.assertNotIn('color', nodes[key], 'A structural group owns no physical finish')
        plain_source = source
        for color in ('cq.Color(0.2,0.4,0.6)', 'cq.Color(0.7,0.3,0.1)', 'cq.Color(0.8,0.1,0.4)'):
            plain_source = plain_source.replace(color, 'None')
        plain = build_shape(spec(plain_source), 2)
        stripped = copy.deepcopy(colored._lad_parts)
        for node in flatten(stripped):
            node.pop('color', None)
        self.assertEqual(stripped, plain._lad_parts, 'Colors must not alter IDs, labels, native order or ownership')
        for a, b in zip(colored.Solids(), plain.Solids()):
            self.assertEqual(a.Center().toTuple(), b.Center().toTuple())

    def test_anonymous_root_and_user_folder_apply_inherited_color_to_physical_owners(self):
        source = """
result = cq.Assembly(color=cq.Color(0.25,0.5,0.75))
result.add(cq.Solid.makeBox(1,2,3), name='Body', metadata={'lad_id':'body'})
folder = cq.Assembly(cq.Solid.makeBox(2,3,4).translate((10,0,0)), name='Folder', metadata={'lad_id':'user-folder:test'})
result.add(folder)
"""
        parts = build_shape(spec(source), 2)._lad_parts
        self.assertEqual([part['id'] for part in parts], ['body', 'user-folder:test'])
        self.assert_color(parts[0], (0.25, 0.5, 0.75))
        self.assertNotIn('color', parts[1])
        self.assert_color(parts[1]['children'][0], (0.25, 0.5, 0.75))

    def test_installed_cadquery_color_tuple_is_srgb_including_linear_input(self):
        import cadquery as cq
        expected = (0.2, 0.4, 0.6)
        self.assert_color({'color': assembly_part_color(cq.Color(*expected))}, expected)
        self.assert_color({'color': assembly_part_color(cq.Color('red'))}, (1, 0, 0))
        linear = (0.05, 0.25, 0.6)
        srgb = tuple(12.92 * value if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055 for value in linear)
        self.assert_color({'color': assembly_part_color(cq.Color(*linear, 1, False))}, srgb)

    def test_nonopaque_assembly_colors_are_rejected_with_actionable_error(self):
        for alpha in (0, 0.5, 0.999):
            source = f"result=cq.Assembly(cq.Solid.makeBox(1,2,3),color=cq.Color(0.2,0.4,0.6,{alpha}))"
            with self.subTest(alpha=alpha), self.assertRaisesRegex(ModelError, 'only opaque.*alpha to 1'):
                build_shape(spec(source), 2)
        import cadquery as cq
        for rgba in ((math.nan, 0, 0, 1), (0, 0, 1.1, 1), (0, 0, 0, math.nan)):
            with self.subTest(rgba=rgba), mock.patch.object(cq.Color, 'toTuple', return_value=rgba), self.assertRaises(ModelError):
                assembly_part_color(cq.Color(0.1, 0.2, 0.3))

    def test_saved_color_schema_is_optional_strict_and_finite(self):
        part = {'id': 'body', 'name': 'Body', 'solidIndices': [0], 'children': None}
        self.assertEqual(validate_parts([part], 1), [part])
        for color in (None, {'red': 0.1, 'green': 0.2, 'blue': 0.3}):
            candidate = {**part, 'color': color}
            self.assertEqual(validate_parts([candidate], 1), [candidate])
        invalid = [[], 'red', {}, {'red': 0, 'green': 0}, {'red': 0, 'green': 0, 'blue': 0, 'alpha': 0.5}]
        for value in (-0.01, 1.01, 10 ** 1000, math.nan, math.inf, True, '0.5', None):
            invalid.append({'red': value, 'green': 0.2, 'blue': 0.3})
        for color in invalid:
            with self.subTest(color=color), self.assertRaisesRegex(ModelError, 'finite sRGB'):
                validate_parts([{**part, 'color': color}], 1)

    def test_saved_exact_preview_replay_retains_colors_without_program_execution(self):
        source = """
result = cq.Assembly(name='Product', color=cq.Color(0.2,0.4,0.6), metadata={'lad_id':'product'})
result.add(cq.Solid.makeBox(2,3,4), name='Body', metadata={'lad_id':'body'})
result.add(cq.Solid.makeBox(1,2,3), name='Cap', loc=cq.Location((10,0,0)), color=cq.Color('red'), metadata={'lad_id':'cap'})
"""
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory) / 'build'
            build.mkdir()
            request = build / 'request.json'
            request.write_text(json.dumps(spec(source)))
            original = run(request, build, 2)
            replay = Path(directory) / 'replay'
            replay.mkdir()
            (replay / 'preview.step').write_bytes(Path(original['stepPath']).read_bytes())
            replay_request = replay / 'request.json'
            replay_request.write_text(json.dumps({'operation': 'preview', 'stepAsset': 'preview.step', 'parts': original['parts']}))
            with mock.patch('worker.build_shape', side_effect=AssertionError('No program execution for exact preview replay')):
                restored = run(replay_request, replay, 2)
            self.assertEqual(restored['parts'], original['parts'])
            self.assertEqual(restored['solids'], 2)
            nodes = {node['id']: node for node in flatten(restored['parts'])}
            self.assert_color(nodes['body'], (0.2, 0.4, 0.6))
            self.assert_color(nodes['cap'], (1, 0, 0))


if __name__ == '__main__':
    unittest.main()
