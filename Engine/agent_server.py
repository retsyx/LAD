#!/usr/bin/env python3
"""Dependency-free local MCP adapter for LAD's native task tools.

The native app owns CAD execution and drawing. This process only transports
JSON requests and image attachments over MCP stdio and a private task directory.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import stat
import sys
import time
import uuid

MAX_MESSAGE_BYTES = 4 * 1024 * 1024
MAX_IMAGE_BYTES = 32 * 1024 * 1024
INSTRUCTIONS = (
    "You are connected to LAD's native CAD runtime. When creating or modifying geometry, write a complete CadQuery/OCP Python program in the task workspace, "
    "then use lad_build, lad_inspect/lad_measure, and lad_render to evaluate and visually review it before the final answer. "
    "For questions, explanations and saved-version lookup, use only the tools needed to answer accurately; a message response does not require a CAD build or replacement program. "
    "LAD provides the installed CAD environment: no CAD bootstrap is needed. Tools are speculative and do not replace the user's design. "
    "When a request refers to an earlier version or custom version name, use lad_versions and lad_version to resolve it from the task's saved history snapshot. "
    "Lookups return metadata and local file references without building geometry or changing the viewport. Use the returned stable versionID after resolution; ambiguous names require clarification. "
    "Replay a saved program with lad_build.versionID to bind that version's exact original inputs. Never import generated geometry from earlier versions. "
    "Use lad_runtime for the selected Python, versions and asset IDs. Full installed CadQuery/OCP APIs are supported, including lofts, sweeps, "
    "splines and surfaces; final results must be closed solids. External tools are user-managed: use additional tools only when the user has provided them, "
    "and never download or install tools or dependencies. Keep analysis and prototyping outputs inside this task workspace without changing original sources or LAD's shared runtime. "
    "lad_import is only for pre-existing external/reference geometry and faithful format conversions of user-provided inputs. "
    "NEVER export/import, reimport or use lad_import for geometry generated as part of the current design, whether authored with LAD or external tools such as SDF software. "
    "Keep all authored geometry in the replayable CAD program; external tools may support analysis and prototyping. Mesh reference inputs remain faceted. "
    "Use lad_get_part_colors for effective sRGB colors and stable part IDs, and lad_set_part_colors to stage color assignments or null resets without rebuilding geometry. "
    "Colors on candidate artifacts remain speculative; only the current patch or the final program's matching artifact patch is committed on success. "
    "Part colors have one current RGB value; the last successful color assignment applies. CadQuery Assembly color=cq.Color(r,g,b) seeds colors for new parts. "
    "Inputs and outputs are file references, never inline complete source files. Screenshots/render tools return actual PNG image content. "
    "For geometry changes, inspect and repair as many times as needed, then return the final complete program and its required assetIDs in the response schema."
)


def schema(properties=None, required=()):
    return {"type": "object", "properties": properties or {}, "required": list(required), "additionalProperties": False}


def prop(type, **extra):
    return {"type": type, **extra}


ARTIFACT = {"artifactID": prop("string", description="Artifact ID returned by lad_build/lad_import, or current for the existing design.")}
INDICES = prop("array", items=prop("integer", minimum=0), description="Zero-based physical solid indices from lad_inspect.")
TOOLS = [
    ("lad_runtime", "Discover LAD's ready-to-use Python/CadQuery/OCP runtime, capabilities, task workspace and available imported asset IDs.", schema(), True),
    ("lad_versions", "List the task's saved design versions with stable IDs, vN history positions, custom names, dates and the current-version marker. Read-only history lookup; does not build geometry, select a version or change the viewport.",
     schema({"offset": prop("integer", minimum=0, default=0), "limit": prop("integer", minimum=1, maximum=100, default=50)}), True),
    ("lad_version", "Look up a saved design version by its stable UUID, vN history position or exact case-sensitive custom name. Stable UUIDs take precedence; duplicate names or a name matching another version's vN label return ambiguity candidates. Returns metadata and local paths to the complete saved CAD program and exact required original inputs, never inline source or binary data. Ambiguous names return candidates instead of guessing. Does not build geometry, select a version or change the viewport.",
     schema({"reference": prop("string", description="Stable version UUID, history position such as v3, or exact custom version name. Use a returned stable UUID to disambiguate names or vN collisions.")}, ["reference"]), True),
    ("lad_build", "Build and validate a workspace Python CAD program using LAD's multicore native CAD worker. Returns an artifact ID and exact geometry metadata; does not commit the design or export STEP.",
     schema({"programPath": prop("string"), "title": prop("string"), "summary": prop("string"), "assetIDs": prop("array", items=prop("string")),
             "versionID": prop("string", description="Optional stable UUID returned by lad_version. Binds that saved version's exact original STEP and imported_assets inputs for this build only; does not change the current design or register historical inputs for the final replacement program.")}, ["programPath"]), False),
    ("lad_inspect", "Inspect exact geometry metadata, named parts and native topology IDs. Paginate vertices, edges or faces to find entities for measurements.",
     schema({**ARTIFACT, "kind": prop("string", enum=["summary", "parts", "vertices", "edges", "faces"]), "solidIndices": INDICES,
             "offset": prop("integer", minimum=0), "limit": prop("integer", minimum=1, maximum=500)}), True),
    ("lad_get_part_colors", "Read current opaque sRGB colors, stable part and folder IDs, and parent relationships. Paginated; current works from the saved parts layout even when its geometry preview is unavailable. Never rebuilds geometry or changes the design.",
     schema({**ARTIFACT, "offset": prop("integer", minimum=0, default=0), "limit": prop("integer", minimum=1, maximum=500, default=100)}), True),
    ("lad_set_part_colors", "Stage an atomic batch of part or folder color assignments for one artifact without rebuilding geometry or changing the live design. Folder assignments expand to physical parts; conflicting overlaps are rejected. Use color:null to set the neutral default finish. Only a successful final response commits the current patch or the final replacement program's matching artifact patch.",
     schema({**ARTIFACT, "changes": prop("array", minItems=1, maxItems=256, items=schema({
         "partID": prop("string", minLength=1, maxLength=1024),
         "color": {"anyOf": [schema({channel: prop("number", minimum=0, maximum=1) for channel in ("red", "green", "blue")}, ["red", "green", "blue"]), {"type": "null"}]}
     }, ["partID", "color"]))}, ["changes"]), False),
    ("lad_measure", "Measure native vertices, edges, curves, faces or whole parts. Returns exact properties and OpenCascade minimum distances/closest points and supported analytic angles.",
     schema({**ARTIFACT, "features": prop("array", items=schema({"kind": prop("string", enum=["vertex", "edge", "face"]),
                                                               "solidIndex": prop("integer", minimum=0), "localIndex": prop("integer", minimum=0)},
                                                              ["kind", "solidIndex", "localIndex"])), "solidIndices": INDICES}), True),
    ("lad_validate", "Check that an artifact passed LAD's native topology, closed-solid, positive-volume and preview validation.", schema(ARTIFACT), True),
    ("lad_render", "Render an artifact through LAD's native camera, lights and display pipeline using a preset or arbitrary camera. Returns a PNG image attachment for visual review without changing the user's view. Camera coordinates are CAD-world millimetres; angles are degrees. Zoom 1 uses automatic fit, 2 doubles magnification, and 0.5 halves it. An explicit cameraPosition defines the base eye position. Perspective zoom dollies that position around cameraTarget by dividing its target distance; orthographic zoom keeps the eye position unchanged and divides the view scale. Do not combine cameraPosition with yawDegrees or elevationDegrees.",
     schema({**ARTIFACT, "view": prop("string", enum=["isometric", "front", "back", "top", "bottom", "left", "right"], default="isometric",
                                    description="Preset starting orientation, retained when angular overrides are omitted."),
             "yawDegrees": prop("number", description="Optional camera azimuth overriding the preset: 0 looks from +X, 90 from +Y. Any finite angle; cannot combine with cameraPosition."),
             "elevationDegrees": prop("number", minimum=-90, maximum=90,
                                      description="Optional elevation overriding the preset: 0 is in the XY plane, +90 is above (+Z), -90 below. Cannot combine with cameraPosition."),
             "rollDegrees": prop("number", default=0, description="Rotation about the viewing axis; positive angles rotate the image counterclockwise. Works with either angular or position-based cameras."),
             "cameraPosition": prop("array", items=prop("number", minimum=-1000000, maximum=1000000), minItems=3, maxItems=3,
                                    description="Optional base camera [x,y,z] in CAD-world millimetres, looking toward cameraTarget. Must differ from the target. Overrides preset orientation; cannot combine with yawDegrees/elevationDegrees. Perspective zoom divides the eye-to-target distance by zoom; orthographic zoom retains this eye position and changes only the view scale."),
             "cameraTarget": prop("array", items=prop("number", minimum=-1000000, maximum=1000000), minItems=3, maxItems=3,
                                  description="Optional look-at [x,y,z] in CAD-world millimetres. Defaults to the automatic fit center of the visible artifact or solidIndices subset."),
             "zoom": prop("number", minimum=0.000001, maximum=1000000, default=1,
                          description="Positive magnification multiplier: 1 is automatic fit, 2 zooms in, 0.5 zooms out. With cameraPosition, 1 uses that exact base position. Perspective zoom divides the base eye-to-target distance; orthographic zoom keeps the eye unchanged and divides the orthographic view scale. Does not change geometry."),
             "projection": prop("string", enum=["perspective", "isometric"]), "display": prop("string", enum=["shaded", "edges", "translucent", "wireframe"]),
             "width": prop("integer", minimum=256, maximum=2048), "height": prop("integer", minimum=256, maximum=2048), "solidIndices": INDICES}), True),
    ("lad_screenshot", "Capture the current LAD viewport as a PNG image attachment. Uses an explicitly disclosed offscreen fallback if no live viewport is attached.", schema(), True),
    ("lad_export_step", "Export exact whole or selected artifact geometry with its current part RGB colors as STEP into the task workspace. Includes staged colors and neutral finishes; preserves separate solids and original coordinates. Returns a file reference without sending the file bytes as text.",
     schema({**ARTIFACT, "path": prop("string"), "solidIndices": INDICES}), False),
    ("lad_import", "Import pre-existing external/reference STEP/BREP or closed STL/OBJ geometry from the task workspace, including faithful format conversions of user-provided inputs. Never import geometry generated as part of the current design by LAD or external tools. Returns an input asset ID, validated artifact and fidelity notes. Access the reference shape using imported_assets[assetID].",
     schema({"path": prop("string"), "name": prop("string"), "producerPaths": prop("array", items=prop("string"), description="Optional source-conversion code and dependency file references for a pre-existing external/reference input's task audit.")}, ["path"]), False),
]
TOOL_NAMES = {tool[0] for tool in TOOLS}


def read_regular(root, path, maximum):
    """Read using directory descriptors; never follow workspace symlinks."""
    supplied_root = Path(os.path.abspath(root))
    root = supplied_root.resolve(strict=True)
    path = Path(path)
    if not path.is_absolute():
        path = root / path
    # abspath collapses '.' and '..' without dereferencing attacker-owned links.
    path = Path(os.path.abspath(path))
    try:
        path = root / path.relative_to(supplied_root)
    except ValueError:
        pass
    try:
        components = path.relative_to(root).parts
    except ValueError as error:
        raise ValueError("The native tool returned a path outside the task workspace.") from error
    if not components:
        raise ValueError("A regular workspace file is required.")
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for component in components[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= maximum:
            raise ValueError("Tool artifacts must be bounded regular files without symbolic or hard links.")
        data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("The tool artifact exceeds its size limit.")
        return data


def transport_result(root, result):
    if not isinstance(result, dict) or not isinstance(result.get("content"), list):
        raise ValueError("The native app returned an invalid tool response.")
    content = []
    for item in result["content"]:
        if not isinstance(item, dict):
            raise ValueError("The native app returned invalid tool content.")
        if item.get("type") == "image_path":
            data = read_regular(root, item.get("path", ""), MAX_IMAGE_BYTES)
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("The native renderer did not return a PNG image.")
            content.append({"type": "image", "data": base64.b64encode(data).decode("ascii"), "mimeType": "image/png"})
        elif item.get("type") == "text" and isinstance(item.get("text"), str):
            content.append({"type": "text", "text": item["text"]})
        else:
            raise ValueError("The native app returned an unsupported tool content type.")
    return {"content": content, **({"isError": True} if result.get("isError") else {})}


class NativeBridge:
    def __init__(self, workspace):
        self.supplied_workspace = Path(os.path.abspath(workspace))
        self.workspace = Path(workspace).resolve(strict=True)
        self.bridge = self.workspace / ".lad-tools"
        self.requests = self.bridge / "requests"
        self.responses = self.bridge / "responses"
        # Native app creates these before starting Codex. Refuse symlinked roots.
        for directory in (self.bridge, self.requests, self.responses):
            info = directory.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError("The native LAD tool bridge is unavailable.")
        self.parent = os.getppid()
        base = os.open(self.workspace, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            private = os.open(".lad-tools", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=base)
            try:
                self.request_fd = os.open("requests", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=private)
                self.response_fd = os.open("responses", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=private)
            finally:
                os.close(private)
        finally:
            os.close(base)

    def call(self, name, arguments):
        if name not in TOOL_NAMES or not isinstance(arguments, dict):
            raise ValueError("Unknown LAD tool or invalid arguments.")
        identity = str(uuid.uuid4())
        data = json.dumps({"id": identity, "name": name, "arguments": arguments}, separators=(",", ":")).encode()
        if len(data) > MAX_MESSAGE_BYTES:
            raise ValueError("The LAD tool request is too large; use file references.")
        temporary = identity + ".tmp"
        final = identity + ".json"
        # UUID names prevent concurrent request collisions. Both the adapter and
        # native host independently validate the private directory and files.
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=self.request_fd)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.replace(temporary, final, src_dir_fd=self.request_fd, dst_dir_fd=self.request_fd)
        response = self.responses / (identity + ".json")
        started = time.monotonic()
        while True:
            if response.exists():
                try:
                    result = json.loads(read_regular(self.supplied_workspace, response, MAX_MESSAGE_BYTES))
                    return transport_result(self.supplied_workspace, result)
                finally:
                    try:
                        os.unlink(identity + ".json", dir_fd=self.response_fd)
                    except FileNotFoundError:
                        pass
            if (self.bridge / "closed").exists():
                raise ValueError("The LAD task has stopped; native tools are no longer available.")
            try:
                os.kill(self.parent, 0)
            except ProcessLookupError as error:
                raise ValueError("The Codex task has stopped.") from error
            except PermissionError:
                # EPERM still means a process exists; an enclosing macOS
                # sandbox may deny signaling the live parent even for signal 0.
                pass
            if time.monotonic() - started > 3600:
                raise ValueError("The native LAD tool did not return a response within its one-hour tool timeout.")
            time.sleep(0.03)


def reply(identity, *, result=None, error=None):
    response = {"jsonrpc": "2.0", "id": identity}
    response["error" if error else "result"] = error if error else result
    sys.stdout.write(json.dumps(response, separators=(",", ":"), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def serve(workspace):
    bridge = NativeBridge(workspace)
    while True:
        raw = sys.stdin.buffer.readline(MAX_MESSAGE_BYTES + 1)
        if not raw:
            return
        if len(raw) > MAX_MESSAGE_BYTES:
            while raw and not raw.endswith(b"\n"):
                raw = sys.stdin.buffer.readline(MAX_MESSAGE_BYTES + 1)
            reply(None, error={"code": -32700, "message": "MCP request exceeds the message limit."})
            continue
        try:
            message = json.loads(raw)
        except (ValueError, UnicodeError):
            reply(None, error={"code": -32700, "message": "Invalid JSON."})
            continue
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            reply(message.get("id") if isinstance(message, dict) else None, error={"code": -32600, "message": "Invalid JSON-RPC request."})
            continue
        if "id" not in message:
            # initialized/cancelled notifications require no response. Native
            # cancellation is also signaled through the task's closed marker.
            continue
        identity = message["id"]
        method, params = message.get("method"), message.get("params", {})
        try:
            if method == "initialize":
                reply(identity, result={"protocolVersion": params.get("protocolVersion", "2024-11-05"),
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "LAD", "version": "1.0.0"}, "instructions": INSTRUCTIONS})
            elif method == "ping":
                reply(identity, result={})
            elif method == "tools/list":
                reply(identity, result={"tools": [{"name": name, "description": description, "inputSchema": input_schema,
                    "annotations": {"readOnlyHint": read_only, "destructiveHint": False, "openWorldHint": False}}
                    for name, description, input_schema, read_only in TOOLS]})
            elif method == "tools/call":
                try:
                    reply(identity, result=bridge.call(params.get("name"), params.get("arguments", {})))
                except Exception as error:
                    reply(identity, result={"isError": True, "content": [{"type": "text", "text": str(error)}]})
            else:
                reply(identity, error={"code": -32601, "message": "Method not found."})
        except Exception as error:
            reply(identity, error={"code": -32602, "message": str(error)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    args = parser.parse_args()
    try:
        serve(args.workspace)
    except Exception as error:
        print(f"LAD MCP: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
