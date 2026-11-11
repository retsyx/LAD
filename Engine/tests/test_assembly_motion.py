"""Moving assembly definitions and exact posed native geometry operations."""
import copy
import hashlib
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import (ModelError, build_shape, exact_bounds, make_preview, posed_solids,
                    run, validate_assembly_motion, write_brep)


def connector(identity, part, origin=(0, 0, 0)):
    return {"id": identity, "part": part, "origin": list(origin),
            "xAxis": [1, 0, 0], "zAxis": [0, 0, 1]}


def definition():
    return {"grounded": ["base"],
            "connectors": [connector("base-pin", "base", (5, 0, 0)),
                           connector("arm-pin", "arm", (25, 0, 0))],
            "joints": [{"id": "hinge", "name": "Arm hinge", "type": "revolute",
                        "parent": "base-pin", "child": "arm-pin", "limits": [-90, 90]}]}


def physical_parts():
    return [{"id": "group", "name": "Mechanism", "solidIndices": [], "children": [
        {"id": "base", "name": "Base", "solidIndices": [0], "children": None},
        {"id": "arm", "name": "Arm", "solidIndices": [1], "children": None},
        {"id": "link", "name": "Link", "solidIndices": [2], "children": None}]}]


def script_spec(script):
    return {"title": "Moving assembly", "summary": "Exact rigid assembly", "units": "mm", "script": script}


def rotation_y(angle, translation=(0, 0, 0)):
    cosine, sine = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    x, y, z = translation
    return [cosine, 0, sine, x, 0, 1, 0, y, -sine, 0, cosine, z, 0, 0, 0, 1]


class AssemblyDefinitionTests(unittest.TestCase):
    def test_build_emits_detached_world_frames_without_changing_built_geometry(self):
        motion = definition()
        script = f"""
motion = {motion!r}
result = cq.Assembly(name='Mechanism', loc=cq.Location((5,0,0)), metadata={{'lad_motion':motion}})
result.add(cq.Solid.makeBox(1,2,3), name='Base', metadata={{'lad_id':'base'}})
result.add(cq.Solid.makeBox(2,3,4), name='Arm', loc=cq.Location((20,0,0)), metadata={{'lad_id':'arm'}})
"""
        shape = build_shape(script_spec(script))
        preview = make_preview(shape)
        self.assertEqual(preview["assemblyMotion"]["grounded"], ["base"])
        self.assertEqual(preview["assemblyMotion"]["connectors"], motion["connectors"])
        self.assertEqual(preview["assemblyMotion"]["joints"][0]["position"], 0)
        self.assertEqual(preview["bounds"], [5, 0, 0, 27, 3, 4])
        self.assertEqual([part["solidIndices"] for part in preview["parts"][0]["children"]], [[0], [1]])
        plain = make_preview(build_shape(script_spec("result = cq.Solid.makeBox(1,2,3)")))
        self.assertNotIn("assemblyMotion", plain)

    def test_closed_loop_and_multiple_grounded_parts_are_retained_for_native_solver(self):
        motion = definition()
        motion["grounded"].append("arm")
        motion["connectors"].append(connector("link-pin", "link"))
        motion["joints"] += [
            {"id": "slider", "type": "slider", "parent": "arm-pin", "child": "link-pin", "position": 3},
            {"id": "closure", "type": "fixed", "parent": "link-pin", "child": "base-pin"}]
        actual = validate_assembly_motion(motion, physical_parts())
        self.assertEqual(len(actual["joints"]), 3)
        self.assertEqual(actual["joints"][1]["name"], "slider")
        motion["connectors"][0]["origin"][0] = 900
        self.assertEqual(actual["connectors"][0]["origin"][0], 5)

    def test_small_axis_roundoff_is_normalized_to_orthonormal_frames(self):
        motion = definition()
        motion["connectors"][0]["xAxis"] = [1.0000001, 0, 0.0000001]
        motion["connectors"][0]["zAxis"] = [0, 0, 0.9999999]
        frame = validate_assembly_motion(motion, physical_parts())["connectors"][0]
        self.assertEqual(frame["xAxis"], [1, 0, 0])
        self.assertEqual(frame["zAxis"], [0, 0, 1])

    def test_omitted_connector_axes_use_world_x_and_z(self):
        motion = definition()
        del motion["connectors"][1]["xAxis"]
        del motion["connectors"][1]["zAxis"]
        frame = validate_assembly_motion(motion, physical_parts())["connectors"][1]
        self.assertEqual(frame["xAxis"], [1, 0, 0])
        self.assertEqual(frame["zAxis"], [0, 0, 1])

    def test_invalid_frames_references_limits_and_ungrounded_components_fail(self):
        invalid = []

        def changed(change):
            value = definition()
            change(value)
            invalid.append(value)

        changed(lambda value: value.update(grounded=[]))
        changed(lambda value: value.update(grounded=["group"]))
        changed(lambda value: value.update(grounded=["base", "base"]))
        changed(lambda value: value["connectors"][1].update(id="base-pin"))
        changed(lambda value: value["connectors"][1].update(part="missing"))
        changed(lambda value: value["connectors"][1].update(part="group"))
        changed(lambda value: value["connectors"][1].update(origin=[0, float("nan"), 0]))
        changed(lambda value: value["connectors"][1].update(xAxis=[2, 0, 0]))
        changed(lambda value: value["connectors"][1].update(zAxis=[1, 0, 0]))
        changed(lambda value: value["joints"][0].update(parent="missing"))
        changed(lambda value: value["joints"][0].update(child="base-pin"))
        changed(lambda value: value["joints"][0].update(type="ball"))
        changed(lambda value: value["joints"][0].update(position=float("inf")))
        changed(lambda value: value["joints"][0].update(position=True))
        changed(lambda value: value["joints"][0].update(limits=[90, -90]))
        changed(lambda value: value["joints"][0].update(position=91))
        changed(lambda value: value["joints"][0].update(type="fixed"))
        changed(lambda value: value.update(grounded=["link"]))
        changed(lambda value: value["joints"].append(copy.deepcopy(value["joints"][0])))
        changed(lambda value: value.update(joints=value["joints"] * 257))
        for index, value in enumerate(invalid):
            with self.subTest(index=index), self.assertRaises(ModelError):
                validate_assembly_motion(value, physical_parts())

    def test_bad_construction_metadata_rejects_candidate(self):
        script = "result=cq.Assembly(cq.Solid.makeBox(1,2,3), metadata={'lad_motion':{}})"
        with self.assertRaisesRegex(ModelError, "Assembly motion requires"):
            build_shape(script_spec(script))


class NativePoseTests(unittest.TestCase):
    def native_operation(self, folder, shape, spec):
        write_brep(shape, folder / "source.brep")
        request = folder / "request.json"
        request.write_text(json.dumps({"brepAsset": "source.brep", **spec}))
        return run(request, folder / "output", 2)

    def assert_vector(self, actual, expected, places=7):
        self.assertEqual(len(actual), len(expected))
        for a, b in zip(actual, expected):
            self.assertAlmostEqual(a, b, places=places)

    def test_exact_step_pose_preserves_geometry_source_and_subset(self):
        import cadquery as cq
        solids = [cq.Solid.makeBox(1, 2, 3), cq.Solid.makeCylinder(2, 5).translate((10, 0, 0))]
        shape = cq.Compound.makeCompound(solids)
        pose = [{"solid": 1, "matrix": rotation_y(90, (20, 5, 7))}]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            report = self.native_operation(folder, shape, {"operation": "export", "solidIndices": [1],
                                                          "solidTransforms": pose})
            original_bytes = hashlib.sha256((folder / "source.brep").read_bytes()).digest()
            actual = cq.importers.importStep(report["stepPath"]).val()
            self.assertEqual(len(actual.Solids()), 1)
            self.assertAlmostEqual(actual.Volume(), 20 * math.pi)
            self.assert_vector(actual.Center().toTuple(), [22.5, 5, -3])
            self.assert_vector(exact_bounds(actual), [20, 3, -5, 25, 7, -1])
            self.assertEqual(hashlib.sha256((folder / "source.brep").read_bytes()).digest(), original_bytes)
            self.assert_vector(solids[1].Center().toTuple(), [10, 0, 2.5])

    def test_pose_measurement_returns_exact_sparse_curved_geometry_and_bounds(self):
        import cadquery as cq
        cylinder = cq.Solid.makeCylinder(2, 5).translate((10, 0, 0))
        angle = 45
        pose = [{"solid": 0, "matrix": rotation_y(angle, (20, 5, 7))}]
        curve = next(index for index, edge in enumerate(cylinder.Edges()) if edge.geomType() == "CIRCLE")
        face = next(index for index, face in enumerate(cylinder.Faces()) if face.geomType() == "CYLINDER")
        selected = [{"kind": "edge", "solidIndex": 0, "localIndex": curve},
                    {"kind": "face", "solidIndex": 0, "localIndex": face}]
        with tempfile.TemporaryDirectory() as directory:
            with (mock.patch("worker._preview_mesh", side_effect=AssertionError("No posed tessellation")),
                  mock.patch("worker.write_step", side_effect=AssertionError("No posed STEP serialization"))):
                report = self.native_operation(Path(directory), cylinder, {
                    "operation": "measure", "features": selected, "solidIndices": [0], "solidTransforms": pose})
        self.assertEqual(report["metrics"], [])
        self.assertNotIn("closestPoints", report)
        topology = report["topology"]
        sine = math.sqrt(.5)
        self.assert_vector(topology["edges"][0]["axis"], [sine, 0, sine])
        self.assert_vector(topology["faces"][0]["axis"], [sine, 0, sine])
        self.assertAlmostEqual(topology["edges"][0]["radius"], 2)
        self.assertEqual(topology["edges"][0]["polyline"], [])
        self.assert_vector(topology["parts"][0]["centroid"], [20 + 12.5 * sine, 5, 7 - 7.5 * sine])
        # A rotated cylinder's old AABB would overstate the perpendicular
        # extent. Native bounds use its analytic circular support instead.
        self.assert_vector(topology["parts"][0]["bounds"],
                           [20 + 8 * sine, 3, 7 - 12 * sine,
                            20 + 17 * sine, 7, 7 - 3 * sine])

    def test_posed_pair_distance_and_three_vertex_positions_use_original_topology_ids(self):
        import cadquery as cq
        shape = cq.Compound.makeCompound([cq.Solid.makeBox(1, 2, 3),
                                          cq.Solid.makeBox(1, 2, 3).translate((10, 0, 0))])
        pose = [{"solid": 1, "matrix": rotation_y(0, (5, 4, 0))}]
        with tempfile.TemporaryDirectory() as directory:
            report = self.native_operation(Path(directory), shape, {
                "operation": "measure", "solidIndices": [0, 1], "solidTransforms": pose})
        distance = next(metric["values"][0] for metric in report["metrics"] if metric["id"] == "pair:distance")
        self.assertAlmostEqual(distance, math.hypot(14, 2))
        self.assertEqual(len(report["topology"]["parts"]), 2)
        selected = [{"kind": "vertex", "solidIndex": 1, "localIndex": index} for index in range(3)]
        with tempfile.TemporaryDirectory() as directory:
            report = self.native_operation(Path(directory), shape, {
                "operation": "measure", "features": selected, "solidTransforms": pose})
        self.assertEqual(report["metrics"], [])
        for item, vertex in zip(report["topology"]["vertices"], shape.Solids()[1].Vertices()[:3]):
            expected = vertex.toTuple()
            self.assert_vector(item["position"], [expected[0] + 5, expected[1] + 4, expected[2]])
        self.assertEqual([item["id"] for item in report["topology"]["vertices"]], selected)

    def test_nonrigid_ambiguous_or_nonfinite_poses_fail_before_native_transform(self):
        import cadquery as cq
        solid = cq.Solid.makeBox(1, 2, 3)
        identity = rotation_y(0)
        matrices = []
        for index, value in ((0, 2), (0, -1), (1, .1), (12, .1), (15, 0), (3, float("nan"))):
            matrix = identity.copy()
            matrix[index] = value
            matrices.append(matrix)
        invalid = [[{"solid": 0, "matrix": matrix}] for matrix in matrices]
        invalid += [[{"solid": True, "matrix": identity}], [{"solid": 1, "matrix": identity}],
                    [{"solid": 0, "matrix": identity}] * 2, [{"solid": 0, "matrix": identity[:12]}]]
        for records in invalid:
            with self.subTest(records=records), self.assertRaises(ModelError):
                posed_solids([solid], records, cq)
        self.assertTrue(posed_solids([solid], [{"solid": 0, "matrix": identity}], cq)[0] is solid)


if __name__ == "__main__":
    unittest.main()
