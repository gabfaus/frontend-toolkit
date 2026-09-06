Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Label
    )

    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "Expected governed guard rejection: $Label" }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$runtimeAllowlist = @('security/claude/runtime')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-governed-runtime-' + [guid]::NewGuid().ToString('N'))
$reparseTarget = Join-Path $fixture 'reparse-target'

function New-SyntheticFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $path = Join-Path $Root ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, 'synthetic governed runtime fixture', (New-Object Text.UTF8Encoding($false)))
}

function Assert-SensitiveFixture {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )

    $root = Join-Path $fixture ('case-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        New-SyntheticFile -Root $root -RelativePath $RelativePath
        Assert-Throws -Label $Label -Action {
            Assert-NoSensitiveArtifactPaths -Root $root -Context $Label -AllowedGovernedRuntimeRoots $runtimeAllowlist
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

try {
    Assert-True (Test-SensitiveArtifactPath -RelativePath 'security/other/runtime/file.txt' -AllowedGovernedRuntimeRoots $runtimeAllowlist) 'Runtime outside the approved root was accepted.'
    Assert-True (Test-SensitiveArtifactPath -RelativePath 'security/claude/runtime/file.txt') 'Claude runtime was not blocked without opt-in.'
    Assert-True (-not (Test-SensitiveArtifactPath -RelativePath 'security/claude/runtime/file.txt' -AllowedGovernedRuntimeRoots $runtimeAllowlist)) 'Exact Claude runtime was not accepted with opt-in.'

    foreach ($case in @(
        @{ Path = 'security/claude/runtime/.env'; Label = 'runtime/.env' }
        @{ Path = 'security/claude/runtime/credentials.json'; Label = 'runtime/credentials.json' }
        @{ Path = 'security/claude/runtime/key.pem'; Label = 'runtime/key.pem' }
        @{ Path = 'security/claude/runtime/.ssh/config'; Label = 'runtime/.ssh/**' }
        @{ Path = 'security/claude/runtime/cache/state'; Label = 'runtime/cache/**' }
        @{ Path = 'security/claude/runtime/temp/state'; Label = 'runtime/temp/**' }
        @{ Path = 'security/claude/runtime-evil/package.json'; Label = 'runtime-evil/**' }
        @{ Path = 'security/claude/runtime2/package.json'; Label = 'runtime2/**' }
    )) {
        Assert-SensitiveFixture -RelativePath $case.Path -Label $case.Label
    }

    foreach ($unsafePath in @(
        'security/claude/runtime/../escape.txt'
        'C:\outside.txt'
        '/outside.txt'
    )) {
        Assert-Throws -Label ('absolute/traversal path ' + $unsafePath) -Action {
            Assert-SafeArchiveEntry -Path $unsafePath -EntryType file -Mode '100644' -Context 'governed runtime path'
        }
    }
    Assert-Throws -Label 'wildcard allowlist rejected' -Action {
        Test-SensitiveArtifactPath -RelativePath 'security/claude/runtime/file.txt' -AllowedGovernedRuntimeRoots @('security/claude/*')
    }

    $historicalRoot = Join-Path $fixture 'historical'
    New-Item -ItemType Directory -Path $historicalRoot -Force | Out-Null
    New-SyntheticFile -Root $historicalRoot -RelativePath 'runtime/probe.txt'
    Assert-Throws -Label 'empty allowlist historical behavior' -Action {
        Assert-NoSensitiveArtifactPaths -Root $historicalRoot -Context 'empty allowlist'
    }
    Assert-True (Test-SensitiveArtifactPath -RelativePath 'runtime/probe.txt') 'Empty allowlist no longer preserves the historical runtime block.'

    $codexText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1')
    Assert-True ($codexText.IndexOf('AllowedGovernedRuntimeRoots', [StringComparison]::Ordinal) -lt 0) 'Codex snapshot builder received the governed runtime exception.'
    Assert-Throws -Label 'Codex deterministic ZIP historical behavior' -Action {
        $codexZipRoot = Join-Path $fixture 'codex-zip'
        New-Item -ItemType Directory -Path $codexZipRoot -Force | Out-Null
        New-SyntheticFile -Root $codexZipRoot -RelativePath 'runtime/probe.txt'
        New-DeterministicZip -Root $codexZipRoot -ZipPath (Join-Path $fixture 'codex.zip')
    }

    $passRoot = Join-Path $fixture 'pass'
    New-SyntheticFile -Root $passRoot -RelativePath 'security/claude/runtime/package.json'
    New-DeterministicZip -Root $passRoot -ZipPath (Join-Path $fixture 'claude.zip') -AllowedGovernedRuntimeRoots $runtimeAllowlist

    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    New-SyntheticFile -Root $reparseTarget -RelativePath 'safe.txt'
    $reparsePath = Join-Path $passRoot 'security/claude/runtime/reparse'
    New-Item -ItemType Junction -Path $reparsePath -Target $reparseTarget | Out-Null
    Assert-Throws -Label 'reparse inside governed Claude runtime' -Action {
        Assert-NoSensitiveArtifactPaths -Root $passRoot -Context 'reparse' -AllowedGovernedRuntimeRoots $runtimeAllowlist
    }

    Write-Output 'PASS: governed Claude runtime exception is exact, opt-in, and fail-closed for sensitive paths, near-misses, reparse points, empty allowlists, and Codex packaging.'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}