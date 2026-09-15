[CmdletBinding()]
param(
    [switch]$PrepareExternal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$syncScript = Join-Path $repoRoot 'scripts/sync-external-skills.ps1'
. (Join-Path $repoRoot 'tests/helpers/external-prerequisite.ps1')

if ($PrepareExternal) {
    Write-Output 'PREPARE external: invoking the governed synchronization script.'
    $prepareOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript 2>&1)
    $prepareExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    foreach ($line in $prepareOutput) { Write-Output ([string]$line) }
    if ($prepareExitCode -ne 0) {
        throw "External preparation failed with exit code $prepareExitCode. No suite test was reported as PASS."
    }
} else {
    Write-Output 'PREPARE external: skipped; no network-capable preparation was requested.'
}

Assert-FtkExternalPrerequisite
Write-Output 'PREFLIGHT external: PASS (both pinned, clean checkouts validated without network).'

$cases = @(
    [pscustomobject]@{ Name = 'impeccable execution robustness'; Path = 'tests/test-impeccable-execution-robustness.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'impeccable effects mediation'; Path = 'tests/test-impeccable-effects-mediation.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'impeccable integrated boundary'; Path = 'tests/test-impeccable-integrated-boundary.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'impeccable authority boundary'; Path = 'tests/test-impeccable-authority-boundary.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'impeccable detector capability'; Path = 'tests/test-impeccable-detector-capability.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'impeccable static HTML golden'; Path = 'tests/test-impeccable-static-html-golden.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'frontend orchestrator'; Path = 'tests/test-frontend-orchestrator.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'routing v3'; Path = 'tests/test-routing-v3.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'plugin security'; Path = 'tests/test-plugin-security.ps1'; Arguments = @('-ExpectKnownBlockers') }
    [pscustomobject]@{ Name = 'plugin packaging'; Path = 'tests/test-plugin-packaging.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'plugin distribution'; Path = 'tests/test-plugin-distribution.ps1'; Arguments = @('-ValidateOnly') }
    [pscustomobject]@{ Name = 'release safety'; Path = 'tests/test-release-safety.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'security inventory consistency'; Path = 'tests/test-security-inventory-consistency.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'FTK09J convergence'; Path = 'tests/test-ftk09j-convergence.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'plugin hardening'; Path = 'tests/test-plugin-hardening.ps1'; Arguments = @() }
)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($case in $cases) {
    $path = Join-Path $repoRoot $case.Path
    Write-Output ("RUN {0}: {1}" -f $case.Name, $case.Path)
    $output = @()
    $exitCode = 0
    try {
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @($case.Arguments) 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $exitCode = 1
        $output += $_.Exception.Message
    }
    foreach ($line in $output) { Write-Output ([string]$line) }
    $status = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    Write-Output ("RESULT {0}: {1} exit={2}" -f $case.Name, $status, $exitCode)
    [void]$results.Add([pscustomobject]@{ Name = $case.Name; Path = $case.Path; Status = $status; ExitCode = $exitCode })
}

$passed = @($results | Where-Object Status -eq 'PASS')
$failed = @($results | Where-Object Status -eq 'FAIL')
Write-Output ("SUMMARY: {0}/{1} PASS; failures={2}" -f $passed.Count, $results.Count, $failed.Count)
if ($failed.Count) {
    Write-Output ("FAILED TESTS: {0}" -f (($failed | ForEach-Object { "$($_.Name) (exit=$($_.ExitCode))" }) -join ', '))
    throw 'Official FTK suite failed; no dependency failure was converted into PASS.'
}

Write-Output ("PASS: official FTK external suite completed with {0}/{0} tests PASS." -f $results.Count)
