# Browser QA boundary

This directory contains the FTK-09H source-only Browser QA boundary. It is
intentionally outside the global plugin packaging allowlist for this gate.
The normal plugin MCP configuration is unchanged and therefore contains no
Playwright MCP or Chrome DevTools MCP.

The Playwright route is the default CORE capability. Its PowerShell launcher
accepts a typed action set, runs a resolved `playwright-cli` executable through
`ProcessStartInfo`, clears the child environment, restricts URLs to loopback,
uses an OS-temporary session root, and refuses automatic package/browser
installation. `-PlanOnly` is the safe way to inspect the command boundary.

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
