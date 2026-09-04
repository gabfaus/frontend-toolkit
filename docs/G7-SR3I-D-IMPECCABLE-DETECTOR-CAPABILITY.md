# G7-SR3I-D3I - Canonical Static-HTML Runtime Integration

Status: **READY FOR HUMAN REVIEW - PRE-COMMIT**. The pinned Impeccable static-HTML engine now runs through the FTK-controlled canonical dependency root, closed module resolution, child-process permissions and governed project containment.

G7S-003 and G7S-004 remain **OPEN - IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**. This gate does not promote either finding.

## Audited upstream capability groups

| Group | Pinned upstream surface | FTK decision |
|---|---|---|
| Pure local analytics | canonical registry, findings, regex engine, rule checks, inline ignores, profiler | Reuse fixed modules after complete known-graph fingerprint validation. |
| Local filesystem reads | file/directory scan, static HTML and linked CSS, design-system data, config/ignores, import graph, static framework detection, CSP | FTK owns containment, traversal, schemas and limits. The pinned static-HTML rule/cascade graph runs through an FTK-owned canonical static-HTML runtime, but full parser/selector equivalence is covered by the D3I differential and adversarial runtime proof. CSP uses one FTK-owned bounded walker and a pure reproduction of pinned CSP classification. |
| Browser / loopback | browser `file://`, local dev-server detection and URL scan | Preserved as separately gated capability. No browser or loopback handler is started by local analytics. |
| External network | non-loopback URL detector | Preserved by `impeccable.detector.external`; endpoint-specific policy and non-forgeable host authorization remain required. |

The upstream CLI is not executed. It combines filesystem reads, dynamic parser/browser imports, port probing, raw stdin/process exit behavior and output formatting in one entrypoint. `impeccable-detector.mjs` is necessary to keep those authorities separate while retaining the real pinned registry and regex/rule implementation. Apache-2.0 attribution remains in the module header and repository notices; the upstream snapshot is unchanged.

## Canonical contract and handlers

`impeccable-operation-policy.json` ties the detector to Impeccable `skill-v4.1.2`, commit `63b04e2530f5c7b41ea83c133daab24f34912456`, canonical registry blob SHA-256 `4544ccca3d7c341d878b941fbe20620750dbf9d29dd6d15e063128a1e390b345`, the exact ordered 59-rule ID list, and 16 reviewed canonical Git blob OID/SHA-256 pairs. Runtime verification canonicalizes a CRLF checkout to committed LF bytes before calculating both identities; policy expectations never follow DevelopmentWorkingTree bytes.

| Operation | Input | Effect | Handler |
|---|---|---|---|
| `impeccable.detector.local` | canonical project root, one contained file, typed options | `LOCAL_READ_ONLY` | pinned rules over one file plus bounded linked local CSS |
| `impeccable.detector.project` | canonical project root, optional contained directory, typed options | `LOCAL_READ_ONLY` | deterministic bounded traversal, import graph and static framework detection |
| `impeccable.detector.payload` | bounded content, declared content type, typed options | `LOCAL_READ_ONLY` | stdin-equivalent pure content analysis with no path/directive authority |
| `impeccable.detector.csp` | canonical project root | `LOCAL_READ_ONLY` | one FTK-governed read path plus pure pinned-equivalent CSP classification |
| `impeccable.detector.browser-file` | canonical project root, contained HTML file, typed options | `LOCAL_READ_ONLY`, `PROJECT_CODE_EXECUTION` | represented but blocked until a non-forgeable host grant exists; handler is never started |

The result schema carries canonical rule ID, severity/classification, message, relative path/source, line, engine, scopes, advisory flag, suppression reason, import context, counts, result/resultCode, quiet metadata, engines executed, rules considered, optional profiler summary, viewport metadata, framework evidence, import-graph counts and skipped/mediated modes. Advisory-only results have `resultCode: 0`; primary findings use `2`, matching upstream automation semantics without delegating raw process control.

## Local data and safety limits

Project config remains data. The boundary reads only `.impeccable/config.json` and `.impeccable/config.local.json`, applies legacy `hook` detector fields first and `detector` fields second, so detector values override overlapping `designSystem` and `advisoryRules` exactly as upstream does. Ignore rule/file/value semantics are preserved and configuration never grants effects.

FTK safety limits are not presented as upstream capability definitions: 1 MiB per detector content/file, 2 MiB request, 8 MiB total, 200 files, depth 12, 64 KiB config, 256 KiB design data, and 100 bounded ignore patterns. CSP has one actual read path with the exact upstream extension set, deterministic traversal, depth 6, 64 KiB per file, 8 MiB total and 200 files. All paths use segment-safe containment, real paths and reparse rejection.

Project-mode duplicate behavior follows upstream: linked CSS findings are attributed to the HTML source and a separately scanned CSS file is attributed to its own path. Those are legitimate distinct findings. The contract prevents an accidental duplicate of the same representative CSS rule within one path; DOM checks may legitimately emit one same-text finding per matching element.

The child uses locked Node 24.20.0, structural argv, fixed boundary/policy/upstream roots, UTF-8 stdin JSON, a fresh six-name environment, forced update/telemetry opt-outs and Node permission mode. It receives read permission only; network, filesystem writes, child process, worker and project-code execution are not granted. A config file containing executable JavaScript is scanned as text and never imported.

## Capability matrix

| Capability | Classification | Evidence |
|---|---|---|
| File scan | MEDIATED | canonical pinned analytics through `detector.local` |
| Project scan | MEDIATED | deterministic traversal and aggregate result |
| Payload/stdin | MEDIATED | typed bounded content, no path authority |
| HTML/CSS | MEDIATED | HTML DOM plus contained linked/local CSS |
| Regex/static engine | PRESERVED | fingerprinted upstream `detect-text.mjs` and rule graph |
| Static HTML full engine | MEDIATED | pinned detect-html plus htmlparser2/css-select/css-tree/domutils from the closed 13-package root; FTK owns containment, typed output and effects
| Browser file | PRESERVED BUT AUTHORIZATION-BLOCKED | typed `impeccable.detector.browser-file`; browser/page code handler never starts without host authorization |
| Loopback | PRESERVED BUT AUTHORIZATION-BLOCKED | `impeccable.detector.loopback`, `LOOPBACK_EPHEMERAL` |
| External URL | PRESERVED BUT AUTHORIZATION-BLOCKED | `impeccable.detector.external`, destination policy required |
| Framework detection | MEDIATED | static config recognition; port probe split to loopback |
| Import graph | MEDIATED | contained import, CSS `@import`, Sass `@use` and `@forward` graph |
| DESIGN/design-system | MEDIATED | contained reads plus upstream parser/normalizer |
| Config/ignores | MEDIATED | upstream precedence and file/rule/value/inline suppression |
| Scopes | PRESERVED | canonical `type`/`layout` registry scopes |
| Viewport | PRESERVED BUT AUTHORIZATION-BLOCKED | viewport changes the browser-file analytical contract; pure local analytics reports it as browser-only |
| Structured/quiet/advisory/result | MEDIATED | typed schema and upstream-compatible result code semantics |
| Profiler/report | PRESERVED | pinned profiler with sanitized relative targets |
| CSP | MEDIATED | single governed read path with preserved CSP classification semantics |

## D3I canonical runtime evidence

The active path is plugin/frontend-toolkit/security/impeccable-static-runtime.mjs, a thin FTK-owned loader. It resolves bare packages only from third_party/runtimes/impeccable-static-html/node_modules in source and from the explicitly copied third_party/static-html-dependencies/node_modules in an ephemeral artifact. It honors only reviewed package exports/entrypoints and rejects ambient, project-local, parent, sibling, NODE_PATH and reparse-based resolution.

tests/test-impeccable-static-html-runtime.ps1 proves the exact 13-package loaded graph, actual HTML DOM and selector/cascade execution, contained linked CSS, typed runtime evidence, no write/network/project-code effect, parent-secret isolation, traversal rejection, module-shadowing resistance and the packaged candidate path. source-map-js/lib/source-map-generator.js is observed; lib/quick-sort.js is neither loaded nor evaluated. The source snapshot remains the single provenance source; the builder copies it by explicit file inventory and checks count, bytes, tree hash and all 13 license files.

This capability is MEDIATED, not because analytical semantics are replaced, but because FTK mediates the input paths, dependency resolution, process, output and effects around the unmodified pinned analytical engine. The old reduced parser/selector/CSS implementation was removed from the active module; canonical initialization failure is fail-closed and cannot silently select a compatibility fallback.
## Validation and release governance

`test-impeccable-detector-capability.ps1` independently reads all 16 pinned Git blobs and proves canonical SHA-256/OID equality while a `core.autocrlf=true` CRLF checkout has different raw hashes. It also proves representative DOM/cascade/contrast behavior, browser-file authorization blocking, CSS/Sass graph forms, ignoreValues, layout scope, honest viewport applicability, containment edge cases, every CSP resource guard, config precedence, engine-family accuracy and upstream-compatible duplicate behavior. The D3I corpus exercises representative HTML structure, selectors, CSS cascade/computed behavior, contrast and containment while the runtime reports the actual loaded package graph; this is the candidate capability proof, with committed-HEAD revalidation still separate.

The module is named literally in source/distribution security allowlists and inventory assertions. No wildcard was added. `integrations/distribution.lock.json` and `integrations/release.lock.json` remain unchanged; DevelopmentWorkingTree hashes are diagnostic only. Committed-HEAD reconciliation remains a separate human-authorized post-commit gate.
