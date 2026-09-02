# G7-SR3B — Impeccable External Effects Mediation

Status: **IMPLEMENTATION COMPLETE IN SR3B — PENDING SR3I INTEGRATION/REVALIDATION**.

This gate addresses only G7S-004. G7S-003 remains open in the parallel SR3A worktree. The pinned
Impeccable checkout remains unchanged at `skill-v4.1.2`, commit
`63b04e2530f5c7b41ea83c133daab24f34912456`.

## Security decision

The FTK boundary now has an Impeccable-specific operation manifest, runner, and network client.
Operations are selected by exact ID, carry one or more explicit effect classes, receive structural
inputs, use fixed handlers and runtime, and fail closed when unknown. Network remains independent
from project-code execution, loopback, telemetry, paid work, writes, and external mutation.

The implementation deliberately does not invent a forgeable authorization flag. Operations that
need a current host grant are registered and inspectable but direct execution remains blocked until
SR3I connects them to a non-forgeable host boundary. This is capability preservation at the correct
layer, not silent removal and not premature enablement.

## Operation inventory

| Family | Operation IDs | Effects | SR3B default |
|---|---|---|---|
| Local context | `impeccable.context.local` | `LOCAL_READ_ONLY` | blocked pending the SR3A parser and SR3I integration |
| Update | `impeccable.update-check` | `NETWORK_PASSIVE` | host network grant required |
| Concepts | `impeccable.concept.local-fallback` | `LOCAL_READ_ONLY` | enabled |
| Concepts | `impeccable.concept.remote-roll`, `impeccable.concept.card-fetch` | `NETWORK_PASSIVE` | host network grant required |
| Telemetry | `impeccable.telemetry.choice` | `TELEMETRY`, `NETWORK_PASSIVE` | separate telemetry opt-in and host network grant required |
| Generation | `impeccable.paid-generation.fake` | `LOCAL_PROJECT_WRITE` | enabled, explicit fake operation only |
| Generation | `impeccable.paid-generation.upstream` | `PAID_GENERATION`, `NETWORK_PASSIVE`, `LOCAL_PROJECT_WRITE` | blocked pending non-forgeable paid authorizer |
| Detector | `impeccable.detector.local` | `LOCAL_READ_ONLY` | blocked pending dispatcher integration |
| Detector | `impeccable.detector.loopback` | `LOCAL_READ_ONLY`, `LOOPBACK_EPHEMERAL` | host loopback grant required |
| Detector | `impeccable.detector.external` | `LOCAL_READ_ONLY`, `NETWORK_PASSIVE` | blocked pending endpoint-specific registration |
| Live | `impeccable.live.loopback` | `LOOPBACK_EPHEMERAL`, `LOCAL_PROJECT_WRITE`, `PROJECT_CODE_EXECUTION` | blocked pending operation authority integration |
| Live | `impeccable.live.external` | `NETWORK_PASSIVE`, `EXTERNAL_MUTATION`, `PROJECT_CODE_EXECUTION` | explicitly denied |
| Hooks | `impeccable.hooks.status` | `LOCAL_READ_ONLY` | blocked pending dispatcher integration |
| Hooks | `impeccable.hooks.enable`, `.disable`, `.ignore`, `.reset` | `LOCAL_PROJECT_WRITE` | blocked pending explicit persistent-write authority |
| Diagnostics | `impeccable.doctor.report` | `LOCAL_READ_ONLY` | blocked pending dispatcher integration |
| Generic write | `impeccable.project.write` | `LOCAL_PROJECT_WRITE` | explicitly denied; a specific future write must be registered |
| Self-update | `impeccable.self-update` | `EXTERNAL_MUTATION`, `NETWORK_PASSIVE`, `LOCAL_PROJECT_WRITE`, `PROJECT_CODE_EXECUTION` | explicitly denied |

The manifest also inventories every top-level `.mjs`/`.js` entrypoint in the reviewed upstream
Skill. Each is mapped to exact operations, marked library-only, or explicitly denied. There are no
wildcard operations. A newly added upstream script is absent from the inventory and therefore
`UNKNOWN`/denied.

## Operation policy

`impeccable-operation-policy.json` records, for every operation:

- exact operation ID and known upstream script or FTK handler;
- all effect classes;
- accepted inputs and project-path inputs;
- output boundaries and endpoint requirements;
- child environment allowlist;
- persistent-effect and project-code-execution state;
- capability description, default state, and authorization requirement.

The policy is intentionally separate from the shared `effect-policy.json` during SR3B. Updating the
shared manifest is an SR3I integration action and was outside this worktree's ownership.

## Runner architecture

`impeccable-runner.ps1` accepts only an operation ID and operation-specific typed parameters. It
loads the manifest, rejects unknown IDs/effects/inputs, canonicalizes the project root, checks
containment and existing reparse points for outputs, resolves the locked Node 24.20.0 runtime, and
uses `ProcessStartInfo` with Windows-native structural argv serialization.

No arbitrary executable, script path, argv array, shell command string, `Invoke-Expression`,
`--authorized`, or `approved=true` surface exists. The runner never replaces or mutates the parent
environment. Direct diagnostics report effect and execution metadata without arguments, prompts,
environment values, credentials, or response bodies.

Release runtime resolves the generated pinned snapshot. A clearly marked `DevelopmentWorkingTree`
fallback resolves the locked checkout only for local diagnostics/tests; it is not release evidence.
Committed HEAD remains the only future release source of truth.

## Child environment

Each child starts from an empty environment. The baseline names are only `SystemRoot`, `TEMP`, and
`TMP`, plus the operation controls that are explicitly registered. Local/default operations force:

- `IMPECCABLE_NO_UPDATE_CHECK=1`;
- `IMPECCABLE_NO_TELEMETRY=1`;
- `DO_NOT_TRACK=1`.

The fake generator additionally receives only `IMPECCABLE_IMAGE_GEN_FAKE=1`. It does not receive
`OPENAI_API_KEY`. The default boundary also excludes `API_KEY_21ST`, Codex state/auth, Git/cloud
credentials, full `PATH`, `HOME`, `USERPROFILE`, and unrelated tokens. `OPENAI_API_KEY` is reserved
in policy exclusively for the exact paid child after a future host grant; SR3B never reads or
injects it.

## Network policy

`impeccable-network-client.mjs` accepts operation IDs and structural fields, never a caller URL.
Production-known destinations are:

| Operation | Exact destination |
|---|---|
| update check | `GET https://impeccable.style/api/version` |
| concept roll | `GET https://impeccable.style/api/roll` with allowlisted query keys |
| card asset | `GET https://impeccable.style/worlds/cards/{validated-card}.webp` |
| choice telemetry | `POST https://impeccable.style/api/chosen` |
| paid generation contract | `POST https://api.openai.com/v1/images/generations` or `/v1/images/edits` |

Unknown operation, host, method, path, query/input field, card name, URL credential, fragment, or
redirect is blocked. Responses are bounded and typed. The client never accepts or injects an OpenAI
key and refuses to execute the paid route; that route belongs to the dedicated upstream child after
host authorization. Tests inject a local mock transport directly into the module and never widen
production policy to localhost.

## Telemetry

FTK telemetry is off by default. Concept selection does not imply telemetry. The only telemetry
route is `impeccable.telemetry.choice`, which requires both a separate telemetry opt-in and network
authorization.

The hermetic regression imported the real pinned `concept-seed.mjs`, replaced `fetch` with an
in-process counter, and independently proved that `IMPECCABLE_NO_TELEMETRY=1` and `DO_NOT_TRACK=1`
each cause `pingChosen` to return without calling the transport. No external network was available
to that proof.

## Update check and self-update

Local context plans force the upstream update check off and do not start a child. The explicit
update operation returns only typed version data and records `updatePerformed=false` and
`cacheWritten=false`. It neither reads nor writes the upstream HOME/profile cache.

`npx impeccable update` is an explicitly denied runtime operation. Impeccable upgrades remain an
FTK governance process: select a new version, update the pin, review the security diff, preserve
provenance/license, run proportional tests, update locks only from committed HEAD, and pass release
review.

## Concept catalog

Without network authorization the runner makes no connection and returns a deterministic typed
`degraded-local` assignment. With a future host network grant, the remote roll and card operations
retain the upstream catalog endpoints. Remote roll output explicitly states
`telemetrySent=false`; choice telemetry remains a separate operation and permission.

## Paid generation

The paid capability is preserved in three layers:

1. host-native image generation remains preferred when the host can authorize it;
2. the upstream paid fallback is fully described with fixed endpoints, prompt/reference/output
   boundaries, minimum environment, and exact key scope;
3. the upstream fake mode executes today as an explicit zero-cost operation and writes only below
   `<project>/.impeccable/ftk-generated`.

Without a non-forgeable host grant the real upstream path creates no child, connection, key
injection, or output. SR3B performed no real generation.

## Live, hooks, and persistent effects

Live loopback is explicitly classified as loopback plus project write plus project-code execution.
Its endpoint contract binds only `127.0.0.1`; `PROJECT_CODE_EXECUTION` does not imply external
network. Non-loopback live is a distinct denied operation. SR3B does not parse live authority.

Hook status is read-only. Enable, disable, ignore, and reset are distinct persistent project-write
operations. No hook runs or changes merely because Impeccable is selected. Doctor/report stays a
read-only capability, while generic project writes are denied until replaced by specific
operation-level contracts.

## Capability preservation

| Capability | Preservation state |
|---|---|
| local detector and doctor/report | registered for SR3I dispatcher integration |
| loopback detector | registered with separate loopback grant |
| external detector | preserved but blocked until an exact endpoint is registered |
| remote concept catalog/cards | exact network operations registered |
| local/degraded concepts | enabled and tested |
| image/design generation | host-native route preserved; upstream paid contract registered; fake route tested |
| explicit update check | registered as typed, cache-free network read |
| live workflow | registered with loopback/write/project-code effects separated |
| hooks | status separated from explicit persistent mutations |
| project writes and persistent operations | preserved only through specific future operations and grants |
| automatic telemetry/update/paid work and silent self-update | intentionally not preserved |

## Tests

`tests/test-impeccable-effects-mediation.ps1` uses temporary fixtures, the pinned upstream, a
synthetic parent secret, and in-process HTTP mocks. It proves all 26 requested properties:
entrypoint registration, unknown denial, child isolation, secret-safe diagnostics, telemetry
defaults and real upstream flags, update separation, offline concept fallback, paid zero-effect
denial and fake routing, endpoint/output rejection, loopback/live rules, persistent hook behavior,
effect independence, and absence of real network, paid work, or dependency installation.

The gate also validates JSON parsing, Node syntax, PowerShell AST, `git diff --check`, and final Git
state. No large shared suite is required or authorized here.

## SR3I Integration Requirements

SR3I must make the following shared changes; none was performed in SR3B:

1. Add exact, literal packaging allowlist entries for
   `security/impeccable-operation-policy.json`, `security/impeccable-runner.ps1`, and
   `security/impeccable-network-client.mjs`. Do not add `security/**`.
2. Extend the shared `effect-policy.json` with the exact operation records selected for runtime;
   retain `UNKNOWN=deny`, multiple effects, persistent flags, and separate `NETWORK_PASSIVE`.
3. Extend `invoke-capability.ps1` with operation-specific structural parameters and handlers only.
   Do not expose arbitrary script/executable/argv/URL or any authorization flag.
4. Integrate the SR3A structural/version-aware context parser before enabling
   `impeccable.context.local`. SR3B does not sanitize or reinterpret upstream authority text.
5. Connect network, telemetry, paid, loopback, project-write, and project-code routes to actual
   non-forgeable host grants. If the host cannot supply such evidence, keep each affected route
   blocked exactly as SR3B does.
6. Ensure the real paid child receives `OPENAI_API_KEY` from the host only for the exact approved
   operation. Prefer host-native image generation; never expose the key to the agent, argv, logs,
   policy files, or unrelated children.
7. Register exact detector, live sub-operation, hook selector, doctor, and project-write argv/path
   validators before changing their default states. Do not collapse them into a generic script or
   write operation.
8. Update the FTK-owned Impeccable adapter to describe only the integrated operations after SR3A
   and SR3B merge. Preserve capability descriptions and current authority ordering.
9. Add the new focused regression to the appropriate shared test driver and packaging checks
   without modifying the test to require external network or real credentials.
10. Build twice from identical committed HEAD, compare plugin/artifact hashes, then perform finding
    revalidation and human review. DevelopmentWorkingTree hashes must remain diagnostic and must
    not update release/distribution locks.
11. Keep G7S-004 open until integration and committed-HEAD revalidation. Do not change G7S-003
    lifecycle from SR3B evidence.

## Residual risks

- Most upstream runtime entrypoints remain intentionally blocked until SR3I supplies the shared
  dispatcher and host authority boundary; SR3B alone is not a release-complete integration.
- The development checkout fallback is useful for hermetic testing but is not release evidence.
- Reparse ancestry is checked before and after the fake output operation, but complete TOCTOU
  elimination against a concurrent local attacker is not claimed.
- An upstream service endpoint or response-schema change fails closed and requires a reviewed
  policy update.
- Detector/live/write subcommands need operation-specific argument and path contracts before
  enablement; a generic pass-through would reopen G7S-004.

## Finding state

G7S-004 remains **OPEN**. The accurate technical state is:

**IMPLEMENTATION COMPLETE IN SR3B — PENDING SR3I INTEGRATION/REVALIDATION**.

G7S-003 remains **OPEN** and is not implemented or reclassified by this gate.
