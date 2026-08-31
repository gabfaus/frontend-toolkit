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
    $upstreamSkillSourcePath = Resolve-RepoPath $dependency.upstreamSkillSourcePath
    $adapterPath = Resolve-RepoPath $dependency.adapterPath
    $pluginAdapterPath = Resolve-RepoPath ('plugin/frontend-toolkit/' + $dependency.distributionAdapterPath)
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

    $upstreamSkillEntry = Join-Path $upstreamSkillSourcePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $upstreamSkillEntry -PathType Leaf)) {
        throw "Missing upstream SKILL.md for $($dependency.id): $upstreamSkillEntry"
    }

    $upstreamEntryHash = (Get-FileHash -LiteralPath $upstreamSkillEntry -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($upstreamEntryHash -ne $dependency.upstreamSkillEntrySha256) {
        throw "Upstream SKILL.md hash mismatch for $($dependency.id): $upstreamEntryHash"
    }

    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
        throw "Missing license file for $($dependency.id): $licensePath"
    }
    $licenseHash = (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($licenseHash -ne $dependency.licenseSha256) {
        throw "License hash mismatch for $($dependency.id): $licenseHash"
    }

    foreach ($candidate in @($adapterPath, $pluginAdapterPath)) {
        $adapter = Get-Item -Force -LiteralPath $candidate
        if (-not $adapter.PSIsContainer -or $adapter.LinkType -or
            ($adapter.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Adapter must be an FTK-owned physical directory: $candidate"
        }
        $adapterEntry = Join-Path $candidate 'SKILL.md'
        $adapterHash = (Get-FileHash -LiteralPath $adapterEntry -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($adapterHash -ne $dependency.adapterEntrySha256) {
            throw "FTK adapter hash mismatch for $($dependency.id): $adapterHash"
        }
    }

    Write-Output "$($dependency.id): ref=$($dependency.ref) commit=$head adapter=$adapterPath snapshot=$($dependency.upstreamSnapshotPath)"
}
