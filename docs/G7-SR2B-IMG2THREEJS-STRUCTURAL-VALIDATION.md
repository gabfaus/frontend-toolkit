# G7-SR2B img2threejs structural data validation

Status: **READY FOR HUMAN REVIEW; G7S-001 and G7S-002 remain OPEN**.

This checkpoint derives and implements closed structural contracts for the four auxiliary JSON files
used by the pinned img2threejs v1.5.1 snapshot at commit
`dede5909be4e494b228c801a55dda47439143932`. The upstream was inspected statically and was neither
modified nor executed. No runner, state handler, shell pipeline, project-code execution, network access,
or effect release is introduced here.

## Upstream-derived data flow

`python/export_sdf_surfaces.py` reads `CHARACTER_REGIONS_JSON` as node-index-to-label data. Missing
entries deliberately fall back to `region<N>`. The label is serialized into binary metadata, preserved
by the Node encoding scripts, and emitted through `JSON.stringify`; it is data, not a TypeScript
identifier. The same Python consumer overlays `CHARACTER_CELL_SIZES_JSON` onto built-in per-node cell
sizes, then uses each positive value for geometry allocation.

`python/build_cross_sections.py` reads `CHARACTER_SECTION_REGIONS_JSON` and `CHARACTER_SPOKES_JSON`.
Every section-region key is indexed in the spokes map, multiple nodes may share a region, and each
region label is interpolated directly into `export const <REGION>_SECTIONS`. Consequently the two maps
must have identical key sets and section-region labels must be TypeScript-safe identifier components.
`python/bake_atlas_uvs.py` reuses the section-region map only to group GLB nodes; it adds no new shape.

The upstream consumers accept overly broad Python values and have no resource ceilings. The FTK closes
that ambiguity as follows:

| Input | Root and cardinality | Keys | Values | Required relationship |
|---|---|---|---|---|
| regions | object, 0..4096 entries | canonical decimal node id, `0..Int32.MaxValue` | NFC lowercase data identifier, 1..64 UTF-16 units, Unicode letters/digits plus `_`/`-` | keys are a subset of `CHARACTER_NODES`; omissions preserve the upstream fallback |
| cell sizes | object, 0..4096 entries | same | finite JSON number in `(0,1]` metres | keys are a subset of `CHARACTER_NODES`; omissions preserve built-in defaults |
| section regions | object, 1..4096 entries | same | ASCII `^[A-Z][A-Z0-9_]*$`, 1..64 units | key set exactly equals spokes; duplicate labels remain valid because a region may span nodes |
| spokes | object, 1..4096 entries | same | JSON integer `3..4096` | key set exactly equals section regions |

The lower bounds come from geometry: a ring needs at least three spokes and a cell size must be
positive. The upper bounds are FTK availability limits, not claims made by upstream: 4096 caps work per
ring/map and one metre caps a nonsensical geometry scale while preserving the upstream's practical
millimetre-scale use. Each file is capped at 1 MiB and nesting is forbidden because all four real
contracts are flat scalar maps.

## `CHARACTER_NODES` and Stage 1

Regions and cell sizes are consumed only while iterating `CHARACTER_NODES`, so dangling keys are
rejected. Section regions and spokes are different: upstream documentation says nodes not selected for
Stage 2 remain on the Stage 1 loft. Forcing the Stage 1 maps to equal `CHARACTER_NODES` would therefore
remove a legitimate configuration. G7-SR2B validates their mutual exact key set but does not invent a
false equality with `CHARACTER_NODES`.

Confirming that any node id exists in the GLB requires a separately bounded structural inventory of the
GLB. That input and integration belong to SR2D. Until then, Stage 2 dangling references are rejected
against `CHARACTER_NODES`, and Stage 1 is internally closed but not claimed to be GLB-proven.

## Parser and security boundary

The FTK-owned parser does not rely on `ConvertFrom-Json`. It scans the closed JSON grammar, records keys
before conversion, rejects duplicate keys, invalid/truncated JSON, trailing data, non-finite or
unrepresentable numbers, invalid Unicode surrogate sequences, raw control characters, nesting, and
oversized inputs. Scalar types remain distinct, so booleans and numeric strings cannot pass as numbers,
and `3.0` cannot pass as an integer spoke count.

No value inside these four documents is a module specifier, executable, plugin, import path, or
filesystem path. `PROJECT_CODE_EXECUTION` is technically required for the separate `CHARACTER_CODEC`,
TypeScript, and Vite boundaries identified in SR2A, but these JSON contracts neither create nor release
that capability. `effect-policy.json` is intentionally unchanged to avoid coupling SR2B to the parallel
SR2C worktree; SR2D must integrate the effect-class decision with the final mediated runner.

The public coordinator returns typed, validated data only. Its literal paths must already have passed
the SR2A project-root containment boundary before SR2D calls it. It does not source configuration, load
modules, invoke shell/Python/Node/upstream, access network, write project/state files, or mediate the
runner.

## SR2D dependencies

SR2D must still:

1. validate the actual GLB node inventory before accepting Stage 1 node references;
2. pass only SR2A-contained JSON paths to this module and repeat path checks immediately before reads;
3. create a fresh allowlisted environment and fixed executable/argv registry;
4. classify and gate `CHARACTER_CODEC`, TypeScript, and Vite as project-code execution;
5. integrate the independently reviewed SR2C state containment without weakening either boundary;
6. keep `img2threejs.glb-pipeline` and `img2threejs.state` blocked until all remaining gates close.
