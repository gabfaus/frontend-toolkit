Set-StrictMode -Version Latest

function Assert-ReleaseNativeSuccess {
    param([Parameter(Mandatory)][string]$Operation)
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Assert-ExactStringSet {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Actual,
        [Parameter(Mandatory)][string[]]$Expected
    )

    $actualSorted = @($Actual | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if (($actualSorted -join "`n") -cne ($expectedSorted -join "`n")) {
        $unexpected = @($actualSorted | Where-Object { $_ -cnotin $expectedSorted })
        $missing = @($expectedSorted | Where-Object { $_ -cnotin $actualSorted })
        throw "$Name diverged. Unexpected: $($unexpected -join ', '); missing: $($missing -join ', ')"
    }
}

function Get-GitPathState {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoRelativePath
    )

    $safeRepo = $RepoRoot.Replace('\', '/')
    & git -c "safe.directory=$safeRepo" -C $RepoRoot ls-files --error-unmatch -- $RepoRelativePath 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'tracked-outside-allowlist' }
    & git -c "safe.directory=$safeRepo" -C $RepoRoot check-ignore --no-index -q -- $RepoRelativePath
    if ($LASTEXITCODE -eq 0) { return 'ignored' }
    return 'untracked'
}

function Get-FrontendToolkitSourceFileAllowlist {
    return @(
        '.codex-plugin/plugin.json'
        '.mcp.json'
        'THIRD_PARTY_NOTICES.md'
        'external-skills.lock.json'
        'skills/frontend-orchestrator/SKILL.md'
        'skills/frontend-orchestrator/references/cost-policy.md'
        'skills/frontend-orchestrator/references/routing-policy.json'
        'skills/frontend-orchestrator/references/routing.md'
        'skills/frontend-orchestrator/references/scenarios.json'
    )
}

function Get-FrontendToolkitSourceDirectoryAllowlist {
    return @(
        '.codex-plugin'
        'skills'
        'skills/frontend-orchestrator'
        'skills/frontend-orchestrator/references'
    )
}

function Assert-ApprovedSourceComposition {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PluginSource,
        [Parameter(Mandatory)][string[]]$FileAllowlist,
        [Parameter(Mandatory)][string[]]$DirectoryAllowlist
    )

    Assert-NoSensitiveArtifactPaths -Root $PluginSource -Context 'plugin source'
    $entries = @(Get-CompleteArtifactEntries -Root $PluginSource)
    $actualFiles = @($entries | Where-Object { -not $_.IsDirectory } | ForEach-Object Path)
    $actualDirectories = @($entries | Where-Object IsDirectory | ForEach-Object Path)

    $unexpectedFiles = @($actualFiles | Where-Object { $_ -cnotin $FileAllowlist })
    if ($unexpectedFiles.Count) {
        $details = @($unexpectedFiles | ForEach-Object {
            $repoPath = 'plugin/frontend-toolkit/' + $_
            "$_ ($(Get-GitPathState -RepoRoot $RepoRoot -RepoRelativePath $repoPath))"
        })
        throw "Plugin source contains unexpected files: $($details -join ', ')"
    }
    Assert-ExactStringSet -Name 'plugin source files' -Actual $actualFiles -Expected $FileAllowlist
    Assert-ExactStringSet -Name 'plugin source directories' -Actual $actualDirectories -Expected $DirectoryAllowlist

    $safeRepo = $RepoRoot.Replace('\', '/')
    $expectedTracked = @($FileAllowlist | ForEach-Object { 'plugin/frontend-toolkit/' + $_ })
    $tracked = @(& git -c "safe.directory=$safeRepo" -C $RepoRoot -c core.quotepath=false ls-files --cached -- 'plugin/frontend-toolkit')
    Assert-ReleaseNativeSuccess 'Plugin source tracked inventory'
    Assert-ExactStringSet -Name 'tracked plugin source' -Actual $tracked -Expected $expectedTracked

    $approvedInputs = @('LICENSE') + $expectedTracked
    & git -c "safe.directory=$safeRepo" -C $RepoRoot diff --quiet HEAD -- @approvedInputs
    if ($LASTEXITCODE -eq 1) { throw 'Approved source inputs differ from HEAD.' }
    Assert-ReleaseNativeSuccess 'Approved source input comparison'
}

function ConvertTo-ArtifactRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the audited root: $fullPath"
    }
    return $fullPath.Substring($rootPath.Length + 1).Replace('\', '/')
}

function Get-CompleteArtifactEntries {
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    return @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force | ForEach-Object {
        [pscustomobject]@{
            Item = $_
            Path = ConvertTo-ArtifactRelativePath -Root $rootPath -Path $_.FullName
            IsDirectory = $_.PSIsContainer
            IsReparsePoint = [bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        }
    })
}

function Test-SensitiveArtifactPath {
    param([Parameter(Mandatory)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/').Trim('/')
    $segments = @($normalized.Split('/') | Where-Object { $_ })
    if (-not $segments.Count) { return $false }

    $leaf = $segments[-1].ToLowerInvariant()
    $lowerSegments = @($segments | ForEach-Object { $_.ToLowerInvariant() })
    if ($leaf -eq '.env' -or $leaf.StartsWith('.env.')) { return $true }
    if ($leaf -in @('auth.json', 'credentials.json', 'cookies.json', 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519')) { return $true }
    if ([IO.Path]::GetExtension($leaf) -in @('.pem', '.key', '.pfx', '.p12')) { return $true }
    if (@($lowerSegments | Where-Object { $_ -in @('.git', '.ssh', '.codex', 'profiles', '.cache', 'cache', 'caches', 'runtime', 'runtimes', 'temp', 'tmp') }).Count) { return $true }
    if (@($lowerSegments | Where-Object { $_ -match '^codex[-_]?home$' }).Count) { return $true }
    return $false
}

function Assert-NoSensitiveArtifactPaths {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Context = 'artifact'
    )

    $entries = @(Get-CompleteArtifactEntries -Root $Root)
    $reparsePoints = @($entries | Where-Object IsReparsePoint)
    if ($reparsePoints.Count) {
        throw "$Context contains reparse points: $($reparsePoints.Path -join ', ')"
    }
    $sensitive = @($entries | Where-Object { Test-SensitiveArtifactPath -RelativePath $_.Path })
    if ($sensitive.Count) {
        throw "$Context contains sensitive paths: $($sensitive.Path -join ', ')"
    }
}

function Get-ArtifactFileEntries {
    param([Parameter(Mandatory)][string]$Root)

    $entries = @(Get-CompleteArtifactEntries -Root $Root | Where-Object { -not $_.IsDirectory })
    return @($entries | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_.Path
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.Item.FullName).Hash.ToLowerInvariant()
        }
    } | Sort-Object path)
}

function Get-ArtifactEntriesHash {
    param([Parameter(Mandatory)][object[]]$Entries)

    $canonical = @($Entries | ForEach-Object { "$($_.path)|$($_.sha256)" }) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}
