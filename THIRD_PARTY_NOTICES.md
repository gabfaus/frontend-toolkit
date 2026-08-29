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

## Shadcn

Shadcn CLI/MCP 4.19.0 is MIT-licensed and resolved at runtime through the pinned `shadcn@4.19.0` command. Its code is not incorporated into the plugin snapshot.

## 21st

21st is used only as the remote MCP service at `https://21st.dev/api/mcp`. No 21st plugin, Skill or service source code is incorporated. Authentication is supplied externally through the environment variable name `API_KEY_21ST`.

See `integrations/external.lock.json`, `integrations/mcp.lock.json`, `plugin/frontend-toolkit/external-skills.lock.json` and generated `SNAPSHOT_PROVENANCE.json` for reproducible provenance.
