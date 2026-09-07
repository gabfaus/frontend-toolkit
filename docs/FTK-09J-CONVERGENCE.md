# FTK-09J — Common Convergence and Integration

Status: source-tree convergence candidate; common changes remain uncommitted for
review. No release, tag, push, marketplace update, or final release identity is
created by this gate.

## Architecture

The existing FTK-owned mediated-adapter architecture remains the source of
truth. invoke-capability.ps1 remains the common effect dispatcher. The
orchestrator adds a PLAN / EXECUTE / VERIFY boundary and emits the smallest
contextual load set; it does not load all capabilities at once.

PLAN selects one primary capability and only distinct conditional additions.
EXECUTE passes typed requested operations to the existing dispatcher and host
adapter. VERIFY is read-only by default and uses Playwright CLI,
ACCESSIBILITY_VERIFY, review-animations, conditional axe, and optional Chrome
DevTools diagnostics.

Unknown capabilities, tools, transports, effects, and future operations fail
closed. Request-only operations create envelopes with handlerInvoked=false and
externalCall=false; they do not call MCP, network, browser, upstream code, or
project writes.

## Capability decisions

- Impeccable remains the primary design/UX authority.
- Taste v2 is optional and explicit-only; image generation and installation are
  never automatic.
- review-animations is VERIFY/read-only.
- improve-animations is diagnosis plus planning.
- animate is explicit and project-write gated.
- FIGMA_READ is the default Figma-source capability.
- FIGMA_DESIGN_TO_CODE is explicit and starts from get_design_context.
- FIGMA_WRITE is manual authorization-required.
- Figma remote and Figma Desktop transports are separate and mutually exclusive.
- Browser QA uses the FTK Playwright wrapper; Playwright MCP is absent/rejected
  for this candidate.
- ACCESSIBILITY_VERIFY is CORE/read-only; ACCESSIBILITY_IMPLEMENT is conditional.
- Context7 is conditional and facade-only with resolve-library-id/query-docs.
- Storybook is conditional on an existing eligible project; installation,
  startup, remote review, publication, and Chromatic are blocked or gated.

## Supply chain exception

@playwright/cli@0.1.19 is accepted for source integration with restrictions.
The exact version, integrity, official source tag, Apache-2.0 license, missing
trusted-publisher/Sigstore provenance, effective alpha dependencies, and
microsoft/playwright#42500 OPEN status at validation remain recorded in
integrations/browser-qa.lock.json.

The npm tarball is not vendored, installation/download is not automatic, and
version replacement fails closed. Release acceptance remains
PENDING_FINAL_RELEASE_REVIEW; the final release gate must re-check issue status,
provenance, integrity, and effective dependencies.

## Hosts

Codex and Claude remain separate adapters. Capability IDs are canonical FTK
IDs; each host maps them to its own Skill/MCP/transport mechanism. No global user
configuration is modified. Normal plugin MCP configuration keeps only Shadcn
and 21st. Figma transports, Context7 facade, Browser QA and Storybook remain
conditional host/project selections rather than silent global activation.

## Validation boundary

All lane tests are hermetic. No real Figma, Context7, 21st, Storybook remote,
Chromatic, model, browser profile, or browser download is used by this gate.
The source-only Browser QA boundary remains outside the global plugin packaging
allowlist until a later packaging decision.
