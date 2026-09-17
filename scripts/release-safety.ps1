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

    $actualSorted = @(Sort-OrdinalStrings -Values $Actual)
    $expectedSorted = @(Sort-OrdinalStrings -Values $Expected)
    if (($actualSorted -join "`n") -cne ($expectedSorted -join "`n")) {
        $unexpected = @($actualSorted | Where-Object { $_ -cnotin $expectedSorted })
        $missing = @($expectedSorted | Where-Object { $_ -cnotin $actualSorted })
        throw "$Name diverged. Unexpected: $($unexpected -join ', '); missing: $($missing -join ', ')"
    }
}

function Assert-SafeArchiveEntry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('file', 'directory', 'symlink', 'gitlink', 'reparse', 'other')][string]$EntryType,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Context,
        [string[]]$AllowedExecutablePaths = @()
    )

    $normalized = $Path.Replace([char]92, [char]47)
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        [IO.Path]::IsPathRooted($Path) -or
        $normalized.StartsWith('/') -or
        $normalized -match '^[A-Za-z]:') {
        throw "$Context contains an absolute or empty archive path: $Path"
    }
    $segments = @($normalized.Split('/') | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0 -or $segments -contains '..' -or $segments -contains '.') {
        throw "$Context contains archive traversal or an ambiguous path: $Path"
    }
    if (@($segments | Where-Object { $_.Equals('.git', [StringComparison]::OrdinalIgnoreCase) }).Count) {
        throw "$Context contains nested Git metadata: $Path"
    }
    if ($EntryType -in @('symlink', 'gitlink', 'reparse', 'other')) {
        throw "$Context contains an unsupported archive entry type $EntryType at $Path"
    }
    if ($Mode -eq '100755' -and $normalized -cnotin $AllowedExecutablePaths) {
        throw "$Context contains an unexpected executable: $Path"
    }
}

function Assert-SafeGitArchiveTree {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$Context,
        [string[]]$Paths = @(),
        [string[]]$AllowedExecutablePaths = @()
    )

    $safeRepository = [IO.Path]::GetFullPath($Repository).Replace([char]92, [char]47)
    $arguments = @('-c', "safe.directory=$safeRepository", '-C', $Repository, '-c', 'core.quotepath=true', 'ls-tree', '-r', '--full-tree', $Commit)
    if ($Paths.Count) { $arguments += @('--') + $Paths }
    $lines = @(& git @arguments)
    Assert-ReleaseNativeSuccess "$Context tree inventory"
    if (-not $lines.Count) { throw "$Context archive selection is empty." }

    foreach ($line in $lines) {
        if ($line -notmatch '^(?<mode>[0-9]{6}) (?<type>[a-z]+) [0-9a-f]+\t(?<path>.+)$') {
            throw "$Context contains an unparseable Git tree entry."
        }
        $path = $Matches.path
        if ($path.StartsWith('"')) { throw "$Context contains a quoted or control-character path: $path" }
        $entryType = if ($Matches.mode -eq '120000') {
            'symlink'
        } elseif ($Matches.mode -eq '160000' -or $Matches.type -eq 'commit') {
            'gitlink'
        } elseif ($Matches.type -eq 'blob') {
            'file'
        } else {
            'other'
        }
        Assert-SafeArchiveEntry -Path $path -EntryType $entryType -Mode $Matches.mode -Context $Context -AllowedExecutablePaths $AllowedExecutablePaths
    }
}

function Export-CanonicalGitFiles {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$DestinationArchive,
        [Parameter(Mandatory)][string[]]$Paths
    )

    $safeRepository = [IO.Path]::GetFullPath($Repository).Replace([char]92, [char]47)
    $arguments = @(
        '-c', "safe.directory=$safeRepository",
        '-C', $Repository,
        '-c', 'core.autocrlf=false',
        'archive', '--format=tar', "--output=$DestinationArchive", $Commit, '--'
    ) + $Paths
    & git @arguments
    Assert-ReleaseNativeSuccess 'Canonical Git archive'
}

function Get-CanonicalLfBytes {
    param([Parameter(Mandatory)][string]$Path)

    $source = [IO.File]::ReadAllBytes($Path)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    for ($index = 0; $index -lt $source.Length; $index++) {
        if ($source[$index] -eq 13 -and $index + 1 -lt $source.Length -and $source[$index + 1] -eq 10) {
            [void]$bytes.Add(10)
            $index++
        } else {
            [void]$bytes.Add($source[$index])
        }
    }
    return $bytes.ToArray()
}

function Get-CanonicalLfFileHash {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash((Get-CanonicalLfBytes -Path $Path)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Assert-AdapterEntryIntegrity {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object[]]$Dependencies
    )

    foreach ($dependency in $Dependencies) {
        $adapterEntry = Join-Path $Root ($dependency.distributionAdapterPath + '/SKILL.md')
        if ([IO.Path]::GetFileName($adapterEntry) -cne 'SKILL.md') { throw 'Adapter integrity canonicalization is restricted to SKILL.md.' }
        if (-not (Test-Path -LiteralPath $adapterEntry -PathType Leaf)) {
            throw "$($dependency.id) adapter entry is missing: $adapterEntry"
        }
        $observed = Get-CanonicalLfFileHash -Path $adapterEntry
        if ($observed -cne $dependency.adapterEntrySha256) {
            throw "$($dependency.id) adapter hash mismatch. Expected: $($dependency.adapterEntrySha256); observed: $observed"
        }
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
        'skills/figma-design-to-code/SKILL.md'
        'skills/impeccable/SKILL.md'
        'skills/img2threejs/SKILL.md'
        'security/effect-policy.json'
        'security/execution-contract.ps1'
        'security/img2threejs-codec-mediator.mjs'
        'security/img2threejs-foundation.ps1'
        'security/img2threejs-runner.ps1'
        'security/img2threejs-runtime-policy.json'
        'security/img2threejs-state-guard.ps1'
        'security/img2threejs-structural-validation.ps1'
        'security/impeccable-authority-policy.json'
        'security/impeccable-context-extractor.mjs'
        'security/impeccable-context-mediator.mjs'
        'security/impeccable-detector.mjs'
        'security/impeccable-static-runtime.mjs'
        'security/impeccable-network-client.mjs'
        'security/impeccable-operation-policy.json'
        'security/impeccable-runner.ps1'
        'security/invoke-capability.ps1'
        'security/context7-operation-policy.json'
        'security/figma-capability-mediator.mjs'
        'security/figma-operation-policy.json'
        'figma.remote.mcp.json'
        'figma-desktop.mcp.json'
        'FIGMA_THIRD_PARTY_NOTICE.md'
        'security/storybook-adapter.mjs'
        'security/design-motion-adapter.mjs'
        'security/design-motion-contract.ps1'
        'security/design-motion-runner.ps1'
        'security/design-motion-source-verifier.ps1'
    )
}

function Get-FrontendToolkitSourceDirectoryAllowlist {
    return @(
        '.codex-plugin'
        'skills'
        'skills/frontend-orchestrator'
        'skills/frontend-orchestrator/references'
        'skills/impeccable'
        'skills/img2threejs'
        'skills/figma-design-to-code'
        'security'
    )
}

function Get-FrontendToolkitDistributionSkillAllowlist {
    $skillNames = @(Get-FrontendToolkitSourceDirectoryAllowlist |
        Where-Object { $_ -match '^skills/[^/]+$' } |
        ForEach-Object { $_.Substring('skills/'.Length) })
    return @(Sort-OrdinalStrings -Values $skillNames)
}

function Assert-ApprovedSourceComposition {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PluginSource,
        [Parameter(Mandatory)][string[]]$FileAllowlist,
        [Parameter(Mandatory)][string[]]$DirectoryAllowlist,
        [switch]$AllowWorkingTree
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

    if (-not $AllowWorkingTree) {
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

function Sort-OrdinalStrings {
    param([Parameter(Mandatory)][string[]]$Values)

    $sorted = @($Values)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

function Sort-ArtifactEntriesOrdinal {
    param([Parameter(Mandatory)][object[]]$Entries)

    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Entries) { [void]$sorted.Add($entry) }
    $sorted.Sort([System.Comparison[object]]{
        param($left, $right)
        return [StringComparer]::Ordinal.Compare([string]$left.path, [string]$right.path)
    })
    return @($sorted)
}

function Get-AllowedGovernedRuntimeRoots {
    param([AllowEmptyCollection()][string[]]$AllowedGovernedRuntimeRoots = @())

    $roots = @()
    foreach ($root in @($AllowedGovernedRuntimeRoots)) {
        if ($root -cne 'security/claude/runtime') {
            throw 'Only the exact governed Claude runtime root may be allowlisted.'
        }
        $roots += $root
    }
    return @($roots | Select-Object -Unique)
}

function Test-PathUnderExactGovernedRuntimeRoot {
    param(
        [Parameter(Mandatory)][string]$NormalizedPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedGovernedRuntimeRoots
    )

    foreach ($root in @($AllowedGovernedRuntimeRoots)) {
        if ($NormalizedPath -ceq $root -or $NormalizedPath.StartsWith($root + '/', [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Test-SensitiveArtifactPath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [AllowEmptyCollection()][string[]]$AllowedGovernedRuntimeRoots = @()
    )

    $allowedRoots = @(Get-AllowedGovernedRuntimeRoots -AllowedGovernedRuntimeRoots $AllowedGovernedRuntimeRoots)
    $normalized = $RelativePath.Replace('\', '/').Trim('/')
    $segments = @($normalized.Split('/') | Where-Object { $_ })
    if (-not $segments.Count) { return $false }

    $leaf = $segments[-1].ToLowerInvariant()
    $lowerSegments = @($segments | ForEach-Object { $_.ToLowerInvariant() })
    if ($leaf -eq '.env' -or $leaf.StartsWith('.env.')) { return $true }
    if ($leaf -in @('auth.json', 'credentials.json', 'cookies.json', 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519')) { return $true }
    if ([IO.Path]::GetExtension($leaf) -in @('.pem', '.key', '.pfx', '.p12')) { return $true }

    $isInsideExactRuntimeRoot = Test-PathUnderExactGovernedRuntimeRoot -NormalizedPath $normalized -AllowedGovernedRuntimeRoots $allowedRoots
    $runtimeRootSegmentIndex = -1
    if ($isInsideExactRuntimeRoot) { $runtimeRootSegmentIndex = 2 }
    for ($index = 0; $index -lt $lowerSegments.Count; $index++) {
        $segment = $lowerSegments[$index]
        if ($segment -in @('runtime', 'runtimes')) {
            if ($isInsideExactRuntimeRoot -and $index -eq $runtimeRootSegmentIndex -and $segment -eq 'runtime') { continue }
            return $true
        }
        if ($allowedRoots.Count -gt 0 -and $segment.StartsWith('runtime', [StringComparison]::Ordinal)) { return $true }
        if ($segment -in @('.git', '.ssh', '.codex', 'profiles', '.cache', 'cache', 'caches', 'temp', 'tmp')) { return $true }
    }
    if (@($lowerSegments | Where-Object { $_ -match '^codex[-_]?home$' }).Count) { return $true }
    return $false
}

function Assert-NoSensitiveArtifactPaths {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Context = 'artifact',
        [AllowEmptyCollection()][string[]]$AllowedGovernedRuntimeRoots = @()
    )

    $allowedRoots = @(Get-AllowedGovernedRuntimeRoots -AllowedGovernedRuntimeRoots $AllowedGovernedRuntimeRoots)
    $entries = @(Get-CompleteArtifactEntries -Root $Root)
    $reparsePoints = @($entries | Where-Object IsReparsePoint)
    if ($reparsePoints.Count) {
        throw "$Context contains reparse points: $($reparsePoints.Path -join ', ')"
    }
    $sensitive = @($entries | Where-Object { Test-SensitiveArtifactPath -RelativePath $_.Path -AllowedGovernedRuntimeRoots $allowedRoots })
    if ($sensitive.Count) {
        throw "$Context contains sensitive paths: $($sensitive.Path -join ', ')"
    }
}

function Get-ArtifactFileEntries {
    param([Parameter(Mandatory)][string]$Root)

    $allEntries = @(Get-CompleteArtifactEntries -Root $Root)
    $reparsePoints = @($allEntries | Where-Object IsReparsePoint)
    if ($reparsePoints.Count) {
        throw "Artifact tree contains reparse points: $($reparsePoints.Path -join ', ')"
    }
    $entries = @($allEntries | Where-Object { -not $_.IsDirectory } | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_.Path
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.Item.FullName).Hash.ToLowerInvariant()
        }
    })
    if (-not $entries.Count) { return @() }
    return @(Sort-ArtifactEntriesOrdinal -Entries $entries)
}

function Get-ArtifactEntriesHash {
    param([Parameter(Mandatory)][object[]]$Entries)

    $orderedEntries = if ($Entries.Count) { @(Sort-ArtifactEntriesOrdinal -Entries $Entries) } else { @() }
    $canonical = @($orderedEntries | ForEach-Object { "$($_.path)|$($_.sha256)" }) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}
function Get-FrontendToolkitSecurityModuleAllowlist {
    return @(
        'effect-policy.json'
        'execution-contract.ps1'
        'img2threejs-codec-mediator.mjs'
        'img2threejs-foundation.ps1'
        'img2threejs-runner.ps1'
        'img2threejs-runtime-policy.json'
        'img2threejs-state-guard.ps1'
        'img2threejs-structural-validation.ps1'
        'impeccable-authority-policy.json'
        'impeccable-context-extractor.mjs'
        'impeccable-context-mediator.mjs'
        'impeccable-detector.mjs'
        'impeccable-static-runtime.mjs'
        'impeccable-network-client.mjs'
        'impeccable-operation-policy.json'
        'impeccable-runner.ps1'
        'invoke-capability.ps1'
        'context7-operation-policy.json'
        'figma-capability-mediator.mjs'
        'figma-operation-policy.json'
        'storybook-adapter.mjs'
        'design-motion-adapter.mjs'
        'design-motion-contract.ps1'
        'design-motion-runner.ps1'
        'design-motion-source-verifier.ps1'
    )
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ZipPath,
        [AllowEmptyCollection()][string[]]$AllowedGovernedRuntimeRoots = @()
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $zipFullPath = [IO.Path]::GetFullPath($ZipPath)
    if (Test-Path -LiteralPath $zipFullPath) { throw "ZIP destination already exists: $zipFullPath" }
    Assert-NoSensitiveArtifactPaths -Root $rootPath -Context 'deterministic ZIP source' -AllowedGovernedRuntimeRoots $AllowedGovernedRuntimeRoots

    $paths = @((Get-ArtifactFileEntries -Root $rootPath) | ForEach-Object { [string]$_.path })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $zipParent = Split-Path -Parent $zipFullPath
    if ($zipParent) { New-Item -ItemType Directory -Path $zipParent -Force | Out-Null }

    $zipStream = $null
    $archive = $null
    try {
        $zipStream = [IO.FileStream]::new($zipFullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $archive = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
        # Policy: files only, ordinal slash paths, Optimal compression, fixed ZIP-safe UTC epoch, no external attributes.
        $fixedTimestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        foreach ($path in $paths) {
            $entry = $archive.CreateEntry($path, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $entry.ExternalAttributes = 0
            $source = $null
            $target = $null
            try {
                $source = [IO.File]::OpenRead((Join-Path $rootPath ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))))
                $target = $entry.Open()
                $source.CopyTo($target)
            } finally {
                if ($target) { $target.Dispose() }
                if ($source) { $source.Dispose() }
            }
        }
    } finally {
        if ($archive) { $archive.Dispose() }
        if ($zipStream) { $zipStream.Dispose() }
    }
}
