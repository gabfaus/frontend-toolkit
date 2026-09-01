param(
    [Parameter(Mandatory)][string]$Destination,
    [switch]$DevelopmentWorkingTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-safety.ps1')

function Get-TreeEntries {
    param([Parameter(Mandatory)][string]$Root)
    return @(Get-ArtifactFileEntries -Root $Root)
}

function Get-EntriesHash {
    param([Parameter(Mandatory)][object[]]$Entries)
    return Get-ArtifactEntriesHash -Entries $Entries
}

function Assert-ReleaseManifestCoverage {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object]$Manifest
    )

    $actualEntries = @(Get-ArtifactFileEntries -Root $Root)
    $actualPaths = @($actualEntries.path | Sort-Object)
    $manifestPaths = @($Manifest.artifactFiles.path | Sort-Object)
    if (($actualPaths -join "`n") -cne ($manifestPaths -join "`n")) {
        throw 'Release manifest does not inventory every artifact file.'
    }
    foreach ($entry in @($Manifest.artifactFiles | Where-Object { -not $_.selfManifest })) {
        $actual = $actualEntries | Where-Object path -CEQ $entry.path
        if ($null -eq $actual -or $actual.sha256 -cne $entry.sha256) {
            throw "Release manifest hash mismatch: $($entry.path)"
        }
    }
    $self = @($Manifest.artifactFiles | Where-Object selfManifest)
    if ($self.Count -ne 1 -or $self[0].path -cne 'RELEASE_MANIFEST.json' -or $null -ne $self[0].sha256) {
        throw 'Release manifest self-entry is invalid.'
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destinationPath = [IO.Path]::GetFullPath($Destination)
$builder = Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1'
$manifestPath = Join-Path $repoRoot 'plugin/frontend-toolkit/.codex-plugin/plugin.json'
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Release candidate requires a strict SemVer plugin version.' }
if (Test-Path -LiteralPath $destinationPath) { throw "Destination already exists: $destinationPath" }
if ($destinationPath.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $repoRoot.StartsWith($destinationPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Destination would replace or contain the repository.'
}

$pluginDestination = Join-Path $destinationPath 'plugins/frontend-toolkit'
$marketplaceDirectory = Join-Path $destinationPath '.agents/plugins'
try {
    New-Item -ItemType Directory -Path $marketplaceDirectory, (Split-Path $pluginDestination) -Force | Out-Null
    $snapshotArguments = @{ Destination = $pluginDestination }
    if ($DevelopmentWorkingTree) { $snapshotArguments.DevelopmentWorkingTree = $true }
    & $builder @snapshotArguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Plugin snapshot build failed.' }

    $marketplace = [ordered]@{
        name = 'frontend-toolkit-local'
        interface = [ordered]@{ displayName = 'Frontend Toolkit Local' }
        plugins = @([ordered]@{
            name = 'frontend-toolkit'
            source = [ordered]@{ source = 'local'; path = './plugins/frontend-toolkit' }
            policy = [ordered]@{ installation = 'AVAILABLE'; authentication = 'ON_USE' }
            category = 'Developer Tools'
        })
    }
    [IO.File]::WriteAllText(
        (Join-Path $marketplaceDirectory 'marketplace.json'),
        (($marketplace | ConvertTo-Json -Depth 10) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )

    Assert-NoSensitiveArtifactPaths -Root $destinationPath -Context 'release candidate payload'
    $entries = Get-TreeEntries -Root $pluginDestination
    $treeHash = Get-EntriesHash -Entries $entries
    $payloadEntries = Get-TreeEntries -Root $destinationPath
    $artifactTreeHash = Get-EntriesHash -Entries $payloadEntries
    $artifactFiles = @($payloadEntries | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_.path
            sha256 = $_.sha256
            selfManifest = $false
        }
    })
    $artifactFiles += [pscustomobject][ordered]@{
        path = 'RELEASE_MANIFEST.json'
        sha256 = $null
        selfManifest = $true
    }
    $artifactFiles = @($artifactFiles | Sort-Object path)
    $releaseManifest = [ordered]@{
        schemaVersion = 1
        version = $manifest.version
        plugin = 'frontend-toolkit'
        marketplace = 'frontend-toolkit-local'
        pluginTreeSha256 = $treeHash
        pluginFileCount = $entries.Count
        pluginFiles = $entries
        artifactTreeSha256 = $artifactTreeHash
        artifactFileCount = $artifactFiles.Count
        artifactFiles = $artifactFiles
        artifactInventoryPolicy = 'all files enumerated with Force; manifest self-listed without self-hash'
        provenance = @($externalLock.dependencies | ForEach-Object {
            [ordered]@{ id = $_.id; ref = $_.ref; commitSha = $_.commitSha; license = $_.license }
        })
        secretsIncluded = $false
        snapshots = 'generated-from-pinned-upstreams'
    }
    [IO.File]::WriteAllText(
        (Join-Path $destinationPath 'RELEASE_MANIFEST.json'),
        (($releaseManifest | ConvertTo-Json -Depth 10) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    Assert-NoSensitiveArtifactPaths -Root $destinationPath -Context 'release candidate'
    $writtenManifest = Get-Content -Raw -LiteralPath (Join-Path $destinationPath 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    Assert-ReleaseManifestCoverage -Root $destinationPath -Manifest $writtenManifest

    [pscustomobject]@{
        Destination = $destinationPath
        Version = $manifest.version
        PluginTreeSha256 = $treeHash
        PluginFileCount = $entries.Count
        ArtifactTreeSha256 = $artifactTreeHash
        ArtifactFileCount = $artifactFiles.Count
    }
} catch {
    if (Test-Path -LiteralPath $destinationPath) {
        [IO.Directory]::Delete('\\?\' + $destinationPath, $true)
    }
    throw
}
