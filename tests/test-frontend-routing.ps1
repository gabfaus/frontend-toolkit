param(
    [switch]$ValidateOnly,
    [switch]$Real21st
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$harnessPath = Join-Path $repoRoot 'scripts/invoke-frontend-routing-test.ps1'
$harness = Get-Content -Raw -LiteralPath $harnessPath

if ($harness -notmatch 'enabled_tools\s*=\s*\["search"\]') { throw '21st is not restricted to search.' }
if ($harness -notmatch '\[switch\]\$Real21st' -or $harness -notmatch "Mode = 'hermetic'") { throw 'Hermetic 21st routing mode is missing.' }
if ($harness -notmatch "--sandbox','danger-full-access") { throw 'FTK-04B real E2E path does not retain the restricted danger-full-access sandbox.' }
if ($harness -match "enabled_tools\s*=\s*\[[^\]]*(generate|iterate_generation|get_component)") { throw 'A gated 21st tool is exposed.' }
if ($harness -notmatch 'SYNTHETIC_REFERENCE\.png' -or $harness -notmatch "Scenario 10 wrote outside \.img2threejs/") { throw 'Scenario 10 synthetic fixture confinement is missing.' }
if ($harness -notmatch 'External checkout changed during routing' -or $harness -notmatch 'FixtureTeardown = if \(\$fixtureRemoved\) \{ ''complete'' \}') { throw 'Scenario 10 checkout or teardown guard is missing.' }

$matrix = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/scenarios.json') | ConvertFrom-Json
if ($matrix.schemaVersion -ne 2 -or @($matrix.scenarios).Count -ne 17) { throw 'FTK-04B scenario contract drifted.' }
if ($ValidateOnly) {
    if ($Real21st) {
        $validation = & $harnessPath -ValidateOnly -Real21st
    } else {
        $validation = & $harnessPath -ValidateOnly
    }
    if ($validation.ScenarioCount -ne 17 -or @($validation.TwentyFirstTools) -cne @('search')) { throw 'FTK-04B validate-only contract failed.' }
    Write-Output ('PASS: FTK-04B {0} harness, search-only routing and teardown contracts validated without behavioral reruns.' -f $validation.Mode)
    return
}

if ($Real21st) {
    if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST','Process'))) { throw 'FTK-04B real E2E mode requires the externally supplied 21st credential.' }
    $result = & $harnessPath -Real21st
    if ($result.ScenariosPassed -ne 10) { throw 'Not all FTK-04B real E2E scenarios passed.' }
    if ($result.PaidOrMutableCalls -ne 0 -or $result.FixtureMutation -notin @('none','ephemeral-only-cleaned') -or $result.FixtureTeardown -ne 'complete' -or $result.PersistentMutation -ne 'none') { throw 'FTK-04B real E2E reported a forbidden effect or incomplete teardown.' }
    Write-Output 'PASS: ten versioned scenarios routed in explicit real E2E mode with minimum necessary capabilities.'
    Write-Output 'PASS: real E2E remained opt-in; 21st stayed search-only and all paid/mutable operations stayed blocked.'
    Write-Output 'REAL 21ST CALLS=1 search scenario family; no generation, quota, mutation or unknown tool call.'
    return
}

$result = & $harnessPath
if ($result.Mode -ne 'hermetic' -or $result.ScenariosPassed -ne 10) { throw 'Hermetic FTK-04B routing contract did not pass all scenarios.' }
if (@($result.TwentyFirstTools) -cne @('search') -or $result.Real21stCalls -ne 0 -or $result.PaidOrMutableCalls -ne 0 -or $result.PersistentMutation -ne 0 -or $result.FixtureTeardown -ne 'complete' -or $result.UnknownTool -ne 'fail-closed' -or $result.NetworkAssertion -ne 'remote-transport-not-started') {
    throw 'Hermetic FTK-04B reported a forbidden capability, effect or incomplete assertion.'
}

Write-Output 'ROUTING: PASS'
Write-Output 'PASS: ten versioned routing contracts validated hermetically with minimum necessary capabilities.'
Write-Output 'PASS: 21st/search is the only selectable tool; generation, quota, mutation and unknown tools fail closed.'
Write-Output 'PASS: production credential gate remains preserved; no API key or remote 21st transport was required.'
Write-Output 'REAL 21ST CALLS=0; PERSISTENT MUTATION=0; FIXTURE CLEANUP=complete.'
