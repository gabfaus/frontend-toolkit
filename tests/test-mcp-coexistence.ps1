param(
    [ValidateSet('Auto', 'WithoutCredential', 'WithCredential')]
    [string]$Mode = 'Auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StringHash {
    param([AllowEmptyString()][string]$Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-FileHashOrAbsent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<absent>' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoSafe = $repoRoot.Replace('\', '/')
$harnessPath = Join-Path $repoRoot 'scripts/invoke-combined-codex-test.ps1'
$toolchain = & (Join-Path $repoRoot 'scripts/resolve-toolchain.ps1')
$lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/mcp.lock.json') | ConvertFrom-Json
$shadcn = $lock.servers | Where-Object id -eq 'shadcn'
$twentyFirst = $lock.servers | Where-Object id -eq '21st'
if ($shadcn.version -ne '4.19.0' -or $twentyFirst.endpoint -ne 'https://21st.dev/api/mcp') { throw 'Approved MCP pins changed.' }
if ($toolchain.StableCodexVersion -ne '0.150.1' -or -not (Test-Path -LiteralPath $toolchain.CodeModeHostPath -PathType Leaf)) { throw 'Stable Codex toolchain is incomplete.' }

$harness = Get-Content -Raw -LiteralPath $harnessPath
if ($harness -notmatch 'enabled_tools\s*=\s*\["search_items_in_registries"\]' -or $harness -notmatch 'enabled_tools\s*=\s*\["search"\]') { throw 'Combined MCP allowlists are missing.' }
if ($harness -notmatch 'bearer_token_env_var\s*=\s*"API_KEY_21ST"') { throw 'Combined credential environment reference is missing.' }
if ($harness -notmatch [regex]::Escape('Primeiro use Shadcn') -or $harness -notmatch [regex]::Escape('Depois use 21st somente em modo search')) { throw 'Explicit sequential routing prompt is missing.' }

foreach ($forbidden in @(
    '.codex/hooks.json','.codex/config.toml','.mcp.json','.codex-plugin/plugin.json',
    '.agents/skills/21st-cli-use','.agents/skills/21st-ai','.agents/skills/21st-registry','.agents/skills/21st-design-sync',
    'node_modules/@21st-dev','node_modules/@21st-dev/magic'
)) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $forbidden)) { throw "Forbidden coexistence artifact found: $forbidden" }
}
if (($lock.inactiveCandidates | Where-Object id -eq 'jpisnice-shadcn-ui-mcp-server').status -notlike '*not-active*') { throw 'Jpisnice is not inactive.' }
if ($lock.prohibited -notcontains 'magic-mcp') { throw 'Magic MCP prohibition is missing.' }

$processPathBefore = $env:PATH
try {
    $env:PATH = "$(Split-Path -Parent $toolchain.StableCodexPath);$processPathBefore"
    & (Join-Path $PSScriptRoot 'test-toolchain.ps1')
    & (Join-Path $PSScriptRoot 'test-skill-integration.ps1')
} finally { $env:PATH = $processPathBefore }

$validation = & $harnessPath -ValidateOnly
if ($validation.CodexVersion -ne '0.150.1' -or $validation.ShadcnVersion -ne '4.19.0' -or $validation.TwentyFirstEndpoint -ne 'https://21st.dev/api/mcp') { throw 'Combined harness validation failed.' }

$credentialAvailable = if ($Mode -eq 'WithoutCredential') { $false } else { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST','Process')) }
if ($Mode -eq 'WithCredential' -and -not $credentialAvailable) { throw 'API_KEY_21ST is required for WithCredential mode.' }
if (-not $credentialAvailable) {
    Write-Output 'PASS: combined toolchain, Skills, MCP pins, allowlists and provider boundaries validated.'
    Write-Output 'FTK-03C aguardando API_KEY_21ST fornecida externamente.'
    exit 0
}

$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = Get-FileHashOrAbsent $configPath
$userPathHashBefore = Get-StringHash ([Environment]::GetEnvironmentVariable('Path','User'))
$machinePathHashBefore = Get-StringHash ([Environment]::GetEnvironmentVariable('Path','Machine'))
$gitBefore = (& git -c "safe.directory=$repoSafe" status --porcelain=v1 --untracked-files=all | Out-String)
$result = @(& $harnessPath)[-1]
if ($result.Mode -ne 'executed' -or $result.CredentialGate -ne 'available') { throw 'Combined authenticated harness did not execute.' }
if (@(Compare-Object @('21st','shadcn') @($result.EnabledServers)).Count) { throw 'Combined session did not isolate exactly Shadcn and 21st.' }
if (@(Compare-Object @('impeccable:impeccable','img2threejs') @($result.Skills)).Count) { throw 'Combined session did not preserve both Skills.' }
if ($result.ShadcnToolCount -ne 7) { throw 'Unexpected Shadcn inventory in coexistence test.' }
if ($result.TwentyFirstSnapshotComparison -ne 'identical-to-ftk-03b') { throw '21st inventory drifted from FTK-03B.' }
if ($result.ShadcnTest -ne 'passed' -or $result.TwentyFirstTest -ne 'passed-search-only' -or $result.SequentialTest -ne 'passed-shadcn-then-21st') { throw 'One or more combined functional tests failed.' }
if ($result.PaidOrMutableCalls -ne 0 -or $result.FixtureMutation -ne 'none' -or $result.PersistentMutation -ne 'none') { throw 'Combined validation reported a forbidden effect.' }

$credential = [Environment]::GetEnvironmentVariable('API_KEY_21ST','Process')
$versionablePaths = @(& git -c "safe.directory=$repoSafe" ls-files --cached --others --exclude-standard)
foreach ($relativePath in $versionablePaths) {
    $candidate = Join-Path $repoRoot $relativePath
    if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and [IO.File]::ReadAllText($candidate).Contains($credential)) { throw "Credential material found in versionable file: $relativePath" }
}
Remove-Variable credential -ErrorAction SilentlyContinue

foreach ($checkout in @('external/impeccable','external/img2threejs')) {
    if (& git -C (Join-Path $repoRoot $checkout) status --porcelain) { throw "External checkout changed: $checkout" }
}
if ((Get-FileHashOrAbsent $configPath) -ne $configHashBefore) { throw 'Codex user config changed.' }
if ((Get-StringHash ([Environment]::GetEnvironmentVariable('Path','User'))) -ne $userPathHashBefore) { throw 'Persistent user PATH changed.' }
if ((Get-StringHash ([Environment]::GetEnvironmentVariable('Path','Machine'))) -ne $machinePathHashBefore) { throw 'Persistent machine PATH changed.' }
$gitAfter = (& git -c "safe.directory=$repoSafe" status --porcelain=v1 --untracked-files=all | Out-String)
if ($gitBefore -ne $gitAfter) { throw 'Coexistence validation mutated the repository.' }

Write-Output "PASS: simultaneous discovery preserved two Skills and two MCPs with distinct namespaces."
Write-Output "PASS: Shadcn=$($result.ShadcnToolCount) tools; 21st=$($result.TwentyFirstToolCount) tools, identical to FTK-03B snapshot."
Write-Output 'PASS: Shadcn-only, 21st search-only and sequential Shadcn-then-21st tests completed without paid or mutable calls.'
