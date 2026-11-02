# Iterative LAD mesh toolbox

The reference, evidence, fits, previews and revisions belong to this agent task.
All CAD construction remains complete editable CadQuery/OCP Python. A private
reconstruction commit does not replace the design window. Return the reviewed
complete program through LAD's normal final CAD response when appropriate.

## Start and iterate

`lad_mesh_open_reference(path, units, maxDeviation, sourceKind="unknown", policyPath?)`
opens an STL or `{vertices:[[x,y,z],...], triangles:[[i,j,k],...]}` JSON file in
the workspace. It returns `contextID`, empty `revisionID` and `branchID`.
Source units are explicit (`mm`, `cm`, `m`, `um`, `in`, `ft`). The returned
context declares working coordinates in **millimeters**, with the original axes
and origin. All subsequent queries, fits, edit dimensions and residuals use mm.
Original bytes, triangle order, coordinates and unit provenance are preserved.
Final bounds include coordinate-conversion error and never enlarge the supplied
physical allowance. Source normals are recomputed from triangle coordinates.

1. `lad_mesh_inspect(contextID, revisionID, queryPath)` creates reusable evidence.
2. `lad_mesh_fit(contextID, revisionID, evidenceIDs, families="auto", constraintsPath?)`
   returns alternative geometric explanations with stable candidate/member IDs.
3. `lad_mesh_try_edit(contextID, revisionID, editPath, programPath?)` stages an
   explicit construction and gives automatic before/after preview comparison.
4. Inspect and render the returned ordinary `artifactID`, then use
   `lad_mesh_commit(contextID, previewID, expectedRevisionID)` to keep an eligible
   intermediate body. Continue with the returned revision and new evidence.
5. `lad_mesh_compare(contextID, targetID, scope="all", quality="final")` requests
   reconstruction acceptance. Only full final `acceptance="pass"` establishes it.

`lad_mesh_undo` and `lad_mesh_redo` move the private branch cursor; optional
`expectedRevisionID` detects a race. `lad_mesh_branch(contextID, revisionID)`
creates and selects another private branch. Exact historical revisions remain
addressable; a stale preview cannot commit against a different branch tip.

The four algorithms return a common `status` (`ok`, `partial`, `no_result`,
`error`), `payload`, diagnostics and provenance. Full records are in `recordPath`;
large arrays and source/program contents are omitted from tool text. Read those
files when planning. Editable copies do not mutate trusted handles. Input
errors are MCP errors; useful geometric failures remain `partial` results.

## Inspection queries

Write the typed query to a workspace JSON file. Examples:

```json
{"kind":"select","source_triangles":[0,1,2]}
```

```json
{"kind":"select","scope":"all"}
```

```json
{"kind":"grow","seed":{"source_triangle":4182},"max_geodesic_distance":8,"barriers":["boundary","nonmanifold","sharp_feature"]}
```

```json
{"kind":"section","scope":"all","source":"reference","plane":{"origin":[0,0,10],"normal":[0,0,1]}}
```

```json
{"kind":"discrepancies","scope":"all","freshness":"refresh_or_partial"}
```

Selections retain original triangle IDs and barycentric clipping provenance.
`grow`/`shrink` use physical distances and explicit barriers. `partition` and
`combine` preserve connectivity and evidence references. Sections retain open
chains, isolated contacts, branches and coplanar areas; they never silently close
a sketch. `measure` gives area, bounds, centroid and conditioning. An empty CAD
revision supports source inspection normally; distances to absent CAD are null.
Discrepancies refresh against the exact requested revision and expose unknown
or unprocessed scope. A truncated result does not mark omitted regions explained.

## Fits and material decisions

Each returned `FitCandidate.id` is **one alternative**, not a solid operation.
A joint candidate contains `members[]`; select its explicit `member_id` when
more than one member is present. Geometry, finite observed support, inferred
extension, independent residuals, constraints and conditioning are separate.
Fitting a cylinder does not establish whether it is a boss, bore or hollow wall.
That material decision belongs to the edit. Mesh-only fits survive unrelated
CAD edits; CAD-dependent evidence and datums retain their exact dependencies.

Implemented family/constraint capabilities and unsupported requests are reported
explicitly. Hard constraints must be satisfied, never implemented by merely
assigning a large optimization penalty. Sampled local residuals do not certify
the final maximum deviation or explain hidden Boolean operands.

The initial fit registry supports `plane`, `line`, `circle`, `cylinder`, `cone`,
`sphere`, line/arc `profile`, `extrusion` and `revolution`. Tori, general sweeps,
lofts and freeform-network recognition currently return capability diagnostics;
complete authored programs can still construct them when their native validity
and comparison methods are supported. A small patch can legitimately return
several families and weakly determined parameters.

Constraints JSON is an array. A fixed constraint uses `kind:"fixed"`,
`parameter`, `value`, and `member` or `evidence_ref` (the target is optional for
one-member fits). Relationships use `kind:"coaxial" | "parallel" |
"perpendicular" | "equal_radius" | "concentric"` with `members:[id,id]`.
`strength:"hard"` is the default; `"soft"` may specify `weight`. Targets can be
candidate member IDs or the corresponding evidence IDs. Unsupported datum
references and general tangency are diagnosed explicitly. Fixed/equality
relationships use shared or eliminated parameters and independent checks.

## Typed edits and complete programs

An edit has `kind: "body" | "construction"` and an `operation`. A body operation
names a stable `target_body`. A tool either names a fitted candidate/member or
supplies a compact explicit family and geometry. Finite extent is an explicit
decision (`observed`, `bounded`, `depth`, or `through_all` where supported).

```json
{"kind":"body","operation":"create","target_body":"body-main","tool":{"family":"box","geometry":{"origin":[0,0,0],"size":[20,20,8]}}}
```

```json
{"kind":"body","operation":"cut","target_body":"body-main","feature_id":"central-bore","tool":{"fit_candidate":"fit-...","member_id":"member-...","extent":{"mode":"through_all"}}}
```

Body operations include `create`, `fuse`, `cut`, `intersect`, `fillet`, explicit
`update_parameters`, and `program_replace`. A `group` with `edits[]` executes
atomically. Construction `add` keeps datums/profiles separately and can commit
with no body. Construction objects never leak into the delivered solid.

`program_replace` references a **complete** self-contained workspace Python
program through the tool's `programPath`. Its edit JSON can declare `body_ids`
and explicit body bindings. It enables the full bundled CadQuery/OCP vocabulary
without a feature-node graph interpreter. Never inline program source in tool
arguments or import generated BREP/STEP/meshes. Complete program snapshots are
the replay truth; native geometry and previews are temporary task data.

Typed dimensions may use explicit bindings such as
`{"parameter":"base-width","value":20,"min":1}`. Later `update_parameters`
with `values:{"base-width":22}` regenerates the complete program and dependent
operations. Fixed bindings remain fixed. Arbitrary programs without bindings
are revised by replacing their complete source.

Semantic body/feature IDs persist in source and metadata. Fillets resolve bounded
geometric anchors and optional adjacent-surface families, never saved native
edge indices. Ambiguous rebinding fails explicitly. Operations do not silently
reduce radii, heal geometry or increase tolerances to make a preview pass.

## Intermediate validity and final acceptance

Keep these distinct:

- Fit success: selected evidence has a useful geometric explanation.
- Edit success: the staged body passes native, STEP and active-invariant gates.
- Final acceptance: the full exposed boundary and all mandatory requirements
  satisfy the immutable reference contract with defensible continuous bounds.

`completion_obligations` describe required finished features. They may remain
unresolved while building an intermediate solid. `active_invariants` protect
established features and must pass each ordinary commit. Omitting a requirement
from an edit cannot disable it. A valid base that fills a future bore is normal
intermediate progress. Improving one scalar distance on every step is unnecessary.

Reference `policyPath` can declare `reference_interpretation`, requirement lists,
and bounded `fit_policy`, `query_policy`, `compare_policy` settings. Unsupported
mandatory predicates or ambiguous material/nesting assumptions prevent final
acceptance. They do not falsely establish that reconstruction is impossible.

For a justified single closed source boundary, the interpretation record is:

```json
{"reference_interpretation":{"material":"oriented_closed_boundary","nesting":"single_component"}}
```

This declares the intended material interpretation; the final audit still checks
closure, orientation, embedding and topology. Explicit disjoint bodies can use
`nesting:"explicit"`. General nested/contacting-shell interpretation remains
inconclusive. Requirement predicates include `body_count` with `count`, `volume`
with `minimum`/`maximum`, bounding-box containment, and exposed `cylinder`, `bore`
or `through_bore` with `origin`, `axis`, `radius`, `tolerance` and optional
`axial_range`. Unknown predicates remain unresolved. Stable string references
can resolve through `requirement_definitions` in the policy.

`fit_policy` supports `sample_budget` (16–10000), `max_candidates` (1–16), local
`distance_tolerance` and Boolean `allow_partial`. `query_policy` supports
`max_triangles`, `max_growth_visits` (1–1000000) and `max_planes` (1–64).
`compare_policy` supports `preview_samples` (16–2048), `final_max_cells`
(1–2000000), `native_si_face_budget` (1–20000), `feature_pair_budget`,
`sharp_feature_degrees`, bounded `source_audit` work and optional mandatory
`require_material_difference` (currently unsupported, hence inconclusive).
These work/fit controls never change the final source allowance. Returned
diagnostics identify exhausted or unprocessed work.

Preview comparison measures both directions with triangle-interior and exposed
CAD-boundary samples, preserves source provenance and groups residual regions.
Numbers are estimates. Final checking uses conservative continuous enclosures
for supported native surfaces/trims, plus structural, feature and representation
checks. Unsupported enclosures, stale dependencies or exhausted budgets yield
`inconclusive`. Preview and local reports never issue a final pass.

`lad_mesh_export_step(contextID, revisionID, comparisonID, path?)` requires a
matching full accepted report. It validates solid STEP readback and compares the
readback against the original source under the same allowance. An unaccepted
reconstruction artifact cannot bypass this gate through `lad_export_step`.

There is no triangle-per-face, disguised spline-facet, or generated-geometry
import fallback. Keep iterating from localized evidence while useful changes
remain feasible. Report unsupported algorithms and numerical failures precisely;
do not require a lower-resolution source merely because LAD reached a budget.
