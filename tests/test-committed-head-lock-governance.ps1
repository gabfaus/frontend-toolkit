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
    'A persistent lock entered the payload it measures',
    'Read-PersistentLockDocument',
    'persistentLocksMatchCandidate',
    'lockUpdateRequired',
    'validated-pending-freeze',
    'locked-current-candidate',
    'torn-lock-state',
    'RequireLockedCurrentCandidate'
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
        $evidence.independentBuildCount -ne 2 -or $evidence.applied -ne $false -or
        $evidence.persistentLocksUnchanged -ne $true) {
        throw 'Committed-HEAD evidence contract drifted.'
    }
    if ($evidence.buildOnePluginTreeSha256 -cne $evidence.buildTwoPluginTreeSha256 -or
        $evidence.buildOneArtifactTreeSha256 -cne $evidence.buildTwoArtifactTreeSha256 -or
        -not $evidence.manifestsEqual -or -not $evidence.zipInventoriesEqual -or -not $evidence.inventoryValidated) {
        throw 'Independent committed-HEAD evidence did not agree.'
    }
    $expectedPlugin = '23c74faed4153944732e900195a62e09fc9240366fb5bfca2285d985df4c78bc'
    $expectedArtifact = 'f81fec8cb9875cf6f14170211420bbea8963e1fb91093a001bf54777b9170f1f'
    $expectedZip = 'eeccc19f6965578104626ab0c685335470a6446fa888dd0a5e1495ee7d5b24de'
    if ($evidence.candidatePluginTreeSha256 -cne $expectedPlugin -or
        $evidence.candidateArtifactTreeSha256 -cne $expectedArtifact -or
        $evidence.candidateZipSha256 -cne $expectedZip) {
        throw 'Committed-HEAD candidate identity drifted.'
    }
    if ($evidence.candidatePluginTreeSha256 -notmatch '^[0-9a-f]{64}$' -or
        $evidence.candidateArtifactTreeSha256 -notmatch '^[0-9a-f]{64}$' -or
        $evidence.candidateZipSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Committed-HEAD candidate identity is invalid.'
    }
    if ($evidence.persistentLocksMatchCandidate -ne $true -or
        $evidence.lockUpdateRequired -ne $false -or
        $evidence.lockState -cne 'locked-current-candidate') {
        throw 'Frozen locks were not reported as LOCKED_CURRENT_CANDIDATE.'
    }
    $fixtureLocks = Join-Path $fixture 'locks'
    New-Item -ItemType Directory -Path $fixtureLocks -Force | Out-Null
    $fixtureDistributionPath = Join-Path $fixtureLocks 'distribution.lock.json'
    $fixtureReleasePath = Join-Path $fixtureLocks 'release.lock.json'
    Copy-Item -LiteralPath $distributionPath -Destination $fixtureDistributionPath
    Copy-Item -LiteralPath $releasePath -Destination $fixtureReleasePath
    $history = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/release-history.json') | ConvertFrom-Json
    $historical = @($history.releases | Where-Object version -CEQ '1.1.0')[0]

    function Write-FixtureJson {
        param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Document)
        [IO.File]::WriteAllText($Path, (($Document | ConvertTo-Json -Depth 20) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    }

    $tornDistribution = Get-Content -Raw -LiteralPath $fixtureDistributionPath | ConvertFrom-Json
    $tornRelease = Get-Content -Raw -LiteralPath $fixtureReleasePath | ConvertFrom-Json
    $tornDistribution.observedSnapshotTreeSha256 = $historical.persistentPluginTreeSha256
    $tornRelease.observedArtifactTreeSha256 = $historical.persistentArtifactTreeSha256
    Write-FixtureJson -Path $fixtureDistributionPath -Document $tornDistribution
    Write-FixtureJson -Path $fixtureReleasePath -Document $tornRelease
    $tornRejected = $false
    try {
        & $reconciler -SourceMode CommittedHead -ExpectedCommit $head -DistributionLockPath $fixtureDistributionPath -ReleaseLockPath $fixtureReleasePath | Out-Null
    } catch {
        $tornRejected = $_.Exception.Message -match 'TORN_LOCK_STATE|partially or inconsistently'
    }
    if (-not $tornRejected) { throw 'Synthetic torn lock state was accepted.' }

    $malformedRelease = Get-Content -Raw -LiteralPath $fixtureReleasePath | ConvertFrom-Json
    $malformedRelease.observedArtifactTreeSha256 = 'invalid'
    Write-FixtureJson -Path $fixtureReleasePath -Document $malformedRelease
    $malformedRejected = $false
    try {
        & $reconciler -SourceMode CommittedHead -ExpectedCommit $head -DistributionLockPath $fixtureDistributionPath -ReleaseLockPath $fixtureReleasePath | Out-Null
    } catch {
        $malformedRejected = $_.Exception.Message -match 'valid lowercase SHA-256|unexpected governance structure|not valid JSON'
    }
    if (-not $malformedRejected) { throw 'Synthetic malformed lock state was accepted.' }

    $mixedVersionDistribution = Get-Content -Raw -LiteralPath $fixtureDistributionPath | ConvertFrom-Json
    $mixedVersionRelease = Get-Content -Raw -LiteralPath $fixtureReleasePath | ConvertFrom-Json
    $mixedVersionDistribution.observedSnapshotTreeSha256 = $expectedPlugin
    $mixedVersionRelease.observedPluginTreeSha256 = $expectedPlugin
    $mixedVersionRelease.observedArtifactTreeSha256 = $expectedArtifact
    $mixedVersionRelease.candidateVersion = '9.9.9'
    Write-FixtureJson -Path $fixtureDistributionPath -Document $mixedVersionDistribution
    Write-FixtureJson -Path $fixtureReleasePath -Document $mixedVersionRelease
    $mixedVersionRejected = $false
    try {
        & $reconciler -SourceMode CommittedHead -ExpectedCommit $head -DistributionLockPath $fixtureDistributionPath -ReleaseLockPath $fixtureReleasePath | Out-Null
    } catch {
        $mixedVersionRejected = $_.Exception.Message -match 'TORN_LOCK_STATE|partially or inconsistently'
    }
    if (-not $mixedVersionRejected) { throw 'Synthetic mixed version/identity state was accepted.' }

    $pendingDistribution = Get-Content -Raw -LiteralPath $distributionPath | ConvertFrom-Json
    $pendingRelease = Get-Content -Raw -LiteralPath $releasePath | ConvertFrom-Json
    $pendingDistribution.observedSnapshotTreeSha256 = $historical.persistentPluginTreeSha256
    $pendingRelease.observedPluginTreeSha256 = $historical.persistentPluginTreeSha256
    $pendingRelease.observedArtifactTreeSha256 = $historical.persistentArtifactTreeSha256
    Write-FixtureJson -Path $fixtureDistributionPath -Document $pendingDistribution
    Write-FixtureJson -Path $fixtureReleasePath -Document $pendingRelease
    $pendingEvidence = & $reconciler -SourceMode CommittedHead -ExpectedCommit $head -DistributionLockPath $fixtureDistributionPath -ReleaseLockPath $fixtureReleasePath
    if ($pendingEvidence.lockState -cne 'validated-pending-freeze' -or
        $pendingEvidence.persistentLocksMatchCandidate -ne $false -or
        $pendingEvidence.lockUpdateRequired -ne $true) {
        throw 'Coherent historical fixture was not reported as VALIDATED_PENDING_FREEZE.'
    }
    $lockedDistribution = Get-Content -Raw -LiteralPath $distributionPath | ConvertFrom-Json
    $lockedRelease = Get-Content -Raw -LiteralPath $releasePath | ConvertFrom-Json
    $lockedDistribution.observedSnapshotTreeSha256 = $expectedPlugin
    $lockedRelease.observedPluginTreeSha256 = $expectedPlugin
    $lockedRelease.observedArtifactTreeSha256 = $expectedArtifact
    $lockedRelease.candidateVersion = $evidence.candidateVersion
    Write-FixtureJson -Path $fixtureDistributionPath -Document $lockedDistribution
    Write-FixtureJson -Path $fixtureReleasePath -Document $lockedRelease
    $lockedEvidence = & $reconciler -SourceMode CommittedHead -ExpectedCommit $head -DistributionLockPath $fixtureDistributionPath -ReleaseLockPath $fixtureReleasePath -RequireLockedCurrentCandidate
    if ($lockedEvidence.lockState -cne 'locked-current-candidate' -or
        $lockedEvidence.persistentLocksMatchCandidate -ne $true -or
        $lockedEvidence.lockUpdateRequired -ne $false) {
        throw 'Explicit LOCKED_CURRENT_CANDIDATE contract drifted.'
    }

    Write-Output "PASS: DevelopmentWorkingTree produced diagnostic candidate $diagnosticHash without persistent lock writes."
    Write-Output 'PASS: DevelopmentWorkingTree lock persistence failed closed and left both locks unchanged.'
    Write-Output "PASS: two committed-HEAD builds agreed at plugin $($evidence.candidatePluginTreeSha256), artifact $($evidence.candidateArtifactTreeSha256) and ZIP $($evidence.candidateZipSha256)."
    Write-Output 'PASS: frozen locks report LOCKED_CURRENT_CANDIDATE; historical fixture reports VALIDATED_PENDING_FREEZE.'
    Write-Output 'PASS: torn and malformed lock fixtures failed closed; explicit LOCKED_CURRENT_CANDIDATE was accepted only when fully aligned.'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true)
    }
}
if (Test-Path -LiteralPath $fixture) { throw 'Lock governance fixture teardown failed.' }
