# Browser QA boundary

This directory contains the FTK-09H source-only Browser QA boundary. It is
intentionally outside the global plugin packaging allowlist for this gate.
The normal plugin MCP configuration is unchanged and therefore contains no
Playwright MCP or Chrome DevTools MCP.

The Playwright route is a CORE capability for selected browser-verification
workflows, not a default-loaded surface. Its PowerShell launcher
accepts a typed action set, and `browser-session-provider.ps1` accepts a typed
transaction for one shared session. Both routes run a resolved
`playwright-cli` package-owned entry through `ProcessStartInfo`, clear the
child environment, apply the exact CLI's explicit `--no-headed` headless
control, restrict URLs to loopback,
use an OS-temporary session root, bound process output/time, and refuse
automatic package/browser installation. `-PlanOnly` is the safe way to inspect
the command boundary.

The transaction sequence is bounded to:
`session.open`, `navigate`, `viewport.resize`, `capture.dom`, `capture.ax`,
`capture.screenshot`, `capture.requests`, typed `interaction`, and
`session.close`. It returns a `BrowserEvidenceBundle` with bounded structured
DOM/AX snapshots, artifact hashes, request summaries, and keyboard/focus
observations. The accessibility verifier consumes this same bundle; it does
not run a second browser session.

The process runner reuses the canonical 03D execution envelope and taxonomy:
`INVALID_INPUT`, `DEPENDENCY_OR_RUNTIME_FAILURE`, `UPSTREAM_EXECUTION_FAILURE`,
`OUTPUT_CONTRACT_FAILURE`, `TIMEOUT`, and `UNKNOWN_FAILURE`. `childStarted` is
the process state; `browserReady` and `sessionReady` are separate evidence
states. Job Object cleanup is reported truthfully as bounded cleanup with a
start/assignment race limitation, never as an absolute guarantee.

`frontend-accessibility` provides a read-only evidence verifier. It does not
pretend that an axe scan proves keyboard flow, focus, semantics, content,
reflow, screen-reader behavior, or motion accessibility. Implementation is
conditional and always requires a subsequent verify pass.

## Playwright CLI supply-chain freeze

The Browser QA pin is `@playwright/cli@0.1.19`. Its upstream repository, source
tag, tarball integrity and Apache-2.0 license were confirmed and are recorded
in `integrations/browser-qa.lock.json`. Public trusted-publisher provenance and
Sigstore/SLSA provenance are `ABSENT` for this release; the corresponding
upstream issue is [microsoft/playwright#42500](https://github.com/microsoft/playwright/issues/42500),
whose status was `OPEN` at validation. No evidence of tampering was observed or
reported. Release acceptance requires an explicit convergence/release
decision.

The effective CLI runtime remains visible and is not normalized: it includes
`playwright@1.63.0-alpha-2026-08-31` and
`playwright-core@1.63.0-alpha-2026-08-31`.

The Chrome DevTools adapter is optional configuration plus a tool/origin
allowlist. It does not start Chrome, attach to an existing browser, or register
an MCP. The exact package metadata and update procedure are in
`integrations/browser-qa.lock.json`.

The lock records the Chromium revision and browser build exposed by the exact
Playwright runtime. Secure dedicated real-browser evidence remains
`PENDING_ENVIRONMENT`; when prepared, it records the environment-specific
executable hash, which is not a portable source-tree artifact.
