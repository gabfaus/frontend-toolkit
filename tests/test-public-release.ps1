param([switch]$Execute)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepositoryFiles {
    param([Parameter(Mandatory)][string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.FullName -notmatch '[\\/]external[\\/]' -and
        $_.FullName -notmatch '[\\/]release-artifacts[\\/]'
    })
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$manifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/.codex-plugin/plugin.json') | ConvertFrom-Json
$releaseLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/release.lock.json') | ConvertFrom-Json
$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')

if ($manifest.version -ne $releaseLock.candidateVersion -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Public candidate version drifted.' }
if ($manifest.license -ne 'Apache-2.0') { throw 'Public plugin license drifted.' }
if ($releaseLock.sourceSnapshots -ne 'ephemeral-only' -or $releaseLock.artifactSnapshots -ne 'generated-from-pinned-upstreams') { throw 'Snapshot publication strategy drifted.' }
if ($releaseLock.sourceComposition -ne 'git-head-explicit-file-allowlist' -or
    $releaseLock.artifactInventory -ne 'all-files-force; manifest-self-listed-unhashed') {
    throw 'Release source/inventory safety contract drifted.'
}
if ($releaseLock.publicationStatus -ne 'not-published' -or $releaseLock.tagStatus -ne 'not-created' -or $releaseLock.releaseStatus -ne 'not-created') { throw 'FTK-06 must not publish, tag or release.' }
foreach ($required in @(
    'SECURITY.md','CONTRIBUTING.md','CHANGELOG.md','THIRD_PARTY_NOTICES.md',
    'docs/INSTALLATION.md','docs/UPDATING.md','docs/VERSIONING.md','docs/RELEASE-CHECKLIST.md',
    'scripts/build-release-candidate.ps1'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $required) -PathType Leaf)) { throw "Missing public file: $required" }
}
foreach ($term in @('frontend-orchestrator','Impeccable','img2threejs','Shadcn','21st','API_KEY_21ST','Instalação','Atualização','Apache-2.0')) {
    if ($readme -notmatch [regex]::Escape($term)) { throw "README is missing public topic: $term" }
}

$files = Get-RepositoryFiles -Root $repoRoot
$personalPathPattern = '(?i)' + 'C:' + '[\\/]Users[\\/]' + '|Users[\\/]' + 'Gabri'
$absolutePathHits = @($files | Where-Object { [IO.File]::ReadAllText($_.FullName) -match $personalPathPattern })
if ($absolutePathHits.Count) { throw "Personal absolute path found: $($absolutePathHits.FullName -join ', ')" }
$secretPattern = '(sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._-]{20,}|API_KEY_21ST\s*[=:]\s*["''][^"'']+["''])'
$secretHits = @($files | Where-Object { [IO.File]::ReadAllText($_.FullName) -match $secretPattern })
if ($secretHits.Count) { throw "Potential secret found: $($secretHits.FullName -join ', ')" }

$sourceSkills = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/skills') -Directory | ForEach-Object Name)
if ($sourceSkills.Count -ne 1 -or $sourceSkills[0] -cne 'frontend-orchestrator') { throw 'Generated snapshots must not be persisted in plugin source.' }
& (Join-Path $repoRoot 'tests/test-release-safety.ps1')

if (-not $Execute) {
    Write-Output 'PASS: public docs, SemVer, metadata, privacy, secrets and source-snapshot policy validated.'
    return
}

& (Join-Path $repoRoot 'tests/test-release-safety.ps1') -Execute
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk06-release-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$one = Join-Path $fixture 'one'
$two = Join-Path $fixture 'two'
try {
    & (Join-Path $repoRoot $releaseLock.builder) -Destination $one | Out-Null
    & (Join-Path $repoRoot $releaseLock.builder) -Destination $two | Out-Null
    $manifestOne = Get-Content -Raw -LiteralPath (Join-Path $one 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    $manifestTwo = Get-Content -Raw -LiteralPath (Join-Path $two 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    if ($manifestOne.pluginTreeSha256 -ne $manifestTwo.pluginTreeSha256) { throw 'Independent candidate builds differ.' }
    if ($manifestOne.pluginTreeSha256 -ne $releaseLock.observedPluginTreeSha256) { throw "Release artifact hash drifted: $($manifestOne.pluginTreeSha256)" }
    if (($manifestOne.pluginFiles.path -join "`n") -ne ($manifestTwo.pluginFiles.path -join "`n")) { throw 'Release artifact trees differ.' }
    if ($manifestOne.artifactTreeSha256 -ne $manifestTwo.artifactTreeSha256) { throw 'Independent artifact payloads differ.' }
    if ($manifestOne.artifactTreeSha256 -ne $releaseLock.observedArtifactTreeSha256) { throw "Release payload hash drifted: $($manifestOne.artifactTreeSha256)" }
    if (($manifestOne.artifactFiles | ConvertTo-Json -Depth 5) -cne ($manifestTwo.artifactFiles | ConvertTo-Json -Depth 5)) { throw 'Independent artifact manifests differ.' }
    if ($manifestOne.artifactFileCount -ne @($manifestOne.artifactFiles).Count) { throw 'Artifact file count is inconsistent.' }
    if ($manifestOne.secretsIncluded -ne $false) { throw 'Release manifest did not prove secrets exclusion.' }
    foreach ($path in @($manifestOne.artifactFiles.path)) {
        if (Test-SensitiveArtifactPath -RelativePath $path) { throw "Sensitive path entered release manifest: $path" }
    }
    foreach ($required in @('plugins/frontend-toolkit/SNAPSHOT_PROVENANCE.json','plugins/frontend-toolkit/THIRD_PARTY_NOTICES.md','plugins/frontend-toolkit/LICENSE')) {
        if (-not (Test-Path -LiteralPath (Join-Path $one $required))) { throw "Release candidate missing $required" }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $fixture 'frontend-toolkit-v1.0.0.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($one, $zipPath)
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $zipEntriesByPath = @{}
        foreach ($zipEntry in @($zip.Entries | Where-Object Name)) {
            $zipEntriesByPath[$zipEntry.FullName.Replace('\', '/')] = $zipEntry
        }
        $zipPaths = @($zipEntriesByPath.Keys | Sort-Object)
        $manifestPaths = @($manifestOne.artifactFiles.path | Sort-Object)
        if (($zipPaths -join "`n") -cne ($manifestPaths -join "`n")) { throw 'ZIP contents diverged from RELEASE_MANIFEST.json.' }
        foreach ($path in $zipPaths) {
            if (Test-SensitiveArtifactPath -RelativePath $path) { throw "Sensitive path entered ZIP: $path" }
        }
        foreach ($entry in @($manifestOne.artifactFiles | Where-Object { -not $_.selfManifest })) {
            $zipEntry = $zipEntriesByPath[$entry.path]
            if ($null -eq $zipEntry) { throw "Manifested file is missing from ZIP: $($entry.path)" }
            $stream = $zipEntry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $zipHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
            } finally {
                $sha.Dispose()
                $stream.Dispose()
            }
            if ($zipHash -cne $entry.sha256) { throw "ZIP content hash diverged: $($entry.path)" }
        }
        $zipManifest = $zipEntriesByPath['RELEASE_MANIFEST.json']
        $stream = $zipManifest.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $zipManifestHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
            $stream.Dispose()
        }
        $candidateManifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $one 'RELEASE_MANIFEST.json')).Hash.ToLowerInvariant()
        if ($zipManifestHash -cne $candidateManifestHash) { throw 'ZIP release manifest bytes diverged from the validated candidate.' }
    } finally {
        $zip.Dispose()
    }
    Write-Output "PASS: v$($manifestOne.version) candidate is deterministic at $($manifestOne.pluginTreeSha256)."
    Write-Output "PASS: artifact payload is deterministic at $($manifestOne.artifactTreeSha256) and ZIP matches its complete manifest."
} finally {
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true) }
}
if (Test-Path -LiteralPath $fixture) { throw 'Release candidate fixture teardown failed.' }
Write-Output 'PASS: release candidate fixture teardown completed.'
