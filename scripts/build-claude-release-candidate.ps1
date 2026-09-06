param(
    [Parameter(Mandatory)][string]$Destination,
    [switch]$DevelopmentWorkingTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-safety.ps1')

function Assert-ClaudeExactPropertySet {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Context
    )

    Assert-ExactStringSet -Name $Context -Actual @($Object.PSObject.Properties.Name) -Expected $Expected
}

function Assert-ClaudeJsonFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Claude source file is missing: $Path" }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Claude source JSON is invalid: $Path" }
}

function Assert-ClaudeMetadata {
    param(
        [Parameter(Mandatory)][object]$Metadata,
        [Parameter(Mandatory)][object]$CodexManifest,
        [Parameter(Mandatory)][object]$ClaudeManifest
    )

    Assert-ClaudeExactPropertySet -Object $Metadata -Expected @('name', 'version', 'displayName', 'description', 'author', 'repository', 'license', 'keywords') -Context 'Common metadata fields'
    Assert-ClaudeExactPropertySet -Object $Metadata.author -Expected @('name') -Context 'Common metadata author fields'
    Assert-ClaudeExactPropertySet -Object $ClaudeManifest -Expected @('name', 'version', 'displayName', 'description', 'author', 'repository', 'license', 'keywords', 'mcpServers', 'defaultEnabled') -Context 'Claude manifest fields'
    Assert-ClaudeExactPropertySet -Object $ClaudeManifest.author -Expected @('name') -Context 'Claude author fields'

    $sharedPairs = @(
        @{ Name = 'name'; Metadata = $Metadata.name; Codex = $CodexManifest.name; Claude = $ClaudeManifest.name }
        @{ Name = 'version'; Metadata = $Metadata.version; Codex = $CodexManifest.version; Claude = $ClaudeManifest.version }
        @{ Name = 'description'; Metadata = $Metadata.description; Codex = $CodexManifest.description; Claude = $ClaudeManifest.description }
        @{ Name = 'license'; Metadata = $Metadata.license; Codex = $CodexManifest.license; Claude = $ClaudeManifest.license }
        @{ Name = 'author.name'; Metadata = $Metadata.author.name; Codex = $CodexManifest.author.name; Claude = $ClaudeManifest.author.name }
        @{ Name = 'displayName'; Metadata = $Metadata.displayName; Codex = $CodexManifest.interface.displayName; Claude = $ClaudeManifest.displayName }
    )
    foreach ($pair in $sharedPairs) {
        if ($pair.Metadata -cne $pair.Codex -or $pair.Metadata -cne $pair.Claude) { throw "Shared metadata drifted: $($pair.Name)" }
    }
    if ((@($Metadata.keywords) -join "`n") -cne (@($CodexManifest.keywords) -join "`n") -or
        (@($Metadata.keywords) -join "`n") -cne (@($ClaudeManifest.keywords) -join "`n")) {
        throw 'Shared metadata drifted: keywords'
    }
    if ($Metadata.repository -cne 'https://github.com/gabfaus/frontend-toolkit' -or
        $ClaudeManifest.repository -cne $Metadata.repository) { throw 'Repository metadata is invalid or drifted.' }
    if ($ClaudeManifest.mcpServers -cne './.mcp.json') { throw 'Claude manifest must reference the local MCP file.' }
    if ($ClaudeManifest.defaultEnabled -ne $false) { throw 'Claude plugin must default to disabled.' }
    if ($Metadata.version -cne '1.1.0' -or $CodexManifest.version -cne '1.1.0' -or $ClaudeManifest.version -cne '1.1.0') { throw 'Claude release version must be 1.1.0 across metadata and host manifests.' }
}

function Assert-ClaudeMcp {
    param([Parameter(Mandatory)][object]$Mcp)

    Assert-ClaudeExactPropertySet -Object $Mcp -Expected @('mcpServers') -Context 'Claude MCP root fields'
    $servers = @($Mcp.mcpServers.PSObject.Properties)
    Assert-ExactStringSet -Name 'Claude MCP server names' -Actual @($servers.Name) -Expected @('shadcn', '21st')
    $shadcn = $Mcp.mcpServers.shadcn
    Assert-ClaudeExactPropertySet -Object $shadcn -Expected @('command', 'args') -Context 'Claude Shadcn MCP fields'
    if ($shadcn.command -cne 'powershell.exe') { throw 'Claude Shadcn MCP command is invalid.' }
    $expectedArgs = @('-NoProfile', '-NonInteractive', '-File', '${CLAUDE_PLUGIN_ROOT}/security/claude/launch-shadcn.ps1')
    if ((@($shadcn.args) -join "`n") -cne ($expectedArgs -join "`n")) { throw 'Claude Shadcn MCP launcher arguments are invalid.' }

    $twentyFirst = $Mcp.mcpServers.'21st'
    Assert-ClaudeExactPropertySet -Object $twentyFirst -Expected @('command', 'args', 'env') -Context 'Claude 21st MCP fields'
    if ($twentyFirst.command -cne 'powershell.exe') { throw 'Claude 21st MCP command is invalid.' }
    $expectedTwentyFirstArgs = @('-NoProfile', '-NonInteractive', '-File', '${CLAUDE_PLUGIN_ROOT}/security/claude/launch-21st-facade.ps1')
    if ((@($twentyFirst.args) -join "`n") -cne ($expectedTwentyFirstArgs -join "`n")) { throw 'Claude 21st MCP launcher arguments are invalid.' }
    Assert-ClaudeExactPropertySet -Object $twentyFirst.env -Expected @('API_KEY_21ST') -Context 'Claude 21st MCP environment fields'
    if ($twentyFirst.env.API_KEY_21ST -cne '${API_KEY_21ST}') { throw 'Claude 21st MCP must receive API_KEY_21ST through external environment interpolation.' }
}

function Assert-ClaudeSourceFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Claude source file is missing: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Claude source file is a reparse point: $Path" }
}

function Get-ClaudeRuntimeLockPackage {
    param(
        [Parameter(Mandatory)][object]$Lock,
        [Parameter(Mandatory)][string]$Name
    )

    $key = 'node_modules/' + $Name
    if (-not $Lock['packages'].ContainsKey($key)) { throw "Claude runtime lock entry is missing: $Name" }
    return $Lock['packages'][$key]
}

function Get-ClaudeRuntimeTreeHash {
    param([Parameter(Mandatory)][string]$NodeModulesRoot)

    if (-not (Test-Path -LiteralPath $NodeModulesRoot -PathType Container)) {
        throw 'Claude runtime node_modules directory is missing.'
    }
    $rootPath = (Resolve-Path -LiteralPath $NodeModulesRoot).Path
    $lines = @(
        Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force | ForEach-Object {
            if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Claude runtime contains a reparse point: $($_.FullName)" }
            $relative = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            $relative + [char]9 + $hash
        }
    )
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join [char]10) + [char]10)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-ClaudeRuntimeJsonFile {
    param([Parameter(Mandatory)][string]$Path)

    try {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        return $serializer.DeserializeObject((Get-Content -Raw -LiteralPath $Path))
    } catch {
        throw "Claude runtime JSON is invalid: $Path"
    }
}

function Assert-ClaudeRuntimeMetadata {
    param([Parameter(Mandatory)][string]$RuntimeRoot)

    $package = Read-ClaudeRuntimeJsonFile -Path (Join-Path $RuntimeRoot 'package.json')
    $lock = Read-ClaudeRuntimeJsonFile -Path (Join-Path $RuntimeRoot 'package-lock.json')
    $provenance = Read-ClaudeRuntimeJsonFile -Path (Join-Path $RuntimeRoot 'dependency-provenance.json')
    Assert-ExactStringSet -Name 'Claude runtime package fields' -Actual @($package.Keys) -Expected @('name', 'version', 'private', 'type', 'engines', 'dependencies')
    Assert-ExactStringSet -Name 'Claude runtime lock fields' -Actual @($lock.Keys) -Expected @('name', 'version', 'lockfileVersion', 'requires', 'packages')
    Assert-ExactStringSet -Name 'Claude runtime provenance fields' -Actual @($provenance.Keys) -Expected @('schemaVersion', 'generatedAt', 'purpose', 'registry', 'resolution', 'nodeModulesTreeSha256', 'packages')
    if ($package['name'] -cne 'frontend-toolkit-claude-mcp-runtime' -or $package['version'] -cne '1.1.0' -or
        $package['private'] -ne $true -or $package['type'] -cne 'module' -or $package['engines']['node'] -cne '>=20') {
        throw 'Claude runtime package identity or engine is invalid.'
    }
    Assert-ExactStringSet -Name 'Claude direct dependency fields' -Actual @($package['dependencies'].Keys) -Expected @('@modelcontextprotocol/client', '@modelcontextprotocol/server')
    if ($package['dependencies']['@modelcontextprotocol/client'] -cne '2.0.0' -or
        $package['dependencies']['@modelcontextprotocol/server'] -cne '2.0.0') {
        throw 'Claude direct MCP SDK dependencies must be pinned to 2.0.0.'
    }
    $lockRoot = $lock['packages']['']
    if ($lock['version'] -cne '1.1.0' -or $lockRoot['version'] -cne '1.1.0' -or $lock['lockfileVersion'] -ne 3 -or $lock['requires'] -ne $true -or
        $lockRoot['dependencies']['@modelcontextprotocol/client'] -cne '2.0.0' -or
        $lockRoot['dependencies']['@modelcontextprotocol/server'] -cne '2.0.0') {
        throw 'Claude runtime lock root is invalid.'
    }
    if ($provenance['schemaVersion'] -ne 1 -or $provenance['registry'] -cne 'https://registry.npmjs.org/' -or
        $provenance['resolution']['scriptsDisabled'] -ne $true -or @($provenance['resolution']['lifecycleScriptsExecuted']).Count -ne 0) {
        throw 'Claude runtime provenance policy is invalid.'
    }

    $expectedNames = @(
        '@modelcontextprotocol/client'
        '@modelcontextprotocol/core'
        '@modelcontextprotocol/server'
        'cross-spawn'
        'eventsource'
        'eventsource-parser'
        'isexe'
        'jose'
        'path-key'
        'pkce-challenge'
        'shebang-command'
        'shebang-regex'
        'which'
        'zod'
    )
    $lockNames = @($lock['packages'].Keys | Where-Object { $_ -ne '' } | ForEach-Object { $_.Substring(13) })
    Assert-ExactStringSet -Name 'Claude runtime lock package inventory' -Actual $lockNames -Expected $expectedNames
    $provenanceNames = @($provenance['packages'] | ForEach-Object { [string]$_['name'] })
    Assert-ExactStringSet -Name 'Claude runtime provenance package inventory' -Actual $provenanceNames -Expected $expectedNames

    foreach ($record in @($provenance['packages'])) {
        $lockPackage = Get-ClaudeRuntimeLockPackage -Lock $lock -Name ([string]$record['name'])
        if ($record['version'] -cne $lockPackage['version'] -or $record['integrity'] -cne $lockPackage['integrity'] -or
            $record['license'] -cne $lockPackage['license'] -or $record['tarballSha512Hex'] -notmatch '^[0-9a-f]{128}$') {
            throw "Claude runtime provenance does not match the lock: $($record['name'])"
        }
        if ($lockPackage['resolved'] -notmatch '^https://registry\.npmjs\.org/[^/].+$' -or
            $lockPackage['integrity'] -notmatch '^sha512-[A-Za-z0-9+/]+=*$' -or
            $lockPackage['version'] -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' -or
            $record['license'] -notin @('MIT', 'ISC')) {
            throw "Claude runtime package provenance is incomplete: $($record['name'])"
        }
    }
    return [pscustomobject][ordered]@{
        Package = $package
        Lock = $lock
        Provenance = $provenance
    }
}

function ConvertTo-ClaudeBuildNativeArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    if ($Value -match '[\x00\r\n]') { throw 'Builder argv values may not contain NUL or line breaks.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes) { [void]$builder.Append(('\' * $backslashes)); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Assert-ClaudeRuntimeMaterialized {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][object]$Metadata
    )

    $nodeModulesRoot = Join-Path $RuntimeRoot 'node_modules'
    $actualPackagePaths = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $nodeModulesRoot -Directory -Force)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Claude runtime contains a reparse point: $($entry.FullName)" }
        if ($entry.Name -ceq '.bin') { continue }
        if ($entry.Name.StartsWith('@', [StringComparison]::Ordinal)) {
            foreach ($scopedEntry in @(Get-ChildItem -LiteralPath $entry.FullName -Directory -Force)) {
                if ($scopedEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Claude runtime contains a reparse point: $($scopedEntry.FullName)" }
                $actualPackagePaths += $entry.Name + '/' + $scopedEntry.Name
            }
        } else {
            $actualPackagePaths += $entry.Name
        }
    }
    $expectedPackagePaths = @($Metadata.Lock['packages'].Keys | Where-Object { $_ -ne '' } | ForEach-Object { $_.Substring(13) })
    Assert-ExactStringSet -Name 'Claude materialized package inventory' -Actual $actualPackagePaths -Expected $expectedPackagePaths
    foreach ($record in @($Metadata.Provenance['packages'])) {
        $packageJson = Join-Path (Join-Path $nodeModulesRoot ([string]$record['name'])) 'package.json'
        $installed = Assert-ClaudeJsonFile -Path $packageJson
        if ($installed.version -cne $record['version']) { throw "Claude materialized package version drifted: $($record['name'])" }
    }
    $treeHash = Get-ClaudeRuntimeTreeHash -NodeModulesRoot $nodeModulesRoot
    $provenancePath = Join-Path $RuntimeRoot 'dependency-provenance.json'
    $provenance = Assert-ClaudeJsonFile -Path $provenancePath
    if ($provenance.nodeModulesTreeSha256 -cne $treeHash -or $treeHash -notmatch '^[0-9a-f]{64}$') {
        throw 'Claude materialized runtime tree hash is invalid.'
    }
    return $treeHash
}

function Invoke-ClaudeRuntimeInstall {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$StageRoot
    )

    $metadata = Assert-ClaudeRuntimeMetadata -RuntimeRoot $RuntimeRoot
    $toolchain = & (Join-Path $PSScriptRoot 'resolve-toolchain.ps1')
    $npmCli = Join-Path $toolchain.NodeDirectory 'node_modules/npm/bin/npm-cli.js'
    if (-not (Test-Path -LiteralPath $npmCli -PathType Leaf)) { throw 'Pinned npm CLI is missing.' }

    $npmCache = Join-Path $StageRoot 'npm-cache'
    $npmConfig = Join-Path $StageRoot 'npmrc'
    New-Item -ItemType Directory -Path $npmCache -Force | Out-Null
    [IO.File]::WriteAllText($npmConfig, (@('ignore-scripts=true', 'audit=false', 'fund=false', 'update-notifier=false') -join [Environment]::NewLine) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $toolchain.NodePath
    $startInfo.WorkingDirectory = (Resolve-Path -LiteralPath $RuntimeRoot).Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.Arguments = (@($npmCli, 'ci', '--ignore-scripts', '--no-audit', '--no-fund', '--loglevel', 'error') | ForEach-Object {
        ConvertTo-ClaudeBuildNativeArgument -Value ([string]$_)
    }) -join ' '
    $startInfo.EnvironmentVariables.Clear()
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot', 'Process')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
    $temp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    $tmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or [string]::IsNullOrWhiteSpace($localAppData) -or
        [string]::IsNullOrWhiteSpace($temp) -or [string]::IsNullOrWhiteSpace($tmp)) {
        throw 'The minimum Windows builder environment is unavailable.'
    }
    $system32 = Join-Path $systemRoot 'System32'
    $environment = [ordered]@{
        SystemRoot = $systemRoot
        LOCALAPPDATA = $localAppData
        TEMP = $temp
        TMP = $tmp
        PATH = (Split-Path -Parent $toolchain.NodePath) + ';' + $system32
        ComSpec = Join-Path $system32 'cmd.exe'
        PATHEXT = '.COM;.EXE;.BAT;.CMD'
        NODE_OPTIONS = '--use-system-ca'
        NPM_CONFIG_CACHE = $npmCache
        NPM_CONFIG_USERCONFIG = $npmConfig
        NPM_CONFIG_REGISTRY = 'https://registry.npmjs.org/'
        NPM_CONFIG_UPDATE_NOTIFIER = 'false'
    }
    foreach ($name in $environment.Keys) { $startInfo.EnvironmentVariables.Add([string]$name, [string]$environment[$name]) }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Claude runtime npm process did not start.' }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Claude runtime npm ci failed.' }
        $treeHash = Get-ClaudeRuntimeTreeHash -NodeModulesRoot (Join-Path $RuntimeRoot 'node_modules')
        $provenancePath = Join-Path $RuntimeRoot 'dependency-provenance.json'
        $provenance = Assert-ClaudeJsonFile -Path $provenancePath
        $provenance.nodeModulesTreeSha256 = $treeHash
        [IO.File]::WriteAllText($provenancePath, ($provenance | ConvertTo-Json -Depth 10) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        return Assert-ClaudeRuntimeMaterialized -RuntimeRoot $RuntimeRoot -Metadata $metadata
    } finally {
        $process.Dispose()
        if (Test-Path -LiteralPath $npmConfig) { Remove-Item -LiteralPath $npmConfig -Force }
    }
}

function Copy-ClaudeSources {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [switch]$AllowWorkingTree
    )

    $paths = @(
        'integrations/plugin-metadata.json'
        'claude/plugin.json'
        'claude/mcp.json'
        'claude/facade/launch-shadcn.ps1'
        'claude/facade/21st-facade.mjs'
        'claude/facade/launch-21st-facade.ps1'
        'claude/facade/runtime/package.json'
        'claude/facade/runtime/package-lock.json'
        'claude/facade/runtime/dependency-provenance.json'
        'claude/facade/runtime/THIRD_PARTY_NOTICES.md'
    )
    $sourceRoot = Join-Path $StageRoot 'claude-source'
    New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
    if ($AllowWorkingTree) {
        foreach ($relativePath in $paths) {
            $sourcePath = Join-Path $RepositoryRoot $relativePath
            Assert-ClaudeSourceFile -Path $sourcePath
            $targetPath = Join-Path $sourceRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path $targetPath) -Force | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath
        }
        return $sourceRoot
    }

    $archivePath = Join-Path $StageRoot 'claude-source.tar'
    Assert-SafeGitArchiveTree -Repository $RepositoryRoot -Commit 'HEAD' -Context 'Claude source' -Paths $paths
    Export-CanonicalGitFiles -Repository $RepositoryRoot -Commit 'HEAD' -DestinationArchive $archivePath -Paths $paths
    & tar -xf $archivePath -C $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw 'Claude source extraction failed.' }
    return $sourceRoot
}

function Copy-CompleteDirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $entry.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-PathHash {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $path = Join-Path $Root ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Artifact file is missing: $RelativePath" }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

function Assert-ClaudeCommonDifferential {
    param(
        [Parameter(Mandatory)][string]$CommonRoot,
        [Parameter(Mandatory)][string]$ClaudeRoot,
        [Parameter(Mandatory)][string[]]$ClaudeOnlyPaths
    )

    $removed = @('.codex-plugin/plugin.json', '.mcp.json')
    $commonEntries = @(Get-ArtifactFileEntries -Root $CommonRoot)
    $claudeEntries = @(Get-ArtifactFileEntries -Root $ClaudeRoot)
    $expected = @($commonEntries.path | Where-Object { $_ -cnotin $removed }) + @(
        '.claude-plugin/plugin.json'
        '.mcp.json'
        'security/claude/launch-shadcn.ps1'
    ) + @($ClaudeOnlyPaths)
    Assert-ExactStringSet -Name 'Claude artifact allowlisted file set' -Actual @($claudeEntries.path) -Expected $expected
    foreach ($entry in @($commonEntries | Where-Object { $_.path -cnotin $removed })) {
        if ((Get-PathHash -Root $CommonRoot -RelativePath $entry.path) -cne (Get-PathHash -Root $ClaudeRoot -RelativePath $entry.path)) {
            throw "Common payload changed in Claude artifact: $($entry.path)"
        }
    }
}

function Assert-ClaudeArtifactNoSensitivePaths {
    param([Parameter(Mandatory)][string]$Root)

    $entries = @(Get-CompleteArtifactEntries -Root $Root)
    $reparsePoints = @($entries | Where-Object IsReparsePoint)
    if ($reparsePoints.Count) { throw "Claude candidate contains reparse points: $($reparsePoints.Path -join ', ')" }
    $runtimePrefix = 'security/claude/runtime'
    $sensitive = @($entries | Where-Object {
        $path = [string]$_.Path
        $isAllowedRuntime = $path -eq $runtimePrefix -or $path.StartsWith($runtimePrefix + '/', [StringComparison]::Ordinal)
        (Test-SensitiveArtifactPath -RelativePath $path) -and -not $isAllowedRuntime
    })
    if ($sensitive.Count) { throw "Claude candidate contains sensitive paths: $($sensitive.Path -join ', ')" }
}

function Assert-ClaudeArtifactSecurity {
    param([Parameter(Mandatory)][string]$Root)

    Assert-ClaudeArtifactNoSensitivePaths -Root $Root
    if (Test-Path -LiteralPath (Join-Path $Root '.codex-plugin')) { throw 'Claude candidate contains the Codex plugin directory.' }
    $artifactEntries = @(Get-ArtifactFileEntries -Root $Root)
    if (@($artifactEntries | Where-Object { $_.path -match '(?i)(\.zip|\.bundle|\.bak|\.backup|~)$' }).Count) {
        throw 'Claude candidate contains a backup or bundle artifact.'
    }

    $hostPaths = @('.claude-plugin/plugin.json', '.mcp.json', 'security/claude/launch-shadcn.ps1', 'security/claude/launch-21st-facade.ps1')
    $hostText = @($hostPaths | ForEach-Object { Get-Content -Raw -LiteralPath (Join-Path $Root $_) }) -join "`n"
    foreach ($forbidden in @('OPENAI_API_KEY', 'bearer_token_env_var', 'C:\Users\', '/Users/')) {
        if ($hostText.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Claude host payload contains forbidden material: $forbidden" }
    }
    $launcher = Get-Content -Raw -LiteralPath (Join-Path $Root 'security/claude/launch-shadcn.ps1')
    foreach ($required in @('ProcessStartInfo', 'EnvironmentVariables.Clear()', 'NODE_OPTIONS', 'shadcn@4.19.0', 'npx-cli.js', 'RedirectStandardOutput = $false', 'RedirectStandardError = $false')) {
        if ($launcher.IndexOf($required, [StringComparison]::Ordinal) -lt 0) { throw "Claude launcher contract is incomplete: $required" }
    }
    foreach ($forbiddenCode in @('Invoke-Expression', 'Start-Process', 'cmd.exe /c', 'API_KEY_21ST', 'OPENAI_API_KEY')) {
        if ($launcher.IndexOf($forbiddenCode, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Claude launcher contains forbidden execution or secret behavior: $forbiddenCode" }
    }

    $mcpText = Get-Content -Raw -LiteralPath (Join-Path $Root '.mcp.json')
    foreach ($forbiddenMcp in @('https://21st.dev/api/mcp', 'bearer_token_env_var')) {
        if ($mcpText.IndexOf($forbiddenMcp, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Claude MCP config contains forbidden direct remote material: $forbiddenMcp" }
    }
    $facade = Get-Content -Raw -LiteralPath (Join-Path $Root 'security/claude/21st-facade.mjs')
    foreach ($requiredFacade in @('StreamableHTTPClientTransport', 'https://21st.dev/api/mcp', 'x-api-key', 'maxRetries: 0', "registerTool('search',")) {
        if ($facade.IndexOf($requiredFacade, [StringComparison]::Ordinal) -lt 0) { throw "Claude 21st facade contract is incomplete: $requiredFacade" }
    }
    foreach ($forbiddenFacade in @('Bearer ', 'process.env.HTTP_PROXY', 'process.env.HTTPS_PROXY', 'tools/list remote forwarding')) {
        if ($facade.IndexOf($forbiddenFacade, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Claude 21st facade contains forbidden behavior: $forbiddenFacade" }
    }
    $twentyFirstLauncher = Get-Content -Raw -LiteralPath (Join-Path $Root 'security/claude/launch-21st-facade.ps1')
    foreach ($requiredTwentyFirstLauncher in @('ProcessStartInfo', 'EnvironmentVariables.Clear()', 'API_KEY_21ST', 'security/claude/21st-facade.mjs', 'security/claude/runtime', 'RedirectStandardOutput = $false', 'RedirectStandardError = $false')) {
        if ($twentyFirstLauncher.IndexOf($requiredTwentyFirstLauncher, [StringComparison]::Ordinal) -lt 0) { throw "Claude 21st launcher contract is incomplete: $requiredTwentyFirstLauncher" }
    }
    foreach ($forbiddenTwentyFirstLauncher in @('Invoke-Expression', 'Start-Process', 'cmd.exe /c', 'OPENAI_API_KEY', 'https://')) {
        if ($twentyFirstLauncher.IndexOf($forbiddenTwentyFirstLauncher, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Claude 21st launcher contains forbidden behavior: $forbiddenTwentyFirstLauncher" }
    }
    [void](Assert-ClaudeRuntimeMetadata -RuntimeRoot (Join-Path $Root 'security/claude/runtime'))
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destinationPath = [IO.Path]::GetFullPath($Destination)
$commonBuilder = Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1'
$sourcePaths = @(
    'integrations/plugin-metadata.json'
    'claude/plugin.json'
    'claude/mcp.json'
    'claude/facade/launch-shadcn.ps1'
    'claude/facade/21st-facade.mjs'
    'claude/facade/launch-21st-facade.ps1'
    'claude/facade/runtime/package.json'
    'claude/facade/runtime/package-lock.json'
    'claude/facade/runtime/dependency-provenance.json'
    'claude/facade/runtime/THIRD_PARTY_NOTICES.md'
)
if (Test-Path -LiteralPath $destinationPath) { throw "Destination already exists: $destinationPath" }
if ($destinationPath.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $repoRoot.StartsWith($destinationPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Destination would replace or contain the repository.'
}
if (-not (Test-Path -LiteralPath $commonBuilder -PathType Leaf)) { throw 'Governed common builder is missing.' }

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('ftk03a-stage-' + [guid]::NewGuid().ToString('N'))
$destinationOwned = $false
try {
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $commonStage = Join-Path $stageRoot 'common'
    $claudeStage = Join-Path $stageRoot 'claude'
    $sourceRoot = Copy-ClaudeSources -RepositoryRoot $repoRoot -StageRoot $stageRoot -AllowWorkingTree:$DevelopmentWorkingTree

    $commonArguments = @{ Destination = $commonStage }
    if ($DevelopmentWorkingTree) { $commonArguments.DevelopmentWorkingTree = $true }
    & $commonBuilder @commonArguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Governed common payload build failed.' }
    Copy-CompleteDirectoryContents -Source $commonStage -Destination $claudeStage

    Remove-Item -LiteralPath (Join-Path $claudeStage '.codex-plugin') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $claudeStage '.mcp.json') -Force

    $claudeManifestDestination = Join-Path $claudeStage '.claude-plugin/plugin.json'
    $claudeMcpDestination = Join-Path $claudeStage '.mcp.json'
    $claudeLauncherDestination = Join-Path $claudeStage 'security/claude/launch-shadcn.ps1'
    $claudeFacadeDestination = Join-Path $claudeStage 'security/claude/21st-facade.mjs'
    $claudeTwentyFirstLauncherDestination = Join-Path $claudeStage 'security/claude/launch-21st-facade.ps1'
    $claudeRuntimeDestination = Join-Path $claudeStage 'security/claude/runtime'
    New-Item -ItemType Directory -Path (Split-Path $claudeManifestDestination), (Split-Path $claudeLauncherDestination), (Split-Path $claudeFacadeDestination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'claude/plugin.json') -Destination $claudeManifestDestination
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'claude/mcp.json') -Destination $claudeMcpDestination
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'claude/facade/launch-shadcn.ps1') -Destination $claudeLauncherDestination
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'claude/facade/21st-facade.mjs') -Destination $claudeFacadeDestination
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'claude/facade/launch-21st-facade.ps1') -Destination $claudeTwentyFirstLauncherDestination
    $runtimeSource = Join-Path $sourceRoot 'claude/facade/runtime'
    New-Item -ItemType Directory -Path $claudeRuntimeDestination -Force | Out-Null
    foreach ($runtimeFile in @('package.json', 'package-lock.json', 'dependency-provenance.json', 'THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $runtimeSource $runtimeFile) -Destination (Join-Path $claudeRuntimeDestination $runtimeFile)
    }
    $runtimeMetadata = Assert-ClaudeRuntimeMetadata -RuntimeRoot $runtimeSource
    $runtimeTreeHash = Invoke-ClaudeRuntimeInstall -RuntimeRoot $claudeRuntimeDestination -StageRoot $stageRoot
    $claudeOnlyPaths = @(
        'security/claude/21st-facade.mjs'
        'security/claude/launch-21st-facade.ps1'
        'security/claude/runtime/package.json'
        'security/claude/runtime/package-lock.json'
        'security/claude/runtime/dependency-provenance.json'
        'security/claude/runtime/THIRD_PARTY_NOTICES.md'
    ) + @(
        Get-ChildItem -LiteralPath (Join-Path $claudeRuntimeDestination 'node_modules') -Recurse -File -Force | ForEach-Object {
            $_.FullName.Substring($claudeStage.Length + 1).Replace('\', '/')
        }
    )
    Assert-ClaudeRuntimeMaterialized -RuntimeRoot $claudeRuntimeDestination -Metadata $runtimeMetadata | Out-Null

    $metadata = Assert-ClaudeJsonFile -Path (Join-Path $sourceRoot 'integrations/plugin-metadata.json')
    $codexManifest = Assert-ClaudeJsonFile -Path (Join-Path $commonStage '.codex-plugin/plugin.json')
    $claudeManifest = Assert-ClaudeJsonFile -Path $claudeManifestDestination
    $claudeMcp = Assert-ClaudeJsonFile -Path $claudeMcpDestination
    Assert-ClaudeMetadata -Metadata $metadata -CodexManifest $codexManifest -ClaudeManifest $claudeManifest
    Assert-ClaudeMcp -Mcp $claudeMcp
    Assert-ClaudeCommonDifferential -CommonRoot $commonStage -ClaudeRoot $claudeStage -ClaudeOnlyPaths $claudeOnlyPaths
    Assert-ClaudeArtifactSecurity -Root $claudeStage
    foreach ($requiredSkill in @('skills/frontend-orchestrator/SKILL.md', 'skills/impeccable/SKILL.md', 'skills/img2threejs/SKILL.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $claudeStage $requiredSkill) -PathType Leaf)) { throw "Claude candidate skill is missing: $requiredSkill" }
    }

    New-Item -ItemType Directory -Path (Split-Path $destinationPath) -Force | Out-Null
    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    $destinationOwned = $true
    Copy-CompleteDirectoryContents -Source $claudeStage -Destination $destinationPath
    Assert-ClaudeCommonDifferential -CommonRoot $commonStage -ClaudeRoot $destinationPath -ClaudeOnlyPaths $claudeOnlyPaths
    Assert-ClaudeArtifactSecurity -Root $destinationPath
    Assert-ClaudeRuntimeMaterialized -RuntimeRoot (Join-Path $destinationPath 'security/claude/runtime') -Metadata $runtimeMetadata | Out-Null

    Write-Output ([pscustomobject][ordered]@{
        Destination = $destinationPath
        Host = 'claude'
        SourceMode = if ($DevelopmentWorkingTree) { 'DevelopmentWorkingTree' } else { 'CommittedHead' }
        CommonFilesPreserved = (@(Get-ArtifactFileEntries -Root $commonStage).Count - 2)
        ClaudeFileCount = @(Get-ArtifactFileEntries -Root $destinationPath).Count
        RuntimeTreeSha256 = $runtimeTreeHash
        DependencyResolutionNetwork = 'registry.npmjs.org only; npm ci --ignore-scripts'
        McpRuntimeNetworkCalls = 0
    })
} catch {
    if ($destinationOwned -and (Test-Path -LiteralPath $destinationPath)) {
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($destinationPath), $true)
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stageRoot) {
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($stageRoot), $true)
    }
}
