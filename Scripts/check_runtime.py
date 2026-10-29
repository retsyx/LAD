"""Exercise packaged CAD, numeric solvers and standalone Python facilities."""
import os
from pathlib import Path
import tempfile

os.environ["NUMBA_THREADING_LAYER"] = "workqueue"
import cadquery as cq
import casadi as ca
import ensurepip
import numba
import numpy as np
import ssl
import venv

shape = cq.Workplane("XY").box(20, 15, 6).edges("|Z").fillet(1)
assert 1700 < shape.val().Volume() < 1800
cq.Sketch().segment((0, 0), (10, 0), tag="line").constrain("line", "Fixed", None).solve()
x = ca.SX.sym("x")
solver = ca.nlpsol("test", "ipopt", {"x": x, "f": (x - 2) ** 2}, {"ipopt.print_level": 0, "print_time": False})
assert abs(float(solver(x0=0)["x"]) - 2) < 1e-6
with tempfile.TemporaryDirectory(prefix="LAD-runtime-smoke-") as directory:
    path = Path(directory) / "exact.step"
    cq.exporters.export(shape, str(path))
    assert abs(cq.importers.importStep(str(path)).val().Volume() - shape.val().Volume()) < 1e-6


@numba.njit(parallel=True)
def parallel_sum(values):
    return values.sum()


assert parallel_sum(np.arange(1000)) == 499500
assert numba.threading_layer() == "workqueue"
print("Standalone CAD runtime checks passed (fillet, exact STEP, Sketch.solve, IPOPT, Numba workqueue).")
