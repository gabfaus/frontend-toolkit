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
. (Join-Path $PSScriptRoot 'helpers/external-prerequisite.ps1')
Assert-FtkExternalPrerequisite
$resolver = Join-Path $repoRoot 'scripts/resolve-toolchain.ps1'
$harness = Join-Path $repoRoot 'scripts/invoke-codex-test.ps1'
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$configHashBefore = if (Test-Path -LiteralPath $configPath) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash.ToLowerInvariant()
} else { '<absent>' }

$toolchain = & $resolver
if ($toolchain.NodeVersion -ne '24.20.0') { throw 'Node resolution failed.' }
if ($toolchain.PythonVersion -ne '3.14.7') { throw 'Python resolution failed.' }
$validation = & $harness -ValidateOnly
if ($validation.ConfigMutation -ne 'none') { throw 'Validate-only harness mutated Codex config.' }

& (Join-Path $PSScriptRoot 'test-skill-integration.ps1')

foreach ($checkout in @('external/impeccable', 'external/img2threejs')) {
    if (& git -C (Join-Path $repoRoot $checkout) status --porcelain) {
        throw "External checkout is dirty: $checkout"
    }
}
foreach ($forbidden in @('.codex/hooks.json', '.codex/config.toml', '.mcp.json', '.codex-plugin/plugin.json')) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $forbidden)) {
        throw "Forbidden integration artifact found: $forbidden"
    }
}

$userPathAfter = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathAfter = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$configHashAfter = if (Test-Path -LiteralPath $configPath) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash.ToLowerInvariant()
} else { '<absent>' }
if ((Get-StringHash $userPathBefore) -ne (Get-StringHash $userPathAfter)) { throw 'User PATH changed.' }
if ((Get-StringHash $machinePathBefore) -ne (Get-StringHash $machinePathAfter)) { throw 'Machine PATH changed.' }
if ($configHashBefore -ne $configHashAfter) { throw 'Codex user config changed.' }

Write-Output 'PASS: toolchain resolves exact pinned runtimes without persistent PATH mutation.'
Write-Output 'PASS: isolation harness validates without changing Codex user config.'
Write-Output 'PASS: skills, external checkouts, hooks, MCPs and plugin boundaries remain valid.'
