"""Agent-selected KiCad conversion discovery and transport contracts."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE))
from agent_server import INSTRUCTIONS, NativeBridge, TOOLS


class KiCadMCPToolTests(unittest.TestCase):
    def test_conversion_tool_requires_an_exact_source_and_writes_task_output(self):
        tool = next(tool for tool in TOOLS if tool[0] == 'lad_convert_kicad')
        _, description, schema, read_only = tool
        self.assertEqual(schema['required'], ['boardPath'])
        self.assertEqual(set(schema['properties']), {'boardPath', 'path'})
        self.assertFalse(schema['additionalProperties'])
        self.assertFalse(read_only)
        self.assertIn('does not build, import, register an asset or commit', description)
        self.assertIn('absolute original source reference', schema['properties']['boardPath']['description'])
        self.assertIn('inside the task workspace', schema['properties']['path']['description'])

    def test_agent_instructions_keep_authored_geometry_in_the_recipe(self):
        self.assertIn('lad_convert_kicad', INSTRUCTIONS)
        self.assertIn('NEVER export/import, reimport or use lad_import for geometry generated as part of the current design', INSTRUCTIONS)
        self.assertIn('replayable CAD program', INSTRUCTIONS)
        importer = next(tool for tool in TOOLS if tool[0] == 'lad_import')
        self.assertIn('pre-existing external/reference', importer[1])
        self.assertIn('Never import geometry generated as part of the current design', importer[1])
        self.assertNotIn('including SDF workflows', importer[1])

    def test_explicit_converter_call_returns_only_the_native_conversion_response(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            control = folder / '.lad-tools'
            requests = control / 'requests'
            responses = control / 'responses'
            requests.mkdir(parents=True)
            responses.mkdir()
            native = NativeBridge(folder)
            received = []
            parent_probed = threading.Event()
            def sandboxed_parent_probe(pid, signal):
                parent_probed.set()
                raise PermissionError("The sandbox forbids signaling this live parent")
            metadata = {'path': str(folder / 'references' / 'pcb.step'), 'format': 'step',
                        'coverageComplete': False, 'missingModels': ['J1: source model missing']}
            def host():
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    pending = list(requests.glob('*.json'))
                    if pending:
                        request = json.loads(pending[0].read_text())
                        received.append(request)
                        if not parent_probed.wait(timeout=2):
                            (control / 'closed').write_text('parent probe did not occur')
                            return
                        payload = {'content': [{'type': 'text', 'text': json.dumps(metadata)}]}
                        temporary = responses / (request['id'] + '.tmp')
                        temporary.write_text(json.dumps(payload))
                        temporary.replace(responses / (request['id'] + '.json'))
                        return
                    time.sleep(0.01)
                (control / 'closed').write_text('closed')
            worker = threading.Thread(target=host)
            worker.start()
            arguments = {'boardPath': '/outside/user supplied.kicad_pcb', 'path': 'references/pcb.step'}
            try:
                with patch('agent_server.os.kill', side_effect=sandboxed_parent_probe):
                    result = native.call('lad_convert_kicad', arguments)
            finally:
                worker.join(timeout=4)
                os.close(native.request_fd)
                os.close(native.response_fd)
            self.assertFalse(worker.is_alive())
            self.assertTrue(parent_probed.is_set(), 'EPERM must keep waiting for the live native host')
            self.assertEqual(len(received), 1)
            self.assertEqual(received[0]['name'], 'lad_convert_kicad')
            self.assertEqual(received[0]['arguments'], arguments)
            self.assertEqual(json.loads(result['content'][0]['text']), metadata)
            self.assertNotIn('artifactID', result['content'][0]['text'])
            self.assertNotIn('assetID', result['content'][0]['text'])
            self.assertFalse(list(responses.iterdir()))


if __name__ == '__main__':
    unittest.main()
