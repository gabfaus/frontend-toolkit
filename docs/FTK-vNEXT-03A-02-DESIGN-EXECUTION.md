# FTK-vNEXT-03A-02 — Design Motion Phase 1

Phase 1 materializes a read-only, FTK-owned bridge for `taste`, `review-animations`, and `improve-animations`. The bridge has four boundaries: typed local contract, governed source verifier, FTK-owned child runner, and structured adapter output.

## Scope and authority

- `taste` is `PLAN` / `READ_ONLY` / advisory and is eligible only after an explicit request or a distinct material aesthetic gap.
- `review-animations` is `VERIFY` / `READ_ONLY` and requires materially relevant existing motion.
- `improve-animations` is `PLAN` / `READ_ONLY`; it requires a concrete finding or explicit request and returns an inline plan only.
- `animate` is registered but has no Phase 1 handler. It returns `REGISTERED_NO_HANDLER` / `PHASE_2_BLOCKED`; no authorization is inferred from routing, findings, review, improve, or Skill selection.

Taste and Emil content are governed semantic source, not runtime executable code. The adapter does not import, evaluate, spawn, or reproduce upstream Skill output. The child receives only validated structured input and verified source metadata.

## Source and fingerprint

The verifier checks the lock-selected origin, exact commit pin, clean checkout root, regular allowlisted files, MIT identity/path, selection mode, and locked entry/license hashes. The default lock is read from the repository's committed `HEAD`; a non-committed synthetic lock is accepted only by the hermetic test mode. It reads committed bytes with Git metadata commands under a no-optional-locks, no-prompt child environment. It never clones, installs, accesses network, or changes the checkout.

Git blobs are normalized in memory to canonical LF bytes. A CRLF-normalized representation is also derived in memory, and the lock hash may match either representation. The verification record states which representation matched; `sourceFingerprint` deterministically covers the selected dependency, pin, license identity, representations, entry hashes, and consumed auxiliary files.

Consumed auxiliary files are `STANDARDS.md` when review references it, and `AUDIT.md` plus `PLAN-TEMPLATE.md` for improve. Animate material and `RECIPES.md` are outside the Phase 1 fingerprint.

## Execution and effects

The runner uses the locked per-user Node path in normal mode, a PATH fallback only for explicit hermetic test mode, bounded timeout/input/output handling, a child-only environment, structural Windows argv construction, and fail-closed Job Object cleanup. The 03D-compatible envelope preserves `materialized`, `attempted`, `childStarted`, `succeeded`, `exitCode`, `failureType`, `timedOut`, cleanup evidence, and `sourceFingerprint`.

The local lane envelope remains `REQUEST_ONLY`/pre-integration; it does not claim common-dispatcher authorization. A local `dedicatedExecution.succeeded` means only that the FTK-owned semantic adapter completed with a valid result; it is not upstream execution or user authorization. Phase 1 has no network, browser, installation, project write, project-code execution, upstream execution, or runtime subagent invocation. `UPSTREAM_EXECUTION_FAILURE` is retained only because it is part of the shared taxonomy; here it denotes a failed FTK semantic adapter child, not execution of upstream code.

Real dedicated execution requires a prepared governed checkout. The default test path is hermetic and reports `NOT_MATERIALIZED` when those checkouts are absent; it never clones them implicitly.
