Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StringHash {
    param([AllowEmptyString()][string]$Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = & (Join-Path $repoRoot 'scripts/resolve-toolchain.ps1')
$lockPath = Join-Path $repoRoot 'integrations/mcp.lock.json'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
$shadcn = $lock.servers | Where-Object id -eq 'shadcn'
if ($shadcn.status -ne 'active-v1' -or $shadcn.version -ne '4.19.0') { throw 'Unexpected Shadcn MCP pin.' }
if ($shadcn.integrity -ne 'sha512-EQF6R+CUXTsEP2BpyhxrUEAFesrtFD1POvVOf5jM+wkgtA4kG1EW1+1Wlmi9LqiprSL681JJXBcS0u8WkVVVyQ==') { throw 'Unexpected Shadcn package integrity.' }
if ($shadcn.processEnvironment.NODE_OPTIONS -ne '--use-system-ca') { throw 'Shadcn MCP system CA environment is not locked.' }
$twentyFirst = $lock.servers | Where-Object id -eq '21st'
if ($twentyFirst.status -ne 'validated-ftk-03b-awaiting-review' -or $twentyFirst.transport -ne 'streamable-http') { throw '21st must remain a separately validated remote provider.' }
if (($lock.inactiveCandidates | Where-Object id -eq 'jpisnice-shadcn-ui-mcp-server').status -ne 'candidate-fallback-not-active-in-v1') { throw 'Community candidate must remain inactive.' }
if ($lock.prohibited -notcontains 'magic-mcp') { throw 'Magic MCP prohibition is missing.' }

$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = if (Test-Path -LiteralPath $configPath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash } else { '<absent>' }
$processPathBefore = $env:PATH
$processNodeOptionsBefore = $env:NODE_OPTIONS
$processNpxBefore = $env:FTK_NPX_CLI_PATH
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("frontend-toolkit-shadcn-smoke-" + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $fixture)
    [IO.File]::WriteAllText((Join-Path $fixture 'components.json'), '{"$schema":"https://ui.shadcn.com/schema.json","style":"new-york","rsc":false,"tsx":true,"tailwind":{"config":"","css":"src/index.css","baseColor":"neutral","cssVariables":true,"prefix":""},"aliases":{"components":"@/components","utils":"@/lib/utils","ui":"@/components/ui","lib":"@/lib","hooks":"@/hooks"},"iconLibrary":"lucide"}', [Text.UTF8Encoding]::new($false))
    $env:PATH = "$($toolchain.NodeDirectory);$processPathBefore"
    $env:NODE_OPTIONS = '--use-system-ca'
    $env:FTK_NPX_CLI_PATH = Join-Path $toolchain.NodeDirectory 'node_modules/npm/bin/npx-cli.js'
    Push-Location $fixture
    try {
        $json = & $toolchain.NodePath (Join-Path $repoRoot 'tests/helpers/shadcn-mcp-smoke.mjs') --functional | Out-String
        if ($LASTEXITCODE -ne 0) { throw 'Direct Shadcn MCP smoke failed.' }
    } finally { Pop-Location }
    $result = $json | ConvertFrom-Json
    $requiredTools = @('get_project_registries', 'list_items_in_registries', 'search_items_in_registries', 'view_items_in_registries', 'get_item_examples_from_registries', 'get_add_command_for_items', 'get_audit_checklist')
    $observedTools = @($result.tools.name)
    foreach ($tool in $requiredTools) { if ($observedTools -notcontains $tool) { throw "Missing MCP tool: $tool" } }
    if ($result.protocolVersion -ne '2025-06-18' -or $result.serverInfo.name -ne 'shadcn') { throw 'Unexpected MCP handshake.' }
    if (-not $result.functional.search -or -not $result.functional.view) { throw 'Functional read-only MCP calls did not pass.' }
} finally {
    $env:PATH = $processPathBefore
    $env:NODE_OPTIONS = $processNodeOptionsBefore
    $env:FTK_NPX_CLI_PATH = $processNpxBefore
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

& (Join-Path $PSScriptRoot 'test-skill-integration.ps1')
$stableValidation = & (Join-Path $repoRoot 'scripts/invoke-shadcn-codex-test.ps1') -ValidateOnly
if ($stableValidation.CodexVersion -ne '0.150.1') { throw 'Stable Codex harness resolution failed.' }
if (-not (Test-Path -LiteralPath $stableValidation.CodeModeHostPath -PathType Leaf)) { throw 'Code-mode host companion is missing.' }
foreach ($forbidden in @('.codex/hooks.json', '.codex/config.toml', '.mcp.json', '.codex-plugin/plugin.json')) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $forbidden)) { throw "Forbidden artifact found: $forbidden" }
}
if ((Get-StringHash $userPathBefore) -ne (Get-StringHash ([Environment]::GetEnvironmentVariable('Path', 'User')))) { throw 'User PATH changed.' }
if ((Get-StringHash $machinePathBefore) -ne (Get-StringHash ([Environment]::GetEnvironmentVariable('Path', 'Machine')))) { throw 'Machine PATH changed.' }
$configHashAfter = if (Test-Path -LiteralPath $configPath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash } else { '<absent>' }
if ($configHashBefore -ne $configHashAfter) { throw 'Codex user config changed.' }

Write-Output 'PASS: official Shadcn MCP 4.19.0 handshake and seven-tool inventory validated.'
Write-Output 'PASS: read-only registry search and component view succeeded with a synthetic fixture.'
Write-Output 'PASS: Skills, config, PATH, hooks, checkouts and provider boundaries remain isolated.'
