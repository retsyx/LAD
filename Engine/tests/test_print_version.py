"""Programs define their 3D printing version through `lad.print`."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker

COUNTERBORE = '''
plate = cq.Workplane("XY").box(40, 20, 6).val()
plate = plate.cut(cq.Solid.makeCylinder(3, 3, cq.Vector(0, 0, 0)))
plate = plate.cut(cq.Solid.makeCylinder(1.6, 10, cq.Vector(0, 0, -5)))
if lad.print:
    # One printed layer closes the shaft where the counterbore steps down.
    plate = plate.fuse(cq.Solid.makeCylinder(1.6, 0.2, cq.Vector(0, 0, -0.2))).clean()
peg = cq.Solid.makeCylinder(3, 15, cq.Vector(30, 0, 0))
result = (cq.Assembly(name="Kit", metadata={"lad_id": "kit", "lad_print_down": (0, 0, 1)})
    .add(plate, name="Plate", metadata={"lad_id": "plate"})
    .add(peg, name="Peg", metadata={"lad_id": "peg", "lad_print_down": [0, 0, -3]}))
'''


def spec(script, printing=False):
    value = {"title": "Kit", "summary": "Printing version test.", "units": "mm", "script": script}
    if printing:
        value["print"] = True
    return value


class PrintVersionTests(unittest.TestCase):
    def build(self, script, printing=False):
        stats = {}
        shape = worker.build_shape(spec(script, printing), preview_stats=stats)
        return shape, worker.make_preview(shape, preview_stats=stats)

    def test_reading_the_flag_defines_a_printing_version_with_extra_geometry(self):
        ordinary, ordinary_preview = self.build(COUNTERBORE)
        printing, printing_preview = self.build(COUNTERBORE, printing=True)
        self.assertTrue(ordinary_preview["printVersion"])
        self.assertTrue(printing_preview["printVersion"])
        bridge = 3.14159265 * 1.6 * 1.6 * 0.2
        self.assertAlmostEqual(printing.Volume() - ordinary.Volume(), bridge, places=3)
        self.assertEqual([part["id"] for part in ordinary_preview["parts"][0]["children"]], ["plate", "peg"])
        self.assertEqual(ordinary_preview["parts"], printing_preview["parts"])

    def test_pinned_directions_are_inherited_overridden_and_normalized(self):
        _, preview = self.build(COUNTERBORE)
        self.assertEqual(preview["printDown"], [{"solid": 0, "direction": [0.0, 0.0, 1.0]},
                                                {"solid": 1, "direction": [0.0, 0.0, -1.0]}])

    def test_programs_that_never_read_the_flag_have_no_printing_version(self):
        shape, preview = self.build("result = cq.Workplane('XY').box(4, 5, 6)")
        self.assertNotIn("printVersion", preview)
        self.assertNotIn("printDown", preview)
        self.assertFalse(shape._lad_print_version)

    def test_invalid_pins_and_options_fail_before_acceptance(self):
        for value in ("(0, 0, 0)", "(0, 0)", "'down'", "(0, 0, float('nan'))", "(True, 0, 0)"):
            script = f"result = cq.Assembly().add(cq.Solid.makeBox(1, 1, 1), name='Box', metadata={{'lad_print_down': {value}}})"
            with self.subTest(value=value), self.assertRaises(worker.ModelError):
                worker.build_shape(spec(script))
        for option in (False, 1, "true"):
            value = spec("result = cq.Solid.makeBox(1, 1, 1)")
            value["print"] = option
            with self.subTest(option=option), self.assertRaises(worker.ModelError):
                worker.validate_spec(value)

    def test_printing_version_has_its_own_validation_receipt(self):
        import cadquery as cq
        with tempfile.TemporaryDirectory() as directory:
            ordinary = worker.validation_hash(spec(COUNTERBORE), Path(directory), cq)
            printing = worker.validation_hash(spec(COUNTERBORE, printing=True), Path(directory), cq)
            self.assertNotEqual(ordinary, printing)
            self.assertEqual(ordinary, worker.validation_hash(spec(COUNTERBORE), Path(directory), cq))


if __name__ == "__main__":
    unittest.main()
