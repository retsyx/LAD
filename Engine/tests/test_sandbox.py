"""Opt-in macOS sandbox integration: run outside another sandbox.

LAD_RUN_SANDBOX_TESTS=1 .venv/bin/python -m unittest discover -s Engine/tests -v
"""
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == "Darwin" and os.environ.get("LAD_RUN_SANDBOX_TESTS") == "1",
                     "Requires macOS and LAD_RUN_SANDBOX_TESTS=1 outside an enclosing sandbox")
class SandboxTests(unittest.TestCase):
    def build(self, source, private_contents="private test data"):
        with tempfile.TemporaryDirectory(prefix="LAD-sandbox-test-") as directory:
            folder = Path(directory).resolve()
            output = folder / "output"
            output.mkdir()
            private = folder / "private.txt"
            private.write_text(private_contents)
            source = source.replace("PRIVATE_FIXTURE", repr(str(private))).replace("OUTSIDE_DESTINATION", repr(str(folder / "forbidden.txt")))
            request = output / "request.json"
            request.write_text(json.dumps({"title": "Sandbox test", "summary": "Native sandbox integration", "units": "mm",
                                           "script": source}))
            runtime = Path(sys.executable).absolute()
            resolved = runtime.resolve()
            framework = resolved.parent.parent / "Resources/Python.app/Contents/MacOS/Python"
            interpreter = framework if framework.is_file() else resolved
            parameters = {"RUNTIME": str(runtime.parent.parent.resolve()), "PYTHON_BASE": str(resolved.parent.parent),
                          "WORKER": str(ROOT / "Engine"), "OUTPUT": str(output),
                          "PYTHON": str(interpreter), "ENTRY_PYTHON": str(runtime)}
            command = ["/usr/bin/sandbox-exec"]
            for key, value in parameters.items():
                command += ["-D", f"{key}={value}"]
            command += ["-f", str(ROOT / "Engine/script.sb"), str(interpreter), str(ROOT / "Engine/worker.py"),
                        "--request", str(request), "--output", str(output), "--threads", "2"]
            environment = {"PATH": "/usr/bin:/bin", "HOME": str(Path.home()), "LANG": "en_US.UTF-8", "LC_ALL": "C",
                           "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "LAD_MODEL_OUTPUT": str(output),
                           "MPLCONFIGDIR": str(output / ".matplotlib"), "XDG_CACHE_HOME": str(output / ".cache"), "TMPDIR": str(output)}
            if interpreter != resolved:
                environment["__PYVENV_LAUNCHER__"] = str(runtime)
            process = subprocess.run(command, cwd=output, env=environment, capture_output=True, text=True, timeout=180)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(private.read_text(), private_contents)
            self.assertFalse((folder / "forbidden.txt").exists())
            return json.loads((output / "result.json").read_text())

    def test_native_text_font_initialization_and_step(self):
        preview = self.build("result = cq.Workplane('XY').text('LAD', 10, 1, combine=False)")
        self.assertGreater(preview["volume"], 1)
        self.assertGreaterEqual(preview["solids"], 3)

    def test_private_reads_writes_network_and_subprocesses_are_denied(self):
        source = """
from pathlib import Path
import socket
import subprocess
import errno
import os
assert 'OPENAI_API_KEY' not in os.environ and 'CODEX_API_KEY' not in os.environ
for action in [lambda: Path(PRIVATE_FIXTURE).read_text(),
               lambda: Path(OUTSIDE_DESTINATION).write_text('forbidden')]:
    try:
        action()
    except PermissionError:
        pass
    else:
        raise AssertionError('Sandbox allowed access outside the model folder')
try:
    with socket.socket() as connection:
        connection.connect(('127.0.0.1',9))
except OSError as error:
    assert error.errno in (errno.EPERM, errno.EACCES), error
else:
    raise AssertionError('Sandbox allowed networking')
try:
    subprocess.run(['/bin/echo','forbidden'], check=True)
except PermissionError:
    pass
else:
    raise AssertionError('Sandbox allowed subprocess execution')
result = cq.Workplane('XY').box(4,5,6)
"""
        preview = self.build(source)
        self.assertAlmostEqual(preview["volume"], 120)


if __name__ == "__main__":
    unittest.main()
