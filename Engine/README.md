# CAD worker

The app passes a complete Python CadQuery/OCP program to a local worker.
The worker builds exact B-rep geometry and generates a preview, deferring STEP
serialization until export. Programs expose the installed CadQuery and
OpenCascade APIs, including advanced curves, surfaces, sweeps, lofts,
transformations, text, assemblies, and direct OCP geometry operations.

Original external STEP assets are staged privately as
`source.step`. A Python request may specify `sourceAsset: "source.step"`; the
worker then preloads the exact geometry as the CadQuery Shape `imported_model`.
Other asset paths and symlinked/nonregular assets are rejected. LAD stores the
original STEP bytes in the project, strips them from Codex prompts, and carries
the asset into subsequent script revisions. A minimal imported model program is
`result = imported_model`.

For development, `Scripts/setup.sh` prepares the pinned standalone Python and
CAD payload under `.build/cad-runtime/arm64`. The app
provisions its own versioned runtime under `~/Library/Application Support/LAD/Runtimes`
from that payload and does not depend on the checkout.

Provisioning warms CadQuery and its dependencies once in the private installed
runtime, generating bytecode caches before marking it ready. Existing installs
without the warmup marker are warmed offline on their next use. Ordinary CAD
workers read those caches while keeping bytecode writes disabled; caches are
not included in the downloadable payload.

Each process holds a shared lock on its runtime's `.in-use` file and refreshes
its `.last-used` marker. After the current runtime is ready, a low-priority pass
removes superseded runtimes except the most recently used previous one, so
alternating between two app builds does not reinstall either. A runtime any
running process holds is never removed. Removal renames under the installation
lock and deletes afterward; the next installation finishes an interrupted one.

```sh
.build/cad-runtime/arm64/expanded/python/bin/python3 Engine/worker.py \
  --request Examples/mounting-bracket.json \
  --output /tmp/lad-bracket --threads 8 --defer-step
.build/cad-runtime/arm64/expanded/python/bin/python3 -m unittest discover -s Engine/tests -v
```

Every build passes exact native curve-on-surface and closed-solid checks,
then a temporary STEP export/reimport must preserve the closed solids and each
part's volume, surface area, analytic bounds and centroid before a preview is
accepted. The imported verification geometry never replaces the native build.
With `--defer-step`, builds remove the verification STEP and write `result.json`
and a private session `model.brep`, with no retained STEP file. The native BREP excludes triangulations and
normals; it is temporary worker IPC, never a project asset. Once the app has
decoded a build, it deletes everything in the scratch folder except `model.brep`
(and `model.step` when present). It keeps display data in memory for the few most
recently displayed revisions; older ones replay their program when shown again. An export request containing
`{"operation":"export","brepAsset":"source.brep"}` converts a privately staged
native solid to STEP without rerunning the model or tessellating it again.
Repeated app exports reuse the exact STEP bytes in memory.

The STEP save dialog can arrange physical solids for 3D printing. A bounded
orientation search combines planar normals, rotational and inertia axes, the
supplied pose and sphere directions. It ranks overhangs using trimmed planar
areas and area-weighted native curved-surface normals, verifies bed contact
against whole-solid analytic bounds, and packs separate solids on Z=0 with
50 mm clearance. When a stable planar base exists, overhang minimization is
restricted to those poses: the volume centroid must project inside the support
hull of actual contact boundaries. Parts without one retain the unrestricted
search. The export applies rigid locations only, without tessellation
or changing the live design. Matching translated instances share orientation
work within that export; cached STEP variants include the arrangement option.
Individual-part export batches the selected native solids in the same worker,
then publishes one complete folder with filenames from the current parts tree.
Approved replacement atomically swaps in that complete folder after staging,
including removal of obsolete outputs.
Printing placement is shared across those files, retaining the combined bed
layout. Both export options are remembered as app-wide preferences.

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
`result.json`. The preview JSON contains six bounding-box coordinates, volume
(mm³), area (mm²), solid/face counts, topology metadata, build duration, the
configured thread count, CAD runtime versions, and the expected absolute STEP
path. Deferred builds also include the native solid path. Display arrays travel
separately in `mesh.bin`, described by the JSON's `meshBuffers`: one
little-endian section each for vertex positions, normals and edge segment
endpoints (Float32), triangle indices (UInt32), and per-triangle and
per-segment owners (Int32). Float32 matches the attributes the app uploads to
the GPU, and the app copies each section straight into its packed array.
Errors exit nonzero and write an actionable description to stderr.

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

Moving assemblies attach a `lad_motion` dictionary to the final root
`cq.Assembly.metadata`. Its `grounded` array contains physical leaf part IDs;
`connectors` contains `{id, part, origin, xAxis, zAxis}` frames; and `joints`
contains `{id, name, type, parent, child, position, limits?}` records. `parent`
and `child` reference connector IDs. Connector origins and unit perpendicular
X/Z axes use the final built geometry's world coordinates, including all nested
Assembly locations. Omitted axes default to world X and Z. The implied Y axis is Z × X. Joint IDs and connector IDs
are unique within their respective lists. Groups cannot act as physical bodies.

Joint types are `fixed`, `revolute` and `slider`. A zero-position mate aligns
its connector frames; a revolute position rotates about the parent connector's
Z axis in degrees, and a slider position translates along that axis in mm.
`position` defaults to zero, and optional `[lower, upper]` limits must contain
it. Fixed joints accept only zero position and no limits. Frames need not
coincide in the construction pose. Closed loops and multiple grounded parts
are allowed, with at least one grounded physical part in each connected joint
component. Definitions are bounded to 1,024 connectors and 256 joints.
Optional `couplings` contain `{id, type, driver, follower, ...}` records that
make the follower joint's coordinate a function of its movable driver joint. A
`linear` coupling sets follower = `ratio` × driver + `offset` (nonzero ratio,
offset default zero). A `table` coupling interpolates linearly between
`samples` `[[driver, follower], ...]` with strictly increasing driver values.
With a positive `period`, samples span at most one period from the first driver
sample, the relation repeats every period, and each period adds `advance`
(default zero) to the follower; a last sample at first + period must equal the
first follower value + advance. Without a period, the driver's limits must lie
within the sample range. Each joint follows at most one coupling, chains are
acyclic, and definitions are bounded to 256 couplings, 4,096 samples each and
65,536 in total. Followers are not free solver variables: the worker derives
their normalized `position`, rejecting a contradicting authored one, and the
app resolves them from their drivers before limit checks, closure and grabs.
Closed loops and grabs act on each follower's independent root driver. Pose
requests cannot drive a follower directly; supplied follower coordinates are
recomputed.

The worker validates and normalizes this metadata as preview `assemblyMotion`;
the native app solves the rigid poses without rebuilding construction geometry.
Definitions remain part of the complete saved Python program, while poses and
derived display/topology data remain separate from the native construction.

Viewport grabs cache the picked point, camera projection and joint graph for
the gesture. Inverse solving runs off the main actor and accepts poses only
after joint closure validation. One background worker coalesces pointer targets;
release drains the final target, while cancellation retains the last accepted
pose. Only the resulting joint coordinates enter the revision's saved state.

Native export and measurement requests accept optional
`solidTransforms: [{solid, matrix}]`. Each matrix is a row-major 4×4 proper rigid
world-space delta from the built pose, acting on column vectors, with translation
at indices 3, 7 and 11. Omitted solids retain their built pose. These requests
preserve native subshape identities and do not replay programs or tessellate.
Export applies poses before optional printing arrangement. A measurement request
with this field returns sparse `topology` for its selected features and parts,
including exact transformed analytic bounds and world-space coordinates,
centroids and directions. It accepts up to 8,192 features, retains pair metrics
and `closestPoints` for exactly two selections, and otherwise returns empty
`metrics`. Without `solidTransforms`, measurement retains its two-item distance
contract.

A `clearance` request contains `pairs` (1–8 pairs of two disjoint, nonempty
solid-index groups) and `poses` (1–361 sparse `solidTransforms` lists). For each
pose and pair it returns the exact OpenCascade minimum distance and closest
points; a distance within 1e-6 mm adds the common volume (`overlapVolume`,
null if the Boolean fails), which separates contact from interference.
`lad_check_motion` solves evenly spaced poses of one independent joint natively,
carrying closed-loop continuity from the last reachable pose, sends only the
paired solids' transforms, and reports reachable samples, per-pair minimum
clearance, contact and interference positions, and the joints that moved.

`lad_render` accepts optional `jointPositions` overrides and a `drivingJoint`
whose requested coordinate remains fixed while passive joints satisfy closed
loops. It solves a private pose for that image and returns the effective joint
coordinates without changing the candidate or live design. `lad_inspect` reports
exact native properties at the artifact's current pose, fetching only its
requested page. Summary metadata identifies construction bounds as `builtBounds`
while an assembly is posed; current per-part bounds come from native inspection.

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
cavities. Intersecting or touching shells are rejected rather than misclassified
as cavities. These are required recipe inputs, stored once in the design's shared
asset table. Arbitrary paths, links, open/invalid meshes and unsupported kinds
are rejected. This does not allow generated replay programs to read user files.

## Agent tool interface

`agent_server.py --workspace <private-task-directory>` is LAD's stdlib-only
stdio MCP adapter. The native app connects it for each Codex invocation and
serves requests through private descriptor-confined filesystem IPC. Its tools
are `lad_runtime`, `lad_request_permission`, `lad_versions`, `lad_version`, `lad_build`, `lad_inspect`,
`lad_get_part_colors`, `lad_set_part_colors`, `lad_measure`, `lad_validate`,
`lad_render`, `lad_check_motion`, `lad_screenshot`, `lad_export_step` and `lad_import`.

`agent-tools.json` is the canonical CAD tool schema catalog shared by this
adapter and LAD's native external-agent interface. When enabled in Settings,
the app also serves MCP Streamable HTTP at `http://127.0.0.1:<port>/mcp`
(default port 47512). The external interface uses per-client credentials,
explicit design/task IDs, an isolated worker per task, binary file uploads,
and opaque task file IDs. `lad_build.programID` refers to an uploaded program;
other file arguments refer to opaque IDs rather than host paths. Authenticated
downloads expose task results without a shared filesystem. See the root
[External agents guide](../README.md#external-agents) for connection and workflow
details.

The iterative `lad_mesh_*` tools keep immutable reference evidence and private
reconstruction revisions. Optional `lad_mesh_inspect` recognition finds supported
surface regions, toroidal blends, measured helical profiles, rounded ports and
concentric spherical surfaces. `lad_mesh_fit` returns alternatives; explicit
`lad_mesh_try_edit` operations compile complete replayable Python programs.
Commits, undo/redo and branches retain useful intermediate bodies without
changing the design window. See [mesh-api.md](mesh-api.md) for schemas and limits.

Normal completed reconstruction delivery checks a full final comparison of the
exact committed recipe. When the agent cannot complete reconstruction, it may
choose `lad_mesh_set_delivery(..., mode="intermediate", reason=..., unresolved=[...])`
for an existing committed revision. The saved summary identifies that result and
its limitations. This choice never establishes source agreement or bypasses the
accepted-comparison and source-checked STEP-readback export gates.

Builds use this worker and the configured CAD runtime. Inspection/measurement
use session topology and native BRep; PNG images use LAD's native Metal renderer
and are returned as MCP image blocks for visual review. Build/export/import
outputs stay in the task workspace until final commit. Stop cancels native work
and releases waiting MCP calls. The built-in Codex adapter does not install a
listener or global MCP configuration. The optional external listener exists
only while enabled in the running app and binds exclusively to 127.0.0.1.
Source files, audit snapshots and geometry input references remain
separate from the bounded initial prompt.

External builds remain speculative until `lad_commit`. Its expected state token
protects newer design state, and its idempotency key is saved with a revision
receipt so retries do not create duplicate revisions. The app reuses the
matching validated native candidate, preserves the existing part-organization
and color rules, and publishes through the same coordinated autosave writer.
External task audits retain the initiating request and public client identity,
with model and effort only when supplied. They do not invent chat messages or
Codex turns. Request text, candidate programs and source snapshots use the
existing shared hash asset table; derived media stays transient.

Failed worker calls publish a bounded `error.json` alongside stderr. Native
validation reports OpenCascade's actual per-entity status codes, the validation
stage, zero-based topology references and available bounds. Edge/face failures
also report their edge tolerance and independently calculated curve-on-surface
discrepancy and witness point when available. References are explicitly scoped
to the candidate or STEP readback; STEP topology must not be treated as feature
IDs in the live design. The app preserves these details in tool errors and the
current request's repair context, with bounded stderr as a fallback.

Native and STEP-readback validation apply a 0.0001 mm (10e-5 mm) minimum
tolerance to edges and vertices. Face tolerances, coordinates, topology,
locations and analytic surfaces remain unchanged; larger existing tolerances
are preserved. STEP import requests this precision; export declares the greatest
native tolerance, at least this floor. Translation settings are scoped to each
operation and restored afterwards. Exact BRep, shell and part-integrity checks
remain enabled. Linear STEP bounds/centroid comparisons use at least this
tolerance; surface-area and volume checks retain their relative criteria.

External tools are user-managed. The bundled CAD baseline needs no extra install.
Before an optional download or installation, Codex calls `lad_request_permission`
with a specific operation and reason. The tool returns a decision only; it never
installs or executes anything. After an allowed decision, Codex performs the
operation in an isolated temporary environment inside its task workspace. Each
new proposed operation must query the current global Mac-local policy, even after
a previous always-allow or always-deny result. Saved chat/audit decisions are not
grants. Settings can change Ask/Always Allow/Always Deny at any time; policy changes
affect future or pending requests without terminating commands already running.
Denied/canceled requests authorize nothing; do not rephrase or retry the same operation
without new user direction. The shared runtime, global settings,
original files and paths outside the workspace stay protected. The final CAD
program must replay with bundled dependencies only; task environments disappear
after the turn. Permission requests and results use the ordinary tool audit. Codex is instructed
to use `lad_import` only for pre-existing external inputs and faithful conversions
of user sources, never geometry it creates or modifies as part of the design,
including LAD exports or newly authored SDF/mesh outputs. Generated geometry must
remain in the complete replayable CAD program. Required reference geometry and
provenance snapshots can be retained for portable replay and audit; native
preview/STEP/BREP/render outputs remain temporary. See the main README for the
optional Tool Activity pane, which is hidden by default.

The final geometry must contain valid nonempty solids and finite positive
volume and area. Geometry is limited to 4,096 solids and bounds
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
export. The same 4,096-solid, bounds and preview limits apply. STL/OBJ imports have
no separate 20,000-face cap; file-size and preview resource limits still apply.

The macOS app starts CAD programs through `sandbox-exec` using `script.sb`.
This denies networking and process creation, allows reads only from the
installed runtime, worker, system libraries/fonts and build directory, and
allows writes only within that build directory. The worker receives a small
environment allowlist without ambient API keys. The interpreter and dependencies
come from LAD’s managed runtime, provisioned offline from the bundled payload.
Font construction is supported using installed
system fonts. Runtime paths are provided as profile parameters rather than
embedded user paths.

The native process runner enforces a 10-minute deadline and cancellation with
a hard-kill fallback. Python model files, including stderr logs, have a hard
512 MB (512,000,000-byte) per-file limit. Geometry inputs, STEP verification,
exports and native BREP artifacts share that limit. On completion the app accepts only bounded regular
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
Candidate-validation checks reject sampled-valid curved defects and lossy
STEP conversion before publishing previews, and remove temporary STEP files.
Deferred-export checks ensure native session artifacts omit display triangulations, export never reruns the program
or mesher, and fast mesh extraction matches CadQuery's vertex data and winding.

Two opt-in macOS integration tests check text/font construction inside the
real native sandbox and verify denial of external reads/writes, sockets and
subprocesses. Run these outside another sandbox:

```sh
LAD_RUN_SANDBOX_TESTS=1 .build/cad-runtime/arm64/expanded/python/bin/python3 -m unittest discover -s Engine/tests -v
```

The preview preserves per-face vertex ranges and oriented triangle winding.
SceneKit can smooth normals within a curved face without smoothing sharp CAD
edges. STEP is exported from the exact solid, independently of preview quality.

`requirements.txt` pins the top-level tested engine version. The full tested
Python 3.14 / Apple Silicon environment is in `requirements-lock.txt`. CadQuery
and its dependencies are third-party packages; their licenses remain applicable.

Saved revisions carry one optional `validated_hash` field. The worker computes
SHA-256 over the program, units, ordered input identities/formats, exact required
input bytes, runtime versions, and worker/assembly adapter source. Titles, summaries and input
display names are excluded, matching validated candidate reuse at final commit. A matching receipt skips exact BRep/shell checks
and STEP roundtrip validation during replay. Missing or changed hashes require
full validation; only successful builds return a new receipt. This is an
accidental-change detector, not an authenticity mechanism or proof that Python
is deterministic. Replay keeps its process sandbox, solid-only and size limits,
finite analytic measurements, and app-side preview/topology checks. Native
geometry, topology and meshes remain session-only. No local receipt database is
used. New receipts are autosaved with the revision.
