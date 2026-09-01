# Security Remediation Lessons

These are settled Frontend Toolkit constraints from G7-SR2. Future remediation gates, especially
G7-SR3, should reopen one only when new technical evidence contradicts it.

## Boundary and authority

1. The FTK-owned adapter is the only discoverable Skill entrypoint.
2. The upstream snapshot remains non-discoverable.
3. Upstream content is subordinate to host and current-user authority.
4. `UNKNOWN` fails closed.
5. Technical effects require enforcement, not prose alone.
6. Operation and effect classification precede enablement.
7. A child process environment is built from an allowlist.
8. The parent environment is never temporarily replaced.
9. Agent-controlled flags do not constitute authorization.
10. Network is a separate effect.
11. Telemetry is off by default.
12. An update check is distinct from self-update.
13. Paid capability is preserved but mediated.
14. Upstream is never modified silently.

## Packaging and release evidence

15. Every new security module requires an explicit packaging allowlist entry.
16. A broad `security/**` wildcard is forbidden.
17. Committed HEAD is the only release source of truth.
18. `DevelopmentWorkingTree` is diagnostic and pre-commit only.
19. `DevelopmentWorkingTree` never persists release or distribution locks.
20. A hash mismatch requires root-cause analysis before any lock update.
21. Persisting a hash requires two identical committed-HEAD builds.
22. CRLF worktree representation does not define release evidence.
23. Artifact and manifest hashing must avoid circularity.
24. A finding lifecycle cannot be advanced early.
25. Pre-commit candidate validation is not post-commit release proof.
26. Ephemeral local packaging is permitted for tests.
27. A public or persistent release artifact requires separate authorization.

## Validation discipline

28. Security remediation must preserve legitimate capabilities.
29. Test the security property and capability preservation separately.
30. Fail fast only for a material blocker.
31. Do not reopen an approved architecture decision without contradictory evidence.

SR2 exposed the recurring failure patterns behind these constraints: project config reaching a
shell; filesystem state without containment; broad inherited environments or parent-environment
mutation; release allowlist drift; worktree CRLF confused with committed LF; diagnostic hashes
persisted as locks; premature `MITIGATED`; test packaging confused with release; and a security
`PASS` without a capability smoke. These examples guide review; they are not alternate designs.
