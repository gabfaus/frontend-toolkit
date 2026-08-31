Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')

function Assert-Rejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Label
    )
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw "Unsafe archive case was accepted: $Label" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-g7s-archive-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $fixture 'stage'
$outside = Join-Path $fixture 'outside-marker.txt'
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    Assert-SafeArchiveEntry -Path 'safe/content.txt' -EntryType file -Mode '100644' -Context 'synthetic safe archive'
    Assert-SafeArchiveEntry -Path 'safe/tool.py' -EntryType file -Mode '100755' -Context 'synthetic safe archive' -AllowedExecutablePaths @('safe/tool.py')
    Assert-SafeGitArchiveTree -Repository $repoRoot -Commit 'HEAD' -Context 'git ls-tree parser contract' -Paths @('AGENTS.md')

    $unsafeCases = @(
        @{ path = '../escape.txt'; type = 'file'; mode = '100644'; label = 'parent traversal' }
        @{ path = 'safe/../../escape.txt'; type = 'file'; mode = '100644'; label = 'nested traversal' }
        @{ path = 'C:/synthetic/escape.txt'; type = 'file'; mode = '100644'; label = 'absolute Windows path' }
        @{ path = '/synthetic/escape.txt'; type = 'file'; mode = '100644'; label = 'absolute POSIX path' }
        @{ path = 'safe/link'; type = 'symlink'; mode = '120000'; label = 'symlink entry' }
        @{ path = 'safe/junction'; type = 'reparse'; mode = '000000'; label = 'junction or reparse entry' }
        @{ path = 'vendor/module'; type = 'gitlink'; mode = '160000'; label = 'submodule entry' }
        @{ path = 'nested/.git/config'; type = 'file'; mode = '100644'; label = 'nested Git metadata' }
        @{ path = 'bin/unexpected.sh'; type = 'file'; mode = '100755'; label = 'unexpected executable' }
    )
    foreach ($case in $unsafeCases) {
        Assert-Rejected -Label $case.label -Action {
            Assert-SafeArchiveEntry -Path $case.path -EntryType $case.type -Mode $case.mode -Context 'synthetic hostile archive'
        }
    }

    Add-Type -AssemblyName System.IO.Compression
    $zipPath = Join-Path $fixture 'hostile.zip'
    $stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($entryPath in @('../escape.txt', 'C:/synthetic/escape.txt', 'nested/.git/config', 'bin/unexpected.sh')) {
                [void]$archive.CreateEntry($entryPath)
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }

    $stream = [IO.File]::OpenRead($zipPath)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            foreach ($entry in $archive.Entries) {
                Assert-Rejected -Label ('ZIP entry ' + $entry.FullName) -Action {
                    $mode = if ($entry.FullName.EndsWith('.sh')) { '100755' } else { '100644' }
                    Assert-SafeArchiveEntry -Path $entry.FullName -EntryType file -Mode $mode -Context 'synthetic hostile ZIP'
                }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }

    if (Test-Path -LiteralPath $outside) { throw 'Synthetic archive escaped its stage.' }
    Write-Output 'PASS: traversal, absolute paths, links, reparse points, submodules, nested Git metadata and unexpected executables fail closed.'
    Write-Output 'PASS: git ls-tree output is parsed before archive generation.'
    Write-Output 'PASS: hostile synthetic archive was inspected but never extracted; no stage escape occurred.'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

if (Test-Path -LiteralPath $fixture) { throw 'Archive security fixture teardown failed.' }
Write-Output 'PASS: archive security fixture teardown complete.'
