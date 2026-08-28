# Routing and workflows

## Decision order

1. Honor explicit user selection, exclusion, and authorization boundaries.
2. Classify the primary intent: design/UX, official component, inspiration/discovery, or 3D.
3. Select the single best capability first.
4. Add another capability only when it supplies a distinct necessary result.
5. Place an authorization gate immediately before any costly, quota-consuming, mutating, or uncertain action.

## Shadcn and 21st

Prefer Shadcn when the user wants a standard component, an official registry answer, direct implementation support, or consistency. Consult 21st only for requested inspiration, meaningful alternatives, or references beyond the official registry. Never query 21st merely because it is available.

Shadcn being unavailable does not make 21st an automatic substitute: explain the difference before using an alternative. 21st being unavailable should not block work that Impeccable and Shadcn can complete.

## Common workflows

### New interface

Use Impeccable for direction when visual/UX decisions are needed, Shadcn for official components, and 21st search only if additional inspiration has clear value. Implement with Codex, then use Impeccable for final review when polish is in scope. Skip unnecessary phases.

### Existing interface

Start with Impeccable for critique or audit. Add Shadcn only for concrete component/pattern replacements. Add 21st search only for explicitly useful alternatives or inspiration.

### Interface with 3D

Use img2threejs for the 3D asset or scene work, Impeccable for visual/UX integration when needed, and Shadcn for surrounding controls. 21st remains optional and search-only by default.

## Fallbacks

- If Impeccable is unavailable, perform only analysis that remains within ordinary Codex capability and disclose the missing specialized review.
- If Shadcn is unavailable, do not present 21st as an official-registry equivalent.
- If 21st is unavailable, continue without inspiration search when the remaining capabilities suffice.
- If img2threejs is unavailable, do not claim that 3D reconstruction or validation occurred.
