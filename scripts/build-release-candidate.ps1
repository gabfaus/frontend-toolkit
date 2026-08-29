param(
    [Parameter(Mandatory)][string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TreeEntries {
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    return @(Get-ChildItem -LiteralPath $rootPath -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        [pscustomobject][ordered]@{
            path = $relative
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        }
    } | Sort-Object path)
}

function Get-EntriesHash {
    param([Parameter(Mandatory)][object[]]$Entries)

    $canonical = @($Entries | ForEach-Object { "$($_.path)|$($_.sha256)" }) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destinationPath = [IO.Path]::GetFullPath($Destination)
$builder = Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1'
$manifestPath = Join-Path $repoRoot 'plugin/frontend-toolkit/.codex-plugin/plugin.json'
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Release candidate requires a strict SemVer plugin version.' }
if (Test-Path -LiteralPath $destinationPath) { throw "Destination already exists: $destinationPath" }
if ($destinationPath.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $repoRoot.StartsWith($destinationPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Destination would replace or contain the repository.'
}

$pluginDestination = Join-Path $destinationPath 'plugins/frontend-toolkit'
$marketplaceDirectory = Join-Path $destinationPath '.agents/plugins'
try {
    New-Item -ItemType Directory -Path $marketplaceDirectory, (Split-Path $pluginDestination) -Force | Out-Null
    & $builder -Destination $pluginDestination | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Plugin snapshot build failed.' }

    $marketplace = [ordered]@{
        name = 'frontend-toolkit-local'
        interface = [ordered]@{ displayName = 'Frontend Toolkit Local' }
        plugins = @([ordered]@{
            name = 'frontend-toolkit'
            source = [ordered]@{ source = 'local'; path = './plugins/frontend-toolkit' }
            policy = [ordered]@{ installation = 'AVAILABLE'; authentication = 'ON_USE' }
            category = 'Developer Tools'
        })
    }
    [IO.File]::WriteAllText(
        (Join-Path $marketplaceDirectory 'marketplace.json'),
        (($marketplace | ConvertTo-Json -Depth 10) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )

    $entries = Get-TreeEntries -Root $pluginDestination
    $treeHash = Get-EntriesHash -Entries $entries
    $releaseManifest = [ordered]@{
        schemaVersion = 1
        version = $manifest.version
        plugin = 'frontend-toolkit'
        marketplace = 'frontend-toolkit-local'
        pluginTreeSha256 = $treeHash
        pluginFileCount = $entries.Count
        pluginFiles = $entries
        provenance = @($externalLock.dependencies | ForEach-Object {
            [ordered]@{ id = $_.id; ref = $_.ref; commitSha = $_.commitSha; license = $_.license }
        })
        secretsIncluded = $false
        snapshots = 'generated-from-pinned-upstreams'
    }
    [IO.File]::WriteAllText(
        (Join-Path $destinationPath 'RELEASE_MANIFEST.json'),
        (($releaseManifest | ConvertTo-Json -Depth 10) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )

    [pscustomobject]@{
        Destination = $destinationPath
        Version = $manifest.version
        PluginTreeSha256 = $treeHash
        PluginFileCount = $entries.Count
    }
} catch {
    if (Test-Path -LiteralPath $destinationPath) {
        [IO.Directory]::Delete('\\?\' + $destinationPath, $true)
    }
    throw
}
