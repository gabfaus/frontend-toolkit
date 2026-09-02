# G7-SR3A — Impeccable Authority Boundary

Status: **IMPLEMENTATION COMPLETE IN SR3A — PENDING SR3I INTEGRATION/REVALIDATION** on 2026-09-01.

G7S-003 remains **OPEN**. This branch does not change G7S-004, which also remains **OPEN**.

## Scope and architecture

SR3A adds an FTK-owned structural boundary between Impeccable/project material and agent-facing context:

`pinned source identity -> FTK-owned structural extraction -> strict validation -> versioned typed envelope -> adapter/orchestrator`

Only the validation and envelope stages are implemented here. Raw upstream stdout is never accepted as an agent instruction surface. PRODUCT.md, DESIGN.md, surface briefs, event payloads, and literal strings that resemble directive names remain subordinate data. Only messages owned by the FTK policy become advisory text.

The enforced authority order is:

1. host and system;
2. explicit current user authorization;
3. Frontend Toolkit policy;
4. frontend-orchestrator;
5. Impeccable adapter;
6. upstream content, always untrusted and subordinate.

Invocation of Impeccable means `capability-selected-only`. It grants no spawn, mutation, network, paid-operation, hook, update, telemetry, or live-effect permission.

## Four SR3A artifacts

| Artifact | Responsibility |
|---|---|
| `plugin/frontend-toolkit/security/impeccable-authority-policy.json` | Versioned pin, fingerprints, block/directive/event allowlists, authority rules, subagent contract, and output schema. |
| `plugin/frontend-toolkit/security/impeccable-context-mediator.mjs` | Pure in-memory validation and typed-envelope construction; no imports, I/O, environment access, process execution, or network. |
| `tests/test-impeccable-authority-boundary.ps1` | Hermetic positive, negative, capability-preservation, live-event, subagent, and no-side-effect regression. |
| `docs/G7-SR3A-IMPECCABLE-AUTHORITY-BOUNDARY.md` | Architecture decision, evidence, integration requirements, lifecycle state, and residual risks. |

No shared policy, adapter, orchestrator, upstream, lock, release, packaging, or img2threejs file is modified by SR3A.

## Source identity and context-loading decision

The expected upstream is Impeccable `skill-v4.1.2`, commit `63b04e2530f5c7b41ea83c133daab24f34912456`, snapshot tree `2acc28d100263c6b5d91f9b75f4bb80e88d33ac7ffdef9a1b3618eeb2d97f2cd`.

The policy also fingerprints four authority-relevant files. Their SHA-256 values were calculated from raw Git blobs at the pinned committed HEAD, not from the CRLF-sensitive Windows worktree:

| Contract file | Committed-blob SHA-256 |
|---|---|
| `skill/SKILL.src.md` | `e250f14b803e9b7eb19e0be448d5b312db024c32c8a7162acaa54afde8eb7555` |
| `skill/scripts/context.mjs` | `7c747b6f5bba3ca860a22075b765ea4b0e7688fdcaa97e1dfc5b01a536303a89` |
| `skill/scripts/lib/surface-briefs.mjs` | `33b35099b95d40e034b6a65657a1fd90fd011cdcb752f1c7a51e8470df37e668` |
| `skill/scripts/live/instructions.mjs` | `9bebb2689fbf4f454b3c3afb2b58e1bcb70705113b05041f959f67caa5c802e1` |

The suggested direct use of upstream `loadContext()` was rejected for this gate:

- its function body performs local reads, but it lives in a module with a broad upstream import graph;
- the same module contains update-check network logic, user-profile cache writes, executable probes, environment-dependent behavior, and the disputed authority directives in its CLI path;
- the upstream checkout is intentionally absent from this dedicated/distribution worktree;
- SR3A has no separately reviewed, packaged, effect-confined upstream module boundary that proves the whole import graph remains side-effect-free.

The upstream CLI and module are therefore not imported or executed. The mediator is deliberately import-free. SR3I must provide an FTK-owned extractor that reads only the legitimate structural fields and supplies the mediator's input schema.

## Input and output contract

Context input schema version 1 contains exactly:

```json
{
  "schemaVersion": 1,
  "sourceFingerprint": {},
  "blocks": [],
  "invocation": {
    "skill": "impeccable",
    "capability": "critique"
  }
}
```

Allowed block types are:

- `product-markdown`;
- `design-markdown`;
- `surface-brief`;
- `directive`;
- `subagent-recommendation`.

Unknown top-level keys, block keys, block types, directives, event keys, event types, schema versions, fingerprints, capabilities, subagent workflows, and subagent identities fail closed.

The output is always the versioned envelope:

```json
{
  "schemaVersion": 1,
  "sourceFingerprint": {},
  "data": [],
  "advisory": [],
  "requestedOperations": [],
  "events": []
}
```

Markdown is not reparsed for authority. Headings, separators, directive-looking strings, and prose remain byte-for-byte string data inside their typed data block. A data field can never become a directive automatically.

## Directive and authority rules

Directive enforcement is based on an exact structural allowlist. It is not based on a broad text regex. Each allowed directive has an exact data-field schema and maps to an FTK-owned advisory code/message.

`AUTONOMY_DIRECTIVE_CHECK`, `SUBAGENT_AUTHORIZATION`, and known authority/authorization overrides are explicitly prohibited. Any new directive, including a new name ending in `_AUTHORIZATION`, is absent from the allowlist and is `UNKNOWN -> deny`. Reserved-name signals in the JSON policy are diagnostic defense in depth only.

The mediator never forwards raw directive text. It emits only the policy-owned advisory representation plus validated inert data.

## Live event handling

Known event schemas are registered for `boot`, `generate`, `steer`, `prefetch`, `variant_mount_failed`, `accept`, `discard`, `manual_edit_apply`, `carbonize_cleanup`, `timeout`, and `exit`.

For each event, the mediator:

1. validates the source fingerprint and live schema version;
2. validates exact required/optional fields and their types;
3. rejects unknown fields;
4. explicitly consumes and discards `_instructions` after confirming it is a string;
5. creates a fixed FTK-owned code and next-action classification;
6. records any effectful continuation only as `sr3i-required` and `not-performed`.

SR3A does not poll, reply, mutate, start or stop servers, perform cleanup, read project files, execute a live helper, or implement any other live effect.

## Subagent mediation

Upstream may recommend one of the registered workflows. The recommendation becomes a typed requested operation with `origin: upstream-recommendation`.

- If the host permission model denies subagents, mediation is `inline-required`.
- If the host permission model permits subagents, mediation is `host-may-dispatch`.
- In both cases, mediator execution is `not-performed` and fallback is `inline`.
- The contract contains no `--authorized`, `approved=true`, `authorized=true`, or equivalent fabricated evidence.

The actual spawn remains outside this module and must be performed only by a host boundary that independently knows current permission.

## Capability preservation

The policy retains critique, audit, polish, layout, typography, hierarchy, UX, accessibility, responsive behavior, motion, design systems, and live workflows. PRODUCT.md, DESIGN.md, surface briefs, and legitimate critique/audit context remain available as typed data. Subagent workflows remain representable when host-permitted, with inline fallback when they are not.

Authority override and fabricated authorization are not capabilities and are intentionally blocked.

## Tests and evidence

`tests/test-impeccable-authority-boundary.ps1` proves:

1. expected pin/fingerprint passes;
2. fingerprint drift fails;
3. valid versioned schema passes;
4. unknown key, block, and directive fail;
5. `AUTONOMY_DIRECTIVE_CHECK` is blocked;
6. `SUBAGENT_AUTHORIZATION` is blocked;
7. directive-looking PRODUCT.md text remains data;
8. directive-looking DESIGN.md text remains data;
9. Markdown separators do not alter type or authority;
10. a known live event becomes an FTK-owned representation;
11. free-form `_instructions` is discarded;
12. an unknown live event fails;
13. Skill invocation does not authorize spawn;
14. host permission preserves the subagent request contract;
15. inline fallback remains available;
16. critique/audit and every registered legitimate capability preserve context;
17. the mediator exposes no network surface;
18. execution writes nothing to a monitored synthetic child profile/temp root;
19. no upstream CLI/module/process surface is imported or executed.

The test resolves the exact locked Node runtime, starts it with a cleared child environment containing only synthetic/system essentials, uses no credentials, performs no network, and removes its temporary fixture.

## SR3I Integration Requirements

SR3I must perform the shared-file and cross-branch integration work intentionally excluded here:

1. add exact packaging/release allowlist entries for the policy and mediator; do not introduce `security/**`;
2. add a registered common-dispatcher route for structural context mediation, without an arbitrary script or raw-stdout path;
3. implement an FTK-owned structural extractor for PRODUCT.md, DESIGN.md, surface briefs, normalized safe directives, and live events; it must not invoke the upstream CLI or import its side-effectful graph;
4. verify the pinned commit, snapshot tree, and committed-blob contract hashes before extraction;
5. map only reviewed upstream structural states to the directive allowlist; new states remain `UNKNOWN -> deny`;
6. update the shared Impeccable adapter instructions so callers use the FTK boundary and never follow raw upstream directives;
7. reconcile context/live operation and effect classifications in the shared effect policy with SR3B; G7S-004 effects must remain separately gated;
8. connect subagent requests only to a real host permission check and retain the inline fallback;
9. connect live events only after SR3B/SR3I supplies the appropriate read/write/network/loopback operation boundaries; SR3A's mediator must remain effect-free;
10. add integration and packaging tests proving the source snapshot is non-discoverable, the two SR3A security files are present, and raw upstream stdout cannot reach the agent instruction surface;
11. revalidate exact schemas against the generated pinned snapshot and committed HEAD, then perform the normal deterministic committed-HEAD release evidence cycle before changing finding status or locks.

No item above is authorized or implemented by SR3A.

## Residual risks

- The FTK-owned extractor and dispatcher wiring do not yet exist, so the boundary is not reachable through the current adapter.
- Live schemas are intentionally strict and may require reviewed field additions during integration; drift will block rather than silently degrade.
- The policy identifies pinned source bytes but does not itself read Git or a snapshot; SR3I must supply verified fingerprint evidence.
- A host consumer could misuse a typed requested operation if it ignores the real permission model; integration tests must enforce that boundary.
- G7S-004 network, telemetry, update, paid generation, hooks, child environment, and live effects are outside this branch and remain open.
- G7S-003 cannot advance beyond implementation complete until shared integration and committed-HEAD revalidation prove that no bypass reaches raw upstream instructions.

## Finding lifecycle

G7S-003 technical state after SR3A:

**OPEN — IMPLEMENTATION COMPLETE IN SR3A, PENDING SR3I INTEGRATION/REVALIDATION**

This document does not authorize staging, commit, merge, rebase, push, tag, release, publication, SR3I, or a G7S-003 lifecycle transition.
