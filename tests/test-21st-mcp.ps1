param(
    [ValidateSet('Auto', 'WithoutCredential', 'WithCredential')]
    [string]$Mode = 'Auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StringHash {
    param([AllowEmptyString()][string]$Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha256.Dispose() }
}

function Get-FileHashOrAbsent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<absent>' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoSafe = $repoRoot.Replace('\', '/')
$toolchain = & (Join-Path $repoRoot 'scripts/resolve-toolchain.ps1')
$lockPath = Join-Path $repoRoot 'integrations/mcp.lock.json'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
$server = $lock.servers | Where-Object id -eq '21st'
if ($server.status -ne 'validated-ftk-03b-awaiting-review') { throw 'Unexpected 21st MCP status.' }
if ($server.transport -ne 'streamable-http' -or $server.endpoint -ne 'https://21st.dev/api/mcp') { throw 'Unexpected 21st transport or endpoint.' }
if ($server.authentication.mechanism -ne 'bearer-token-env-var' -or $server.authentication.envVar -ne 'API_KEY_21ST') { throw 'Unexpected 21st authentication contract.' }
if ($server.validatedCodexVersion -ne '0.150.1' -or $toolchain.StableCodexVersion -ne '0.150.1') { throw 'Stable Codex 0.150.1 is required.' }

$categories = @(
    @($server.observedToolSurface.discoveryReadOnly),
    @($server.observedToolSurface.retrieval),
    @($server.observedToolSurface.accountUsageReadOnly),
    @($server.observedToolSurface.generationMetered),
    @($server.observedToolSurface.mutationWrite)
)
$lockedTools = @($categories | ForEach-Object { $_ })
if ($lockedTools.Count -ne 35 -or @($lockedTools | Sort-Object -Unique).Count -ne 35) { throw '21st tool classifications must contain 35 distinct tools.' }
if ($server.observedToolSurface.count -ne 35) { throw '21st observed tool count does not match classifications.' }
if ($server.functionalValidation.tool -ne 'search' -or $server.functionalValidation.mutating) { throw 'Only read-only search may be used functionally.' }
if (@($server.costAndSafety.writeOperationsUsed).Count -ne 0) { throw 'The lock reports a write operation.' }

$helperPath = Join-Path $repoRoot 'tests/helpers/21st-mcp-smoke.mjs'
$harnessPath = Join-Path $repoRoot 'scripts/invoke-21st-codex-test.ps1'
$helper = Get-Content -Raw -LiteralPath $helperPath
$harness = Get-Content -Raw -LiteralPath $harnessPath
if ($helper -notmatch [regex]::Escape('https://21st.dev/api/mcp') -or $helper -notmatch 'process\.env\.API_KEY_21ST') { throw 'Direct helper does not use the locked endpoint and environment reference.' }
if ($helper -match '(?i)--api-key' -or $harness -match '(?i)--api-key') { throw 'A 21st key could be passed on the command line.' }
if ($harness -notmatch 'enabled_tools\s*=\s*\["search"\]' -or $harness -notmatch '(?s)\[mcp_servers\.shadcn\].*?enabled\s*=\s*false') { throw 'Codex harness allowlist or Shadcn isolation is missing.' }

foreach ($forbidden in @(
    '.codex/hooks.json',
    '.codex/config.toml',
    '.mcp.json',
    '.codex-plugin/plugin.json',
    '.agents/skills/21st-cli-use',
    '.agents/skills/21st-ai',
    '.agents/skills/21st-registry',
    '.agents/skills/21st-design-sync',
    'node_modules/@21st-dev',
    'node_modules/@21st-dev/magic'
)) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $forbidden)) { throw "Forbidden 21st/Magic/plugin artifact found: $forbidden" }
}
if ($lock.prohibited -notcontains 'magic-mcp') { throw 'Magic MCP prohibition is missing.' }

$processPathForDiscovery = $env:PATH
try {
    $env:PATH = "$(Split-Path -Parent $toolchain.StableCodexPath);$processPathForDiscovery"
    & (Join-Path $PSScriptRoot 'test-skill-integration.ps1')
} finally { $env:PATH = $processPathForDiscovery }
$validation = & $harnessPath -ValidateOnly
if ($validation.CodexVersion -ne '0.150.1' -or $validation.Endpoint -ne 'https://21st.dev/api/mcp') { throw '21st Codex harness validation failed.' }

$credentialAvailable = if ($Mode -eq 'WithoutCredential') {
    $false
} else {
    -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST', 'Process'))
}
if ($Mode -eq 'WithCredential' -and -not $credentialAvailable) { throw 'API_KEY_21ST is required for WithCredential mode.' }
if (-not $credentialAvailable) {
    Write-Output 'PASS: 21st static configuration, lock, endpoint, harness and provider boundaries validated.'
    Write-Output 'PASS: Impeccable and img2threejs remain intact; Shadcn is isolated; 21st plugin/Skills and Magic are absent.'
    Write-Output 'FTK-03B aguardando API_KEY_21ST fornecida externamente.'
    exit 0
}

$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = Get-FileHashOrAbsent $configPath
$userPathHashBefore = Get-StringHash ([Environment]::GetEnvironmentVariable('Path', 'User'))
$machinePathHashBefore = Get-StringHash ([Environment]::GetEnvironmentVariable('Path', 'Machine'))
$gitBefore = (& git -c "safe.directory=$repoSafe" status --porcelain=v1 --untracked-files=all | Out-String)
$nodeOptionsBefore = $env:NODE_OPTIONS
try {
    $env:NODE_OPTIONS = '--use-system-ca'
    $raw = & $toolchain.NodePath $helperPath --functional | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Direct 21st MCP smoke failed.' }
} finally { $env:NODE_OPTIONS = $nodeOptionsBefore }
$direct = $raw | ConvertFrom-Json
if ($direct.endpoint -ne $server.endpoint -or $direct.protocolVersion -ne $server.observedProtocolVersion) { throw 'Direct 21st MCP handshake drifted.' }
if ($direct.serverInfo.name -ne '21st') { throw 'Unexpected 21st server identity.' }
$observedTools = @($direct.tools.name)
if (@(Compare-Object ($lockedTools | Sort-Object) ($observedTools | Sort-Object)).Count -ne 0) { throw 'Remote 21st tool inventory drifted from the dated lock snapshot.' }
if ($direct.functional.tool -ne 'search' -or $direct.functional.outcome -ne 'results-returned') { throw 'Free read-only dashboard search failed.' }
if ($direct.teardown -notin @('stateless-no-session-id', 'http-200', 'http-202', 'http-204', 'http-404', 'http-405')) { throw 'Direct MCP teardown was not controlled.' }

$codexResult = & $harnessPath
if ($codexResult[-1].McpCall -ne 'completed' -or $codexResult[-1].ShadcnEnabled -ne $false) { throw 'Stable Codex 21st validation failed.' }

$credential = [Environment]::GetEnvironmentVariable('API_KEY_21ST', 'Process')
$versionablePaths = @(& git -c "safe.directory=$repoSafe" ls-files --cached --others --exclude-standard)
foreach ($relativePath in $versionablePaths) {
    $candidate = Join-Path $repoRoot $relativePath
    if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and [IO.File]::ReadAllText($candidate).Contains($credential)) {
        throw "Credential material found in a versionable repository file: $relativePath"
    }
}
Remove-Variable credential -ErrorAction SilentlyContinue

if ((Get-FileHashOrAbsent $configPath) -ne $configHashBefore) { throw 'Codex user config changed.' }
if ((Get-StringHash ([Environment]::GetEnvironmentVariable('Path', 'User'))) -ne $userPathHashBefore) { throw 'Persistent user PATH changed.' }
if ((Get-StringHash ([Environment]::GetEnvironmentVariable('Path', 'Machine'))) -ne $machinePathHashBefore) { throw 'Persistent machine PATH changed.' }
$gitAfter = (& git -c "safe.directory=$repoSafe" status --porcelain=v1 --untracked-files=all | Out-String)
if ($gitBefore -ne $gitAfter) { throw 'FTK-03B validation mutated the repository.' }

Write-Output 'PASS: 21st MCP handshake, 35-tool inventory and stateless teardown validated.'
Write-Output 'PASS: free read-only dashboard search completed directly and through Codex CLI 0.150.1.'
Write-Output 'PASS: no paid, account, generation or write tool was called; secrets and persistent state remain isolated.'
