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
GEOMETRY_TOLERANCE_MM = 1e-4
LIMIT = 100_000.0
_validated_replay = ContextVar("validated_replay", default=False)
_validation_scope = ContextVar("validation_scope", default="native_candidate")
_validation_input = ContextVar("validation_input", default=None)

ROOT_KEYS = {"title", "summary", "units", "script"}


class ModelError(ValueError):
    """An actionable, user-visible modeling error."""

    def __init__(self, message, *, diagnostic=None):
        super().__init__(message)
        self.diagnostic = diagnostic


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
    if not isinstance(spec, dict) or not ROOT_KEYS <= set(spec) or set(spec) - ROOT_KEYS - {"sourceAsset", "inputAssets"}:
        raise ModelError("Design must contain title, summary, units and a complete Python script.")
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
    assets = spec.get("inputAssets", [])
    if not isinstance(assets, list) or len(assets) > 256:
        raise ModelError("Imported geometry contains too many input assets.")
    seen = set()
    for index, asset in enumerate(assets):
        if (not isinstance(asset, dict) or set(asset) != {"id", "name", "format", "path"}
                or not isinstance(asset["id"], str) or not 1 <= len(asset["id"]) <= 1024
                or any(ord(char) < 32 for char in asset["id"]) or asset["id"] in seen
                or not isinstance(asset["name"], str) or not 1 <= len(asset["name"]) <= 255
                or not isinstance(asset["format"], str) or asset["format"] not in {"step", "stp", "brep", "stl", "obj"}
                or asset["path"] != f"input-{index:03d}.{asset['format']}"):
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


def validate_shape(shape, preview_stats=None):
    """Validate exact, closed geometry before meshing or accepting a build."""
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
    if not _validated_replay.get():
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


def assembly_parts(assembly, shape):
    """Keep named assembly structure mapped to the exported solid ordering.

    Locations are composed in the same parent-before-child order as CadQuery's
    Assembly iterator. Shape identity includes the native location, so repeated
    instances of one shape map to their own bodies without comparing geometry
    or changing the model's coordinates.
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

    def visit(node, parent_location, path, parent_color=None):
        location = parent_location * node.loc
        color = assembly_part_color(node.color) if node.color is not None else parent_color
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
            part = visit(child, location, path + [supplied_name(child) or f"@{index}"], color)
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


def build_script(script, cq, source_asset=None, input_assets=None, preview_stats=None):
    """Run ordinary Python with the installed CadQuery/OpenCascade APIs.

    This is intentionally not a Python-language security boundary. The native
    app applies a macOS process sandbox restricting files, subprocesses and
    networking. CLI callers must apply equivalent isolation for untrusted code.
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
    namespace = {"cq": cq, "math": math, "np": np, "__name__": "__lad_model__"}
    namespace["imported_assets"] = {}
    for asset, path in input_assets or []:
        with validation_scope("input_asset", {"id": asset["id"], "name": asset["name"], "format": asset["format"]}):
            namespace["imported_assets"][asset["id"]] = import_input_asset(path, asset["format"], cq)
    if source_asset is not None:
        import stat
        try:
            info = source_asset.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
                raise ModelError("The imported STEP asset must be a regular private file of at most 512 MB.")
            with validation_scope("source_step", {"name": source_asset.name, "format": "step"}):
                imported = import_step(source_asset, cq)
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
    validate_shape(result, preview_stats=preview_stats)
    if assembly is not None:
        result._lad_parts = assembly_parts(assembly, result)
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


def build_shape(spec, threads=1, asset_directory=None, preview_stats=None):
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
    return build_script(spec["script"], cq, source_asset, staged, preview_stats=preview_stats)


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


def _preview_edge_polyline(edge, mesh_polylines, tolerance):
    """Use the face mesher's boundary, with analytic sampling only as fallback."""
    for native, polyline in mesh_polylines.get(hash(edge.wrapped), ()):
        if native.IsSame(edge.wrapped):
            return polyline
    count = 2 if edge.geomType() == "LINE" else min(256, max(16, math.ceil(edge.Length() / max(tolerance * 8, 0.1))))
    sampled, _ = edge.sample(count)
    polyline = [list(point.toTuple()) for point in sampled]
    # CadQuery omits the duplicate final point for closed curves. Both the
    # display segments and topology polyline need the last-to-first segment.
    if edge.IsClosed() and len(polyline) > 1 and polyline[-1] != polyline[0]:
        polyline.append(polyline[0].copy())
    return polyline


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
    from OCP.BRep import BRep_Tool
    from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
    from OCP.gp import gp_Pnt
    surface = BRep_Tool.Surface_s(face.wrapped)
    for triangle in result:
        corners = np.asarray([points[index] for index in triangle])
        samples = [corners.mean(axis=0)] + [(corners[index] + corners[(index + 1) % 3]) / 2 for index in range(3)]
        for sample in samples:
            projection = GeomAPI_ProjectPointOnSurf(gp_Pnt(*sample), surface)
            if not projection.NbPoints() or not projection.LowerDistance() <= tolerance:
                raise _PreviewMeshError("a repaired surface patch exceeds the display surface deflection")
    return result


def _preview_triangle_matches_surface(face, corners, uv, tolerance, distance_limit):
    """Check suspect cells against their own surface and parameter chart."""
    from OCP.BRep import BRep_Tool
    from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
    from OCP.gp import gp_Pnt
    try:
        surface = BRep_Tool.Surface_s(face.wrapped)
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
                projection = GeomAPI_ProjectPointOnSurf(gp_Pnt(*point), surface)
                if not projection.NbPoints() or not projection.LowerDistance() <= distance_limit:
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
    orientation_cache = {}

    def raw_audit(cells):
        corners = xyz[cells]
        planes = np.cross(corners[..., 1, :] - corners[..., 0, :], corners[..., 2, :] - corners[..., 0, :])
        lengths = np.linalg.norm(planes, axis=-1)
        dots = np.divide((planes * exact[cells].mean(axis=-2)).sum(axis=-1), lengths,
                         out=np.zeros_like(lengths), where=lengths > 1e-20)
        return dots, lengths

    def audit(cells):
        nonlocal uv, surface
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
                surface = BRepGProp_Face(face.wrapped)
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
                                or _preview_triangle_matches_surface(face, corners[index], cell_uv, tolerance, tolerance)):
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
                                                              GEOMETRY_TOLERANCE_MM)):
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
        refined = []
        for cell in indices.tolist():
            middle = [midpoints.get(tuple(sorted((cell[index], cell[(index + 1) % 3])))) for index in range(3)]
            count = sum(node is not None for node in middle)
            if count == 0:
                refined.append(cell)
            elif count == 1:
                offset = next(index for index, node in enumerate(middle) if node is not None)
                a, b, c = [cell[(offset + index) % 3] for index in range(3)]
                m = middle[offset]
                refined.extend(((a, m, c), (m, b, c)))
            elif count == 2:
                missing = next(index for index, node in enumerate(middle) if node is None)
                offset = (missing + 1) % 3
                a, b, c = [cell[(offset + index) % 3] for index in range(3)]
                m, n = middle[offset], middle[(offset + 1) % 3]
                refined.extend(((b, n, m), (a, m, c), (m, n, c)))
            else:
                a, b, c = cell
                m, n, p = middle
                refined.extend(((a, m, p), (m, b, n), (p, n, c), (m, n, p)))
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
        result = set()
        for edge in edges:
            for wrapped in (edge.wrapped, TopoDS.Edge(edge.wrapped.Reversed())):
                polygon = BRep_Tool.PolygonOnTriangulation_s(wrapped, poly, location)
                if polygon is not None:
                    nodes = polygon.Nodes()
                    sequence = [nodes.Value(index) - 1 for index in range(nodes.Lower(), nodes.Upper() + 1)]
                    result.update(tuple(sorted(pair)) for pair in zip(sequence, sequence[1:]))
        return result
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


def _preview_mesh(shape, solids, tolerance):
    from OCP.BRep import BRep_Tool
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    from OCP.BRepTools import BRepTools
    from OCP.IMeshTools import IMeshTools_Parameters, IMeshTools_MeshAlgoType
    from OCP.TopLoc import TopLoc_Location
    faces = [[(face, _shape_entities(face, "Edge")) for face in _shape_entities(solid, "Face")] for solid in solids]
    # Retain healthy native meshes; retry only a failed display candidate.
    # Small connector blends can need finer boundary angles even when the
    # assembly-wide linear deflection is already adequate.
    attempts = [(IMeshTools_MeshAlgoType.IMeshTools_MeshAlgoType_Watson, angle, tolerance, False)
                for angle in (0.15, 0.07)] + [
        (IMeshTools_MeshAlgoType.IMeshTools_MeshAlgoType_Delabella, angle, tolerance, False)
        for angle in (0.16, 0.14, 0.18, 0.20)]
    # Pole-adjacent trims can still fold an analytic sphere's native mesh at
    # every ordinary angle. Refine its boundary and surface sampling together
    # before giving up; do not flip those facets or alter the exact geometry.
    attempts += [(IMeshTools_MeshAlgoType.IMeshTools_MeshAlgoType_Delabella, 0.20, tolerance * factor, False)
                 for factor in (0.25, 0.125)]
    refinement_queued = False
    for attempt, (algorithm, angle, linear_deflection, refine_surface) in enumerate(attempts):
        if attempt:
            BRepTools.Clean_s(shape.wrapped)
        parameters = IMeshTools_Parameters()
        parameters.Deflection, parameters.Angle = linear_deflection, angle
        parameters.Relative, parameters.InParallel = False, True
        parameters.ControlSurfaceDeflection = not refine_surface
        # Watson can report success with folded facets and large missing areas
        # on trimmed analytic spheres. Try an independent native triangulator.
        parameters.MeshAlgo = algorithm
        mesher = BRepMesh_IncrementalMesh(shape.wrapped, parameters)
        failure_feature = None
        if not mesher.IsDone():
            failure = "OpenCascade did not complete triangulation"
            continue
        result = []
        total_nodes, total_triangles = 0, 0
        try:
            for solid_index, solid_faces in enumerate(faces):
                chunks = []
                for local_index, (face, edges) in enumerate(solid_faces):
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
                result.append(chunks)
            return result
        except _PreviewMeshError as error:
            failure = f"part {solid_index + 1}, face {local_index + 1}: {error}"
            failure_feature = feature_id("face", solid_index, local_index)
            if error.refine_surface and not refinement_queued:
                # A highly sheared chart can make native surface refinement
                # manufacture hundreds of thousands of folded cells. Try one
                # coarse seed instead, with LAD's independent, bounded exact-
                # surface refinement and complete trim audit on every face.
                attempts.insert(attempt + 1, (algorithm, angle, linear_deflection, True))
                refinement_queued = True
    diagnostic = {"stage": "preview_meshing", "geometryScope": "native_candidate",
                  "openCascadeMeshingStatus": mesher.GetStatusFlags(),
                  "linearDeflectionMM": linear_deflection, "angularDeflectionRadians": angle,
                  "independentSurfaceRefinement": refine_surface,
                  "meshingAlgorithm": "Watson" if algorithm == attempts[0][0] else "Delabella"}
    if failure_feature is not None:
        diagnostic["feature"] = failure_feature
    raise ModelError(f"OpenCascade could not produce a complete design preview ({failure}).",
                     diagnostic=diagnostic)


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
    # Keep an explicit triangle-to-solid mapping for native part picking. A
    # fused body is one selectable solid; a disconnected union/pattern has
    # multiple selectable solids. Tessellating each solid retains CadQuery's
    # per-face vertex boundaries and correct face orientation.
    vertices, normals, triangles, triangle_solids, triangle_faces = [], [], [], [], []
    topology = {"vertices": [], "edges": [], "faces": [], "parts": []}
    mesh_polylines = [{} for _ in solids]
    mesh_edge_segments = 0
    for solid_index, solid in enumerate(solids):
        topology["parts"].append(prepared["solidProperties"][solid_index] if prepared is not None
                                 else part_metadata(solid, solid_index, bounds=solid_bounds[solid_index]))
        topology["vertices"].extend({"id": feature_id("vertex", solid_index, local_index),
                                      "position": list(vertex.toTuple())}
                                     for local_index, vertex in enumerate(_shape_entities(solid, "Vertex")))
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
            # Native hashes ignore orientation; IsSame resolves collisions and
            # keeps repeated/located instances separate within each owner.
            polylines = mesh_polylines[solid_index]
            for edge in face_edges:
                bucket = polylines.setdefault(hash(edge.wrapped), [])
                if any(native.IsSame(edge.wrapped) for native, _ in bucket):
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
                bucket.append((edge.wrapped, points))
    segments, edge_solids, edge_features = [], [], []
    for solid_index, solid in enumerate(solids):
        for local_index, edge in enumerate(_shape_entities(solid, "Edge")):
            # Keep shared edges per owner so hiding a part removes all its
            # boundaries without also hiding a visible neighboring body.
            points = _preview_edge_polyline(edge, mesh_polylines[solid_index], tolerance)
            edge_index = len(topology["edges"])
            topology["edges"].append(edge_metadata(edge, solid_index, local_index, points))
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
    return {
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
        from OCP.BRep import BRep_Builder
        from OCP.BRepTools import BRepTools
        from OCP.TopoDS import TopoDS_Shape
        with path.open("rb") as stream:
            if not stream.read(128).startswith(b"DBRep_DrawableShape\n"):
                raise ModelError("The imported BREP asset is invalid.")
        wrapped = TopoDS_Shape()
        if not BRepTools.Read_s(wrapped, str(path), BRep_Builder()) or wrapped.IsNull():
            raise ModelError("The imported BREP asset could not be read.")
        return validate_shape(cq.Shape.cast(wrapped))
    if format in {"stl", "obj"}:
        return mesh_to_solid(read_mesh(path, format), cq)
    raise ModelError("Unsupported imported geometry format.")


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
    """Read only the private, app-staged native geometry, without meshing."""
    if spec.get("brepAsset") != "source.brep":
        raise ModelError("Native operations require the private source.brep asset.")
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
    with validation_scope("native_artifact", {"name": source.name, "format": "brep"}):
        return validate_shape(cq.Shape.cast(wrapped))


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


def export_brep(spec, asset_directory, output, cq, threads):
    """Create whole or selected STEP without replaying or tessellating."""
    if set(spec) - {"operation", "brepAsset", "solidIndices", "solidColors"} or spec.get("brepAsset") != "source.brep":
        raise ModelError("STEP export requires the private source.brep asset.")
    shape = read_brep(spec, asset_directory, cq, threads)
    solids = shape.Solids()
    indices = selected_solids(spec, solids)
    colors = export_solid_colors(spec.get("solidColors", []), len(solids))
    if not indices:
        raise ModelError("Select at least one part to export.")
    if set(indices) != set(range(len(solids))):
        chosen = [solids[index] for index in indices]
        shape = chosen[0] if len(chosen) == 1 else cq.Compound.makeCompound(chosen)
    else:
        indices = list(range(len(solids)))
    step = output / "model.step"
    write_step(solids, step, cq, colors=colors, indices=indices)
    return {"solids": len(shape.Solids()), "faces": len(shape.Faces())}


def measure_brep(spec, asset_directory, cq, threads):
    """Exact minimum separation of two bounded native entities.

    The app supplies precomputed single-item properties. This operation does
    not mesh, execute programs, or serialize STEP; all closest points come from
    OpenCascade's extrema solver on the selected trimmed topology.
    """
    if set(spec) - {"operation", "brepAsset", "features", "solidIndices"}:
        raise ModelError("The measurement request contains unsupported fields.")
    shape = read_brep(spec, asset_directory, cq, threads)
    solids = shape.Solids()
    indices = selected_solids(spec, solids, required=True)
    features = spec.get("features", [])
    if not isinstance(features, list) or len(features) > 2:
        raise ModelError("Choose two items for an exact distance measurement.")
    entities = []
    seen = set()
    for feature in features:
        if not isinstance(feature, dict) or set(feature) != {"kind", "solidIndex", "localIndex"}:
            raise ModelError("The selected topology reference is invalid.")
        kind, owner, local = feature["kind"], feature["solidIndex"], feature["localIndex"]
        if (kind not in {"vertex", "edge", "face"} or isinstance(owner, bool) or not isinstance(owner, int)
                or not 0 <= owner < len(solids) or isinstance(local, bool) or not isinstance(local, int)):
            raise ModelError("The selected topology reference is invalid.")
        values = {"vertex": solids[owner].Vertices, "edge": solids[owner].Edges, "face": solids[owner].Faces}[kind]()
        if not 0 <= local < len(values) or (kind, owner, local) in seen:
            raise ModelError("The selected topology reference is missing or duplicated.")
        seen.add((kind, owner, local))
        entities.append(values[local])
    entities.extend(solids[index] for index in indices)
    if len(entities) != 2:
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
    return {"title": "Measurements", "metrics": metrics, "features": features, "solidIndices": indices,
            "closestPoints": [first, second], "solids": len(solids), "faces": len(shape.Faces())}


def runtime_info(cq):
    import platform
    from importlib.metadata import PackageNotFoundError, version
    try:
        ocp_version = version("cadquery-ocp")
    except PackageNotFoundError:
        import OCP
        ocp_version = getattr(OCP, "__version__", "unknown")
    return {"python": platform.python_version(), "cadquery": cq.__version__, "ocp": ocp_version}


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
    add(Path(__file__).read_bytes())
    add(json.dumps(runtime_info(cq), sort_keys=True, separators=(",", ":")).encode())
    # Match the app's validated-preview reuse contract: display metadata can
    # change between a successful candidate and its final saved revision.
    # Imported-assets insertion order remains significant to Python programs.
    construction = {"units": spec["units"], "script": spec["script"],
                    "sourceAsset": bool(spec.get("sourceAsset")),
                    "inputAssets": [{"id": asset["id"], "format": asset["format"]}
                                    for asset in spec.get("inputAssets", [])]}
    add(json.dumps(construction, sort_keys=True, separators=(",", ":")).encode())
    paths = ([directory / "source.step"] if spec.get("sourceAsset") else [])
    paths += [directory / asset["path"] for asset in spec.get("inputAssets", [])]
    for path in paths:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_GEOMETRY_BYTES:
            raise ModelError("Imported geometry must be a regular private file of at most 512 MB.")
        add(path.read_bytes())
    return digest.hexdigest()


def run(request, output, threads, defer_step=False, validated_hash=None):
    if not 1 <= threads <= 256:
        raise ModelError("Thread count must be between 1 and 256.")
    size = request.stat().st_size
    if size > 16 * 1024 * 1024:
        raise ModelError("CAD request exceeds the 16 MiB size limit.")
    spec = json.loads(request.read_text())
    if isinstance(spec, dict) and str(spec.get("operation", "")).startswith("mesh_"):
        from mesh_tools import execute, envelope, diagnostic, canonical
        try:
            return execute(spec, request.parent.resolve(), output, threads)
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
    is_measurement = isinstance(spec, dict) and spec.get("operation") == "measure"
    is_runtime = spec == {"operation": "runtime"}
    if not is_preview and not is_export and not is_measurement and not is_runtime:
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
    elif is_measurement:
        preview = measure_brep(spec, request.parent.resolve(), cq, threads)
    elif is_export:
        preview = export_brep(spec, request.parent.resolve(), output, cq, threads)
    elif is_preview:
        preview = preview_step(spec, request.parent.resolve(), output, cq, threads)
    else:
        fingerprint = validation_hash(spec, request.parent.resolve(), cq)
        reuse_validation = validated_hash == fingerprint
        preview_stats = {}
        token = _validated_replay.set(reuse_validation)
        try:
            shape = build_shape(spec, threads, request.parent.resolve(), preview_stats=preview_stats)
            # A successful native build is not sufficient: STEP translation can
            # turn closed native geometry into open shells. Verify it before the
            # candidate can be rendered, reused by lad_validate or committed.
            # Export the same unique physical solids as the app's colored exporter.
            solids = preview_stats["solids"]
            if reuse_validation:
                if not defer_step:
                    write_step(solids, step, cq)
            elif defer_step:
                import tempfile
                with tempfile.TemporaryDirectory(prefix=".step-validation-", dir=output) as directory:
                    validation_step = Path(directory) / "candidate.step"
                    write_step(solids, validation_step, cq)
                    validate_step_roundtrip(shape, cq, validation_step, preview_stats=preview_stats)
            else:
                write_step(solids, step, cq)
                validate_step_roundtrip(shape, cq, step, preview_stats=preview_stats)
            preview = make_preview(shape, preview_stats=preview_stats)
        finally:
            _validated_replay.reset(token)
        preview["validatedHash"] = fingerprint
    if not is_export and not is_measurement and not is_preview and not is_runtime:
        # Both STEP imports and generated previews retain the identical native
        # topology so later measurements cannot be remapped by a STEP roundtrip.
        brep = (output / "model.brep").resolve()
        write_brep(shape, brep)
        preview["brepPath"] = str(brep)
    if not is_runtime and not is_measurement and (not defer_step or is_preview or is_export) and (not step.is_file() or step.stat().st_size < 100):
        raise ModelError("STEP export did not produce a design file.")
    preview.update(buildSeconds=time.perf_counter() - started, threads=threads,
                   stepPath=str(step), runtime=runtime_info(cq))
    temporary = output / "result.json.tmp"
    temporary.write_text(json.dumps(preview, separators=(",", ":"), allow_nan=False))
    temporary.replace(output / "result.json")
    return preview


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--threads", type=int, default=max(1, min(32, os.cpu_count() or 1)))
    parser.add_argument("--defer-step", action="store_true",
                        help="Verify a temporary STEP, then retain only the preview and private native solid.")
    parser.add_argument("--validated-hash", help="Reuse successful validation of identical replay inputs.")
    arguments = parser.parse_args()
    try:
        result = run(arguments.request, arguments.output, arguments.threads, arguments.defer_step, arguments.validated_hash)
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
