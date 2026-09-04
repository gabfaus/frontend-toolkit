Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginRoot = Join-Path $repoRoot 'plugin/frontend-toolkit'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot '.codex-plugin/plugin.json') | ConvertFrom-Json
$mcp = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot '.mcp.json') | ConvertFrom-Json
$external = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot 'external-skills.lock.json') | ConvertFrom-Json

if ($manifest.name -ne 'frontend-toolkit' -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Plugin identity or semver is invalid.' }
if ($manifest.license -ne 'Apache-2.0' -or -not (Test-Path -LiteralPath (Join-Path $repoRoot 'LICENSE'))) { throw 'Frontend Toolkit license is not Apache-2.0.' }
if ($manifest.skills -ne './skills/' -or $manifest.mcpServers -ne './.mcp.json') { throw 'Plugin component paths drifted.' }
if (-not (Test-Path -LiteralPath (Join-Path $pluginRoot 'skills/frontend-orchestrator/SKILL.md'))) { throw 'frontend-orchestrator is not bundled.' }
$skillNames = @(Get-ChildItem -LiteralPath (Join-Path $pluginRoot 'skills') -Directory | Sort-Object Name | Select-Object -ExpandProperty Name)
if (($skillNames -join ',') -ne 'frontend-orchestrator,img2threejs,impeccable') { throw "Plugin source Skills drifted: $($skillNames -join ',')" }
if ($manifest.PSObject.Properties.Name -contains 'hooks' -or (Test-Path -LiteralPath (Join-Path $pluginRoot 'hooks'))) { throw 'Hooks must remain disabled.' }

$shadcn = $mcp.mcpServers.shadcn
$twentyFirst = $mcp.mcpServers.'21st'
if ($shadcn.command -ne 'npx' -or ($shadcn.args -join ' ') -ne '--yes shadcn@4.19.0 mcp') { throw 'Shadcn MCP is not pinned.' }
if ($twentyFirst.url -ne 'https://21st.dev/api/mcp' -or $twentyFirst.bearer_token_env_var -ne 'API_KEY_21ST') { throw '21st MCP auth contract drifted.' }
if (($twentyFirst.PSObject.Properties.Name | Where-Object { $_ -match 'token|key|secret' }) -contains 'bearer_token') { throw 'A 21st secret was embedded.' }
if ((Get-Content -Raw -LiteralPath (Join-Path $pluginRoot '.mcp.json')) -match 'magic-mcp|jpisnice') { throw 'A prohibited or inactive MCP was packaged.' }

if ($external.strategy -ne 'mediated-adapter-generated-snapshots' -or $external.architecture -ne 'ftk-owned-mediated-adapter' -or @($external.dependencies).Count -ne 2) { throw 'External Skill strategy drifted.' }
foreach ($dependency in $external.dependencies) {
    if ($dependency.license -ne 'Apache-2.0' -or $dependency.commitSha -notmatch '^[0-9a-f]{40}$') { throw "Invalid external Skill provenance: $($dependency.id)" }
    if (-not $dependency.adapterBundled -or $dependency.upstreamSnapshotBundled) { throw "Source bundling state drifted: $($dependency.id)" }
    $adapter = Join-Path $pluginRoot ($dependency.adapterPath + '/SKILL.md')
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $adapter).Hash.ToLowerInvariant() -ne $dependency.adapterEntrySha256) { throw "Adapter provenance drifted: $($dependency.id)" }
}
if (Test-Path -LiteralPath (Join-Path $pluginRoot 'third_party')) { throw 'Upstream snapshots must not exist in plugin source.' }
$effectPolicy = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot 'security/effect-policy.json') | ConvertFrom-Json
if ($effectPolicy.unknownEffectPolicy -ne 'deny' -or @($effectPolicy.effectClasses) -notcontains 'UNKNOWN' -or @($effectPolicy.effectClasses) -notcontains 'PROJECT_CODE_EXECUTION') { throw 'Capability boundary is not fail-closed or lacks project-code mediation.' }
$expectedImpeccableGuards = @('impeccable-authority-policy.json','impeccable-context-extractor.mjs','impeccable-context-mediator.mjs','impeccable-detector.mjs','impeccable-static-runtime.mjs','impeccable-network-client.mjs','impeccable-operation-policy.json','impeccable-runner.ps1')
foreach ($guard in $expectedImpeccableGuards) {
    if (-not (Test-Path -LiteralPath (Join-Path $pluginRoot ('security/' + $guard)) -PathType Leaf)) { throw "Impeccable guard is missing: $guard" }
}

$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$impeccable = $externalLock.dependencies | Where-Object id -eq 'impeccable'
if ($impeccable.noticeSha256 -notmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath (Join-Path $repoRoot $impeccable.noticeFile))) { throw 'Impeccable NOTICE provenance is incomplete.' }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repoRoot $impeccable.noticeFile)).Hash.ToLowerInvariant() -ne $impeccable.noticeSha256) { throw 'Impeccable NOTICE hash drifted.' }

Write-Output 'PASS: plugin source contains exactly three FTK adapters, two MCPs and a fail-closed effect policy.'
