param([switch]$Execute)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginSource = Join-Path $repoRoot 'plugin/frontend-toolkit'
$safetyModule = Join-Path $repoRoot 'scripts/release-safety.ps1'
$snapshotBuilder = Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1'
$releaseBuilder = Join-Path $repoRoot 'scripts/build-release-candidate.ps1'
$lockReconciler = Join-Path $repoRoot 'scripts/reconcile-committed-head-locks.ps1'
. $safetyModule

$fileAllowlist = @(Get-FrontendToolkitSourceFileAllowlist)
$directoryAllowlist = @(Get-FrontendToolkitSourceDirectoryAllowlist)
$requiredSecurityFiles = @(
    'security/effect-policy.json'
    'security/img2threejs-codec-mediator.mjs'
    'security/img2threejs-foundation.ps1'
    'security/img2threejs-runner.ps1'
    'security/img2threejs-runtime-policy.json'
    'security/img2threejs-state-guard.ps1'
    'security/img2threejs-structural-validation.ps1'
    'security/invoke-capability.ps1'
)
$actualSecurityFiles = @(Get-ChildItem -LiteralPath (Join-Path $pluginSource 'security') -File -Force |
    ForEach-Object { 'security/' + $_.Name })
$allowlistedSecurityFiles = @($fileAllowlist | Where-Object { $_.StartsWith('security/', [StringComparison]::Ordinal) })
Assert-ExactStringSet -Name 'FTK-owned security files' -Actual $actualSecurityFiles -Expected $requiredSecurityFiles
Assert-ExactStringSet -Name 'FTK-owned security allowlist' -Actual $allowlistedSecurityFiles -Expected $requiredSecurityFiles
Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $pluginSource -FileAllowlist $fileAllowlist -DirectoryAllowlist $directoryAllowlist -AllowWorkingTree

$snapshotText = Get-Content -Raw -LiteralPath $snapshotBuilder
$releaseText = Get-Content -Raw -LiteralPath $releaseBuilder
$reconcilerText = Get-Content -Raw -LiteralPath $lockReconciler
if ($snapshotText -match 'Copy-Item\s+-LiteralPath\s+\$pluginSource\s+-Destination\s+\$destinationPath\s+-Recurse') {
    throw 'Snapshot builder still recursively copies the local plugin source.'
}
foreach ($required in @('Export-CanonicalGitFiles', 'HEAD', 'Assert-ApprovedSourceComposition', 'Assert-AdapterEntryIntegrity', 'Assert-NoSensitiveArtifactPaths')) {
    if ($snapshotText -notmatch [regex]::Escape($required)) { throw "Snapshot builder is missing safety contract: $required" }
}
if ((Get-Command Export-CanonicalGitFiles).Definition -notmatch [regex]::Escape('core.autocrlf=false')) {
    throw 'Canonical Git export does not disable checkout line-ending conversion.'
}
foreach ($required in @('Get-ArtifactFileEntries', 'Assert-NoSensitiveArtifactPaths', 'Assert-ReleaseManifestCoverage', 'artifactFiles', 'DevelopmentWorkingTree')) {
    if ($releaseText -notmatch [regex]::Escape($required)) { throw "Release builder is missing safety contract: $required" }
}
foreach ($required in @('SourceMode', 'CommittedHead', 'DevelopmentWorkingTree is diagnostic-only', 'ExpectedCommit', 'independentBuildCount', 'Set-JsonHashProperty')) {
    if ($reconcilerText -notmatch [regex]::Escape($required)) { throw "Lock reconciler is missing safety contract: $required" }
}
if ($reconcilerText -match '&\s+\$builder[^\r\n]*DevelopmentWorkingTree') {
    throw 'Lock reconciler can pass DevelopmentWorkingTree to the release builder.'
}
$persistentHashWriters = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -File -Filter '*.ps1' | Where-Object {
    $text = Get-Content -Raw -LiteralPath $_.FullName
    $text -match 'observed(Snapshot|Plugin|Artifact)TreeSha256' -and $text -match 'WriteAllText'
})
if ($persistentHashWriters.Count -ne 1 -or $persistentHashWriters[0].FullName -cne $lockReconciler) {
    throw "Persistent hash writers are not confined to the committed-HEAD reconciler: $($persistentHashWriters.Name -join ', ')"
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
            Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $fixturePlugin -FileAllowlist $fileAllowlist -DirectoryAllowlist $directoryAllowlist -AllowWorkingTree
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
        Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $fixturePlugin -FileAllowlist $fileAllowlist -DirectoryAllowlist $directoryAllowlist -AllowWorkingTree
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
