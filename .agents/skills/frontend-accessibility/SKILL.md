---
name: frontend-accessibility
description: Verify frontend accessibility through a read-only WCAG 2.2 evidence contract, with conditional implementation and optional axe support.
---

# Frontend Accessibility

This FTK-owned Skill separates evidence collection from code changes.

## ACCESSIBILITY_VERIFY — CORE

Use `integrations/browser-qa/accessibility-verify.mjs` in read-only mode. It
accepts a bounded observation JSON and emits one of `PASS`, `FAIL`,
`INCOMPLETE`, or `UNKNOWN` without changing source code or writing a report.
Missing evidence is `INCOMPLETE`; contradictory or malformed evidence fails
closed. Non-deterministic checks remain `UNKNOWN` until a manual or LLM review
records its decision.

The evidence contract covers:

- WCAG 2.2 coverage;
- semantic HTML, landmarks, and heading structure;
- keyboard flow and focus visibility/management;
- forms, labels, validation, and error recovery;
- ARIA roles, states, properties, and relationships;
- text contrast and non-text contrast;
- zoom, reflow, and responsive content order;
- `prefers-reduced-motion` and motion accessibility; and
- screen-reader reasoning and meaningful content.

An axe result is supplementary evidence only. The conditional adapter checks
for an already-installed `@axe-core/playwright@4.13.0` and compatible
Playwright; it never installs, executes a scan, or modifies the project.

## ACCESSIBILITY_IMPLEMENT — CONDITIONAL

Implementation is a conditional capability, not the default route. It requires
explicit current authorization for the named project files and must be followed
by `ACCESSIBILITY_VERIFY`. Do not infer write authority from a failed check,
from axe findings, from a browser session, or from this Skill.

Prefer semantic HTML and native controls before adding ARIA. Preserve keyboard
operation, visible focus, error associations, content meaning, zoom/reflow, and
motion preferences. If a design choice is inherently subjective, return
`UNKNOWN` and request manual review instead of manufacturing a pass.

The optional Chrome DevTools policy is configuration-only and does not start
Chrome or register an MCP. Its defaults deny existing-browser attach,
extensions, PWA mutation, third-party/WebMCP tools, arbitrary JavaScript,
CrUX, telemetry, memory debugging, uncontrolled filesystem access, and
unapproved external traffic.
