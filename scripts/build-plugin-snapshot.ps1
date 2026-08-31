param(
    [Parameter(Mandatory)][string]$Destination
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

Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $pluginSource -FileAllowlist $sourceFileAllowlist -DirectoryAllowlist $sourceDirectoryAllowlist

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
    $approvedSourceTar = Join-Path $stageRoot 'approved-source.tar'
    New-Item -ItemType Directory -Path $approvedSourceRoot, $destinationPath -Force | Out-Null
    $safeRepo = $repoRoot.Replace('\', '/')
    $approvedRepoPaths = @('LICENSE') + @($sourceFileAllowlist | ForEach-Object { 'plugin/frontend-toolkit/' + $_ })
    $archiveArguments = @(
        '-c', "safe.directory=$safeRepo", '-C', $repoRoot,
        'archive', '--format=tar', "--output=$approvedSourceTar", 'HEAD', '--'
    ) + $approvedRepoPaths
    & git @archiveArguments
    Assert-NativeSuccess 'Approved source archive'
    & tar -xf $approvedSourceTar -C $approvedSourceRoot
    Assert-NativeSuccess 'Approved source extraction'

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

    Copy-Item -LiteralPath (Join-Path $impeccableExtract 'plugin/skills/impeccable') -Destination (Join-Path $destinationPath 'skills/impeccable') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $destinationPath 'third_party/impeccable') | Out-Null
    Copy-Item -LiteralPath (Join-Path $impeccableExtract 'LICENSE') -Destination (Join-Path $destinationPath 'third_party/impeccable/LICENSE')
    Copy-Item -LiteralPath (Join-Path $impeccableExtract 'NOTICE.md') -Destination (Join-Path $destinationPath 'third_party/impeccable/NOTICE.md')
    Copy-Item -LiteralPath (Join-Path $img2threejsExtract 'img2threejs') -Destination (Join-Path $destinationPath 'skills/img2threejs') -Recurse

    $impeccableLicenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $destinationPath 'third_party/impeccable/LICENSE')).Hash.ToLowerInvariant()
    $impeccableNoticeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $destinationPath 'third_party/impeccable/NOTICE.md')).Hash.ToLowerInvariant()
    $img2threejsLicenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $destinationPath 'skills/img2threejs/LICENSE')).Hash.ToLowerInvariant()
    if ($impeccableLicenseHash -ne $impeccable.licenseSha256) { throw 'Impeccable license hash mismatch.' }
    if ($impeccableNoticeHash -ne $impeccable.noticeSha256) { throw 'Impeccable NOTICE hash mismatch.' }
    if ($img2threejsLicenseHash -ne $img2threejs.licenseSha256) { throw 'img2threejs license hash mismatch.' }

    $artifactLockPath = Join-Path $destinationPath 'external-skills.lock.json'
    $artifactLock = Get-Content -Raw -LiteralPath $artifactLockPath | ConvertFrom-Json
    $artifactLock.strategy = 'generated-distribution-snapshots'
    foreach ($dependency in $artifactLock.dependencies) { $dependency.bundled = $true }
    [IO.File]::WriteAllText($artifactLockPath, (($artifactLock | ConvertTo-Json -Depth 10) + "`n"), (New-Object Text.UTF8Encoding($false)))

    $provenance = [ordered]@{
        schemaVersion = 1
        generator = 'scripts/build-plugin-snapshot.ps1'
        dependencies = @(
            [ordered]@{ id = 'impeccable'; commitSha = $impeccable.commitSha; skillPath = 'skills/impeccable'; license = 'Apache-2.0'; licenseSha256 = $impeccable.licenseSha256; noticeSha256 = $impeccable.noticeSha256 },
            [ordered]@{ id = 'img2threejs'; commitSha = $img2threejs.commitSha; skillPath = 'skills/img2threejs'; license = 'Apache-2.0'; licenseSha256 = $img2threejs.licenseSha256 }
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
