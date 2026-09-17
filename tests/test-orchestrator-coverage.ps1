Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExactSet {
    param([Parameter(Mandatory)][string[]]$Actual, [Parameter(Mandatory)][string[]]$Expected, [Parameter(Mandatory)][string]$Label)
    $left = @($Actual | Sort-Object)
    $right = @($Expected | Sort-Object)
    if (($left -join "`n") -cne ($right -join "`n")) { throw "$Label diverged. Actual: $($left -join ', '); Expected: $($right -join ', ')" }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$coveragePath = Join-Path $repoRoot 'integrations/orchestrator-coverage.v1.3.json'
$policyPath = Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/routing-policy.json'
if (-not (Test-Path -LiteralPath $coveragePath -PathType Leaf)) { throw 'Orchestrator coverage matrix is missing.' }
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json
$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
if ($coverage.schemaVersion -ne 1 -or $coverage.candidateVersion -ne '1.3.0' -or $coverage.result -ne 'NO ORPHAN CAPABILITIES') { throw 'Coverage matrix identity/result is invalid.' }
$policyIds = @($policy.capabilities.PSObject.Properties.Name)
Assert-ExactSet -Actual @($coverage.capabilityIds) -Expected $policyIds -Label 'Policy/matrix capability IDs'
$rows = @($coverage.capabilities)
if ($rows.Count -ne $policyIds.Count) { throw 'Coverage row count does not match policy capability count.' }
foreach ($row in $rows) {
    foreach ($required in @('id', 'domain', 'stageRoles', 'availability', 'effect', 'authorization', 'supportedHosts', 'routingPath', 'failClosed')) {
        if (-not ($row.PSObject.Properties.Name -contains $required)) { throw "Coverage row is missing ${required}: $($row.id)" }
    }
    if ($row.id -notin $policyIds) { throw "Coverage contains an orphan capability: $($row.id)" }
    Assert-ExactSet -Actual @($row.stageRoles.PSObject.Properties.Name) -Expected @('EXECUTE', 'PLAN', 'VERIFY') -Label "Stages for $($row.id)"
    if ([string]::IsNullOrWhiteSpace([string]$row.failClosed)) { throw "Fail-closed behavior is missing: $($row.id)" }
    if (@($row.supportedHosts).Count -eq 0) { throw "Supported host list is empty: $($row.id)" }
}
$codex = $coverage.hostProfiles.Codex
$claude = $coverage.hostProfiles.Claude
Assert-ExactSet -Actual @($codex.expectedSkills) -Expected @('figma-design-to-code','frontend-accessibility','frontend-orchestrator','img2threejs','impeccable','playwright-cli') -Label 'Codex host Skills'
Assert-ExactSet -Actual @($claude.expectedSkills) -Expected @('figma-design-to-code','frontend-orchestrator','img2threejs','impeccable') -Label 'Claude host Skills'
if ($codex.result -ne '6/6' -or $claude.result -ne '4/4') { throw 'Host distribution result is invalid.' }
if (@($claude.expectedSkills | Where-Object { $_ -in @('frontend-accessibility','playwright-cli') }).Count) { throw 'Claude received artificial Codex-only Skills.' }
$guarded = @($coverage.guardedSurfaces.id)
Assert-ExactSet -Actual $guarded -Expected @('21st-non-search-effects','playwright-test-runtime') -Label 'Guarded auxiliary surfaces'
Write-Output 'PASS: orchestrator coverage matrix matches every policy capability with no orphan capabilities.'
Write-Output 'PASS: Codex host coverage is 6/6 and Claude host coverage is 4/4 without artificial symmetry.'
Write-Output 'PASS: guarded 21st non-search effects and Playwright Test support runtime are explicit and fail-closed.'
