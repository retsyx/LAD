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
# A rubber duck's bill: trimmed torus rims whose optimal bounds change once the
# solid is written as BREP and read again.
BILL = """import math
from OCP.gp import gp_Pnt, gp_Dir, gp_Ax1
from OCP.GC import GC_MakeArcOfCircle, GC_MakeSegment
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeWire, BRepBuilderAPI_MakeFace
from OCP.BRepPrimAPI import BRepPrimAPI_MakeRevol


def P(x, z):
    return gp_Pnt(x, 0.0, z)


def arc3(a, b, c):
    return BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(a, b, c).Value()).Edge()


def mid_on_circle(c, r, p, q):
    a1 = math.atan2(p[1] - c[1], p[0] - c[0])
    a2 = math.atan2(q[1] - c[1], q[0] - c[0])
    while a2 - a1 > math.pi:
        a2 -= 2 * math.pi
    while a1 - a2 > math.pi:
        a2 += 2 * math.pi
    am = 0.5 * (a1 + a2)
    return (c[0] + r * math.cos(am), c[1] + r * math.sin(am))


def domed_puck(d, rho, h0):
    Rs = (d * d + h0 * h0 - rho * rho) / (2 * (h0 - rho))
    cz = h0 - Rs
    n = math.hypot(d, -cz)
    tp = (Rs * d / n, cz + Rs * (-cz) / n)
    top_pole, bot_pole = (h0, 0.0), (-h0, 0.0)
    tp_, bp_ = (tp[1], tp[0]), (-tp[1], tp[0])
    wire = BRepBuilderAPI_MakeWire()
    for edge in (arc3(P(*top_pole), P(*mid_on_circle((cz, 0.0), Rs, top_pole, tp_)), P(*tp_)),
                 arc3(P(*tp_), P(0.0, d + rho), P(*bp_)),
                 arc3(P(*bp_), P(*mid_on_circle((-cz, 0.0), Rs, bp_, bot_pole)), P(*bot_pole)),
                 BRepBuilderAPI_MakeEdge(GC_MakeSegment(P(*bot_pole), P(*top_pole)).Value()).Edge()):
        wire.Add(edge)
    face = BRepBuilderAPI_MakeFace(wire.Wire(), True).Face()
    solid = cq.Shape.cast(BRepPrimAPI_MakeRevol(face, gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0)), 2 * math.pi).Shape())
    return solid.rotate((0, 0, 0), (0, 1, 0), -90).rotate((0, 0, 0), (0, 0, 1), 180)


head = cq.Solid.makeSphere(22, angleDegrees1=-90, angleDegrees2=90, angleDegrees3=360)
head = head.rotate((0, 0, 0), (1, 0, 0), -90).rotate((0, 0, 0), (0, 1, 0), -90).translate(cq.Vector(14, 0, 60))
upper = domed_puck(10.5, 2.6, 4.0).rotate((0, 0, 0), (0, 1, 0), 3).translate(cq.Vector(35.5, 0, 55.5))
lower = domed_puck(7.5, 2.0, 2.8).rotate((0, 0, 0), (0, 1, 0), 3).translate(cq.Vector(33.0, 0, 51.8))
result = upper.fuse(lower).cut(head).clean()
"""


class DeferredVerificationTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)

    def build(self, script, **options):
        build = self.folder / f"build-{len(list(self.folder.iterdir()))}"
        build.mkdir()
        (build / "request.json").write_text(json.dumps({"title": "Box", "summary": "A box", "units": "mm", "script": script}))
        return worker.run(build / "request.json", build / "output", 2, defer_step=True, **options)

    def verify(self, preview, parts=None):
        folder = Path(tempfile.mkdtemp(dir=self.folder))
        shutil.copyfile(preview["brepPath"], folder / "source.brep")
        if parts is None:
            parts = [{key: part[key] for key in ("volume", "area", "bounds", "centroid")}
                     for part in preview["topology"]["parts"]]
        (folder / "request.json").write_text(json.dumps({"operation": "verify", "brepAsset": "source.brep",
                                                          "nativeIdentity": preview["brepPath"], "validatedNative": True,
                                                          "expectedParts": parts}))
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

    def test_verification_compares_step_with_the_parts_the_build_measured(self):
        import cadquery as cq
        from OCP.BRep import BRep_Builder
        from OCP.BRepTools import BRepTools
        from OCP.TopoDS import TopoDS_Shape
        preview = self.build(BILL, verify_later=True)
        native = TopoDS_Shape()
        self.assertTrue(BRepTools.Read_s(native, preview["brepPath"], BRep_Builder()))
        reread = worker.exact_bounds(cq.Shape.cast(native))
        self.assertGreater(max(abs(a - b) for a, b in zip(reread, preview["bounds"])), 1e-3,
                           "The fixture must expose bounds that change after a BREP roundtrip.")
        self.assertTrue(self.verify(preview)["verified"])
        full = self.build(BILL)
        self.assertEqual(full["validatedHash"], preview["pendingValidationHash"])

    def test_verification_requires_the_builds_measurement_of_each_solid(self):
        preview = self.build(BOX, verify_later=True)
        part = {key: preview["topology"]["parts"][0][key] for key in ("volume", "area", "bounds", "centroid")}
        for parts in ([], [part, part], [dict(part, volume=float("nan"))], [dict(part, bounds=part["bounds"][:3])],
                      [dict(part, solidIndex=0)]):
            with self.assertRaisesRegex(worker.ModelError, "measurements"):
                self.verify(preview, parts)

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
