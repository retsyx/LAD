"""Exercise optional recognition through the real immutable worker boundary."""
import copy
import math
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_mesh_tools import WorkerCalls


def torus_mesh():
    center = [2., -3., 4.]
    nu, nv = 40, 16
    vertices = []
    for i in range(nu):
        u = 2 * math.pi * i / nu
        for j in range(nv):
            v = 2 * math.pi * j / nv
            radius = 1.5 + .25 * math.cos(v)
            vertices.append([center[0] + radius * math.cos(u),
                             center[1] + radius * math.sin(u),
                             center[2] + .25 * math.sin(v)])
    triangles = []
    for i in range(nu):
        for j in range(nv):
            a, b = i * nv + j, ((i + 1) % nu) * nv + j
            c, d = ((i + 1) % nu) * nv + (j + 1) % nv, i * nv + (j + 1) % nv
            triangles.extend([[a, b, c], [a, c, d]])
    return {"vertices": vertices, "triangles": triangles}


class RecognitionWorkflowTests(unittest.TestCase):
    def test_inch_reference_recognition_fit_edit_and_final_source_comparison(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = WorkerCalls(directory)
            _, opened, _ = calls.call(
                "open_reference", options={"units": "in", "max_deviation": .03},
                sourceAsset=torus_mesh(), policyAsset={"reference_interpretation": {
                    "material": "oriented_closed_boundary", "nesting": "single_component"}})
            self.assertEqual(opened["status"], "ok", opened)
            context, revision = opened["payload"]["context"], opened["payload"]["revision"]
            original = copy.deepcopy(context)
            _, inspected, _ = calls.call(
                "inspect", contextAsset=context, revisionAsset=revision,
                queryAsset={"kind": "recognize", "scope": "all", "families": ["torus"]})
            self.assertIn(inspected["status"], ["ok", "partial"], inspected)
            self.assertTrue(inspected["payload"]["recognition_records"], inspected["diagnostics"])
            metadata, fitted, _ = calls.call(
                "fit", options={"families": ["torus"]}, contextAsset=context,
                revisionAsset=revision, evidenceAsset=[inspected["payload"]])
            self.assertTrue(fitted["payload"], fitted["diagnostics"])
            self.assertNotIn("script", metadata)
            candidate = fitted["payload"][0]
            member = candidate["members"][0]
            self.assertAlmostEqual(member["geometry"]["major_radius"], 38.1, delta=.01)
            self.assertAlmostEqual(member["geometry"]["minor_radius"], 6.35, delta=.01)
            for actual, expected in zip(member["geometry"]["center"], [50.8, -76.2, 101.6]):
                self.assertAlmostEqual(actual, expected, delta=.01)
            _, edited, folder = calls.call(
                "try_edit", contextAsset=context, revisionAsset=revision, fitsAsset=[candidate],
                editAsset={"kind": "body", "operation": "create", "target_body": "ring",
                           "tool": {"fit_candidate": candidate["id"], "member_id": member["id"],
                                    "extent": {"mode": "full"}}})
            self.assertTrue(edited["payload"]["commit_eligible"], edited["diagnostics"])
            self.assertNotIn("imported_assets", edited["payload"]["script"])
            self.assertEqual(edited["payload"]["quick_comparison"]["after"]["acceptance"], "not_evaluated")
            _, compared, _ = calls.call(
                "compare", options={"scope": "all", "quality": "final"}, contextAsset=context,
                revisionAsset=edited["payload"], brepAsset=(folder / "model.brep").read_bytes())
            self.assertEqual(compared["payload"]["acceptance"], "pass", {
                key: compared["payload"].get(key) for key in
                ("validity_checks", "representation_checks", "feature_checks", "limitations")})
            self.assertTrue(compared["payload"]["scope_completed"]["whole_continuous_cover"])
            self.assertEqual(context, original)


if __name__ == "__main__":
    unittest.main()
