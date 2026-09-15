Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/external-prerequisite.ps1')
Assert-FtkExternalPrerequisite
$manifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/.codex-plugin/plugin.json') | ConvertFrom-Json
$distribution = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/distribution.lock.json') | ConvertFrom-Json
$external = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$notices = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md')

if ($manifest.license -ne 'Apache-2.0') { throw 'Plugin license metadata drifted.' }
if ((Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE') -TotalCount 3 | Out-String) -notmatch 'Apache License') { throw 'Apache-2.0 license text is missing.' }
foreach ($term in @('Impeccable', 'img2threejs', 'Shadcn', '21st', 'Platform Design Skills')) { if ($notices -notmatch [regex]::Escape($term)) { throw "Third-party notice is missing $term." } }
if ($distribution.strategy -ne 'mediated-adapter-generated-snapshots' -or $distribution.architecture -ne 'ftk-owned-mediated-adapter' -or $distribution.observedSnapshotTreeSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Distribution lock drifted.' }
$impeccable = $external.dependencies | Where-Object id -eq 'impeccable'
if ($impeccable.noticeSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Impeccable NOTICE is not locked.' }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repoRoot $impeccable.noticeFile)).Hash.ToLowerInvariant() -ne $impeccable.noticeSha256) { throw 'Impeccable NOTICE hash drifted.' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts/invoke-installed-plugin-smoke.ps1'))) { throw 'Installed smoke harness is missing.' }

$secretPattern = '(sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._-]{20,}|API_KEY_21ST\s*[=:]\s*["''][^"'']+["''])'
$secretHits = @()
Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -notmatch '[\\/]external[\\/]' } | ForEach-Object {
    try { if ([IO.File]::ReadAllText($_.FullName) -match $secretPattern) { $secretHits += $_.FullName.Substring($repoRoot.Length + 1) } } catch { }
}
if ($secretHits.Count) { throw "Potential secret material found: $($secretHits -join ', ')" }

& (Join-Path $repoRoot 'tests/test-release-safety.ps1')
& (Join-Path $repoRoot 'tests/test-cross-worktree-determinism.ps1')
& (Join-Path $repoRoot 'tests/test-plugin-packaging.ps1')
& (Join-Path $repoRoot 'tests/test-impeccable-detector-capability.ps1')
& (Join-Path $repoRoot 'tests/test-impeccable-integrated-boundary.ps1')
& (Join-Path $repoRoot 'tests/test-impeccable-execution-robustness.ps1')
& (Join-Path $repoRoot 'tests/test-plugin-distribution.ps1') -ValidateOnly
& (Join-Path $repoRoot 'tests/test-plugin-official-validation.ps1')
& (Join-Path $repoRoot 'scripts/invoke-installed-plugin-smoke.ps1') -ValidateOnly

Write-Output 'PASS: plugin hardening includes the integrated Impeccable boundary, packaging, distribution, validators and installed-smoke contracts.'
