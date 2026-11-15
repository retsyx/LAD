"""A build worker started ahead of its request runs exactly that one build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

WORKER = Path(__file__).resolve().parents[1] / "worker.py"
BOX = {"title": "Box", "summary": "A box", "units": "mm", "script": "result = cq.Solid.makeBox(2, 3, 4)"}


class AwaitBuildTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.start = self.folder / "start"
        os.mkfifo(self.start, 0o600)

    def launch(self):
        process = subprocess.Popen([sys.executable, str(WORKER), "--await-build", str(self.start), "--output", str(self.folder)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env={**os.environ, "MPLCONFIGDIR": str(self.folder / ".matplotlib")})
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def send(self, options):
        with open(self.start, "w") as stream:
            json.dump(options, stream)

    def test_waits_for_its_options_then_runs_the_staged_build(self):
        process = self.launch()
        time.sleep(0.5)
        self.assertIsNone(process.poll(), "The worker waits for its build.")
        (self.folder / "request.json").write_text(json.dumps(BOX))
        self.send({"threads": 2, "deferStep": True, "verifyLater": True})
        _, errors = process.communicate(timeout=120)
        self.assertEqual(process.returncode, 0, errors)
        result = json.loads((self.folder / "result.json").read_text())
        self.assertEqual(result["solids"], 1)
        self.assertEqual(len(result["pendingValidationHash"]), 64)
        self.assertTrue((self.folder / "model.brep").is_file())

    def test_invalid_options_run_no_program(self):
        process = self.launch()
        (self.folder / "request.json").write_text(json.dumps(BOX))
        self.send({"threads": "2", "deferStep": True})
        process.communicate(timeout=120)
        self.assertEqual(process.returncode, 1)
        self.assertIn("options are invalid", json.loads((self.folder / "error.json").read_text())["message"])
        self.assertFalse((self.folder / "result.json").exists())

    def test_waiting_worker_exits_once_its_parent_has(self):
        launcher = subprocess.run(["/bin/sh", "-c", f'"{sys.executable}" "{WORKER}" --await-build "{self.start}" '
                                   f'--output "{self.folder}" >/dev/null 2>&1 & echo $!'],
                                  capture_output=True, text=True, check=True)
        pid = int(launcher.stdout.strip())
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.2)
        os.kill(pid, 9)
        self.fail("A waiting worker must not outlive LAD.")


if __name__ == "__main__":
    unittest.main()
