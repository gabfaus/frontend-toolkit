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
if ($manifest.PSObject.Properties.Name -contains 'hooks' -or (Test-Path -LiteralPath (Join-Path $pluginRoot 'hooks'))) { throw 'Hooks must remain disabled.' }

$shadcn = $mcp.mcpServers.shadcn
$twentyFirst = $mcp.mcpServers.'21st'
if ($shadcn.command -ne 'npx' -or ($shadcn.args -join ' ') -ne '--yes shadcn@4.19.0 mcp') { throw 'Shadcn MCP is not pinned.' }
if ($twentyFirst.url -ne 'https://21st.dev/api/mcp' -or $twentyFirst.bearer_token_env_var -ne 'API_KEY_21ST') { throw '21st MCP auth contract drifted.' }
if (($twentyFirst.PSObject.Properties.Name | Where-Object { $_ -match 'token|key|secret' }) -contains 'bearer_token') { throw 'A 21st secret was embedded.' }
if ((Get-Content -Raw -LiteralPath (Join-Path $pluginRoot '.mcp.json')) -match 'magic-mcp|jpisnice') { throw 'A prohibited or inactive MCP was packaged.' }

if ($external.strategy -ne 'external-prerequisites' -or @($external.dependencies).Count -ne 2) { throw 'External Skill strategy drifted.' }
if (@($external.dependencies | Where-Object bundled).Count -ne 0) { throw 'External upstream source was copied into FTK-05A.' }
foreach ($dependency in $external.dependencies) {
    if ($dependency.license -ne 'Apache-2.0' -or $dependency.commitSha -notmatch '^[0-9a-f]{40}$') { throw "Invalid external Skill provenance: $($dependency.id)" }
}

$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$impeccable = $externalLock.dependencies | Where-Object id -eq 'impeccable'
if ($impeccable.noticeSha256 -notmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath (Join-Path $repoRoot $impeccable.noticeFile))) { throw 'Impeccable NOTICE provenance is incomplete.' }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repoRoot $impeccable.noticeFile)).Hash.ToLowerInvariant() -ne $impeccable.noticeSha256) { throw 'Impeccable NOTICE hash drifted.' }

Write-Output 'PASS: FTK-05A plugin manifest, MCP wiring, external prerequisites and safety invariants validated.'
