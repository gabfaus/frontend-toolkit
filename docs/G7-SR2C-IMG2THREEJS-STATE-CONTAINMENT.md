# G7-SR2C img2threejs state containment

Status: **IMPLEMENTATION COMPLETE — PENDING INTEGRATION/REVALIDATION**.

G7-SR2C implements the FTK-owned filesystem boundary required for G7S-002. It does not enable
`img2threejs.state`, execute upstream, implement the GLB runner, or integrate SR2B. G7S-001 remains
OPEN. The final finding transition is reserved for SR2D after launcher integration and full
revalidation.

## Boundary and preserved capability

The only authorized state root is the canonical project directory joined with `.img2threejs`.
The guard accepts the default `.img2threejs/state.json` and arbitrarily nested `.json` state below
that root. It provides concrete read, create, write, and update handlers. The operation contract maps
upstream behavior without executing it:

| Upstream behavior | Guarded access | SR2C handler or SR2D contract |
|---|---|---|
| `init` | create without overwrite | `ftk.state.create` |
| `status` | read | `ftk.state.read` |
| `mark` | update existing | `ftk.state.update` |
| `next` | read, and update when synchronization requires it | `ftk.state.read/ftk.state.update` |
| direct read/write/update | explicit state-only operation | implemented in SR2C |

This is not a generic writer or script runner. Inputs must name JSON state under the component root;
absolute, UNC, drive-relative, alternate-stream, traversal, foreign-root, sibling-prefix, and
foreign-extension forms fail closed. Content receives only JSON syntax validation in this gate.
The four structural JSON schemas and every `CHARACTER_*` rule remain owned by SR2B.

## Enforcement

`plugin/frontend-toolkit/security/img2threejs-state-guard.ps1`:

1. receives and canonicalizes an explicit existing project root;
2. derives `<project>/.img2threejs` and safely creates it only for a validated mutating request;
3. rejects a project root, authorized root, target, or existing descendant boundary component with
   `FileAttributes.ReparsePoint`;
4. compares path components with ordinal case-insensitive semantics on Windows and ordinal semantics
   elsewhere, rather than using a textual prefix;
5. rejects dot, traversal, empty, rooted, drive-relative, UNC, alternate-stream, and non-JSON input;
6. canonicalizes existing targets; for nonexistent targets, finds the nearest existing ancestor,
   canonicalizes it, and rebuilds only validated segments;
7. proves that both target and parent remain within the authorized root;
8. creates nested directories one level at a time with a boundary recheck before each creation;
9. re-resolves target and boundary immediately before temporary-file creation and atomic commit;
10. writes a same-directory temporary file, atomically moves or replaces it, then canonicalizes and
    verifies the resulting target;
11. validates temporary and backup paths before cleanup.

The release source allowlist includes the guard, but the common launcher and effect manifest still
leave `img2threejs.state` at `blocked-g7-sr2`. That separation is intentional: implementation is
present, while runtime integration remains unauthorized until SR2D.

## TOCTOU guarantee and residual risk

The implementation narrows race windows through repeated canonicalization, ancestry checks, reparse
rejection, immediate pre-operation checks, same-directory atomic replacement, and post-write
verification. These checks stop static traversal and detectable link/reparse escapes and make a
late boundary change fail closed when observed.

It does **not** eliminate TOCTOU against a concurrent local attacker who can mutate filesystem
entries between a check and the subsequent path-based operation. PowerShell 5.1 and the selected
path APIs do not provide a complete handle-relative, no-follow chain for every directory creation,
open, replacement, and read used here. A stronger future implementation could use platform-specific
directory handles and no-follow/open-by-handle primitives, but that adds native complexity and is not
required by the accepted threat model for this gate.

## Synthetic verification

`tests/test-img2threejs-state-containment.ps1` covers default, nested and multi-level state; create,
read, write and update; operation-contract preservation; immediate mutation recheck; post-write
verification; traversal variants; absolute and foreign targets; prefix confusion; Windows path and
case forms; non-JSON targets; root and descendant reparse points; junction escape; symbolic-link
escape when the host permits creating one; and a nonexistent target below an outside-pointing
ancestor. The fixture and every outside target remain under a generated temporary test directory.

## SR2D dependencies

SR2D must:

- register only the explicit state operations and pass upstream only the canonical approved path;
- keep `init` create-only, `status` read-only, `mark` update-only, and classify `next` accurately
  when specification synchronization mutates state;
- call the guard again at the final launcher boundary rather than caching an earlier approval;
- integrate SR2B independently without moving its four schemas into this guard;
- run the complete adapter, packaging, security, and upstream compatibility regression;
- reassess G7S-002 before changing the finding from pending integration/revalidation.
