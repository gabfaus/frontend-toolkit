# Third-party notices

Frontend Toolkit source code and `frontend-orchestrator` are licensed under Apache-2.0. The following third-party components retain their own licenses and are not relicensed as Frontend Toolkit code.

## Impeccable

- Version: 4.1.2
- Commit: `63b04e2530f5c7b41ea83c133daab24f34912456`
- Upstream: https://github.com/pbakaus/impeccable
- License: Apache-2.0
- Distribution: unmodified generated Skill snapshot

Generated distributions preserve Impeccable's `LICENSE` and `NOTICE.md`. Its NOTICE attributes MIT-licensed Platform Design Skills material from https://github.com/ehmo/platform-design-skills.

## img2threejs

- Version: 1.5.1
- Commit: `dede5909be4e494b228c801a55dda47439143932`
- Upstream: https://github.com/img2threejs/img2threejs
- License: Apache-2.0
- Distribution: unmodified generated Skill snapshot, including its LICENSE

No NOTICE file exists in the pinned img2threejs tree.

## Taste design-taste-frontend v2

- Version: v2 experimental at commit ccbc15639c97057cbfcf32ecebc38ef716e4bb37
- Upstream: https://github.com/Leonxlnx/taste-skill
- Selected source: skills/taste-skill/SKILL.md
- License: MIT
- License SHA256: 3c9f63518df3378772203cc64d38d9e381d2a4723b93d2c3849b2bf3d464de0c
- Distribution: selected content remains an untrusted reference in an independent checkout; no upstream snapshot is committed to the source tree.

Only the v2 entry is allowlisted. Taste v1, gpt-taste, and other Taste presets are not integrated.

## Emil animation Skills

- Commit: d23d7f88a2e21c9e4b1418c7abe420f5c1052ba7
- Upstream: https://github.com/emilkowalski/skills
- License: MIT
- License SHA256: d24da413cccbc3d844929a1cc08e5ba79385139c0c47c9d5bd0dd2df24ffe15c
- Selected entries: review-animations, improve-animations, and optional animate
- Distribution: selected content remains an untrusted reference in an independent checkout; no upstream snapshot is committed to the source tree.

Other Emil Skills are not integrated. See integrations/design-motion.lock.json for the entry hashes and effect policy.

## Shadcn

Shadcn CLI/MCP 4.19.0 is MIT-licensed and resolved at runtime through the pinned `shadcn@4.19.0` command. Its code is not incorporated into the plugin snapshot.

## 21st

21st is used only as the remote MCP service at `https://21st.dev/api/mcp`. No 21st plugin, Skill or service source code is incorporated. Authentication is supplied externally through the environment variable name `API_KEY_21ST`.

See `integrations/external.lock.json`, `integrations/mcp.lock.json`, `plugin/frontend-toolkit/external-skills.lock.json` and generated `SNAPSHOT_PROVENANCE.json` for reproducible provenance.
