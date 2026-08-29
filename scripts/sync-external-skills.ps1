[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lockPath = Join-Path $repoRoot 'integrations/external.lock.json'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required on PATH. No private Codex runtime fallback is allowed.'
}

function Resolve-RepoPath {
    param([Parameter(Mandatory)][string]$RelativePath)

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $RelativePath))
    if (-not $candidate.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes repository root: $RelativePath"
    }
    return $candidate
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

foreach ($dependency in $lock.dependencies) {
    $checkoutPath = Resolve-RepoPath $dependency.checkoutPath
    $skillSourcePath = Resolve-RepoPath $dependency.skillSourcePath
    $discoveryPath = Resolve-RepoPath $dependency.discoveryPath
    $licensePath = Resolve-RepoPath $dependency.licenseFile

    if (-not (Test-Path -LiteralPath $checkoutPath)) {
        if ($ValidateOnly) {
            throw "Missing checkout for $($dependency.id): $checkoutPath"
        }

        $checkoutParent = Split-Path -Parent $checkoutPath
        New-Item -ItemType Directory -Path $checkoutParent -Force | Out-Null
        Invoke-Git @('clone', '--quiet', '--depth', '1', '--branch', $dependency.ref, $dependency.upstream, $checkoutPath) | Out-Null
    }

    $origin = (Invoke-Git @('-C', $checkoutPath, 'remote', 'get-url', 'origin') | Select-Object -First 1).Trim()
    if ($origin -ne $dependency.upstream) {
        throw "Unexpected origin for $($dependency.id): $origin"
    }

    $head = (Invoke-Git @('-C', $checkoutPath, 'rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    if ($head -ne $dependency.commitSha) {
        throw "Unexpected commit for $($dependency.id): $head"
    }

    $checkoutChanges = Invoke-Git @('-C', $checkoutPath, 'status', '--porcelain')
    if ($checkoutChanges) {
        throw "External checkout is dirty: $($dependency.id)"
    }

    $skillEntry = Join-Path $skillSourcePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillEntry -PathType Leaf)) {
        throw "Missing SKILL.md for $($dependency.id): $skillEntry"
    }

    $entryHash = (Get-FileHash -LiteralPath $skillEntry -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($entryHash -ne $dependency.skillEntrySha256) {
        throw "SKILL.md hash mismatch for $($dependency.id): $entryHash"
    }

    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
        throw "Missing license file for $($dependency.id): $licensePath"
    }
    $licenseHash = (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($licenseHash -ne $dependency.licenseSha256) {
        throw "License hash mismatch for $($dependency.id): $licenseHash"
    }

    if (Test-Path -LiteralPath $discoveryPath) {
        $link = Get-Item -Force -LiteralPath $discoveryPath
        if ($link.LinkType -ne 'Junction') {
            throw "Discovery path is not a junction: $discoveryPath"
        }

        $actualTarget = [System.IO.Path]::GetFullPath([string]$link.Target)
        $expectedTarget = [System.IO.Path]::GetFullPath($skillSourcePath)
        if ($actualTarget -ne $expectedTarget) {
            throw "Junction target mismatch for $($dependency.id): $actualTarget"
        }
    } elseif (-not $ValidateOnly) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $discoveryPath) -Force | Out-Null
        New-Item -ItemType Junction -Path $discoveryPath -Target $skillSourcePath | Out-Null
    } else {
        throw "Missing discovery junction for $($dependency.id): $discoveryPath"
    }

    Write-Output "$($dependency.id): ref=$($dependency.ref) commit=$head discovery=$discoveryPath"
}
