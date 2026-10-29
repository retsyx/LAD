"""Saved design version discovery, replay binding and MCP transport contracts."""
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


class VersionMCPToolTests(unittest.TestCase):
    def test_history_listing_is_bounded_and_read_only(self):
        _, description, schema, read_only = next(tool for tool in TOOLS if tool[0] == 'lad_versions')
        self.assertTrue(read_only)
        self.assertEqual(schema['required'], [])
        self.assertFalse(schema['additionalProperties'])
        self.assertEqual(set(schema['properties']), {'offset', 'limit'})
        self.assertEqual(schema['properties']['offset'], {'type': 'integer', 'minimum': 0, 'default': 0})
        self.assertEqual(schema['properties']['limit'], {'type': 'integer', 'minimum': 1, 'maximum': 100, 'default': 50})
        self.assertIn('stable IDs', description)
        self.assertIn('current-version marker', description)
        self.assertIn('does not build geometry, select a version or change the viewport', description)

    def test_version_lookup_requires_a_reference_and_returns_file_references(self):
        _, description, schema, read_only = next(tool for tool in TOOLS if tool[0] == 'lad_version')
        self.assertTrue(read_only)
        self.assertEqual(schema['required'], ['reference'])
        self.assertEqual(set(schema['properties']), {'reference'})
        self.assertEqual(schema['properties']['reference']['type'], 'string')
        self.assertFalse(schema['additionalProperties'])
        for supported_reference in ('UUID', 'vN', 'custom name'):
            self.assertIn(supported_reference, description)
        self.assertIn('exact case-sensitive custom name', description)
        self.assertIn("a name matching another version's vN label", description)
        self.assertIn('local paths', description)
        self.assertIn('never inline source or binary data', description)
        self.assertIn('Ambiguous names return candidates', description)

    def test_historical_replay_is_optional_and_scoped_to_one_build(self):
        _, _, schema, _ = next(tool for tool in TOOLS if tool[0] == 'lad_build')
        self.assertEqual(schema['required'], ['programPath'])
        version_id = schema['properties']['versionID']
        self.assertEqual(version_id['type'], 'string')
        self.assertIn('stable UUID returned by lad_version', version_id['description'])
        self.assertIn('for this build only', version_id['description'])
        self.assertIn('does not change the current design or register historical inputs', version_id['description'])
        self.assertIn('lad_versions and lad_version', INSTRUCTIONS)
        self.assertIn('task\'s saved history snapshot', INSTRUCTIONS)
        self.assertIn('ambiguous names require clarification', INSTRUCTIONS)
        self.assertIn('Never import generated geometry from earlier versions', INSTRUCTIONS)

    def test_informational_history_lookup_does_not_require_a_replacement_program(self):
        self.assertIn('When creating or modifying geometry', INSTRUCTIONS)
        self.assertIn('a message response does not require a CAD build or replacement program', INSTRUCTIONS)
        self.assertIn('For geometry changes, inspect and repair', INSTRUCTIONS)

    def test_history_calls_and_replay_binding_reach_the_native_host_unchanged(self):
        version_id = '17846697-B847-47F3-944E-D184A26DB12A'
        requests_to_send = [
            ('lad_versions', {'offset': 50, 'limit': 25}),
            ('lad_version', {'reference': 'v3'}),
            ('lad_version', {'reference': 'Original lid'}),
            ('lad_version', {'reference': version_id}),
            ('lad_build', {'programPath': 'versions/v3/program.py', 'versionID': version_id}),
        ]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            control = folder / '.lad-tools'
            requests = control / 'requests'
            responses = control / 'responses'
            requests.mkdir(parents=True)
            responses.mkdir()
            native = NativeBridge(folder)
            received = []
            handled = set()

            def host():
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline and len(received) < len(requests_to_send):
                    for pending in requests.glob('*.json'):
                        if pending.name in handled:
                            continue
                        handled.add(pending.name)
                        request = json.loads(pending.read_text())
                        received.append(request)
                        payload = {'content': [{'type': 'text', 'text': json.dumps({'arguments': request['arguments']})}]}
                        temporary = responses / (request['id'] + '.tmp')
                        temporary.write_text(json.dumps(payload))
                        temporary.replace(responses / (request['id'] + '.json'))
                    time.sleep(0.01)
                if len(received) != len(requests_to_send):
                    (control / 'closed').write_text('host ended')

            worker = threading.Thread(target=host)
            worker.start()
            try:
                with patch('agent_server.os.kill'):
                    for name, arguments in requests_to_send:
                        result = native.call(name, arguments)
                        self.assertEqual(json.loads(result['content'][0]['text'])['arguments'], arguments)
            finally:
                worker.join(timeout=5)
                os.close(native.request_fd)
                os.close(native.response_fd)
            self.assertFalse(worker.is_alive())
            self.assertEqual([(request['name'], request['arguments']) for request in received], requests_to_send)
            self.assertFalse(list(responses.iterdir()))


if __name__ == '__main__':
    unittest.main()
