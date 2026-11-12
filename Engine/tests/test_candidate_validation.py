"""Candidate acceptance requires exact native and STEP-transfer integrity."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import cadquery as cq
from OCP.BRepCheck import BRepCheck_Analyzer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


def displaced_pcurve_program(delta, origin=(0, 0, 0)):
    """Keep box geometry fixed while offsetting one face's edge representation."""
    return f"""from OCP.BRep import BRep_Builder, BRep_Tool
from OCP.gp import gp_Vec2d
result = cq.Solid.makeBox(2, 3, 4, cq.Vector({origin[0]!r}, {origin[1]!r}, {origin[2]!r}))
face = result.Faces()[0]
edge = face.Edges()[0]
curve = BRep_Tool.CurveOnSurface_s(edge.wrapped, face.wrapped, 0., 0.)
BRep_Builder().UpdateEdge(edge.wrapped, curve.Translated(gp_Vec2d({delta!r}, 0)), face.wrapped, 1e-7)
"""


def displaced_pcurve_box(delta, origin=(0, 0, 0)):
    namespace = {'cq': cq}
    exec(displaced_pcurve_program(delta, origin), namespace, namespace)
    return namespace['result']


class CandidateNativeValidationTests(unittest.TestCase):
    @staticmethod
    def offset_curve_solid():
        # One closed cubic trace reproduces a tiny representation discrepancy
        # in the stamp design, below the application's numeric tolerance.
        points = [cq.Vector(x * 0.06, y * 0.06, 0)
                  for x, y in [(404, 330), (295, 386), (201, 418), (211, 500)]]
        curve = cq.Edge.makeBezier(points)
        trace = cq.Wire.assembleEdges([
            curve, cq.Edge.makeLine(points[-1], points[0])])
        offsets = trace.offset2D(0.75, "arc") + trace.offset2D(-0.75, "arc")
        offsets.sort(key=lambda wire: cq.Face.makeFromWires(wire).Area(), reverse=True)
        return cq.Solid.extrudeLinear(offsets[0], offsets[1:], cq.Vector(0, 0, 2))

    def test_accepts_small_offset_discrepancy_within_geometry_tolerance(self):
        shape = self.offset_curve_solid()
        self.assertTrue(shape.isValid(), "The fixture passes sampled checks at its original tolerances.")
        self.assertFalse(BRepCheck_Analyzer(shape.wrapped, True, False, True).IsValid())
        worker.validate_shape(shape)
        self.assertTrue(BRepCheck_Analyzer(shape.wrapped, True, False, True).IsValid())

    def test_accepts_controlled_curve_discrepancy_below_tolerance_without_moving_geometry(self):
        shape = displaced_pcurve_box(1e-5)
        positions = [vertex.toTuple() for vertex in shape.Vertices()]
        self.assertFalse(BRepCheck_Analyzer(shape.wrapped, True, False, True).IsValid())
        worker.validate_shape(shape)
        self.assertTrue(BRepCheck_Analyzer(shape.wrapped, True, False, True).IsValid())
        self.assertEqual([vertex.toTuple() for vertex in shape.Vertices()], positions)

    def test_rejects_controlled_curve_discrepancy_above_geometry_tolerance(self):
        shape = displaced_pcurve_box(1e-3)
        with self.assertRaises(worker.ModelError) as caught:
            worker.validate_shape(shape)
        failures = caught.exception.diagnostic['failures']
        edge_failures = [failure for failure in failures if failure['entity']['kind'] == 'edge']
        self.assertTrue(edge_failures)
        self.assertTrue(any(failure['maxDeviation'] > 1e-4 for failure in edge_failures))
        self.assertTrue(all(failure['tolerance'] >= 1e-4 for failure in edge_failures))

    def test_rejects_construction_geometry_beside_a_valid_solid(self):
        shape = cq.Compound.makeCompound([
            cq.Solid.makeBox(2, 3, 4), cq.Face.makePlane(1, 1)])
        self.assertTrue(shape.isValid())
        self.assertGreater(shape.Volume(), 0)
        with self.assertRaises(worker.ModelError):
            worker.validate_shape(shape)

    def test_rejects_negative_volume_part_despite_positive_whole_design_volume(self):
        reversed_part = cq.Shape.cast(cq.Solid.makeBox(1, 1, 1).wrapped.Reversed())
        shape = cq.Compound.makeCompound([
            cq.Solid.makeBox(2, 3, 4), reversed_part.translate((10, 0, 0))])
        self.assertTrue(shape.isValid())
        self.assertGreater(shape.Volume(), 0)
        self.assertLess(shape.Solids()[1].Volume(), 0)
        with self.assertRaises(worker.ModelError):
            worker.validate_shape(shape)

    def test_rejects_open_shell_wrapped_as_a_solid(self):
        box = cq.Solid.makeBox(2, 3, 4)
        shape = cq.Solid.makeSolid(cq.Shell.makeShell(box.Faces()[:-1]))
        self.assertEqual(shape.ShapeType(), "Solid")
        self.assertGreater(shape.Volume(), 0)
        with self.assertRaises(worker.ModelError):
            worker.validate_shape(shape)


class CandidateSTEPRoundtripTests(unittest.TestCase):
    @staticmethod
    def write_step(shape, folder):
        path = folder / "candidate.step"
        cq.exporters.export(shape, str(path), exportType="STEP")
        return path

    def test_native_step_verification_and_import_accept_more_than_128_mib(self):
        source = cq.Solid.makeBox(2, 3, 4)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            step = self.write_step(source, folder)
            header, marker, rest = step.read_bytes().partition(b"HEADER;")
            self.assertTrue(marker)
            # A legal STEP comment exercises the real parser above the former
            # cap. Write bounded chunks rather than allocate a huge string.
            prefix, suffix = header, marker + rest
            remaining = 128 * 1024 * 1024 + 1 - len(prefix) - len(suffix)
            comment = b"/* LAD size boundary fixture */\n"
            chunk = comment * (1_048_576 // len(comment))
            with step.open("wb") as stream:
                stream.write(prefix)
                while remaining >= len(comment):
                    count = min(remaining, len(chunk))
                    count -= count % len(comment)
                    stream.write(chunk[:count])
                    remaining -= count
                stream.write(b" " * remaining)
                stream.write(suffix)
            self.assertGreater(step.stat().st_size, 128 * 1024 * 1024)
            worker.validate_step_roundtrip(source, cq, step)
            imported = worker.import_input_asset(step, "step", cq)
            self.assertAlmostEqual(imported.Volume(), source.Volume(), places=7)

    def test_step_size_boundary_is_512_mb_and_rejects_larger_before_reading(self):
        source = cq.Solid.makeBox(2, 3, 4)
        with tempfile.TemporaryDirectory() as directory:
            step = Path(directory) / "boundary.step"
            # Sparse files exercise size gates at the actual boundary without
            # allocating 512 MB. Native STEP parsing has real coverage above.
            with step.open("wb") as stream:
                stream.truncate(512_000_000)
            original_import = worker.import_step

            def import_fixture(path, runtime, preview_stats=None):
                self.assertEqual(path, step)
                return worker.validate_shape(source, preview_stats=preview_stats)

            with mock.patch.object(worker, "import_step", side_effect=import_fixture) as reader:
                worker.validate_step_roundtrip(source, cq, step)
                reader.assert_called_once()
            # Earlier build tests lower this process's hard file cap, so model
            # the one-byte-oversize stat rather than trying to exceed that cap.
            fields = list(step.stat())
            fields[6] = 512_000_001
            oversized = os.stat_result(fields)
            with (mock.patch.object(Path, "stat", return_value=oversized),
                  mock.patch.object(worker, "import_step", wraps=original_import) as reader):
                with self.assertRaisesRegex(worker.ModelError, "512 MB"):
                    worker.validate_step_roundtrip(source, cq, step)
                reader.assert_not_called()
            with (mock.patch.object(Path, "lstat", return_value=oversized),
                  self.assertRaisesRegex(worker.ModelError, "512 MB")):
                worker.import_input_asset(step, "step", cq)

    def test_accepts_unchanged_parts_when_step_reorders_them(self):
        parts = [cq.Solid.makeBox(2, 3, 4).translate((-20, 1, 2)),
                 cq.Solid.makeCylinder(2, 5).translate((11, 2, -3))]
        source = cq.Compound.makeCompound(parts)
        with tempfile.TemporaryDirectory() as directory:
            step = self.write_step(cq.Compound.makeCompound(parts[::-1]), Path(directory))
            worker.validate_step_roundtrip(source, cq, step)

    def test_step_precision_settings_are_restored_after_success_and_read_failure(self):
        from OCP.Interface import Interface_Static
        from OCP.STEPControl import STEPControl_Controller
        STEPControl_Controller.Init_s()
        settings = {}
        for direction in ('read', 'write'):
            settings[direction] = (Interface_Static.IVal_s(f'{direction}.precision.mode'),
                                   Interface_Static.RVal_s(f'{direction}.precision.val'))
        try:
            # Distinct caller values make an unscoped assignment observable.
            for direction in settings:
                Interface_Static.SetIVal_s(f'{direction}.precision.mode', 0)
                Interface_Static.SetRVal_s(f'{direction}.precision.val', 3e-6)
            shape = cq.Solid.makeBox(2, 3, 4)
            with tempfile.TemporaryDirectory() as directory:
                step = Path(directory) / 'candidate.step'
                worker.write_step([shape], step, cq)
                worker.validate_step_roundtrip(shape, cq, step)
                step.write_text('ISO-10303-21;\nNot a STEP entity.\nEND-ISO-10303-21;\n')
                with self.assertRaises(worker.ModelError):
                    worker.validate_step_roundtrip(shape, cq, step)
            for direction in settings:
                self.assertEqual(Interface_Static.IVal_s(f'{direction}.precision.mode'), 0)
                self.assertEqual(Interface_Static.RVal_s(f'{direction}.precision.val'), 3e-6)
        finally:
            for direction, (mode, value) in settings.items():
                Interface_Static.SetIVal_s(f'{direction}.precision.mode', mode)
                Interface_Static.SetRVal_s(f'{direction}.precision.val', value)

    def test_near_coincident_part_matching_is_independent_of_import_order(self):
        source = cq.Compound.makeCompound([
            cq.Solid.makeBox(1, 1, 1),
            cq.Solid.makeBox(1, 1, 1).translate((1e-4, 0, 0)),
        ])
        # The +0.5e-4 mm part can match either original within the allowed
        # tolerance; the -0.5e-4 mm part can match only the first original.
        # Matching the first available body greedily rejects one STEP order.
        with tempfile.TemporaryDirectory() as directory:
            for offsets in ((0.5e-4, -0.5e-4), (-0.5e-4, 0.5e-4)):
                with self.subTest(offsets=offsets):
                    transferred = cq.Compound.makeCompound([
                        cq.Solid.makeBox(1, 1, 1).translate((offset, 0, 0))
                        for offset in offsets])
                    step = self.write_step(transferred, Path(directory))
                    worker.validate_step_roundtrip(source, cq, step)

    def test_rejects_missing_or_changed_bodies_and_equal_volume_displacement(self):
        source = cq.Solid.makeBox(2, 3, 4)
        replacements = {
            "open surface instead of a body": cq.Shell.makeShell(source.Faces()[:-1]),
            "different volume": cq.Solid.makeBox(2, 3, 5),
            "same volume and area at a different location": source.translate((5, 0, 0)),
            "same total volume split into separate bodies": cq.Compound.makeCompound([
                cq.Solid.makeBox(1, 3, 4),
                cq.Solid.makeBox(1, 3, 4).translate((1, 0, 0))]),
        }
        with tempfile.TemporaryDirectory() as directory:
            for label, replacement in replacements.items():
                with self.subTest(label=label):
                    step = self.write_step(replacement, Path(directory))
                    with self.assertRaises(worker.ModelError):
                        worker.validate_step_roundtrip(source, cq, step)

    def test_rejects_part_movement_hidden_by_unchanged_whole_design_totals(self):
        enclosure = cq.Solid.makeBox(10, 10, 10)
        inner = cq.Solid.makeBox(1, 1, 1).translate((2, 2, 2))
        source = cq.Compound.makeCompound([enclosure, inner])
        shifted = cq.Compound.makeCompound([enclosure, inner.translate((3, 0, 0))])
        self.assertAlmostEqual(source.Volume(), shifted.Volume())
        self.assertAlmostEqual(source.Area(), shifted.Area())
        self.assertEqual(worker.exact_bounds(source), worker.exact_bounds(shifted))
        with tempfile.TemporaryDirectory() as directory:
            step = self.write_step(shifted, Path(directory))
            with self.assertRaises(worker.ModelError):
                worker.validate_step_roundtrip(source, cq, step)

    def test_converts_step_read_failure_to_a_candidate_error(self):
        source = cq.Solid.makeBox(2, 3, 4)
        with tempfile.TemporaryDirectory() as directory:
            step = self.write_step(source, Path(directory))
            with mock.patch.object(cq.importers, "importStep", side_effect=ValueError("bad transfer")):
                with self.assertRaises(worker.ModelError):
                    worker.validate_step_roundtrip(source, cq, step)

    def test_deferred_build_rejects_bad_step_before_preview_or_native_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            request = folder / "request.json"
            output = folder / "output"
            request.write_text(json.dumps({
                "title": "Box", "summary": "A box", "units": "mm",
                "script": "result = cq.Solid.makeBox(2, 3, 4)",
            }))
            original_export = worker.write_step

            def corrupted_export(solids, filename, runtime, colors=None, indices=None):
                moved = [solid.translate((5, 0, 0)) for solid in solids]
                return original_export(moved, filename, runtime, colors=colors, indices=indices)

            with (mock.patch.object(worker, "write_step", side_effect=corrupted_export),
                  mock.patch.object(worker, "make_preview", side_effect=AssertionError("No preview before acceptance"))):
                with self.assertRaises(worker.ModelError):
                    worker.run(request, output, 2, defer_step=True)
            for name in ("result.json", "result.json.tmp", "mesh.bin", "model.brep", "model.step"):
                self.assertFalse((output / name).exists(), f"Rejected candidate published {name}.")

    def test_deferred_build_checks_step_then_removes_temporary_export(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            request = folder / "request.json"
            output = folder / "output"
            request.write_text(json.dumps({
                "title": "Box", "summary": "A box", "units": "mm",
                "script": "result = cq.Solid.makeBox(2, 3, 4)",
            }))
            checked_paths = []
            original_validate = worker.validate_step_roundtrip

            def capture_check(shape, runtime, step_path, preview_stats=None):
                checked_paths.append(Path(step_path))
                self.assertTrue(Path(step_path).is_file())
                return original_validate(shape, runtime, step_path, preview_stats=preview_stats)

            with mock.patch.object(worker, "validate_step_roundtrip", side_effect=capture_check):
                result = worker.run(request, output, 2, defer_step=True)
            self.assertEqual(len(checked_paths), 1)
            self.assertTrue(all(not path.exists() for path in checked_paths))
            self.assertFalse((output / "model.step").exists())
            self.assertTrue(Path(result["brepPath"]).is_file())
            self.assertEqual(result["solids"], 1)
            self.assertEqual(result["faces"], 6)
            self.assertAlmostEqual(result["volume"], 24)


class GeometryFileResourceLimitTests(unittest.TestCase):
    def test_worker_allows_512_mb_files_and_preserves_a_stricter_inherited_limit(self):
        # build_script sets an irreversible hard cap. Run each case in a child
        # so the unittest process and its other native fixtures stay unaffected.
        code = """
import errno
import json
from pathlib import Path
import resource
import signal
import sys
import cadquery as cq

sys.path.insert(0, sys.argv[1])
import worker
requested = int(sys.argv[2])
if requested:
    resource.setrlimit(resource.RLIMIT_FSIZE, (requested, requested))
before = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
worker.build_script('result = cq.Solid.makeBox(1,1,1)', cq)
expected = 512_000_000 if before == resource.RLIM_INFINITY else min(512_000_000, before)
actual = resource.getrlimit(resource.RLIMIT_FSIZE)
assert actual == (expected, expected), (actual, expected)
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
path = Path(sys.argv[3])
with path.open('wb') as stream:
    stream.truncate(expected)
assert path.stat().st_size == expected
blocked = False
try:
    with path.open('r+b') as stream:
        stream.truncate(expected + 1)
except OSError as error:
    blocked = error.errno == errno.EFBIG
assert blocked, 'The worker file cap did not prevent a larger file'
print(json.dumps({'limit': expected, 'blocked': blocked}))
"""
        with tempfile.TemporaryDirectory() as directory:
            for inherited in (0, 96_000_000):
                with self.subTest(inherited=inherited):
                    result = subprocess.run([
                        sys.executable, "-c", code, str(Path(worker.__file__).parent),
                        str(inherited), str(Path(directory) / "output.bin"),
                    ], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    report = json.loads(result.stdout)
                    self.assertEqual(report["limit"], inherited or 512_000_000)
                    self.assertTrue(report["blocked"])


if __name__ == "__main__":
    unittest.main()
