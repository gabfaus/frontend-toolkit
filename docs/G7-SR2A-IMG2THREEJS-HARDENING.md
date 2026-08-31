# G7-SR2A img2threejs hardening analysis and foundation

Status: **SAFE CHECKPOINT; G7S-001 and G7S-002 remain OPEN**.

This checkpoint audits the pinned img2threejs v1.5.1 snapshot at commit
`dede5909be4e494b228c801a55dda47439143932`. No upstream file was modified or executed. The FTK
operations `img2threejs.glb-pipeline` and `img2threejs.state` remain `blocked-g7-sr2`.

## G7S-001 data flow

The current upstream flow is:

`--config` argv -> `CONFIG` -> file check -> `source "$CONFIG"` -> shell variables -> selected exports,
shell interpolation and argv -> Python/Node scripts -> filesystem/build/code-execution sinks.

Quoting `$CONFIG` protects only the filename. `source` still evaluates every command, substitution,
redirection and function in project-provided content. No executable `eval` statement exists in the GLB
pipeline or its called scripts; unrelated `model.eval()` calls are ML inference-mode methods, not code
evaluation. `source` is nevertheless equivalent arbitrary shell interpretation for this finding.

The pipeline has two unsafe unquoted expansions:

- `$CHARACTER_NODES` becomes multiple argv entries and also permits pathname expansion;
- `$CHARACTER_LEVELS` controls two `for` loops through shell word splitting and pathname expansion.

`IMG2THREEJS_GLB_PIPELINE_PYTHON` is outside the `CHARACTER_*` schema but is another executable
boundary. It is stored in scalar `PY` and invoked as `"$PY"`; therefore the documented multiword value
`uv run ... python3` is treated as one executable name, while any single executable path is caller
selectable. A mediated runner must select a registered executable plus a fixed argv prefix; it must not
accept a command string.

### Complete CHARACTER_* sink map

| Field | Structural type | Downstream sinks | Security/effect note |
|---|---|---|---|
| `CHARACTER_GLB` | contained project path | `head`; argv to `verify_cells.mjs`; Python/Node GLB reads; inherited subprocess env | read |
| `CHARACTER_DIFFUSE` | contained path or `none/neutral/embedded/glb` | Pillow image read in `export_sdf_surfaces.py` | read |
| `CHARACTER_DEMO_ID` | lowercase slug | default destination construction; capture `--demo`; render-profile filename and URL fragment | path/URL interpolation |
| `CHARACTER_NODES` | unique non-negative integer list | unquoted argv to `export_sdf_surfaces.py`; per-node indexing and subprocess argv | unsafe shell split in upstream |
| `CHARACTER_LEVELS` | unique subset of `x2/x3/default` | two unquoted shell loops; argv to encode/emit/roundtrip; filename suffixes | unsafe shell split in upstream |
| `CHARACTER_BIN_DIR` | contained project path | Node binary reads; shell `mv` away and restore during Stage 9 | read plus temporary rename |
| `CHARACTER_OUT_PREFIX` | contained project path prefix | Python `.bin` destination creation/write | write |
| `CHARACTER_WORKDIR` | contained project path | Python directory creation; `V.npy`/`T.npy` intermediates | write |
| `CHARACTER_WORK_TAG` | empty or safe `-tag` | Node/Python intermediate and capture output filenames | read/write path interpolation |
| `CHARACTER_CODEC` | contained project code path | esbuild `entryPoints`, generated module, dynamic `import()` in `verify_roundtrip.mjs` | executes project code |
| `CHARACTER_CODEC_IMPORT` | safe `./` module specifier | interpolated into generated TypeScript import | source generation; must exclude quotes/traversal |
| `CHARACTER_REGIONS_JSON` | optional contained JSON path | JSON read; labels enter metadata then generated TS through `JSON.stringify` | nested schema required |
| `CHARACTER_CELL_SIZES_JSON` | optional contained JSON path | JSON read; numeric values drive allocation/geometry | nested schema required |
| `CHARACTER_SECTION_REGIONS_JSON` | optional contained JSON path | JSON read by cross-section/UV scripts; labels become TS identifiers | nested schema and identifier validation required |
| `CHARACTER_SPOKES_JSON` | optional contained JSON path | JSON read; integers drive geometry size/work | nested schema required |
| `CHARACTER_CROSS_SECTIONS` | optional contained project path | Python read and overwrite | read/write |
| `CHARACTER_DEST_X2` | optional contained project path | argv to `emit_surface_module.mjs` -> `writeFileSync` | write generated TS |
| `CHARACTER_DEST_X3` | optional contained project path | argv to `emit_surface_module.mjs` -> `writeFileSync` | write generated TS |
| `CHARACTER_DEST_DEFAULT` | optional contained project path | argv to `emit_surface_module.mjs` -> `writeFileSync` | write generated TS |
| `CHARACTER_SLICES` | integer 1..4096 | Python environment -> cross-section loop/allocation | config assignment is not exported upstream |
| `CHARACTER_ALLOW_BASELINE_UV` | empty or exact `1` | shell branch and Python opt-in gate -> in-place TS rewrite | explicit mutating mode; config assignment is not exported upstream |
| `CHARACTER_UV_SLACK` | finite invariant float 0..1 | Python UV matching tolerance | config assignment is not exported upstream |

The upstream shell exports only a subset after sourcing. `CHARACTER_SLICES`,
`CHARACTER_ALLOW_BASELINE_UV` and `CHARACTER_UV_SLACK` set only in the config are not reliably present
in child Python processes unless they were already exported by the parent. A future runner must create a
fresh allowlisted environment explicitly rather than inherit or depend on Bash export attributes.

### Called scripts and process boundaries

`build-character.sh` directly invokes fixed script paths for:

1. `python/build_cross_sections.py`;
2. `python/bake_atlas_uvs.py`;
3. `python/export_sdf_surfaces.py`;
4. `node/verify_cells.mjs`;
5. `node/encode_surfaces.mjs`;
6. `node/emit_surface_module.mjs`;
7. `node/verify_roundtrip.mjs`;
8. `node/capture-character.mjs`.

`export_sdf_surfaces.py` calls `build_head_surface.py` with a real argv array:
`[sys.executable, fixed-script, node, cell]`, `shell=False` by default. It inherits the entire ambient
environment and overrides only `CHARACTER_GLB`; the argv boundary is safe from shell reparsing, but the
environment is broader than the future FTK allowlist.

The shell also calls fixed `head`, `git`, `node`, `npx`, `mv`, `mktemp` and `rmdir` commands. `npx tsc
--noEmit` and `npx vite build` may load project configuration/plugins and therefore execute project
code. `verify_roundtrip.mjs` also bundles and dynamically imports the project-selected codec. These are
legitimate capability surfaces, not safe read-only operations, and require an accurately classified
enabled operation later. `compare_views.mjs` is only printed as a suggested next command; it is not
invoked by the pipeline. Top-level `scripts/character_audit.sh` is separately callable and not called by
`build-character.sh`; its argv use is quoted and it invokes fixed Node/Python scripts, but it remains a
separate executable surface for later registration and validation.

### Closed structural schemas

The line parser schema is version 1 and contains exactly the 22 fields above. Grammar is one
`KEY=VALUE` assignment per line plus blank lines/comments. Unknown and duplicate keys, `export`, inline
comments, multiline values, command substitution and backticks fail closed. Quotes delimit data; they
do not enable shell escapes. The only placeholder is an exact leading
`${IMG2THREEJS_SHOWCASE_ROOT}`, resolved structurally against the authorized project root. Config and
all path fields must be relative and contained; existing reparse points are rejected.

Before the pipeline can be enabled, the four referenced JSON documents must be parsed and validated as:

- regions: JSON object, canonical non-negative-integer string keys, lowercase identifier values;
- section regions: JSON object, canonical non-negative-integer string keys, TypeScript-safe uppercase
  identifier values;
- spokes: JSON object, canonical non-negative-integer string keys, integer values in `3..4096`;
- cell sizes: JSON object, canonical non-negative-integer string keys, finite numeric values in `(0,1]`.

All objects must reject duplicate JSON keys after parsing, inherited/prototype properties, non-finite
numbers and unexpected nesting. Node keys must be unique and consistent with `CHARACTER_NODES` where
the consuming stage requires it. This nested-schema validator is specified but not implemented in this
checkpoint, so G7S-001 remains open.

## G7S-002 containment algorithm

`AUTHORIZED_ROOT` is the physical project root joined with `.img2threejs`. The closed algorithm is:

1. require an existing project directory and resolve it physically;
2. accept only a relative input beginning exactly `.img2threejs/`;
3. require a non-empty `.json` leaf;
4. reject rooted, drive-relative and alternate-data-stream forms;
5. join and normalize with the platform path library;
6. compare candidate to `AUTHORIZED_ROOT + separator` using platform-appropriate case semantics;
7. reject every existing reparse/symlink/junction component from the boundary through the target;
8. repeat containment immediately before every read, directory creation, temporary-file creation and
   atomic replace; never accept a previously validated path as a durable authority token.

Default `.img2threejs/state.json` and arbitrarily nested state below that root remain supported.
Absolute paths, traversal, a foreign project subdirectory and detectable link-target escape fail closed.
The foundation resolver is intentionally non-mutating. The repeated checks and actual load/save handler
are not wired in this checkpoint; a no-follow/handle-relative implementation should be preferred where
the host offers it to reduce TOCTOU risk. G7S-002 therefore remains open.

## Implemented foundation and remaining work

Implemented and focused-testable:

- schema-versioned, allowlisted, non-shell parser for the safe compatible config subset;
- typed node/level/numeric/flag values and an explicit future environment map;
- project/config/path containment with existing reparse-point rejection;
- non-mutating state resolver preserving default and nested state;
- tests for compatible parsing, unknown/duplicate keys, shell syntax, unquoted reparsing, traversal,
  absolute/foreign/non-JSON state, real temporary junction escape, and blocked operation status.

Remaining before either finding may be called mitigated:

1. implement and test the four nested JSON validators;
2. implement a fixed executable/argv registry and fresh environment allowlist;
3. replace upstream orchestration behavior through an FTK-owned handler without modifying upstream;
4. remove all shell word-splitting/globbing from runtime data flow;
5. enforce path access mode at every called-script read/write and protect destructive rename/restore;
6. mediate project-code execution (`CHARACTER_CODEC`, tsc and Vite) as its true effect;
7. wire load/save through repeated state containment and adversarial race/reparse tests;
8. re-run focused, adapter, packaging and security regressions before changing blocked status.
