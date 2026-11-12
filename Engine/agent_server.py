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
import select
import stat
import sys
import time
from typing import NamedTuple
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
    "splines and surfaces; final results must be closed solids. External tools are user-managed. Before downloading or installing optional tools or dependencies, "
    "call lad_request_permission with the proposed operation and reason and proceed only when allowed is true. The tool returns a decision only; "
    "you execute approved installations yourself in an isolated environment inside this task workspace. Denial or cancellation never permits installation; do not rephrase or retry that same operation without new user direction. Use existing capabilities or explain the limitation. "
    "Task commands have no network access until a permission decision is allowed; LAD then enables it for the rest of the task. "
    "Call lad_request_permission for each new proposed operation even after a prior always-allow or always-deny result; Settings can change at any time. "
    "Saved chat, audit records and earlier-turn decisions are not current permission. "
    "Keep analysis and prototyping outputs inside this task workspace without changing original sources, global settings or LAD's shared runtime. "
    "The final CAD program must replay with LAD's bundled dependencies only, using registered reference inputs when required. "
    "lad_import is only for pre-existing external/reference geometry and faithful format conversions of user-provided inputs. "
    "NEVER export/import, reimport or use lad_import for geometry generated as part of the current design, whether authored with LAD or external tools such as SDF software. "
    "Keep all authored geometry in the replayable CAD program; external tools may support analysis and prototyping. Mesh reference inputs remain faceted. "
    "For analytic reconstruction from a mesh, use LAD's iterative lad_mesh toolbox described by lad_runtime.meshAPIHelpPath. "
    "Open the immutable reference with lad_mesh_open_reference, inspect evidence, fit alternatives, try an explicit edit, and inspect/compare the exposed result. "
    "lad_mesh_commit keeps a valid intermediate body in a private reconstruction branch; it never changes the user's design. "
    "Unfinished completion obligations do not block intermediate commits. Active invariants protect established features. "
    "Continue revising from discrepancy evidence; a failed fit or edit is feedback, not proof the reference cannot be reconstructed. "
    "Preview metrics are estimates, not final maximum bounds. Only full final lad_mesh_compare acceptance=pass establishes reconstruction acceptance. "
    "For verified final reconstruction delivery, commit the final recipe and compare that exact committed revision with scope=all and quality=final. "
    "Verified final delivery requires its unchanged program's passing full final comparison; lad_build, local/preview reports and another revision/context's acceptance cannot grant verification. "
    "If you decide completion is not achievable and keeping useful interim results is appropriate, explicitly call lad_mesh_set_delivery for that exact committed revision with mode=intermediate, a reason and unresolved items. No user approval is required for that decision. "
    "LAD then permits that exact intermediate program and saves a clear limitation disclosure; this choice does not authorize another recipe or verified STEP export. Otherwise continue editing or return message/unsupported while preserving the current design. "
    "Use lad_mesh_export_step with the exact committed revision and accepted comparison for checked STEP readback. "
    "Render successful preview artifactIDs and use their complete self-contained programPath for final CAD; never import generated geometry. "
    "Use lad_get_part_colors for effective sRGB colors and stable part IDs, and lad_set_part_colors to stage color assignments or null resets without rebuilding geometry. "
    "Colors on candidate artifacts remain speculative; only the current patch or the final program's matching artifact patch is committed on success. "
    "Part colors have one current RGB value; the last successful color assignment applies. CadQuery Assembly color=cq.Color(r,g,b) seeds colors for new parts. "
    "For moving assemblies, return a cq.Assembly with stable physical part metadata lad_id and root metadata lad_motion={grounded,connectors,joints}. "
    "Grounded is a list of physical part IDs. Connectors are {id,part,origin:[x,y,z],xAxis:[x,y,z],zAxis:[x,y,z]} in the final built geometry's world coordinates, with unit perpendicular axes. "
    "Joints are {id,name,type,parent,child,position:0,limits:[lower,upper]} using connector IDs, with optional position/limits. "
    "Types are fixed, revolute (degrees about connector Z), or slider (mm along Z); fixed joints have zero position and no limits. "
    "A zero-position mate aligns its connector frames even when they differ in the built geometry. Anchor every connected mechanism with a grounded part. "
    "Closed joint loops are supported when their constraints can be satisfied; use explicit finite travel limits where appropriate and inspect the resulting assemblyMotion after lad_build. "
    "Optional lad_motion couplings [{id,type,driver,follower,...}] make a follower joint a function of its driver joint: linear {ratio,offset} for gears, belts, racks and screws; "
    "table {samples:[[driver,follower],...],period,advance} for cams, Geneva drives and intermittent motion. Followers are derived; position their drivers instead. "
    "Use lad_render jointPositions to review isolated poses, with optional drivingJoint to hold one requested joint while passive joints satisfy closed-loop constraints; inspect the returned effective jointPositions. This never changes the artifact or live viewport. "
    "Use lad_check_motion to sweep an independent joint and check exact clearance, contact and interference between engaging parts before the final answer. "
    "Inputs and outputs are file references, never inline complete source files. Screenshots/render tools return actual PNG image content. "
    "For geometry changes, inspect and repair as many times as needed, then return the final complete program and its required assetIDs in the response schema."
)


class Tool(NamedTuple):
    """A catalog tool as agents see it. Its host properties belong to the native app."""
    name: str
    description: str
    input_schema: dict
    read_only: bool

    def descriptor(self):
        return {"name": self.name, "description": self.description, "inputSchema": self.input_schema,
                "annotations": {"readOnlyHint": self.read_only, "destructiveHint": False, "openWorldHint": False}}


# One canonical tool catalog is shared by the internal stdio adapter and the
# native external MCP endpoint. It is bundled beside this adapter and read once.
with Path(__file__).with_name("agent-tools.json").open(encoding="utf-8") as catalog_file:
    TOOLS = tuple(Tool(tool["name"], tool["description"], tool["inputSchema"], tool["annotations"]["readOnlyHint"])
                  for tool in json.load(catalog_file))
TOOL_NAMES = frozenset(tool.name for tool in TOOLS)


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
            self.bridge_fd = os.open(".lad-tools", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=base)
            self.request_fd = os.open("requests", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self.bridge_fd)
            self.response_fd = os.open("responses", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self.bridge_fd)
        finally:
            os.close(base)
        # Wait for responses, the closed marker and the agent's exit as events
        # rather than polling.
        self.events = select.kqueue()
        self.events.control([select.kevent(descriptor, filter=select.KQ_FILTER_VNODE,
                                           flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)
                             for descriptor in (self.response_fd, self.bridge_fd)], 0, 0)
        self.parent_exited = False
        try:
            self.events.control([select.kevent(self.parent, filter=select.KQ_FILTER_PROC,
                                               flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 0, 0)
        except ProcessLookupError:
            self.parent_exited = True

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
        deadline = time.monotonic() + 3600
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
            if self.parent_exited:
                raise ValueError("The agent task has stopped.")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError("The native LAD tool did not return a response within its one-hour tool timeout.")
            for event in self.events.control(None, 3, remaining):
                if event.filter == select.KQ_FILTER_PROC:
                    self.parent_exited = True


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
                reply(identity, result={"tools": [tool.descriptor() for tool in TOOLS]})
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
