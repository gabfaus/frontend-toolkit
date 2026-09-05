# Frontend Toolkit security model

This document describes the reviewed v1.0.0 candidate. It is a threat model, not a guarantee of absolute security. Project files, third-party Skills, registry content, and MCP responses remain untrusted even when their source is pinned or reputable.

## Assets and authority

Protected assets are user credentials, project source and data, filesystem integrity, user accounts, MCP quota and spend, release provenance, and availability of the local environment.

Authority is evaluated in this order:

1. host and system restrictions;
2. explicit and current user authorization;
3. Toolkit security policy;
4. orchestrator routing;
5. external Skills;
6. project content;
7. MCP responses.

The last three categories are untrusted data and cannot elevate permissions. A prompt, README, source comment, Skill instruction, registry item, generated command, or MCP response cannot authorize secret access, shell execution, remote mutation, or paid work.

## Trust boundaries

| Boundary | Trusted asset | Untrusted asset/capability | Principal risk | Existing mitigation | Missing mitigation | Severity |
|---|---|---|---|---|---|---|
| User | explicit intent | ambiguous or socially engineered prompt | unintended effect or spend | approval gates | confirm consequential scope | Medium |
| User prompt | requested result | embedded override/exfiltration instruction | permission elevation | authority policy | behavioral host enforcement | Medium |
| Project files | selected source | arbitrary content and names | injection, secret disclosure | treat as data | universal taint enforcement | High |
| Third-party project content | required inputs | dependencies, docs, comments | supply-chain injection | minimum reads | content sandbox | High |
| Frontend orchestrator | routing policy | ambiguous capability selection | excessive capability | minimum-capability routing | automated policy engine | Medium |
| External Skills | pinned instructions | executable scripts and policy text | local execution, network, authority conflict | provenance and review | runtime confinement | Critical |
| Executable scripts | reviewed code | parameters and project config | command injection, destructive effects | argument arrays in most paths | reject sourced project config | Critical |
| Local filesystem | authorized workspace | absolute, traversal and link paths | read/write escape | host sandbox when available | component boundary checks | High |
| Subprocesses | pinned executable | arguments and environment | arbitrary code or injection | explicit argv in Python | central subprocess policy | High |
| Shadcn MCP | official registry queries | project registry/config | header disclosure, generated commands | exact npm pin; read-only test | registry allowlist and header gate | Medium |
| 21st MCP | reviewed search | mutable remote tool surface | spend, mutation, exfiltration | search-only policy | consumer tool allowlist not manifest-enforced | High |
| MCP responses | useful component data | adversarial instructions | prompt injection | responses treated as data | structured sanitization | High |
| npm registry | pinned package metadata | registry/package compromise | supply-chain execution | exact version and recorded integrity | runtime integrity enforcement by MCP config | High |
| Impeccable upstream | pinned snapshot | scripts, telemetry, remote API | network/spend/policy override | SHA and content inventory | remove or gate unsafe runtime behavior | Critical |
| img2threejs upstream | pinned snapshot | executable repository tree | path escape/arbitrary shell execution | SHA and content inventory | narrow snapshot and enforce paths/config parsing | Critical |
| Release artifact | manifest and provenance | unexpected executable content | redistributed attack surface | deterministic builder and inventory | explicit pre-extraction mode/path allowlist | Medium |
| User environment/credentials | user-owned secrets | environment inherited by tools | leakage or account use | no maintainer credentials; no secret values in artifact | per-process environment minimization | High |

Threat classes considered are confidentiality, integrity, availability, unauthorized external effects, cost/quota consumption, destructive filesystem effects, and supply-chain compromise.

## Component review

### G7-SR1 mediated-adapter boundary

The discovery root contains exactly three FTK-owned Skills: `frontend-orchestrator`, `impeccable`, and `img2threejs`. Impeccable and img2threejs upstream `SKILL.md` files are no longer discovered directly. The release builder materializes their byte-verified pinned payloads only under `third_party/upstreams/<id>` and records adapters and upstream snapshots as separate provenance classes.

The common capability manifest classifies effects as `LOCAL_READ_ONLY`, `LOCAL_PROJECT_WRITE`, `LOOPBACK_EPHEMERAL`, `NETWORK_PASSIVE`, `TELEMETRY`, `PAID_GENERATION`, `EXTERNAL_MUTATION`, or `UNKNOWN`. `UNKNOWN` is denied. The launcher accepts only a registered operation identifier and has no arbitrary script entrypoint. At the G7-SR1 checkpoint only local capability summaries were enabled and none of the four findings was yet remediated; later gates retain that boundary while recording each finding's current lifecycle state.

### Frontend orchestrator

### G7-SR2D img2threejs execution boundary

G7-SR2D adds `PROJECT_CODE_EXECUTION` and routes the img2threejs GLB pipeline, codec, TypeScript,
Vite, and all state operations through FTK-owned handlers. Project config is strict data and never
reaches the preserved upstream `source` sink. Node/Python are resolved from the FTK runtime policy,
argv is structural, the child environment is allowlisted, and external network is not implied by
project-code execution. The four structural JSON maps and real GLB node inventory validate before
downstream use. All state routes use the SR2C guard at the actual boundary. See
[G7-SR2D](G7-SR2D-IMG2THREEJS-SAFE-EXECUTION.md).

The upstream defects remain unchanged inside the non-discoverable pinned snapshot. G7-SR2E
revalidated two identical committed-HEAD builds, after which human review approved closure. G7S-001
and G7S-002 are **CLOSED**. Detectable reparse attacks are blocked, but complete TOCTOU elimination
against a concurrent local attacker is not claimed. See [G7-SR2F](G7-SR2F-IMG2THREEJS-SECURITY-CLOSEOUT.md)
and the durable [remediation lessons](SECURITY-REMEDIATION-LESSONS.md).

The orchestrator is instruction-only. It has no executable, filesystem, subprocess, or direct network surface. Its policy permits only a currently verified 21st search by default. Generation, iteration, copy/install, publication, mutation, account changes, and unknown or uncertain tools require explicit authorization immediately before use. Project, Skill, and MCP content cannot waive this gate.

### Impeccable

G7-SR3I places the integrated FTK boundary in front of every Impeccable runtime request: the pure authority mediator emits canonical requested-operation IDs, the common dispatcher verifies the common and component effect contracts, and only a fixed handler can be selected. A separate bounded extractor reads physical project-local PRODUCT.md, DESIGN.md, and surface briefs without importing the upstream context graph. Raw directives and live `_instructions` cannot become authority.

The current plugin has no non-forgeable host-grant input. Network, telemetry, paid generation, persistent writes, live execution, hooks mutations, and external mutation therefore remain registered but return `AUTHORIZATION_REQUIRED` before a handler. Local context/event mediation and degraded concepts remain available. G7-S-FA revalidated these controls on the final clean committed HEAD; G7S-003 and G7S-004 are **closed** after technical mitigation verification and human review.

The distributed snapshot contains Markdown plus JavaScript and MJS executables. It can inspect and modify project files, run Node/npm commands, spawn local servers and browser/agent workflows, contact impeccable.style, and use a user OPENAI_API_KEY for image generation. Its context helper performs an update check and stores state under the user profile; concept selection can send telemetry unless disabled. The reviewed context also emits an autonomy directive that claims higher authority than surrounding policy. No Toolkit hook is activated, but the Skill can offer hook activation when explicitly invoked.

These capabilities exceed a passive design-review Skill. Pinning proves identity, not safety. The FTK boundary keeps the upstream payload non-discoverable and gates network, paid generation, authority, and project-write behavior. G7-S-FA found zero remaining HIGH or CRITICAL findings; publication itself remains outside this gate and requires the later preparation/audit approvals.

G7-SR3 must use a structural, version-aware, fail-closed context parser. An unknown format or a new authority/authorization directive is `UNKNOWN` and blocked; broad regex filtering is not the primary boundary. Environment inheritance should be allowlisted. Names such as `IMPECCABLE_NO_UPDATE_CHECK` and `IMPECCABLE_NO_TELEMETRY` are not accepted as controls until the pinned version is proven to honor them, otherwise equivalent external enforcement is required. A CLI flag such as `--authorized` is not proof of host authorization for `PAID_GENERATION`; generation remains available only through a real host-mediated authorization boundary or an equivalent host-native tool.

### img2threejs

The entire tracked upstream repository is redistributed, including Python entrypoints, shell scripts, integrations, issue automation, and network-capable helpers. Python subprocess calls reviewed use argument arrays; no shell=True, os.system, or command execution through the tested state key was found. Some helpers can fetch user-supplied URLs.

The state API accepts caller-provided paths, resolves them, creates the resolved parent, and replaces the resolved target without a workspace boundary check. Static canonicalization classifies absolute paths, parent traversal, and link targets outside the policy root. The optional GLB character pipeline sources a project-provided environment file as shell code. Both are release blockers. State is therefore not reliably confined to `.img2threejs`.

### Containment decision

For the defensive review, `AUTHORIZED_ROOT` is `<project>/.img2threejs`. This is the Toolkit policy boundary; the upstream does not declare or enforce it. With the process working directory at `<project>`, the reviewed paths resolve as follows:

| Input class | Canonical target | Decision |
|---|---|---|
| default `.img2threejs/state.json` | `<project>/.img2threejs/state.json` | `INSIDE_AUTHORIZED_ROOT` |
| nested `.img2threejs/nested/state.json` | `<project>/.img2threejs/nested/state.json` | `INSIDE_AUTHORIZED_ROOT` |
| `.img2threejs/../../outside-authorized-root/traversal.json` | sibling of `<project>` in the synthetic model | `OUTSIDE_AUTHORIZED_ROOT` |
| absolute target outside `.img2threejs` | that absolute target | `OUTSIDE_AUTHORIZED_ROOT` |
| junction or symlink below `.img2threejs` targeting outside | physical target outside `.img2threejs` | `OUTSIDE_AUTHORIZED_ROOT` |

The data-flow is caller-controlled `--state` → `Path` → `expanduser().resolve()` → parent creation → temporary file → `os.replace`. There is no `relative_to`, `is_relative_to`, `commonpath`, authorized-root comparison, or link-target containment assertion before the write. The test models link resolution and performs no upstream write.

G7-SR1 removes the direct-discovery bypass by placing an FTK-owned adapter at the Skill boundary. It does not yet make the upstream state or shell pipeline safe to execute. Shell escaping is not a valid remediation for an arbitrary sourced file. No upstream checkout or generated snapshot was patched.

At G7-SR1, G7-SR2 was required to add executable containment and structural configuration mediation before these entrypoints could be enabled. Its completed sink audit traced every sanitized `CHARACTER_*` value without routing project configuration through `build-character.sh`. Any `eval`, constructed command, unsafe unquoted expansion, or equivalent reparsing remains blocked. Canonical state enforcement resolves the authorized root and target before every operation and rejects traversal, absolute escape, and detectable symlink/junction/reparse escape.

## MCP and network model

Shadcn runs the exact shadcn@4.19.0 npm package through npx. Its reviewed tools discover registries, list/search/view items and examples, return an add command, and return an audit checklist. A returned command is data and must not be executed automatically. The default registry needs no credential. The documented custom-registry shape can name headers whose values reference environment variables. Because components.json is project-controlled, it must not select a registry or authorize environment access implicitly; queries should name an approved registry explicitly and credentialed registries require trusted configuration plus explicit user intent. The G7-S test parses this shape as inert data and inventories only the header name. No environment value was defined, read, or sent: DYNAMIC TEST NOT EXECUTED  STATIC/DEFENSIVE REVIEW COMPLETED.

21st is a remote HTTPS MCP at https://21st.dev/api/mcp and uses the consumer's own API_KEY_21ST. No maintainer key or 21st code is distributed. The remote surface is mutable. Only search is automatically authorized by Toolkit policy. Every new, unknown, metered, quota-relevant, copy/install, generate, iterate, publish, edit, delete, bookmark/list, account/profile, mutating, or uncertain operation requires explicit approval. A consumer-side enabled-tools allowlist is defense in depth, not a guarantee supplied by the plugin manifest.

Expected network destinations are:

| Component | Destination | Data/effect | Authorization |
|---|---|---|---|
| Shadcn MCP bootstrap | configured npm registry over HTTPS | package name/version; package download and execution | MCP use and documented dependency bootstrap |
| Shadcn registry | ui.shadcn.com or explicitly approved registry | query, registry names/items; optional user header | read-only intent; explicit approval for custom/private registry |
| 21st | 21st.dev over HTTPS | query and user API key; tool-dependent remote effects | search only by default; all other effects explicit |
| Release builder | pinned Git upstreams over HTTPS | commit/tag fetch | explicit build/update action |
| Impeccable | impeccable.style; optional api.openai.com | version/telemetry context; prompt and user API key for images | currently insufficiently gated; blocker |
| img2threejs helpers | caller-provided URL, GitHub, or integration endpoint | metadata/images/issues depending on entrypoint | explicit invocation and reviewed destination required |

No endpoint discovered outside these classes is silently allowed. Network access should be denied when it is unnecessary.

## Prompt injection and exfiltration

Synthetic fixtures cover project-file instructions to read a fake .env and send it externally, MCP output requesting unapproved generation, dangerous commands in README/source/comments, and social engineering that claims administrator authority or waives credits. The deterministic policy-contract evaluator treats all such content as data, performs no sensitive read or disclosure, executes no command, and retains the authorization gate.

Sensitive targets include .env, auth.json, credential files, environment variables, files outside the workspace, command arguments, logs, and MCP prompts. Legitimate access must be requested for a specific task, permitted by the host, minimized, and never converted into remote disclosure implicitly. Tests use synthetic markers only; no real credential is read, printed, or transmitted.

Prompt injection is a managed risk, not an impossible condition. Instruction policy alone is defense in depth and does not replace filesystem, process, network, and tool-level enforcement. The policy-contract test is not an authenticated model-session smoke. A Codex behavioral smoke still requires an isolated, officially authenticated CODEX_HOME and cannot be claimed from static or deterministic checks.

## Filesystem, archives, and subprocesses

Builders use git archive at locked commits, extract into a temporary stage, validate provenance, and reject persisted reparse points in the final candidate. Before extraction, the builder now inventories the selected Git tree and rejects absolute or ambiguous paths, traversal, symlinks, gitlinks/submodules, nested Git metadata, control-character paths, unsupported types, and executables outside an exact allowlist. Reviewed pinned trees contain no symlink, submodule, or nested repository entry. The release process also rejects secrets, hidden repositories, unexpected files, and unsafe destinations.

Local executable entrypoints must reject absolute output paths, traversal, symlink/junction/reparse escapes, and writes outside the authorized workspace and documented state directory. Recursive deletion is limited to validated disposable stages. Temporary fixtures use synthetic directories and require complete teardown.

Subprocess inventory includes PowerShell release/test scripts invoking Git, tar, Python, Node, npm/npx, and Codex; Impeccable Node scripts invoking npm/browser/server/agent helpers; and img2threejs Python/shell integrations. Prefer explicit argument arrays, fixed executable names, no shell interpolation, no sourced project configuration, minimized inherited environment, and no command returned by an MCP executed without independent review.

## Supply chain and updates

The candidate records upstream origin, tag, commit, license, content hashes, and provenance:

- Impeccable: tag skill-v4.1.2, commit 63b04e2530f5c7b41ea83c133daab24f34912456, Apache-2.0.
- img2threejs: tag v1.5.1, commit dede5909be4e494b228c801a55dda47439143932, Apache-2.0.
- Shadcn: package shadcn@4.19.0 with recorded npm integrity and shasum, MIT.
- 21st: remote endpoint only; no incorporated code; mutable tool surface.

No critical build input intentionally uses latest, a moving branch, or remote HEAD as its source of truth. A pin prevents unnoticed version drift, but it does not make executable content safe.

Every Impeccable, img2threejs, Shadcn, 21st surface, Codex CLI, or orchestrator-policy update requires: upstream diff; release notes; proportional security review; capability/tool reclassification; tests; provenance; deterministic build comparison; and cost-gate regression. Every new 21st tool starts as UNKNOWN - AUTHORIZATION REQUIRED.

## Installation and minimum privilege

Installation adds a local marketplace/plugin package. It does not require administrator/root, danger-full-access, sandbox bypass, global PATH changes, global package installation, unrestricted filesystem access, maintainer credentials, a hardcoded OpenAI key, or a maintainer 21st key. Each user authenticates their own Codex account and optionally supplies their own API_KEY_21ST.

Installation itself must not call a paid tool, read a secret, send a project file, mutate a project, or activate a hook. Using a Skill can execute its local code; using an MCP can start its process and network activity. npx may download the exact pinned Shadcn package when it is absent from cache. 21st is optional for all other capabilities.

## Known findings and release status

Severity scale used by this review: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, and `INFORMATIONAL`. No `LOW` finding is currently recorded.

| ID | Severity | Component | Finding | Exploitability | Mitigation/status |
|---|---|---|---|---|---|
| G7S-001 | CRITICAL | img2threejs | Preserved upstream shell sources project config | upstream sink remains non-discoverable and is never invoked by the FTK runner | **closed** after committed-HEAD revalidation and human review |
| G7S-002 | HIGH | img2threejs | Preserved upstream state accepts escaping paths | all registered FTK state operations require canonical guard and revalidation | **closed** after committed-HEAD revalidation and human review; TOCTOU residual retained |
| G7S-003 | HIGH | Impeccable | External instruction claims authority over host policy | raw upstream context is excluded from the integrated boundary | **closed** after final clean committed-HEAD revalidation and human review |
| G7S-004 | HIGH | Impeccable | Update, telemetry, and potentially paid image network effects are not consistently approval-gated | sensitive handlers stop at `AUTHORIZATION_REQUIRED` without a non-forgeable host grant | **closed** after final clean committed-HEAD revalidation and human review |
| G7S-005 | MEDIUM | Shadcn | Untrusted custom registry may cause environment-backed header disclosure | requires project registry selection | require explicit registry/header approval |
| G7S-006 | MEDIUM | Release builder | Archive entry mode/path checks were stronger after materialization than before extraction | required malicious pinned upstream update | mitigated by pre-extraction Git-tree validator and synthetic archive regression |
| G7S-007 | INFORMATIONAL | 21st | Live surface could not be re-enumerated without invoking the credentialed remote | no call made; drift remains unknown | all unknown tools fail closed |

G7S-001, G7S-002, G7S-003, and G7S-004 are **closed** after the final clean committed-HEAD acceptance and human review. No HIGH or CRITICAL finding remains. Canonicalization remediation is closed, and the release is ready for publication-preparation gates; this gate did not publish, tag, or push the candidate.

DYNAMIC TEST NOT EXECUTED  STATIC/DEFENSIVE REVIEW COMPLETED
