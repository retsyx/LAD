# CAD worker

The app passes a complete Python CadQuery/OCP program to a local worker.
The worker builds exact B-rep geometry and generates a preview, deferring STEP
serialization until export. Programs expose the installed CadQuery and
OpenCascade APIs, including advanced curves, surfaces, sweeps, lofts,
transformations, text, assemblies, and direct OCP geometry operations.

Native STEP assets, including KiCad exports, are staged privately as
`source.step`. A Python request may specify `sourceAsset: "source.step"`; the
worker then preloads the exact geometry as the CadQuery Shape `imported_model`.
Other asset paths and symlinked/nonregular assets are rejected. LAD stores the
original STEP bytes in the project, strips them from Codex prompts, and carries
the asset into subsequent script revisions. A minimal imported model program is
`result = imported_model`.

```sh
.venv/bin/python Engine/worker.py \
  --request Examples/mounting-bracket.json \
  --output /tmp/lad-bracket --threads 8 --defer-step
.venv/bin/python -m unittest discover -s Engine/tests -v
```

With `--defer-step`, builds write `result.json` and a private session
`model.brep`, with no STEP file. The native BREP excludes triangulations and
normals; it is temporary worker IPC, never a project asset. The app retains
display data in memory when revisiting revisions. An export request containing
`{"operation":"export","brepAsset":"source.brep"}` converts a privately staged
native solid to STEP without rerunning the model or tessellating it again.
Repeated app exports reuse the exact STEP bytes in memory.

Preview extraction uses explicit indexed access to OpenCascade topology maps.
This avoids the repeated native exception overhead of Python sequence iteration
on per-face maps, while retaining CadQuery's subshape order, orientations,
locations and degenerate-edge filtering. The installed CadQuery API and saved
construction programs are unchanged.

Exact area/volume and centroid queries share one native integral. Part bounds
are computed once from analytic geometry and reused for whole-design bounds
and meshing deflection. Final validation hands its statistics directly to the
matching preview through a consumed, build-local object; no measurements are
cached on mutable shapes or retained across builds. Wire perimeters use the
same native curve adaptor and integrator as CadQuery, with indexed extraction
for single-edge wires.

Without `--defer-step`, the standalone CLI still writes `model.step` and
`result.json`. The preview JSON contains
vertices, indexed triangles, analytic edge line segments, six bounding-box
coordinates, volume (mm³), area (mm²), solid/face counts, build duration, the
configured thread count, CAD runtime versions, and the expected absolute STEP
path. Deferred builds also include the native solid path. Errors exit nonzero and
write an actionable description to stderr.

`triangleSolids` maps every triangle to a zero-based solid index, and
`edgeSolids` maps each analytic edge segment to the same index space. Edges are
sampled per owner, including shared boundaries, so hiding one body removes all
of its faces and edges while retaining visible neighbors. A fused body is one
selectable solid; disconnected unions and patterns contain several. Visibility
affects only the preview; STEP always contains the complete model.

`parts` is a recursive array of `{id, name, solidIndices, children}` nodes.
Body leaves use `children: null` and own one body in `solidIndices`; folders use
a `children` array and empty `solidIndices`. Empty arrays therefore identify
empty folders rather than leaves. An Assembly with its own body and child parts
gets a separate body leaf so every physical body has an individual tree row.
A folder's full body set is the union of every descendant's indices. All final
bodies have exactly one leaf owner. Named
CadQuery Assembly nodes retain their hierarchy and labels, and nested locations
are applied identically to the mesh and exact STEP export. A named multi-solid
compound, such as an imported PCB, becomes a folder containing individually
selectable generic body nodes. Non-Assembly results use Part 1, Part 2, etc.

For persistent identities, assign a unique string `metadata={"lad_id":"..."}`
to each Assembly node and retain it across refinements and folder changes.
These are emitted verbatim as the part IDs, including existing user-created
folder IDs. Without explicit metadata, a globally unique
supplied node name becomes `name:<name>`; duplicate names use a qualified
`path:` ID excluding the outer root, and the outer container uses `root`.
CadQuery-generated UUID names are treated as unnamed. Generic bodies inside a
named compound use a `body:` ID based on that folder's ID and local body ordinal;
unnamed non-Assembly bodies use `solid/<index>`. Explicit IDs therefore preserve
custom placements through renames, reordering and reparenting; generic body
identity is limited by the source solid ordering. A generated ID that collides
with an explicit ID receives a `generated:` prefix. Repeated explicit IDs are
rejected instead of silently assigning the user's layout to the wrong part.

For Python programs ending in a Compound, the worker can infer preview
labels from exact `cq.Shape` or single-value `cq.Workplane` aliases left in the
program namespace. Matched final `base`, `lid`, and `pcb`/`board` components get
Case/Base/Lid and PCB folders; other known aliases retain their compound nesting
and names. Generic temporary aliases are ignored. This is optional metadata
only: it neither rewrites the saved program nor converts, relocates, or replaces
the original result used for meshing and STEP export. Ambiguous aliases
retain generic per-solid fallback labels. Explicit named Assemblies remain the
preferred hierarchy contract.

All dimensions are in millimeters, angles in degrees. A design request contains
`title`, `summary`, `units` (`"mm"`), and a required nonempty `script`. The private
`sourceAsset` and `inputAssets` fields may accompany these construction fields. The native
app retains source names and hierarchy intent as document metadata and strips
them before the worker request.

`inputAssets` is a list of `{id,name,format,path}` records with fixed numbered
private filenames such as `input-000.step`. The worker loads these shapes as
`imported_assets[id]`. STEP and BREP retain their native boundary representation;
closed STL/OBJ meshes are sewn into faceted BRep solids, retaining closed nested
cavities. These are required recipe inputs, stored once in the design's shared
asset table. Arbitrary paths, links, open/invalid meshes and unsupported kinds
are rejected. This does not allow generated replay programs to read user files.

## Agent tool interface

`agent_server.py --workspace <private-task-directory>` is LAD's stdlib-only
stdio MCP adapter. The native app connects it for each Codex invocation and
serves requests through private descriptor-confined filesystem IPC. Its tools
are `lad_runtime`, `lad_build`, `lad_inspect`, `lad_measure`, `lad_validate`,
`lad_render`, `lad_screenshot`, `lad_export_step`, `lad_convert_kicad` and `lad_import`.

`lad_convert_kicad` reuses the native app's KiCad converter for an exact referenced
board file and returns a temporary workspace STEP path, coverage, diagnostics
and provenance. It does not import, register or commit geometry. All PCB requests
go to Codex normally; the agent chooses whether conversion is useful and whether
to import the resulting external PCB reference separately.

Builds use this worker and the configured CAD runtime. Inspection/measurement
use session topology and native BRep; PNG images use LAD's native Metal renderer
and are returned as MCP image blocks for visual review. Build/export/import
outputs stay in the task workspace until final commit. Stop cancels native work
and releases waiting MCP calls. No listening port or global MCP configuration
is installed. Source files, audit snapshots and geometry input references remain
separate from the bounded initial prompt.

The Codex task workspace supports command execution and workspace-local optional
dependencies for analysis and alternative modeling approaches. Codex is instructed
to use `lad_import` only for pre-existing external inputs and faithful conversions
of user sources, never geometry it creates or modifies as part of the design,
including LAD exports or newly authored SDF/mesh outputs. Generated geometry must
remain in the complete replayable CAD program. Required reference geometry and
provenance snapshots can be retained for portable replay and audit; native
preview/STEP/BREP/render outputs remain temporary. See the main README for the
optional Tool Activity pane, which is hidden by default.

The final geometry must contain valid nonempty solids and finite positive
volume and area. Geometry is limited to 4,096 solids, 20,000 faces, and bounds
within ±1,000,000 mm. The preview is capped at one million vertices/triangles
and 250,000 analytic edge segments. These output limits bound native resource
use; programs can use the full installed CAD API without an operation whitelist.
The app contains each build in a cancellable process.

OpenCascade booleans run with parallel execution enabled. The worker configures
the native OCCT thread pool and explicitly uses OCCT threads, then runs parallel
absolute-deflection BRepMesh meshing. Python itself does not serialize these
native jobs through the GIL. Very small parts may not benefit from extra threads.
A program's Python statements execute in order; an individual native kernel
job may use the configured CPU cores.

After the parallel mesher runs, extraction reads indexed native triangles
directly with `Poly_Triangulation.Triangle(i).Get()`. It avoids the slow Python
sequence iterator over `Poly_Array1OfTriangle` and CadQuery Vector wrappers,
while preserving the same vertices, face-local boundaries, oriented winding,
quality tolerances, and per-solid ownership.

## CAD programs

A design's `script` contains at most 200,000 UTF-8 bytes. The script is ordinary
Python, with `cq` (CadQuery), `math`, and `np` (NumPy) already available. It may import any installed modules,
including `OCP`, and use normal functions, classes, loops and the full installed
CAD APIs. There is no restricted operation list or Python AST subset. Define
the final CAD object as the variable `result`:

```python
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox

# Direct OpenCascade TopoDS shapes are accepted, as are cq.Shape and Workplane.
body = cq.Shape.cast(BRepPrimAPI_MakeBox(20, 12, 6).Shape())
rounded = cq.Workplane("XY").newObject([body]).edges("|Z").fillet(1)
loft = cq.Workplane("XY").circle(3).workplane(offset=8).rect(4, 5).loft()
result = cq.Assembly(rounded, name="body")
result.add(loft, name="loft", loc=cq.Location((30, 0, 0)))
```

The result may be a CadQuery Shape, a Workplane containing shapes, a CadQuery
Assembly, or a raw `OCP.TopoDS.TopoDS_Shape`. Assemblies convert to compounds
with their child and root locations applied and their named hierarchy retained
in preview metadata; disconnected bodies remain separately selectable. The final result must contain valid closed solids with
nonzero finite volume. Construction wires and sheet faces can be used while
modeling, but must be converted to solids or excluded from `result` before STEP
export. The same 20,000-face, 4,096-solid, bounds and preview limits apply.

The macOS app starts CAD programs through `sandbox-exec` using `script.sb`.
This denies networking and process creation, allows reads only from the
installed runtime, worker, system libraries/fonts and build directory, and
allows writes only within that build directory. The worker receives a small
environment allowlist without ambient API keys. Homebrew Python framework
launchers are bypassed in favor of the actual interpreter, retaining the
selected virtual environment. Font construction is supported using installed
system fonts. Runtime paths are provided as profile parameters rather than
embedded user paths.

The native process runner enforces a 10-minute deadline and cancellation with
a hard-kill fallback. Python model files, including stderr logs, have a hard
256 MiB per-file limit. On completion the app accepts only bounded regular
output files, rejects symbolic links and hardlinks, verifies private native
solid paths and STEP delimiters, and reads only a bounded diagnostic tail on failure.
The sandbox fails closed if its tool or profile is unavailable. Direct CLI
calls execute Python normally; apply equivalent process isolation when using
the worker outside LAD with untrusted scripts.

FeatureScript is not executed by this worker. A FeatureScript import is a
translation into CadQuery/OCP Python, with the original source retained by the
app. A completed source translation must describe its fidelity accurately.

## Tests

Normal geometry tests cover primitives, booleans, profiles, patterns, shells,
fillets, chamfers, transforms, Bezier and nonuniform geometry, lofts, sweeps,
direct OCP, transformed nested assemblies,
multi-solid selection, per-part edge ownership, stable named identities across
reparenting, script diagnostics and actual STEP reimport.
Deferred-export checks ensure previews never call the STEP exporter, native
session artifacts omit display triangulations, export never reruns the program
or mesher, and fast mesh extraction matches CadQuery's vertex data and winding.

Two opt-in macOS integration tests check text/font construction inside the
real native sandbox and verify denial of external reads/writes, sockets and
subprocesses. Run these outside another sandbox:

```sh
LAD_RUN_SANDBOX_TESTS=1 .venv/bin/python -m unittest discover -s Engine/tests -v
```

The preview preserves per-face vertex ranges and oriented triangle winding.
SceneKit can smooth normals within a curved face without smoothing sharp CAD
edges. STEP is exported from the exact solid, independently of preview quality.

`requirements.txt` pins the top-level tested engine version. The full tested
Python 3.11 / Apple Silicon environment is in `requirements-lock.txt`. CadQuery
and its dependencies are third-party packages; their licenses remain applicable.
