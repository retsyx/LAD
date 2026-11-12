"""The long-lived native worker serves only native operations and reuses solids."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker

ROOT = Path(__file__).resolve().parents[2]


def stage(folder, name, payload):
    directory = folder / name
    directory.mkdir()
    (directory / "request.json").write_text(json.dumps(payload))
    return directory


class NativeServingTests(unittest.TestCase):
    def test_serving_answers_native_requests_and_refuses_programs(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            runtime = stage(folder, "runtime", {"operation": "runtime"})
            program = stage(folder, "program", {"title": "Box", "summary": "Generated program", "units": "mm",
                                                "script": "result = cq.Solid.makeBox(1, 1, 1)"})
            mesh = stage(folder, "mesh", {"operation": "mesh_inspect"})
            lines = "".join(json.dumps({"id": index, "request": str(directory / "request.json"),
                                        "output": str(directory), "threads": 1}) + "\n"
                            for index, directory in enumerate([runtime, program, mesh], start=1))
            completed = subprocess.run([sys.executable, str(ROOT / "Engine" / "worker.py"), "--serve"], input=lines,
                                       capture_output=True, text=True, timeout=120)
            self.assertEqual(completed.returncode, 0)
            replies = [json.loads(line) for line in completed.stdout.splitlines()]
            self.assertEqual([reply["id"] for reply in replies], [1, 2, 3])
            self.assertEqual(replies[0]["status"], "complete")
            self.assertIn("runtime", json.loads((runtime / "result.json").read_text()))
            for reply, directory in zip(replies[1:], [program, mesh]):
                self.assertEqual(reply["status"], "error")
                self.assertIn("only native geometry operations", reply["message"])
                self.assertTrue((directory / "error.json").exists())
                self.assertFalse((directory / "result.json").exists(), "A refused request publishes no result.")

    def test_serving_reuses_a_solid_by_identity_and_trusts_validated_solids(self):
        import cadquery as cq
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            source = folder / "source.brep"
            worker.write_brep(cq.Workplane().box(2, 3, 4).val(), source)
            spec = {"brepAsset": "source.brep", "nativeIdentity": "/session/build/model.brep", "validatedNative": True}
            with mock.patch.object(worker, "_serving", True), mock.patch.dict(worker._native_shapes, clear=True), \
                    mock.patch.object(worker, "validate_shape", side_effect=AssertionError("validated solids are not rechecked")):
                first = worker.read_brep(spec, folder, cq, 1)
                source.unlink()
                self.assertIs(worker.read_brep(spec, folder, cq, 1), first, "A repeated identity reuses the parsed solid.")
            # Without the validated marker, a staged solid is validated again,
            # and one-shot processes never cache.
            worker.write_brep(cq.Workplane().box(2, 3, 4).val(), source)
            with mock.patch.object(worker, "validate_shape", wraps=worker.validate_shape) as validate, \
                    mock.patch.dict(worker._native_shapes, clear=True):
                worker.read_brep({"brepAsset": "source.brep", "nativeIdentity": "/session/other/model.brep"}, folder, cq, 1)
                self.assertEqual(validate.call_count, 1)
                self.assertEqual(worker._native_shapes, {})


if __name__ == "__main__":
    unittest.main()
