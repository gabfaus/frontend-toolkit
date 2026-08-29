param([switch]$ValidateOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$harnessPath = Join-Path $repoRoot 'scripts/invoke-frontend-routing-test.ps1'
$harness = Get-Content -Raw -LiteralPath $harnessPath

if ($harness -notmatch 'enabled_tools\s*=\s*\["search"\]') { throw '21st is not restricted to search.' }
if ($harness -notmatch "--sandbox','danger-full-access") { throw 'FTK-04B does not use the restricted danger-full-access sandbox.' }
if ($harness -match "enabled_tools\s*=\s*\[[^\]]*(generate|iterate_generation|get_component)") { throw 'A gated 21st tool is exposed.' }
if ($harness -notmatch 'SYNTHETIC_REFERENCE\.png' -or $harness -notmatch "Scenario 10 wrote outside \.img2threejs/") { throw 'Scenario 10 synthetic fixture confinement is missing.' }
if ($harness -notmatch 'External checkout changed during routing' -or $harness -notmatch 'FixtureTeardown = if \(\$fixtureRemoved\) \{ ''complete'' \}') { throw 'Scenario 10 checkout or teardown guard is missing.' }

$matrix = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/scenarios.json') | ConvertFrom-Json
if (@($matrix.scenarios).Count -ne 10) { throw 'FTK-04B scenario contract drifted.' }
if ($ValidateOnly) {
    $validation = & $harnessPath -ValidateOnly
    if ($validation.ScenarioCount -ne 10 -or $validation.TwentyFirstTools -ne 'search') { throw 'FTK-04B validate-only contract failed.' }
    Write-Output 'PASS: FTK-04B harness, scenario 10 confinement and teardown contracts validated without behavioral reruns.'
    return
}
if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST','Process'))) { throw 'FTK-04B behavioral run requires the externally supplied 21st credential.' }

$result = & $harnessPath
if ($result.ScenariosPassed -ne 10) { throw 'Not all FTK-04B scenarios passed.' }
if ($result.PaidOrMutableCalls -ne 0 -or $result.FixtureMutation -notin @('none','ephemeral-only-cleaned') -or $result.FixtureTeardown -ne 'complete' -or $result.PersistentMutation -ne 'none') { throw 'FTK-04B reported a forbidden effect or incomplete teardown.' }

Write-Output 'PASS: ten versioned scenarios routed behaviorally with minimum necessary capabilities.'
Write-Output 'PASS: 21st remained search-only; generation, quota, mutation and uncertain operations stopped before execution.'
Write-Output 'PASS: Codex config, persistent PATH and external checkouts remained unchanged; ephemeral fixture artifacts were removed.'
