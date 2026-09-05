Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-IndependentOrdinalPaths {
    param([Parameter(Mandatory)][string[]]$Values)

    $sorted = [string[]]@($Values)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')

$reconcilerText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/reconcile-committed-head-locks.ps1')
Assert-True ($reconcilerText -match '\$manifestPaths\s*=\s*@\(Sort-OrdinalStrings\s+-Values') 'Reconciler manifest inventory is not explicitly ordinal.'
Assert-True ($reconcilerText -notmatch 'Sort-Object') 'Reconciler still contains a default Sort-Object.'

$releaseSafetyText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/release-safety.ps1')
Assert-True ($releaseSafetyText -match '\$actualSorted\s*=\s*@\(Sort-OrdinalStrings\s+-Values' -and $releaseSafetyText -match '\$expectedSorted\s*=\s*@\(Sort-OrdinalStrings\s+-Values') 'Canonical release-safety set comparison is not explicitly ordinal.'

$representative = [string[]]@('A.txt', 'a.d.ts', 'a.d.ts.map', 'RELEASE_MANIFEST.json', 'marketplace.json')
$defaultOrder = [string[]]@($representative | Sort-Object)
$ordinalOrder = Get-IndependentOrdinalPaths -Values $representative
Assert-True ((($defaultOrder -join [char]10) -cne ($ordinalOrder -join [char]10))) 'Representative inventory did not expose default-sort divergence.'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-reconciler-ordinal-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path ([IO.Path]::GetTempPath()) ('ftk-reconciler-ordinal-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'lower') -Force | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    foreach ($file in @(
        @{ path = 'A.txt'; value = 'upper' },
        @{ path = 'a.d.ts'; value = 'type Inventory = string' },
        @{ path = 'a.d.ts.map'; value = '{version:3}' },
        @{ path = 'marketplace.json'; value = '{name:fixture}' },
        @{ path = 'lower/a.txt'; value = 'lower' }
    )) {
        $path = Join-Path $fixture $file.path
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $file.value, $utf8)
    }

    $baseEntries = @(Get-ArtifactFileEntries -Root $fixture)
    $artifactEntries = @($baseEntries | ForEach-Object {
        [pscustomobject][ordered]@{ path = $_.path; sha256 = $_.sha256; selfManifest = $false }
    })
    $artifactEntries += [pscustomobject][ordered]@{ path = 'RELEASE_MANIFEST.json'; sha256 = $null; selfManifest = $true }
    $artifactEntries = @(Sort-ArtifactEntriesOrdinal -Entries $artifactEntries)
    $manifest = [ordered]@{ artifactFiles = $artifactEntries }
    [IO.File]::WriteAllText(
        (Join-Path $fixture 'RELEASE_MANIFEST.json'),
        (($manifest | ConvertTo-Json -Depth 10) + [char]10),
        $utf8
    )

    New-DeterministicZip -Root $fixture -ZipPath $zipPath
    $writtenManifest = Get-Content -Raw -LiteralPath (Join-Path $fixture 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    $manifestPaths = [string[]]@($writtenManifest.artifactFiles.path)
    $manifestOrdinal = Get-IndependentOrdinalPaths -Values $manifestPaths
    $manifestDefault = [string[]]@($manifestPaths | Sort-Object)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $zipPaths = [string[]]@($archive.Entries | Where-Object Name | ForEach-Object { $_.FullName.Replace('\', '/') })
    } finally {
        $archive.Dispose()
    }
    $zipOrdinal = Get-IndependentOrdinalPaths -Values $zipPaths

    Assert-True ((($manifestDefault -join [char]10) -cne ($manifestOrdinal -join [char]10))) 'Actual manifest inventory did not expose default-sort divergence.'
    Assert-True ((($manifestOrdinal -join [char]10) -ceq ($zipOrdinal -join [char]10))) 'Manifest and ZIP inventories differ under the independent ordinal oracle.'
    Write-Output 'PASS: default Sort-Object diverges from strict ordinal order for representative release paths.'
    Write-Output 'PASS: actual release manifest and deterministic ZIP inventories agree under an independent ordinal oracle.'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        Get-ChildItem -LiteralPath $fixture -Recurse -Force | ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true)
    }
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
}
if (Test-Path -LiteralPath $fixture) { throw 'Ordinal inventory fixture teardown failed.' }
if (Test-Path -LiteralPath $zipPath) { throw 'Ordinal inventory ZIP teardown failed.' }
