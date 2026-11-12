"""A pending native tool call ends when the task closes or the agent exits."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE))
from agent_server import NativeBridge


def bridge_folder(root):
    control = root / '.lad-tools'
    (control / 'requests').mkdir(parents=True)
    (control / 'responses').mkdir()
    return control


def wait_for_request(control, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any((control / 'requests').glob('*.json')):
            return True
        time.sleep(0.01)
    return False


class BridgeWaitTests(unittest.TestCase):
    def test_closed_marker_ends_a_pending_call(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            control = bridge_folder(root)
            bridge = NativeBridge(root)

            def close():
                if wait_for_request(control):
                    (control / 'closed').write_text('host ended')

            closer = threading.Thread(target=close)
            closer.start()
            try:
                with self.assertRaisesRegex(ValueError, 'task has stopped'):
                    bridge.call('lad_runtime', {})
            finally:
                closer.join()

    def test_agent_exit_ends_a_pending_call(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            control = bridge_folder(root)
            outcome = root / 'outcome.json'
            adapter = textwrap.dedent(f'''
                import json, os, sys
                sys.path.insert(0, {str(ENGINE)!r})
                from agent_server import NativeBridge
                try:
                    NativeBridge({str(root)!r}).call('lad_runtime', {{}})
                    message = 'returned'
                except ValueError as error:
                    message = str(error)
                with open({str(outcome) + '.tmp'!r}, 'w') as stream:
                    stream.write(json.dumps(message))
                os.replace({str(outcome) + '.tmp'!r}, {str(outcome)!r})
            ''')
            # The agent launches the adapter and exits while its call is pending.
            agent = textwrap.dedent(f'''
                import pathlib, subprocess, sys, time
                subprocess.Popen([sys.executable, '-c', {adapter!r}])
                requests = pathlib.Path({str(control / 'requests')!r})
                deadline = time.monotonic() + 20
                while not any(requests.glob('*.json')) and time.monotonic() < deadline:
                    time.sleep(0.01)
            ''')
            subprocess.run([sys.executable, '-c', agent], check=True, timeout=60)
            deadline = time.monotonic() + 30
            while not outcome.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(outcome.exists(), 'The adapter kept waiting after the agent exited.')
            self.assertIn('agent task has stopped', json.loads(outcome.read_text()))


if __name__ == '__main__':
    unittest.main()
