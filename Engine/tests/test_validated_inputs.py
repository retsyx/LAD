"""Validated input copies skip repeated imports without changing what programs receive."""
import json
import math
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import cadquery as cq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker

ASSET = {"id": "asset-a", "name": "a.step", "format": "step", "path": "input-000.step"}
COMBINED = "result = cq.Compound.makeCompound([imported_model, imported_assets['asset-a']])"


def spec(script, source_copy=False, asset_copy=False):
    asset = dict(ASSET, validatedBREP="input-000.validated.brep") if asset_copy else dict(ASSET)
    value = {"title": "Inputs", "summary": "Imported geometry.", "units": "mm", "script": script,
             "sourceAsset": "source.step", "inputAssets": [asset]}
    if source_copy:
        value["sourceValidatedBREP"] = "source.validated.brep"
    return value


class ValidatedInputCopyTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        worker.write_step([cq.Solid.makeBox(2, 3, 4).translate((5, 0, 0))], self.folder / "input-000.step", cq)
        worker.write_step([cq.Solid.makeCylinder(1, 2)], self.folder / "source.step", cq)

    def copy(self, name):
        return self.folder / f"{name}{worker.VALIDATED_COPY_SUFFIX}"

    def test_new_inputs_are_copied_before_the_program_runs(self):
        program = "imported_assets['asset-a'].move(cq.Location((100, 0, 0)))\nresult = imported_assets['asset-a']"
        moved = worker.build_shape(spec(program), 1, self.folder, validated_copies=self.folder)
        self.assertAlmostEqual(moved.BoundingBox().xmin, 105, places=6)
        copy = worker.read_validated_copy(self.copy("input-000"), cq)
        self.assertAlmostEqual(copy.BoundingBox().xmin, 5, places=6,
                               msg="A copy holds the validated input, never the program's changes.")
        self.assertAlmostEqual(copy.Volume(), 24, places=6)
        self.assertAlmostEqual(worker.read_validated_copy(self.copy("source"), cq).Volume(), 2 * math.pi, places=6)

    def test_staged_copies_replace_import_and_validation(self):
        original = worker.build_shape(spec(COMBINED), 1, self.folder, validated_copies=self.folder)
        written = {name: self.copy(name).stat().st_ino for name in ("source", "input-000")}
        with (mock.patch.object(worker, "import_step", side_effect=AssertionError("STEP imported again")),
              mock.patch.object(worker, "import_input_asset", side_effect=AssertionError("Input imported again"))):
            replay = worker.build_shape(spec(COMBINED, source_copy=True, asset_copy=True), 1, self.folder,
                                        validated_copies=self.folder)
        self.assertEqual({name: self.copy(name).stat().st_ino for name in written}, written,
                         "A staged copy is read, not rewritten.")
        self.assertAlmostEqual(replay.Volume(), original.Volume(), places=9)
        self.assertEqual([round(value, 9) for value in worker.exact_bounds(replay)],
                         [round(value, 9) for value in worker.exact_bounds(original)])
        self.assertEqual(len(worker._shape_entities(replay, "Face")), len(worker._shape_entities(original, "Face")))

    def test_unreadable_copy_falls_back_to_the_original_input(self):
        self.copy("input-000").write_bytes(b"DBRep_DrawableShape\nnot a shape")
        shape = worker.build_shape(spec("result = imported_assets['asset-a']", asset_copy=True), 1, self.folder,
                                   validated_copies=self.folder)
        self.assertAlmostEqual(shape.Volume(), 24, places=6)

    def test_copy_names_must_match_their_inputs(self):
        wrong = spec(COMBINED)
        wrong["inputAssets"][0]["validatedBREP"] = "input-001.validated.brep"
        unowned = spec(COMBINED, source_copy=True)
        del unowned["sourceAsset"]
        renamed = spec(COMBINED)
        renamed["sourceValidatedBREP"] = "other.validated.brep"
        for value in (wrong, unowned, renamed):
            with self.assertRaises(worker.ModelError):
                worker.validate_spec(value)
        worker.validate_spec(spec(COMBINED, source_copy=True, asset_copy=True))

    def test_only_the_importing_build_validates_inputs(self):
        original = worker.validate_shape
        validated = []

        def counting(shape, *args, **kwargs):
            validated.append(shape)
            return original(shape, *args, **kwargs)

        with mock.patch.object(worker, "validate_shape", side_effect=counting):
            worker.build_shape(spec(COMBINED), 1, self.folder)
        self.assertEqual(len(validated), 1, "A design's saved inputs are trusted; only the result is validated.")
        validated.clear()
        with mock.patch.object(worker, "validate_shape", side_effect=counting):
            worker.build_shape({**spec(COMBINED), "validateInputs": True}, 1, self.folder)
        self.assertEqual(len(validated), 3, "Importing validates the source STEP, the input and the result.")

    def test_trusted_inputs_reach_programs_exactly_as_validated_inputs(self):
        from OCP.ShapeAnalysis import ShapeAnalysis_ShapeTolerance
        from OCP.TopAbs import TopAbs_EDGE
        for name, value in (("trusted", spec(COMBINED)), ("validated", {**spec(COMBINED), "validateInputs": True})):
            (self.folder / name).mkdir()
            worker.build_shape(value, 1, self.folder, validated_copies=self.folder / name)
        for stem in ("source", "input-000"):
            trusted = self.folder / "trusted" / f"{stem}{worker.VALIDATED_COPY_SUFFIX}"
            self.assertEqual(trusted.read_bytes(),
                             (self.folder / "validated" / f"{stem}{worker.VALIDATED_COPY_SUFFIX}").read_bytes())
            shape = worker.read_validated_copy(trusted, cq)
            self.assertGreaterEqual(ShapeAnalysis_ShapeTolerance().Tolerance(shape.wrapped, -1, TopAbs_EDGE),
                                    worker.GEOMETRY_TOLERANCE_MM * (1 - 1e-9),
                                    "Trusted inputs keep validation's boundary tolerance.")

    def test_importing_builds_validate_instead_of_reading_staged_copies(self):
        worker.build_shape(spec(COMBINED), 1, self.folder, validated_copies=self.folder)
        with mock.patch.object(worker, "read_validated_copy", side_effect=AssertionError("Staged copy read")):
            shape = worker.build_shape({**spec(COMBINED, source_copy=True, asset_copy=True), "validateInputs": True},
                                       1, self.folder)
        self.assertAlmostEqual(shape.Volume(), 24 + 2 * math.pi, places=6)

    def test_input_validation_option_must_be_true_when_present(self):
        worker.validate_spec({**spec(COMBINED), "validateInputs": True})
        for value in (False, 1, "true"):
            with self.assertRaises(worker.ModelError):
                worker.validate_spec({**spec(COMBINED), "validateInputs": value})

    def test_build_requests_keep_copies_in_their_output_folder(self):
        (self.folder / "request.json").write_text(json.dumps(spec(COMBINED)))
        output = self.folder / "output"
        worker.run(self.folder / "request.json", output, 1, defer_step=True)
        for name in ("source", "input-000"):
            self.assertTrue(worker.read_validated_copy(output / f"{name}{worker.VALIDATED_COPY_SUFFIX}", cq).Solids())


if __name__ == "__main__":
    unittest.main()
