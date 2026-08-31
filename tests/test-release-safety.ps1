param([switch]$Execute)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginSource = Join-Path $repoRoot 'plugin/frontend-toolkit'
$safetyModule = Join-Path $repoRoot 'scripts/release-safety.ps1'
$snapshotBuilder = Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1'
$releaseBuilder = Join-Path $repoRoot 'scripts/build-release-candidate.ps1'
. $safetyModule

$fileAllowlist = @(Get-FrontendToolkitSourceFileAllowlist)
$directoryAllowlist = @(Get-FrontendToolkitSourceDirectoryAllowlist)
Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $pluginSource -FileAllowlist $fileAllowlist -DirectoryAllowlist $directoryAllowlist

$snapshotText = Get-Content -Raw -LiteralPath $snapshotBuilder
$releaseText = Get-Content -Raw -LiteralPath $releaseBuilder
if ($snapshotText -match 'Copy-Item\s+-LiteralPath\s+\$pluginSource\s+-Destination\s+\$destinationPath\s+-Recurse') {
    throw 'Snapshot builder still recursively copies the local plugin source.'
}
foreach ($required in @('git', 'archive', 'HEAD', 'Assert-ApprovedSourceComposition', 'Assert-NoSensitiveArtifactPaths')) {
    if ($snapshotText -notmatch [regex]::Escape($required)) { throw "Snapshot builder is missing safety contract: $required" }
}
foreach ($required in @('Get-ArtifactFileEntries', 'Assert-NoSensitiveArtifactPaths', 'Assert-ReleaseManifestCoverage', 'artifactFiles')) {
    if ($releaseText -notmatch [regex]::Escape($required)) { throw "Release builder is missing safety contract: $required" }
}

foreach ($sensitive in @(
    '.env', '.env.local', 'auth.json', 'credentials.json', 'cookies.json',
    'private.pem', 'private.key', 'private.pfx', 'private.p12',
    'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519',
    '.ssh/config', '.git/config', 'CODEX_HOME/auth.json',
    'profiles/default', '.cache/state', 'runtimes/node', 'temp/file'
)) {
    if (-not (Test-SensitiveArtifactPath -RelativePath $sensitive)) {
        throw "Sensitive path was not rejected: $sensitive"
    }
}
foreach ($allowed in @('.codex-plugin/plugin.json', '.mcp.json', 'skills/frontend-orchestrator/SKILL.md', 'skills/impeccable/scripts/detector/profile/profiler.mjs')) {
    if (Test-SensitiveArtifactPath -RelativePath $allowed) { throw "Approved path was overblocked: $allowed" }
}

if (-not $Execute) {
    Write-Output 'PASS: release allowlist, denylist and builder contracts validated.'
    return
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk07a1r-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fixturePlugin = Join-Path $fixture 'plugin/frontend-toolkit'
$stageBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Force -Filter 'ftk05b-stage-*' | ForEach-Object FullName)
try {
    foreach ($relativePath in $fileAllowlist) {
        $source = Join-Path $pluginSource $relativePath
        $target = Join-Path $fixturePlugin $relativePath
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target
    }

    $cases = @(
        [pscustomobject]@{ Name = '.env'; File = '.env'; Root = '.env'; Hidden = $false },
        [pscustomobject]@{ Name = 'auth'; File = 'auth.json'; Root = 'auth.json'; Hidden = $false },
        [pscustomobject]@{ Name = 'credentials'; File = 'credentials.json'; Root = 'credentials.json'; Hidden = $false },
        [pscustomobject]@{ Name = 'untracked'; File = 'unexpected.txt'; Root = 'unexpected.txt'; Hidden = $false },
        [pscustomobject]@{ Name = 'ignored'; File = 'unexpected.local.json'; Root = 'unexpected.local.json'; Hidden = $false },
        [pscustomobject]@{ Name = 'hidden'; File = '.hidden-unexpected'; Root = '.hidden-unexpected'; Hidden = $true },
        [pscustomobject]@{ Name = 'nested-git'; File = '.git/config.synthetic'; Root = '.git'; Hidden = $false },
        [pscustomobject]@{ Name = 'private-key-name'; File = 'id_ed25519'; Root = 'id_ed25519'; Hidden = $false }
    )
    foreach ($case in $cases) {
        $attackFile = Join-Path $fixturePlugin $case.File
        New-Item -ItemType Directory -Path (Split-Path $attackFile) -Force | Out-Null
        [IO.File]::WriteAllText($attackFile, 'synthetic release-safety marker', (New-Object Text.UTF8Encoding($false)))
        if ($case.Hidden) { (Get-Item -Force -LiteralPath $attackFile).Attributes = [IO.FileAttributes]::Hidden }

        $rejected = $false
        try {
            Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $fixturePlugin -FileAllowlist $fileAllowlist -DirectoryAllowlist $directoryAllowlist
        } catch {
            $rejected = $true
        }
        if (-not $rejected) { throw "Synthetic attack was accepted: $($case.Name)" }

        $attackRoot = Join-Path $fixturePlugin $case.Root
        if (Test-Path -LiteralPath $attackRoot -PathType Container) {
            [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($attackRoot), $true)
        } elseif (Test-Path -LiteralPath $attackRoot) {
            (Get-Item -Force -LiteralPath $attackRoot).Attributes = [IO.FileAttributes]::Normal
            Remove-Item -Force -LiteralPath $attackRoot
        }
        Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $fixturePlugin -FileAllowlist $fileAllowlist -DirectoryAllowlist $directoryAllowlist
    }
    Write-Output 'PASS: synthetic .env, auth, credentials, untracked, ignored, hidden, nested Git and private-key paths fail closed.'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true)
    }
}

$stageAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Force -Filter 'ftk05b-stage-*' | ForEach-Object FullName)
if ((($stageBefore | Sort-Object) -join "`n") -cne (($stageAfter | Sort-Object) -join "`n")) {
    throw 'Synthetic source attacks left snapshot stage state.'
}
if (Test-Path -LiteralPath $fixture) { throw 'Release-safety fixture teardown failed.' }
Write-Output 'PASS: synthetic release-safety fixture teardown completed.'
