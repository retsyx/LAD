"""Discovery and transparent transport of preset/custom render cameras."""
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
from agent_server import NativeBridge, TOOLS


class RenderCameraMCPTests(unittest.TestCase):
    def test_discovery_retains_presets_and_describes_optional_camera_controls(self):
        _, description, schema, read_only = next(tool for tool in TOOLS if tool[0] == 'lad_render')
        properties = schema['properties']
        self.assertEqual(properties['view']['enum'], ['isometric', 'front', 'back', 'top', 'bottom', 'left', 'right'])
        self.assertEqual(schema['required'], [])
        self.assertFalse(schema['additionalProperties'])
        self.assertTrue(read_only)
        self.assertIn('without changing the user', description)
        self.assertIn('Do not combine cameraPosition', description)
        for angle in ('yawDegrees', 'elevationDegrees', 'rollDegrees'):
            self.assertEqual(properties[angle]['type'], 'number')
        self.assertEqual(properties['elevationDegrees']['minimum'], -90)
        self.assertEqual(properties['elevationDegrees']['maximum'], 90)
        self.assertIn('counterclockwise', properties['rollDegrees']['description'])
        for point in ('cameraPosition', 'cameraTarget'):
            self.assertEqual(properties[point]['type'], 'array')
            self.assertEqual(properties[point]['minItems'], 3)
            self.assertEqual(properties[point]['maxItems'], 3)
            self.assertEqual(properties[point]['items'], {'type': 'number', 'minimum': -1000000, 'maximum': 1000000})
        self.assertEqual(properties['zoom']['default'], 1)
        self.assertGreater(properties['zoom']['minimum'], 0)
        self.assertIn('divide', properties['zoom']['description'])
        self.assertIn('orthographic zoom keeps the eye unchanged', properties['zoom']['description'])
        self.assertIn('orthographic zoom retains this eye position', properties['cameraPosition']['description'])
        self.assertIn('orthographic zoom keeps the eye position unchanged', description)
        self.assertEqual(properties['projection']['enum'], ['perspective', 'isometric'])
        self.assertEqual(properties['jointPositions']['type'], 'object')
        self.assertEqual(properties['jointPositions']['maxProperties'], 256)
        self.assertEqual(properties['jointPositions']['additionalProperties']['type'], 'number')
        self.assertIn('render only', properties['jointPositions']['description'])
        self.assertEqual(properties['drivingJoint']['type'], 'string')
        self.assertIn('passive joints', properties['drivingJoint']['description'])

    def test_custom_angle_and_position_requests_reach_the_native_host_unchanged(self):
        requests_to_send = [
            {'artifactID': 'candidate', 'view': 'front', 'yawDegrees': 23.75, 'elevationDegrees': -12.5,
             'rollDegrees': 31, 'cameraTarget': [12, -3, 8], 'zoom': 1.75, 'projection': 'perspective',
             'display': 'edges', 'width': 800, 'height': 600, 'solidIndices': [1, 4],
             'jointPositions': {'hinge': 35.5, 'slide': 12}, 'drivingJoint': 'hinge'},
            {'artifactID': 'candidate', 'cameraPosition': [80.5, -24, 41], 'cameraTarget': [12, -3, 8],
             'rollDegrees': -10, 'zoom': 0.5, 'projection': 'isometric'},
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
                        payload = {'content': [{'type': 'text', 'text': json.dumps({'camera': request['arguments']})}]}
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
                    for arguments in requests_to_send:
                        result = native.call('lad_render', arguments)
                        self.assertEqual(json.loads(result['content'][0]['text'])['camera'], arguments)
            finally:
                worker.join(timeout=5)
                os.close(native.request_fd)
                os.close(native.response_fd)
            self.assertFalse(worker.is_alive())
            self.assertEqual([request['name'] for request in received], ['lad_render', 'lad_render'])
            self.assertEqual([request['arguments'] for request in received], requests_to_send)
            self.assertFalse(list(responses.iterdir()))


if __name__ == '__main__':
    unittest.main()
