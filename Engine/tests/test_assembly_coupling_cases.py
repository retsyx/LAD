"""Golden coupling cases shared with the native app's AssemblyCouplingTests."""
import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from assembly_motion import AssemblyMotionError, coupled_position, validate_motion

CASES = json.loads(Path(__file__).with_name("assembly-coupling-cases.json").read_text(encoding="utf-8"))


def definition(joints, couplings):
    return copy.deepcopy({"grounded": CASES["grounded"], "connectors": CASES["connectors"],
                          "joints": joints, "couplings": couplings})


def positions(motion, drivers):
    """Every joint's position, resolving followers from their drivers."""
    joints = {joint["id"]: joint for joint in motion["joints"]}
    couplings = {coupling["follower"]: coupling for coupling in motion["couplings"]}

    def value(identity):
        coupling = couplings.get(identity)
        if coupling is None:
            return drivers.get(identity, joints[identity]["position"])
        return coupled_position(coupling, value(coupling["driver"]))
    return {identity: value(identity) for identity in joints}


class SharedCouplingCaseTests(unittest.TestCase):
    def assertPositions(self, actual, expected):
        self.assertEqual(set(expected) - set(actual), set())
        for identity, value in expected.items():
            self.assertAlmostEqual(actual[identity], value, delta=1e-9 * max(1.0, abs(value)), msg=identity)

    def test_follower_positions_match_the_shared_cases(self):
        for case in CASES["cases"]:
            with self.subTest(case["name"]):
                motion = validate_motion(definition(case["joints"], case["couplings"]), CASES["parts"])
                self.assertPositions({joint["id"]: joint["position"] for joint in motion["joints"]}, case["initial"])
                for sample in case["samples"]:
                    self.assertPositions(positions(motion, sample["drivers"]), {**sample["drivers"], **sample["expected"]})

    def test_shared_invalid_couplings_are_rejected(self):
        for case in CASES["invalid"]:
            joints = copy.deepcopy(CASES["invalidJoints"])
            if "driverLimits" in case:
                joints[0]["limits"] = case["driverLimits"]
            with self.subTest(case["name"]), self.assertRaises(AssemblyMotionError):
                validate_motion(definition(joints, case["couplings"]), CASES["parts"])


if __name__ == "__main__":
    unittest.main()
