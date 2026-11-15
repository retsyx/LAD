"""A preview may display before exact checks and STEP verification, never be accepted before them."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import OCP.BRepCheck as BRepCheck

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker
from test_candidate_validation import displaced_pcurve_program

BOX = "result = cq.Solid.makeBox(2, 3, 4)"


class DeferredVerificationTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)

    def build(self, script, **options):
        build = self.folder / f"build-{len(list(self.folder.iterdir()))}"
        build.mkdir()
        (build / "request.json").write_text(json.dumps({"title": "Box", "summary": "A box", "units": "mm", "script": script}))
        return worker.run(build / "request.json", build / "output", 2, defer_step=True, **options)

    def verify(self, preview):
        folder = Path(tempfile.mkdtemp(dir=self.folder))
        shutil.copyfile(preview["brepPath"], folder / "source.brep")
        (folder / "request.json").write_text(json.dumps({"operation": "verify", "brepAsset": "source.brep",
                                                          "nativeIdentity": preview["brepPath"], "validatedNative": True}))
        return worker.run(folder / "request.json", folder / "output", 2, native_only=True)

    def test_deferred_build_publishes_a_pending_receipt_without_exact_checks_or_step(self):
        with (mock.patch.object(BRepCheck, "BRepCheck_Analyzer", side_effect=AssertionError("Exact check before display")),
              mock.patch.object(worker, "write_step", side_effect=AssertionError("STEP before display"))):
            preview = self.build(BOX, verify_later=True)
        self.assertNotIn("validatedHash", preview)
        self.assertEqual(len(preview["pendingValidationHash"]), 64)
        self.assertTrue(Path(preview["brepPath"]).is_file())
        self.assertEqual(preview["faces"], 6)

    def test_verification_runs_the_deferred_checks_on_the_native_solid(self):
        preview = self.build(BOX, verify_later=True)
        original = self.build(BOX)
        self.assertEqual(preview["pendingValidationHash"], original["validatedHash"],
                         "A verified deferred build earns the same receipt as a fully checked build.")
        analyzer, roundtrip = BRepCheck.BRepCheck_Analyzer, worker.validate_step_roundtrip
        with (mock.patch.object(BRepCheck, "BRepCheck_Analyzer", side_effect=analyzer) as exact,
              mock.patch.object(worker, "validate_step_roundtrip", side_effect=roundtrip) as step):
            self.assertTrue(self.verify(preview)["verified"])
        self.assertEqual(exact.call_count, 2, "The native solid and its STEP readback, as in a fully checked build.")
        self.assertEqual(step.call_count, 1)

    def test_verification_rejects_an_exact_validation_defect_the_preview_displayed(self):
        preview = self.build(displaced_pcurve_program(1e-3), verify_later=True)
        with self.assertRaises(worker.ModelError) as caught:
            self.verify(preview)
        self.assertTrue(any(failure["entity"]["kind"] == "edge" for failure in caught.exception.diagnostic["failures"]))

    def test_verification_rejects_a_lossy_step_export(self):
        preview = self.build(BOX, verify_later=True)
        original = worker.write_step

        def moved(solids, path, cq, colors=None, indices=None):
            return original([solid.translate((5, 0, 0)) for solid in solids], path, cq, colors=colors, indices=indices)

        with mock.patch.object(worker, "write_step", side_effect=moved):
            with self.assertRaisesRegex(worker.ModelError, "STEP verification"):
                self.verify(preview)

    def test_matching_receipt_needs_no_verification(self):
        receipt = self.build(BOX)["validatedHash"]
        preview = self.build(BOX, verify_later=True, validated_hash=receipt)
        self.assertEqual(preview["validatedHash"], receipt)
        self.assertNotIn("pendingValidationHash", preview)

    def test_display_failure_reports_the_exact_defect_it_deferred(self):
        failure = worker.ModelError("OpenCascade could not produce a complete design preview (part 1).")
        with mock.patch.object(worker, "make_preview", side_effect=failure):
            with self.assertRaises(worker.ModelError) as invalid:
                self.build(displaced_pcurve_program(1e-3), verify_later=True)
            with self.assertRaises(worker.ModelError) as valid:
                self.build(BOX, verify_later=True)
        self.assertIn("failures", invalid.exception.diagnostic)
        self.assertIs(valid.exception, failure)

    def test_verification_accepts_only_a_native_solid(self):
        preview = self.build(BOX, verify_later=True)
        folder = Path(tempfile.mkdtemp(dir=self.folder))
        shutil.copyfile(preview["brepPath"], folder / "source.brep")
        (folder / "request.json").write_text(json.dumps({"operation": "verify", "brepAsset": "source.brep",
                                                          "script": BOX}))
        with self.assertRaises(worker.ModelError):
            worker.run(folder / "request.json", folder / "output", 2, native_only=True)


if __name__ == "__main__":
    unittest.main()
