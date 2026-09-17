Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')

function Assert-NativeSuccess {
    param([Parameter(Mandatory)][string]$Operation)
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Write-Utf8Lf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value
    )
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Value.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Expand-CanonicalSource {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string[]]$Paths
    )
    $archive = Join-Path (Split-Path $Destination) ((Split-Path $Destination -Leaf) + '.tar')
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Export-CanonicalGitFiles -Repository $Repository -Commit 'HEAD' -DestinationArchive $archive -Paths $Paths
    & tar -xf $archive -C $Destination
    Assert-NativeSuccess 'Canonical fixture extraction'
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-adapter-integrity-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'source'
$clone = Join-Path $fixture 'clone'
$first = Join-Path $fixture 'first'
$second = Join-Path $fixture 'second'
$changed = Join-Path $fixture 'changed'
$snapshot = Join-Path $fixture 'snapshot'
$adapterPaths = @(
    'plugin/frontend-toolkit/skills/impeccable/SKILL.md'
    'plugin/frontend-toolkit/skills/img2threejs/SKILL.md'
)
$securityPaths = @(
    'plugin/frontend-toolkit/security/img2threejs-state-guard.ps1'
    'plugin/frontend-toolkit/security/img2threejs-structural-validation.ps1'
)
$fixturePaths = @($adapterPaths + $securityPaths)

try {
    New-Item -ItemType Directory -Path $source | Out-Null
    git -C $source init --quiet --initial-branch=main
    Assert-NativeSuccess 'Fixture repository initialization'
    Write-Utf8Lf -Path (Join-Path $source $adapterPaths[0]) -Value "# Impeccable fixture`n`nCommitted LF bytes.`n"
    Write-Utf8Lf -Path (Join-Path $source $adapterPaths[1]) -Value "# img2threejs fixture`n`nCommitted LF bytes.`n"
    $lf = [string][char]10
    Write-Utf8Lf -Path (Join-Path $source $securityPaths[0]) -Value ("function Test-StateGuardFixture {" + $lf + "    return 'committed LF'" + $lf + "}" + $lf)
    Write-Utf8Lf -Path (Join-Path $source $securityPaths[1]) -Value ("function Test-StructuralFixture {" + $lf + "    return 'committed LF'" + $lf + "}" + $lf)
    git -C $source add -- $fixturePaths
    Assert-NativeSuccess 'Fixture staging'
    git -C $source -c user.name='Frontend Toolkit Test' -c user.email='fixture@example.invalid' commit --quiet -m 'fixture: committed adapters'
    Assert-NativeSuccess 'Fixture commit'

    git -c core.autocrlf=true clone --quiet --no-hardlinks $source $clone
    Assert-NativeSuccess 'Clean fixture clone'
    git -C $clone config core.autocrlf true
    git -C $clone checkout --force --quiet HEAD
    Assert-NativeSuccess 'CRLF fixture checkout'
    if (git -C $clone status --porcelain) { throw 'Fixture clone is not clean at HEAD.' }

    $dependencies = @(
        [pscustomobject]@{
            id = 'impeccable'
            distributionAdapterPath = 'skills/impeccable'
            adapterEntrySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source $adapterPaths[0])).Hash.ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'img2threejs'
            distributionAdapterPath = 'skills/img2threejs'
            adapterEntrySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source $adapterPaths[1])).Hash.ToLowerInvariant()
        }
    )

    Expand-CanonicalSource -Repository $clone -Destination $first -Paths $fixturePaths
    Assert-AdapterEntryIntegrity -Root (Join-Path $first 'plugin/frontend-toolkit') -Dependencies $dependencies

    foreach ($path in $fixturePaths) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $clone $path))
        if (-not (([Text.Encoding]::UTF8.GetString($bytes)).Contains("`r`n"))) {
            throw "Fixture did not exercise a CRLF worktree: $path"
        }
    }
    Expand-CanonicalSource -Repository $clone -Destination $second -Paths $fixturePaths
    Assert-AdapterEntryIntegrity -Root (Join-Path $second 'plugin/frontend-toolkit') -Dependencies $dependencies
    foreach ($dependency in $dependencies) {
        $firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $first ('plugin/frontend-toolkit/' + $dependency.distributionAdapterPath + '/SKILL.md'))).Hash
        $secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $second ('plugin/frontend-toolkit/' + $dependency.distributionAdapterPath + '/SKILL.md'))).Hash
        if ($firstHash -cne $secondHash) { throw "$($dependency.id) canonical export depends on worktree line endings." }
    }
    $firstTreeHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root (Join-Path $first 'plugin/frontend-toolkit'))
    $secondTreeHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root (Join-Path $second 'plugin/frontend-toolkit'))
    if ($firstTreeHash -cne $secondTreeHash) {
        throw 'Canonical plugin evidence depends on adapter or security-module worktree line endings.'
    }

    $staleDependencies = @($dependencies | ForEach-Object {
        [pscustomobject]@{ id = $_.id; distributionAdapterPath = $_.distributionAdapterPath; adapterEntrySha256 = $_.adapterEntrySha256 }
    })
    $staleDependencies[0].adapterEntrySha256 = ('0' * 64)
    $staleRejected = $false
    try { Assert-AdapterEntryIntegrity -Root (Join-Path $first 'plugin/frontend-toolkit') -Dependencies $staleDependencies } catch { $staleRejected = $true }
    if (-not $staleRejected) { throw 'A stale adapter hash was accepted.' }

    Write-Utf8Lf -Path (Join-Path $clone $adapterPaths[1]) -Value "# img2threejs fixture`n`nCommitted bytes changed for integrity testing.`n"
    git -C $clone add -- $adapterPaths[1]
    Assert-NativeSuccess 'Changed adapter staging'
    git -C $clone -c user.name='Frontend Toolkit Test' -c user.email='fixture@example.invalid' commit --quiet -m 'fixture: change adapter bytes'
    Assert-NativeSuccess 'Changed adapter commit'
    Expand-CanonicalSource -Repository $clone -Destination $changed -Paths $fixturePaths
    $changeRejected = $false
    try { Assert-AdapterEntryIntegrity -Root (Join-Path $changed 'plugin/frontend-toolkit') -Dependencies $dependencies } catch { $changeRejected = $true }
    if (-not $changeRejected) { throw 'A real committed adapter byte change was accepted.' }

    $releaseLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/release.lock.json') | ConvertFrom-Json
    $distributionLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/distribution.lock.json') | ConvertFrom-Json
    $history = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/release-history.json') | ConvertFrom-Json
    $historical = @($history.releases | Where-Object version -CEQ '1.1.0')[0]
    if ($releaseLock.candidateVersion -cne '1.3.0' -or
        $releaseLock.observedPluginTreeSha256 -ceq $historical.persistentPluginTreeSha256 -or
        $distributionLock.observedSnapshotTreeSha256 -ceq $historical.persistentPluginTreeSha256 -or
        $releaseLock.observedArtifactTreeSha256 -ceq $historical.persistentArtifactTreeSha256) {
        throw 'Current v1.3 locks overwrote history or remain on the historical v1.1 identities.'
    }

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1') -Destination $snapshot -DevelopmentWorkingTree | Out-Null
    Assert-NativeSuccess 'Current v1.3 candidate plugin snapshot build'
    $realLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
    Assert-AdapterEntryIntegrity -Root $snapshot -Dependencies @($realLock.dependencies)
    $candidateTreeHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root $snapshot)

    Write-Output 'PASS: clean CRLF clone exports canonical committed LF bytes for adapters, state guard and structural validator.'
    Write-Output 'PASS: committed adapter changes and stale expected hashes fail closed.'
    Write-Output "PASS: historical v1.1 identities remain immutable in integrations/release-history.json."
    Write-Output "PASS: current v1.3 candidate tree validates at $candidateTreeHash; this is pre-final evidence only."
} finally {
    if (Test-Path -LiteralPath $fixture) {
        Get-ChildItem -LiteralPath $fixture -Recurse -Force | ForEach-Object {
            $_.Attributes = [IO.FileAttributes]::Normal
        }
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true)
    }
}
