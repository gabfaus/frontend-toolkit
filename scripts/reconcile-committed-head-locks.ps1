[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('CommittedHead', 'DevelopmentWorkingTree')][string]$SourceMode,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
    [switch]$Apply,
    [string]$DistributionLockPath,
    [string]$ReleaseLockPath,
    [switch]$RequireLockedCurrentCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-safety.ps1')

function Assert-NativeSuccess {
    param([Parameter(Mandatory)][string]$Operation)
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Assert-EqualEvidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$First,
        [Parameter(Mandatory)]$Second
    )
    if ((ConvertTo-CanonicalJson $First) -cne (ConvertTo-CanonicalJson $Second)) {
        throw "Independent committed-HEAD builds disagree on $Name."
    }
}

function Get-ZipInventory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ZipPath
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-DeterministicZip -Root $Root -ZipPath $ZipPath
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($zip.Entries | Where-Object Name | ForEach-Object {
            $stream = $_.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                [pscustomobject][ordered]@{
                    path = $_.FullName.Replace('\', '/')
                    sha256 = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
                }
            } finally {
                $sha.Dispose()
                $stream.Dispose()
            }
        })
        return @(Sort-ArtifactEntriesOrdinal -Entries $entries)
    } finally {
        $zip.Dispose()
    }
}

function Assert-ReleaseInventory {
    param(
        [Parameter(Mandatory)][string]$CandidateRoot,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$ExternalLock
    )

    $pluginRoot = Join-Path $CandidateRoot 'plugins/frontend-toolkit'
    $skills = @(Sort-OrdinalStrings -Values @(Get-ChildItem -LiteralPath (Join-Path $pluginRoot 'skills') -Directory | ForEach-Object Name))
    $expectedSkills = @(Get-FrontendToolkitDistributionSkillAllowlist)
    Assert-ExactStringSet -Name 'Committed-HEAD Skill inventory' -Actual $skills -Expected $expectedSkills

    $mcp = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot '.mcp.json') | ConvertFrom-Json
    $mcpNames = @(Sort-OrdinalStrings -Values @($mcp.mcpServers.PSObject.Properties.Name))
    if (($mcpNames -join ',') -cne '21st,shadcn') {
        throw "Committed-HEAD MCP inventory drifted: $($mcpNames -join ',')"
    }

    $requiredSecurity = @(Get-FrontendToolkitSecurityModuleAllowlist)
    $security = @(Sort-OrdinalStrings -Values @(Get-ChildItem -LiteralPath (Join-Path $pluginRoot 'security') -File -Force | ForEach-Object Name))
    $newline = [string][char]10
    if (($security -join $newline) -cne ((Sort-OrdinalStrings -Values $requiredSecurity) -join $newline)) {
        throw 'Committed-HEAD security inventory drifted.'
    }

    $upstreams = @(Sort-OrdinalStrings -Values @(Get-ChildItem -LiteralPath (Join-Path $pluginRoot 'third_party/upstreams') -Directory | ForEach-Object Name))
    if (($upstreams -join ',') -cne 'img2threejs,impeccable') {
        throw "Committed-HEAD upstream inventory drifted: $($upstreams -join ',')"
    }

    $provenance = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot 'SNAPSHOT_PROVENANCE.json') | ConvertFrom-Json
    $adapterIds = @(Sort-OrdinalStrings -Values @($provenance.adapters.id))
    $snapshotIds = @(Sort-OrdinalStrings -Values @($provenance.upstreamSnapshots.id))
    if (($adapterIds -join ',') -cne 'img2threejs,impeccable' -or ($snapshotIds -join ',') -cne 'img2threejs,impeccable') {
        throw 'Committed-HEAD adapter/upstream provenance drifted.'
    }
    foreach ($dependency in @($ExternalLock.dependencies)) {
        $snapshot = $provenance.upstreamSnapshots | Where-Object id -CEQ $dependency.id
        if ($null -eq $snapshot -or $snapshot.commitSha -cne $dependency.commitSha -or $snapshot.treeSha256 -cne $dependency.snapshotTreeSha256) {
            throw "Committed-HEAD upstream pin drifted: $($dependency.id)"
        }
    }

    $manifestPaths = @(Sort-OrdinalStrings -Values @($Manifest.artifactFiles.path))
    if ($manifestPaths -contains 'integrations/distribution.lock.json' -or $manifestPaths -contains 'integrations/release.lock.json') {
        throw 'A persistent lock entered the payload it measures.'
    }
}

function Set-JsonHashProperty {
    param(
        [Parameter(Mandatory)][string]$JsonText,
        [Parameter(Mandatory)][string]$Property,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Value
    )
    $pattern = '("' + [regex]::Escape($Property) + '"\s*:\s*")([0-9a-f]{64})(")'
    $regex = [regex]::new($pattern)
    if ($regex.Matches($JsonText).Count -ne 1) {
        throw "Persistent lock property is missing or ambiguous: $Property"
    }
    return $regex.Replace($JsonText, { param($match) $match.Groups[1].Value + $Value + $match.Groups[3].Value }, 1)
}

function Assert-RequiredJsonProperties {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string[]]$Properties
    )

    $available = @($Document.PSObject.Properties.Name)
    if (-not $available.Count) { throw "$Context has an unexpected JSON structure." }
    foreach ($property in $Properties) {
        if ($property -notin $available) { throw "$Context is missing required property: $property" }
    }
}

function Assert-LockSha256 {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)]$Value
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context is not a valid lowercase SHA-256 identity."
    }
}

function Read-PersistentLockDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Distribution', 'Release')][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Kind persistent lock is missing: $Path"
    }
    try {
        $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        throw "$Kind persistent lock is not valid JSON: $Path"
    }
    if ($null -eq $document) { throw "$Kind persistent lock is empty: $Path" }

    if ($Kind -eq 'Distribution') {
        Assert-RequiredJsonProperties -Document $document -Context 'Distribution lock' -Properties @(
            'schemaVersion', 'strategy', 'architecture', 'generator', 'externalLock',
            'observedSnapshotTreeSha256', 'snapshotPersistence', 'sourceComposition',
            'components', 'hooksEnabled', 'twentyFirstAutomaticTools'
        )
        if ($document.schemaVersion -ne 2 -or
            $document.strategy -cne 'mediated-adapter-generated-snapshots' -or
            $document.architecture -cne 'ftk-owned-mediated-adapter' -or
            $document.generator -cne 'scripts/build-plugin-snapshot.ps1' -or
            $document.externalLock -cne 'integrations/external.lock.json' -or
            $document.snapshotPersistence -cne 'ephemeral-only' -or
            $document.hooksEnabled -ne $false -or
            (@($document.twentyFirstAutomaticTools) -join ',') -cne 'search') {
            throw 'Distribution lock contains an unexpected governance structure.'
        }
        Assert-LockSha256 -Context 'Distribution lock observedSnapshotTreeSha256' -Value $document.observedSnapshotTreeSha256
        Assert-RequiredJsonProperties -Document $document.sourceComposition -Context 'Distribution lock sourceComposition' -Properties @(
            'strategy', 'unexpectedFilesystemEntries', 'sensitivePathDefense', 'enumeration'
        )
        if ($document.sourceComposition.strategy -cne 'git-head-explicit-file-allowlist' -or
            $document.sourceComposition.unexpectedFilesystemEntries -cne 'fail' -or
            $document.sourceComposition.sensitivePathDefense -cne 'fail' -or
            $document.sourceComposition.enumeration -cne 'all-files-force') {
            throw 'Distribution lock source composition is unexpected.'
        }
        $components = @($document.components)
        $componentIds = @(Sort-OrdinalStrings -Values @($components | ForEach-Object id))
        if ($components.Count -ne 2 -or ($componentIds -join ',') -cne 'img2threejs,impeccable') {
            throw 'Distribution lock component structure is unexpected.'
        }
        foreach ($component in $components) {
            Assert-RequiredJsonProperties -Document $component -Context "Distribution lock component $($component.id)" -Properties @(
                'id', 'adapterEntrySha256', 'snapshotTreeSha256'
            )
            Assert-LockSha256 -Context "Distribution lock component $($component.id) adapterEntrySha256" -Value $component.adapterEntrySha256
            Assert-LockSha256 -Context "Distribution lock component $($component.id) snapshotTreeSha256" -Value $component.snapshotTreeSha256
        }
    } else {
        Assert-RequiredJsonProperties -Document $document -Context 'Release lock' -Properties @(
            'schemaVersion', 'candidateVersion', 'builder', 'marketplaceName', 'sourceSnapshots',
            'artifactSnapshots', 'observedPluginTreeSha256', 'observedArtifactTreeSha256',
            'sourceComposition', 'artifactInventory', 'publicationStatus', 'tagStatus', 'releaseStatus'
        )
        if ($document.schemaVersion -ne 1 -or
            $document.builder -cne 'scripts/build-release-candidate.ps1' -or
            $document.marketplaceName -cne 'frontend-toolkit-local' -or
            $document.sourceSnapshots -cne 'ephemeral-only' -or
            $document.artifactSnapshots -cne 'generated-from-pinned-upstreams' -or
            $document.sourceComposition -cne 'git-head-explicit-file-allowlist' -or
            $document.artifactInventory -cne 'all-files-force; manifest-self-listed-unhashed' -or
            $document.publicationStatus -cne 'not-published' -or
            $document.tagStatus -cne 'not-created' -or
            $document.releaseStatus -cne 'not-created' -or
            $document.candidateVersion -notmatch '^\d+\.\d+\.\d+$') {
            throw 'Release lock contains an unexpected governance structure.'
        }
        Assert-LockSha256 -Context 'Release lock observedPluginTreeSha256' -Value $document.observedPluginTreeSha256
        Assert-LockSha256 -Context 'Release lock observedArtifactTreeSha256' -Value $document.observedArtifactTreeSha256
    }
    return $document
}

if ($SourceMode -cne 'CommittedHead') {
    throw 'Persistent release/distribution hashes require SourceMode=CommittedHead; DevelopmentWorkingTree is diagnostic-only.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$safeRepo = $repoRoot.Replace('\', '/')
$actualCommit = (& git -c "safe.directory=$safeRepo" -C $repoRoot rev-parse HEAD).Trim()
Assert-NativeSuccess 'HEAD resolution'
if ($actualCommit -cne $ExpectedCommit) {
    throw "Committed-HEAD reconciliation expected $ExpectedCommit but found $actualCommit."
}

$evidenceCriticalPaths = @(
    'LICENSE',
    'plugin/frontend-toolkit',
    'integrations/external.lock.json',
    'scripts/build-plugin-snapshot.ps1',
    'scripts/build-release-candidate.ps1',
    'scripts/release-safety.ps1'
)
& git -c "safe.directory=$safeRepo" -C $repoRoot diff --quiet $ExpectedCommit -- $evidenceCriticalPaths
if ($LASTEXITCODE -ne 0) {
    throw 'Evidence-critical builder, plugin, license, or external pin bytes differ from the expected committed HEAD.'
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-lock-reconcile-' + [guid]::NewGuid().ToString('N'))
$candidateOne = Join-Path $fixture 'candidate-one'
$candidateTwo = Join-Path $fixture 'candidate-two'
$zipOne = Join-Path $fixture 'candidate-one.zip'
$zipTwo = Join-Path $fixture 'candidate-two.zip'
$builder = Join-Path $repoRoot 'scripts/build-release-candidate.ps1'
$customLockPaths = $PSBoundParameters.ContainsKey('DistributionLockPath') -or $PSBoundParameters.ContainsKey('ReleaseLockPath')
if ($customLockPaths -and (-not $PSBoundParameters.ContainsKey('DistributionLockPath') -or -not $PSBoundParameters.ContainsKey('ReleaseLockPath'))) {
    throw 'DistributionLockPath and ReleaseLockPath must be provided together.'
}
if ($Apply -and $customLockPaths) {
    throw 'Apply is restricted to the repository persistent locks.'
}
$distributionLockPath = if ($customLockPaths) { [IO.Path]::GetFullPath($DistributionLockPath) } else { Join-Path $repoRoot 'integrations/distribution.lock.json' }
$releaseLockPath = if ($customLockPaths) { [IO.Path]::GetFullPath($ReleaseLockPath) } else { Join-Path $repoRoot 'integrations/release.lock.json' }
$distributionLockBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $distributionLockPath).Hash
$releaseLockBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseLockPath).Hash

try {
    $buildOne = & $builder -Destination $candidateOne
    $buildTwo = & $builder -Destination $candidateTwo
    $manifestOne = Get-Content -Raw -LiteralPath (Join-Path $candidateOne 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    $manifestTwo = Get-Content -Raw -LiteralPath (Join-Path $candidateTwo 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    $externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json

    if ($buildOne.PluginTreeSha256 -cne $buildTwo.PluginTreeSha256 -or $buildOne.ArtifactTreeSha256 -cne $buildTwo.ArtifactTreeSha256) {
        throw 'Independent committed-HEAD build hashes disagree.'
    }
    Assert-EqualEvidence -Name 'release manifests' -First $manifestOne -Second $manifestTwo
    Assert-EqualEvidence -Name 'plugin file inventory' -First @($manifestOne.pluginFiles) -Second @($manifestTwo.pluginFiles)
    Assert-EqualEvidence -Name 'artifact file inventory' -First @($manifestOne.artifactFiles) -Second @($manifestTwo.artifactFiles)
    Assert-ReleaseInventory -CandidateRoot $candidateOne -Manifest $manifestOne -ExternalLock $externalLock
    Assert-ReleaseInventory -CandidateRoot $candidateTwo -Manifest $manifestTwo -ExternalLock $externalLock

    $zipInventoryOne = @(Get-ZipInventory -Root $candidateOne -ZipPath $zipOne)
    $zipInventoryTwo = @(Get-ZipInventory -Root $candidateTwo -ZipPath $zipTwo)
    Assert-EqualEvidence -Name 'ZIP inventory' -First $zipInventoryOne -Second $zipInventoryTwo
    $zipShaOne = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipOne).Hash.ToLowerInvariant()
    $zipShaTwo = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipTwo).Hash.ToLowerInvariant()
    if ($zipShaOne -cne $zipShaTwo) { throw 'Committed-HEAD raw ZIP bytes differ.' }

    $extractOne = Join-Path $fixture 'candidate-one-extracted'
    $extractTwo = Join-Path $fixture 'candidate-two-extracted'
    New-Item -ItemType Directory -Path $extractOne, $extractTwo | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($zipOne, $extractOne)
    [IO.Compression.ZipFile]::ExtractToDirectory($zipTwo, $extractTwo)
    $extractedInventoryOne = @(Get-ArtifactFileEntries -Root $extractOne)
    $extractedInventoryTwo = @(Get-ArtifactFileEntries -Root $extractTwo)
    Assert-EqualEvidence -Name 'extracted ZIP inventory' -First $extractedInventoryOne -Second $extractedInventoryTwo
    $newline = [string][char]10
    $manifestPaths = @(Sort-OrdinalStrings -Values @($manifestOne.artifactFiles.path))
    if (($zipInventoryOne.path -join $newline) -cne ($manifestPaths -join $newline)) {
        throw 'Committed-HEAD ZIP inventory diverged from the release manifest.'
    }

    if ($manifestOne.pluginTreeSha256 -cne $buildOne.PluginTreeSha256 -or $manifestOne.artifactTreeSha256 -cne $buildOne.ArtifactTreeSha256) {
        throw 'Builder output and manifest hashes disagree.'
    }

    $distributionLock = Read-PersistentLockDocument -Path $distributionLockPath -Kind Distribution
    $releaseLock = Read-PersistentLockDocument -Path $releaseLockPath -Kind Release
    $candidateVersion = [string]$manifestOne.version
    $persistentCandidateVersion = [string]$releaseLock.candidateVersion
    $persistentPluginIdentities = @(
        [string]$distributionLock.observedSnapshotTreeSha256
        [string]$releaseLock.observedPluginTreeSha256
    )
    $persistentArtifactIdentity = [string]$releaseLock.observedArtifactTreeSha256
    $candidatePluginIdentity = [string]$buildOne.PluginTreeSha256
    $candidateArtifactIdentity = [string]$buildOne.ArtifactTreeSha256
    Assert-LockSha256 -Context 'Candidate plugin tree identity' -Value $candidatePluginIdentity
    Assert-LockSha256 -Context 'Candidate artifact tree identity' -Value $candidateArtifactIdentity
    Assert-LockSha256 -Context 'Candidate ZIP identity' -Value $zipShaOne
    $pluginIdentitiesAreCoherent = $persistentPluginIdentities[0] -ceq $persistentPluginIdentities[1]
    $hashIdentitiesMatchCandidate = $pluginIdentitiesAreCoherent -and
        $persistentPluginIdentities[0] -ceq $candidatePluginIdentity -and
        $persistentArtifactIdentity -ceq $candidateArtifactIdentity
    $versionMatchesCandidate = $persistentCandidateVersion -ceq $candidateVersion
    $anyPersistentIdentityMatchesCandidate = @(
        $persistentPluginIdentities | Where-Object { $_ -ceq $candidatePluginIdentity }
        if ($persistentArtifactIdentity -ceq $candidateArtifactIdentity) { $persistentArtifactIdentity }
    ).Count -gt 0

    if ($hashIdentitiesMatchCandidate -and $versionMatchesCandidate) {
        $lockState = 'locked-current-candidate'
    } elseif ($hashIdentitiesMatchCandidate -or $anyPersistentIdentityMatchesCandidate -or -not $pluginIdentitiesAreCoherent) {
        $lockState = 'torn-lock-state'
    } else {
        $lockState = 'validated-pending-freeze'
    }
    if ($lockState -eq 'torn-lock-state') {
        throw 'Persistent locks are partially or inconsistently aligned with the candidate: TORN_LOCK_STATE.'
    }
    if ($RequireLockedCurrentCandidate -and $lockState -cne 'locked-current-candidate') {
        throw 'Persistent locks do not satisfy LOCKED_CURRENT_CANDIDATE.'
    }

    if ($Apply) {
        if (-not $versionMatchesCandidate) {
            throw 'Cannot apply hashes while candidateVersion differs from the candidate version; FTK-09L must update release metadata coherently.'
        }
        $distributionText = Get-Content -Raw -LiteralPath $distributionLockPath
        $releaseText = Get-Content -Raw -LiteralPath $releaseLockPath
        $distributionText = Set-JsonHashProperty -JsonText $distributionText -Property 'observedSnapshotTreeSha256' -Value $buildOne.PluginTreeSha256
        $releaseText = Set-JsonHashProperty -JsonText $releaseText -Property 'observedPluginTreeSha256' -Value $buildOne.PluginTreeSha256
        $releaseText = Set-JsonHashProperty -JsonText $releaseText -Property 'observedArtifactTreeSha256' -Value $buildOne.ArtifactTreeSha256
        [IO.File]::WriteAllText($distributionLockPath, $distributionText, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($releaseLockPath, $releaseText, (New-Object Text.UTF8Encoding($false)))
    }

    $outputLockState = if ($Apply) { 'locked-current-candidate' } else { $lockState }
    $distributionLockUnchanged = $distributionLockBefore -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath $distributionLockPath).Hash
    $releaseLockUnchanged = $releaseLockBefore -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseLockPath).Hash

    [pscustomobject][ordered]@{
        schemaVersion = 1
        sourceMode = 'CommittedHead'
        sourceCommit = $actualCommit
        independentBuildCount = 2
        buildOnePluginTreeSha256 = $buildOne.PluginTreeSha256
        buildTwoPluginTreeSha256 = $buildTwo.PluginTreeSha256
        buildOneArtifactTreeSha256 = $buildOne.ArtifactTreeSha256
        buildTwoArtifactTreeSha256 = $buildTwo.ArtifactTreeSha256
        manifestsEqual = $true
        zipInventoriesEqual = $true
        rawZipSha256One = $zipShaOne
        rawZipSha256Two = $zipShaTwo
        rawZipBytesEqual = $true
        extractedInventoriesEqual = $true
        inventoryValidated = $true
        candidateVersion = $candidateVersion
        persistentCandidateVersion = $persistentCandidateVersion
        candidatePluginTreeSha256 = $candidatePluginIdentity
        candidateArtifactTreeSha256 = $candidateArtifactIdentity
        candidateZipSha256 = $zipShaOne
        persistentPluginTreeSha256 = $distributionLock.observedSnapshotTreeSha256
        persistentReleasePluginTreeSha256 = $releaseLock.observedPluginTreeSha256
        persistentArtifactTreeSha256 = $releaseLock.observedArtifactTreeSha256
        persistentLocksMatchCandidate = ($outputLockState -eq 'locked-current-candidate')
        lockUpdateRequired = ($outputLockState -eq 'validated-pending-freeze')
        lockState = $outputLockState
        persistentLocksUnchanged = ($distributionLockUnchanged -and $releaseLockUnchanged)
        applied = [bool]$Apply
    }
} finally {
    $fullFixture = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $fullFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Lock reconciliation fixture escaped TEMP.'
    }
    if ([IO.Directory]::Exists($fullFixture)) {
        [IO.Directory]::Delete('\\?\' + $fullFixture, $true)
    }
}
if (Test-Path -LiteralPath $fixture) { throw 'Lock reconciliation fixture teardown failed.' }
