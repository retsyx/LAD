#!/usr/bin/env python3
"""LAD's exact CAD worker for full CadQuery/OCP Python programs.

Every invocation is isolated in its own process, keeping OpenCascade failures,
imports, modeling and meshing away from the native application's main thread.
The macOS app additionally sandboxes CAD programs before launch.
"""
from __future__ import annotations

import argparse
from contextvars import ContextVar
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import time

from assembly_motion import AssemblyMotionError, transformed_solids, validate_motion

MAX_TRIANGLES = 1_000_000
MAX_VERTICES = 1_000_000
MAX_EDGE_SEGMENTS = 250_000
MAX_SCRIPT_BYTES = 200_000
MAX_GEOMETRY_BYTES = 512_000_000
MAX_VALIDATION_FAILURES = 24
MAX_PREVIEW_EXACT_ORIENTATION_CELLS = 4_096
MAX_PREVIEW_REFINEMENT_NODES = 20_000
MAX_PREVIEW_REFINEMENT_PASSES = 16
MAX_PREVIEW_REFINEMENT_PROJECTIONS = 16_384
MAX_PREVIEW_REFINEMENT_CELLS = 100_000
MAX_PREVIEW_SHADING_SAMPLES = 64_000
MAX_PREVIEW_SHADING_PROJECTIONS = 512
MAX_PREVIEW_SHADING_NODES = 8_192
MAX_PREVIEW_SHADING_PASSES = 4
PREVIEW_SHADING_NORMAL_DOT = math.cos(math.radians(1.0))
GEOMETRY_TOLERANCE_MM = 1e-4
LIMIT = 100_000.0
_validated_replay = ContextVar("validated_replay", default=False)
_validation_scope = ContextVar("validation_scope", default="native_candidate")
_validation_input = ContextVar("validation_input", default=None)
# A serving worker keeps recently read native solids, keyed by the identity
# the app assigns each build's model.brep. One-shot processes never cache.
_serving = False
_native_shapes = {}
NATIVE_CACHE_SIZE = 2
NATIVE_OPERATIONS = {"runtime", "export", "dxf", "measure", "clearance", "print_orient", "verify"}
# Fields every native operation accepts beside its own (see read_brep).
NATIVE_SOURCE_FIELDS = {"brepAsset", "nativeIdentity", "validatedNative"}

ROOT_KEYS = {"title", "summary", "units", "script"}


class ModelError(ValueError):
    """An actionable, user-visible modeling error."""

    def __init__(self, message, *, diagnostic=None):
        super().__init__(message)
        self.diagnostic = diagnostic


class HostError(RuntimeError):
    """The app's request or the CAD runtime is at fault, not the design."""


def failure_kind(error):
    """Report "design" when changing the program could fix the failure.

    Program exceptions arrive wrapped in ModelError, so an OSError or
    ImportError reaching here comes from the runtime or its file access.
    """
    if isinstance(error, (HostError, ImportError, OSError)):
        return "runtime"
    return "design"


def validate_assembly_motion(definition, parts):
    try:
        return validate_motion(definition, parts)
    except AssemblyMotionError as error:
        raise ModelError(str(error)) from error


def posed_solids(solids, records, cq):
    try:
        return transformed_solids(solids, records, cq)
    except AssemblyMotionError as error:
        raise ModelError(str(error)) from error


@contextmanager
def validation_scope(scope, input_asset=None):
    scope_token = _validation_scope.set(scope)
    input_token = _validation_input.set(input_asset)
    try:
        yield
    finally:
        _validation_input.reset(input_token)
        _validation_scope.reset(scope_token)


def apply_geometry_tolerance(shape):
    """Allow sub-micron boundary discrepancies without moving any geometry.

    WIRE applies to edges and vertices. A zero upper limit means minimum-only:
    never reduce a larger existing tolerance or change face surfaces, topology,
    orientation or locations. Exact BRep validation still runs afterwards.
    """
    from OCP.ShapeFix import ShapeFix_ShapeTolerance
    from OCP.TopAbs import TopAbs_WIRE
    ShapeFix_ShapeTolerance().LimitTolerance(shape.wrapped, GEOMETRY_TOLERANCE_MM, 0.0, TopAbs_WIRE)
    return shape


@contextmanager
def step_precision(direction):
    """Scope OCCT precision to this operation without understating accuracy.

    Read mode 1 uses our requested precision. Write mode 1 uses the greatest
    native tolerance, which is at least our boundary floor and may be larger
    for existing geometry. Both settings are restored before returning.
    """
    from OCP.Interface import Interface_Static
    from OCP.STEPControl import STEPControl_Controller
    STEPControl_Controller.Init_s()
    mode, value = f"{direction}.precision.mode", f"{direction}.precision.val"
    previous = Interface_Static.IVal_s(mode), Interface_Static.RVal_s(value)
    try:
        if (not Interface_Static.SetIVal_s(mode, 1)
                or not Interface_Static.SetRVal_s(value, GEOMETRY_TOLERANCE_MM)):
            raise ModelError(f"Could not configure STEP {direction} precision.",
                             diagnostic={"stage": "step_precision"})
        yield
    finally:
        Interface_Static.SetIVal_s(mode, previous[0])
        Interface_Static.SetRVal_s(value, previous[1])


def validate_spec(spec):
    """Validate the complete request before importing or calling the CAD kernel."""
    if (not isinstance(spec, dict) or not ROOT_KEYS <= set(spec)
            or set(spec) - ROOT_KEYS - {"sourceAsset", "sourceValidatedBREP", "inputAssets", "print"}):
        raise ModelError("Design must contain title, summary, units and a complete Python script.")
    if "print" in spec and spec["print"] is not True:
        raise ModelError("The 3D printing build option must be true when present.")
    for name, maximum in (("title", 160), ("summary", 6000)):
        if not isinstance(spec[name], str) or not 1 <= len(spec[name]) <= maximum:
            raise ModelError(f"{name} must be a nonempty string of at most {maximum} characters.")
    if spec["units"] != "mm":
        raise ModelError("Only millimeters (units: mm) are supported.")
    script = spec["script"]
    if not isinstance(script, str) or not script.strip() or len(script.encode("utf-8")) > MAX_SCRIPT_BYTES:
        raise ModelError(f"Python script must be nonempty text of at most {MAX_SCRIPT_BYTES:,} UTF-8 bytes.")
    if "sourceAsset" in spec and spec["sourceAsset"] != "source.step":
        raise ModelError("Imported geometry requires the private source.step asset.")
    if "sourceValidatedBREP" in spec and ("sourceAsset" not in spec
                                          or spec["sourceValidatedBREP"] != "source" + VALIDATED_COPY_SUFFIX):
        raise ModelError("A validated copy of the imported STEP requires the private source.validated.brep asset.")
    assets = spec.get("inputAssets", [])
    if not isinstance(assets, list) or len(assets) > 256:
        raise ModelError("Imported geometry contains too many input assets.")
    seen = set()
    for index, asset in enumerate(assets):
        if (not isinstance(asset, dict) or not {"id", "name", "format", "path"} <= set(asset)
                or set(asset) - {"id", "name", "format", "path", "validatedBREP"}
                or not isinstance(asset["id"], str) or not 1 <= len(asset["id"]) <= 1024
                or any(ord(char) < 32 for char in asset["id"]) or asset["id"] in seen
                or not isinstance(asset["name"], str) or not 1 <= len(asset["name"]) <= 255
                or not isinstance(asset["format"], str) or asset["format"] not in {"step", "stp", "brep", "stl", "obj"}
                or asset["path"] != f"input-{index:03d}.{asset['format']}"
                or asset.get("validatedBREP", f"input-{index:03d}{VALIDATED_COPY_SUFFIX}")
                != f"input-{index:03d}{VALIDATED_COPY_SUFFIX}"):
            raise ModelError("Imported geometry requires uniquely identified private input assets.")
        seen.add(asset["id"])
    return spec


def configure_threads(threads):
    from OCP.OSD import OSD_Parallel, OSD_ThreadPool
    # OpenCascade uses this shared C++ pool for parallel boolean operations and
    # BRepMesh. Unlike Python threads this uses all configured CPU cores.
    OSD_ThreadPool.DefaultPool_s().Init(threads)
    OSD_Parallel.SetUseOcctThreads_s(True)


def _shape_entities(shape, kind):
    """Match CadQuery's subshape order without iterating an OCP map.

    The bound map's Python sequence iterator terminates by raising a native
    out-of-range exception. That is costly for every small per-face traversal.
    Indexed access avoids the exception while retaining CadQuery's exact
    TopExp.MapShapes ordering, native locations and degenerate-edge filtering.
    Keep this local to worker extraction; user programs and the shared runtime
    continue to use the installed CadQuery API unchanged.
    """
    from cadquery.occ_impl import shapes as cq_shapes
    from OCP.BRep import BRep_Tool
    from OCP.TopAbs import (TopAbs_VERTEX, TopAbs_EDGE, TopAbs_WIRE, TopAbs_FACE,
                           TopAbs_SHELL, TopAbs_SOLID, TopAbs_COMPSOLID, TopAbs_COMPOUND)
    from OCP.TopExp import TopExp
    from OCP.TopoDS import TopoDS
    from OCP.TopTools import TopTools_IndexedMapOfShape
    native_kind, wrapper = {
        "Vertex": (TopAbs_VERTEX, cq_shapes.Vertex), "Edge": (TopAbs_EDGE, cq_shapes.Edge),
        "Wire": (TopAbs_WIRE, cq_shapes.Wire), "Face": (TopAbs_FACE, cq_shapes.Face),
        "Shell": (TopAbs_SHELL, cq_shapes.Shell), "Solid": (TopAbs_SOLID, cq_shapes.Solid),
        "CompSolid": (TopAbs_COMPSOLID, cq_shapes.CompSolid), "Compound": (TopAbs_COMPOUND, cq_shapes.Compound),
    }[kind]
    entities = TopTools_IndexedMapOfShape()
    TopExp.MapShapes_s(shape.wrapped, native_kind, entities)
    result = []
    for index in range(1, entities.Extent() + 1):
        native = entities.FindKey(index)
        if kind == "Edge" and BRep_Tool.Degenerated_s(TopoDS.Edge(native)):
            continue
        result.append(wrapper(native))
    return result


def geometry_validation_error(shape, analyzer):
    """Keep OCCT's actual statuses and pointers scoped to this exact shape.

    These are zero-based native topology indices, not STEP entity numbers or
    selections in a previous preview. In particular STEP readback can reorder
    and split topology. Never silently remap its indices to the live design.
    """
    import cadquery as cq
    from OCP.BRepCheck import BRepCheck_NoError
    from OCP.TopAbs import (TopAbs_VERTEX, TopAbs_EDGE, TopAbs_WIRE, TopAbs_FACE,
                           TopAbs_SHELL, TopAbs_SOLID, TopAbs_COMPSOLID, TopAbs_COMPOUND)
    from OCP.TopExp import TopExp
    from OCP.TopTools import TopTools_IndexedMapOfShape
    scope = _validation_scope.get()
    failures, seen = [], set()
    omitted = 0
    stage = {"step_readback": "step_readback_validation", "input_asset": "input_validation",
             "source_step": "input_validation", "saved_step": "input_validation"}.get(scope, "native_validation")
    diagnostic = {"stage": stage,
                  "geometryScope": scope, "failures": failures, "omittedFailures": 0}
    input_asset = _validation_input.get()
    if input_asset:
        diagnostic["inputAsset"] = input_asset
    try:
        maps, owners = {}, {}
        kinds = [("Vertex", TopAbs_VERTEX), ("Edge", TopAbs_EDGE), ("Wire", TopAbs_WIRE),
                 ("Face", TopAbs_FACE), ("Shell", TopAbs_SHELL), ("Solid", TopAbs_SOLID),
                 ("CompSolid", TopAbs_COMPSOLID), ("Compound", TopAbs_COMPOUND)]
        for kind, native_kind in kinds:
            native_map = TopTools_IndexedMapOfShape()
            TopExp.MapShapes_s(shape.wrapped, native_kind, native_map)
            maps[kind] = native_map
        # Match the existing feature order, including its degenerate-edge
        # filtering, while also retaining pointers to other invalid subshapes.
        for solid_index, solid in enumerate(_shape_entities(shape, "Solid")):
            for kind, _ in kinds:
                for local_index, entity in enumerate(_shape_entities(solid, kind)):
                    index = maps[kind].FindIndex(entity.wrapped)
                    owners.setdefault((kind, index), []).append(
                        {"solidIndex": solid_index, "localIndex": local_index})

        def reference(native):
            wrapped = cq.Shape.cast(native)
            kind = wrapped.ShapeType()
            index = maps[kind].FindIndex(native) if kind in maps else 0
            result = {"kind": kind.lower(), "index": index - 1}
            references = owners.get((kind, index), [])
            if references:
                result["owners"] = references[:4]
                if len(references) > 4:
                    result["omittedOwners"] = len(references) - 4
            return result

        measurements = {}

        def measures(native, context, entity, parent):
            key = (entity["kind"], entity["index"],
                   parent["kind"] if parent else None, parent["index"] if parent else None)
            if key in measurements:
                return measurements[key]
            values = {}
            try:
                bounds = exact_bounds(cq.Shape.cast(native))
                if all(math.isfinite(value) for value in bounds):
                    values["bounds"] = bounds
            except Exception:
                pass
            if entity["kind"] == "edge":
                from OCP.BRep import BRep_Tool
                from OCP.TopoDS import TopoDS
                edge = TopoDS.Edge(native)
                tolerance = BRep_Tool.Tolerance_s(edge)
                if math.isfinite(tolerance) and tolerance >= 0:
                    values["tolerance"] = tolerance
                if parent and parent["kind"] == "face" and not BRep_Tool.Degenerated_s(edge):
                    try:
                        from OCP.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Curve2d, BRepAdaptor_Surface
                        from OCP.Adaptor3d import Adaptor3d_CurveOnSurface
                        from OCP.GeomLib import GeomLib_CheckCurveOnSurface
                        face = TopoDS.Face(context)
                        curve = BRepAdaptor_Curve(edge)
                        surface_curve = Adaptor3d_CurveOnSurface(
                            BRepAdaptor_Curve2d(edge, face), BRepAdaptor_Surface(face))
                        check = GeomLib_CheckCurveOnSurface(curve)
                        check.Perform(surface_curve)
                        if check.IsDone():
                            distance, parameter = check.MaxDistance(), check.MaxParameter()
                            point = list(curve.Value(parameter).Coord())
                            if (math.isfinite(distance) and distance >= 0 and math.isfinite(parameter)
                                    and all(math.isfinite(value) for value in point)):
                                values.update(maxDeviation=distance, maxDeviationPoint=point)
                    except Exception:
                        # Missing or malformed representations may prevent an
                        # independent distance calculation. Preserve OCCT's
                        # actual status without guessing a discrepancy.
                        pass
            measurements[key] = values
            return values

        def add(statuses, native, context=None):
            nonlocal omitted
            entity = reference(native)
            parent = reference(context) if context is not None else None
            for status in statuses:
                if status == BRepCheck_NoError:
                    continue
                name = getattr(status, "name", str(status).rsplit(".", 1)[-1])
                key = (entity["kind"], entity["index"], name,
                       parent["kind"] if parent else None, parent["index"] if parent else None)
                if key in seen:
                    continue
                seen.add(key)
                if len(failures) >= MAX_VALIDATION_FAILURES:
                    omitted += 1
                    continue
                item = {"status": name, "entity": entity}
                if parent is not None:
                    item["context"] = parent
                item.update(measures(native, context, entity, parent))
                failures.append(item)

        for kind, _ in kinds:
            native_map = maps[kind]
            for index in range(1, native_map.Extent() + 1):
                native = native_map.FindKey(index)
                result = analyzer.Result(native)
                if result is None:
                    continue
                add(result.Status(), native)
                result.InitContextIterator()
                while result.MoreShapeInContext():
                    add(result.StatusOnShape(), native, result.ContextualShape())
                    result.NextShapeInContext()
    except Exception as error:
        diagnostic["collectionError"] = f"Could not collect all OpenCascade statuses: {type(error).__name__}: {error}"[:1000]
    diagnostic["omittedFailures"] = omitted

    def label(entity):
        text = f"{entity['kind']}[{entity['index']}]"
        if entity.get("owners"):
            text += " (" + ", ".join(f"solid[{owner['solidIndex']}]/{entity['kind']}[{owner['localIndex']}]"
                                     for owner in entity["owners"]) + ")"
        return text

    lines = ["OpenCascade geometry validation failed.",
             f"Geometry scope: {scope}; all topology indices are zero-based and refer only to this geometry."]
    if input_asset:
        lines.append("Input geometry: " + json.dumps(input_asset, ensure_ascii=False, sort_keys=True))
    if scope == "step_readback":
        lines.append("STEP readback indices must not be used as selections in the original design.")
    for failure in failures:
        line = f"{failure['status']}: {label(failure['entity'])}"
        if failure.get("context"):
            line += f" in {label(failure['context'])}"
        if failure.get("bounds"):
            line += "; bounds (mm): [" + ", ".join(f"{value:.9g}" for value in failure["bounds"]) + "]"
        if "tolerance" in failure:
            line += f"; edge tolerance: {failure['tolerance']:.9g} mm"
        if "maxDeviation" in failure:
            line += f"; max curve-on-surface discrepancy: {failure['maxDeviation']:.9g} mm"
            line += " at [" + ", ".join(f"{value:.9g}" for value in failure["maxDeviationPoint"]) + "] mm"
        lines.append(line)
    if omitted:
        lines.append(f"{omitted} additional failure statuses omitted.")
    if not failures:
        lines.append("OpenCascade returned an invalid result without an available per-entity failure status.")
    if diagnostic.get("collectionError"):
        lines.append(diagnostic["collectionError"])
    return ModelError("\n".join(lines), diagnostic=diagnostic)


def write_error_report(error, output):
    """Publish bounded failure details independently of diagnostic log tails."""
    import tempfile
    report = {"formatVersion": 1, "stage": "worker", **(getattr(error, "diagnostic", None) or {}),
              "failureKind": failure_kind(error),
              "message": str(error).encode("utf-8")[:32_000].decode("utf-8", errors="ignore")}
    data = json.dumps(report, separators=(",", ":"), allow_nan=False, ensure_ascii=False).encode("utf-8")
    if len(data) > 65_536:
        report.pop("failures", None)
        report["detailsOmitted"] = True
        data = json.dumps(report, separators=(",", ":"), allow_nan=False, ensure_ascii=False).encode("utf-8")
    while len(data) > 65_536 and report["message"]:
        # Control characters need escaping even without ASCII-only encoding.
        # Bound the serialized bytes, not just the source string's length.
        report["message"] = report["message"][:len(report["message"]) // 2]
        report["messageTruncated"] = True
        data = json.dumps(report, separators=(",", ":"), allow_nan=False, ensure_ascii=False).encode("utf-8")
    output.mkdir(parents=True, exist_ok=True)
    path = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".error-", dir=output, delete=False) as stream:
            path = Path(stream.name)
            stream.write(data)
        path.replace(output / "error.json")
    finally:
        if path is not None:
            path.unlink(missing_ok=True)


def validate_shape(shape, preview_stats=None, exact=True):
    """Validate exact, closed geometry before meshing or accepting a build.

    `exact` False leaves the exact topology and shell checks to a separate
    verification of the same native solid; the remaining checks still run.
    """
    from OCP.BRepCheck import BRepCheck_Analyzer, BRepCheck_Shell, BRepCheck_NoError
    if preview_stats is not None:
        preview_stats.clear()
    if shape.isNull():
        raise ModelError("operation produced invalid geometry")
    if not _only_solids(shape):
        raise ModelError("Design must contain only closed solids; remove construction wires, faces and tools from result.")
    solids = _shape_entities(shape, "Solid")
    if not solids:
        raise ModelError("operation produced no solid; check dimensions and overlapping inputs")
    if len(solids) > 4_096:
        raise ModelError("geometry exceeds the 4,096 solid limit; simplify the design")
    apply_geometry_tolerance(shape)
    face_count = len(_shape_entities(shape, "Face"))
    if exact and not _validated_replay.get():
        # CadQuery's isValid() uses finitely sampled curve/surface checks. Exact
        # checking catches parameterization defects that those samples can miss.
        analyzer = BRepCheck_Analyzer(shape.wrapped, True, False, True)
        if not analyzer.IsValid():
            raise geometry_validation_error(shape, analyzer)
        for shell in _shape_entities(shape, "Shell"):
            check = BRepCheck_Shell(shell.wrapped)
            if check.Closed() != BRepCheck_NoError or check.Orientation() != BRepCheck_NoError:
                raise ModelError("Design contains an open or inconsistently oriented solid shell.")
    solid_bounds, coordinates = _preview_bounds(solids)
    properties = [part_metadata(solid, index, bounds=solid_bounds[index]) for index, solid in enumerate(solids)]
    if any(not math.isfinite(part["volume"]) or part["volume"] <= 1e-10 for part in properties):
        raise ModelError("Every design part must have a positive finite volume.")
    volume = shape.Volume()
    if not math.isfinite(volume) or volume <= 1e-10:
        raise ModelError("operation produced no solid; check dimensions and overlapping inputs")
    area = shape.Area()
    if not math.isfinite(area) or area <= 0:
        raise ModelError("operation produced an invalid surface area")
    if any(not math.isfinite(v) or abs(v) > LIMIT * 10 for v in coordinates):
        raise ModelError("geometry exceeds the design size limit")
    if preview_stats is not None:
        # A single-use handoff from final validation straight to extraction.
        # Do not attach these values to shapes: user programs can mutate native
        # geometry in place, invalidating any automatically retained statistics.
        preview_stats.update(shape=shape, solids=solids, solidBounds=solid_bounds,
                             solidProperties=properties, bounds=coordinates,
                             volume=volume, area=area, faces=face_count)
    return shape


def _only_solids(shape):
    if shape.ShapeType() in {"Solid", "CompSolid"}:
        return True
    if shape.ShapeType() == "Compound":
        children = list(shape)
        return bool(children) and all(_only_solids(child) for child in children)
    return False


def validate_step_roundtrip(shape, cq, step_path, preview_stats=None):
    """Reject lossy STEP conversion before publishing a candidate's preview.

    Compare unordered physical parts, never native feature indices: STEP can
    reorder bodies or split faces. Keep the original native shape for picking,
    measurements and final commit, and share measurements only within this
    build's explicit single-use preview handoff.
    """
    from bisect import bisect_left, bisect_right
    expected = preview_stats
    if expected is None:
        expected = {}
        validate_shape(shape, preview_stats=expected)
    if expected.get("shape") is not shape:
        raise ModelError("STEP verification measurements belong to a different build.")
    actual = {}
    try:
        if not 0 < Path(step_path).stat().st_size <= MAX_GEOMETRY_BYTES:
            raise ModelError("The STEP design is empty or exceeds 512 MB.")
        with validation_scope("step_readback"):
            import_step(step_path, cq, preview_stats=actual)
    except Exception as error:
        raise ModelError(f"Design failed STEP verification before acceptance: {error}",
                         diagnostic=getattr(error, "diagnostic", None) or {
                             "stage": "step_readback", "geometryScope": "step_readback"}) from error
    before, after = expected["solidProperties"], actual["solidProperties"]
    if len(before) != len(after):
        raise ModelError(f"Design failed STEP verification: expected {len(before)} closed solids, received {len(after)}.",
                         diagnostic={"stage": "step_geometry_comparison", "geometryScope": "step_readback",
                                     "expectedSolids": len(before), "receivedSolids": len(after)})
    # Bounds and centroids use a linear tolerance relative to each part's own
    # size, independent of world-space translation. Measures use a small
    # relative allowance for analytic surface conversion and integration.
    def tolerance(part):
        bounds = part["bounds"]
        return max(GEOMETRY_TOLERANCE_MM,
                   1e-6 + math.hypot(*(bounds[i + 3] - bounds[i] for i in range(3))) * 1e-7)

    ordered = sorted(before, key=lambda part: part["bounds"][0])
    starts = [part["bounds"][0] for part in ordered]
    maximum_tolerance = max(map(tolerance, before))
    def candidates(part):
        return range(bisect_left(starts, part["bounds"][0] - maximum_tolerance),
                     bisect_right(starts, part["bounds"][0] + maximum_tolerance))

    def equivalent(original, part):
        linear = tolerance(original)
        return (all(abs(a - b) <= linear for key in ("bounds", "centroid")
                    for a, b in zip(original[key], part[key]))
                and all(math.isclose(original[key], part[key], rel_tol=1e-6, abs_tol=1e-7)
                        for key in ("volume", "area")))

    owners, assigned = {}, {}
    for source_index, part in enumerate(after):
        # Prefer a free equivalent part. Near-coincident parts can have
        # overlapping tolerance ranges, so a greedy match alone is not enough:
        # an augmenting path must be able to reassign earlier matches.
        available = next((index for index in candidates(part)
                          if index not in owners and equivalent(ordered[index], part)), None)
        if available is not None:
            owners[available], assigned[source_index] = source_index, available
            continue
        from collections import deque
        pending, parents, visited = deque([source_index]), {}, {source_index}
        while pending and available is None:
            current = pending.popleft()
            for index in candidates(after[current]):
                if index in parents or not equivalent(ordered[index], after[current]):
                    continue
                parents[index] = current
                if index not in owners:
                    available = index
                    break
                previous = owners[index]
                if previous not in visited:
                    visited.add(previous)
                    pending.append(previous)
        if available is None:
            part = after[source_index]
            raise ModelError("Design failed STEP verification: conversion changed a part's volume, surface area, dimensions or position. "
                             f"No original part matches STEP readback solid[{source_index}]: "
                             f"volume={part['volume']:.12g} mm³, area={part['area']:.12g} mm², "
                             f"bounds={part['bounds']}, centroid={part['centroid']}.",
                             diagnostic={"stage": "step_geometry_comparison", "geometryScope": "step_readback",
                                         "unmatchedReadbackSolid": source_index, "readbackProperties": part})
        while available is not None:
            current = parents[available]
            previous = assigned.get(current)
            owners[available], assigned[current] = current, available
            available = previous


def validate_part_color(color):
    """Validate the opaque sRGB metadata shared by previews and saved parts."""
    if (not isinstance(color, dict) or set(color) != {"red", "green", "blue"}
            or any(isinstance(value, bool) or not isinstance(value, (int, float))
                   or not 0 <= value <= 1 or not math.isfinite(value) for value in color.values())):
        raise ModelError("Part colors must contain finite sRGB red, green and blue values between 0 and 1.")
    return color


def assembly_part_color(color):
    if color is None:
        return None
    import cadquery as cq
    if not isinstance(color, cq.Color):
        raise ModelError("Assembly colors must be CadQuery Color values.")
    # CadQuery returns Quantity_TOC_sRGB from toTuple, not OCCT's linear RGB.
    red, green, blue, alpha = color.toTuple()
    if not math.isfinite(alpha) or alpha != 1:
        raise ModelError("LAD supports only opaque assembly colors; set alpha to 1.")
    return validate_part_color({"red": red, "green": green, "blue": blue})


def print_down_direction(value):
    """Validate a pinned 3D printing direction: the world-space outward
    direction that faces the build plate."""
    if (not isinstance(value, (list, tuple)) or len(value) != 3
            or any(isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item)
                   for item in value)):
        raise ModelError("Assembly metadata lad_print_down must be three finite numbers.")
    length = math.sqrt(sum(float(item) * float(item) for item in value))
    if length < 1e-9:
        raise ModelError("Assembly metadata lad_print_down must be a nonzero direction.")
    return [float(item) / length for item in value]


def assembly_parts(assembly, shape, print_down=None):
    """Keep named assembly structure mapped to the exported solid ordering.

    Locations are composed in the same parent-before-child order as CadQuery's
    Assembly iterator. Shape identity includes the native location, so repeated
    instances of one shape map to their own bodies without comparing geometry
    or changing the model's coordinates. Pinned printing directions are
    inherited like colors and recorded per solid in `print_down`.
    """
    import cadquery as cq
    solids = _shape_entities(shape, "Solid")
    by_hash = {}
    for index, solid in enumerate(solids):
        by_hash.setdefault(solid.hashCode(), []).append(index)
    claimed = set()
    name_counts, explicit_ids = {}, set()

    def supplied_name(node):
        name = node.name.strip()
        # CadQuery generates UUID names when none was supplied. Those change
        # on every execution and must not become labels or persistent IDs.
        return "" if re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", name) else name

    for _, node in assembly.traverse():
        name = supplied_name(node)
        if node is not assembly and name:
            name_counts[name] = name_counts.get(name, 0) + 1
        identity = node.metadata.get("lad_id")
        if identity is not None:
            if not isinstance(identity, str) or not identity.strip():
                raise ModelError("Assembly metadata lad_id must be a nonempty string.")
            if identity in explicit_ids:
                raise ModelError(f"Assembly metadata lad_id must be unique: {identity!r}.")
            explicit_ids.add(identity)
    generated_ids = set(explicit_ids)

    def generated_id(candidate):
        # Explicit IDs are used verbatim so user-created folder IDs can be
        # reused in new model programs. Keep generated fallback namespaces
        # from colliding with any such user-supplied identity.
        while candidate in generated_ids:
            candidate = f"generated:{candidate}"
        generated_ids.add(candidate)
        return candidate

    def visit(node, parent_location, path, parent_color=None, parent_down=None):
        location = parent_location * node.loc
        color = assembly_part_color(node.color) if node.color is not None else parent_color
        down = (print_down_direction(node.metadata["lad_print_down"])
                if node.metadata.get("lad_print_down") is not None else parent_down)
        name = supplied_name(node)
        if node.metadata.get("lad_id") is not None:
            identity = node.metadata["lad_id"]
        elif node is assembly:
            identity = generated_id("root")
        elif name and name_counts[name] == 1:
            identity = generated_id(f"name:{name}")
        else:
            identity = generated_id("path:" + json.dumps(path, ensure_ascii=False, separators=(",", ":")))
        indices = []
        for own_shape in node.shapes:
            for solid in _shape_entities(own_shape.moved(location), "Solid"):
                matches = by_hash.get(solid.hashCode(), [])
                index = next((i for i in matches if solid.isSame(solids[i])), None)
                if index is None:
                    raise ModelError("Could not match an assembly part to the final design.")
                # OCCT's solid map collapses coincident references to the same
                # native solid. Give such a body one owner, matching its mesh.
                if index not in claimed:
                    claimed.add(index)
                    indices.append(index)
                    if down is not None and print_down is not None:
                        print_down[index] = down
        children = []
        is_folder = identity.startswith(("user-folder:", "folder:"))
        if len(indices) > 1 or (indices and (node.children or is_folder)):
            # Imported compounds often represent a PCB or another assembly
            # without body names. Keep that logical folder while exposing
            # every contained solid for independent selection and visibility.
            for number, index in enumerate(indices):
                body = {"id": generated_id("body:" + json.dumps([identity, number], ensure_ascii=False, separators=(",", ":"))),
                        "name": (name or "Body") if len(indices) == 1 else f"Part {number + 1}",
                        "solidIndices": [index], "children": None}
                if color is not None:
                    body["color"] = color
                children.append(body)
            indices = []
        for index, child in enumerate(node.children):
            part = visit(child, location, path + [supplied_name(child) or f"@{index}"], color, down)
            if part is not None:
                children.append(part)
        if not indices and not children:
            return None
        if not name:
            name = "Parts" if children else f"Part {indices[0] + 1}"
        part = {"id": identity, "name": name, "solidIndices": indices,
                "children": children if children or is_folder else None}
        if indices and color is not None:
            part["color"] = color
        return part

    root = visit(assembly, cq.Location(), [])
    if claimed != set(range(len(solids))):
        raise ModelError("Assembly parts do not cover every solid in the final design.")
    # A default empty Assembly is just a container for its named children.
    if root and not supplied_name(assembly) and not assembly.shapes and not assembly.metadata.get("lad_id"):
        return root["children"]
    return [root] if root else []


def compound_assembly_from_aliases(shape, namespace, cq):
    """Infer preview labels from exact shape aliases in compound programs.

    This auxiliary Assembly is never exported or used to replace the result.
    Native identity, including location, is the only matching criterion; no
    guessed geometry or geometric proximity is used to associate a variable.
    """
    if shape.ShapeType() != "Compound":
        return None
    ignored = {"result", "imported_model", "tmp", "temp", "shape", "solid", "s", "value", "tool", "cutter"}
    preferred = {"base": 0, "lid": 1, "pcb": 2, "board": 3}
    aliases = {}
    for name, value in namespace.items():
        if name.startswith("_") or name.lower() in ignored or name.lower().startswith(("tmp_", "temp_", "tool_")):
            continue
        if isinstance(value, cq.Workplane):
            values = value.vals()
            value = values[0] if len(values) == 1 else None
        if isinstance(value, cq.Shape) and not value.isNull():
            aliases.setdefault(value.hashCode(), []).append((name, value))

    def alias_for(child):
        matches = [(name, value) for name, value in aliases.get(child.hashCode(), []) if child.isSame(value)]
        return min(matches, key=lambda pair: (preferred.get(pair[0].lower(), 4), pair[0]))[0] if matches else None

    solids = _shape_entities(shape, "Solid")
    solid_indices = {}
    for index, solid in enumerate(solids):
        solid_indices.setdefault(solid.hashCode(), []).append((index, solid))
    used_ids = set()
    found_alias = False

    def identity(candidate, path):
        if candidate in used_ids:
            candidate = "legacy-instance:" + json.dumps(path, separators=(",", ":"))
        used_ids.add(candidate)
        return candidate

    def make_node(child, path, label=None, identifier=None, keep_compound=False):
        nonlocal found_alias
        alias = alias_for(child)
        found_alias = found_alias or alias is not None
        child_solids = _shape_entities(child, "Solid")
        first = next(index for index, solid in solid_indices[child_solids[0].hashCode()]
                     if child_solids[0].isSame(solid))
        alias_label = alias.replace("_", " ") if alias else ""
        name = label or (alias_label[:1].upper() + alias_label[1:] if alias else f"Part {first + 1}")
        part_id = identity(identifier or (f"legacy:{alias}" if alias else
                           f"solid/{first}" if len(child_solids) == 1 else
                           "legacy-group:" + json.dumps(path, separators=(",", ":"))), path)
        if child.ShapeType() == "Compound" and not keep_compound:
            node = cq.Assembly(name=name, metadata={"lad_id": part_id})
            for index, nested in enumerate(child):
                node.add(make_node(nested, path + [index]))
            return node
        return cq.Assembly(child, name=name, metadata={"lad_id": part_id})

    children = list(shape)
    child_names = [alias_for(child) for child in children]
    recognized = {name.lower(): index for index, name in enumerate(child_names) if name and name.lower() in preferred}
    case_indices = set()
    root = cq.Assembly()
    if {"base", "lid"} <= recognized.keys() and ("pcb" in recognized or "board" in recognized):
        case = cq.Assembly(name="Case", metadata={"lad_id": "case"})
        used_ids.add("case")
        for name in ("base", "lid"):
            index = recognized[name]
            case_indices.add(index)
            case.add(make_node(children[index], [index], name.capitalize(), f"case-{name}", keep_compound=True))
        root.add(case)
    for index, child in enumerate(children):
        if index in case_indices:
            continue
        if case_indices and child_names[index] and child_names[index].lower() in {"pcb", "board"}:
            root.add(make_node(child, [index], "PCB", "pcb", keep_compound=True))
        else:
            root.add(make_node(child, [index]))
    return root if found_alias else None


class LADBuildMode:
    """The program's `lad` value. `lad.print` is true only while building the
    design's 3D printing version. A program that never reads it has no
    distinct printing version, so its ordinary geometry serves both."""
    __slots__ = ("_printing", "printing_read")

    def __init__(self, printing):
        self._printing = bool(printing)
        self.printing_read = False

    @property
    def print(self):
        self.printing_read = True
        return self._printing

    def __repr__(self):
        return "lad"


def build_script(script, cq, source_asset=None, input_assets=None, preview_stats=None, printing=False,
                 validated_inputs=None, exact=True):
    """Run ordinary Python with the installed CadQuery/OpenCascade APIs.

    This is intentionally not a Python-language security boundary. The native
    app applies a macOS process sandbox restricting files, subprocesses and
    networking. CLI callers must apply equivalent isolation for untrusted code.
    `validated_inputs` reads and keeps validated copies of imported inputs;
    `exact` False defers the result's exact checks (see validate_shape).
    """
    import resource
    # Bound individual files (including stderr) before generated Python runs.
    # The hard limit cannot be raised again by the model's process.
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    ceiling = MAX_GEOMETRY_BYTES
    if hard != resource.RLIM_INFINITY:
        ceiling = min(ceiling, hard)
    resource.setrlimit(resource.RLIMIT_FSIZE, (ceiling, ceiling))
    import numpy as np
    build_mode = LADBuildMode(printing)
    namespace = {"cq": cq, "math": math, "np": np, "lad": build_mode, "__name__": "__lad_model__"}
    namespace["imported_assets"] = {}
    validated_inputs = validated_inputs or ValidatedInputs()
    for asset, path in input_assets or []:
        with validation_scope("input_asset", {"id": asset["id"], "name": asset["name"], "format": asset["format"]}):
            namespace["imported_assets"][asset["id"]] = validated_inputs.load(
                path.stem, cq, lambda path=path, asset=asset: import_input_asset(path, asset["format"], cq))
    if source_asset is not None:
        import stat
        try:
            info = source_asset.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
                raise ModelError("The imported STEP asset must be a regular private file of at most 512 MB.")
            with validation_scope("source_step", {"name": source_asset.name, "format": "step"}):
                imported = validated_inputs.load("source", cq, lambda: import_step(source_asset, cq))
            namespace["imported_model"] = imported
        except ModelError:
            raise
        except Exception as error:
            raise ModelError(f"Could not read the imported STEP geometry: {error}") from error
    try:
        compiled = compile(script, "<LAD model>", "exec")
        exec(compiled, namespace, namespace)
    except BaseException as error:
        # Keep SyntaxError/traceback line numbers useful to the Codex repair
        # loop, including SystemExit, which should never terminate the worker.
        line = getattr(error, "lineno", None)
        trace = error.__traceback__
        while trace is not None:
            if trace.tb_frame.f_code.co_filename == "<LAD model>":
                line = trace.tb_lineno
            trace = trace.tb_next
        location = f" at line {line}" if line else ""
        raise ModelError(f"Python design{location}: {type(error).__name__}: {error}") from error
    if "result" not in namespace:
        raise ModelError("Python design must assign its final Shape, Workplane or Assembly to result.")
    result = namespace["result"]
    from OCP.TopoDS import TopoDS_Shape
    if isinstance(result, TopoDS_Shape):
        result = cq.Shape.cast(result)
    assembly = result if isinstance(result, cq.Assembly) else None
    if assembly is not None:
        result = result.toCompound()
    elif isinstance(result, cq.Workplane):
        values = result.vals()
        if not values or any(not isinstance(value, cq.Shape) for value in values):
            raise ModelError("Python design result Workplane must contain solid CAD shapes.")
        result = values[0] if len(values) == 1 else cq.Compound.makeCompound(values)
    if not isinstance(result, cq.Shape):
        raise ModelError("Python design result must be a CadQuery Shape, Workplane or Assembly.")
    if not _only_solids(result):
        raise ModelError("Python design result must contain only closed solids; remove construction wires, faces and tools from result.")
    validate_shape(result, preview_stats=preview_stats, exact=exact)
    result._lad_print_version = build_mode.printing_read
    if assembly is not None:
        print_down = {}
        result._lad_parts = assembly_parts(assembly, result, print_down)
        result._lad_print_down = print_down
        if "lad_motion" in assembly.metadata:
            result._lad_assembly_motion = validate_assembly_motion(assembly.metadata["lad_motion"], result._lad_parts)
    else:
        # Explicit Assemblies have a strict naming contract. For compound
        # programs, exact shape aliases provide optional preview labels while
        # ambiguous variables leave the generic per-solid labels intact.
        try:
            inferred = compound_assembly_from_aliases(result, namespace, cq)
            if inferred is not None:
                result._lad_parts = assembly_parts(inferred, result)
        except Exception:
            pass
    return result


def build_shape(spec, threads=1, asset_directory=None, preview_stats=None, validated_copies=None, exact=True):
    """`validated_copies` is the directory receiving copies of newly imported inputs."""
    validate_spec(spec)
    import cadquery as cq
    configure_threads(threads)
    source_asset = None
    if spec.get("sourceAsset"):
        if asset_directory is None:
            raise ModelError("The imported STEP asset directory is unavailable.")
        source_asset = Path(asset_directory) / "source.step"
    inputs = spec.get("inputAssets", [])
    if inputs and asset_directory is None:
        raise ModelError("The imported geometry asset directory is unavailable.")
    staged = [(asset, Path(asset_directory) / asset["path"]) for asset in inputs]
    copies = {Path(name).name.removesuffix(VALIDATED_COPY_SUFFIX): Path(asset_directory) / name
              for name in [spec.get("sourceValidatedBREP")] + [asset.get("validatedBREP") for asset in inputs] if name}
    return build_script(spec["script"], cq, source_asset, staged, preview_stats=preview_stats,
                        printing=spec.get("print", False),
                        validated_inputs=ValidatedInputs(copies, None if validated_copies is None else Path(validated_copies)),
                        exact=exact)


VALIDATED_COPY_SUFFIX = ".validated.brep"


class ValidatedInputs:
    """Session copies of imported inputs, as this worker imported and validated them.

    Translating and exactly validating an unchanged STEP or mesh input again in
    every build of a task repeats the same work. The app stages a native copy
    of each input that an earlier build of this worker and runtime validated,
    beside its unchanged original bytes, and keeps each new copy written here.
    Copies are written before the program runs, so they hold the shapes a
    program receives rather than anything it changes afterwards. A copy that
    cannot be read falls back to importing the original.
    """

    def __init__(self, staged=None, directory=None):
        self.staged, self.directory = staged or {}, directory

    def load(self, name, cq, read):
        copy = self.staged.get(name)
        if copy is not None:
            try:
                return read_validated_copy(copy, cq)
            except Exception:
                pass
        shape = read()
        if copy is None and self.directory is not None:
            path = self.directory / f"{name}{VALIDATED_COPY_SUFFIX}"
            try:
                write_brep(shape, path)
            except Exception:
                # A copy only saves later work; never fail this build for it.
                path.unlink(missing_ok=True)
        return shape


def read_validated_copy(path, cq):
    """Read an app-staged copy of an input this worker version already validated."""
    import stat
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
        raise ModelError("A validated input copy must be a regular private file of at most 512 MB.")
    shape = _read_brep_file(path, cq, "validated input copy")
    if shape.isNull() or not _only_solids(shape) or not 0 < len(_shape_entities(shape, "Solid")) <= 4_096:
        raise ModelError("The validated input copy does not contain closed solids.")
    return shape


def feature_id(kind, solid_index, local_index):
    return {"kind": kind, "solidIndex": solid_index, "localIndex": local_index}


def exact_bounds(shape):
    """Use analytic geometry, never the display tessellation, for dimensions."""
    from OCP.Bnd import Bnd_Box
    from OCP.BRepBndLib import BRepBndLib
    box = Bnd_Box()
    BRepBndLib.AddOptimal_s(shape.wrapped, box, False, False)
    return list(box.Get())


def _preview_bounds(solids):
    """Measure each solid once and reuse the union for whole-design bounds."""
    solid_bounds = [exact_bounds(solid) for solid in solids]
    bounds = [min(item[axis] for item in solid_bounds) for axis in range(3)] + [
        max(item[axis] for item in solid_bounds) for axis in range(3, 6)]
    return solid_bounds, bounds


def edge_metadata(edge, solid_index, local_index, polyline):
    from OCP.BRepAdaptor import BRepAdaptor_Curve
    item = {"id": feature_id("edge", solid_index, local_index),
            "type": edge.geomType(), "length": edge.Length(), "polyline": polyline,
            "startPoint": list(edge.startPoint().toTuple()), "endPoint": list(edge.endPoint().toTuple()),
            "closed": edge.IsClosed()}
    curve = BRepAdaptor_Curve(edge.wrapped)
    if item["type"] == "LINE":
        item["direction"] = list(curve.Line().Direction().Coord())
    elif item["type"] == "CIRCLE":
        circle = curve.Circle()
        item.update(radius=circle.Radius(), diameter=2 * circle.Radius(),
                    center=list(circle.Location().Coord()), axis=list(circle.Axis().Direction().Coord()),
                    sweepDegrees=abs(curve.LastParameter() - curve.FirstParameter()) * 180 / math.pi)
    elif item["type"] == "ELLIPSE":
        ellipse = curve.Ellipse()
        item.update(majorRadius=ellipse.MajorRadius(), minorRadius=ellipse.MinorRadius(),
                    center=list(ellipse.Location().Coord()), axis=list(ellipse.Axis().Direction().Coord()))
    return item


def _shape_measurements(shape, volume=False):
    """Compute an exact measure and its centroid with one native integral.

    These are the same default OpenCascade calls used separately by
    CadQuery's Area/Volume and Center methods. Keep their default flags so
    exact surfaces, shared boundaries and orientations retain their existing
    semantics; display triangulation is never a measurement approximation.
    """
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps
    properties = GProp_GProps()
    calculate = BRepGProp.VolumeProperties_s if volume else BRepGProp.SurfaceProperties_s
    calculate(shape.wrapped, properties)
    return properties.Mass(), list(properties.CentreOfMass().Coord())


def part_metadata(solid, solid_index, bounds=None):
    volume, centroid = _shape_measurements(solid, volume=True)
    return {"solidIndex": solid_index, "area": solid.Area(), "volume": volume,
            "bounds": exact_bounds(solid) if bounds is None else bounds, "centroid": centroid}


def _wire_length(wire):
    """Keep CadQuery's curve integration without its one-edge map iterator.

    Summing individual edge lengths is not equivalent for all trimmed or
    singular wires. Use the identical single-curve/composite-curve choice and
    native integrator as Wire.Length, retaining its boundary semantics.
    """
    from OCP.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_CompCurve
    from OCP.GCPnts import GCPnts_AbscissaPoint
    from OCP.ShapeAnalysis import ShapeAnalysis_Wire
    analysis = ShapeAnalysis_Wire()
    analysis.Load(wire.wrapped)
    if analysis.NbEdges() == 1:
        curve = BRepAdaptor_Curve(_shape_entities(wire, "Edge")[-1].wrapped)
    else:
        curve = BRepAdaptor_CompCurve(wire.wrapped)
    return GCPnts_AbscissaPoint.Length_s(curve)


def face_metadata(face, solid_index, local_index):
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    area, center = _shape_measurements(face)
    item = {"id": feature_id("face", solid_index, local_index), "type": face.geomType(),
            "area": area, "center": center,
            "perimeter": sum(_wire_length(wire) for wire in _shape_entities(face, "Wire"))}
    surface = BRepAdaptor_Surface(face.wrapped)
    if item["type"] == "PLANE":
        item["normal"] = list(face.normalAt().toTuple())
    elif item["type"] == "CYLINDER":
        cylinder = surface.Cylinder()
        item.update(radius=cylinder.Radius(), diameter=2 * cylinder.Radius(), axis=list(cylinder.Axis().Direction().Coord()))
    elif item["type"] == "SPHERE":
        item.update(radius=surface.Sphere().Radius(), diameter=2 * surface.Sphere().Radius())
    elif item["type"] == "TORUS":
        torus = surface.Torus()
        item.update(majorRadius=torus.MajorRadius(), minorRadius=torus.MinorRadius(),
                    axis=list(torus.Axis().Direction().Coord()))
    elif item["type"] == "CONE":
        cone = surface.Cone()
        item.update(axis=list(cone.Axis().Direction().Coord()), semiAngleDegrees=abs(cone.SemiAngle()) * 180 / math.pi)
    return item


class _PreviewMeshEdge:
    """A solid's edge as its adjacent face meshes found it."""
    __slots__ = ("native", "polyline", "seam")

    def __init__(self, native, seam):
        self.native, self.polyline, self.seam = native, None, seam


def _preview_mesh_edge(edge, mesh_edges):
    """Find an edge's face-mesh record. Native hashes ignore orientation and
    can collide; IsSame resolves collisions and keeps located instances apart."""
    for record in mesh_edges.get(hash(edge.wrapped), ()):
        if record.native.IsSame(edge.wrapped):
            return record
    return None


def _preview_edge_polyline(edge, mesh_polyline, tolerance):
    """Use the face mesher's boundary, with analytic sampling only as fallback."""
    if mesh_polyline is not None:
        return mesh_polyline
    count = 2 if edge.geomType() == "LINE" else min(256, max(16, math.ceil(edge.Length() / max(tolerance * 8, 0.1))))
    sampled, _ = edge.sample(count)
    polyline = [list(point.toTuple()) for point in sampled]
    # CadQuery omits the duplicate final point for closed curves. Both the
    # display segments and topology polyline need the last-to-first segment.
    if edge.IsClosed() and len(polyline) > 1 and polyline[-1] != polyline[0]:
        polyline.append(polyline[0].copy())
    return polyline


def _preview_seam_vertices(solid, seams):
    """Return local indices of a solid's vertices that bound only its seams.

    A sphere's poles or a cone's apex mark nothing visible once their seams
    are hidden. Degenerate pole edges do not count; any other edge keeps its
    endpoints selectable. Look up only the seams' endpoints in native maps.
    """
    from OCP.BRep import BRep_Tool
    from OCP.TopAbs import TopAbs_EDGE, TopAbs_VERTEX
    from OCP.TopExp import TopExp
    from OCP.TopoDS import TopoDS
    from OCP.TopTools import TopTools_IndexedDataMapOfShapeListOfShape, TopTools_IndexedMapOfShape
    vertices = TopTools_IndexedMapOfShape()
    TopExp.MapShapes_s(solid.wrapped, TopAbs_VERTEX, vertices)
    ancestors = TopTools_IndexedDataMapOfShapeListOfShape()
    TopExp.MapShapesAndAncestors_s(solid.wrapped, TopAbs_VERTEX, TopAbs_EDGE, ancestors)
    hidden, checked = set(), set()
    for seam in seams:
        for vertex in (TopExp.FirstVertex_s(seam), TopExp.LastVertex_s(seam)):
            index = vertices.FindIndex(vertex)
            if not index or index in checked or not ancestors.Contains(vertex):
                continue
            checked.add(index)
            # The native list iterates begin-to-end without an exception.
            if not any(not BRep_Tool.Degenerated_s(TopoDS.Edge_s(edge)) and not any(edge.IsSame(other) for other in seams)
                       for edge in ancestors.FindFromKey(vertex)):
                hidden.add(index - 1)
    return hidden


def _preview_face_normals(face, poly, location):
    """Return outward lighting normals from the exact face, not mesh facets.

    OpenCascade computes these in C++ from the triangulation's UV nodes and
    underlying surface, including limiting normals at surface singularities.
    Its result is unoriented and local to the triangulation. Keep the native
    face boundaries so a sharp edge never averages its two surface normals.
    """
    from OCP.BRepLib import BRepLib_ToolTriangulatedShape
    from OCP.TopAbs import TopAbs_Orientation
    transform = location.Transformation()
    reverse = face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED
    # Imported/caller-supplied triangulations can already contain averaged
    # normals. ComputeNormals otherwise retains them without consulting UVs.
    poly.RemoveNormals()
    if poly.HasUVNodes():
        try:
            BRepLib_ToolTriangulatedShape.ComputeNormals_s(face.wrapped, poly)
        except Exception:
            # Recover only affected nodes below; do not replace an entire
            # curved face with polygon-derived normals after one failure.
            pass
    normals = [None] * poly.NbNodes()
    if poly.HasNormals():
        for index in range(1, poly.NbNodes() + 1):
            try:
                normal = poly.Normal(index).Transformed(transform)
                coordinates = list(normal.Coord())
                if all(math.isfinite(value) for value in coordinates):
                    normals[index - 1] = [-value for value in coordinates] if reverse else coordinates
            except Exception:
                pass
    missing = [index for index, normal in enumerate(normals) if normal is None]
    if not missing:
        return normals

    # A valid imported triangulation can lack UV nodes. Project its nodes to
    # the exact surface rather than smoothing the whole curved face. This is
    # deliberately a rare fallback; ordinary previews use the native C++ path.
    from OCP.BRep import BRep_Tool
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    from OCP.BRepLProp import BRepLProp_SLProps
    from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
    adaptor = BRepAdaptor_Surface(face.wrapped)
    properties = BRepLProp_SLProps(adaptor, 1, 1e-12)
    surface = BRep_Tool.Surface_s(face.wrapped) if not poly.HasUVNodes() else None
    for index in missing:
        try:
            if poly.HasUVNodes():
                uv = poly.UVNode(index + 1)
                u, v = uv.X(), uv.Y()
            else:
                point = poly.Node(index + 1).Transformed(transform)
                projection = GeomAPI_ProjectPointOnSurf(point, surface)
                if not projection.NbPoints():
                    continue
                u, v = projection.LowerDistanceParameters()
            properties.SetParameters(u, v)
            if properties.IsNormalDefined():
                coordinates = list(properties.Normal().Coord())
                if all(math.isfinite(value) for value in coordinates):
                    # BRepAdaptor_Surface already includes the face location.
                    normals[index] = [-value for value in coordinates] if reverse else coordinates
        except Exception:
            pass
    missing = [index for index, normal in enumerate(normals) if normal is None]
    if not missing:
        return normals

    # A cusp can genuinely have no unique surface normal. Bound the fallback
    # to its own incident facets, leaving every regular surface node exact.
    points = [poly.Node(index).Transformed(transform).Coord() for index in range(1, poly.NbNodes() + 1)]
    sums = [[0.0, 0.0, 0.0] for _ in points]
    for index in range(1, poly.NbTriangles() + 1):
        a, b, c = [node - 1 for node in poly.Triangle(index).Get()]
        ab = [points[b][axis] - points[a][axis] for axis in range(3)]
        ac = [points[c][axis] - points[a][axis] for axis in range(3)]
        cross = [ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0]]
        for node in (a, b, c):
            for axis in range(3):
                sums[node][axis] += -cross[axis] if reverse else cross[axis]
    for index in missing:
        length = math.hypot(*sums[index])
        if math.isfinite(length) and length > 1e-24:
            normals[index] = [value / length for value in sums[index]]
    for index in missing:
        if normals[index] is None:
            # An unused degenerate mesh node has no incident facets. Reuse
            # the closest defined normal on this face instead of a fixed axis.
            defined = [other for other, normal in enumerate(normals) if normal is not None]
            if not defined:
                raise ModelError("OpenCascade could not compute surface normals for the design preview.")
            nearest = min(defined, key=lambda other: math.dist(points[index], points[other]))
            normals[index] = normals[nearest].copy()
    return normals


class _PreviewMeshError(ValueError):
    def __init__(self, message, *, refine_surface=False):
        super().__init__(message)
        self.refine_surface = refine_surface


def _preview_patch_triangles(loop, points, normals, face, tolerance):
    """Close a small trim gap in physical space using its existing nodes.

    Straight chords of a curved boundary can cross in a distorted surface UV
    chart, even though their 3D polygon is simple. Never triangulate that gap
    in UV space, move its boundary, or flip an inward facet to hide it.
    """
    import numpy as np
    xyz = np.asarray([points[index] for index in loop], dtype=float)
    exact = np.asarray([normals[index] for index in loop], dtype=float)
    normal = exact.sum(axis=0)
    length = np.linalg.norm(normal)
    if not math.isfinite(length) or length <= 1e-12:
        raise _PreviewMeshError("a missing surface patch has ambiguous surface normals")
    normal /= length
    if not np.all(exact @ normal > 0.95):
        raise _PreviewMeshError("a missing surface patch is too curved for local triangulation")
    direction = xyz[1] - xyz[0]
    direction -= normal * np.dot(direction, normal)
    length = np.linalg.norm(direction)
    if not length > 1e-12:
        raise _PreviewMeshError("a missing surface patch has a degenerate boundary")
    direction /= length
    xy = np.stack([(xyz - xyz[0]) @ direction, (xyz - xyz[0]) @ np.cross(normal, direction)], axis=1)

    def cross(a, b, c):
        ab, ac = xy[b] - xy[a], xy[c] - xy[a]
        return float(ab[0] * ac[1] - ab[1] * ac[0])

    # The loop follows missing native boundary segments and closes opposite an
    # existing mesh edge. It must bound an outward patch, not overlapping ink.
    area = sum(xy[index, 0] * xy[(index + 1) % len(loop), 1] -
               xy[index, 1] * xy[(index + 1) % len(loop), 0] for index in range(len(loop)))
    if not area > 1e-16:
        raise _PreviewMeshError("a missing surface patch has inconsistent boundary orientation")
    # Reject self intersections before ear clipping. This is a local graph over
    # the exact mean normal; unrelated trim loops must never be bridged.
    for a in range(len(loop)):
        b = (a + 1) % len(loop)
        for c in range(a + 1, len(loop)):
            d = (c + 1) % len(loop)
            if len({a, b, c, d}) == 4 and cross(a, b, c) * cross(a, b, d) < 0 and cross(c, d, a) * cross(c, d, b) < 0:
                raise _PreviewMeshError("a missing surface patch has a crossing boundary")
    polygon, result = list(range(len(loop))), []
    while len(polygon) > 3:
        for position, b in enumerate(polygon):
            a, c = polygon[position - 1], polygon[(position + 1) % len(polygon)]
            if cross(a, b, c) <= 1e-16:
                continue
            if any(min(cross(a, b, q), cross(b, c, q), cross(c, a, q)) >= -1e-16
                   for q in polygon if q not in (a, b, c)):
                continue
            result.append([loop[a], loop[b], loop[c]])
            polygon.pop(position)
            break
        else:
            raise _PreviewMeshError("a missing surface patch could not be triangulated")
    result.append([loop[index] for index in polygon])
    for a, b, c in result:
        plane = np.cross(np.asarray(points[b]) - points[a], np.asarray(points[c]) - points[a])
        if np.dot(plane, np.asarray([normals[a], normals[b], normals[c]]).sum(axis=0)) <= 0:
            raise _PreviewMeshError("a repaired surface patch contains an inward triangle")
    projector = _SurfaceProjector(face)
    for triangle in result:
        corners = np.asarray([points[index] for index in triangle])
        samples = [corners.mean(axis=0)] + [(corners[index] + corners[(index + 1) % 3]) / 2 for index in range(3)]
        for sample in samples:
            distance = projector.lower_distance(sample)
            if distance is None or not distance <= tolerance:
                raise _PreviewMeshError("a repaired surface patch exceeds the display surface deflection")
    return result


class _SurfaceProjector:
    """One face's exact surface with a projector initialised on first use.

    Constructing GeomAPI_ProjectPointOnSurf for each point rebuilds its
    extrema sampling of the whole surface, which costs tens of milliseconds
    per point on a large B-spline. Init with the surface's natural bounds and
    default tolerance is the constructor's own configuration, so each
    projection finds the same global minimum, up to rounding.
    """
    __slots__ = ("surface", "_projector")

    def __init__(self, face):
        from OCP.BRep import BRep_Tool
        self.surface, self._projector = BRep_Tool.Surface_s(face.wrapped), None

    def lower_distance(self, point):
        """The global minimum distance to the surface, or None without a projection."""
        from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
        from OCP.gp import gp_Pnt
        if self._projector is None:
            projector = GeomAPI_ProjectPointOnSurf()
            projector.Init(self.surface, *self.surface.Bounds())
            self._projector = projector
        self._projector.Perform(gp_Pnt(*(float(value) for value in point)))
        return self._projector.LowerDistance() if self._projector.NbPoints() else None


def _preview_triangle_matches_surface(face, corners, uv, tolerance, distance_limit, projector=None):
    """Check suspect cells against their own surface and parameter chart.

    Callers checking several cells of one face share its `projector`.
    """
    try:
        projector = projector or _SurfaceProjector(face)
        surface = projector.surface
        # Sample both the boundary and interior. The parameter check also
        # guards against a projection onto an unrelated nearby surface branch.
        for first in range(5):
            for second in range(5 - first):
                weights = [first / 4, second / 4, (4 - first - second) / 4]
                point = [sum(weights[index] * corners[index][axis] for index in range(3)) for axis in range(3)]
                u, v = [sum(weights[index] * uv[index][axis] for index in range(3)) for axis in range(2)]
                expected = surface.Value(u, v).Coord()
                if (not all(math.isfinite(value) for value in [*point, *expected])
                        or math.dist(point, expected) > tolerance):
                    return False
                if distance_limit >= tolerance:
                    continue  # The corresponding surface point already proves this bound.
                distance = projector.lower_distance(point)
                if distance is None or not distance <= distance_limit:
                    return False
    except Exception:
        return False
    return True


def _preview_metric_triangles(points, normals, uv, triangles, boundary, sign):
    """Repair interior diagonals in batches without changing any node."""
    import numpy as np
    xyz, exact, uv = np.asarray(points), np.asarray(normals), np.asarray(uv)
    indices = np.array(triangles, dtype=np.int64, copy=True)
    threshold = -1e-8 / 3

    def raw_audit(cells):
        corners = xyz[cells]
        planes = np.cross(corners[..., 1, :] - corners[..., 0, :], corners[..., 2, :] - corners[..., 0, :])
        lengths = np.linalg.norm(planes, axis=-1)
        dots = np.divide((planes * exact[cells].mean(axis=-2)).sum(axis=-1), lengths,
                         out=np.zeros_like(lengths), where=lengths > 1e-20)
        return dots, lengths

    def signed(cells):
        corners = uv[cells]
        ab, ac = corners[..., 1, :] - corners[..., 0, :], corners[..., 2, :] - corners[..., 0, :]
        return sign * (ab[..., 0] * ac[..., 1] - ab[..., 1] * ac[..., 0])

    _, lengths = raw_audit(indices)
    if np.any((lengths > 1e-12) & (signed(indices) <= 0)):
        raise _PreviewMeshError("the triangulation contains inward surface triangles with reversed UV winding")
    # An encoded pair is exact for native node IDs; no coincident seam/pole
    # positions are merged. The preview node limit keeps these within int64.
    base = len(xyz)
    native_boundary = np.asarray(list(boundary), dtype=np.int64).reshape(-1, 2)
    boundary_keys = native_boundary.min(axis=1) * base + native_boundary.max(axis=1)
    for iteration in range(20):
        dots, lengths = raw_audit(indices)
        if not np.any((lengths > 1e-12) & (dots < threshold)):
            break
        # Build all ownership and proposal data in native array operations.
        # Calling a two-cell NumPy/native audit for every edge made large
        # sheared surfaces spend minutes in otherwise bounded repair passes.
        edges = np.stack((indices, np.roll(indices, -1, axis=1)), axis=-1).reshape(-1, 2)
        opposite = np.roll(indices, 1, axis=1).reshape(-1)
        keys = edges.min(axis=1) * base + edges.max(axis=1)
        order = np.argsort(keys, kind="stable")
        ordered = keys[order]
        starts = np.r_[0, np.flatnonzero(ordered[1:] != ordered[:-1]) + 1]
        counts = np.diff(np.r_[starts, len(ordered)])
        if np.any(counts > 2):
            raise _PreviewMeshError("the triangulation contains nonmanifold surface edges")
        paired = starts[counts == 2]
        first_edge, second_edge = order[paired], order[paired + 1]
        keep = ((first_edge // 3 != second_edge // 3)
                & ~np.isin(keys[first_edge], boundary_keys))
        first_edge, second_edge = first_edge[keep], second_edge[keep]
        first, second = first_edge // 3, second_edge // 3
        a, b = edges[first_edge].T
        if np.any(a != edges[second_edge, 1]) or np.any(b != edges[second_edge, 0]):
            raise _PreviewMeshError("the triangulation has inconsistent shared-edge directions")
        c, d = opposite[first_edge], opposite[second_edge]
        proposed_keys = np.minimum(c, d) * base + np.maximum(c, d)
        old_squared = ((xyz[a] - xyz[b]) ** 2).sum(axis=1)
        new_squared = ((xyz[c] - xyz[d]) ** 2).sum(axis=1)
        keep = ((c != d) & ~np.isin(proposed_keys, ordered[starts])
                & (np.sqrt(new_squared) < np.sqrt(old_squared) - 1e-10))
        a, b, c, d = a[keep], b[keep], c[keep], d[keep]
        first, second = first[keep], second[keep]
        proposed_keys, old_squared = proposed_keys[keep], old_squared[keep]
        proposed = np.stack((np.stack((c, a, d), axis=1), np.stack((c, d, b), axis=1)), axis=1)
        keep = np.all(signed(proposed) > 1e-16, axis=1)
        proposed, first, second = proposed[keep], first[keep], second[keep]
        proposed_keys, old_squared = proposed_keys[keep], old_squared[keep]
        new_dots, new_lengths = raw_audit(proposed)
        old_bad = (dots[first] < threshold).astype(np.int8) + (dots[second] < threshold)
        keep = (np.all(new_lengths > 1e-12, axis=1)
                & (np.count_nonzero(new_dots < threshold, axis=1) <= old_bad)
                & (new_dots.min(axis=1) > np.minimum(dots[first], dots[second]) + 1e-6))
        eligible = np.flatnonzero(keep)
        eligible = eligible[np.argsort(-old_squared[eligible], kind="stable")]
        # Match the sequential pass's non-overlapping owners, and prohibit two
        # independent flips from introducing the same new diagonal together.
        touched = np.zeros(len(indices), dtype=bool)
        diagonals, chosen = set(), []
        for index in eligible:
            left, right, diagonal = int(first[index]), int(second[index]), int(proposed_keys[index])
            if touched[left] or touched[right] or diagonal in diagonals:
                continue
            touched[left] = touched[right] = True
            diagonals.add(diagonal)
            chosen.append(index)
        if not chosen:
            break
        chosen = np.asarray(chosen, dtype=np.int64)
        indices[first[chosen]], indices[second[chosen]] = proposed[chosen, 0], proposed[chosen, 1]
    return indices


def _preview_retriangulate_face(face, poly, points, normals, triangles, boundary, tolerance, uv_nodes=None):
    """Improve folded native cells without moving or adding mesh nodes.

    A sheared surface chart can give Delaunay-in-UV a physically long diagonal.
    Re-triangulate only convex UV quads across shared interior edges. Every
    change preserves their oriented UV coverage and native trim polygons,
    shortens the physical diagonal, and improves the worst surface orientation.
    """
    import numpy as np
    from OCP.TopAbs import TopAbs_Orientation
    xyz, exact = np.asarray(points), np.asarray(normals)
    indices = np.array(triangles, dtype=np.int64, copy=True)
    threshold = -1e-8 / 3
    sign = -1 if face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED else 1
    uv = None if uv_nodes is None else np.asarray(uv_nodes)
    if uv is not None and (uv.shape != (len(points), 2) or not np.all(np.isfinite(uv))):
        raise _PreviewMeshError("surface orientation requires finite native UV coordinates")
    surface = None
    projector = None
    orientation_cache = {}

    def raw_audit(cells):
        corners = xyz[cells]
        planes = np.cross(corners[..., 1, :] - corners[..., 0, :], corners[..., 2, :] - corners[..., 0, :])
        lengths = np.linalg.norm(planes, axis=-1)
        dots = np.divide((planes * exact[cells].mean(axis=-2)).sum(axis=-1), lengths,
                         out=np.zeros_like(lengths), where=lengths > 1e-20)
        return dots, lengths

    def audit(cells):
        nonlocal uv, surface, projector
        dots, lengths = raw_audit(cells)
        corners = xyz[cells]
        planes = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
        unit = np.divide(planes, lengths[:, None], out=np.zeros_like(planes), where=lengths[:, None] > 1e-20)
        suspects = np.flatnonzero((lengths > 1e-12) & (dots < threshold))
        if len(suspects) > MAX_PREVIEW_EXACT_ORIENTATION_CELLS:
            raise _PreviewMeshError("inward surface triangles exceed the bounded orientation repair budget",
                                    refine_surface=True)
        if len(suspects) and (poly.HasUVNodes() or uv is not None):
            from OCP.BRepGProp import BRepGProp_Face
            from OCP.gp import gp_Pnt, gp_Vec
            if uv is None:
                uv = np.asarray([poly.UVNode(index).Coord() for index in range(1, poly.NbNodes() + 1)])
            if surface is None:
                surface, projector = BRepGProp_Face(face.wrapped), _SurfaceProjector(face)
            for index in suspects:
                cell_uv = uv[cells[index]]
                ab, ac = cell_uv[1] - cell_uv[0], cell_uv[2] - cell_uv[0]
                if sign * (ab[0] * ac[1] - ab[1] * ac[0]) <= 0:
                    continue  # Never excuse reversed native parameter winding.
                cache_key = tuple(sorted(int(node) for node in cells[index]))
                if cache_key in orientation_cache:
                    dots[index] = orientation_cache[cache_key]
                    continue
                # Corner normals can cancel or reverse around a surface cusp.
                # Judge the facet against the exact normal inside its UV cell;
                # keep the original exact lighting normals at every vertex.
                u, v = cell_uv.mean(axis=0)
                point, normal = gp_Pnt(), gp_Vec()
                try:
                    surface.Normal(float(u), float(v), point, normal)
                except Exception:
                    continue
                if normal.SquareMagnitude() > 1e-24:
                    center_dot = float(np.dot(unit[index], normal.Normalized().Coord()))
                    if math.isfinite(center_dot):
                        if (center_dot < threshold
                                or _preview_triangle_matches_surface(face, corners[index], cell_uv, tolerance, tolerance,
                                                                     projector)):
                            dots[index] = center_dot
                if dots[index] >= threshold:
                    if len(orientation_cache) < len(triangles) * 4:
                        orientation_cache[cache_key] = dots[index]
                    continue
                longest = max(np.linalg.norm(corners[index][right] - corners[index][left])
                              for left, right in ((0, 1), (1, 2), (2, 0)))
                # Native trims can contain wrinkles below the kernel's own
                # positional precision. Retain their coverage and node identity
                # only when the physical width and surface error are both
                # unresolved at that precision. Meaningful folds still fail.
                if (lengths[index] / longest <= GEOMETRY_TOLERANCE_MM
                        and _preview_triangle_matches_surface(face, corners[index], cell_uv, tolerance,
                                                              GEOMETRY_TOLERANCE_MM, projector)):
                    dots[index] = 0
                if len(orientation_cache) < len(triangles) * 4:
                    orientation_cache[cache_key] = dots[index]
        return dots, lengths

    dots, lengths = raw_audit(indices)
    suspects = (lengths > 1e-12) & (dots < threshold)
    if not np.any(suspects):
        return triangles
    # Rare corner-normal ambiguities are cheap to resolve before changing a
    # healthy mesh. A grossly folded candidate must not trigger thousands of
    # per-cell native surface projections before its bounded metric repair.
    if np.count_nonzero(suspects) <= MAX_PREVIEW_EXACT_ORIENTATION_CELLS:
        precise_dots, precise_lengths = audit(indices)
        if not np.any((precise_lengths > 1e-12) & (precise_dots < threshold)):
            return triangles
    if face.geomType() not in {"BSPLINE", "BEZIER"}:
        raise _PreviewMeshError("the triangulation contains inward surface triangles")
    if not poly.HasUVNodes() and uv is None:
        raise _PreviewMeshError("inward surface triangles have no native UV coordinates")
    if uv is None:
        uv = np.asarray([poly.UVNode(index).Coord() for index in range(1, poly.NbNodes() + 1)])

    def signed(cells):
        corners = uv[cells]
        ab, ac = corners[..., 1, :] - corners[..., 0, :], corners[..., 2, :] - corners[..., 0, :]
        return sign * (ab[..., 0] * ac[..., 1] - ab[..., 1] * ac[..., 0])

    if np.any((lengths > 1e-12) & (signed(indices) <= 0)):
        raise _PreviewMeshError("the triangulation contains inward surface triangles with reversed UV winding")
    indices = _preview_metric_triangles(xyz, exact, uv, indices, boundary(), sign)
    dots, lengths = audit(indices)
    if np.any((lengths > 1e-12) & (dots < threshold)):
        raise _PreviewMeshError("inward surface triangles remain after bounded metric triangulation")
    return indices.tolist()


def _preview_split_triangle(cell, midpoints):
    """Split an oriented triangle along any marked edges, preserving its winding."""
    middle = [midpoints.get(tuple(sorted((cell[index], cell[(index + 1) % 3])))) for index in range(3)]
    count = sum(node is not None for node in middle)
    if count == 0:
        return [cell]
    if count == 1:
        offset = next(index for index, node in enumerate(middle) if node is not None)
        a, b, c = [cell[(offset + index) % 3] for index in range(3)]
        m = middle[offset]
        return [(a, m, c), (m, b, c)]
    if count == 2:
        offset = (middle.index(None) + 1) % 3
        a, b, c = [cell[(offset + index) % 3] for index in range(3)]
        m, n = middle[offset], middle[(offset + 1) % 3]
        return [(b, n, m), (a, m, c), (m, n, c)]
    a, b, c = cell
    m, n, p = middle
    return [(a, m, p), (m, b, n), (p, n, c), (m, n, p)]


def _preview_boundary_edges(edges, poly, location):
    from OCP.BRep import BRep_Tool
    from OCP.TopoDS import TopoDS
    result = set()
    for edge in edges:
        for wrapped in (edge.wrapped, TopoDS.Edge(edge.wrapped.Reversed())):
            polygon = BRep_Tool.PolygonOnTriangulation_s(wrapped, poly, location)
            if polygon is not None:
                nodes = polygon.Nodes()
                sequence = [nodes.Value(index) - 1 for index in range(nodes.Lower(), nodes.Upper() + 1)]
                result.update(tuple(sorted(pair)) for pair in zip(sequence, sequence[1:]))
    return result


def _preview_refine_face(face, poly, location, points, normals, triangles, boundary, tolerance):
    """Refine a coarse native mesh on its exact surface, preserving trim nodes.

    Surface-control meshing can oversample a severely sheared parameter chart.
    A coarse candidate is usable only after every nondegenerate cell passes an
    independent surface check. Split shared interior edges conformingly; never
    move an existing node or change a native boundary segment. All work stays
    private until both orientation and surface fidelity have been established.
    """
    import numpy as np
    from OCP.BRep import BRep_Tool
    from OCP.BRepGProp import BRepGProp_Face
    from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
    from OCP.Poly import Poly_Triangle
    from OCP.TopAbs import TopAbs_Orientation
    from OCP.gp import gp_Pnt, gp_Pnt2d, gp_Vec

    original_count = len(points)
    if (not isinstance(points, list) or not isinstance(normals, list)
            or not poly.HasUVNodes() or poly.NbNodes() != original_count
            or len(normals) != original_count or not math.isfinite(tolerance) or tolerance <= 0):
        raise _PreviewMeshError("surface refinement requires complete native UV nodes and normals")
    candidate_points = [list(point) for point in points]
    candidate_normals = [list(normal) for normal in normals]
    candidate_uv = [list(poly.UVNode(index).Coord()) for index in range(1, original_count + 1)]
    xyz, exact, uv = np.asarray(candidate_points), np.asarray(candidate_normals), np.asarray(candidate_uv)
    indices = np.array(triangles, dtype=np.int64, copy=True)
    if original_count > MAX_VERTICES or len(indices) > MAX_TRIANGLES:
        raise _PreviewMeshError("surface refinement exceeds the mesh size budget")
    if (xyz.shape != (original_count, 3) or exact.shape != xyz.shape
            or uv.shape != (original_count, 2) or indices.ndim != 2 or indices.shape[1] != 3
            or not len(indices) or np.any(indices < 0) or np.any(indices >= original_count)
            or not np.all(np.isfinite(xyz)) or not np.all(np.isfinite(exact))
            or not np.all(np.isfinite(uv)) or np.any(np.abs((exact * exact).sum(axis=1) - 1) > 1e-6)):
        raise _PreviewMeshError("surface refinement received invalid native mesh data")
    native_boundary = {tuple(sorted((int(a), int(b)))) for a, b in boundary}
    if any(a < 0 or b >= original_count for a, b in native_boundary):
        raise _PreviewMeshError("surface refinement received invalid native boundary indices")
    reverse = face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED
    sign = -1 if reverse else 1
    threshold = -1e-8 / 3
    surface = BRep_Tool.Surface_s(face.wrapped)
    oriented_surface = BRepGProp_Face(face.wrapped)
    surface_bounds = surface.Bounds()
    quality_cache = {}
    projection_count = 0
    # Leave room for curvature between the finite lattice samples. The denser
    # independent regression checks use the full requested display deflection.
    fidelity_limit = tolerance * 0.9
    weights = np.asarray([[first / 4, second / 4, (4 - first - second) / 4]
                          for first in range(5) for second in range(5 - first)])
    if face.geomType() == "PLANE":
        # Both the plane and its UV map are affine. The corner error bounds
        # every barycentric point without repeating identical native queries.
        weights = np.eye(3)

    # Existing nodes cannot be moved by refinement. Reject an inaccurate
    # native corner before spending work around it, including collapsed XYZ
    # cells whose UV coordinates still cover a real surface patch.
    for index in np.unique(indices):
        u, v = uv[index]
        try:
            expected = surface.Value(float(u), float(v)).Coord()
        except Exception as error:
            raise _PreviewMeshError("the exact surface could not be sampled during refinement") from error
        if (not all(math.isfinite(value) for value in expected)
                or math.dist(xyz[index], expected) > fidelity_limit):
            raise _PreviewMeshError("a native refinement node exceeds the display surface deflection")

    def raw_audit(cells):
        corners = xyz[cells]
        planes = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
        lengths = np.linalg.norm(planes, axis=1)
        dots = (planes * exact[cells].mean(axis=1)).sum(axis=1)
        bad = (lengths > 1e-12) & (dots < lengths * threshold)
        return bad, lengths

    def signed(cells):
        corners = uv[cells]
        ab, ac = corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0]
        return sign * (ab[:, 0] * ac[:, 1] - ab[:, 1] * ac[:, 0])

    def check_coverage():
        directed = np.stack((indices, np.roll(indices, -1, axis=1)), axis=-1).reshape(-1, 2)
        edges = np.sort(directed, axis=1)
        unique, inverse, counts = np.unique(edges, axis=0, return_inverse=True, return_counts=True)
        meaningful = np.linalg.norm(xyz[unique[:, 0]] - xyz[unique[:, 1]], axis=1) > 1e-12
        balance = np.bincount(inverse, weights=np.where(directed[:, 0] < directed[:, 1], 1, -1),
                              minlength=len(unique))
        if np.any(meaningful & ((counts > 2) | ((counts == 2) & (balance != 0)))):
            raise _PreviewMeshError("surface refinement contains overlapping or nonmanifold edges")
        present = {tuple(pair) for pair in unique[meaningful]}
        single = {tuple(pair) for pair in unique[meaningful & (counts == 1)]}
        required = {pair for pair in native_boundary if math.dist(candidate_points[pair[0]],
                                                                 candidate_points[pair[1]]) > 1e-12}
        if single - required or required - present:
            raise _PreviewMeshError("surface refinement does not preserve complete native trim coverage")

    def matches_surface(cell, length):
        nonlocal projection_count
        if length <= 1e-12:
            parameters = uv[cell]
            scale = np.max(np.abs(parameters), axis=0)
            parameters = parameters / np.where(scale > 0, scale, 1)
            ab, ac = parameters[1] - parameters[0], parameters[2] - parameters[0]
            epsilon = np.finfo(float).eps
            uncertainty = epsilon * (np.abs(parameters[1:]) + np.abs(parameters[0])
                                      + np.abs(np.asarray([ab, ac])))
            area = ab[0] * ac[1] - ab[1] * ac[0]
            roundoff = 8 * (uncertainty[0, 0] * abs(ac[1]) + uncertainty[0, 1] * abs(ac[0])
                           + uncertainty[1, 0] * abs(ab[1]) + uncertainty[1, 1] * abs(ab[0])
                           + epsilon * (abs(ab[0] * ac[1]) + abs(ab[1] * ac[0])))
            if abs(area) <= roundoff:
                return True  # A native stitch has no resolved UV surface area.
        key = tuple(sorted(int(node) for node in cell))
        if key in quality_cache:
            return quality_cache[key]
        if len(quality_cache) >= MAX_PREVIEW_REFINEMENT_CELLS:
            raise _PreviewMeshError("surface refinement exceeds the bounded cell validation budget")
        corners, parameters = xyz[cell], uv[cell]
        samples, sample_uv = weights @ corners, weights @ parameters
        low, high = parameters.min(axis=0), parameters.max(axis=0)
        padding = np.maximum(1e-12, (high - low) * 1e-9)
        low, high = low - padding, high + padding
        for axis, (minimum, maximum) in enumerate(((surface_bounds[0], surface_bounds[1]),
                                                   (surface_bounds[2], surface_bounds[3]))):
            if math.isfinite(minimum):
                low[axis] = max(low[axis], minimum)
            if math.isfinite(maximum):
                high[axis] = min(high[axis], maximum)
        valid = True
        try:
            for point, (u, v) in zip(samples, sample_uv):
                expected = surface.Value(float(u), float(v)).Coord()
                if not all(math.isfinite(value) for value in expected):
                    valid = False
                    break
                if math.dist(point, expected) <= fidelity_limit:
                    continue
                if projection_count >= MAX_PREVIEW_REFINEMENT_PROJECTIONS:
                    raise _PreviewMeshError("surface refinement exceeds the bounded projection budget")
                projection_count += 1
                # Stay on this cell's surface patch rather than projecting to
                # an unrelated nearby portion of a long, folded surface chart.
                projection = GeomAPI_ProjectPointOnSurf(
                    gp_Pnt(*point), surface, float(low[0]), float(high[0]),
                    float(low[1]), float(high[1]), 1e-7)
                if not projection.NbPoints() or not projection.LowerDistance() <= fidelity_limit:
                    valid = False
                    break
        except _PreviewMeshError:
            raise
        except Exception as error:
            raise _PreviewMeshError("the exact surface could not be sampled during refinement") from error
        quality_cache[key] = valid
        return valid

    def midpoint(a, b):
        center = (uv[a] + uv[b]) / 2
        point, normal = gp_Pnt(), gp_Vec()
        try:
            oriented_surface.Normal(float(center[0]), float(center[1]), point, normal)
            if not normal.SquareMagnitude() > 1e-24:
                raise _PreviewMeshError("the exact surface normal is undefined during refinement")
            coordinates = list(point.Coord())
            direction = list(normal.Normalized().Coord())
        except _PreviewMeshError:
            raise
        except Exception as error:
            raise _PreviewMeshError("the exact surface could not be evaluated during refinement") from error
        if (not all(math.isfinite(value) and abs(value) <= LIMIT * 10 for value in coordinates)
                or not all(math.isfinite(value) for value in direction)
                or abs(sum(value * value for value in direction) - 1) > 1e-6):
            raise _PreviewMeshError("surface refinement produced an invalid point or normal")
        error = float(np.linalg.norm(np.asarray(coordinates) - (xyz[a] + xyz[b]) / 2))
        return error, center, coordinates, direction

    check_coverage()
    complete = False
    for iteration in range(MAX_PREVIEW_REFINEMENT_PASSES + 1):
        indices = _preview_metric_triangles(xyz, exact, uv, indices, native_boundary, sign)
        bad, lengths = raw_audit(indices)
        orientation = signed(indices)
        if np.any((lengths > 1e-12) & (orientation <= 0)):
            raise _PreviewMeshError("surface refinement contains reversed native UV winding")
        quality_bad = np.asarray([not matches_surface(cell, length) for cell, length in zip(indices, lengths)])
        targets = np.flatnonzero(bad | quality_bad)
        if not len(targets):
            complete = True
            break
        if not np.any(quality_bad) and np.count_nonzero(bad) <= MAX_PREVIEW_EXACT_ORIENTATION_CELLS:
            # Reuse the ordinary centroid-normal/kernel-precision policy for
            # microscopic native ambiguities; do not refine those forever.
            # The extra UV nodes are still private and have not reached poly.
            try:
                checked = _preview_retriangulate_face(
                    face, poly, candidate_points, candidate_normals, indices.tolist(),
                    lambda: native_boundary, tolerance, uv_nodes=uv)
            except _PreviewMeshError:
                pass
            else:
                indices = np.asarray(checked, dtype=np.int64)
                _, lengths = raw_audit(indices)
                quality_bad = np.asarray([not matches_surface(cell, length) for cell, length in zip(indices, lengths)])
                if not np.any(quality_bad):
                    complete = True
                    break
                # The shared policy accepted orientation, but any newly
                # changed diagonal must still meet this fallback's fidelity.
                targets = np.flatnonzero(quality_bad)
                orientation = signed(indices)
        if iteration == MAX_PREVIEW_REFINEMENT_PASSES:
            break
        owners = {}
        for index, cell in enumerate(indices.tolist()):
            for a, b in zip(cell, cell[1:] + cell[:1]):
                owners.setdefault(tuple(sorted((a, b))), []).append(index)
        selected, midpoint_cache = {}, {}
        for index in targets:
            cell = indices[index].tolist()
            candidates = []
            for a, b in zip(cell, cell[1:] + cell[:1]):
                key = tuple(sorted((a, b)))
                adjacent = owners[key]
                if key in native_boundary or len(adjacent) != 2:
                    continue
                # A native zero-UV stitch must not acquire new physical area.
                # Refining an edge beside such an owner can duplicate its
                # existing opposite UV node and create a nonmanifold junction.
                if any(orientation[owner] <= 1e-16 for owner in adjacent):
                    continue
                if key not in midpoint_cache:
                    midpoint_cache[key] = midpoint(a, b)
                candidates.append((key, midpoint_cache[key]))
            if candidates:
                key, sample = max(candidates, key=lambda item: item[1][0])
                selected[key] = sample
        if not selected:
            break
        added = len(candidate_points) - original_count
        if (added + len(selected) > MAX_PREVIEW_REFINEMENT_NODES
                or len(candidate_points) + len(selected) > MAX_VERTICES
                or len(indices) + 2 * len(selected) > MAX_TRIANGLES):
            raise _PreviewMeshError("surface refinement exceeds the bounded mesh growth budget")
        midpoints = {}
        for key, (_, center, coordinates, direction) in selected.items():
            midpoints[key] = len(candidate_points)
            candidate_points.append(coordinates)
            candidate_normals.append(direction)
            candidate_uv.append(center.tolist())
        refined = [child for cell in indices.tolist() for child in _preview_split_triangle(cell, midpoints)]
        xyz = np.asarray(candidate_points)
        exact = np.asarray(candidate_normals)
        uv = np.asarray(candidate_uv)
        indices = np.asarray(refined, dtype=np.int64)
    if not complete:
        raise _PreviewMeshError("the surface could not be refined within its bounded fidelity budget")
    check_coverage()

    # Publish derived display data only after the whole candidate has passed.
    # Existing nodes, UVs, and Python lighting normals retain their exact bits.
    result = indices.tolist()
    if len(candidate_points) != original_count or not np.array_equal(indices, np.asarray(triangles)):
        inverse = location.Transformation().Inverted()
        additions = [(gp_Pnt(*point).Transformed(inverse), gp_Pnt2d(*parameters))
                     for point, parameters in zip(candidate_points[original_count:], candidate_uv[original_count:])]
        native_triangles = [Poly_Triangle(a + 1, c + 1, b + 1) if reverse else Poly_Triangle(a + 1, b + 1, c + 1)
                            for a, b, c in result]
        poly.RemoveNormals()
        if additions:
            poly.ResizeNodes(len(candidate_points), True)
            for index, (point, parameters) in enumerate(additions, original_count + 1):
                poly.SetNode(index, point)
                poly.SetUVNode(index, parameters)
        poly.ResizeTriangles(len(result), True)
        for index, triangle in enumerate(native_triangles, 1):
            poly.SetTriangle(index, triangle)
        points.extend(candidate_points[original_count:])
        normals.extend(candidate_normals[original_count:])
    return result


def _preview_face_triangles(face, poly, location, points, normals, edges, tolerance, refine_surface=False):
    """Audit native coverage and complete small gaps at curved trim corners."""
    from collections import Counter, defaultdict
    from OCP.BRep import BRep_Tool
    from OCP.TopAbs import TopAbs_Orientation
    from OCP.TopoDS import TopoDS
    reverse = face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED
    triangles = [[a - 1, (c if reverse else b) - 1, (b if reverse else c) - 1]
                 for a, b, c in (poly.Triangle(index).Get() for index in range(1, poly.NbTriangles() + 1))]
    # Boundary edges are immutable; only interior diagonals may change. Build
    # their constraints lazily so healthy faceted imports retain the fast path.
    def boundary():
        return _preview_boundary_edges(edges, poly, location)
    if refine_surface:
        triangles = _preview_refine_face(face, poly, location, points, normals, triangles, boundary(), tolerance)
    else:
        triangles = _preview_retriangulate_face(face, poly, points, normals, triangles, boundary, tolerance)
    if len(points) == 3 and len(triangles) == 1:
        return triangles  # Common faceted imports need no boundary graph.

    # Collapse only endpoints of native zero-length mesh/pole edges for the
    # audit. Nearby nodes on unrelated trim curves retain distinct identities.
    parents = list(range(len(points)))
    def root(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index
    def join_if_collapsed(a, b):
        if math.dist(points[a], points[b]) <= 1e-12:
            parents[root(b)] = root(a)
    for triangle in triangles:
        for a, b in zip(triangle, triangle[1:] + triangle[:1]):
            join_if_collapsed(a, b)
    boundary_pairs, seam_pairs = [], []
    for edge in edges:
        seam = BRep_Tool.IsClosed_s(edge.wrapped, poly, location)
        for wrapped in (edge.wrapped, TopoDS.Edge(edge.wrapped.Reversed())):
            polygon = BRep_Tool.PolygonOnTriangulation_s(wrapped, poly, location)
            if polygon is None:
                continue
            nodes = polygon.Nodes()
            indices = [nodes.Value(index) - 1 for index in range(nodes.Lower(), nodes.Upper() + 1)]
            for a, b in zip(indices, indices[1:]):
                join_if_collapsed(a, b)
                boundary_pairs.append((a, b))
                if seam:
                    seam_pairs.append((a, b))
    keys = [root(index) for index in range(len(points))]
    def key(a, b):
        return tuple(sorted((keys[a], keys[b])))
    native = {key(a, b): (a, b) for a, b in boundary_pairs if keys[a] != keys[b]}
    seams = {key(a, b) for a, b in seam_pairs if keys[a] != keys[b]}
    incidence, directed, balance = Counter(), {}, Counter()
    for triangle in triangles:
        if len({keys[index] for index in triangle}) < 3:
            continue  # Collapsed pole facets contribute no surface boundary.
        for a, b in zip(triangle, triangle[1:] + triangle[:1]):
            if keys[a] != keys[b]:
                edge_key = key(a, b)
                incidence[edge_key] += 1
                balance[edge_key] += 1 if keys[a] < keys[b] else -1
                directed[edge_key] = (a, b)
    if any(count > 2 or (count == 2 and balance[edge_key] != 0) or
           (edge_key in native and count != 1 and edge_key not in seams) for edge_key, count in incidence.items()):
        raise _PreviewMeshError("the triangulation contains overlapping or nonmanifold surface edges")
    missing = {edge_key: pair for edge_key, pair in native.items() if edge_key not in incidence}
    extra = {edge_key: directed[edge_key] for edge_key, count in incidence.items()
             if count == 1 and edge_key not in native}
    if not missing and not extra:
        return triangles
    graph = defaultdict(list)
    pairs = {**missing, **extra}
    for a, b in pairs:
        graph[a].append(b)
        graph[b].append(a)
    if any(len(neighbors) != 2 for neighbors in graph.values()):
        raise _PreviewMeshError("the triangulation has an open or branched surface gap")
    while extra:
        edge_key, (a, b) = next(iter(extra.items()))
        # Start opposite the existing oriented mesh edge. The remaining path
        # must close through this same connected difference boundary.
        first, current, previous = keys[b], keys[a], keys[b]
        loop_keys = [first, current]
        while True:
            following = next(node for node in graph[current] if node != previous)
            if following == first:
                break
            if following in loop_keys:
                raise _PreviewMeshError("the triangulation has a repeated surface-gap boundary")
            loop_keys.append(following)
            previous, current = current, following
        node_indices = {keys[index]: index for pair in pairs.values() for index in pair}
        loop = [node_indices[node] for node in loop_keys]
        # Every extra mesh edge in this component must be cancelled by the
        # added patch, never doubled in the same direction.
        for left, right in zip(loop_keys, loop_keys[1:] + loop_keys[:1]):
            boundary_key = tuple(sorted((left, right)))
            if boundary_key in extra:
                x, y = extra[boundary_key]
                if (left, right) != (keys[y], keys[x]):
                    raise _PreviewMeshError("a surface gap has inconsistent edge directions")
                del extra[boundary_key]
            missing.pop(boundary_key, None)
        triangles.extend(_preview_patch_triangles(loop, points, normals, face, tolerance))
        if len(triangles) > MAX_TRIANGLES:
            raise ModelError("Preview exceeds the mesh size limit; simplify the design.")
    if missing:
        raise _PreviewMeshError("the triangulation omits native trim boundaries")
    # Check the completed mesh, rather than trusting the mesher's success flag.
    completed, balance = Counter(), Counter()
    for triangle in triangles:
        if len({keys[index] for index in triangle}) < 3:
            continue
        for a, b in zip(triangle, triangle[1:] + triangle[:1]):
            edge_key = key(a, b)
            completed[edge_key] += 1
            balance[edge_key] += 1 if keys[a] < keys[b] else -1
    if any(count > 2 or (count == 2 and balance[edge_key] != 0) or
           (count == 1 and edge_key not in native) or
           (edge_key in native and count != 1 and edge_key not in seams)
           for edge_key, count in completed.items()) or any(edge_key not in completed for edge_key in native):
        raise _PreviewMeshError("surface triangulation remains incomplete after trim repair")
    return triangles


def _preview_solid_groups(solids):
    """Partition solids that share native faces or edges, in solid order.

    A face's triangulation and its edges' boundary polygons live on the shared
    native subshapes, including every located instance of one solid. Cleaning
    and remeshing one solid would discard the display data of each solid it
    shares with, so those solids are meshed and retried together.
    """
    from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE
    from OCP.TopExp import TopExp
    from OCP.TopLoc import TopLoc_Location
    from OCP.TopTools import TopTools_IndexedMapOfShape
    parents = list(range(len(solids)))

    def root(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    shared, owners, identity = TopTools_IndexedMapOfShape(), {}, TopLoc_Location()
    for index, solid in enumerate(solids):
        for kind in (TopAbs_FACE, TopAbs_EDGE):
            local = TopTools_IndexedMapOfShape()
            TopExp.MapShapes_s(solid.wrapped, kind, local)
            for position in range(1, local.Extent() + 1):
                owner = owners.setdefault(shared.Add(local.FindKey(position).Located(identity)), index)
                if root(owner) != root(index):
                    parents[root(index)] = root(owner)
    groups = {}
    for index in range(len(solids)):
        groups.setdefault(root(index), []).append(index)
    return list(groups.values())


def _preview_mesh(shape, solids, tolerance):
    from OCP.BRep import BRep_Builder, BRep_Tool
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    from OCP.BRepTools import BRepTools
    from OCP.IMeshTools import IMeshTools_Parameters, IMeshTools_MeshAlgoType
    from OCP.TopLoc import TopLoc_Location
    from OCP.TopoDS import TopoDS_Compound
    watson = IMeshTools_MeshAlgoType.IMeshTools_MeshAlgoType_Watson
    delabella = IMeshTools_MeshAlgoType.IMeshTools_MeshAlgoType_Delabella
    faces = [[(face, _shape_entities(face, "Edge")) for face in _shape_entities(solid, "Face")] for solid in solids]
    # Retain healthy native meshes; retry only the solids whose display
    # candidate failed, never the whole assembly. Watson can report success
    # with folded facets and large missing areas on trimmed analytic spheres,
    # so try the independent native triangulator at the same angle before a
    # finer one: small connector blends can need finer boundary angles even
    # when the assembly-wide linear deflection is already adequate, but a finer
    # angle multiplies the triangles of threads and other long curved trims.
    attempts = [(watson, 0.15, tolerance, False), (delabella, 0.16, tolerance, False),
                (watson, 0.07, tolerance, False)] + [
        (delabella, angle, tolerance, False) for angle in (0.14, 0.18, 0.20)]
    # Pole-adjacent trims can still fold an analytic sphere's native mesh at
    # every ordinary angle. Refine its boundary and surface sampling together
    # before giving up; do not flip those facets or alter the exact geometry.
    attempts += [(delabella, 0.20, tolerance * factor, False) for factor in (0.25, 0.125)]
    result = [None] * len(solids)
    accepted = [0, 0]  # Nodes and triangles of solids whose meshes passed.

    def mesh(target, attempt):
        algorithm, angle, linear_deflection, refine_surface = attempt
        parameters = IMeshTools_Parameters()
        parameters.Deflection, parameters.Angle = linear_deflection, angle
        parameters.Relative, parameters.InParallel = False, True
        parameters.ControlSurfaceDeflection = not refine_surface
        parameters.MeshAlgo = algorithm
        return BRepMesh_IncrementalMesh(target, parameters)

    def candidate(group, mesher):
        """Try the group's next attempt on its current native meshes."""
        attempt = group["attempts"].pop(0)
        algorithm, angle, linear_deflection, refine_surface = attempt
        group.update(attempt=attempt, status=mesher.GetStatusFlags(), feature=None)
        if not mesher.IsDone():
            group["failure"] = "OpenCascade did not complete triangulation"
            return False
        total_nodes, total_triangles = accepted
        meshes = {}
        try:
            for solid_index in group["solids"]:
                chunks = []
                for local_index, (face, edges) in enumerate(faces[solid_index]):
                    location = TopLoc_Location()
                    poly = BRep_Tool.Triangulation_s(face.wrapped, location)
                    if poly is None or not poly.NbTriangles():
                        raise _PreviewMeshError("OpenCascade returned no surface triangles")
                    if total_nodes + poly.NbNodes() > MAX_VERTICES or total_triangles + poly.NbTriangles() > MAX_TRIANGLES:
                        raise ModelError("Preview exceeds the mesh size limit; simplify the design.")
                    transform = location.Transformation()
                    points = [list(poly.Node(index).Transformed(transform).Coord()) for index in range(1, poly.NbNodes() + 1)]
                    normals = _preview_face_normals(face, poly, location)
                    triangles = _preview_face_triangles(face, poly, location, points, normals, edges,
                                                        linear_deflection, refine_surface)
                    total_nodes += len(points)
                    total_triangles += len(triangles)
                    if total_nodes > MAX_VERTICES or total_triangles > MAX_TRIANGLES:
                        raise ModelError("Preview exceeds the mesh size limit; simplify the design.")
                    chunks.append((face, edges, poly, location, points, normals, triangles))
                meshes[solid_index] = chunks
        except _PreviewMeshError as error:
            group["failure"] = f"part {solid_index + 1}, face {local_index + 1}: {error}"
            group["feature"] = feature_id("face", solid_index, local_index)
            if error.refine_surface and not group["refinement_queued"]:
                # A highly sheared chart can make native surface refinement
                # manufacture hundreds of thousands of folded cells. Try one
                # coarse seed instead, with LAD's independent, bounded exact-
                # surface refinement and complete trim audit on every face.
                group["attempts"].insert(0, (algorithm, angle, linear_deflection, True))
                group["refinement_queued"] = True
            return False
        for solid_index, chunks in meshes.items():
            result[solid_index] = chunks
        accepted[:] = total_nodes, total_triangles
        return True

    def exhausted(group):
        algorithm, angle, linear_deflection, refine_surface = group["attempt"]
        diagnostic = {"stage": "preview_meshing", "geometryScope": "native_candidate",
                      "openCascadeMeshingStatus": group["status"],
                      "linearDeflectionMM": linear_deflection, "angularDeflectionRadians": angle,
                      "independentSurfaceRefinement": refine_surface,
                      "meshingAlgorithm": "Watson" if algorithm == watson else "Delabella"}
        if group["feature"] is not None:
            diagnostic["feature"] = group["feature"]
        return ModelError(f"OpenCascade could not produce a complete design preview ({group['failure']}).",
                          diagnostic=diagnostic)

    groups = [{"solids": solids_in_group, "attempts": list(attempts), "refinement_queued": False}
              for solids_in_group in _preview_solid_groups(solids)]
    # One assembly-wide pass gives the native mesher every face at once.
    mesher = mesh(shape.wrapped, attempts[0])
    pending = [group for group in groups if not candidate(group, mesher)]
    while pending:
        for group in pending:
            if not group["attempts"]:
                raise exhausted(group)
        # Remesh only failed groups; groups at the same attempt share a pass.
        batches = {}
        for group in pending:
            batches.setdefault(group["attempts"][0], []).append(group)
        pending = []
        for attempt, members in batches.items():
            compound, builder = TopoDS_Compound(), BRep_Builder()
            builder.MakeCompound(compound)
            for group in members:
                for solid_index in group["solids"]:
                    builder.Add(compound, solids[solid_index].wrapped)
            BRepTools.Clean_s(compound)
            mesher = mesh(compound, attempt)
            pending += [group for group in members if not candidate(group, mesher)]
        pending.sort(key=lambda group: group["solids"][0])
    return result


def _preview_shading_dots(corners, normals, samples):
    """Compare at projected XYZ positions, accounting for nonuniform UV spacing."""
    import numpy as np
    first, second = corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0]
    plane = np.cross(first, second)
    area_squared = np.einsum("ni,ni->n", plane, plane)
    offset = samples[..., :3] - corners[:, None, 0]
    w1 = np.einsum("nsi,ni->ns", np.cross(offset, second[:, None]), plane) / area_squared[:, None]
    w2 = np.einsum("nsi,ni->ns", np.cross(first[:, None], offset), plane) / area_squared[:, None]
    weights = np.stack((1 - w1 - w2, w1, w2), axis=-1)
    # A curved edge may project just outside the flat cell. Ignore samples
    # that leave it substantially, especially on sheared or singular charts.
    within_cell = weights.min(axis=-1) >= -0.1
    weights = np.maximum(weights, 0)
    blend = weights @ normals
    length = np.linalg.norm(blend, axis=-1)
    valid = within_cell & np.isfinite(length) & (length > 1e-12)
    dot = np.einsum("nsi,nsi->ns", blend, samples[..., 3:])
    return np.divide(dot, length, out=np.ones_like(dot), where=valid)


def _preview_shading_project_midpoint(surface, parameters, position, tolerance):
    """Find the chord midpoint's nearest surface point on this local patch."""
    from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
    from OCP.gp import gp_Pnt
    u_min, u_max, v_min, v_max = surface.Bounds()
    low = parameters.min(axis=0)
    high = parameters.max(axis=0)
    try:
        projection = GeomAPI_ProjectPointOnSurf(
            gp_Pnt(*position), surface, max(u_min, low[0]), min(u_max, high[0]),
            max(v_min, low[1]), min(v_max, high[1]), 1e-7)
        if projection.NbPoints() and projection.LowerDistance() <= tolerance:
            return projection.LowerDistanceParameters()
    except Exception:
        pass  # This optional split needs a solution on the local surface.
    return None


def _preview_shading_split(xyz, normals, uv, cells, selected, owners, sign, projected_parameters=None, project=None):
    """Retry folded children at physical midpoints and keep independent splits."""
    import numpy as np
    projected_parameters = dict(projected_parameters or {})
    for attempt in range(3):
        if not selected:
            break
        additions = np.asarray(list(selected.values()))
        candidate_xyz = np.concatenate((xyz, additions[:, :3]))
        candidate_normals = np.concatenate((normals, additions[:, 3:]))
        split_uv = uv[np.asarray(list(selected))].mean(axis=1)
        for index, key in enumerate(selected):
            if key in projected_parameters:
                split_uv[index] = projected_parameters[key]
        candidate_uv = np.concatenate((uv, split_uv))
        midpoints = {key: len(xyz) + offset for offset, key in enumerate(selected)}
        affected = sorted({cell for key in selected for cell in owners[key]})
        subdivisions = [_preview_split_triangle(cells[cell].tolist(), midpoints) for cell in affected]
        children = np.asarray([child for group in subdivisions for child in group])
        new_corners, new_uv = candidate_xyz[children], candidate_uv[children]
        first, second = new_uv[:, 1] - new_uv[:, 0], new_uv[:, 2] - new_uv[:, 0]
        cross_uv = sign * (first[:, 0] * second[:, 1] - first[:, 1] * second[:, 0])
        plane = np.cross(new_corners[:, 1] - new_corners[:, 0], new_corners[:, 2] - new_corners[:, 0])
        outward = np.einsum("ni,ni->n", plane, candidate_normals[children].mean(axis=1))
        invalid = ~((cross_uv > 1e-16) & (outward > 1e-12))
        if not np.any(invalid):
            keep = np.ones(len(cells), dtype=bool)
            keep[affected] = False
            return candidate_xyz, candidate_normals, candidate_uv, np.concatenate((cells[keep], children))

        if attempt == 2:
            break
        parents = np.repeat(affected, [len(group) for group in subdivisions])
        rejected = set(parents[invalid])
        retry = {}
        for edge, sample in selected.items():
            if rejected.isdisjoint(owners[edge]):
                retry[edge] = sample
            elif project is not None and edge not in projected_parameters:
                # Thin neighboring cells may fold from a small sideways
                # displacement that was within the chord's distance tolerance.
                projected = project(edge, owners[edge])
                if projected is not None:
                    retry[edge], _, projected_parameters[edge] = projected
        selected = retry
    return None


def _refine_preview_shading_face(chunk, tolerance, samples_left, nodes_left, projections_left):
    """Improve an accepted face's display mesh without touching its native polygon."""
    import numpy as np
    from OCP.BRep import BRep_Tool
    from OCP.BRepGProp import BRepGProp_Face
    from OCP.TopAbs import TopAbs_Orientation
    from OCP.gp import gp_Pnt, gp_Vec

    face, edges, poly, location, points, normals, triangles = chunk
    xyz, exact, cells = np.asarray(points), np.asarray(normals), np.asarray(triangles)
    sign = -1 if face.wrapped.Orientation() == TopAbs_Orientation.TopAbs_REVERSED else 1
    uv = np.asarray([poly.UVNode(i).Coord() for i in range(1, len(points) + 1)])
    surface = BRepGProp_Face(face.wrapped)
    point, normal = gp_Pnt(), gp_Vec()
    boundary = None
    samples = {}
    projections = {}
    exact_surface = None
    candidate_limit = samples_left // 4

    def evaluate(parameters):
        try:
            surface.Normal(float(parameters[0]), float(parameters[1]), point, normal)
            length = normal.Magnitude()
            if length > 1e-12 and math.isfinite(length):
                return (*point.Coord(), *(value / length for value in normal.Coord()))
        except Exception:
            pass  # A singular or unavailable sample cannot justify a split.
        return (math.nan,) * 6

    def probe(key):
        if key not in samples:
            if len(samples) >= samples_left:
                return (math.nan,) * 6
            samples[key] = evaluate(uv[list(key)].mean(axis=0))
        return samples[key]

    def project(key, adjacent):
        nonlocal exact_surface
        if key not in projections and len(projections) < projections_left:
            if exact_surface is None:
                exact_surface = BRep_Tool.Surface_s(face.wrapped)
            parameters = uv[cells[adjacent]].reshape(-1, 2)
            start, end = key
            chord = xyz[end] - xyz[start]
            midpoint = (xyz[start] + xyz[end]) / 2
            result = _preview_shading_project_midpoint(exact_surface, parameters, midpoint, tolerance)
            projections[key] = None
            if result is not None:
                sample = evaluate(result)
                fraction = np.dot(sample[:3] - xyz[start], chord) / np.dot(chord, chord)
                if np.all(np.isfinite(sample)) and 0.1 <= fraction <= 0.9:
                    blend = (1 - fraction) * exact[start] + fraction * exact[end]
                    length = np.linalg.norm(blend)
                    if length > 1e-12:
                        dot = float(np.dot(blend, sample[3:]) / length)
                        projections[key] = sample, dot, result
        return projections.get(key)

    for _ in range(MAX_PREVIEW_SHADING_PASSES):
        corners, parameters = xyz[cells], uv[cells]
        sides = np.roll(corners, -1, axis=1) - corners
        side_squared = np.einsum("nsi,nsi->ns", sides, sides)
        longest = side_squared.max(axis=1)
        plane = np.cross(sides[:, 0], -sides[:, 2])
        area_squared = np.einsum("ni,ni->n", plane, plane)
        # Skip kernel-sized slivers and cells whose chords are already small
        # compared to the preview's positional tolerance.
        first, second = parameters[:, 1] - parameters[:, 0], parameters[:, 2] - parameters[:, 0]
        winding = sign * (first[:, 0] * second[:, 1] - first[:, 1] * second[:, 0])
        suitable = ((longest >= tolerance ** 2) & (area_squared > longest * GEOMETRY_TOLERANCE_MM ** 2)
                    & (winding > 1e-16))
        candidates = np.flatnonzero(suitable)
        if not len(candidates):
            break
        if len(candidates) > candidate_limit:
            priority = np.argsort(-longest[candidates], kind="stable")[:candidate_limit]
            candidates = candidates[priority]
        directed = np.stack((cells, np.roll(cells, -1, axis=1)), axis=-1)
        edge_keys = np.sort(directed, axis=-1)
        sampled = np.asarray([[probe(tuple(sorted(cell))), *(probe(tuple(pair)) for pair in keys)]
                              for cell, keys in zip(cells[candidates].tolist(), edge_keys[candidates].tolist())])
        dots = _preview_shading_dots(corners[candidates], exact[cells[candidates]], sampled)
        worst = dots.min(axis=1)
        failing = np.flatnonzero(worst < PREVIEW_SHADING_NORMAL_DOT)
        if not len(failing):
            break
        if boundary is None:
            boundary = _preview_boundary_edges(edges, poly, location)
        # An edge must be shared by two cells with sound UV winding. A native
        # trim, a seam or an edge bordering a collapsed cell retains its chord.
        # Search all cells for neighbors, but build Python owner lists only
        # for edges that could be split on this pass.
        edge_codes = edge_keys[..., 0] * len(xyz) + edge_keys[..., 1]
        affected_edges = np.unique(edge_codes[candidates[failing]])
        owner_slots = np.flatnonzero(np.isin(edge_codes.ravel(), affected_edges))
        owners = {}
        for slot in owner_slots:
            cell, side = divmod(int(slot), 3)
            owners.setdefault(tuple(edge_keys[cell, side]), []).append(cell)
        selected, projected_parameters = {}, {}
        for index in failing[np.argsort(worst[failing], kind="stable")]:
            cell = candidates[index]
            options = []
            for offset, key in enumerate(edge_keys[cell].tolist()):
                key = tuple(key)
                adjacent = owners[key]
                if (key in boundary or len(adjacent) != 2
                        or not all(suitable[owner] for owner in adjacent)
                        or not np.all(np.isfinite(sampled[index, offset + 1]))):
                    continue
                # Bound the change in positions and keep the new vertex away
                # from either endpoint even when the UV parameter is stretched.
                a = xyz[key[0]]
                chord = xyz[key[1]] - a
                sample = sampled[index, offset + 1]
                delta = sample[:3] - a
                fraction = np.dot(delta, chord) / side_squared[cell, offset]
                dot = dots[index, offset + 1]
                midpoint_uv = None
                if not (0.1 <= fraction <= 0.9
                        and np.linalg.norm(delta - fraction * chord) <= tolerance):
                    # A UV midpoint can be displaced along the surface even
                    # when the physical midpoint can move onto it within
                    # tolerance. Only search the two incident cells' UV patch.
                    projected = project(key, adjacent)
                    if projected is None:
                        continue
                    sample, dot, midpoint_uv = projected
                options.append((dot, -side_squared[cell, offset], key, sample, midpoint_uv))
            # A bad sample on a locked edge is not fixable by splitting the
            # interior unless there is also error at the center or a usable edge.
            if not options:
                continue
            dot, _, key, sample, midpoint_uv = min(options, key=lambda option: option[:2])
            if min(dots[index, 0], dot) >= PREVIEW_SHADING_NORMAL_DOT:
                continue
            selected[key] = sample
            if midpoint_uv is not None:
                projected_parameters[key] = midpoint_uv
            if len(selected) == nodes_left:
                break
        if not selected:
            break

        refined = _preview_shading_split(xyz, exact, uv, cells, selected, owners, sign, projected_parameters, project)
        if refined is None:
            break
        new_xyz, exact, uv, cells = refined
        nodes_left -= len(new_xyz) - len(xyz)
        xyz = new_xyz
        if not nodes_left or len(samples) == samples_left:
            break
    if len(xyz) != len(points):
        chunk = face, edges, poly, location, xyz.tolist(), exact.tolist(), cells.tolist()
    return chunk, len(samples), len(projections)


def _refine_preview_shading(mesh, tolerance):
    """Spend a bounded assembly-wide budget on lighting after mesh acceptance."""
    samples_left = MAX_PREVIEW_SHADING_SAMPLES
    projections_left = MAX_PREVIEW_SHADING_PROJECTIONS
    nodes_left = min(MAX_PREVIEW_SHADING_NODES,
                     MAX_VERTICES - sum(len(chunk[4]) for solid in mesh for chunk in solid),
                     (MAX_TRIANGLES - sum(len(chunk[6]) for solid in mesh for chunk in solid)) // 2)
    if samples_left < 4 or nodes_left <= 0:
        return
    # Start with the most heavily tessellated spline faces so small blends
    # cannot consume the entire budget before the main surfaces are sampled.
    spline_faces = [(solid, index) for solid in mesh for index, chunk in enumerate(solid)
                    if chunk[0].geomType() in {"BSPLINE", "BEZIER"} and chunk[2].HasUVNodes()
                    and chunk[2].NbNodes() == len(chunk[4])]
    for solid, index in sorted(spline_faces, key=lambda item: -len(item[0][item[1]][6])):
        chunk = solid[index]
        refined, sampled, projected = _refine_preview_shading_face(
            chunk, tolerance, samples_left, nodes_left, projections_left)
        solid[index] = refined
        projections_left -= projected
        nodes_left -= len(refined[4]) - len(chunk[4])
        samples_left -= sampled
        if samples_left < 4 or not nodes_left:
            break


def make_preview(shape, preview_stats=None):
    from OCP.BRep import BRep_Tool
    prepared = None
    if preview_stats is not None:
        prepared = dict(preview_stats)
        preview_stats.clear()
        if prepared.pop("shape", None) is not shape:
            raise ModelError("Preview measurements belong to a different or already consumed build.")
    solids = prepared["solids"] if prepared is not None else _shape_entities(shape, "Solid")
    if not solids:
        raise ModelError("A design preview requires closed solid geometry.")
    # Derive whole-design dimensions from the same exact part bounds already
    # needed by measurements. Do this once before meshing: a triangulation-aware
    # bounding box can otherwise change with an existing coarse display mesh,
    # and traversing every face again for the whole assembly repeats the work.
    solid_bounds, bounds = ((prepared["solidBounds"], prepared["bounds"]) if prepared is not None
                            else _preview_bounds(solids))
    diagonal = math.sqrt(sum((bounds[axis + 3] - bounds[axis]) ** 2 for axis in range(3)))
    tolerance = max(0.005, min(0.25, diagonal / 1000))
    mesh = _preview_mesh(shape, solids, tolerance)
    _refine_preview_shading(mesh, tolerance)
    # Keep an explicit triangle-to-solid mapping for native part picking. A
    # fused body is one selectable solid; a disconnected union/pattern has
    # multiple selectable solids. Tessellating each solid retains CadQuery's
    # per-face vertex boundaries and correct face orientation.
    vertices, normals, triangles, triangle_solids, triangle_faces = [], [], [], [], []
    topology = {"vertices": [], "edges": [], "faces": [], "parts": []}
    mesh_edges = [{} for _ in solids]
    mesh_edge_segments = 0
    for solid_index, solid in enumerate(solids):
        topology["parts"].append(prepared["solidProperties"][solid_index] if prepared is not None
                                 else part_metadata(solid, solid_index, bounds=solid_bounds[solid_index]))
        solid_vertices = [{"id": feature_id("vertex", solid_index, local_index), "position": list(vertex.toTuple())}
                          for local_index, vertex in enumerate(_shape_entities(solid, "Vertex"))]
        topology["vertices"].extend(solid_vertices)
        seam_candidates = []
        # Keep the native face order and node positions, including separate
        # boundaries for hard lighting normals and the original stroke nodes.
        for local_index, (face, face_edges, poly, location, points, face_normals, face_triangles) in enumerate(mesh[solid_index]):
            face_index = len(topology["faces"])
            topology["faces"].append(face_metadata(face, solid_index, local_index))
            offset = len(vertices)
            node_count, triangle_count = len(points), len(face_triangles)
            if offset + node_count > MAX_VERTICES or len(triangles) + triangle_count > MAX_TRIANGLES:
                raise ModelError("Preview exceeds the mesh size limit; simplify the design.")
            transform = location.Transformation()
            vertices.extend(points)
            normals.extend(face_normals)
            triangles.extend([index + offset for index in triangle] for triangle in face_triangles)
            triangle_solids.extend([solid_index] * triangle_count)
            triangle_faces.extend([face_index] * triangle_count)
            # Independent curve sampling can place a coarse chord inside its
            # own finer curved face, making depth-tested rims appear dashed.
            # Reuse the exact edge polygon from this face's triangulation so
            # strokes and adjacent surface triangles have identical boundaries.
            # A seam joins the two parametric sides of one periodic or closed
            # face, such as a sphere's meridian. It bounds no other face and
            # the surface is smooth across it, so it is neither drawn nor
            # picked; its arbitrary placement would otherwise read as a crease.
            edges = mesh_edges[solid_index]
            for edge in face_edges:
                bucket = edges.setdefault(hash(edge.wrapped), [])
                record = next((known for known in bucket if known.native.IsSame(edge.wrapped)), None)
                if record is None:
                    record = _PreviewMeshEdge(edge.wrapped, BRep_Tool.IsClosed_s(edge.wrapped, face.wrapped))
                    bucket.append(record)
                    if record.seam:
                        seam_candidates.append(record)
                else:
                    # A face lists each edge once, so this is a second face.
                    record.seam = False
                if record.polyline is not None or record.seam:
                    continue
                polygon = BRep_Tool.PolygonOnTriangulation_s(edge.wrapped, poly, location)
                if polygon is None or polygon.NbNodes() < 2:
                    continue
                if polygon.NbNodes() > MAX_EDGE_SEGMENTS + 1:
                    raise ModelError("Preview exceeds the edge size limit; simplify the design.")
                nodes = polygon.Nodes()
                points = [list(poly.Node(nodes.Value(index)).Transformed(transform).Coord())
                          for index in range(nodes.Lower(), nodes.Upper() + 1)]
                if edge.IsClosed() and points[-1] != points[0]:
                    points.append(points[0].copy())
                mesh_edge_segments += len(points) - 1
                if mesh_edge_segments > MAX_EDGE_SEGMENTS:
                    raise ModelError("Preview exceeds the edge size limit; simplify the design.")
                record.polyline = points
        seams = [record.native for record in seam_candidates if record.seam]
        if seams:
            for local_index in _preview_seam_vertices(solid, seams):
                solid_vertices[local_index]["seam"] = True
    segments, edge_solids, edge_features = [], [], []
    for solid_index, solid in enumerate(solids):
        for local_index, edge in enumerate(_shape_entities(solid, "Edge")):
            # Keep shared edges per owner so hiding a part removes all its
            # boundaries without also hiding a visible neighboring body.
            # Seams keep their topology identity with no display polyline.
            record = _preview_mesh_edge(edge, mesh_edges[solid_index])
            seam = record is not None and record.seam
            points = [] if seam else _preview_edge_polyline(edge, None if record is None else record.polyline, tolerance)
            edge_index = len(topology["edges"])
            item = edge_metadata(edge, solid_index, local_index, points)
            if seam:
                item["seam"] = True
            topology["edges"].append(item)
            for start, end in zip(points, points[1:]):
                segments.append(start + end)
                edge_solids.append(solid_index)
                edge_features.append(edge_index)
            if len(segments) > MAX_EDGE_SEGMENTS:
                raise ModelError("Preview exceeds the edge size limit; simplify the design.")
    parts = getattr(shape, "_lad_parts", None)
    if parts is None:
        parts = [{"id": f"solid/{index}", "name": f"Part {index + 1}",
                  "solidIndices": [index], "children": None} for index in range(len(solids))]
    preview = {
        "vertices": vertices,
        "normals": normals,
        "triangles": triangles,
        "triangleSolids": triangle_solids,
        "triangleFaces": triangle_faces,
        "edges": segments,
        "edgeSolids": edge_solids,
        "edgeFeatures": edge_features,
        "topology": topology,
        "parts": parts,
        "bounds": bounds,
        "volume": prepared["volume"] if prepared is not None else shape.Volume(),
        "area": prepared["area"] if prepared is not None else shape.Area(),
        "solids": len(solids),
        "faces": prepared["faces"] if prepared is not None else len(_shape_entities(shape, "Face")),
    }
    motion = getattr(shape, "_lad_assembly_motion", None)
    if motion is not None:
        preview["assemblyMotion"] = motion
    if getattr(shape, "_lad_print_version", False):
        preview["printVersion"] = True
    pins = getattr(shape, "_lad_print_down", None)
    if pins:
        preview["printDown"] = [{"solid": index, "direction": pins[index]} for index in sorted(pins)]
    return preview


# Display arrays travel to the app as packed little-endian 4-byte sections in
# mesh.bin, beside compact JSON metadata: (preview key, section, array code,
# values per item). Float32 matches the GPU attributes the app uploads.
PREVIEW_SECTIONS = (
    ("vertices", "positions", "f", 3), ("normals", "normals", "f", 3), ("triangles", "triangles", "I", 3),
    ("edges", "edges", "f", 6), ("triangleSolids", "triangleSolids", "i", 1), ("triangleFaces", "triangleFaces", "i", 1),
    ("edgeSolids", "edgeSolids", "i", 1), ("edgeFeatures", "edgeFeatures", "i", 1),
)


def write_preview_result(preview, output):
    """Publish result.json, moving any display arrays into mesh.bin first."""
    from array import array
    from itertools import chain
    result = dict(preview)
    sections, offset = {}, 0
    mesh = output / "mesh.bin"
    temporary = output / "mesh.bin.tmp"
    try:
        with temporary.open("wb") as stream:
            for key, name, code, width in PREVIEW_SECTIONS:
                values = result.pop(key, None)
                if values is None:
                    continue
                packed = array(code, chain.from_iterable(values) if width > 1 else values)
                if len(packed) != len(values) * width or packed.itemsize != 4:
                    raise ModelError(f"The preview {key} data is malformed.")
                if sys.byteorder != "little":
                    packed.byteswap()
                packed.tofile(stream)
                sections[name] = {"offset": offset, "count": len(packed)}
                offset += len(packed) * 4
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    if sections:
        temporary.replace(mesh)
        result["meshBuffers"] = {"path": mesh.name, "sections": sections}
    else:
        temporary.unlink()
    staged = output / "result.json.tmp"
    staged.write_text(json.dumps(result, separators=(",", ":"), allow_nan=False))
    staged.replace(output / "result.json")


def validate_parts(parts, solid_count):
    """Check semantic ownership independently of disposable tessellation data."""
    if not isinstance(parts, list) or len(parts) > 8192:
        raise ModelError("The saved parts hierarchy is invalid or too large.")
    pending = [(part, 0) for part in parts]
    identifiers, owners, count = set(), set(), 0
    while pending:
        part, depth = pending.pop()
        count += 1
        if (not isinstance(part, dict) or not {"id", "name", "solidIndices"} <= set(part)
                or set(part) - {"id", "name", "solidIndices", "children", "color"} or count > 8192 or depth > 32):
            raise ModelError("The saved parts hierarchy contains invalid items.")
        identity, name = part["id"], part["name"]
        if (not isinstance(identity, str) or not identity or len(identity.encode("utf-8")) > 1024
                or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in identity)
                or identity in identifiers or not isinstance(name, str) or not name.strip() or len(name) > 160
                or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in name)):
            raise ModelError("The saved parts hierarchy contains invalid or duplicate identities.")
        identifiers.add(identity)
        if part.get("color") is not None:
            validate_part_color(part["color"])
        indices, children = part["solidIndices"], part.get("children")
        if (not isinstance(indices, list) or (children is not None and not isinstance(children, list))
                or (children is None and not indices)):
            raise ModelError("The saved parts hierarchy contains invalid ownership.")
        for index in indices:
            if isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < solid_count or index in owners:
                raise ModelError("Each saved solid must belong to exactly one part.")
            owners.add(index)
        pending.extend((child, depth + 1) for child in children or [])
        if count + len(pending) > 8192:
            raise ModelError("The saved parts hierarchy is too large.")
    if owners != set(range(solid_count)):
        raise ModelError("The saved parts hierarchy must include every solid.")
    return parts


def import_step(path, cq, preview_stats=None):
    # A STEP can have multiple transfer roots. Workplane.val() silently keeps
    # only the first one; combine every imported root in its stored order.
    with step_precision("read"):
        values = cq.importers.importStep(str(path)).vals()
    if not values or any(not isinstance(value, cq.Shape) for value in values):
        raise ModelError("The saved STEP contains no solid geometry.")
    shape = values[0] if len(values) == 1 else cq.Compound.makeCompound(values)
    return validate_shape(shape, preview_stats=preview_stats)


def import_input_asset(path, format, cq):
    """Read an app-staged recipe input, never an arbitrary program path."""
    input_asset = _validation_input.get() or {"name": path.name, "format": format}
    with validation_scope("input_asset", input_asset):
        try:
            return _read_input_asset(path, format, cq)
        except ModelError as error:
            if error.diagnostic is None:
                error.diagnostic = {"stage": "input_import", "geometryScope": "input_asset", "inputAsset": input_asset}
            raise
        except Exception as error:
            raise ModelError(f"Input geometry import failed: {type(error).__name__}: {error}",
                             diagnostic={"stage": "input_import", "geometryScope": "input_asset",
                                         "inputAsset": input_asset}) from error


def _read_input_asset(path, format, cq):
    import stat
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
        raise ModelError("Imported geometry must be a regular private file of at most 512 MB.")
    if format in {"step", "stp"}:
        return import_step(path, cq)
    if format == "brep":
        return validate_shape(_read_brep_file(path, cq, "imported BREP asset"))
    if format in {"stl", "obj"}:
        return mesh_to_solid(read_mesh(path, format), cq)
    raise ModelError("Unsupported imported geometry format.")


def _read_brep_file(path, cq, label):
    from OCP.BRep import BRep_Builder
    from OCP.BRepTools import BRepTools
    from OCP.TopoDS import TopoDS_Shape
    with path.open("rb") as stream:
        if not stream.read(128).startswith(b"DBRep_DrawableShape\n"):
            raise ModelError(f"The {label} is invalid.")
    wrapped = TopoDS_Shape()
    if not BRepTools.Read_s(wrapped, str(path), BRep_Builder()) or wrapped.IsNull():
        raise ModelError(f"The {label} could not be read.")
    return cq.Shape.cast(wrapped)


def read_mesh(path, format):
    """Read triangle/polygon geometry without viewer or extra mesh packages."""
    import struct
    if format == "stl":
        data = path.read_bytes()
        count = struct.unpack_from("<I", data, 80)[0] if len(data) >= 84 else 0
        if count and 84 + count * 50 == len(data):
            triangles = [[list(values[index:index + 3]) for index in (3, 6, 9)]
                         for values in (struct.unpack_from("<12fH", data, 84 + index * 50) for index in range(count))]
        else:
            try:
                text = data.decode("utf-8")
                vertices = []
                for match in re.finditer(r"(?im)^\s*vertex\s+(\S+)\s+(\S+)\s+(\S+)\s*$", text):
                    vertices.append([float(value) for value in match.groups()])
            except (UnicodeError, ValueError) as error:
                raise ModelError("The imported STL is not a valid binary or ASCII triangle mesh.") from error
            if len(vertices) % 3:
                raise ModelError("The imported STL contains incomplete triangles.")
            triangles = [vertices[index:index + 3] for index in range(0, len(vertices), 3)]
    else:
        vertices, triangles = [], []
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                fields = line.split("#", 1)[0].split()
                if not fields:
                    continue
                if fields[0] == "v":
                    if len(fields) not in {4, 5}:
                        raise ModelError("OBJ vertices require three Cartesian coordinates.")
                    point = [float(value) for value in fields[1:4]]
                    if len(fields) == 5:
                        weight = float(fields[4])
                        if not weight:
                            raise ModelError("OBJ vertices cannot have a zero homogeneous weight.")
                        point = [value / weight for value in point]
                    vertices.append(point)
                    if len(vertices) > 1_000_000:
                        raise ModelError("The imported mesh contains too many vertices.")
                elif fields[0] == "f":
                    if len(fields) < 4:
                        raise ModelError("OBJ faces require at least three vertices.")
                    indices = [int(field.split("/", 1)[0]) for field in fields[1:]]
                    indices = [index - 1 if index > 0 else len(vertices) + index if index < 0 else -1 for index in indices]
                    if any(index < 0 or index >= len(vertices) for index in indices):
                        raise ModelError("The imported OBJ contains an invalid vertex index.")
                    points = [vertices[index] for index in indices]
                    # OBJ allows non-triangular planar faces. Construct these as
                    # native polygons rather than a fan that could cross a
                    # concave boundary. STEP keeps their original faceted form.
                    triangles.append(points)
        except (UnicodeError, ValueError) as error:
            if isinstance(error, ModelError):
                raise
            raise ModelError("The imported OBJ is not a valid polygon mesh.") from error
    if not triangles:
        raise ModelError("Import a nonempty closed mesh.")
    for triangle in triangles:
        if any(len(point) != 3 or any(not math.isfinite(value) or abs(value) > LIMIT * 10 for value in point) for point in triangle):
            raise ModelError("The imported mesh has invalid or out-of-range coordinates.")
    return triangles


def mesh_to_solid(polygons, cq):
    """Sew closed faceted surfaces into exact BRep faces, retaining voids."""
    from OCP.BRep import BRep_Tool
    from OCP.BRepBuilderAPI import BRepBuilderAPI_Sewing
    from OCP.BRepExtrema import BRepExtrema_DistShapeShape
    from OCP.ShapeFix import ShapeFix_Solid
    sewing = BRepBuilderAPI_Sewing(1e-7)
    try:
        for polygon in polygons:
            face = cq.Face.makeFromWires(cq.Wire.makePolygon([cq.Vector(*point) for point in polygon], close=True))
            if not face.isValid() or face.Area() <= 1e-14:
                raise ModelError("The imported mesh contains a degenerate or non-planar face.")
            sewing.Add(face.wrapped)
        sewing.Perform()
        sewn = cq.Shape.cast(sewing.SewedShape())
        shells = sewn.Shells()
        if not shells or len(sewn.Faces()) != len(polygons) or any(not BRep_Tool.IsClosed_s(shell.wrapped) for shell in shells):
            raise ModelError("The imported mesh is open or non-manifold; a closed watertight mesh is required.")
        solids = [cq.Shape.cast(ShapeFix_Solid().SolidFromShell(shell.wrapped)) for shell in shells]
        if any(not solid.isValid() or solid.Volume() <= 1e-10 for solid in solids):
            raise ModelError("The imported mesh could not be converted to valid closed solids.")
        # A sealed cavity is a second shell, not a second filled body. First
        # prove that shell surfaces are disjoint: one inside vertex alone can
        # misclassify an intersecting body as a cavity and discard its exterior.
        # Once connected closed boundaries cannot cross or touch, a point on
        # either boundary classifies the containment of that entire shell.
        tolerance = 1e-7
        samples = [solid.Vertices()[0].Center() for solid in solids]
        bounds = []
        for solid in solids:
            box = solid.BoundingBox()
            bounds.append((box.xmin, box.ymin, box.zmin, box.xmax, box.ymax, box.zmax))
        containers = [set() for _ in solids]
        for i, solid in enumerate(solids):
            for j in range(i):
                a, b = bounds[i], bounds[j]
                if any(a[axis + 3] < b[axis] - tolerance or b[axis + 3] < a[axis] - tolerance for axis in range(3)):
                    continue
                distance = BRepExtrema_DistShapeShape(shells[i].wrapped, shells[j].wrapped)
                if not distance.IsDone() or not math.isfinite(distance.Value()):
                    raise ModelError("The imported mesh's closed shells could not be classified reliably.")
                if distance.Value() <= tolerance:
                    raise ModelError("The imported mesh contains intersecting or touching closed shells; use disjoint bodies or fully enclosed cavities.")
                if solids[j].isInside(samples[i], tolerance):
                    containers[i].add(j)
                if solid.isInside(samples[j], tolerance):
                    containers[j].add(i)
        depths = [len(owners) for owners in containers]
        bodies = []
        for index, solid in enumerate(solids):
            if depths[index] % 2:
                continue
            voids = [other for j, other in enumerate(solids) if depths[j] == depths[index] + 1 and index in containers[j]]
            bodies.append(solid.cut(*voids) if voids else solid)
        result = bodies[0] if len(bodies) == 1 else cq.Compound.makeCompound(bodies)
        return validate_shape(result)
    except ModelError:
        raise
    except Exception as error:
        raise ModelError(f"The imported mesh could not be sewn into a closed faceted solid: {error}") from error


def preview_step(spec, asset_directory, output, cq, threads):
    """Tessellate exact saved geometry; never evaluate a generated program."""
    if (set(spec) - {"operation", "stepAsset", "parts"} or spec.get("stepAsset") != "preview.step"):
        raise ModelError("Saved previews require the private preview.step asset and optional parts hierarchy.")
    import stat
    source = asset_directory / "preview.step"
    info = source.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
        raise ModelError("The saved STEP must be a regular private file of at most 512 MB.")
    data = source.read_bytes()
    if not data[:512].lstrip().startswith(b"ISO-10303-21;") or b"END-ISO-10303-21;" not in data[-512:]:
        raise ModelError("The saved STEP asset is incomplete.")
    configure_threads(threads)
    preview_stats = {}
    with validation_scope("saved_step", {"name": source.name, "format": "step"}):
        shape = import_step(source, cq, preview_stats=preview_stats)
    if spec.get("parts") is not None:
        shape._lad_parts = validate_parts(spec["parts"], len(shape.Solids()))
    preview = make_preview(shape, preview_stats=preview_stats)
    # Exporting again could change the exact model or its STEP entity order.
    # This file is temporary worker IPC, and retains the saved bytes verbatim.
    step = output / "model.step"
    step.write_bytes(data)
    brep = (output / "model.brep").resolve()
    write_brep(shape, brep)
    preview["brepPath"] = str(brep)
    return preview


def write_brep(shape, path):
    """Private session artifact: exact geometry, with no preview triangulation."""
    from OCP.BRepTools import BRepTools
    from OCP.TopTools import TopTools_FormatVersion
    if not BRepTools.Write_s(shape.wrapped, str(path), False, False,
                            TopTools_FormatVersion.TopTools_FormatVersion_VERSION_3):
        raise ModelError("The CAD engine could not retain the native solid for export.")


def read_brep(spec, asset_directory, cq, threads):
    """Read only the private, app-staged native geometry, without meshing.

    The app marks a solid `validatedNative` when this worker validated it before
    writing it; reading it again checks only that it holds closed solids. A
    serving worker reuses the solid for repeated requests with the same
    `nativeIdentity`.
    """
    if spec.get("brepAsset") != "source.brep":
        raise ModelError("Native operations require the private source.brep asset.")
    identity = spec.get("nativeIdentity") if _serving else None
    if identity is not None and (not isinstance(identity, str) or not 0 < len(identity) <= 4096):
        raise ModelError("The native solid identity is invalid.")
    if identity in _native_shapes:
        configure_threads(threads)
        shape = _native_shapes.pop(identity)
        _native_shapes[identity] = shape
        return shape
    import stat
    from OCP.BRep import BRep_Builder
    from OCP.BRepTools import BRepTools
    from OCP.TopoDS import TopoDS_Shape
    source = asset_directory / "source.brep"
    info = source.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
        raise ModelError("The native solid must be a regular private file of at most 512 MB.")
    with source.open("rb") as stream:
        if not stream.read(128).startswith(b"DBRep_DrawableShape\n"):
            raise ModelError("The native solid asset is invalid.")
    configure_threads(threads)
    wrapped = TopoDS_Shape()
    if not BRepTools.Read_s(wrapped, str(source), BRep_Builder()) or wrapped.IsNull():
        raise ModelError("The native solid asset could not be read.")
    shape = cq.Shape.cast(wrapped)
    if spec.get("validatedNative") is True:
        if shape.isNull() or not _only_solids(shape) or not 0 < len(_shape_entities(shape, "Solid")) <= 4_096:
            raise ModelError("The native solid asset does not contain the validated solids.")
    else:
        with validation_scope("native_artifact", {"name": source.name, "format": "brep"}):
            shape = validate_shape(shape)
    if identity is not None:
        _native_shapes[identity] = shape
        while len(_native_shapes) > NATIVE_CACHE_SIZE:
            _native_shapes.pop(next(iter(_native_shapes)))
    return shape


def selected_solids(spec, solids, required=False):
    indices = spec.get("solidIndices")
    if indices is None:
        if required:
            return []
        return list(range(len(solids)))
    if (not isinstance(indices, list) or len(indices) > len(solids)
            or any(isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < len(solids) for index in indices)
            or len(set(indices)) != len(indices)):
        raise ModelError("The selected parts contain invalid or duplicate solid indices.")
    return indices


def export_solid_colors(records, solid_count):
    """Validate the complete color request before creating any export output."""
    if not isinstance(records, list) or len(records) > solid_count:
        raise ModelError("STEP colors must be a list of uniquely indexed solid colors.")
    colors = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"solidIndex", "color"}:
            raise ModelError("Each STEP color must contain a solidIndex and an RGB color.")
        index = record["solidIndex"]
        if isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < solid_count or index in colors:
            raise ModelError("STEP colors contain invalid or duplicate solid indices.")
        colors[index] = validate_part_color(record["color"])
    return colors


def write_step(solids, path, cq, colors=None, indices=None):
    """Use one STEP serializer for candidate verification and actual exports."""
    from cadquery.occ_impl.exporters.assembly import exportAssembly
    assembly = cq.Assembly(name="Parts")
    for index in range(len(solids)) if indices is None else indices:
        apply_geometry_tolerance(solids[index])
        rgb = (colors or {}).get(index)
        color = cq.Color(rgb["red"], rgb["green"], rgb["blue"], 1) if rgb is not None else None
        assembly.add(solids[index], name=f"Part {index + 1}", color=color)
    try:
        with step_precision("write"):
            if not exportAssembly(assembly, str(path), mode="default", precision_mode=1):
                raise ModelError("STEP export could not write the design parts; the CAD exporter reported failure.",
                                 diagnostic={"stage": "step_export"})
    except ModelError:
        raise
    except Exception as error:
        raise ModelError(f"STEP export failed: {type(error).__name__}: {error}",
                         diagnostic={"stage": "step_export"}) from error


def _print_surface_samples(solid):
    """Area-weighted exact-surface normals; never create or read a mesh.

    Planes contribute their complete trimmed area. Curves use bounded UV
    quadrature, rejecting samples outside the face and weighting by the surface
    Jacobian before normalizing to its native area. Sampling is done once, not
    once per candidate orientation.
    """
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    from OCP.BRepClass import BRepClass_FaceClassifier
    from OCP.BRepGProp import BRepGProp_Face
    from OCP.GeomAbs import (GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone,
                             GeomAbs_Sphere, GeomAbs_Torus, GeomAbs_SurfaceOfRevolution)
    from OCP.TopAbs import TopAbs_IN, TopAbs_ON
    from OCP.gp import gp_Pnt, gp_Pnt2d, gp_Vec
    normals, points, weights, planes, axes = [], [], [], [], []
    for face in _shape_entities(solid, "Face"):
        area, center = _shape_measurements(face)
        if not math.isfinite(area) or area <= 0:
            continue
        adaptor = BRepAdaptor_Surface(face.wrapped)
        kind = adaptor.GetType()
        if kind == GeomAbs_Plane:
            normal = face.normalAt().toTuple()
            planes.append((normal, center, area, face))
            normals.append(normal); points.append(center); weights.append(area)
            continue
        if kind in (GeomAbs_Cylinder, GeomAbs_Cone, GeomAbs_Torus, GeomAbs_SurfaceOfRevolution):
            axis = {GeomAbs_Cylinder: adaptor.Cylinder, GeomAbs_Cone: adaptor.Cone,
                    GeomAbs_Torus: adaptor.Torus,
                    GeomAbs_SurfaceOfRevolution: adaptor.AxeOfRevolution}[kind]()
            if kind != GeomAbs_SurfaceOfRevolution:
                axis = axis.Axis()
            axes.append((axis.Direction().Coord(), area))
        surface = BRepGProp_Face(face.wrapped)
        u0, u1, v0, v1 = surface.Bounds()
        if not all(math.isfinite(value) for value in (u0, u1, v0, v1)):
            raise ModelError("A part has an unbounded surface and cannot be arranged for 3D printing.")
        # More angular samples for complete round surfaces; small blends use a
        # short rule. Midpoints avoid poles and periodic seams.
        nu = 12 if kind in (GeomAbs_Cylinder, GeomAbs_Cone, GeomAbs_Sphere, GeomAbs_Torus) else 6
        nv = 8 if kind in (GeomAbs_Sphere, GeomAbs_Torus) else 4
        classifier = BRepClass_FaceClassifier()
        point, normal = gp_Pnt(), gp_Vec()
        samples = []
        for refinement in (1, 2, 4):
            for i in range(nu * refinement):
                u = u0 + (u1 - u0) * (i + 0.5) / (nu * refinement)
                for j in range(nv * refinement):
                    v = v0 + (v1 - v0) * (j + 0.5) / (nv * refinement)
                    classifier.Perform(face.wrapped, gp_Pnt2d(u, v), 1e-7)
                    if classifier.State() not in (TopAbs_IN, TopAbs_ON):
                        continue
                    surface.Normal(u, v, point, normal)
                    jacobian = normal.Magnitude()
                    if jacobian > 1e-20 and math.isfinite(jacobian):
                        samples.append((tuple(value / jacobian for value in normal.Coord()),
                                        point.Coord(), jacobian))
            if samples:
                break
        if not samples:
            # Extremely thin trimmed patches can evade the bounded grid. Use a
            # point on a boundary p-curve, still evaluated on the exact surface.
            from OCP.BRepAdaptor import BRepAdaptor_Curve2d
            for edge in _shape_entities(face, "Edge"):
                curve = BRepAdaptor_Curve2d(edge.wrapped, face.wrapped)
                uv = curve.Value((curve.FirstParameter() + curve.LastParameter()) / 2)
                surface.Normal(uv.X(), uv.Y(), point, normal)
                jacobian = normal.Magnitude()
                if jacobian > 1e-20 and math.isfinite(jacobian):
                    samples.append((tuple(value / jacobian for value in normal.Coord()), point.Coord(), jacobian))
        if not samples:
            raise ModelError("A part's surface normals could not be evaluated for 3D printing.")
        scale = area / sum(sample[2] for sample in samples)
        for normal, point, jacobian in samples:
            normals.append(normal); points.append(point); weights.append(jacobian * scale)
    return normals, points, weights, planes, axes


def _print_candidates(solid, planes, axes, properties=None):
    """Shortlist geometry directions, grouping equivalent face/axis evidence."""
    import numpy as np
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps
    grouped = {}

    def add(direction, importance=0):
        direction = np.asarray(direction, dtype=float)
        length = np.linalg.norm(direction)
        if not np.isfinite(length) or length < 1e-12:
            return
        direction /= length
        key = tuple(round(float(value), 6) for value in direction)
        if key in grouped:
            grouped[key][1] += importance
        else:
            grouped[key] = [direction, importance]

    for normal, _, area, _ in planes:
        add([-value for value in normal], area)
    for axis, area in axes:
        axis = np.asarray(axis)
        reference = np.eye(3)[np.argmin(np.abs(axis))]
        perpendicular = np.cross(axis, reference)
        for direction in (axis, perpendicular, np.cross(axis, perpendicular)):
            add(direction, area); add(-direction, area)
    # Limit only the ranked CAD shortlist; flat faces split into many pieces
    # accumulate their areas instead of receiving extra candidate votes.
    directions = [item[0] for item in sorted(grouped.values(), key=lambda item: -item[1])[:48]]
    grouped.clear()
    add((0, 0, 1))  # Keep the supplied pose first in equal-score ties.
    for direction in directions:
        add(direction)
    if properties is None:
        properties = GProp_GProps()
        BRepGProp.VolumeProperties_s(solid.wrapped, properties)
    principal = properties.PrincipalProperties()
    for axis in (principal.FirstAxisOfInertia(), principal.SecondAxisOfInertia(), principal.ThirdAxisOfInertia()):
        vector = np.asarray(axis.Coord())
        add(vector); add(-vector)
    for axis in np.eye(3):
        add(axis); add(-axis)
    # Deterministic equal-area sphere coverage supplies oblique/freeform poses.
    for index in range(32):
        z = 1 - 2 * (index + 0.5) / 32
        angle = index * math.pi * (3 - math.sqrt(5))
        radius = math.sqrt(1 - z * z)
        add((radius * math.cos(angle), radius * math.sin(angle), z))
    return np.asarray([item[0] for item in grouped.values()])


def _print_rotation(direction):
    from OCP.gp import gp_Quaternion, gp_Trsf, gp_Vec
    transform = gp_Trsf()
    transform.SetRotation(gp_Quaternion(gp_Vec(*direction), gp_Vec(0, 0, 1)))
    return transform


def _print_contact_is_stable(faces, direction, centroid, boundary_points=None):
    """Require gravity to fall inside real planar support, not a bounding box.

    A convex hull of native boundary points is conservative: its points lie on
    the actual contact faces, including circular rims and disconnected feet.
    This is a two-dimensional support polygon, with no solid tessellation.
    """
    import numpy as np
    from OCP.BRepAdaptor import BRepAdaptor_Curve
    from OCP.GeomAbs import GeomAbs_Line
    if boundary_points is None:
        boundary_points = {}
    points = []
    for face in faces:
        key = id(face)
        if key not in boundary_points:
            boundary = []
            for edge in _shape_entities(face, "Edge"):
                curve = BRepAdaptor_Curve(edge.wrapped)
                count = 1 if curve.GetType() == GeomAbs_Line else 16
                first, last = curve.FirstParameter(), curve.LastParameter()
                boundary.extend(curve.Value(first + (last - first) * index / count).Coord()
                                for index in range(count + 1))
            boundary_points[key] = boundary
        points.extend(boundary_points[key])
    if len(points) < 3:
        return False
    normal = np.asarray(direction)
    tangent = np.cross(normal, np.eye(3)[np.argmin(np.abs(normal))])
    tangent /= np.linalg.norm(tangent)
    other = np.cross(normal, tangent)
    relative = np.asarray(points) - np.asarray(centroid)
    projected = sorted(set(zip(relative @ tangent, relative @ other)))

    def cross(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    lower, upper = [], []
    for chain, sequence in ((lower, projected), (upper, reversed(projected))):
        for point in sequence:
            while len(chain) >= 2 and cross(chain[-2], chain[-1], point) <= 0:
                chain.pop()
            chain.append(point)
    hull = lower[:-1] + upper[:-1]
    if len(hull) < 3:
        return False
    tolerance = max(1e-7, float(np.ptp(relative, axis=0).max()) * 1e-9)
    return all(cross(a, b, (0, 0)) > tolerance * math.hypot(b[0] - a[0], b[1] - a[1])
               for a, b in zip(hull, hull[1:] + hull[:1]))


def print_orientation(solid, cq):
    """Minimize a 45-degree overhang integral over the bounded CAD shortlist.

    Prefer a stable planar bed when one exists, then minimize overhang within
    those feasible poses. Otherwise an oblique pose balancing on an edge could
    beat every usable base. Smooth parts without a stable planar base retain
    the unrestricted search. All scoring varies the bed normal against fixed
    CAD samples; exact contact checks use shared native reference-frame locations.
    """
    import numpy as np
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps
    normals, points, weights, planes, axes = _print_surface_samples(solid)
    properties = GProp_GProps()
    BRepGProp.VolumeProperties_s(solid.wrapped, properties)
    centroid = properties.CentreOfMass().Coord()
    directions = _print_candidates(solid, planes, axes, properties)
    normals, points, weights = np.asarray(normals), np.asarray(points), np.asarray(weights)
    # Centre the dot products to preserve precision for parts far from origin.
    origin = points[0].copy()
    points -= origin
    costs = np.zeros(len(directions))
    lows, highs = np.full(len(directions), np.inf), np.full(len(directions), -np.inf)
    threshold = math.sqrt(0.5)
    # Bounded intermediate storage on large assemblies.
    for start in range(0, len(weights), 2048):
        block = slice(start, start + 2048)
        penalties = np.maximum(0, -normals[block] @ directions.T - threshold)
        costs += weights[block] @ (penalties * penalties)
        heights = points[block] @ directions.T
        lows = np.minimum(lows, heights.min(axis=0)); highs = np.maximum(highs, heights.max(axis=0))
    possible_contacts = [[] for _ in directions]
    contact_limits = np.zeros(len(directions))
    for normal, center, area, face in planes:
        normal = np.asarray(normal)
        candidates = np.flatnonzero(directions @ normal < -1 + 1e-10)
        for index in candidates:
            height = float((np.asarray(center) - origin) @ directions[index])
            tolerance = max(1e-6, (highs[index] - lows[index]) * 1e-8)
            if height > lows[index] + tolerance:
                continue
            possible_contacts[index].append((height, area, tolerance, face))
            contact_limits[index] += area
    relief = (1 - threshold) ** 2
    lower_costs = np.maximum(0, costs - contact_limits * relief)
    epsilon = max(1e-10, float(weights.sum()) * 1e-9)
    heights = highs - lows
    # Evaluate optimistic scores first. Once a pose cannot beat the verified
    # winner, skip its native extrema. This matters on spline-heavy assemblies,
    # where each exact bound is much dearer than all the cached dot products.
    order = sorted(range(len(directions)), key=lambda index:
                   (round(float(lower_costs[index]) / epsilon), -contact_limits[index], heights[index], index))
    best, best_cost, best_contact = None, math.inf, -1.0
    support_bounds = {}
    verified_contacts, boundary_points = {}, {}
    for require_stable_bed in (True, False):
        for index in order:
            if lower_costs[index] > best_cost + epsilon:
                continue
            if lower_costs[index] >= best_cost - epsilon and contact_limits[index] < best_contact - 1e-10:
                continue
            if require_stable_bed:
                # A subset of these possible faces cannot provide a larger
                # support hull. Reject impossible support before native extrema.
                faces = [entry[3] for entry in possible_contacts[index]]
                if not _print_contact_is_stable(faces, directions[index], centroid, boundary_points):
                    continue
            if index not in verified_contacts:
                contacts = []
                if possible_contacts[index]:
                    located = solid.moved(cq.Location(_print_rotation(directions[index])))
                    support_bounds[index] = exact_bounds(located)
                    bottom = support_bounds[index][2] - float(origin @ directions[index])
                    contacts = [entry for entry in possible_contacts[index]
                                if abs(entry[0] - bottom) <= entry[2]]
                verified_contacts[index] = contacts
            contacts = verified_contacts[index]
            if require_stable_bed and not _print_contact_is_stable(
                    [entry[3] for entry in contacts], directions[index], centroid, boundary_points):
                continue
            contact = sum(entry[1] for entry in contacts)
            cost = max(0, costs[index] - contact * relief)
            if (cost < best_cost - epsilon or
                    (abs(cost - best_cost) <= epsilon and
                     (best is None or (-contact, heights[index], index) < (-best_contact, heights[best], best)))):
                best, best_cost, best_contact = index, cost, contact
        if best is not None:
            break
    rotation = _print_rotation(directions[best])
    return rotation, support_bounds.get(best) or exact_bounds(solid.moved(cq.Location(rotation)))


def _print_matrix(transform):
    """Row-major 4x4 rigid matrix acting on column position vectors."""
    return [transform.Value(row, column) for row in range(1, 4) for column in range(1, 5)] + [0.0, 0.0, 0.0, 1.0]


def print_orientations(solids, cq, pins=None):
    """Orient each exact solid for printing, independently of the others.

    Returns one (matrix, bounds) pair per solid: a world-space rigid delta from
    the built solid to its printing orientation, and the oriented solid's exact
    bounds. A pinned outward bed direction replaces the overhang search for its
    solid. Rigid locations preserve analytic geometry, native solid order and
    colors; no Boolean operation, tessellation or change to the design is
    needed. Placement on the bed is left to the caller.
    """
    from OCP.gp import gp_Ax1, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
    results = []
    oriented_instances = {}
    for position, solid in enumerate(solids):
        pin = pins[position] if pins is not None else None
        pin = tuple(pin) if pin is not None else None
        # Assembly instances often share native geometry and rotation. Remove
        # translation only, retaining the supplied build direction and sphere
        # candidates. Reuse within this request, with an equality collision
        # guard; never retain measurements on mutable shapes or across builds.
        pose = solid.wrapped.Location().Transformation()
        canonical = solid.located(cq.Location())
        rotation = tuple(pose.Value(row, column) for row in range(1, 4) for column in range(1, 4))
        key = (hash(canonical.wrapped), solid.wrapped.Orientation(), rotation, pin)
        shift = gp_Trsf()
        shift.SetTranslation(gp_Vec(*(-pose.Value(row, 4) for row in range(1, 4))))
        match = next((entry for entry in oriented_instances.get(key, ())
                      if entry[0].wrapped.IsPartner(solid.wrapped)), None)
        if match is None:
            pose.SetTranslationPart(gp_Vec())
            unshifted = solid.located(cq.Location(pose))
            if pin is None:
                turn, bounds = print_orientation(unshifted, cq)
            else:
                turn = _print_rotation(tuple(-value for value in pin))
                bounds = exact_bounds(unshifted.moved(cq.Location(turn)))
            width, depth = bounds[3] - bounds[0], bounds[4] - bounds[1]
            # In-plane quarter turns reduce long narrow rows without changing
            # the printing direction or overhang score.
            if depth > width:
                quarter = gp_Trsf()
                quarter.SetRotation(gp_Ax1(gp_Pnt(), gp_Dir(0, 0, 1)), math.pi / 2)
                turn = quarter.Multiplied(turn)
                bounds = [-bounds[4], bounds[0], bounds[2], -bounds[1], bounds[3], bounds[5]]
            oriented_instances.setdefault(key, []).append((solid, turn, bounds))
        else:
            _, turn, bounds = match
        results.append((_print_matrix(turn.Multiplied(shift)), [float(value) for value in bounds]))
    return results


def print_orient_brep(spec, asset_directory, cq, threads):
    """Printing orientations of the requested native solids, without meshing."""
    if set(spec) - NATIVE_SOURCE_FIELDS - {"operation", "solidIndices", "printDown"}:
        raise ModelError("The printing orientation request contains unsupported fields.")
    shape = read_brep(spec, asset_directory, cq, threads)
    solids = _shape_entities(shape, "Solid")
    indices = selected_solids(spec, solids)
    records = spec.get("printDown", [])
    if not isinstance(records, list) or len(records) > len(solids):
        raise ModelError("Pinned printing directions must be a list of uniquely indexed solids.")
    pins = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"solid", "direction"}:
            raise ModelError("Each pinned printing direction requires a solid index and a direction.")
        index = record["solid"]
        if isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < len(solids) or index in pins:
            raise ModelError("Pinned printing directions contain invalid or duplicate solid indices.")
        pins[index] = print_down_direction(record["direction"])
    oriented = print_orientations([solids[index] for index in indices], cq, [pins.get(index) for index in indices])
    return {"orientations": [{"solid": index, "matrix": matrix, "bounds": bounds}
                             for index, (matrix, bounds) in zip(indices, oriented)]}


def export_brep(spec, asset_directory, output, cq, threads):
    """Create whole or selected STEP without replaying or tessellating."""
    if set(spec) - NATIVE_SOURCE_FIELDS - {"operation", "solidIndices", "solidColors", "individualParts", "solidTransforms"} or spec.get("brepAsset") != "source.brep":
        raise ModelError("STEP export requires the private source.brep asset.")
    shape = read_brep(spec, asset_directory, cq, threads)
    solids = posed_solids(shape.Solids(), spec.get("solidTransforms", []), cq)
    indices = selected_solids(spec, solids)
    colors = export_solid_colors(spec.get("solidColors", []), len(solids))
    if not indices:
        raise ModelError("Select at least one part to export.")
    parts = spec.get("individualParts")
    if "individualParts" in spec:
        if not isinstance(parts, list) or not 1 <= len(parts) <= len(indices):
            raise ModelError("Individual STEP files require a nonempty list of available parts.")
        used, selected = set(), set(indices)
        for part in parts:
            if (not isinstance(part, list) or not part
                    or any(isinstance(index, bool) or not isinstance(index, int)
                           or index not in selected for index in part)
                    or len(set(part)) != len(part) or used.intersection(part)):
                raise ModelError("Individual STEP files must contain distinct selected parts.")
            used.update(part)
        if used != selected:
            raise ModelError("Individual STEP files must include every selected part exactly once.")
    if set(indices) != set(range(len(solids))):
        chosen = [solids[index] for index in indices]
        shape = chosen[0] if len(chosen) == 1 else cq.Compound.makeCompound(chosen)
    else:
        indices = list(range(len(solids)))
    report = {"solids": len(shape.Solids()), "faces": len(shape.Faces())}
    if parts is not None:
        files, total = [], 0
        for position, part in enumerate(parts):
            name = f"part-{position:04d}.step"
            step = output / name
            write_step(solids, step, cq, colors=colors, indices=part)
            size = step.stat().st_size
            if size < 100 or size > MAX_GEOMETRY_BYTES - total:
                raise ModelError("The exported STEP parts are invalid or exceed 512 MB in total.")
            total += size
            files.append({"path": name, "solidIndices": part})
        report["partFiles"] = files
    else:
        write_step(solids, output / "model.step", cq, colors=colors, indices=indices)
    return report


def face_drawing_plane(face, cq):
    """Frame a planar face as seen from outside its solid.

    Local Z is the oriented outward normal. Local Y follows world +Z projected
    onto the face, so side faces read upright; horizontal faces keep world +X to
    the right. The origin is the face's area centroid, the same center its
    measurements report. Projecting it onto the exact plane keeps axis-aligned
    drawings at exactly zero depth.
    """
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    normal = face.normalAt()
    up = cq.Vector(0, 0, 1) - normal * normal.z
    x_dir = up.normalized().cross(normal) if up.Length > 1e-7 else cq.Vector(1, 0, 0)
    point = cq.Vector(BRepAdaptor_Surface(face.wrapped).Plane().Location())
    center = cq.Vector(*_shape_measurements(face)[1])
    return cq.Plane(center - normal * (center - point).dot(normal), x_dir, normal)


def export_face_dxf(spec, asset_directory, output, cq, threads):
    """Draw one planar face as an exact 2D DXF, without replaying or meshing.

    Face indices follow the native topology order of previews and measurements.
    Lines, circles, arcs and ellipses remain analytic; other curves become
    exact splines.
    """
    if set(spec) - NATIVE_SOURCE_FIELDS - {"operation", "feature", "solidTransforms"}:
        raise ModelError("The DXF export request contains unsupported fields.")
    feature = spec.get("feature")
    if not isinstance(feature, dict) or set(feature) != {"kind", "solidIndex", "localIndex"} or feature["kind"] != "face":
        raise ModelError("DXF export requires one selected face.")
    owner, local = feature["solidIndex"], feature["localIndex"]
    if isinstance(owner, bool) or not isinstance(owner, int) or isinstance(local, bool) or not isinstance(local, int):
        raise ModelError("The selected face reference is invalid.")
    shape = read_brep(spec, asset_directory, cq, threads)
    solids = posed_solids(_shape_entities(shape, "Solid"), spec.get("solidTransforms", []), cq)
    faces = _shape_entities(solids[owner], "Face") if 0 <= owner < len(solids) else []
    if not 0 <= local < len(faces):
        raise ModelError("The selected face is missing.")
    face = faces[local]
    if face.geomType() != "PLANE":
        raise ModelError("Only a flat face can be exported as a DXF drawing.")
    from cadquery.occ_impl.exporters.dxf import DxfDocument
    from ezdxf import zoom
    document = DxfDocument()
    # The exporter moves a workplane's contents from its plane onto the
    # drawing's XY plane. A bare shape would also skip its spline conversion.
    document.add_shape(cq.Workplane(face_drawing_plane(face, cq)).add(face))
    zoom.extents(document.msp)
    path = output / "face.dxf"
    document.document.saveas(path)
    if not 100 <= path.stat().st_size <= MAX_GEOMETRY_BYTES:
        raise ModelError("The DXF drawing is invalid or exceeds 512 MB.")
    return {"entities": len(document.msp)}


def measure_brep(spec, asset_directory, cq, threads):
    """Exact selected properties and separation on native rigidly posed solids.

    The app supplies precomputed single-item properties. This operation does
    not mesh, execute programs, or serialize STEP; all closest points come from
    OpenCascade's extrema solver on the selected trimmed topology.
    """
    if set(spec) - NATIVE_SOURCE_FIELDS - {"operation", "features", "solidIndices", "solidTransforms"}:
        raise ModelError("The measurement request contains unsupported fields.")
    shape = read_brep(spec, asset_directory, cq, threads)
    posed = "solidTransforms" in spec
    solids = posed_solids(_shape_entities(shape, "Solid"), spec.get("solidTransforms", []), cq)
    indices = selected_solids(spec, solids, required=True)
    features = spec.get("features", [])
    if not isinstance(features, list) or len(features) > (8192 if posed else 2):
        raise ModelError("The selected measurement features are invalid or too numerous.")
    entities, topology_maps = [], {}
    seen = set()
    for feature in features:
        if not isinstance(feature, dict) or set(feature) != {"kind", "solidIndex", "localIndex"}:
            raise ModelError("The selected topology reference is invalid.")
        kind, owner, local = feature["kind"], feature["solidIndex"], feature["localIndex"]
        if (kind not in ("vertex", "edge", "face") or isinstance(owner, bool) or not isinstance(owner, int)
                or not 0 <= owner < len(solids) or isinstance(local, bool) or not isinstance(local, int)):
            raise ModelError("The selected topology reference is invalid.")
        key = kind, owner
        if key not in topology_maps:
            topology_maps[key] = _shape_entities(solids[owner], kind.capitalize())
        values = topology_maps[key]
        if not 0 <= local < len(values) or (kind, owner, local) in seen:
            raise ModelError("The selected topology reference is missing or duplicated.")
        seen.add((kind, owner, local))
        entities.append(values[local])
    entities.extend(solids[index] for index in indices)
    report = {"title": "Measurements", "metrics": [], "features": features, "solidIndices": indices,
              "solids": len(solids), "faces": len(_shape_entities(shape, "Face"))}
    if posed:
        if not entities:
            raise ModelError("Select a part, face, edge, or vertex to measure.")
        topology = {"vertices": [], "edges": [], "faces": [],
                    "parts": [part_metadata(solids[index], index) for index in indices]}
        for feature, entity in zip(features, entities):
            kind, owner, local = feature["kind"], feature["solidIndex"], feature["localIndex"]
            if kind == "vertex":
                topology["vertices"].append({"id": feature_id(kind, owner, local), "position": list(entity.toTuple())})
            elif kind == "edge":
                topology["edges"].append(edge_metadata(entity, owner, local, []))
            else:
                topology["faces"].append(face_metadata(entity, owner, local))
        report["topology"] = topology
    if len(entities) != 2:
        if posed:
            return report
        raise ModelError("Choose two items for an exact distance measurement.")
    from OCP.BRepExtrema import BRepExtrema_DistShapeShape
    extrema = BRepExtrema_DistShapeShape()
    extrema.LoadS1(entities[0].wrapped)
    extrema.LoadS2(entities[1].wrapped)
    extrema.SetMultiThread(True)
    extrema.Perform()
    if not extrema.IsDone() or not extrema.NbSolution():
        raise ModelError("OpenCascade could not determine a minimum distance between these items.")
    first, second = list(extrema.PointOnShape1(1).Coord()), list(extrema.PointOnShape2(1).Coord())
    metrics = []

    def metric(identity, label, values, unit):
        metrics.append({"id": identity, "label": label, "values": values, "unit": unit})

    metric("pair:distance", "Minimum distance", [extrema.Value()], "mm")
    metric("pair:delta", "Delta X, Y, Z", [b - a for a, b in zip(first, second)], "mm")
    metric("pair:first", "Closest point 1", first, "mm")
    metric("pair:second", "Closest point 2", second, "mm")

    def direction(entity):
        from OCP.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
        if entity.ShapeType() == "Edge" and entity.geomType() == "LINE":
            return "line", BRepAdaptor_Curve(entity.wrapped).Line().Direction().Coord()
        if entity.ShapeType() == "Face" and entity.geomType() == "PLANE":
            return "plane", entity.normalAt().toTuple()
        if entity.ShapeType() == "Edge" and entity.geomType() in {"CIRCLE", "ELLIPSE"}:
            adaptor = BRepAdaptor_Curve(entity.wrapped)
            curve = adaptor.Circle() if entity.geomType() == "CIRCLE" else adaptor.Ellipse()
            return "axis", curve.Axis().Direction().Coord()
        if entity.ShapeType() == "Face" and entity.geomType() in {"CYLINDER", "CONE", "TORUS"}:
            adaptor = BRepAdaptor_Surface(entity.wrapped)
            surface = {"CYLINDER": adaptor.Cylinder, "CONE": adaptor.Cone, "TORUS": adaptor.Torus}[entity.geomType()]()
            return "axis", surface.Axis().Direction().Coord()
        return None

    a, b = direction(entities[0]), direction(entities[1])
    if a is not None and b is not None:
        dot = max(0, min(1, abs(sum(x * y for x, y in zip(a[1], b[1])))))
        if (a[0] == "plane") != (b[0] == "plane"):
            angle = math.asin(dot)
            label = "Line–plane angle" if "line" in {a[0], b[0]} else "Axis–plane angle"
        else:
            angle = math.acos(dot)
            label = "Plane angle" if a[0] == b[0] == "plane" else "Line angle" if a[0] == b[0] == "line" else "Axis angle"
        metric("pair:angle", label + " (acute)", [angle * 180 / math.pi], "°")

    if all(entity.ShapeType() == "Edge" and entity.geomType() == "CIRCLE" for entity in entities):
        from OCP.BRepAdaptor import BRepAdaptor_Curve
        centers = [list(BRepAdaptor_Curve(entity.wrapped).Circle().Location().Coord()) for entity in entities]
        delta = [b - a for a, b in zip(*centers)]
        metric("pair:centerDistance", "Circle center distance", [math.sqrt(sum(value * value for value in delta))], "mm")
        metric("pair:centerDelta", "Circle center delta X, Y, Z", delta, "mm")
    report.update(metrics=metrics, closestPoints=[first, second])
    return report


MAX_CLEARANCE_PAIRS = 8
MAX_CLEARANCE_POSES = 361
CONTACT_DISTANCE = 1e-6


def clearance_brep(spec, asset_directory, cq, threads):
    """Exact minimum separation between part groups at each rigid assembly pose.

    Each pose is a sparse list of rigid world-space deltas, as in measurement.
    A zero distance includes the common volume, which separates surface contact
    from interference. Nothing is meshed, serialized or rebuilt.
    """
    if not {"operation", "brepAsset", "pairs", "poses"} <= set(spec) or set(spec) - NATIVE_SOURCE_FIELDS - {"operation", "pairs", "poses"}:
        raise ModelError("The clearance request contains unsupported fields.")
    shape = read_brep(spec, asset_directory, cq, threads)
    solids = _shape_entities(shape, "Solid")
    pairs, poses = spec["pairs"], spec["poses"]
    if not isinstance(pairs, list) or not 1 <= len(pairs) <= MAX_CLEARANCE_PAIRS:
        raise ModelError("A clearance check requires between 1 and 8 part pairs.")
    if not isinstance(poses, list) or not 1 <= len(poses) <= MAX_CLEARANCE_POSES:
        raise ModelError("A clearance check requires between 1 and 361 poses.")
    groups = []
    for pair in pairs:
        if not isinstance(pair, list) or len(pair) != 2:
            raise ModelError("Each clearance pair requires two groups of solid indices.")
        selected = [selected_solids({"solidIndices": group}, solids) for group in pair]
        if not all(selected) or set(selected[0]) & set(selected[1]):
            raise ModelError("Each clearance pair requires two nonempty, disjoint groups of solids.")
        groups.append(selected)

    from OCP.BRepAlgoAPI import BRepAlgoAPI_Common
    from OCP.BRepExtrema import BRepExtrema_DistShapeShape
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps

    def combined(posed, indices):
        return posed[indices[0]] if len(indices) == 1 else cq.Compound.makeCompound([posed[index] for index in indices])

    samples = []
    for records in poses:
        posed = posed_solids(solids, records, cq)
        results = []
        for first, second in groups:
            a, b = combined(posed, first), combined(posed, second)
            extrema = BRepExtrema_DistShapeShape()
            extrema.LoadS1(a.wrapped)
            extrema.LoadS2(b.wrapped)
            extrema.SetMultiThread(True)
            extrema.Perform()
            if not extrema.IsDone() or not extrema.NbSolution():
                raise ModelError("OpenCascade could not determine the clearance between these parts.")
            distance = max(0.0, extrema.Value())
            item = {"distance": distance,
                    "closestPoints": [list(extrema.PointOnShape1(1).Coord()), list(extrema.PointOnShape2(1).Coord())]}
            if distance <= CONTACT_DISTANCE:
                common = BRepAlgoAPI_Common(a.wrapped, b.wrapped)
                volume = None
                if common.IsDone():
                    properties = GProp_GProps()
                    BRepGProp.VolumeProperties_s(common.Shape(), properties)
                    if math.isfinite(properties.Mass()):
                        volume = max(0.0, properties.Mass())
                item["overlapVolume"] = volume
            results.append(item)
        samples.append(results)
    return {"samples": samples}


def verify_brep(spec, asset_directory, output, cq, threads):
    """Run the checks a preview build deferred, on that build's own native solid.

    Exact topology and shell validation and STEP roundtrip verification are
    what acceptance requires, not what a display needs. A build may defer them
    so its design displays first; this performs exactly those checks, and a
    design is accepted only after they pass.
    """
    if set(spec) - {"operation", "expectedParts"} - NATIVE_SOURCE_FIELDS:
        raise ModelError("Verification accepts only a build's native solid and its part measurements.")
    import tempfile
    # The build already checked closed solids; the exact checks follow here.
    shape = read_brep({**spec, "validatedNative": True}, asset_directory, cq, threads)
    stats = {}
    validate_shape(shape, preview_stats=stats)
    # Compare the STEP readback with the parts the build measured on the shape
    # it produced, as a build that runs these checks does. The optimal bounds
    # of some trimmed periodic faces change once the solid is written as BREP
    # and read again, although its geometry does not.
    expected = _expected_parts(spec.get("expectedParts"), len(stats["solids"]))
    with tempfile.TemporaryDirectory(prefix=".step-validation-", dir=output) as directory:
        step = Path(directory) / "candidate.step"
        write_step(stats["solids"], step, cq)
        validate_step_roundtrip(shape, cq, step, preview_stats={**stats, "solidProperties": expected})
    return {"verified": True}


def _expected_parts(records, count):
    """A verification's per-part measurements from its build, one per solid."""
    def numbers(value, length):
        return (isinstance(value, list) and len(value) == length
                and all(isinstance(item, (int, float)) and not isinstance(item, bool) and math.isfinite(item)
                        for item in value))
    if (not isinstance(records, list) or len(records) != count
            or any(not isinstance(record, dict) or set(record) != {"volume", "area", "bounds", "centroid"}
                   or not numbers([record["volume"], record["area"]], 2)
                   or not numbers(record["bounds"], 6) or not numbers(record["centroid"], 3) for record in records)):
        raise ModelError("Verification requires the build's measurements for each of its solids.")
    return [{key: record[key] for key in ("volume", "area", "bounds", "centroid")} for record in records]


def runtime_info(cq):
    import platform
    from importlib.metadata import PackageNotFoundError, version
    try:
        ocp_version = version("cadquery-ocp")
    except PackageNotFoundError:
        import OCP
        ocp_version = getattr(OCP, "__version__", "unknown")
    return {"python": platform.python_version(), "cadquery": cq.__version__, "ocp": ocp_version}


# The validation rules a receipt certifies. A matching receipt lets replay skip
# exact BRep/shell checks and STEP roundtrip verification, so bump this when
# those checks change or when anything changes the geometry they validated:
# program execution, input import, tolerance handling, assembly and motion
# adaptation, or STEP export and readback. Other worker edits keep receipts.
VALIDATION_RULES_VERSION = 1


def validation_hash(spec, directory, cq):
    """Bind validation to exact replay inputs, kernel versions and worker rules.

    This is an accidental-change detector, not an authenticity signature.
    Never hash a user-supplied flag or generated geometry into the receipt.
    """
    import stat
    digest = hashlib.sha256()
    def add(data):
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    add(f"lad-validation-rules-{VALIDATION_RULES_VERSION}".encode())
    add(json.dumps(runtime_info(cq), sort_keys=True, separators=(",", ":")).encode())
    # Match the app's validated-preview reuse contract: display metadata can
    # change between a successful candidate and its final saved revision.
    # Imported-assets insertion order remains significant to Python programs.
    construction = {"units": spec["units"], "script": spec["script"],
                    "sourceAsset": bool(spec.get("sourceAsset")),
                    "inputAssets": [{"id": asset["id"], "format": asset["format"]}
                                    for asset in spec.get("inputAssets", [])]}
    # The printing version is a different construction of the same program.
    if spec.get("print"):
        construction["print"] = True
    add(json.dumps(construction, sort_keys=True, separators=(",", ":")).encode())
    paths = ([directory / "source.step"] if spec.get("sourceAsset") else [])
    paths += [directory / asset["path"] for asset in spec.get("inputAssets", [])]
    for path in paths:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
            raise ModelError("Imported geometry must be a regular private file of at most 512 MB.")
        add(path.read_bytes())
    return digest.hexdigest()


def run(request, output, threads, defer_step=False, validated_hash=None, native_only=False, verify_later=False):
    if not 1 <= threads <= 256:
        raise HostError("Thread count must be between 1 and 256.")
    size = request.stat().st_size
    if size > 16 * 1024 * 1024:
        raise ModelError("CAD request exceeds the 16 MiB size limit.")
    spec = json.loads(request.read_text())
    if native_only and not (isinstance(spec, dict) and spec.get("operation") in NATIVE_OPERATIONS):
        # The serving worker runs outside the program sandbox.
        raise ModelError("This worker performs only native geometry operations.")
    if isinstance(spec, dict) and str(spec.get("operation", "")).startswith("mesh_"):
        from mesh_tools import execute, envelope, diagnostic, canonical
        try:
            # Lend mesh tools this loaded module (__main__ when run as a script).
            return execute(spec, request.parent.resolve(), output, threads, worker=sys.modules[__name__])
        except Exception as error:
            # Domain failures remain inspectable tool results. The native host
            # never receives a candidate artifact from an unsuccessful call.
            result = envelope({}, None, "error", [diagnostic(getattr(error, "code", "INVALID_REQUEST"), str(error))])
            output.mkdir(parents=True, exist_ok=True)
            (output / "mesh-result.json").write_bytes(canonical(result))
            (output / "mesh-record.json").write_bytes(canonical(result))
            return result
    is_preview = isinstance(spec, dict) and spec.get("operation") == "preview"
    is_export = isinstance(spec, dict) and spec.get("operation") == "export"
    is_parts_export = is_export and "individualParts" in spec
    is_drawing = isinstance(spec, dict) and spec.get("operation") == "dxf"
    is_measurement = isinstance(spec, dict) and spec.get("operation") in ("measure", "clearance", "print_orient", "verify")
    is_runtime = spec == {"operation": "runtime"}
    if not is_preview and not is_export and not is_drawing and not is_measurement and not is_runtime:
        if size > 2 * 1024 * 1024:
            raise ModelError("Design specification exceeds the 2 MiB size limit.")
        validate_spec(spec)
    output.mkdir(parents=True, exist_ok=True)
    # Imported modules may cache font information; keep all such files local.
    os.environ.setdefault("MPLCONFIGDIR", str(output / ".matplotlib"))
    import cadquery as cq
    started = time.perf_counter()
    step = (output / "model.step").resolve()
    if is_runtime:
        preview = {}
    elif is_measurement and spec["operation"] == "clearance":
        preview = clearance_brep(spec, request.parent.resolve(), cq, threads)
    elif is_measurement and spec["operation"] == "print_orient":
        preview = print_orient_brep(spec, request.parent.resolve(), cq, threads)
    elif is_measurement and spec["operation"] == "verify":
        preview = verify_brep(spec, request.parent.resolve(), output, cq, threads)
    elif is_measurement:
        preview = measure_brep(spec, request.parent.resolve(), cq, threads)
    elif is_export:
        preview = export_brep(spec, request.parent.resolve(), output, cq, threads)
    elif is_drawing:
        preview = export_face_dxf(spec, request.parent.resolve(), output, cq, threads)
    elif is_preview:
        preview = preview_step(spec, request.parent.resolve(), output, cq, threads)
    else:
        fingerprint = validation_hash(spec, request.parent.resolve(), cq)
        reuse_validation = validated_hash == fingerprint
        # A preview can display before its exact checks and STEP roundtrip;
        # a separate `verify` of its native solid must pass before acceptance.
        deferred = verify_later and defer_step and not reuse_validation
        preview_stats = {}
        token = _validated_replay.set(reuse_validation)
        try:
            shape = build_shape(spec, threads, request.parent.resolve(), preview_stats=preview_stats,
                                validated_copies=output, exact=not deferred)
            # A successful native build is not sufficient: STEP translation can
            # turn closed native geometry into open shells. Verify it before the
            # candidate can be accepted, here or in its deferred verification.
            # Export the same unique physical solids as the app's colored exporter.
            solids = preview_stats["solids"]
            if reuse_validation:
                if not defer_step:
                    write_step(solids, step, cq)
            elif deferred:
                pass
            elif defer_step:
                import tempfile
                with tempfile.TemporaryDirectory(prefix=".step-validation-", dir=output) as directory:
                    validation_step = Path(directory) / "candidate.step"
                    write_step(solids, validation_step, cq)
                    validate_step_roundtrip(shape, cq, validation_step, preview_stats=preview_stats)
            else:
                write_step(solids, step, cq)
                validate_step_roundtrip(shape, cq, step, preview_stats=preview_stats)
            try:
                preview = make_preview(shape, preview_stats=preview_stats)
            except ModelError:
                if deferred:
                    # Report the deferred exact check's failure, which names the
                    # defective topology, rather than its display consequence.
                    validate_shape(shape)
                raise
        finally:
            _validated_replay.reset(token)
        preview["pendingValidationHash" if deferred else "validatedHash"] = fingerprint
    if not is_export and not is_drawing and not is_measurement and not is_preview and not is_runtime:
        # Both STEP imports and generated previews retain the identical native
        # topology so later measurements cannot be remapped by a STEP roundtrip.
        brep = (output / "model.brep").resolve()
        write_brep(shape, brep)
        preview["brepPath"] = str(brep)
    if not is_runtime and not is_measurement and not is_drawing and not is_parts_export and (not defer_step or is_preview or is_export) and (not step.is_file() or step.stat().st_size < 100):
        raise ModelError("STEP export did not produce a design file.")
    preview.update(buildSeconds=time.perf_counter() - started, threads=threads, runtime=runtime_info(cq))
    if not is_parts_export and not is_drawing:
        preview["stepPath"] = str(step)
    write_preview_result(preview, output)
    return preview


def serve():
    """Answer native-geometry requests from the app, one JSON line each.

    Each request names a request file, an output folder and a thread count; the
    reply reports completion or the error, and results stay in that folder.
    Native output and stray prints go to stderr so they cannot corrupt replies.
    The loop ends when the app closes stdin, including when it exits.
    """
    global _serving
    _serving = True
    replies = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    for line in sys.stdin:
        message, output = None, None
        try:
            message = json.loads(line)
            output = Path(message["output"])
            run(Path(message["request"]), output, int(message["threads"]), native_only=True)
            reply = {"id": message["id"], "status": "complete"}
        except Exception as error:
            if output is not None:
                try:
                    write_error_report(error, output)
                except Exception:
                    pass
            reply = {"id": message.get("id") if isinstance(message, dict) else None, "status": "error",
                     "message": f"LAD CAD engine: {error}"[:16_000]}
        replies.write(json.dumps(reply) + "\n")
    return 0


BUILD_OPTIONS = {"threads", "deferStep", "validatedHash", "verifyLater"}


def await_build(start):
    """Load the CAD runtime, then wait for one build's options on `start`.

    The app starts a sandboxed worker before its next build is requested, so
    Python, CadQuery and NumPy are already imported when it is. The app stages
    the request in the output directory and writes the options to this private
    FIFO. The worker runs exactly one program and exits once LAD does.
    """
    import threading
    parent = os.getppid()

    def watch():
        # An orphan is reparented to launchd, possibly before this started.
        while os.getppid() == parent != 1:
            time.sleep(1)
        os._exit(1)

    threading.Thread(target=watch, daemon=True).start()
    import cadquery  # noqa: F401 -- the import this worker loads ahead of its build
    import numpy  # noqa: F401
    with open(start, "rb") as stream:
        options = json.loads(stream.read(4_096))
    if (not isinstance(options, dict) or set(options) - BUILD_OPTIONS
            or isinstance(options.get("threads"), bool) or not isinstance(options.get("threads"), int)
            or any(not isinstance(options.get(name, False), bool) for name in ("deferStep", "verifyLater"))
            or not isinstance(options.get("validatedHash", ""), str)):
        raise HostError("The CAD build options are invalid.")
    return options


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", help="Answer native-geometry requests on stdin.")
    parser.add_argument("--request", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--threads", type=int, default=max(1, min(32, os.cpu_count() or 1)))
    parser.add_argument("--defer-step", action="store_true",
                        help="Verify a temporary STEP, then retain only the preview and private native solid.")
    parser.add_argument("--validated-hash", help="Reuse successful validation of identical replay inputs.")
    parser.add_argument("--verify-later", action="store_true",
                        help="With --defer-step, leave exact checks and STEP verification to a separate verify request.")
    parser.add_argument("--await-build", type=Path,
                        help="Load the CAD runtime, then read one build's options from this FIFO; the request is in --output.")
    arguments = parser.parse_args()
    if arguments.serve:
        return serve()
    if arguments.await_build is not None and arguments.output is not None:
        try:
            options = await_build(arguments.await_build)
        except Exception as error:
            try:
                write_error_report(error, arguments.output)
            except Exception:
                pass
            print(f"LAD CAD engine: {error}", file=sys.stderr)
            return 1
        arguments.request = arguments.output / "request.json"
        arguments.threads = options["threads"]
        arguments.defer_step = options.get("deferStep", False)
        arguments.verify_later = options.get("verifyLater", False)
        arguments.validated_hash = options.get("validatedHash")
    if arguments.request is None or arguments.output is None:
        parser.error("--request and --output are required")
    try:
        result = run(arguments.request, arguments.output, arguments.threads, arguments.defer_step, arguments.validated_hash,
                     verify_later=arguments.verify_later)
        print(json.dumps({"status": "complete", "solids": result.get("solids"), "faces": result.get("faces")}))
    except Exception as error:
        try:
            write_error_report(error, arguments.output)
        except Exception:
            # Report publication must not replace the original CAD failure.
            pass
        print(f"LAD CAD engine: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
