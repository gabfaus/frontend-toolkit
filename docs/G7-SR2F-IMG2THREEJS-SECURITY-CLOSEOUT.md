# G7-SR2F — img2threejs Security Closeout & Lessons Learned

Status: **READY FOR HUMAN REVIEW** on 2026-09-01.

## Final finding status

G7-SR2E reproduced two identical candidates exclusively from committed HEAD
`09b07747067acab3c96045baf98e9b0aed0cce15`:

- plugin tree: `669d11cfd754cc0656c810669ec2a662e253898debe2eab63981e19b2b75c3a4`;
- artifact payload: `efcf45ca29616d311a44499c21f65812c0ae60d07e074a7ecf873477dc97df01`.

Human review approved the technical mitigation for closure. The complete lifecycle is preserved:

| Finding | Lifecycle | Current status |
|---|---|---|
| G7S-001 | `OPEN -> IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION -> MITIGATED -> HUMAN REVIEW -> CLOSED` | **CLOSED** |
| G7S-002 | `OPEN -> IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION -> MITIGATED -> HUMAN REVIEW -> CLOSED` | **CLOSED** |

The preserved upstream defects remain byte-identical and non-discoverable. Closure rests on the
FTK-owned enforced boundary, not on a claim that upstream was rewritten. Detectable state escapes
are blocked; TOCTOU against a concurrent local attacker remains a documented residual risk.
The adapters' `As of G7-SR2D` status sentence remains a historical checkpoint and is intentionally
unchanged so this documentation-only gate does not change the release payload or its locked hashes.

## G7-SR3 handoff

- **G7S-003 — OPEN:** authority/instruction conflict.
- **G7S-004 — OPEN:** network, telemetry, paid generation, and update effects.

G7-SR3 must reuse the mediated-adapter architecture and the constraints in
[Security Remediation Lessons](SECURITY-REMEDIATION-LESSONS.md). This closeout does not authorize
SR3 implementation, release, publication, staging, commit, push, remote, or tag creation.
