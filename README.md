# LAD

Language Aided Design

LAD eschews traditional CAD in favor of a pure agent chat. Tell the agent what you want, review the design, request changes, and export STEP files.

LAD requires that ChatGPT/Codex or Claude Code be already installed for the built-in chat. A LAD MCP server, for use by the agent of your choice, can be enabled in LAD Settings.

You must have your own Codex or Claude (or equivalent) subscription. LAD does not provide agent functionality on its own.

## Features

- Full CAD implementation for agent modeling.
- Mesh tools to enable an agent to model objects based on a mesh (useful for STL -> STEP conversion).
- Simple design viewer for inspecting and measuring proposed designs.
- Moving assemblies - drag parts to test design motion, or use precision inputs to select positions.
- Attach reference images to the chat for the agent to use in modeling.
- Reference external files (STL, STEP, KiCad, etc.) to guide the agent in modeling.
- Export STEP files optionally oriented for 3D printing.


## Run

The app has been built at **`dist/LAD.app`**. Open it in Finder, or:

```sh
open dist/LAD.app
```

LAD carries its Python/CadQuery/OpenCascade runtime as a bundled payload. Before the first CAD operation, it prepares a versioned private runtime under `~/Library/Application Support/LAD/Runtimes` without a network download. Moving the app or removing the source checkout does not remove that runtime. When an updated LAD installs a newer runtime, it removes older ones, keeping the most recently used previous runtime and any runtime another running copy of LAD is using. Codex or Claude Code is the only separately installed LAD dependency; install, configure and sign in to at least one of them before sending a request. LAD does not install, update or sign in to either agent.

Automatic discovery prefers the installed Codex app, then the ChatGPT desktop app, standalone CLI locations and compatible VS Code extension binaries. For Claude Code, it prefers the native installer and Homebrew locations, then the newest Claude Code editor-extension binary, then PATH and npm installations. Configure each agent in its own installation; LAD uses that installation for design requests and model discovery. When both agents are installed, LAD asks once at first launch which agent new designs use.

For a development build from a fresh checkout, install Xcode (or its command line tools) and sign in to an installed Codex. The build scripts download a pinned standalone Python distribution and prepare the bundled CAD payload:

```sh
Scripts/setup.sh
Scripts/build-app.sh
open dist/LAD.app
```

The build-time payload preparation uses the pinned dependencies in `Engine/requirements-lock.txt`; users do not install Python, Homebrew or CAD libraries. LAD Settings (`⌘,`) contains the default save location, CAD thread count and agent permission policy. Agent, model and reasoning choices are available only in the composer. When both agents are installed, its dropdown lists the agents first; it then lists the selected agent’s models, followed by the selected model’s supported reasoning levels, using the installed agent’s model catalog (for Codex, its [model catalog](https://learn.chatgpt.com/docs/app-server#models)). Each design remembers its agent, its model and reasoning preferences per model, and the last choice made for the other agent. New designs start from the chosen agent’s installed configuration, then retain their explicit selections. Unsupported levels are replaced with the selected model’s advertised default. Changes apply to the next design request, including its repair attempt. No API key is stored by LAD.

You can also open `Package.swift` in Xcode to work on the native target. `LAD_BUILD_CONFIGURATION=debug Scripts/build-app.sh` packages a debug build. LAD supports **Apple Silicon (arm64) only**, on macOS 14 or later. All build and release tooling targets that architecture.

## Downloadable releases

`Scripts/build-app.sh` creates the local development app. `Scripts/release.sh` builds a versioned DMG, signs the runtime and app, notarizes them, staples tickets, and verifies the actual app copied out of the mounted DMG. End users drag `LAD.app` onto the DMG's Applications shortcut; CAD dependencies are provisioned offline from the app's payload.

The release machine needs Apple Silicon, Xcode command-line tools, an unlocked keychain containing a **Developer ID Application** certificate and private key, and a `notarytool` keychain profile. Configure credentials through Apple's `xcrun notarytool store-credentials` command before invoking the release script. Credentials are not stored in this repository or passed to the app.

From a clean, committed checkout with reviewed release notes:

```sh
LAD_RUN_ENGINE_TESTS=1 LAD_RUN_SANDBOX_TESTS=1 Scripts/test.sh
Scripts/release.sh --version 0.3.0 --build-number 100 \
  --notes path/to/release-notes.md \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile LAD-release
```

`--identity` and `--notary-profile` can also come from `LAD_SIGNING_IDENTITY` and `LAD_NOTARY_PROFILE`. Production builds use a private snapshot of the committed source and verify that the prepared runtime matches its exact recipes and artifact locks. Version/build metadata is injected into the packaged app without changing the source plist. The output directory defaults to `dist/releases/<version>+<build>` and must not already exist; `--output` selects another new directory. It contains the arm64 DMG, `SHA256SUMS`, `release-notes.md`, and `release.json` with source revision, runtime inventory, verification results, and notarization IDs. Nothing is placed there until all required checks pass. Complete notarization logs remain under `.build/releases`; failed builds preserve their staging workspace for diagnosis.

Before signing, packaging saves UUID-matched dSYM bundles for LAD and its thumbnail extension, strips their debug records, and rejects personal home or checkout paths remaining in either executable. Resource lookup no longer embeds the checkout's source path. The signed app and the actual copy from the DMG are checked again. Keep the symbols private for crash diagnosis: releases retain them under their `.build/releases/<workspace>/symbols` directory, separately from the distributable artifacts. Copy them to private storage before cleaning the checkout; `.build` is disposable, and a later CI checkout can remove it. Ordinary release-configuration app builds retain symbols under a unique `.build/app-symbols/release.<suffix>` directory; `LAD_APP_SYMBOLS_OUTPUT` can select another private destination.

The release process signs each of the runtime's native images individually with hardened runtime and a secure timestamp, then submits the **expanded runtime** in a ZIP for notarization. This is necessary because the app normally carries those images inside a compressed tar payload. Python alone receives `allow-unsigned-executable-memory`, required by the bundled LLVM/Numba implementation and verified by the hardened JIT smoke test; the LAD app and native libraries receive no exceptions. Production Python retains library validation. The final signed runtime receives a new content-addressed installation identity. The app is then signed, notarized and stapled, followed by the DMG. Signing never uses `codesign --deep`; verification uses it to inspect nested code. The offline DMG verification recreates the private venv, checks preserved signatures, exercises CAD and numeric solvers, and runs the packaged worker's file/network/process restrictions and STEP export.

To validate packaging without release credentials:

```sh
Scripts/release.sh --local --version 0.3.0 --build-number 100 \
  --notes path/to/release-notes.md
```

Local outputs have a `-local` suffix and `distributable: false` metadata. They are ad-hoc signed and are never submitted for notarization. They validate packaging and runtime behavior; Developer ID, Gatekeeper and stapling checks run only in the production path. Local Python may require an ad-hoc-only library-validation exception because ad-hoc signatures have no signing team; that exception is excluded from production signing.

The manually dispatched [release workflow](.github/workflows/release.yml) runs on a dedicated Apple Silicon macOS runner labeled `lad-release`. Configure the repository variables `LAD_SIGNING_IDENTITY` and `LAD_NOTARY_PROFILE` to reference its preconfigured keychain. Restrict the runner group to this workflow on the protected default branch. The workflow runs native tests, builds the verified artifacts and retains them; its optional final job creates a **draft** GitHub release. Review that draft and the remaining real-machine acceptance checks before publishing. The workflow never publishes a public release automatically.

Before publication, also test a browser-downloaded, quarantined DMG on a clean standard-user Mac: install, eject, launch from Finder, connect the user's Codex, generate/save/reopen/export, and exercise offline use and failed saves. Automated package verification does not replace this live clean-machine check. Normal opening supports only the current directory-package format; the development archive converter is an explicit one-time tool.

## Controls

**Help → LAD Help** (`⌘?`) opens a separate window with the viewport mouse and keyboard controls. Reopening Help focuses the same window; closing it leaves the open designs intact.

**New Design** (`⌘N`) opens an empty independent design window and leaves the existing design open. It starts with no geometry, conversation messages, revisions, or sample prompts, and does not launch a CAD build. Each independent design has its own conversation, history, viewport, agent and model selection and autosave file. **Open Design** opens a separate window, or brings an already-open design to the front. Menu actions apply to the active design. Closing a design’s last window saves it and stops its work; quitting LAD saves all open designs.

Drop a `.lad` file on a design window's title bar, viewer, parts tree or conversation history to open it in that window. LAD validates the dropped file and saves the outgoing design before switching. If another window already shows that file, both windows share one document and autosave writer; closing one view leaves the other open. A corrupt or unreadable drop leaves the current design in place. The chat editor is an exception: dropping any file or folder there inserts its local path into the prompt, without inserting file contents or replacing the open design.

**File → Open Recent** lists the 15 most recently opened or saved LAD designs and retains them across launches. Selecting one opens its design or focuses its existing window. Renaming a design updates its recent entry. **Clear Menu** clears these references without deleting any design files.

| Action | Control |
| --- | --- |
| New design window | `⌘N` |
| Toggle a vertex, edge/curve, or face | Left-click in the viewport |
| Select whole parts | Click in the parts tree |
| Add or remove parts from the selection | `⌘`-click or `⇧`-click in the parts tree |
| Select a group of parts | Click a folder in the parts tree |
| Toggle part or group visibility | Eye button in the parts tree |
| Assign part or group colors | **Color…** in the parts tree context menu |
| Hide selected / show all parts | Context menu in the viewport or parts tree |
| Move parts or folders | Drag onto a folder or the Parts header; or use **Move Selected To** in the tree context menu |
| Create or rename folders and parts | Folder-plus button or tree context menu |
| Deselect all parts and features | Double-click empty viewport space, Escape, or context menu |
| Context menu | Right-click without dragging |
| Rotate about the design’s geometric center | Right-click and drag |
| Fit from front / back / left / right / top / bottom | Click the corresponding cube face |
| Fit from the opposite direction | Click a face border on the orientation cube |
| Fit from eight isometric directions | Click the corresponding cube corner |
| Pan | Middle-drag or Shift + right-drag |
| Zoom toward the current mouse location | Scroll |
| Zoom toward the gesture anchor | Trackpad pinch |
| Fit design | `F`, toolbar, or `⌘F` |
| Isometric / front / top / right | `0` / `1` / `2` / `3` with viewport focused, or Design menu |
| Submit prompt | `Return` |
| New line in prompt | `⌥Return` |
| Add next queued request to the current request, or submit prompt when the queue is empty | `⌘Return` |
| Save New / open design | `⌘S` / `⌘O` |
| Save design as | `⇧⌘S` |
| Export STEP | `⇧⌘E` |
| Export selected parts as STEP | **Export STEP…** in the parts tree context menu |

The parts tree on the left preserves named, nested CadQuery assemblies. Codex organizes new designs into groups such as Case and PCB, with individual solid parts beneath them. Older designs without assembly names receive numbered part entries. You can create folders, rename labels inline using the tree’s **Rename** command (Return applies, Escape cancels), and move parts or entire folders; these changes remain with the design and are retained when Codex updates matching parts. **Ungroup** removes a folder while keeping its contents in the parent folder; empty folders have **Remove Folder** instead. Selecting a folder selects all its descendants; each eye button changes visibility for its part or entire folder. A minus badge marks folders containing both visible and hidden parts. Hidden parts remain in the tree so they can be shown again. Visibility affects the preview only. The main STEP export includes the complete design; **Export STEP…** in the tree context menu exports just the selected parts, including selected folders' descendants, at their original coordinates.

Moving assemblies can include mate connectors and fixed, revolute, and slider joints, with travel limits and closed linkages. Coupled joints follow another joint, so gears, belts, racks, cams, and indexing mechanisms such as Geneva drives move together from a single input; **Motion** shows coupled joints without separate controls. Ask Codex to create the mechanism, then move its parts directly in the viewport or use **Motion** in the Design pane to change joint positions or reset them. Positions are saved with each version; measurements and STEP exports use the current pose. Motion describes rigid movement without collision response or physical simulation. `Examples/Hinged arm.json` is a small program example.

Choose **Color…** from a part or folder’s context menu for curated swatches, recent colors used in this design, and the full macOS color picker. A folder colors its contained parts; a context menu on a selected part applies to the selected parts. **Default Color** sets the neutral gray finish. Colors stay attached to stable part identities across hierarchy edits and matching Codex refinements, and are saved with each revision. Full-design and selected-part STEP exports include each exported part’s current RGB color, including the neutral finish. Recent choices belong to the design. Updating colors reuses the existing geometry; selected parts keep their selection highlight until deselected.

The viewport supports shaded, shaded with analytic edges, translucent, and wireframe display. A separate Perspective / Isometric selector switches between perspective and parallel projection while preserving the camera pose. Both projections support rotation, panning, and cursor-relative zoom. The orientation cube follows the viewport camera. Click a labeled face to align the view, a gray face border to view from its opposite direction, or a corner for one of eight isometric directions. Each cube click smoothly turns to the chosen direction and centers and fits the complete design using the initial-view framing criteria while retaining the current projection. Reduce Motion skips these transitions; direct navigation remains immediate. Rotation uses the midpoint of the complete design’s bounding box, including all parts. Pan and cursor zoom keep that rotation pivot fixed. This view reference does not translate geometry or change CAD coordinates in part operations or STEP exports. Whole parts are selected in the hierarchy; viewport clicks toggle native vertices, edges/curves, and faces. Hover previews the clickable feature with a softer gold highlight without selecting it or changing measurements. Selected features use the same gold as selected whole parts. Their owning parts and folders are marked partially selected in the tree. Right-click preserves the current selection. Double-click empty viewport space clears both part and feature selections. The design details below the parts tree show dimensions, volume, CAD program, and a revision selector. Agent, model and reasoning choices are available only in the conversation composer's combined menu beside Send, including custom model IDs. Each `.lad` design retains its own agent, model, reasoning level, and remembered effort for each model. New designs start from the chosen agent’s installed configuration. Settings contains the default save location and CAD thread count. Conversation messages, errors, source text, and CAD programs have standard copy icons with confirmation feedback.

Highlighted faces and parts receive the highlight color in the normal surface rendering. A separate overlay keeps highlighted vertices, edges, and curves visible through nearer geometry. Faces and parts receive only the outline of their viewport projection, so selecting a cube outlines its silhouette rather than every cube edge. Hover uses the same rendering with a softer color; picking still respects geometry visibility.

Codex can answer questions or ask for clarification without changing the design. These replies appear in the conversation. Answer using the same composer at the bottom; replies run before paused queued refinements, and only a validated CAD result creates a new version.

Submitting while LAD is working queues the follow-up above the composer. Each queued request keeps its captured model/reasoning choice and complete source snapshots. Edit it inline, remove it, or use its small grab handle to reorder it. After a successful design is validated and committed, LAD sends exactly the next queued request against that updated design. Stop or failure pauses the remaining queue; Resume continues it. Reopening a design also restores its queue paused. Pending requests and the unsent composer draft are saved with the design, sharing attachment bytes with conversation history. Save New keeps its existing latest-design-only behavior and leaves pending work with the original design.

The **Add to current request** button on a queued item delivers it as supplemental user input to the running Codex turn. It does not interrupt the task or start another design task. The button is available only while Codex can accept live input, and the item remains queued until Codex acknowledges it. An uncertain or rejected delivery keeps the item and pauses automatic replay so it cannot be sent twice silently. Accepted supplemental messages become part of the conversation and that task's audit.

The left panel contains Parts above Design, with a draggable divider. New designs use a 75% / 25% split; each design saves its chosen split, and selection or content changes never resize the panes. Design information appears first in the lower pane, followed by Measurements when geometry is selected. Measurements use native OpenCascade geometry rather than display triangles. Single-feature properties appear immediately; general pair distances run asynchronously without blocking navigation or CAD construction.

CAD edges keep a consistent width on screen through zoom, orbit and projection changes. Ordinary edges use a dark 1.6-point stroke; hover uses a 3-point pale-gold core with a lighter halo, and selection uses a 4-point gold core with a dark outline. The strokes remain depth-tested and reuse cached GPU buffers. Grid guides keep their thin appearance.

| Selection | Measurements |
| --- | --- |
| Vertex | X/Y/Z coordinates |
| Two vertices | Distance and signed X/Y/Z deltas in selection order |
| Three vertices | Angle at the second vertex, triangle area, perimeter and side lengths |
| Edge or curve | Length; endpoints and chord; radius, diameter, center, axis, sweep angle or ellipse radii where defined |
| Face | Area, perimeter, surface centroid and surface type; plane normal or analytic radii/axis/cone half-angle where defined |
| Two features or parts | Exact minimum distance, closest points and X/Y/Z deltas; acute line/plane/analytic-axis angles where defined |
| Multiple edges or faces | Total edge length, face area and face perimeter |
| Whole parts or folders | Part count, surface area, volume, bounding dimensions and limits, volume centroid |

General splines and curved surfaces do not have a single radius or normal. Mass is not inferred without material density. Measurement and topology metadata are regenerated for each native revision and are never embedded in `.lad` files.

Viewport illumination combines ambient light with camera-relative directional lights: a main light above-right and a softer fill above-left. Their directions remain fixed in the view as you orbit, pan, zoom, or switch projection. Curved surfaces produce highlights from their normals and material properties.

Newly loaded preview geometry prepares its drawing resources in the background before appearing. Camera interaction reuses those resources, and unrelated conversation or save-status updates leave unchanged materials intact.

## Designs and history

`.lad` designs are self-contained directory packages, presented by Finder as single documents. The top-level `project.json` contains identity, per-design settings, drafts, the queue, and references to revision, conversation, activity and asset-catalog indexes. Each section alternates between `index-1.json` and `index-2.json`; the manifest records its expected content hash. Revision recipes/parts, message chunks, activity records and catalog buckets (grouped by the first two hash characters) are immutable files, so a save rewrites only the catalog buckets whose assets changed. Saves write complete new dependencies first, atomically publish `project.json` last, and then clean up superseded dependencies. Unchanged dependencies are reused, so small settings edits do not rewrite programs or history.

Exact payloads are stored once at `assets/sha256/<first-two-hash-characters>/<full-sha256>`, shared by revisions, attachments and execution snapshots. Suitable assets are compressed independently once; their identities hash the original uncompressed bytes. The normal opener accepts only this package format. There are no state, recovery or geometry-cache folders.

State-only edits reuse cached history metadata, assets and verified thumbnails, and encode the root manifest once. History edits reuse unchanged section references, revision recipes/parts, task records and chunk contents; only changed records are encoded, with exact source assets shared across sections. Cached records retain validation of their payloads, while every save still checks current cross-section references and aggregate limits. An immediate save consumes pending draft/divider and audit timers whose contents it already includes.

Different designs use independent package locks. Established saves retain their destination policy without rediscovering the default folder, and optional iCloud folder branding runs once per successfully checked directory identity. Unchanged save URLs and recent-project preferences are not republished. Snapshots compare cached thumbnail presentation metadata without resolving Parts colors; matching validated replays reuse the saved PNG, while actual recipe, color, visibility or view changes invalidate it. Thumbnail rendering remains asynchronous and outside required saving.

The opt-in `ProjectAutosaveProfileTests` accepts `LAD_AUTOSAVE_PROFILE_SOURCE` and `LAD_AUTOSAVE_PROFILE_REPORT`. `testProfileStateOnlyAutosave` measures grid changes through actual AppState save completion on disposable copies; sidebar timings include the 650 ms editing debounce. `testProfileIncrementalHistoryAutosave` measures transcript growth, activity appends and version naming through direct and coordinated saves, including record/chunk encoding counts. Both verify persisted content, unchanged unrelated dependencies and the original design without machine-specific timing thresholds.

The app bundles a Quick Look thumbnail extension. A package may contain one small, separately referenced PNG of its saved design; Finder can display it as a content thumbnail while the gold LAD cube remains the registered document icon. The thumbnail is generated asynchronously from validated geometry without moving the live viewport, and the extension only reads that image. Missing or damaged thumbnails never prevent opening or saving. After building and registering the app, `xcrun swift Scripts/check-thumbnail-scales.swift /tmp/lad-thumbnail-scales` verifies native content thumbnails at 128, 256 and 512 points with both 1× and 2× backing scales, using fresh disposable packages. Generated STEP outputs, native BREP and display caches remain temporary. Every successful revision contains:

- The complete CadQuery/OCP Python program, title, summary, and timestamp.
- References to any original imported geometry needed by its program.
- Stable part identities, the default parts hierarchy, user organization, visibility, and each folder's expanded/collapsed state.
- CAD runtime version metadata for newly built revisions.

The design also contains **all chat messages**, complete attached source snapshots, and the selected revision. Opening a revision runs its saved CAD program locally and prepares its preview in the background; this does not contact Codex. Other revisions are rebuilt only when selected, and cached previews make subsequent visits immediate. Before accepting a build, LAD checks exact native geometry and verifies a temporary STEP export/reimport preserves closed solids and each part's geometry. The verification file is discarded; previews and later exports use the original native solid without executing the program again. Native solid artifacts are private, temporary session files, never design assets. Rebuilding uses LAD's managed CAD runtime; the pinned environment is recorded in `Engine/requirements-lock.txt`. For a follow-up request, LAD makes saved snapshots available as local referenced files, so Codex can inspect them even after the original source paths disappear. Selecting an older revision retains the later revisions and the complete conversation. A follow-up prompt operates on the selected design and appends a new revision.

Tool activity travels with the design too: each task retains its captured language model/reasoning level, start/end time, outcome, tool and command inputs/outputs, durations, and CAD candidate/producer source snapshots. Exact source bytes and activity text share the same deduplicated asset table as final programs and attachments. Required external geometry inputs are also stored once for portable replay. Generated render images, display metadata, native caches and STEP exports remain temporary.

Projection, rendering mode, and grid visibility are saved per design. Their viewport controls and **Design → Show Grid** autosave these choices; reopening or switching designs restores each file's options. Save New and full copies retain them. New designs start with perspective projection, edges rendering, and the grid visible.

New designs begin saving automatically after you submit the first request. Until then, drafts and settings stay in memory and no `.lad` file is created. Files are saved in **iCloud Drive/LAD** when iCloud Drive is available, or **Documents/LAD** otherwise. Settings lets you select **iCloud Drive** directly or choose another default folder for new designs. The iCloud location is labeled **iCloud Drive**, with LAD files stored in its LAD folder. Opened designs continue saving to their existing location, including files outside that default folder. Filenames use the descriptive design title generated by Codex from the request. Each design retains its complete revision and conversation history. LAD restores the last design on launch. Explicit **Save Design As** creates a portable file at your chosen location.

**Save New** opens a save dialog for an independent design containing only the latest validated design. Right-click a version in the version dropdown and choose **Save New…** to start from that version instead, without changing the current selection. Both actions preserve required input assets, parts organization, visibility, grid and Codex choices. Other revisions, all chat messages and task activity, drafts and queued requests are omitted. The open design keeps its complete history; Save New cannot replace it. **Save Design As** remains available for a complete copy.

Click the filename at the top of the window to rename a design in place. Return applies the name; Escape cancels. The `.lad` file is renamed automatically, and your chosen name stays with the design when you change revisions or ask Codex for further changes. Existing files are preserved when names collide.

The interface shows a save status only while changes are pending or when saving fails; there is no "saved" or "autosaved" confirmation. A failed autosave leaves the design unsaved, including after its window closes. On quit, LAD offers Save, Don’t Save and Cancel for each unsaved design. Cancel stops quitting; canceling a subsequent save dialog also returns to LAD. Don’t Save explicitly discards that design’s unsaved changes. Metadata encoding, individual asset compression and disk work run off the main UI thread. The package reader validates bounded files, content hashes and references, IDs, programs, hierarchy and STEP headers, and rejects symbolic links or paths outside the package. Imported solid geometry, STEP verification/exports and temporary native geometry have a 512 MB (512,000,000-byte) per-file limit. Required unique asset payloads have a 1,024 MB expanded total limit, and the root manifest has a separate 32 MB limit. Generated STEP and native geometry remain temporary and are not saved in designs.

Try `Examples/Mounting Bracket.lad`: it includes two complete modeling recipes and four conversation messages. `Examples/*.json` are CadQuery program examples, not complete designs.

For a one-time conversion of development archives, run `Scripts/migrate-projects.sh stage SOURCE_DIRECTORY STAGING_DIRECTORY --thumbnails`. Staging leaves the source archives untouched, verifies all metadata and exact asset bytes after reading the new packages, and writes `migration-report.json`. After reviewing the report and quitting LAD, run `Scripts/migrate-projects.sh publish SOURCE_DIRECTORY STAGING_DIRECTORY BACKUP_DIRECTORY`. Publication verifies each source hash again, preserves the original as a `.lad.zip` backup, and replaces it with the validated package at the same path. The converter is opt-in development tooling; normal LAD opening has no archive fallback.

## Architecture

Developer naming uses **Project** for LAD documents and their internal state: source filenames, types, data structures, helpers, variables, tests, preference keys, and scene identifiers. The interface calls the same document a **Design** (for example, `ProjectWindowCoordinator` implements **New Design**). Keep this terminology boundary when adding code; external API/protocol identifiers and user-authored content retain their own names. Files keep the `.lad` suffix and top-level `project.json` filename.

```text
SwiftUI conversation + revision state
               │
               ▼
Codex CLI ── structured design JSON ──► CAD worker process
                                        │
                             CadQuery / OpenCascade (C++)
                                        │
                           ┌────────────┴────────────┐
                           ▼                         ▼
                    STEP on export            Preview mesh + edges
                                                     │
                                                     ▼
                                             SceneKit / Metal
```

Swift owns the native interface, designs, camera, and Codex lifecycle. A separate Python worker is a thin adapter to CadQuery's C++ OpenCascade kernel. Native booleans and meshing use the configured OCCT thread pool; the UI stays available during modeling. The preview and exported STEP come from the same validated solid.

Codex runs in an isolated temporary task workspace using the `workspace-write` sandbox, initially without network access. LAD connects its own stdio MCP server on that invocation; it does not edit global Codex configuration. Claude Code runs in the same kind of task workspace with the same LAD tools, instructions and validated response format, and only LAD's MCP server for that task. Its sandbox limits commands and file edits to the task workspace, no host is pre-allowed, other permission prompts are declined rather than waiting for a person, and LAD keeps it from updating itself or saving sessions or memory for the task. Supplemental user messages join a running Claude task once Claude Code acknowledges them. LAD uses a private [Codex app-server](https://developers.openai.com/codex/app-server) for streamed progress, schema-constrained final responses and acknowledged same-turn steering. The initial context contains file references, brief metadata, and a bounded recent conversation. It never embeds source file contents, attached or historical source snapshots, the current design's saved program, or audit output. The current design is staged as `context/current-model.json` and referenced as **CURRENT MODEL FILE**. Source manifests provide the name, original provenance `path`, staged snapshot `readPath`, SHA-256, and byte count. Geometry inputs have a separate local manifest. Codex inspects these files and writes new work in its private workspace; original source files remain unchanged. Initial request size stays independent of referenced file size.

Complete source snapshots stay in the portable design and remain available even when their original messages move beyond the recent conversation window or the original files no longer exist. LAD stages the saved data for each request instead of truncating files or replacing missing details with guessed geometry. The full conversation is retained locally. Codex design requests have no LAD-imposed elapsed-time limit; use Stop to cancel a request. Codex can correct kernel failures and rebuild repeatedly within its turn. Final construction is validated before commit; if it differs from the geometry built through the tools and fails validation, one additional repair turn remains available. Matching validated geometry is reused without another CAD build.

Codex starts with a short plan and provides concise progress updates during substantial work. LAD displays these messages as they arrive and retains them in the saved conversation. The running task status includes its captured model and reasoning level, so changing the composer for the next request does not relabel ongoing work. The final design summary appears only after CAD validation succeeds; failures and cancellation retain their actual outcomes. Tool logs, private reasoning, and the structured CAD response are kept out of progress messages.

Every Codex design task has these LAD tools available by default, with instructions to build, inspect, measure, validate and visually review the result before returning it:

| Tool | Purpose |
| --- | --- |
| `lad_runtime` | Discover the selected Python, installed CAD versions and full API capabilities |
| `lad_request_permission` | Request a decision for an optional task-local download or dependency installation; performs no installation or execution |
| `lad_versions` | List saved versions with stable IDs, history positions, custom names and the current marker |
| `lad_version` | Resolve a version reference to metadata and local files for its complete program and original inputs |
| `lad_build` | Build a complete local Python recipe into validated native geometry and a preview |
| `lad_inspect` | Inspect parts, vertices, edges/curves and faces, with paginated exact properties |
| `lad_get_part_colors` | Read paginated part/folder IDs, current colors without rebuilding |
| `lad_set_part_colors` | Stage atomic part/folder color assignments or neutral defaults for the current design or a candidate |
| `lad_measure` | Measure native features or parts using the same exact geometry as the viewer |
| `lad_validate` | Check the successfully built solid, dimensions, topology and preview |
| `lad_render` | Return a PNG image to Codex from a chosen standard view, projection, shading and optional part subset |
| `lad_check_motion` | Sweep a mechanism joint and report exact clearance, contact and interference between moving parts |
| `lad_screenshot` | Return an image of the current live LAD viewport; disclose an offscreen fallback if no view is attached |
| `lad_export_step` | Export complete or selected geometry with the artifact's current part colors into the task workspace |
| `lad_import` | Register validated pre-existing STEP/BREP or closed STL/OBJ reference inputs, with optional provenance snapshots |

Codex can inspect and change current part colors without rebuilding geometry. Each part has one RGB value, regardless of who set it; the last successful assignment applies. Color tools use stable physical part IDs, support folder assignments and neutral default colors, and remain speculative until a successful final response. Current color-only changes use a normal conversational response; a geometry replacement uses its matching candidate's current colors. Other candidate and historical color changes remain isolated. New candidates retain existing current colors by stable ID, while historical replays use that saved version's current colors. `cq.Color(r,g,b)` assembly values supply initial colors for new parts.

Rendering uses LAD's camera, geometry, materials and lighting. Candidate renders do not move the user's camera or replace the open design; only the final validated result becomes a revision. Image data is delivered to Codex as an MCP image attachment, so it can review the result during the turn. Tool outputs use file references and concise geometry metadata, rather than complete source files or CAD programs.

When a request references v3 or a custom version name, Codex can look it up from a task snapshot of the design's complete saved history. Version lookup does not rebuild geometry or change the selected version. It returns complete local recipe and original-input references; an explicit `lad_build` with the returned `versionID` can replay that version for inspection or rendering. Ambiguous names return candidates for clarification. Historical generated geometry is never imported as a frozen reference.

The **Tool Activity** toggle beside the conversation settings opens a separate nonmodal pane. It is **hidden by default**, is never restored visible, and leaves the existing window layout intact. It shows live and saved task events with expandable complete inputs, outputs, source snapshots and standard copy buttons. Cancellation and interruption retain their outcomes. Private reasoning, final-response JSON and derived image payloads are excluded. LAD retains its own audit while using a private Codex app-server with an ephemeral thread per design request; transient task files are removed afterward. Live supplemental input uses the same active thread and turn. An oversized malformed CLI event produces an explicit incomplete-record diagnostic instead of silently claiming a complete log.

External tools are user-managed. The bundled CAD baseline requires no extra installation. Before an optional download or dependency installation, Codex calls `lad_request_permission` with the proposed operation and reason. LAD returns a decision only; it does not install tools or run installation commands. If allowed, Codex executes the operation in an isolated temporary environment inside its task workspace. Task commands have no network access until a request is allowed in that task, and an allowed request enables network access for the rest of the task: Codex continues the same conversation in a new turn whose sandbox allows the network, and Claude Code's sandbox then allows each connection and web fetch. With Always deny, or before any allowed request, the sandbox blocks network access. That workspace is removed after the turn, and the final CAD program must replay with bundled CAD dependencies only. The shared CAD runtime, original files and global settings remain protected. Permission prompts offer Allow or Deny, with a checkbox to remember either choice for all future requests. The remembered policy is global to LAD on this Mac, stored outside `.lad` files, and editable in Settings as Ask each time, Always allow or Always deny. Every new proposed operation checks the current policy, including after an earlier automatic decision; saved chat and audit records never grant permission. Changing the policy affects future or pending permission requests, without stopping shell commands already running. Denied or canceled requests do not authorize an installation; Codex must not rephrase or retry the same operation without new user direction. Codex is instructed never to use `lad_import` for geometry it creates or modifies as part of the design, including LAD exports and newly generated SDF/mesh results. Generated geometry stays in the complete replayable CAD program. `lad_import` is for pre-existing external reference geometry and faithful format conversions of user inputs; required exact reference bytes are saved with the final recipe and exposed as `imported_assets[id]`. STL/OBJ reference imports become **faceted closed BRep solids**: exporting them as STEP preserves the facets and does not recover smooth analytic surfaces. Input provenance and dependency descriptions can be retained with the import activity. Standalone open meshes and invalid solids are rejected with actionable diagnostics.

The CAD worker supports complete Python programs using the installed **CadQuery and OCP/OpenCascade APIs**: sketches, curved profiles, Bezier and B-spline geometry, lofts, sweeps, shells, offsets, text, patterns, assemblies, and direct kernel operations. It preloads `cq`, `math`, and `np`; a program assigns its final Shape, Workplane, or Assembly to `result`. The inspector exposes the program for review. Dimensions are millimeters. See [the engine protocol](Engine/README.md), [CadQuery API](https://cadquery.readthedocs.io/en/stable/apireference.html), and [OCP bindings](https://github.com/CadQuery/OCP).

Python programs saved for replay run in a separate macOS sandbox with access to the CAD runtime and their private build directory. They cannot access arbitrary user files, network services, or launch arbitrary commands. This replay-worker restriction is separate from Codex's writable task workspace and external tooling. The engine strips ambient credential environment variables, enforces a build deadline, validates final solids and meshes, and exports STEP itself. Individual native kernel operations still obey OpenCascade's geometry/tolerance requirements; exposing the APIs does not guarantee every generated program will succeed.

## Import source designs

Name an absolute local source path in a prompt, such as `Import the design from /path/to/design.fs`, or use the composer's paperclip. LAD snapshots supported UTF-8 sources (`.fs`, `.scad`, `.py`, `.json`, `.txt`, `.kicad_pcb`) locally and sends references and brief metadata when model generation is needed. Source contents are never inlined in the initial Codex prompt. Codex can open the staged snapshots with read-only tools, using scoped searches rather than dumping large source files. Paths with spaces can be quoted. Up to four files may be attached per request, with a 1 MiB per-file and 2 MiB combined limit. Missing, unreadable, and oversized files produce errors before generation.

Source formats, including `.kicad_pcb`, are passed to Codex as ordinary source references. LAD does not provide a KiCad converter, download component libraries, or route requests by PCB/STEP keywords. If faithful conversion requires external software, Codex can use a user-provided tool or request permission for an optional task-local installation; a supported reference export also remains an option. Codex may use `lad_import` for pre-existing external STEP/BREP or closed STL/OBJ geometry and faithful conversions of user-provided inputs. Only required reference assets retained by the final accepted program are saved; their shapes are available through `imported_assets[id]`. Existing original STEP inputs remain available as `imported_model`. STEP bytes stay local rather than being included in the prompt. Authored design geometry remains a replayable CAD program and must never be exported and re-imported as an opaque input.

Onshape FeatureScript and OpenSCAD are **translated into CadQuery/OCP**, rather than executed by their original CAD systems. Codex must use source dimensions and describe the translation. If it cannot faithfully express the design, it reports the unsupported features and preserves the current design; it cannot substitute the existing design as a successful import. Approximations require an explicit user request. Source comments are treated as data, and source files are never modified by the import path.

## External agents

LAD can serve external agents running on the same Mac through MCP Streamable HTTP. In **Settings → External Agents**, enable the server, choose a port, and create a client credential. The default endpoint is `http://127.0.0.1:47512/mcp`. LAD must remain running. The listener binds only to IPv4 loopback; it does not make LAD available on the LAN or internet. A cloud-hosted agent's `127.0.0.1` refers to its own host and cannot reach this endpoint directly.

Each client receives its own revocable credential and grants for reading, building, committing, exporting, capturing the live viewport, or managing designs. Grants can be restricted to selected designs. Copy the client configuration from Settings into an MCP client that supports Streamable HTTP and authorization headers. A typical configuration has this form; use the actual endpoint and credential supplied by LAD:

```json
{
  "mcpServers": {
    "lad": {
      "url": "http://127.0.0.1:47512/mcp",
      "headers": {
        "Authorization": "Bearer <client-token>"
      }
    }
  }
}
```

The external agent writes a complete CadQuery/OCP program and uses LAD's native CAD tools directly. LAD does not launch its internal Codex agent for these calls. Client configuration and bearer credentials remain on the Mac and are never saved into `.lad` files or tool activity.

1. Call `lad_projects` to find an authorized open design, or use `lad_project_create` for a new independent design window. `lad_project_open` opens LAD's native design chooser; it does not accept an arbitrary filesystem path.
2. Call `lad_task_begin` with the returned `projectID` and a concise `request`. Optional `model` and `reasoningEffort` describe the external agent for the audit; LAD does not choose or run that model. Retain the returned `taskID`, `expectedStateToken`, and `uploadURL`.
3. Upload the complete program and any original reference inputs as binary files using the client credential. For example, with the returned upload URL and credential in task-local environment variables:

   ```sh
   curl --fail-with-body \
     --header "Authorization: Bearer $LAD_MCP_TOKEN" \
     --header 'Content-Type: application/octet-stream' \
     --data-binary @candidate.py \
     "${LAD_UPLOAD_URL}?name=candidate.py"
   ```

   The upload returns an opaque `fileID`. Uploads do not grant access to arbitrary local paths, and never change the original file. Put references and brief metadata in agent context; do not paste program or asset contents into prompts.
4. Call `lad_build` with `taskID`, `programID` set to the uploaded file ID, and the candidate's `title`, `summary`, and required `assetIDs`. Use `lad_inspect`, `lad_measure`, `lad_validate`, and `lad_render` to review and repair candidates. Existing tool arguments named `path`, `queryPath`, or similar accept task file IDs in this external interface. Tools return file IDs and authenticated download URLs, rather than requiring a shared filesystem. Render and screenshot tools return the exact PNG as MCP image content.
5. Call `lad_commit` with `taskID`, the reviewed `artifactID`, `expectedStateToken`, and a unique `idempotencyKey`. Builds and color edits remain speculative until this call. A commit reuses the exact validated native geometry, publishes its revision, and uses LAD's existing autosave writer. A current-design color-only commit updates that revision while preserving history selection. A changed design produces a conflict instead of silently replacing newer work; repeated successful commit requests resolve to the existing revision, including after task cleanup or reopening an authorized design. Check `committed` separately from the response's `persistence.status`, which reports `memory`, `pending`, `saved`, or `failed` and includes an error when saving fails.
6. Use `lad_task_status` to inspect the task, `lad_task_cancel` to stop it, and `lad_task_end` to release temporary files and candidates. All three take `taskID`. A committed task accepts status, downloads, commit retries, and cleanup; start a fresh task for further uploads or CAD operations. Exported files are temporary authenticated downloads; only required original reference assets and complete replay programs become part of a saved design.

Saved history, colors, native inspection, measurements, imports, exports, and mesh reconstruction use the same CAD operations as LAD's internal agent. Task IDs keep work and activity separate across clients and designs. Ordinary renders do not move the live viewport. Optional dependency permission requests still use LAD's existing per-operation policy and owning design window. LAD restricts operations performed through its tools; an external agent remains responsible for its independently executed commands and installations.

## Verification

```sh
Scripts/test.sh
```

To include native app-worker and sandbox checks in a normal macOS Terminal:

```sh
LAD_RUN_ENGINE_TESTS=1 LAD_RUN_SANDBOX_TESTS=1 Scripts/test.sh
```

These checks require the installed CAD runtime and cannot launch a nested macOS sandbox from inside another restrictive sandbox.

The suite includes camera projection invariants for cursor zoom and rotation about the design’s geometric center, Codex process/error/cancellation integration, reference-only context regressions, complete design and geometry roundtrips, and actual CAD builds with STEP reimport and volume checks.

A live Codex request was also verified in the macOS app: a 30 mm OD / 12 mm ID / 8 mm tall spacer ring with 0.6 mm chamfers was generated, rendered, and saved as another design revision. Native UI checks covered selection, context menus, zoom, saved revision restoration, design saving, and STEP export.

## Current scope

This is a working development app with a bundled, managed Python/CAD runtime and an Apple Silicon release pipeline. Local builds are ad-hoc signed; distributable DMGs require the Developer ID/notarization workflow described above. Programs have access to the installed modeling APIs, subject to final solid/preview limits (4,096 solids, 1,000,000 vertices/triangles, and 200,000 UTF-8 bytes of source). There is no native FeatureScript/OpenSCAD interpreter, interactive sketch/constraint editor, or assembly mating UI. Assemblies are previewed as positioned solids with their part names and hierarchy. Current part colors are saved with the design and included in STEP exports; assembly mates are not exported.

The native viewport uses SceneKit with Metal; design files use exact OpenCascade geometry. The bundled runtime omits optional native plugins that require separately installed solver products or MATLAB, and uses Numba’s workqueue backend in place of its optional OpenMP backend. Core CadQuery/OCP construction, sketch solving and the bundled IPOPT solver remain included; the runtime manifest records the exact exclusions. Dependencies retain their own licenses; inspect the installed distributions before redistributing a bundled runtime.
