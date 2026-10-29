"""Permission-only MCP discovery, current-policy instructions and transport."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_server import INSTRUCTIONS, NativeBridge, TOOLS


class PermissionMCPToolTests(unittest.TestCase):
    def test_permission_schema_is_bounded_and_contains_no_execution_input(self):
        _, description, schema, read_only = next(tool for tool in TOOLS if tool[0] == 'lad_request_permission')
        self.assertFalse(read_only, 'A remembered user decision may change the global policy.')
        self.assertEqual(schema['required'], ['operation', 'reason'])
        self.assertFalse(schema['additionalProperties'])
        self.assertEqual(set(schema['properties']), {'operation', 'reason'})
        for name, maximum in [('operation', 200), ('reason', 2000)]:
            field = schema['properties'][name]
            self.assertEqual(field['type'], 'string')
            self.assertEqual(field['minLength'], 1)
            self.assertEqual(field['maxLength'], maximum)
        for phrase in ('does not install or execute anything', 'Mac-local global policy',
                       'including after an earlier always-allow/always-deny result',
                       'final CAD replay must use bundled dependencies only'):
            self.assertIn(phrase, description)

    def test_instructions_require_current_permission_and_respect_denial(self):
        for phrase in ('call lad_request_permission', 'proceed only when allowed is true',
                       'each new proposed operation', 'Settings can change at any time',
                       'Saved chat, audit records and earlier-turn decisions are not current permission',
                       'do not rephrase or retry that same operation without new user direction',
                       'you execute approved installations yourself', "LAD's bundled dependencies only"):
            self.assertIn(phrase, INSTRUCTIONS)
        self.assertNotIn('never download or install tools or dependencies', INSTRUCTIONS)

    def test_permission_decisions_reach_agent_without_executing_described_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            control = root / '.lad-tools'
            requests, responses = control / 'requests', control / 'responses'
            requests.mkdir(parents=True)
            responses.mkdir()
            bridge = NativeBridge(root)
            marker = root / 'operation-must-not-run'
            arguments = {'operation': f'touch {marker}', 'reason': 'A permission-only transport check'}
            received = []
            payloads = []
            for allowed in (False, True):
                payloads.append({'allowed': allowed, 'source': 'policy',
                                 'rememberedPolicy': 'alwaysAllow' if allowed else 'alwaysDeny',
                                 'scope': 'task_workspace', 'workspace': str(root),
                                 'executionPerformed': False})

            def host():
                handled = set()
                deadline = time.monotonic() + 4
                while len(received) < 2 and time.monotonic() < deadline:
                    for pending in requests.glob('*.json'):
                        if pending.name in handled:
                            continue
                        handled.add(pending.name)
                        request = json.loads(pending.read_text())
                        received.append((request['name'], request['arguments']))
                        output = {'content': [{'type': 'text', 'text': json.dumps(payloads[len(received) - 1])}]}
                        temporary = responses / (request['id'] + '.tmp')
                        temporary.write_text(json.dumps(output))
                        temporary.replace(responses / (request['id'] + '.json'))
                    time.sleep(0.01)
                if len(received) != 2:
                    (control / 'closed').write_text('host ended')

            worker = threading.Thread(target=host)
            worker.start()
            try:
                with patch('agent_server.os.kill'):
                    for expected in payloads:
                        result = bridge.call('lad_request_permission', arguments)
                        self.assertNotIn('isError', result, 'Denial is a successful permission decision.')
                        self.assertEqual(json.loads(result['content'][0]['text']), expected)
                        self.assertFalse(marker.exists())
            finally:
                worker.join(timeout=5)
                os.close(bridge.request_fd)
                os.close(bridge.response_fd)
            self.assertFalse(worker.is_alive())
            self.assertEqual(received, [('lad_request_permission', arguments)] * 2)
            self.assertFalse(list(responses.iterdir()))


if __name__ == '__main__':
    unittest.main()
