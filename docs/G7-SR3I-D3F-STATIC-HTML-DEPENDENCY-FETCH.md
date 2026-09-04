# G7-SR3I-D3F — Canonical Static-HTML Dependency Fetch & Audit

Status: **READY FOR HUMAN REVIEW — PRE-COMMIT SUBSTRATE ONLY**.

This gate used the explicit narrow network grant only for exact-version metadata and tarballs from `https://registry.npmjs.org/`. It did not install dependencies, run package or lifecycle code, contact GitHub/search engines, use credentials, alter a user cache, or integrate the result into the active detector. G7S-003 and G7S-004 remain **OPEN — IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**.

## Canonical identity and integrity

The 13 approved versions and their SHA-512 SRI values match the pinned `external/impeccable/bun.lock` blob `437713e65217d1e69d00120f9331b2a63ebbba95` at Impeccable commit `63b04e2530f5c7b41ea83c133daab24f34912456`. Registry SRI matched downloaded SHA-512 for every tarball; SHA-256 and npm `shasum` are recorded in `integrations/impeccable-static-html-dependencies.lock.json`.

| Package | Tarball SHA-256 | License | Redistribution evidence |
|---|---|---|---|
| `htmlparser2@12.0.0` | `bd21df686ef9b29b6786aac9aa75a9d20e1e884ad3f3089882db1d576dd4aaa0` | MIT | COMPLETE — `LICENSE`, Chris Winberry |
| `css-select@7.0.0` | `7c35ad92211a399ed536174c12ede417bc8b96100895cad78be9010e9c84419f` | BSD-2-Clause | COMPLETE — `LICENSE`, Felix Böhm |
| `css-tree@3.2.1` | `4c06bfe733d006103a4c070dcf8e0a3b2eb6b6a83e20e21c32d2d3b9c3ffae0a` | MIT | COMPLETE — `LICENSE`, Roman Dvornov |
| `domutils@4.0.2` | `64922a8f80c4c31a0d146e563ba054de86453c0d78e50fba66e4e8c8462a95ac` | BSD-2-Clause | COMPLETE — `LICENSE`, Felix Böhm |
| `boolbase@2.0.0` | `9c8433ec18090ee5b75246976b368169aa7af7685626fdb41deaffdbe683fb92` | ISC | COMPLETE — `LICENSE`, Felix Boehm |
| `css-what@8.0.0` | `1eccce8f4d523832253a082815495f823b8621d0aab6a2eea5853d0d37eb4417` | BSD-2-Clause | COMPLETE — `LICENSE`, Felix Böhm |
| `dom-serializer@3.1.1` | `12272f96b8a76363d78b67d7695b73410f339171f56a6cc5793cb4bfc6b15aa0` | MIT | COMPLETE — `LICENSE`, Cheerio contributors |
| `domelementtype@3.0.0` | `078a496be3f33f3268f6749b3a5d45629f4b98beca1e53e3ef6d1ba2040811d5` | BSD-2-Clause | COMPLETE — `LICENSE`, Felix Böhm |
| `domhandler@6.0.1` | `c42bd0d96c5a10ebcfd938fa1fd97db12b9f592a485fb75d9aba5fa66e66d93b` | BSD-2-Clause | COMPLETE — `LICENSE`, Felix Böhm |
| `entities@8.0.0` | `8e8b16388e19c12fc80f9f75f518a0f83d99428be6765a38f04c264a078cc25b` | BSD-2-Clause | COMPLETE — `LICENSE`, Felix Böhm |
| `mdn-data@2.27.1` | `63985bd4ce64e9a0142d70465c3a7f54c488f3ef6da3f9512d54a728cde46870` | CC0-1.0 | COMPLETE — full `LICENSE` waiver/public-license fallback |
| `nth-check@3.0.1` | `db23d012df85d2c0308c7b3fd3bd538664d9e0e1dca1aa96e659641b76457a8f` | BSD-2-Clause | COMPLETE — `LICENSE`, Felix Böhm |
| `source-map-js@1.2.1` | `f126a6f9fca487a43219d8cb8c3a955279187a966119d548eb5cd47e999d4853` | BSD-3-Clause | COMPLETE — `LICENSE`, Mozilla Foundation and contributors |

All archives used one `package/` root and regular files only. No absolute, traversal, drive-qualified or backslash paths; symlinks, hardlinks, devices and special files were absent.

## Runtime graph and install audit

The exact mandatory manifest edges close inside the snapshot:

- `htmlparser2` → `domelementtype`, `domhandler`, `domutils`, `entities`
- `css-select` → `boolbase`, `css-what`, `domhandler`, `domutils`, `nth-check`
- `css-tree` → `mdn-data`, `source-map-js`
- `domutils` → `dom-serializer`, `domelementtype`, `domhandler`
- `dom-serializer` → `domelementtype`, `domhandler`, `entities`
- `domhandler` → `domelementtype`
- `nth-check` → `boolbase`

The other six packages have no mandatory runtime edge. No manifest declares optional, peer or bundled dependencies, binary entrypoints, `gypfile`, or `preinstall`/`install`/`postinstall`. `boolbase`, `domelementtype`, `dom-serializer` and `nth-check` declare `prepare`, but their required `dist/` output is already present in the canonical tarballs; no build/install step is required or executed.

## Static security audit

The pinned engine dynamically imports the four package roots `htmlparser2`, `css-select`, `css-tree` and `domutils`. Static import closure over the canonical bytes found no reachable external network, telemetry, update check, subprocess/shell, filesystem write, environment/secret access, native addon, HOME/profile dependency, arbitrary dynamic import or project-code execution.

`source-map-js/lib/quick-sort.js` contains `new Function`, but it is outside the reachable closure: `css-tree/lib/generator/sourceMap.js` imports `source-map-js/lib/source-map-generator.js` directly, and that subgraph does not import the consumer/quick-sort implementation. This unreachable utility is retained because safe pruning of canonical package contents was not proven.

## Snapshot and evidence

The complete canonical tarball contents are preserved at `third_party/runtimes/impeccable-static-html/node_modules`: 13 packages, 601 files, 3,696,727 bytes, tree SHA-256 `5f537671feab493afc06129128ba2e116a12368f916c8ec1b40032e8130c499d`. This location is outside `.agents/skills` and `plugin/frontend-toolkit/skills`; it is not a Skill.

The dedicated lock records registry metadata, exact identities, both integrity sources, tarball hashes, canonical tree hashes, license file hashes, relationship and dependency edges. `tests/test-impeccable-static-html-dependencies.ps1` proves exact inventory, closed local graph, hashes/licenses, absence of reparse or nested resolution roots, no active detector wiring and byte-identical pinned Impeccable snapshot evidence.

Network closeout: 26 HTTP requests (13 exact-version metadata + 13 exact tarballs), only `registry.npmjs.org`, HTTPS, zero redirects, no credentials and no other host. Temporary metadata, extraction roots and tarballs are deleted after validation. `integrations/distribution.lock.json` and `integrations/release.lock.json` remain unchanged.

## Next gate

No capability is promoted here. A separately authorized integration gate must wire the canonical engine to this closed module root, preserve the FTK authority boundary, prove no project/user/global resolution, run a differential static-HTML corpus plus security tests, and only then reconsider `Static HTML Full Engine — PRESERVED`. Committed-HEAD revalidation and any release-lock reconciliation remain later human gates.
