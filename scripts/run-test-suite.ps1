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

$externalPrerequisiteReady = $true
$externalPrerequisiteState = 'READY'
$externalPrerequisiteDetails = ''
try {
    Assert-FtkExternalPrerequisite
    Write-Output 'PREFLIGHT external: PASS (both pinned, clean checkouts validated without network).'
} catch {
    $externalPrerequisiteReady = $false
    $externalPrerequisiteDetails = (($_ | Out-String).Trim() -replace '\s+', ' ')
    $externalPrerequisiteState = if ($externalPrerequisiteDetails -match 'EXTERNAL_PREREQUISITE_MISSING') { 'EXTERNAL_PREREQUISITE_MISSING' } else { 'EXTERNAL_PREREQUISITE_INVALID' }
    Write-Output ("PREFLIGHT external: {0}; prepared-integration cases remain NOT_RUN. {1}" -f $externalPrerequisiteState, $externalPrerequisiteDetails)
}

$cases = @(
    [pscustomobject]@{ Name = 'impeccable execution robustness'; Path = 'tests/test-impeccable-execution-robustness.ps1'; Arguments = @(); Classification = 'SELF_MATERIALIZING' }
    [pscustomobject]@{ Name = 'impeccable effects mediation'; Path = 'tests/test-impeccable-effects-mediation.ps1'; Arguments = @(); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'impeccable integrated boundary'; Path = 'tests/test-impeccable-integrated-boundary.ps1'; Arguments = @(); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'impeccable authority boundary'; Path = 'tests/test-impeccable-authority-boundary.ps1'; Arguments = @(); Classification = 'HERMETIC' }
    [pscustomobject]@{ Name = 'impeccable detector capability'; Path = 'tests/test-impeccable-detector-capability.ps1'; Arguments = @(); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'impeccable static HTML golden'; Path = 'tests/test-impeccable-static-html-golden.ps1'; Arguments = @(); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'frontend orchestrator'; Path = 'tests/test-frontend-orchestrator.ps1'; Arguments = @(); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'routing v3'; Path = 'tests/test-routing-v3.ps1'; Arguments = @(); Classification = 'HERMETIC' }
    [pscustomobject]@{ Name = 'plugin security'; Path = 'tests/test-plugin-security.ps1'; Arguments = @('-ExpectKnownBlockers'); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'plugin packaging'; Path = 'tests/test-plugin-packaging.ps1'; Arguments = @(); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'plugin distribution'; Path = 'tests/test-plugin-distribution.ps1'; Arguments = @('-ValidateOnly'); Classification = 'VALIDATE_ONLY' }
    [pscustomobject]@{ Name = 'release safety'; Path = 'tests/test-release-safety.ps1'; Arguments = @(); Classification = 'VALIDATE_ONLY' }
    [pscustomobject]@{ Name = 'security inventory consistency'; Path = 'tests/test-security-inventory-consistency.ps1'; Arguments = @(); Classification = 'VALIDATE_ONLY' }
    [pscustomobject]@{ Name = 'FTK09J convergence'; Path = 'tests/test-ftk09j-convergence.ps1'; Arguments = @(); Classification = 'VALIDATE_ONLY' }
    [pscustomobject]@{ Name = 'plugin hardening'; Path = 'tests/test-plugin-hardening.ps1'; Arguments = @(); Classification = 'PREPARED_INTEGRATION' }
    [pscustomobject]@{ Name = 'design motion Phase 1'; Path = 'tests/test-design-motion-phase1.ps1'; Arguments = @(); Classification = 'HERMETIC' }
    [pscustomobject]@{ Name = 'browser QA'; Path = 'tests/test-browser-qa.ps1'; Arguments = @(); Classification = 'HERMETIC' }
    [pscustomobject]@{ Name = 'img2threejs procedural Phase 1'; Path = 'tests/test-img2threejs-procedural-contract.ps1'; Arguments = @(); Classification = 'HERMETIC' }
)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($case in $cases) {
    $path = Join-Path $repoRoot $case.Path
    $classification = [string]$case.Classification
    Write-Output ("RUN {0}: {1} classification={2}" -f $case.Name, $case.Path, $classification)
    if (-not $externalPrerequisiteReady -and $classification -eq 'PREPARED_INTEGRATION') {
        Write-Output ("RESULT {0}: NOT_RUN classification={1} prerequisite={2}" -f $case.Name, $classification, $externalPrerequisiteState)
        [void]$results.Add([pscustomobject]@{
                Name = $case.Name
                Path = $case.Path
                Classification = $classification
                Status = 'NOT_RUN'
                EvidenceState = $externalPrerequisiteState
                ExitCode = $null
            })
        continue
    }
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
    $joinedOutput = ((@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) -replace '\s+', ' ').Trim()
    $evidenceState = if ($joinedOutput -match '\bNOT_MATERIALIZED\b') {
        'NOT_MATERIALIZED'
    } elseif ($joinedOutput -match '\bPENDING_ENVIRONMENT\b') {
        'PENDING_ENVIRONMENT'
    } elseif ($joinedOutput -match '\bREGISTERED_NO_HANDLER\b') {
        'REGISTERED_NO_HANDLER'
    } elseif ($joinedOutput -match '\bUNAVAILABLE\b') {
        'UNAVAILABLE'
    } elseif ($joinedOutput -match '\bBLOCKED\b') {
        'BLOCKED'
    } else {
        'NONE'
    }
    Write-Output ("RESULT {0}: {1} classification={2} evidenceState={3} exit={4}" -f $case.Name, $status, $classification, $evidenceState, $exitCode)
    [void]$results.Add([pscustomobject]@{
            Name = $case.Name
            Path = $case.Path
            Classification = $classification
            Status = $status
            EvidenceState = $evidenceState
            ExitCode = $exitCode
        })
}

$passed = @($results | Where-Object Status -eq 'PASS')
$failed = @($results | Where-Object Status -eq 'FAIL')
$notRun = @($results | Where-Object Status -eq 'NOT_RUN')
$notMaterialized = @($results | Where-Object EvidenceState -eq 'NOT_MATERIALIZED')
$pendingEnvironment = @($results | Where-Object EvidenceState -eq 'PENDING_ENVIRONMENT')
Write-Output ("SUMMARY: {0}/{1} PASS; failures={2}; notRun={3}; notMaterialized={4}; pendingEnvironment={5}" -f $passed.Count, $results.Count, $failed.Count, $notRun.Count, $notMaterialized.Count, $pendingEnvironment.Count)
if ($failed.Count -or $notRun.Count) {
    Write-Output ("FAILED TESTS: {0}" -f (($failed | ForEach-Object { "$($_.Name) (exit=$($_.ExitCode))" }) -join ', '))
    if ($notRun.Count) {
        Write-Output ("NOT RUN: {0}" -f (($notRun | ForEach-Object { "$($_.Name) [$($_.EvidenceState)]" }) -join ', '))
    }
    throw 'Official FTK suite did not complete; dependency/environment states remain distinct from PASS.'
}

Write-Output ("PASS: official FTK external suite completed with {0}/{0} tests PASS." -f $results.Count)
