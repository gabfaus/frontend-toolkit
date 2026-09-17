[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-ConfigValue {
    param([Parameter(Mandatory)][ValidateSet('global', 'system')][string]$Scope)

    $output = @(& git config "--$Scope" --get core.autocrlf 2>$null)
    return (($output -join [Environment]::NewLine).Trim())
}

function Invoke-GitQuiet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git @Arguments 2>$null)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $exitCode." }
    return $output
}

function Get-ByteCount {
    param([Parameter(Mandatory)][string]$Root)

    return [long]((Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum)
}

function Assert-ByteTreeEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right,
        [Parameter(Mandatory)][string]$Label
    )

    $leftRoot = (Resolve-Path -LiteralPath $Left).Path
    $rightRoot = (Resolve-Path -LiteralPath $Right).Path
    $leftEntries = @(Get-ArtifactFileEntries -Root $leftRoot)
    $rightEntries = @(Get-ArtifactFileEntries -Root $rightRoot)
    $leftFiles = @{}
    $rightFiles = @{}
    foreach ($entry in $leftEntries) { $leftFiles[[string]$entry.path] = Join-Path $leftRoot ($entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar)) }
    foreach ($entry in $rightEntries) { $rightFiles[[string]$entry.path] = Join-Path $rightRoot ($entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar)) }

    $paths = @($leftFiles.Keys) + @($rightFiles.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $uniquePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $paths) {
        if ($uniquePaths.Count -eq 0 -or $uniquePaths[$uniquePaths.Count - 1] -cne $path) { [void]$uniquePaths.Add($path) }
    }

    $differing = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $uniquePaths) {
        if (-not $leftFiles.ContainsKey($path) -or -not $rightFiles.ContainsKey($path)) {
            [void]$differing.Add($path)
            continue
        }
        $leftBytes = [IO.File]::ReadAllBytes($leftFiles[$path])
        $rightBytes = [IO.File]::ReadAllBytes($rightFiles[$path])
        if ($leftBytes.Length -ne $rightBytes.Length) {
            [void]$differing.Add($path)
            continue
        }
        $same = $true
        for ($index = 0; $index -lt $leftBytes.Length; $index++) {
            if ($leftBytes[$index] -ne $rightBytes[$index]) {
                $same = $false
                break
            }
        }
        if (-not $same) { [void]$differing.Add($path) }
    }

    if ($differing.Count) {
        throw "$Label differs in $($differing.Count) files: $(($differing | Select-Object -First 5) -join ', ')"
    }
    return [pscustomobject][ordered]@{
        differingFiles = 0
        fileCount = $leftEntries.Count
        byteCount = Get-ByteCount -Root $leftRoot
    }
}

function Get-ExternalArchiveSpec {
    param([Parameter(Mandatory)]$Dependency)

    if ($Dependency.id -eq 'impeccable') {
        return [pscustomobject][ordered]@{
            paths = @('LICENSE', 'NOTICE.md', 'plugin/skills/impeccable')
            prefix = ''
        }
    }
    return [pscustomobject][ordered]@{
        paths = @('.')
        prefix = 'img2threejs/'
    }
}

function Export-TestArchive {
    param(
        [Parameter(Mandatory)]$Dependency,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ArchivePath
    )

    $spec = Get-ExternalArchiveSpec -Dependency $Dependency
    $allowedExecutables = @(
        'forge/_shared/feature_acceptance_policy.py'
        'forge/stage1_intake/delight_albedo.py'
        'forge/stage1_intake/extract_pbr_evidence.py'
        'forge/stage1_intake/probe_image.py'
        'forge/stage1_intake/solve_camera_pose.py'
        'forge/stage2_spec/new_pre_spec_assessment.py'
        'forge/stage2_spec/new_sculpt_spec.py'
        'forge/stage3_build/bake_projected_texture.py'
        'forge/stage3_build/orchestrate_passes.py'
        'forge/stage4_review/append_review.py'
        'forge/stage4_review/make_comparison_sheet.py'
        'integrations/glb_character_pipeline/build-character.sh'
        'scripts/character_audit.sh'
    )
    if ($Dependency.id -eq 'impeccable') {
        Assert-SafeGitArchiveTree -Repository $Repository -Commit $Dependency.commitSha -Context "$($Dependency.id) canonical archive test" -Paths $spec.paths -AllowedExecutablePaths $allowedExecutables
    } else {
        Assert-SafeGitArchiveTree -Repository $Repository -Commit $Dependency.commitSha -Context "$($Dependency.id) canonical archive test" -AllowedExecutablePaths $allowedExecutables
    }
    $arguments = @{
        Repository = $Repository
        Commit = $Dependency.commitSha
        DestinationArchive = $ArchivePath
        Paths = $spec.paths
        CoreAutocrlf = 'true'
    }
    if ($spec.prefix) { $arguments.Prefix = $spec.prefix }
    Export-CanonicalGitFiles @arguments | Out-Null
}

function Invoke-ReleaseBuilder {
    param(
        [Parameter(Mandatory)][string]$Builder,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Builder -Destination $Destination 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        foreach ($line in $output) { Write-Output ("$Label child: " + [string]$line) }
        throw "$Label failed: $($output -join [Environment]::NewLine)"
    }
}

function Get-ReleaseEvidence {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ZipPath
    )

    $manifestPath = Join-Path $Root 'RELEASE_MANIFEST.json'
    $provenancePath = Join-Path $Root 'plugins/frontend-toolkit/SNAPSHOT_PROVENANCE.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    return [pscustomobject][ordered]@{
        plugin = $manifest.pluginTreeSha256
        artifact = $manifest.artifactTreeSha256
        zip = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
        manifest = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
        provenance = (Get-FileHash -Algorithm SHA256 -LiteralPath $provenancePath).Hash.ToLowerInvariant()
        pluginFiles = [int]$manifest.pluginFileCount
        artifactFiles = [int]$manifest.artifactFileCount
        pluginBytes = Get-ByteCount -Root (Join-Path $Root 'plugins/frontend-toolkit')
        artifactBytes = Get-ByteCount -Root $Root
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$builder = Join-Path $repoRoot 'scripts/build-release-candidate.ps1'
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$helperText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/release-safety.ps1')
Assert-True ($helperText -match 'core\.autocrlf=false' -and $helperText -match 'core\.autocrlf=true') 'Canonical Git archive helper does not expose both explicit process-local autocrlf settings.'
Assert-True ($helperText -match 'ValidatePattern\(') 'Canonical Git archive prefix validation is missing.'

$globalBefore = Get-ConfigValue -Scope global
$systemBefore = Get-ConfigValue -Scope system
$oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$oldGitConfigNoSystem = $env:GIT_CONFIG_NOSYSTEM
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk07a-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$externalEvidence = @{}
$releaseEvidence = @{}

try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $modeConfig = @{}
    foreach ($mode in @('true', 'false')) {
        $configPath = Join-Path $fixture ('git-' + $mode + '.config')
        Invoke-Git @('config', '--file', $configPath, 'core.autocrlf', $mode) | Out-Null
        Invoke-Git @('config', '--file', $configPath, 'core.excludesFile', 'NUL') | Out-Null
        $modeConfig[$mode] = $configPath
    }
    $env:GIT_CONFIG_GLOBAL = $modeConfig['true']
    $env:GIT_CONFIG_NOSYSTEM = '1'

    $baselineExternal = @{}
    foreach ($dependency in $externalLock.dependencies) {
        $checkout = (Resolve-Path (Join-Path $repoRoot $dependency.checkoutPath)).Path
        $safe = $checkout.Replace('\', '/')
        $head = (Invoke-Git @('-c', "safe.directory=$safe", '-C', $checkout, 'rev-parse', 'HEAD') | Select-Object -First 1).Trim()
        Assert-True ($head -ceq $dependency.commitSha) "$($dependency.id) checkout is not at its locked commit."
        $status = @(Invoke-Git @('-c', "safe.directory=$safe", '-C', $checkout, 'status', '--porcelain'))
        Assert-True ($status.Count -eq 0) "$($dependency.id) checkout is dirty before the test."
        $baselineExternal[$dependency.id] = [pscustomobject]@{ path = $checkout; head = $head }
        $externalEvidence[$dependency.id] = @{}
    }

    # Simulate independent true/false worktrees without touching the governed checkouts.
    $cloneRoot = Join-Path $fixture 'external-clones'
    foreach ($dependency in $externalLock.dependencies) {
        foreach ($mode in @('true', 'false')) {
            $clone = Join-Path $cloneRoot ($dependency.id + '/' + $mode)
            New-Item -ItemType Directory -Path (Split-Path $clone) -Force | Out-Null
            Invoke-Git @('-c', "core.autocrlf=$mode", 'clone', '--quiet', '--local', '--no-hardlinks', $baselineExternal[$dependency.id].path, $clone) | Out-Null
            Invoke-Git @('-C', $clone, 'config', 'core.autocrlf', $mode) | Out-Null
            Invoke-Git @('-C', $clone, 'checkout', '--force', '--quiet', $dependency.commitSha) | Out-Null
            $runtimeMarker = Join-Path $clone 'runtime/ignored-marker.txt'
            New-Item -ItemType Directory -Path (Split-Path $runtimeMarker) -Force | Out-Null
            [IO.File]::WriteAllText($runtimeMarker, 'synthetic ignored runtime artifact')
            [IO.File]::AppendAllText((Join-Path $clone '.git/info/exclude'), "runtime/`n")
            $ignoredStatus = @(Invoke-Git @('-C', $clone, 'status', '--porcelain', '--ignored', '--untracked-files=all'))
            Assert-True (@($ignoredStatus | Where-Object { ([string]$_).Contains('runtime/ignored-marker.txt') }).Count -eq 1) "$($dependency.id) ignored runtime fixture was not created."
            $cleanStatus = @(Invoke-Git @('-C', $clone, 'status', '--porcelain'))
            Assert-True ($cleanStatus.Count -eq 0) "$($dependency.id) temporary ignored runtime fixture became tracked."

            $modeRoot = Join-Path $fixture ('external-archives/' + $dependency.id + '/' + $mode)
            $archivePath = Join-Path $fixture ('external-archives/' + $dependency.id + '/' + $mode + '.tar')
            New-Item -ItemType Directory -Path $modeRoot -Force | Out-Null
            Export-TestArchive -Dependency $dependency -Repository $clone -ArchivePath $archivePath
            & tar -xf $archivePath -C $modeRoot
            if ($LASTEXITCODE -ne 0) { throw "$($dependency.id) $mode archive extraction failed." }
            $archiveEntries = @(Get-ArtifactFileEntries -Root $modeRoot)
            Assert-True (@($archiveEntries | Where-Object { $_.path -match 'runtime/ignored-marker\.txt$' }).Count -eq 0) "$($dependency.id) included an ignored/runtime artifact in its archive."
            Assert-True (@($archiveEntries | Where-Object { $_.path -match '(^|/)\.git(/|$)' }).Count -eq 0) "$($dependency.id) included Git metadata in its archive."

            if ($dependency.id -eq 'img2threejs') {
                $snapshotRoot = Join-Path $fixture ('external-snapshots/' + $dependency.id + '/' + $mode)
                New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
                Get-ChildItem -LiteralPath (Join-Path $modeRoot 'img2threejs') -Force | Copy-Item -Destination $snapshotRoot -Recurse -Force
            } else {
                $snapshotRoot = $modeRoot
            }
            $componentHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root $snapshotRoot)
            Assert-True ($componentHash -ceq $dependency.snapshotTreeSha256) "$($dependency.id) archive does not satisfy the current external.lock component hash contract."
            $expectedCount = if ($dependency.id -eq 'impeccable') { 150 } else { 333 }
            Assert-True (@(Get-ArtifactFileEntries -Root $snapshotRoot).Count -eq $expectedCount) "$($dependency.id) archive file count drifted."
            $externalEvidence[$dependency.id][$mode] = [pscustomobject][ordered]@{
                archiveSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
                files = $expectedCount
                bytes = Get-ByteCount -Root $snapshotRoot
                componentHash = $componentHash
                archiveRoot = $modeRoot
                snapshotRoot = $snapshotRoot
            }
        }
        $trueEvidence = $externalEvidence[$dependency.id]['true']
        $falseEvidence = $externalEvidence[$dependency.id]['false']
        $byteComparison = Assert-ByteTreeEqual -Left $trueEvidence.archiveRoot -Right $falseEvidence.archiveRoot -Label "$($dependency.id) external archive materialization"
        Assert-True ($trueEvidence.archiveSha256 -ceq $falseEvidence.archiveSha256) "$($dependency.id) raw canonical archive bytes differ across worktree environments."
        Write-Output ("PASS: {0} external archive true/false byte equality; files={1}; bytes={2}; component={3}" -f $dependency.id, $byteComparison.fileCount, $byteComparison.byteCount, $trueEvidence.componentHash)
    }

    foreach ($temporaryExternalRoot in @('external-clones', 'external-archives', 'external-snapshots')) {
        $temporaryPath = Join-Path $fixture $temporaryExternalRoot
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Recurse -Force }
    }

    # Run the real release builder in two isolated Git configuration environments.
    foreach ($mode in @('true', 'false')) {
        $env:GIT_CONFIG_GLOBAL = $modeConfig[$mode]
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $candidate = Join-Path $fixture ('candidates/' + $mode)
        $zipPath = Join-Path $fixture ('candidates/' + $mode + '.zip')
        Invoke-ReleaseBuilder -Builder $builder -Destination $candidate -Label "$mode release candidate"
        New-DeterministicZip -Root $candidate -ZipPath $zipPath
        $releaseEvidence[$mode] = [pscustomobject]@{
            root = $candidate
            zipPath = $zipPath
            identities = Get-ReleaseEvidence -Root $candidate -ZipPath $zipPath
        }
    }

    $trueRelease = $releaseEvidence['true']
    $falseRelease = $releaseEvidence['false']
    $releaseComparison = Assert-ByteTreeEqual -Left $trueRelease.root -Right $falseRelease.root -Label 'release candidate cross-environment output'
    Assert-True ($trueRelease.identities.plugin -ceq $falseRelease.identities.plugin) 'Cross-environment plugin tree hashes differ.'
    Assert-True ($trueRelease.identities.artifact -ceq $falseRelease.identities.artifact) 'Cross-environment artifact tree hashes differ.'
    Assert-True ($trueRelease.identities.zip -ceq $falseRelease.identities.zip) 'Cross-environment ZIP hashes differ.'
    Assert-True ($trueRelease.identities.manifest -ceq $falseRelease.identities.manifest) 'Cross-environment release manifest hashes differ.'
    Assert-True ($trueRelease.identities.provenance -ceq $falseRelease.identities.provenance) 'Cross-environment snapshot provenance hashes differ.'
    Write-Output ("PASS: release true/false byte equality; files={0}; bytes={1}; plugin={2}; artifact={3}; zip={4}; manifest={5}; provenance={6}" -f $releaseComparison.fileCount, $releaseComparison.byteCount, $falseRelease.identities.plugin, $falseRelease.identities.artifact, $falseRelease.identities.zip, $falseRelease.identities.manifest, $falseRelease.identities.provenance)

    # Same-environment determinism and canonical ZIP metadata.
    $env:GIT_CONFIG_GLOBAL = $modeConfig['false']
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $repeatCandidate = Join-Path $fixture 'candidates/false-repeat'
    $repeatZip = Join-Path $fixture 'candidates/false-repeat.zip'
    Invoke-ReleaseBuilder -Builder $builder -Destination $repeatCandidate -Label 'false repeat release candidate'
    New-DeterministicZip -Root $repeatCandidate -ZipPath $repeatZip
    $repeatComparison = Assert-ByteTreeEqual -Left $falseRelease.root -Right $repeatCandidate -Label 'same-environment release candidate output'
    $repeatZipSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $repeatZip).Hash.ToLowerInvariant()
    Assert-True ($repeatZipSha -ceq $falseRelease.identities.zip) 'Same-environment raw ZIP bytes differ.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($falseRelease.zipPath)
    try {
        $zipPaths = [string[]]@($archive.Entries | ForEach-Object FullName)
        $sortedZipPaths = [string[]]$zipPaths.Clone()
        [Array]::Sort($sortedZipPaths, [StringComparer]::Ordinal)
        Assert-True (($zipPaths -join "`n") -ceq ($sortedZipPaths -join "`n")) 'Deterministic ZIP entry ordering drifted from ordinal order.'
        foreach ($entry in $archive.Entries) {
            Assert-True ($entry.LastWriteTime.Year -eq 1980 -and $entry.LastWriteTime.Month -eq 1 -and $entry.LastWriteTime.Day -eq 1 -and $entry.LastWriteTime.Hour -eq 0 -and $entry.LastWriteTime.Minute -eq 0 -and $entry.LastWriteTime.Second -eq 0) "Deterministic ZIP timestamp drifted: $($entry.FullName)"
            Assert-True ($entry.ExternalAttributes -eq 0) "Deterministic ZIP external attributes drifted: $($entry.FullName)"
        }
    } finally { $archive.Dispose() }
    $extractTrue = Join-Path $fixture 'zip-extract/true'
    $extractFalse = Join-Path $fixture 'zip-extract/false'
    New-Item -ItemType Directory -Path $extractTrue, $extractFalse -Force | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($trueRelease.zipPath, $extractTrue)
    [IO.Compression.ZipFile]::ExtractToDirectory($falseRelease.zipPath, $extractFalse)
    Assert-ByteTreeEqual -Left $extractTrue -Right $extractFalse -Label 'cross-environment ZIP extraction' | Out-Null
    Write-Output ("PASS: same-environment candidate bytes and raw ZIP are deterministic; files={0}; bytes={1}; zip={2}" -f $repeatComparison.fileCount, $repeatComparison.byteCount, $repeatZipSha)
    Write-Output 'PASS: ZIP ordering is ordinal, timestamps are 1980-01-01T00:00:00Z, and external attributes are zero.'

    # A runtime artifact added after the build must fail closed before ZIP creation.
    $runtimeArtifact = Join-Path $falseRelease.root 'runtime/ignored-after-build.txt'
    New-Item -ItemType Directory -Path (Split-Path $runtimeArtifact) -Force | Out-Null
    [IO.File]::WriteAllText($runtimeArtifact, 'synthetic runtime artifact')
    $rejectedZip = Join-Path $fixture 'runtime-rejected.zip'
    $rejected = $false
    try { New-DeterministicZip -Root $falseRelease.root -ZipPath $rejectedZip | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'A runtime artifact was accepted into the release ZIP source.'
    if (Test-Path -LiteralPath $rejectedZip) { Remove-Item -LiteralPath $rejectedZip -Force }
    Remove-Item -LiteralPath (Split-Path $runtimeArtifact) -Recurse -Force
    Write-Output 'PASS: unexpected runtime artifacts fail closed and are not normalized into a false reproducibility result.'
} finally {
    $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal
    $env:GIT_CONFIG_NOSYSTEM = $oldGitConfigNoSystem
    if (Test-Path -LiteralPath $fixture) {
        Get-ChildItem -LiteralPath $fixture -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true)
    }
}

Assert-True ($globalBefore -ceq (Get-ConfigValue -Scope global)) 'Global core.autocrlf changed during canonical archive testing.'
Assert-True ($systemBefore -ceq (Get-ConfigValue -Scope system)) 'System core.autocrlf changed during canonical archive testing.'
foreach ($dependency in $externalLock.dependencies) {
    $checkout = (Resolve-Path (Join-Path $repoRoot $dependency.checkoutPath)).Path
    $safe = $checkout.Replace('\', '/')
    $head = (Invoke-GitQuiet @('-c', "safe.directory=$safe", '-C', $checkout, 'rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    Assert-True ($head -ceq $dependency.commitSha) "$($dependency.id) checkout changed during canonical archive testing."
    $status = @(Invoke-GitQuiet @('-c', "safe.directory=$safe", '-C', $checkout, 'status', '--porcelain'))
    Assert-True ($status.Count -eq 0) "$($dependency.id) checkout became dirty during canonical archive testing."
}
Write-Output 'PASS: global/system Git configuration, pinned external commits and external worktrees remained unchanged.'
