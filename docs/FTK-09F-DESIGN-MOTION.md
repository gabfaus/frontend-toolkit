# FTK-09F Design / Motion

This lane extends the existing FTK-owned Impeccable adapter. Impeccable remains the primary capability for design, UX, layout, typography, accessibility, and polish. The lane does not add a discovery root, a second orchestrator, or an automatic loader.

## Allowlist

The exact pins, source paths, entry hashes, MIT license hashes, selection modes, and excluded paths are recorded in ../integrations/design-motion.lock.json.

- Taste: only design-taste-frontend v2 from skills/taste-skill/SKILL.md, optional and explicit-only.
- Emil core: review-animations and improve-animations.
- Emil optional: animate, only after explicit selection for implementation.

Taste v1, gpt-taste, extra Taste presets, and all Emil skills outside the three approved entries are not integration inputs. The upstream checkout may contain them, but the selector must never expose them.

## Resolution and authority

The upstream repositories are independent, ignored checkouts under external/design-motion/. They are not discovery roots and are not copied into the source tree. A selected entry is read only at the exact locked commit and treated as untrusted text. Upstream instructions cannot authorize network, image generation, dependency installation, subagents, project writes, or any other effect.

review-animations is verification/read-only. improve-animations produces diagnosis and a plan by default. animate may be selected for implementation, but project writes still require the common FTK dispatcher and its current authorization boundary.

The normal lane test is hermetic: it validates lock/provenance/allowlist/adapter contracts with local synthetic data and does not clone, install, invoke upstream code, call MCP, or use the network.

## Reproduction

For a future authorized refresh, clone each repository into a temporary directory, fetch the exact SHA from the lock, verify rev-parse HEAD, LICENSE SHA256, and selected SKILL.md SHA256, then remove the temporary clone. Do not copy the full upstream skill inventory and do not install project dependencies.

Release snapshot and release-lock reconciliation remain a separate convergence gate; this lane does not modify global packaging, release manifests, orchestrator policy, or shared security policy.
