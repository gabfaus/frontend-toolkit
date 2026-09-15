Set-StrictMode -Version Latest

function Get-FtkExternalValidationText {
    param([AllowNull()][object[]]$Output)
    return ((@($Output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ') -replace '\s+', ' ').Trim()
}

function Assert-FtkExternalPrerequisite {
    [CmdletBinding()]
    param()
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $syncScript = Join-Path $repoRoot 'scripts/sync-external-skills.ps1'
    $validationOutput = @()
    $exitCode = 0
    try {
        $validationOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncScript -ValidateOnly 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $exitCode = 1
        $validationOutput += $_.Exception.Message
    }
    if ($exitCode -eq 0) { return }
    $details = Get-FtkExternalValidationText $validationOutput
    $classification = if ($details -match '(?i)Missing checkout') { 'EXTERNAL_PREREQUISITE_MISSING' } else { 'EXTERNAL_PREREQUISITE_INVALID' }
    $prepareCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-external-skills.ps1'
    $runnerCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-test-suite.ps1 -PrepareExternal'
    $guidance = if ($classification -ceq 'EXTERNAL_PREREQUISITE_MISSING') {
        "pinned external Skills are absent. Prepare them via governed synchronization: {0} or the official runner with explicit preparation: {1}." -f $prepareCommand, $runnerCommand
    } else {
        'pinned external Skills are invalid. Restore or correct the governed checkout and rerun validation; this test does not auto-correct wrong SHA, dirty worktree, wrong origin, or other invalid state.'
    }
    throw ("{0}: {1} This test does not start network preparation. Validation details: {2}" -f $classification, $guidance, $details)
}
