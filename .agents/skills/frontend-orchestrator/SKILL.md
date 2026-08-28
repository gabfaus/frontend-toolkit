---
name: frontend-orchestrator
description: Route frontend, UX, component, and Three.js requests among Impeccable, Shadcn, 21st, and img2threejs using the minimum necessary capabilities and approval gates for costly or mutating actions. Use when choosing or sequencing Frontend Toolkit capabilities matters; do not use for unrelated technical work.
metadata:
  short-description: Route frontend capabilities safely
---

# Frontend Orchestrator

Choose the smallest set of Frontend Toolkit capabilities that can satisfy the user's actual intent. Do not invoke every capability by default, and do not treat tool availability as a reason to use it.

## Route by primary intent

- Use Impeccable for design direction, UX, visual critique, hierarchy, layout, typography, responsive review, and polish.
- Use Shadcn for official components, canonical registry patterns, examples, and implementation support. Prefer it over 21st for common components such as buttons, dialogs, forms, inputs, dropdowns, tables, sheets, and tabs.
- Use 21st for discovery, alternatives, and visual inspiration when those add concrete value. The default authorized operation is only a currently verified free/read-only `search` equivalent.
- Use img2threejs only for explicit or clearly implied 3D, Three.js, image-to-model, procedural reconstruction, asset, or scene work.

The user's explicit routing and exclusions take precedence. For ambiguous requests such as “melhore esta tela”, start with Impeccable and add another capability only after identifying a concrete need.

## Apply safety gates

Before any 21st operation other than a currently verified free/read-only search, read [cost-policy.md](references/cost-policy.md). Require explicit user authorization immediately before any metered, quota-consuming, mutating, publishing, account-changing, or uncertain operation. If current metadata leaves cost or effect unclear, do not call the tool.

Do not install the 21st plugin or Skills, Magic MCP, Jpisnice, or another routing Skill. Do not activate hooks. This Skill coordinates the four existing capabilities without duplicating their upstream instructions.

## Combine only when useful

For multi-capability or ambiguous frontend work, read [routing.md](references/routing.md). Preserve source attribution and order capabilities deliberately. A possible workflow is not a mandatory pipeline.

If a capability is unavailable, do not silently replace it with a semantically different one. Continue only with a genuinely equivalent safe path; otherwise report the limitation.

The machine-readable contract is [routing-policy.json](references/routing-policy.json). Use [scenarios.json](references/scenarios.json) as examples when interpreting ambiguous requests or validating policy changes. Do not treat the scenario wording as an exhaustive prompt list.
