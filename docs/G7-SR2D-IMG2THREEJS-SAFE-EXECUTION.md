# G7-SR2D — img2threejs Safe Execution & Final Integration

Status: **IMPLEMENTED; READY FOR FINAL REGRESSION AND HUMAN REVIEW**.

This gate integrates the SR2A parser, SR2B structural validator, and SR2C state guard into one
FTK-owned execution boundary. The pinned upstream remains byte-unchanged and non-discoverable. Its
`build-character.sh` still contains the original `source`, word splitting, and ambient executable
selection, but the FTK runner never invokes that shell file.

## Architecture

The common launcher accepts a registered operation ID plus operation-specific named data. It looks
up `effect-policy.json`, rejects `UNKNOWN` or disabled operations, rejects inputs not registered for
that operation, and dispatches only a fixed FTK handler. It exposes no arbitrary executable, script,
command, or argv parameter and has no authorization boolean.

For executable operations the runner resolves Node 24.20.0 and Python 3.14.7 from the FTK runtime
policy, builds argv arrays, creates a new allowlisted process environment, and invokes known FTK or
pinned-upstream entrypoints. Project configuration cannot select the executable. On Windows
PowerShell 5.1 the runner temporarily replaces the process environment while launching the child and
restores it in `finally`; this keeps the child environment minimal without constructing a command
string.

`PROJECT_CODE_EXECUTION` is a separate effect class. Codec, TypeScript, Vite, and the composite GLB
pipeline use it. A current request to run/build project code plus host sandbox/approval mediation is
required; `PlanOnly` only reduces effects and is not authorization. External network remains a
separate operation boundary.

## Registered operations

| Operation | Effects | Handler/runtime | Network |
| --- | --- | --- | --- |
| `img2threejs.capability-summary` | `LOCAL_READ_ONLY` | built-in | none |
| `img2threejs.state.init` | `LOCAL_PROJECT_WRITE` | guarded pinned Python/state.py | none |
| `img2threejs.state.status` | `LOCAL_READ_ONLY` | guarded pinned Python/state.py | none |
| `img2threejs.state.mark` | `LOCAL_PROJECT_WRITE` | guarded pinned Python/state.py | none |
| `img2threejs.state.next` | `LOCAL_PROJECT_WRITE` | guarded pinned Python/next.py | none |
| `img2threejs.state.create/read/write/update` | read or write as declared | FTK state guard | none |
| `img2threejs.codec-verify` | `PROJECT_CODE_EXECUTION`, `LOCAL_PROJECT_WRITE` | pinned Node + FTK codec mediator + pinned esbuild | none |
| `img2threejs.typescript-build` | `PROJECT_CODE_EXECUTION`, `LOCAL_PROJECT_WRITE` | pinned Node + contained pre-resolved tsc | none |
| `img2threejs.vite-build` | `PROJECT_CODE_EXECUTION`, `LOCAL_PROJECT_WRITE` | pinned Node + contained pre-resolved Vite | none |
| `img2threejs.glb-pipeline` | `PROJECT_CODE_EXECUTION`, `LOCAL_PROJECT_WRITE`, optional `LOOPBACK_EPHEMERAL` | fixed Python/Node stage graph | fixed loopback capture only |
| `img2threejs.network-helper` | `NETWORK_PASSIVE` | not enabled until a specific helper is registered | separate authorization required |

Every enabled operation records executable source, argv grammar, project inputs, output boundaries,
environment names, network requirement, project-code behavior, validators, and state-guard use.
There is no wildcard registration.

## Environment policy

Base child processes may receive only `SystemRoot`, `TEMP`, and `TMP`. Python additionally receives
fixed `PYTHONIOENCODING`, `PYTHONDONTWRITEBYTECODE`, and `PYTHONNOUSERSITE`. Pipeline stages receive
only the normalized 22 `CHARACTER_*` values plus `IMG2THREEJS_SHOWCASE_ROOT`. `PATH`, profile/home
variables, Git/SSH/cloud state, `OPENAI_API_KEY`, `API_KEY_21ST`, and unrelated parent values are not
inherited. Diagnostics enumerate names, never secret values.

## Config and CHARACTER sink revalidation

Both strict legacy `KEY=VALUE` and strict JSON-object forms are supported. JSON values are strings;
duplicate/unknown keys, nested values, invalid UTF-8, trailing data, and excessive inputs fail
closed. Neither form is emitted as a shell program. The runner passes normalized values only as argv
elements or allowlisted environment data to fixed child entrypoints.

| Field | Normalization and final sink |
| --- | --- |
| `CHARACTER_GLB` | contained path; GLB magic/version/length/JSON node inventory validated; data environment/argv |
| `CHARACTER_DIFFUSE` | contained path or fixed enum; data environment |
| `CHARACTER_DEMO_ID` | lowercase slug; fixed argv/data environment |
| `CHARACTER_NODES` | unique integer array; checked against real GLB inventory; one argv element per node |
| `CHARACTER_LEVELS` | unique `x2`/`x3`/`default` array; runner loop, never shell splitting |
| `CHARACTER_BIN_DIR` | contained read/write path; data environment |
| `CHARACTER_OUT_PREFIX` | contained output path; data environment |
| `CHARACTER_WORKDIR` | contained output path; data environment |
| `CHARACTER_WORK_TAG` | bounded safe tag; derived contained capture path |
| `CHARACTER_CODEC` | contained code entrypoint; FTK esbuild module-graph mediation before import |
| `CHARACTER_CODEC_IMPORT` | traversal-free relative module specifier; emitted data, not executable selection |
| `CHARACTER_REGIONS_JSON` | contained optional path; SR2B validation immediately before consumer |
| `CHARACTER_CELL_SIZES_JSON` | contained optional path; SR2B validation immediately before consumer |
| `CHARACTER_SECTION_REGIONS_JSON` | contained optional path; paired SR2B validation immediately before consumer |
| `CHARACTER_SPOKES_JSON` | contained optional path; paired SR2B validation immediately before consumer |
| `CHARACTER_CROSS_SECTIONS` | contained output path; data environment |
| `CHARACTER_DEST_X2` | contained output path; fixed level mapping |
| `CHARACTER_DEST_X3` | contained output path; fixed level mapping |
| `CHARACTER_DEST_DEFAULT` | contained output path; fixed level mapping |
| `CHARACTER_SLICES` | integer 1–4096; data environment |
| `CHARACTER_ALLOW_BASELINE_UV` | exact false/`1`; branch decision/data environment |
| `CHARACTER_UV_SLACK` | invariant finite unit float; data environment |

No field selects Bash, Python, Node, tsc, Vite, esbuild, or another executable. The former
`IMG2THREEJS_GLB_PIPELINE_PYTHON` command-string override is intentionally not accepted: Python is
resolved by FTK and its arguments remain separate.

## Structural integration

The four maps keep the SR2B 1 MiB and 4096-entry FTK resource limits. The composite validator runs
during plan construction and again immediately before any stage marked as a structural JSON
consumer. Region/cell keys must be subsets of configured nodes; section-region/spoke keys must
match; configured nodes must also exist in the actual GLB node array. Downstream Python is not
started when validation fails.

## Codec, TypeScript, and Vite

The codec mediator invokes pinned esbuild without project plugins, bundles the contained entrypoint,
realpaths every metafile input, rejects any module outside the project or through a link, and only
then dynamically imports the temporary bundle to verify the `decodeSurfaces` contract. The pipeline
uses that mediated bundle for upstream round-trip verification.

TypeScript and Vite use the pinned Node executable with fixed entrypoints
`node_modules/typescript/bin/tsc --noEmit` and `node_modules/vite/bin/vite.js build`. Dependencies must
already exist inside the project; the runner never calls `npx`, installs, downloads, or updates them.
Project configuration/plugins can execute, so neither operation is downgraded to a write effect.

## State integration and residual risk

All eight registered state operations require the SR2C guard. Paths stay under canonical
`<project>/.img2threejs`; default and nested paths are supported. Mutations re-resolve immediately
before the effect and verify the resulting canonical target. `next` also validates stored reference
and spec paths before pinned upstream code reads them. No alternate generic state operation remains.

This does not claim complete TOCTOU elimination. A concurrent local attacker able to replace path
components between the final check and an OS operation remains a residual risk. Child processes use
`ProcessStartInfo` with shell execution disabled and an explicitly cleared/rebuilt child environment;
the parent process environment is never replaced, so concurrent launches do not share an environment lock.

## Finding revalidation

- `G7S-001`: **IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**. Project config never reaches `source`; all 22 sinks are
  normalized; nodes/levels avoid shell splitting; executable selection is fixed; argv and environment
  are structural; project code is separately classified; focused regressions pass.
- `G7S-002`: **IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**. All registered state operations pass the actual guard,
  canonical/reparse/pre-operation/post-operation checks pass, and the guard is explicitly packaged.

The status is pending committed-HEAD revalidation after human review and an authorized commit. Historical SR2A/SR2B/SR2C documents intentionally retain the
state that was true at those gates.
