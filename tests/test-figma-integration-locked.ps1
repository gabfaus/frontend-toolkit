Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/figma.lock.json') | ConvertFrom-Json
$policy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/figma-operation-policy.json') | ConvertFrom-Json

function Get-Server($config, [string]$name) {
    $property = @($config.mcpServers.PSObject.Properties | Where-Object Name -eq $name)
    if ($property.Count -ne 1) { return $null }
    return $property[0].Value
}

function Assert-SetEqual {
    param([string[]]$Actual, [string[]]$Expected, [string]$Label)
    $delta = @(Compare-Object -ReferenceObject $Expected -DifferenceObject $Actual)
    if ($delta.Count) { throw "$Label drifted: $($delta | Out-String)" }
}

$expectedReadTools = @(
    'get_design_context', 'get_metadata', 'get_screenshot', 'get_variable_defs',
    'get_figjam', 'get_motion_context', 'get_libraries', 'search_design_system',
    'get_code_connect_map'
)
$expectedWriteTools = @(
    'use_figma', 'create_new_file', 'generate_figma_design', 'generate_diagram',
    'upload_assets', 'add_code_connect_map', 'send_code_connect_mappings',
    'plugins.generative', 'shaders', 'weave.mutations', 'remote.create',
    'remote.edit', 'remote.delete'
)

if ($lock.repository -ne 'https://github.com/figma/mcp-server-guide' -or -not $lock.officialRepository -or
    $lock.skill.commitSha -ne 'ae7e5e5f80da20f1dd7445e0c6ae5ac58a5b0bce' -or
    $lock.skill.ref -ne $lock.skill.commitSha -or $lock.skill.commitSha -notmatch '^[0-9a-f]{40}$' -or
    $lock.skill.commitIdentity -ne 'Skills v2.2.107 (#96)' -or $lock.skill.verification -ne 'GitHub-verified' -or
    $lock.skill.sourceSha256 -ne '936bbe68b4731d4a8748db15f85247efde232c8ae0902857c2c79a9ed40649ea') {
    throw 'Official Figma pin, commit identity or source hash drifted.'
}
if ($lock.skill.license -ne 'not-declared-in-repository' -or $null -ne $lock.skill.licenseFile -or
    $lock.skill.license_model -ne 'Figma Developer Terms' -or $lock.skill.terms -ne 'Figma Developer Terms' -or
    $lock.skill.upstream_status -ne 'Beta' -or
    $lock.skill.distribution_model -ne 'link-only / upstream content not redistributed') {
    throw 'Figma legal/provenance model drifted.'
}

Assert-SetEqual @($policy.capabilities.FIGMA_READ.tools) $expectedReadTools 'Figma read allowlist'
Assert-SetEqual @($policy.capabilities.FIGMA_WRITE.tools) $expectedWriteTools 'Figma write boundary'
if ($policy.defaultCapability -ne 'FIGMA_READ' -or $policy.unknownToolPolicy -ne 'deny' -or
    $policy.unknownEffectPolicy -ne 'deny' -or $policy.responseTrust -ne 'untrusted-external-data' -or
    $policy.capabilities.FIGMA_READ.automaticCalls -ne $false -or
    $policy.capabilities.FIGMA_DESIGN_TO_CODE.remoteWrite -ne $false -or
    $policy.capabilities.FIGMA_DESIGN_TO_CODE.firstReadTool -ne 'get_design_context' -or
    $policy.capabilities.FIGMA_WRITE.enabledByDefault -ne $false -or
    $policy.capabilities.FIGMA_WRITE.handler -ne 'none' -or
    $policy.capabilities.FIGMA_WRITE.remoteWrite -ne $false -or
    $policy.manualOperations.download_assets.automaticCalls -ne $false -or
    @($policy.manualOperations.download_assets.effects) -notcontains 'LOCAL_PROJECT_WRITE' -or
    $policy.manualOperations.whoami.automaticCalls -ne $false) {
    throw 'Figma fail-closed capability boundary drifted.'
}
if ($policy.transports.remote.id -ne 'figma' -or $policy.transports.remote.endpoint -ne 'https://mcp.figma.com/mcp' -or
    $policy.transports.desktop.id -ne 'figma-desktop' -or $policy.transports.desktop.endpoint -ne 'http://127.0.0.1:3845/mcp' -or
    $policy.serverSelection.activeServerIdsMustBeExactlyOne -ne $true -or
    $policy.serverSelection.rejectMultipleActiveServers -ne $true) {
    throw 'Remote/Desktop Figma transport separation drifted.'
}

$configs = @(
    @{ Path = 'plugin/frontend-toolkit/figma.remote.mcp.json'; Name = 'figma'; Url = 'https://mcp.figma.com/mcp' },
    @{ Path = 'plugin/frontend-toolkit/figma-desktop.mcp.json'; Name = 'figma-desktop'; Url = 'http://127.0.0.1:3845/mcp' },
    @{ Path = 'claude/figma.remote.mcp.json'; Name = 'figma'; Url = 'https://mcp.figma.com/mcp' },
    @{ Path = 'claude/figma-desktop.mcp.json'; Name = 'figma-desktop'; Url = 'http://127.0.0.1:3845/mcp' }
)
foreach ($entry in $configs) {
    $config = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $entry.Path) | ConvertFrom-Json
    $servers = @($config.mcpServers.PSObject.Properties)
    if ($servers.Count -ne 1 -or $servers[0].Name -ne $entry.Name) { throw "Figma config enables an unexpected server: $($entry.Path)" }
    $server = $servers[0].Value
    if ($server.url -ne $entry.Url) { throw "Figma endpoint drifted: $($entry.Path)" }
    Assert-SetEqual @($server.enabled_tools) $expectedReadTools "$($entry.Path) read tools"
}

$adapterPaths = @('.agents/skills/figma-design-to-code/SKILL.md', 'plugin/frontend-toolkit/skills/figma-design-to-code/SKILL.md')
$adapterHashes = @($adapterPaths | ForEach-Object {
    $path = Join-Path $repoRoot $_
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Figma adapter missing: $_" }
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
})
if ($adapterHashes[0] -ne $adapterHashes[1] -or $adapterHashes[0] -eq $lock.skill.sourceSha256) {
    throw 'Codex/plugin adapter identity is invalid or contains the upstream source copy.'
}

foreach ($forbiddenPath in @('external/figma', 'third_party/upstreams/figma')) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $forbiddenPath)) { throw "Figma upstream content was vendored: $forbiddenPath" }
}

$mediator = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/figma-capability-mediator.mjs')
foreach ($forbidden in @('fetch(', 'McpServer', 'StreamableHTTPClientTransport', 'callTool(')) {
    if ($mediator.IndexOf($forbidden, [StringComparison]::Ordinal) -ge 0) { throw "Figma mediator contains a forbidden runtime: $forbidden" }
}

$nodePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs/FrontendToolkit/node-v24.20.0-win-x64/node.exe'
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $nodeCommand) { throw 'Node is required for the hermetic Figma mediator test.' }
    $nodePath = $nodeCommand.Source
}
& $nodePath (Join-Path $repoRoot 'tests/figma-mediator-smoke.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Hermetic Figma mediator test failed.' }

$credentialPattern = '(?i)(sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._-]{20,}|(?:api[_-]?key|access[_-]?token|secret|cookie|credential)\s*[=:]\s*["''][^"'']+["''])'
$figmaPaths = @($adapterPaths + @(
    'plugin/frontend-toolkit/security/figma-operation-policy.json',
    'plugin/frontend-toolkit/security/figma-capability-mediator.mjs',
    'plugin/frontend-toolkit/figma.remote.mcp.json',
    'plugin/frontend-toolkit/figma-desktop.mcp.json',
    'claude/figma.remote.mcp.json',
    'claude/figma-desktop.mcp.json',
    'integrations/figma.lock.json'
))
foreach ($relativePath in $figmaPaths) {
    $content = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $relativePath)
    if ($content -match $credentialPattern) { throw "Potential credential material found in $relativePath." }
}

Write-Output 'PASS: official Figma pin, commit identity, terms/Beta model and link-only provenance are locked.'
Write-Output 'PASS: read allowlist, write/manual boundary, unknown denial and untrusted responses validated.'
Write-Output 'PASS: Codex/Claude remote and Desktop configs use distinct mutually exclusive IDs.'
Write-Output 'REAL FIGMA CALLS=0; OAUTH=0; CREDENTIALS PERSISTED=0; REMOTE WRITES=0; ACCOUNT/PLAN SELECTION=0'
