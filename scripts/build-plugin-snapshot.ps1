param(
    [Parameter(Mandatory)][string]$Destination,
    [switch]$DevelopmentWorkingTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-safety.ps1')

function Assert-NativeSuccess {
    param([Parameter(Mandatory)][string]$Operation)
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginSource = Join-Path $repoRoot 'plugin/frontend-toolkit'
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$destinationPath = [IO.Path]::GetFullPath($Destination)
$sourceFileAllowlist = @(Get-FrontendToolkitSourceFileAllowlist)
$sourceDirectoryAllowlist = @(Get-FrontendToolkitSourceDirectoryAllowlist)

Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $pluginSource -FileAllowlist $sourceFileAllowlist -DirectoryAllowlist $sourceDirectoryAllowlist -AllowWorkingTree:$DevelopmentWorkingTree

if (Test-Path -LiteralPath $destinationPath) { throw "Destination already exists: $destinationPath" }
if ($destinationPath.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $repoRoot.StartsWith($destinationPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Destination would replace or contain the repository.'
}
foreach ($protected in @($pluginSource) + @($externalLock.dependencies | ForEach-Object { (Resolve-Path (Join-Path $repoRoot $_.checkoutPath)).Path })) {
    $protectedPath = [IO.Path]::GetFullPath($protected)
    if ($destinationPath.Equals($protectedPath, [StringComparison]::OrdinalIgnoreCase) -or
        $destinationPath.StartsWith($protectedPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $protectedPath.StartsWith($destinationPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Destination overlaps a protected source: $protectedPath"
    }
}

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('ftk05b-stage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Path (Split-Path $destinationPath), $stageRoot -Force | Out-Null
    $approvedSourceRoot = Join-Path $stageRoot 'approved-source'
    New-Item -ItemType Directory -Path $approvedSourceRoot, $destinationPath -Force | Out-Null
    if ($DevelopmentWorkingTree) {
        New-Item -ItemType Directory -Path (Join-Path $approvedSourceRoot 'plugin/frontend-toolkit') -Force | Out-Null
        foreach ($relativePath in $sourceFileAllowlist) {
            $sourcePath = Join-Path $pluginSource $relativePath
            $approvedPath = Join-Path $approvedSourceRoot ('plugin/frontend-toolkit/' + $relativePath)
            New-Item -ItemType Directory -Path (Split-Path $approvedPath) -Force | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $approvedPath
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $approvedSourceRoot 'LICENSE')
    } else {
        $approvedSourceTar = Join-Path $stageRoot 'approved-source.tar'
        $safeRepo = $repoRoot.Replace('\', '/')
        $approvedRepoPaths = @('LICENSE') + @($sourceFileAllowlist | ForEach-Object { 'plugin/frontend-toolkit/' + $_ })
        Assert-SafeGitArchiveTree -Repository $repoRoot -Commit 'HEAD' -Context 'approved source' -Paths $approvedRepoPaths
        $archiveArguments = @(
            '-c', "safe.directory=$safeRepo", '-C', $repoRoot,
            'archive', '--format=tar', "--output=$approvedSourceTar", 'HEAD', '--'
        ) + $approvedRepoPaths
        & git @archiveArguments
        Assert-NativeSuccess 'Approved source archive'
        & tar -xf $approvedSourceTar -C $approvedSourceRoot
        Assert-NativeSuccess 'Approved source extraction'
    }

    foreach ($relativePath in $sourceFileAllowlist) {
        $sourcePath = Join-Path $approvedSourceRoot ('plugin/frontend-toolkit/' + $relativePath)
        $targetPath = Join-Path $destinationPath $relativePath
        New-Item -ItemType Directory -Path (Split-Path $targetPath) -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath
    }
    Copy-Item -LiteralPath (Join-Path $approvedSourceRoot 'LICENSE') -Destination (Join-Path $destinationPath 'LICENSE')

    $impeccable = $externalLock.dependencies | Where-Object id -eq 'impeccable'
    $img2threejs = $externalLock.dependencies | Where-Object id -eq 'img2threejs'
    foreach ($dependency in @($impeccable, $img2threejs)) {
        $checkout = (Resolve-Path (Join-Path $repoRoot $dependency.checkoutPath)).Path
        $safeCheckout = $checkout.Replace('\', '/')
        $head = (& git -c "safe.directory=$safeCheckout" -C $checkout rev-parse HEAD).Trim()
        Assert-NativeSuccess "$($dependency.id) HEAD resolution"
        if ($head -ne $dependency.commitSha) { throw "$($dependency.id) checkout is not at the locked SHA." }
        if (& git -c "safe.directory=$safeCheckout" -C $checkout status --porcelain) {
            throw "$($dependency.id) checkout is dirty."
        }
    }

    $impeccableCheckout = (Resolve-Path (Join-Path $repoRoot $impeccable.checkoutPath)).Path
    $img2threejsCheckout = (Resolve-Path (Join-Path $repoRoot $img2threejs.checkoutPath)).Path
    $impeccableTar = Join-Path $stageRoot 'impeccable.tar'
    $img2threejsTar = Join-Path $stageRoot 'img2threejs.tar'
    Assert-SafeGitArchiveTree -Repository $impeccableCheckout -Commit $impeccable.commitSha -Context 'Impeccable snapshot' -Paths @('LICENSE', 'NOTICE.md', 'plugin/skills/impeccable')
    $img2threejsExecutables = @(
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
    Assert-SafeGitArchiveTree -Repository $img2threejsCheckout -Commit $img2threejs.commitSha -Context 'img2threejs snapshot' -AllowedExecutablePaths $img2threejsExecutables
    & git -c "safe.directory=$($impeccableCheckout.Replace('\','/'))" -C $impeccableCheckout archive --format=tar --output=$impeccableTar $impeccable.commitSha -- LICENSE NOTICE.md plugin/skills/impeccable
    Assert-NativeSuccess 'Impeccable archive'
    & git -c "safe.directory=$($img2threejsCheckout.Replace('\','/'))" -C $img2threejsCheckout archive --format=tar --output=$img2threejsTar --prefix=img2threejs/ $img2threejs.commitSha
    Assert-NativeSuccess 'img2threejs archive'

    $impeccableExtract = Join-Path $stageRoot 'impeccable'
    $img2threejsExtract = Join-Path $stageRoot 'img2threejs'
    New-Item -ItemType Directory -Path $impeccableExtract, $img2threejsExtract | Out-Null
    & tar -xf $impeccableTar -C $impeccableExtract
    Assert-NativeSuccess 'Impeccable extraction'
    & tar -xf $img2threejsTar -C $img2threejsExtract
    Assert-NativeSuccess 'img2threejs extraction'

    $upstreamRoot = Join-Path $destinationPath 'third_party/upstreams'
    $impeccableSnapshot = Join-Path $upstreamRoot 'impeccable'
    $img2threejsSnapshot = Join-Path $upstreamRoot 'img2threejs'
    New-Item -ItemType Directory -Path $upstreamRoot, $impeccableSnapshot | Out-Null
    Copy-Item -LiteralPath (Join-Path $impeccableExtract 'LICENSE') -Destination (Join-Path $impeccableSnapshot 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $impeccableExtract 'NOTICE.md') -Destination (Join-Path $impeccableSnapshot 'NOTICE.md')
    New-Item -ItemType Directory -Path (Join-Path $impeccableSnapshot 'plugin/skills') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $impeccableExtract 'plugin/skills/impeccable') -Destination (Join-Path $impeccableSnapshot 'plugin/skills/impeccable') -Recurse
    Copy-Item -LiteralPath (Join-Path $img2threejsExtract 'img2threejs') -Destination $img2threejsSnapshot -Recurse

    $impeccableLicenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $impeccableSnapshot 'LICENSE')).Hash.ToLowerInvariant()
    $impeccableNoticeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $impeccableSnapshot 'NOTICE.md')).Hash.ToLowerInvariant()
    $img2threejsLicenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $img2threejsSnapshot 'LICENSE')).Hash.ToLowerInvariant()
    if ($impeccableLicenseHash -ne $impeccable.licenseSha256) { throw 'Impeccable license hash mismatch.' }
    if ($impeccableNoticeHash -ne $impeccable.noticeSha256) { throw 'Impeccable NOTICE hash mismatch.' }
    if ($img2threejsLicenseHash -ne $img2threejs.licenseSha256) { throw 'img2threejs license hash mismatch.' }

    foreach ($dependency in @($impeccable, $img2threejs)) {
        $adapterEntry = Join-Path $destinationPath ($dependency.distributionAdapterPath + '/SKILL.md')
        $adapterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $adapterEntry).Hash.ToLowerInvariant()
        if ($adapterHash -ne $dependency.adapterEntrySha256) { throw "$($dependency.id) adapter hash mismatch." }
        $snapshot = Join-Path $destinationPath $dependency.upstreamSnapshotPath
        $snapshotHash = Get-ArtifactEntriesHash -Entries @(Get-ArtifactFileEntries -Root $snapshot)
        if ($snapshotHash -ne $dependency.snapshotTreeSha256) { throw "$($dependency.id) snapshot tree hash mismatch." }
    }

    $artifactLockPath = Join-Path $destinationPath 'external-skills.lock.json'
    $artifactLock = Get-Content -Raw -LiteralPath $artifactLockPath | ConvertFrom-Json
    foreach ($dependency in $artifactLock.dependencies) { $dependency.upstreamSnapshotBundled = $true }
    [IO.File]::WriteAllText($artifactLockPath, (($artifactLock | ConvertTo-Json -Depth 10) + "`n"), (New-Object Text.UTF8Encoding($false)))

    $provenance = [ordered]@{
        schemaVersion = 2
        generator = 'scripts/build-plugin-snapshot.ps1'
        architecture = 'ftk-owned-mediated-adapter'
        sourceComposition = 'explicit-file-allowlist'
        adapters = @(
            [ordered]@{ id = 'impeccable'; path = $impeccable.distributionAdapterPath; sha256 = $impeccable.adapterEntrySha256; owner = 'Frontend Toolkit' },
            [ordered]@{ id = 'img2threejs'; path = $img2threejs.distributionAdapterPath; sha256 = $img2threejs.adapterEntrySha256; owner = 'Frontend Toolkit' }
        )
        upstreamSnapshots = @(
            [ordered]@{ id = 'impeccable'; commitSha = $impeccable.commitSha; path = $impeccable.upstreamSnapshotPath; treeSha256 = $impeccable.snapshotTreeSha256; license = 'Apache-2.0'; licenseSha256 = $impeccable.licenseSha256; noticeSha256 = $impeccable.noticeSha256 },
            [ordered]@{ id = 'img2threejs'; commitSha = $img2threejs.commitSha; path = $img2threejs.upstreamSnapshotPath; treeSha256 = $img2threejs.snapshotTreeSha256; license = 'Apache-2.0'; licenseSha256 = $img2threejs.licenseSha256 }
        )
    }
    [IO.File]::WriteAllText((Join-Path $destinationPath 'SNAPSHOT_PROVENANCE.json'), (($provenance | ConvertTo-Json -Depth 10) + "`n"), (New-Object Text.UTF8Encoding($false)))
    Assert-NoSensitiveArtifactPaths -Root $destinationPath -Context 'plugin distribution'
    Write-Output ([pscustomobject]@{
        Destination = $destinationPath
        Skills = 'frontend-orchestrator,impeccable,img2threejs'
        SourceCommits = "$($impeccable.commitSha),$($img2threejs.commitSha)"
        Licenses = 'Apache-2.0,Apache-2.0'
    })
} catch {
    if (Test-Path -LiteralPath $destinationPath) {
        [IO.Directory]::Delete('\\?\' + $destinationPath, $true)
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stageRoot) {
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($stageRoot), $true)
    }
}
