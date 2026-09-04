# G7-SR3I — Impeccable Integrated Security Boundary

Status: **IMPLEMENTATION COMPLETE — PENDING COMMITTED-HEAD REVALIDATION**.

G7S-003 and G7S-004 remain **OPEN**. This pre-commit gate does not mark either finding mitigated or closed.

## Integrated architecture

The only supported runtime chain is:

`user/host -> frontend-orchestrator -> FTK Impeccable adapter -> authority mediator -> typed requested operation -> common dispatcher -> common effect policy -> Impeccable operation policy -> host authorization boundary -> fixed runner/network handler`

Every stage is fail closed. An operation proceeds only when its ID is registered, its authority representation is typed, every required effect is independently classified, its authorization requirement is satisfied, and its fixed handler is available. No operation ID, argv field, environment value, project file, agent flag, or upstream payload is authorization.

## Contract reconciliation

SR3I reconciles the SR3A authority contract with the SR3B operation contract by mapping context and known live events to canonical Impeccable operation IDs. The integrated regression asserts exact equality between the Impeccable operation inventory in `effect-policy.json` and `impeccable-operation-policy.json`, including ordered effect sets. Unknown operation, effect, live event, directive, schema, field, or source identity fails closed.

`impeccable-context-mediator.mjs` remains import-free and effect-free. The new `impeccable-context-extractor.mjs` is separate because filesystem extraction cannot be added to the pure authority boundary without invalidating SR3A's no-I/O property. The extractor reads only bounded physical PRODUCT.md, DESIGN.md, and `.impeccable/surfaces/*.md` files below a validated project root. It rejects ambiguous context names, path escape, symlink/junction input, unknown surface names, oversized files, and policy drift. Project text remains data even when it resembles an authority directive.

## Host authorization

No repository or current plugin interface provides non-forgeable host authorization evidence to `invoke-capability.ps1`. SR3I therefore does not invent one. Operations requiring network, telemetry opt-in, paid work, persistent project writes, live execution, hook mutation, or external mutation remain registered and return `AUTHORIZATION_REQUIRED` before their handler is invoked. `PlanOnly` exposes the exact effects and authorization decision without executing a handler.

Local context mediation, live-event mediation, capability summaries, the degraded local concept route, declarative hook status, and an FTK boundary doctor/report are enabled. G7-SR3I-D replaces the reduced detector with separate file, project, payload, and CSP `LOCAL_READ_ONLY` operations. Those detector operations start only the locked Node child with an empty-by-default allowlisted environment and Node permission mode granting reads to fixed boundary/upstream/project roots; network, writes, subprocesses, browser startup, and project-code execution receive no permission. External detector remains blocked pending an endpoint-specific operation. Generic project write and self-update are explicitly denied runtime operations. See `G7-SR3I-D-IMPECCABLE-DETECTOR-CAPABILITY.md`.

## Effects and behaviors

- `NETWORK_PASSIVE` never implies `TELEMETRY`, `PAID_GENERATION`, `LOCAL_PROJECT_WRITE`, or `PROJECT_CODE_EXECUTION`.
- Live loopback requires `LOOPBACK_EPHEMERAL`, `LOCAL_PROJECT_WRITE`, and `PROJECT_CODE_EXECUTION`; it does not receive external network implicitly.
- Known live payloads are mediated by `impeccable.live.event-mediate`; `_instructions` is discarded and effectful continuation remains `not-performed` until separately dispatched.
- Telemetry defaults off through `IMPECCABLE_NO_TELEMETRY=1` and `DO_NOT_TRACK=1` in the exact child.
- Local context forces `IMPECCABLE_NO_UPDATE_CHECK=1`; explicit update check is a cache-free network read; self-update has no runtime handler.
- Host-native generation remains preferred. Upstream paid generation is registered with paid, network, write, endpoint, output, and child-secret contracts but remains blocked without a non-forgeable host spend boundary. No paid call was made.
- Hook status is read-only; enable, disable, ignore, and reset are distinct persistent mutations. Skill invocation never activates hooks.

## Child environment and packaging

Impeccable children start from an allowlist and do not inherit PATH, HOME, USERPROFILE, Codex state, cloud/Git credentials, `API_KEY_21ST`, or `OPENAI_API_KEY`. The parent environment is never replaced. Diagnostics omit argv, prompt, environment values, credentials, and response bodies.

The packaging allowlist names all seven Impeccable guards literally, including the extractor and detector boundary. The release-safety regression asserts that actual security files equal the exact expected security files and that the same set equals the allowlisted files. No `security/**` or extension wildcard was introduced.

## Validation and lifecycle

The focused SR3A and SR3B tests and the combined SR3I regression use only synthetic files, fixed local runtimes, in-process mocks, and loopback-free local execution. They perform no external network, telemetry, paid generation, self-update, dependency installation, or real secret access. The source still discovers exactly three FTK-owned Skills and packages exactly two MCPs; upstream Impeccable remains non-discoverable; img2threejs boundaries are unchanged.

DevelopmentWorkingTree builds are diagnostic pre-commit evidence only. `integrations/distribution.lock.json` and `integrations/release.lock.json` are intentionally unchanged. After a human-approved commit, a separate gate must build twice from the exact committed HEAD, prove identical plugin and artifact hashes, reconcile locks from that committed evidence, rerun the complete security/capability suite, and only then consider `MITIGATED` followed by human review.

Technical finding state:

- G7S-003: **OPEN — IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**.
- G7S-004: **OPEN — IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**.
