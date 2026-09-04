Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Canonical($Value) { $Value | ConvertTo-Json -Depth 20 -Compress }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$builder = Join-Path $repoRoot 'scripts/build-release-candidate.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-deterministic-zip-' + [guid]::NewGuid().ToString('N'))
$one = Join-Path $fixture 'build-one'
$two = Join-Path $fixture 'build-two'
$zipOne = Join-Path $fixture 'build-one.zip'
$zipTwo = Join-Path $fixture 'build-two.zip'
$extractOne = Join-Path $fixture 'extract-one'
$extractTwo = Join-Path $fixture 'extract-two'

try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    & $builder -Destination $one | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Committed-HEAD build one failed.' }
    & $builder -Destination $two | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Committed-HEAD build two failed.' }

    New-DeterministicZip -Root $one -ZipPath $zipOne
    New-DeterministicZip -Root $two -ZipPath $zipTwo
    $shaOne = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipOne).Hash.ToLowerInvariant()
    $shaTwo = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipTwo).Hash.ToLowerInvariant()
    Assert-True ($shaOne -ceq $shaTwo) "Committed-HEAD raw ZIP SHA-256 differs: $shaOne vs $shaTwo"

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixedTimestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    foreach ($zipPath in @($zipOne, $zipTwo)) {
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $archive.Entries) {
                Assert-True ($entry.FullName -notmatch '\\' -and $entry.FullName -notmatch '/$') "ZIP path metadata is not canonical: $($entry.FullName)"
                Assert-True ($entry.LastWriteTime.Year -eq 1980 -and $entry.LastWriteTime.Month -eq 1 -and $entry.LastWriteTime.Day -eq 1 -and $entry.LastWriteTime.Hour -eq 0 -and $entry.LastWriteTime.Minute -eq 0 -and $entry.LastWriteTime.Second -eq 0) "ZIP timestamp drifted: $($entry.FullName)"
                Assert-True ($entry.ExternalAttributes -eq 0) "ZIP external attributes drifted: $($entry.FullName)"
            }
        } finally { $archive.Dispose() }
    }

    New-Item -ItemType Directory -Path $extractOne, $extractTwo | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($zipOne, $extractOne)
    [IO.Compression.ZipFile]::ExtractToDirectory($zipTwo, $extractTwo)
    $inventoryOne = @(Get-ArtifactFileEntries -Root $extractOne)
    $inventoryTwo = @(Get-ArtifactFileEntries -Root $extractTwo)
    Assert-True ((Canonical $inventoryOne) -ceq (Canonical $inventoryTwo)) 'Extracted ZIP inventories differ.'
    $packagedPaths = @(Get-ArtifactFileEntries -Root $one | ForEach-Object path)
    Assert-True (@($packagedPaths | Where-Object { $_ -like 'tests/*' }).Count -eq 0) 'Source tests entered the production release artifact.'
    Assert-True ($packagedPaths -notcontains 'tests/fixtures/impeccable-static-html-golden.json') 'Golden fixture entered the production release artifact.'
    Write-Output "PASS: committed-head raw ZIP SHA-256 $shaOne"
    Write-Output "PASS: extracted ZIP inventories are identical; source tests and golden fixture are absent from the package."
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}