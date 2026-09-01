Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$reconciler = Join-Path $repoRoot 'scripts/reconcile-committed-head-locks.ps1'
$distributionPath = Join-Path $repoRoot 'integrations/distribution.lock.json'
$releasePath = Join-Path $repoRoot 'integrations/release.lock.json'
$snapshotBuilder = Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1'
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw 'Committed HEAD could not be resolved.' }
if (-not (Test-Path -LiteralPath $reconciler -PathType Leaf)) { throw 'Committed-HEAD lock reconciler is missing.' }

$scriptText = Get-Content -Raw -LiteralPath $reconciler
foreach ($required in @(
    'SourceMode',
    'CommittedHead',
    'DevelopmentWorkingTree is diagnostic-only',
    'ExpectedCommit',
    'independentBuildCount',
    'Set-JsonHashProperty',
    'A persistent lock entered the payload it measures'
)) {
    if ($scriptText -notmatch [regex]::Escape($required)) { throw "Lock governance contract is missing: $required" }
}
if ($scriptText -match '&\s+\$builder[^\r\n]*DevelopmentWorkingTree') {
    throw 'Lock reconciler can pass DevelopmentWorkingTree to the release builder.'
}

$beforeDistribution = (Get-FileHash -Algorithm SHA256 -LiteralPath $distributionPath).Hash
$beforeRelease = (Get-FileHash -Algorithm SHA256 -LiteralPath $releasePath).Hash
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-lock-governance-' + [guid]::NewGuid().ToString('N'))
$diagnostic = Join-Path $fixture 'diagnostic'
try {
    & $snapshotBuilder -Destination $diagnostic -DevelopmentWorkingTree | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $diagnostic 'SNAPSHOT_PROVENANCE.json'))) {
        throw 'DevelopmentWorkingTree diagnostic candidate failed.'
    }
    $diagnosticHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root $diagnostic)
    if ($diagnosticHash -notmatch '^[0-9a-f]{64}$') { throw 'Diagnostic candidate did not produce a valid diagnostic hash.' }

    $rejected = $false
    try {
        & $reconciler -SourceMode DevelopmentWorkingTree -ExpectedCommit $head -Apply | Out-Null
    } catch {
        $rejected = $_.Exception.Message -match 'diagnostic-only'
    }
    if (-not $rejected) { throw 'DevelopmentWorkingTree was accepted for persistent lock reconciliation.' }
    if ($beforeDistribution -cne (Get-FileHash -Algorithm SHA256 -LiteralPath $distributionPath).Hash -or
        $beforeRelease -cne (Get-FileHash -Algorithm SHA256 -LiteralPath $releasePath).Hash) {
        throw 'Rejected DevelopmentWorkingTree reconciliation changed a persistent lock.'
    }

    $evidence = & $reconciler -SourceMode CommittedHead -ExpectedCommit $head
    if ($evidence.sourceMode -cne 'CommittedHead' -or $evidence.sourceCommit -cne $head -or
        $evidence.independentBuildCount -ne 2 -or $evidence.applied -ne $false) {
        throw 'Committed-HEAD evidence contract drifted.'
    }
    if ($evidence.buildOnePluginTreeSha256 -cne $evidence.buildTwoPluginTreeSha256 -or
        $evidence.buildOneArtifactTreeSha256 -cne $evidence.buildTwoArtifactTreeSha256 -or
        -not $evidence.manifestsEqual -or -not $evidence.zipInventoriesEqual -or -not $evidence.inventoryValidated) {
        throw 'Independent committed-HEAD evidence did not agree.'
    }
    $distribution = Get-Content -Raw -LiteralPath $distributionPath | ConvertFrom-Json
    $release = Get-Content -Raw -LiteralPath $releasePath | ConvertFrom-Json
    if ($distribution.observedSnapshotTreeSha256 -cne $evidence.buildOnePluginTreeSha256 -or
        $release.observedPluginTreeSha256 -cne $evidence.buildOnePluginTreeSha256 -or
        $release.observedArtifactTreeSha256 -cne $evidence.buildOneArtifactTreeSha256) {
        throw 'Persistent locks do not match reproduced committed-HEAD evidence.'
    }

    Write-Output "PASS: DevelopmentWorkingTree produced diagnostic candidate $diagnosticHash without persistent lock writes."
    Write-Output 'PASS: DevelopmentWorkingTree lock persistence failed closed and left both locks unchanged.'
    Write-Output "PASS: two committed-HEAD builds agreed at plugin $($evidence.buildOnePluginTreeSha256) and artifact $($evidence.buildOneArtifactTreeSha256)."
} finally {
    if (Test-Path -LiteralPath $fixture) {
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true)
    }
}
if (Test-Path -LiteralPath $fixture) { throw 'Lock governance fixture teardown failed.' }
