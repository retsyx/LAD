"""The worker publishes display arrays as packed binary sections."""
from array import array
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import ModelError, write_preview_result


class PreviewResultTests(unittest.TestCase):
    def read(self, folder):
        result = json.loads((folder / "result.json").read_text())
        data = (folder / "mesh.bin").read_bytes() if (folder / "mesh.bin").exists() else b""

        def section(name, code):
            spec = result["meshBuffers"]["sections"][name]
            values = array(code)
            values.frombytes(data[spec["offset"]:spec["offset"] + spec["count"] * 4])
            return values.tolist()
        return result, section

    def test_moves_display_arrays_into_packed_sections(self):
        preview = {"vertices": [[0, 0, 0], [1, 0, 0], [0, 1, 0]], "normals": [[0, 0, 1]] * 3,
                   "triangles": [[0, 1, 2]], "edges": [[0, 0, 0, 1, 0, 0]], "triangleSolids": [0],
                   "triangleFaces": [0], "edgeSolids": [0], "edgeFeatures": [0], "solids": 1, "bounds": [0, 0, 0, 1, 1, 0]}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            write_preview_result(preview, folder)
            result, section = self.read(folder)
            for key in ("vertices", "normals", "triangles", "edges", "triangleSolids", "triangleFaces", "edgeSolids", "edgeFeatures"):
                self.assertNotIn(key, result)
            self.assertEqual(result["solids"], 1)
            self.assertEqual(result["meshBuffers"]["path"], "mesh.bin")
            self.assertEqual(section("positions", "f"), [0, 0, 0, 1, 0, 0, 0, 1, 0])
            self.assertEqual(section("normals", "f"), [0, 0, 1] * 3)
            self.assertEqual(section("triangles", "I"), [0, 1, 2])
            self.assertEqual(section("edges", "f"), [0, 0, 0, 1, 0, 0])
            self.assertEqual(section("triangleSolids", "i"), [0])
            self.assertEqual(section("edgeFeatures", "i"), [0])
            self.assertFalse((folder / "mesh.bin.tmp").exists())
            self.assertIn("vertices", preview, "The caller's preview is not modified.")

    def test_results_without_display_arrays_write_only_json(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            write_preview_result({"solids": 0}, folder)
            self.assertEqual(json.loads((folder / "result.json").read_text()), {"solids": 0})
            self.assertFalse((folder / "mesh.bin").exists())
            self.assertFalse((folder / "mesh.bin.tmp").exists())

    def test_rejects_rows_with_the_wrong_width(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with self.assertRaises(ModelError):
                write_preview_result({"vertices": [[0, 0, 0], [1, 0]]}, folder)
            self.assertEqual(list(folder.iterdir()), [], "A malformed preview publishes nothing.")


if __name__ == "__main__":
    unittest.main()
