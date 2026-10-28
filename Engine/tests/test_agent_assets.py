"""Native external-backend import and MCP transport regression checks."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE))
from worker import ModelError, build_shape, import_input_asset, read_mesh, run, validate_spec, write_brep
from agent_server import NativeBridge, read_regular, transport_result


def cube_obj(low=0, high=1, offset=0):
    points = [(low, low, low), (high, low, low), (high, high, low), (low, high, low),
              (low, low, high), (high, low, high), (high, high, high), (low, high, high)]
    faces = [(1, 4, 3, 2), (5, 6, 7, 8), (1, 2, 6, 5), (2, 3, 7, 6), (3, 4, 8, 7), (4, 1, 5, 8)]
    return ''.join('v %s %s %s\n' % point for point in points) + ''.join('f ' + ' '.join(str(i + offset) for i in face) + '\n' for face in faces)


def spec(asset, script=None):
    return {'title': 'External geometry', 'summary': 'Imported input test', 'units': 'mm',
            'script': script or "result = imported_assets['external']", 'inputAssets': [asset]}


class AgentAssetTests(unittest.TestCase):
    def test_input_order_is_available_to_complete_python_programs(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            first = {'id': 'first', 'name': 'one.obj', 'format': 'obj', 'path': 'input-000.obj'}
            second = {'id': 'second', 'name': 'two.obj', 'format': 'obj', 'path': 'input-001.obj'}
            value = spec(first, 'result = next(iter(imported_assets.values()))')
            value['inputAssets'] = [first, second]
            (folder / 'input-000.obj').write_text(cube_obj(0, 1))
            (folder / 'input-001.obj').write_text(cube_obj(0, 2))
            self.assertAlmostEqual(build_shape(value, 2, folder).Volume(), 1, places=8)
            value['inputAssets'] = [{**second, 'path': 'input-000.obj'}, {**first, 'path': 'input-001.obj'}]
            (folder / 'input-000.obj').write_text(cube_obj(0, 2))
            (folder / 'input-001.obj').write_text(cube_obj(0, 1))
            self.assertAlmostEqual(build_shape(value, 2, folder).Volume(), 8, places=8)

    def test_closed_obj_mesh_and_nested_cavity_preserve_volume_and_placement(self):
        import cadquery as cq
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cube.obj'
            path.write_text(cube_obj(10, 12))
            shape = import_input_asset(path, 'obj', cq)
            self.assertAlmostEqual(shape.Volume(), 8, places=8)
            self.assertAlmostEqual(shape.BoundingBox().xmin, 10, places=8)
            path.write_text(cube_obj(0, 4) + cube_obj(1, 3, offset=8))
            hollow = import_input_asset(path, 'obj', cq)
            self.assertEqual(len(hollow.Solids()), 1)
            self.assertAlmostEqual(hollow.Volume(), 56, places=7)

    def test_binary_ascii_stl_and_open_mesh_rejection(self):
        import cadquery as cq
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'cube.stl'
            cq.exporters.export(cq.Solid.makeBox(2, 3, 4), str(path), exportType='STL')
            binary = import_input_asset(path, 'stl', cq)
            self.assertAlmostEqual(binary.Volume(), 24, places=7)
            triangles = read_mesh(path, 'stl')
            text = 'solid cube\n' + ''.join('facet normal 0 0 0\nouter loop\n' + ''.join('vertex %s %s %s\n' % tuple(p) for p in triangle) + 'endloop\nendfacet\n' for triangle in triangles) + 'endsolid cube\n'
            path.write_text(text)
            self.assertAlmostEqual(import_input_asset(path, 'stl', cq).Volume(), 24, places=7)
            path.write_text('solid open\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid\n')
            with self.assertRaisesRegex(ModelError, 'open|closed|watertight'):
                import_input_asset(path, 'stl', cq)

    def test_staged_inputs_replay_with_full_cad_api_and_all_native_formats(self):
        import cadquery as cq
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            expected = cq.Solid.makeBox(2, 3, 4).translate((10, 20, 30))
            cq.exporters.export(expected, str(folder / 'input-000.step'), exportType='STEP')
            write_brep(expected, folder / 'input-000.brep')
            (folder / 'input-000.obj').write_text(cube_obj())
            for format, volume in [('step', 24), ('brep', 24), ('obj', 1)]:
                asset = {'id': 'external', 'name': 'Input geometry', 'format': format, 'path': 'input-000.' + format}
                value = spec(asset, "body = imported_assets['external']\nresult = body.translate((0,0,5))")
                rebuilt = build_shape(value, 2, folder)
                self.assertAlmostEqual(rebuilt.Volume(), volume, places=7)
                if format != 'obj':
                    self.assertAlmostEqual(rebuilt.BoundingBox().zmin, 35, places=7)
            request = folder / 'request.json'
            request.write_text(json.dumps(spec({'id': 'external', 'name': 'Cube', 'format': 'obj', 'path': 'input-000.obj'})))
            preview = run(request, folder, 2, defer_step=True)
            self.assertEqual(preview['solids'], 1)
            self.assertAlmostEqual(preview['volume'], 1, places=7)
            self.assertTrue((folder / 'model.brep').is_file())
            self.assertFalse((folder / 'model.step').exists())

    def test_invalid_asset_records_paths_links_and_mesh_numbers_fail_before_replay(self):
        import cadquery as cq
        valid = {'id': 'external', 'name': 'Cube', 'format': 'obj', 'path': 'input-000.obj'}
        for changed in [{'path': '../cube.obj'}, {'format': 'exe'}, {'format': []}, {'id': ''}, {'name': 1}]:
            with self.subTest(changed=changed), self.assertRaises(ModelError):
                validate_spec(spec({**valid, **changed}))
        value = spec(valid)
        value['inputAssets'] *= 2
        with self.assertRaises(ModelError):
            validate_spec(value)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            original = folder / 'original.obj'
            original.write_text(cube_obj())
            linked = folder / 'input-000.obj'
            linked.symlink_to(original)
            with self.assertRaisesRegex(ModelError, 'regular private'):
                build_shape(spec(valid), 1, folder)
            linked.unlink()
            os.link(original, linked)
            with self.assertRaisesRegex(ModelError, 'regular private'):
                build_shape(spec(valid), 1, folder)
            linked.unlink()
            linked.write_text('v nan 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n')
            with self.assertRaisesRegex(ModelError, 'invalid|out-of-range'):
                import_input_asset(linked, 'obj', cq)

    def test_runtime_query_does_not_create_native_or_step_geometry(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            request = folder / 'request.json'
            request.write_text('{"operation":"runtime"}')
            result = run(request, folder, 2)
            self.assertIn('cadquery', result['runtime'])
            self.assertNotIn('solids', result)
            self.assertFalse((folder / 'model.step').exists())
            self.assertFalse((folder / 'model.brep').exists())


class MCPTransportTests(unittest.TestCase):
    def prepare(self, folder):
        bridge = folder / '.lad-tools'
        (bridge / 'requests').mkdir(parents=True)
        (bridge / 'responses').mkdir()
        return bridge

    def test_stdio_protocol_discovers_tools_and_returns_real_image_content(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            bridge = self.prepare(folder)
            # Header is enough for transport: native render tests validate actual PNGs.
            image = folder / 'render.png'
            image.write_bytes(b'\x89PNG\r\n\x1a\nexample')
            process = subprocess.Popen([sys.executable, str(ENGINE / 'agent_server.py'), '--workspace', str(folder)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            def call(message):
                process.stdin.write(json.dumps(message) + '\n'); process.stdin.flush()
                return json.loads(process.stdout.readline())
            try:
                initialized = call({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05'}})
                self.assertIn('no CAD bootstrap', initialized['result']['instructions'])
                tools = call({'jsonrpc':'2.0','id':2,'method':'tools/list'})['result']['tools']
                names = {tool['name'] for tool in tools}
                self.assertTrue({'lad_build','lad_inspect','lad_measure','lad_render','lad_screenshot','lad_import','lad_validate','lad_export_step','lad_runtime'} <= names)
                def native():
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        requests = list((bridge/'requests').glob('*.json'))
                        if requests:
                            request = json.loads(requests[0].read_text())
                            self.assertEqual(request['name'], 'lad_render')
                            (bridge/'responses'/(request['id']+'.json')).write_text(json.dumps({'content':[{'type':'text','text':'{"artifactID":"test"}'},{'type':'image_path','path':str(image),'mimeType':'image/png'}]}))
                            return
                        time.sleep(0.01)
                thread = threading.Thread(target=native); thread.start()
                result = call({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'lad_render','arguments':{'artifactID':'test'}}})['result']
                thread.join()
                self.assertEqual(result['content'][1]['type'], 'image')
                self.assertEqual(base64.b64decode(result['content'][1]['data']), image.read_bytes())
                self.assertFalse(list((bridge/'responses').glob('*.json')))
                (bridge/'closed').write_text('closed')
                failed = call({'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'lad_runtime','arguments':{}}})['result']
                self.assertTrue(failed['isError'])
                self.assertIn('stopped', failed['content'][0]['text'])
            finally:
                process.stdin.close()
                process.wait(timeout=3)
                self.assertEqual(process.returncode, 0, process.stderr.read())
                process.stdout.close(); process.stderr.close()

    def test_image_adapter_rejects_external_paths_symlinks_and_hardlinks(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            folder = Path(directory)
            external = Path(outside)/'image.png'; external.write_bytes(b'\x89PNG\r\n\x1a\nimage')
            for path in [external, folder/'symlink.png', folder/'hardlink.png']:
                if path.name == 'symlink.png': path.symlink_to(external)
                if path.name == 'hardlink.png': os.link(external, path)
                with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                    transport_result(folder, {'content':[{'type':'image_path','path':str(path)}]})
            link = folder/'linked-dir'; link.symlink_to(Path(outside), target_is_directory=True)
            with self.assertRaises(OSError):
                read_regular(folder, link/'image.png', 1024)


if __name__ == '__main__':
    unittest.main()
