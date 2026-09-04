Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Contract: enumerate all non-directory files with -Recurse -Force; preserve
# file bytes and path spelling; normalize separators to '/'; sort by strict
# ordinal path comparison; hash file bytes with SHA-256; serialize UTF-8
# without BOM as path|lowercase hex hash records joined by LF (0x0A), without
# a terminal LF. Directories and metadata do not contribute to the identity.

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-IndependentContractEntries {
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $records = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        }
    })
    $paths = [string[]]@($records | ForEach-Object { $_.path })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    foreach ($path in $paths) { $records | Where-Object { $_.path -ceq $path } }
}

function Get-IndependentContractHash {
    param([Parameter(Mandatory)][object[]]$Entries)

    $stream = @($Entries | ForEach-Object { '{0}|{1}' -f $_.path, $_.sha256 }) -join [char]10
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($stream)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$distributionScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests/test-plugin-distribution.ps1')
$releaseSafetyScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/release-safety.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-tree-hash-contract-' + [guid]::NewGuid().ToString('N'))

try {
    Assert-True ($distributionScript -notmatch 'function\s+Get-TreeHash') 'Distribution retains an independent tree-hash implementation.'
    Assert-True ($distributionScript -match 'Get-ArtifactEntriesHash\s+-Entries\s+@\(') 'Distribution does not delegate to the canonical tree-hash helper.'
    Assert-True ($releaseSafetyScript -match '\[StringComparer\]::Ordinal') 'Canonical helper does not declare strict ordinal ordering.'
    Assert-True ($releaseSafetyScript -notmatch 'Sort-Object\s+(?:-Property\s+)?path') 'Canonical helper still uses Sort-Object path ordering.'

    New-Item -ItemType Directory -Path (Join-Path $fixture 'nested'), (Join-Path $fixture 'lower') -Force | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $fixture 'A.txt'), 'uppercase path', $utf8)
    [IO.File]::WriteAllText((Join-Path $fixture 'a.d.ts'), ('type Fixture = string' + [char]10), $utf8)
    [IO.File]::WriteAllText((Join-Path $fixture 'a.d.ts.map'), ('{"version":3}' + [char]10), $utf8)
    [IO.File]::WriteAllText((Join-Path $fixture 'lower/a.txt'), 'lowercase path', $utf8)
    [IO.File]::WriteAllText((Join-Path $fixture 'nested/ReadMe.txt'), 'same bytes', $utf8)

    $entries = @(Get-ArtifactFileEntries -Root $fixture)
    $independentEntries = @(Get-IndependentContractEntries -Root $fixture)
    Assert-True ((@($entries.path) -join "`n") -ceq (@($independentEntries.path) -join "`n")) 'Canonical helper path order differs from the independent ordinal oracle.'
    Assert-True ((@($entries.path)[0]) -ceq 'A.txt') 'Ordinal path order must place A.txt before a.d.ts.'
    Assert-True ((@($entries.path)[1..3] -join ',') -ceq 'a.d.ts,a.d.ts.map,lower/a.txt') 'Prefix-sensitive ordinal path order drifted.'
    $releaseHash = Get-ArtifactEntriesHash -Entries $entries
    $distributionHash = Get-ArtifactEntriesHash -Entries @($entries[($entries.Count - 1)..0])
    $independentHash = Get-IndependentContractHash -Entries $independentEntries
    Assert-True ($releaseHash -ceq $distributionHash) "Release and distribution hashes differ: $releaseHash vs $distributionHash"
    Assert-True ($releaseHash -ceq $independentHash) "Canonical hash does not match the independently serialized contract: $releaseHash vs $independentHash"

    $originalCulture = [Globalization.CultureInfo]::CurrentCulture
    $originalUICulture = [Globalization.CultureInfo]::CurrentUICulture
    $cultureHashes = [ordered]@{}
    try {
        foreach ($cultureName in @('pt-BR', 'en-US', 'tr-TR', 'invariant')) {
            $culture = if ($cultureName -eq 'invariant') { [Globalization.CultureInfo]::InvariantCulture } else { New-Object Globalization.CultureInfo($cultureName) }
            [Globalization.CultureInfo]::CurrentCulture = $culture
            [Globalization.CultureInfo]::CurrentUICulture = $culture
            $cultureHashes[$cultureName] = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root $fixture)
        }
    } finally {
        [Globalization.CultureInfo]::CurrentCulture = $originalCulture
        [Globalization.CultureInfo]::CurrentUICulture = $originalUICulture
    }
    Assert-True (@($cultureHashes.Values | Select-Object -Unique).Count -eq 1) 'Canonical tree hash changed with process culture.'
    Assert-True ($cultureHashes['pt-BR'] -ceq $releaseHash) 'Culture-specific canonical hash differs from the baseline.'

    [IO.File]::WriteAllText((Join-Path $fixture 'nested/ReadMe.txt'), 'changed bytes', $utf8)
    $changedHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root $fixture)
    Assert-True ($changedHash -cne $releaseHash) 'A meaningful file-content change did not change the tree hash.'

    Move-Item -LiteralPath (Join-Path $fixture 'nested/ReadMe.txt') -Destination (Join-Path $fixture 'nested/Renamed.txt')
    $renamedHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root $fixture)
    Assert-True ($renamedHash -cne $changedHash) 'A governed path change did not change the tree hash.'

    Write-Output "PASS: release and distribution use the canonical ordinal tree hash $releaseHash."
    Write-Output 'PASS: independent UTF-8/LF contract oracle agrees, including A.txt, a.d.ts, a.d.ts.map and a.txt.'
    Write-Output "PASS: pt-BR, en-US, tr-TR and invariant cultures produced $($cultureHashes['pt-BR'])."
    Write-Output 'PASS: meaningful file-content change changes the tree hash.'
    Write-Output 'PASS: governed path change changes the tree hash.'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        [IO.Directory]::Delete('\\?\'+[IO.Path]::GetFullPath($fixture), $true)
    }
}
if (Test-Path -LiteralPath $fixture) { throw 'Tree-hash contract fixture teardown failed.' }
