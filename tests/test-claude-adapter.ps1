Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)

    if ($Actual -cne $Expected) { throw ($Label + ' mismatch.') }
}

function Assert-SetEqual {
    param(
        [Parameter(Mandatory)][string[]]$Actual,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    $actualSorted = @($Actual)
    $expectedSorted = @($Expected)
    [Array]::Sort($actualSorted, [StringComparer]::Ordinal)
    [Array]::Sort($expectedSorted, [StringComparer]::Ordinal)
    if (($actualSorted -join "`n") -cne ($expectedSorted -join "`n")) { throw ($Label + ' diverged.') }
}

function Get-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing JSON fixture: $Path" }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid JSON fixture: $Path" }
}

function Get-ArtifactPaths {
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $paths = @(
        Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force | ForEach-Object {
            $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        }
    )
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    return $paths
}

function Get-RelativeFileHash {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $path = Join-Path $Root ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing artifact file: $RelativePath" }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

function ConvertTo-TestWindowsNativeArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    if ($Value -match '[\x00\r\n]') { throw 'Test argv values may not contain NUL or line breaks.' }
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

function Assert-PropertySet {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    Assert-SetEqual -Actual @($Object.PSObject.Properties.Name) -Expected $Expected -Label $Label
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$codexManifestPath = Join-Path $repoRoot 'plugin/frontend-toolkit/.codex-plugin/plugin.json'
$codexMcpPath = Join-Path $repoRoot 'plugin/frontend-toolkit/.mcp.json'
$metadataPath = Join-Path $repoRoot 'integrations/plugin-metadata.json'
$claudeManifestPath = Join-Path $repoRoot 'claude/plugin.json'
$claudeMcpPath = Join-Path $repoRoot 'claude/mcp.json'
$launcherSourcePath = Join-Path $repoRoot 'claude/facade/launch-shadcn.ps1'
$facadeSourcePath = Join-Path $repoRoot 'claude/facade/21st-facade.mjs'
$facadeLauncherSourcePath = Join-Path $repoRoot 'claude/facade/launch-21st-facade.ps1'
$runtimeSourcePath = Join-Path $repoRoot 'claude/facade/runtime'
$claudeBuilderPath = Join-Path $repoRoot 'scripts/build-claude-release-candidate.ps1'

$codexManifest = Get-JsonFile -Path $codexManifestPath
$codexMcp = Get-JsonFile -Path $codexMcpPath
$metadata = Get-JsonFile -Path $metadataPath
$claudeManifest = Get-JsonFile -Path $claudeManifestPath
$claudeMcp = Get-JsonFile -Path $claudeMcpPath
$launcherSource = Get-Content -Raw -LiteralPath $launcherSourcePath
$facadeSource = Get-Content -Raw -LiteralPath $facadeSourcePath
$facadeLauncherSource = Get-Content -Raw -LiteralPath $facadeLauncherSourcePath

Assert-Equal $codexManifest.version '1.1.0' 'Codex public version'
Assert-Equal $metadata.version '1.1.0' 'Common public version'
Assert-Equal $claudeManifest.version '1.1.0' 'Claude public version'
Assert-PropertySet -Object $metadata -Expected @('name', 'version', 'displayName', 'description', 'author', 'repository', 'license', 'keywords') -Label 'Common metadata fields'
Assert-PropertySet -Object $claudeManifest -Expected @('name', 'version', 'displayName', 'description', 'author', 'repository', 'license', 'keywords', 'mcpServers', 'defaultEnabled') -Label 'Claude manifest fields'
if ($claudeManifest.PSObject.Properties.Name -contains 'skills') { throw 'Claude manifest contains a forbidden optional field.' }
Assert-Equal $metadata.name $codexManifest.name 'Shared name'
Assert-Equal $metadata.version $codexManifest.version 'Shared version against Codex'
Assert-Equal $metadata.version $claudeManifest.version 'Shared version against Claude'
Assert-Equal $metadata.displayName $codexManifest.interface.displayName 'Shared displayName'
Assert-Equal $metadata.description $codexManifest.description 'Shared description'
Assert-Equal $metadata.author.name $codexManifest.author.name 'Shared author'
Assert-Equal $metadata.license $codexManifest.license 'Shared license'
Assert-Equal $metadata.repository 'https://github.com/gabfaus/frontend-toolkit' 'Shared repository'
Assert-Equal $claudeManifest.mcpServers './.mcp.json' 'Claude MCP reference'
if ($claudeManifest.defaultEnabled -ne $false) { throw 'Claude defaultEnabled must be false.' }
Assert-SetEqual -Actual @($metadata.keywords) -Expected @($codexManifest.keywords) -Label 'Shared keywords against Codex'
Assert-SetEqual -Actual @($metadata.keywords) -Expected @($claudeManifest.keywords) -Label 'Shared keywords against Claude'

Assert-PropertySet -Object $claudeMcp -Expected @('mcpServers') -Label 'Claude MCP root'
$claudeServers = @($claudeMcp.mcpServers.PSObject.Properties)
Assert-Equal $claudeServers.Count 2 'Claude MCP server count'
Assert-SetEqual -Actual @($claudeServers.Name) -Expected @('shadcn', '21st') -Label 'Claude MCP server names'
Assert-PropertySet -Object $claudeMcp.mcpServers.shadcn -Expected @('command', 'args') -Label 'Claude Shadcn server'
Assert-Equal $claudeMcp.mcpServers.shadcn.command 'powershell.exe' 'Claude Shadcn command'
$expectedMcpArgs = @('-NoProfile', '-NonInteractive', '-File', '${CLAUDE_PLUGIN_ROOT}/security/claude/launch-shadcn.ps1')
Assert-Equal (@($claudeMcp.mcpServers.shadcn.args) -join "`n") ($expectedMcpArgs -join "`n") 'Claude Shadcn arguments'
$claudeMcpText = Get-Content -Raw -LiteralPath $claudeMcpPath
$twentyFirst = $claudeMcp.mcpServers.'21st'
Assert-PropertySet -Object $twentyFirst -Expected @('command', 'args', 'env') -Label 'Claude 21st server'
Assert-Equal $twentyFirst.command 'powershell.exe' 'Claude 21st command'
$expectedTwentyFirstArgs = @('-NoProfile', '-NonInteractive', '-File', '${CLAUDE_PLUGIN_ROOT}/security/claude/launch-21st-facade.ps1')
Assert-Equal (@($twentyFirst.args) -join ([Environment]::NewLine)) ($expectedTwentyFirstArgs -join ([Environment]::NewLine)) 'Claude 21st arguments'
Assert-PropertySet -Object $twentyFirst.env -Expected @('API_KEY_21ST') -Label 'Claude 21st environment'
Assert-Equal $twentyFirst.env.API_KEY_21ST '${API_KEY_21ST}' 'Claude 21st environment interpolation'
foreach ($forbidden in @('21st.dev', 'bearer_token_env_var', 'OPENAI_API_KEY')) {
    if ($claudeMcpText.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Claude MCP contains forbidden material: $forbidden" }
}

foreach ($required in @('ProcessStartInfo', 'EnvironmentVariables.Clear()', 'NODE_OPTIONS', 'shadcn@4.19.0', 'npx-cli.js', 'RedirectStandardOutput = $false', 'RedirectStandardError = $false')) {
    if ($launcherSource.IndexOf($required, [StringComparison]::Ordinal) -lt 0) { throw "Launcher contract missing: $required" }
}
foreach ($forbidden in @('C:\Users\', '/Users/', 'Invoke-Expression', 'Start-Process', 'cmd.exe /c', 'API_KEY_21ST', 'OPENAI_API_KEY')) {
    if ($launcherSource.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Launcher contains forbidden material: $forbidden" }
}
if ($launcherSource -match '(?i)https?://') { throw 'Launcher contains an arbitrary URL.' }
foreach ($required in @('Client', 'StreamableHTTPClientTransport', 'McpServer', 'StdioServerTransport', 'https://21st.dev/api/mcp', 'x-api-key', 'maxRetries: 0', "server.registerTool('search',")) {
    if ($facadeSource.IndexOf($required, [StringComparison]::Ordinal) -lt 0) { throw "21st facade contract missing: $required" }
}
foreach ($forbidden in @('Bearer ', 'Authorization:', 'tools/list remote forwarding')) {
    if ($facadeSource.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "21st facade contains forbidden material: $forbidden" }
}
foreach ($required in @('ProcessStartInfo', 'EnvironmentVariables.Clear()', 'API_KEY_21ST', 'security/claude/21st-facade.mjs', 'security/claude/runtime', 'RedirectStandardOutput = $false', 'RedirectStandardError = $false')) {
    if ($facadeLauncherSource.IndexOf($required, [StringComparison]::Ordinal) -lt 0) { throw "21st launcher contract missing: $required" }
}
foreach ($forbidden in @('C:\Users\', '/Users/', 'Start-Process', 'Invoke-Expression', 'cmd.exe /c')) {
    if ($facadeLauncherSource.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "21st launcher contains forbidden material: $forbidden" }
}
if ($facadeLauncherSource -match '(?i)https?://') { throw '21st launcher contains an arbitrary URL.' }
if (-not (Test-Path -LiteralPath (Join-Path $runtimeSourcePath 'package-lock.json') -PathType Leaf)) { throw 'Claude-only runtime lock is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $runtimeSourcePath 'dependency-provenance.json') -PathType Leaf)) { throw 'Claude-only dependency provenance is missing.' }

# Codex-only source is a protected baseline for this gate, except the public version bump.
$headCodexManifest = ((& git -C $repoRoot show 'HEAD:plugin/frontend-toolkit/.codex-plugin/plugin.json') -join [Environment]::NewLine) | ConvertFrom-Json
$workingCodexManifest = Get-JsonFile -Path $codexManifestPath
$headCodexManifest.PSObject.Properties.Remove('version')
$workingCodexManifest.PSObject.Properties.Remove('version')
if (($headCodexManifest | ConvertTo-Json -Depth 20 -Compress) -cne ($workingCodexManifest | ConvertTo-Json -Depth 20 -Compress)) { throw 'Codex manifest changed beyond its public version.' }
& git -C $repoRoot diff --quiet HEAD -- 'plugin/frontend-toolkit/.mcp.json' 'plugin/frontend-toolkit/skills' 'plugin/frontend-toolkit/security' 'integrations/mcp.lock.json' 'integrations/toolchain.lock.json' 'third_party'
if ($LASTEXITCODE -ne 0) { throw 'A protected Codex/common path differs from HEAD.' }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ftk03a-test-' + [guid]::NewGuid().ToString('N'))
$commonCandidate = Join-Path $tempRoot 'common'
$claudeCandidate = Join-Path $tempRoot 'claude'
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    & (Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1') -Destination $commonCandidate -DevelopmentWorkingTree | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Common DevelopmentWorkingTree candidate failed.' }
    & $claudeBuilderPath -Destination $claudeCandidate -DevelopmentWorkingTree | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Claude DevelopmentWorkingTree candidate failed.' }

    $commonPaths = @(Get-ArtifactPaths -Root $commonCandidate)
    $claudePaths = @(Get-ArtifactPaths -Root $claudeCandidate)
    $removed = @('.codex-plugin/plugin.json', '.mcp.json')
    $runtimeCandidateRoot = Join-Path $claudeCandidate 'security/claude/runtime/node_modules'
    $runtimeCandidateFiles = @(Get-ChildItem -LiteralPath $runtimeCandidateRoot -Recurse -File -Force | ForEach-Object {
        $_.FullName.Substring($claudeCandidate.Length + 1).Replace('\', '/')
    })
    $expectedClaudePaths = @($commonPaths | Where-Object { $_ -cnotin $removed }) + @(
        '.claude-plugin/plugin.json'
        '.mcp.json'
        'security/claude/launch-shadcn.ps1'
        'security/claude/21st-facade.mjs'
        'security/claude/launch-21st-facade.ps1'
        'security/claude/runtime/package.json'
        'security/claude/runtime/package-lock.json'
        'security/claude/runtime/dependency-provenance.json'
        'security/claude/runtime/THIRD_PARTY_NOTICES.md'
    ) + $runtimeCandidateFiles
    Assert-SetEqual -Actual $claudePaths -Expected $expectedClaudePaths -Label 'Claude artifact file set'
    foreach ($path in @($commonPaths | Where-Object { $_ -cnotin $removed })) {
        Assert-Equal (Get-RelativeFileHash -Root $claudeCandidate -RelativePath $path) (Get-RelativeFileHash -Root $commonCandidate -RelativePath $path) ('Common byte identity ' + $path)
    }
    foreach ($requiredArtifact in @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'external-skills.lock.json', 'SNAPSHOT_PROVENANCE.json', 'integrations/toolchain.lock.json', 'skills/frontend-orchestrator/SKILL.md', 'skills/impeccable/SKILL.md', 'skills/img2threejs/SKILL.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $claudeCandidate $requiredArtifact) -PathType Leaf)) { throw "Required artifact file is missing: $requiredArtifact" }
    }
    if (Test-Path -LiteralPath (Join-Path $claudeCandidate '.codex-plugin')) { throw 'Claude artifact contains .codex-plugin.' }
    $artifactManifest = Get-JsonFile -Path (Join-Path $claudeCandidate '.claude-plugin/plugin.json')
    $artifactMcp = Get-JsonFile -Path (Join-Path $claudeCandidate '.mcp.json')
    Assert-Equal $artifactManifest.defaultEnabled $false 'Artifact defaultEnabled'
    Assert-Equal $artifactManifest.mcpServers './.mcp.json' 'Artifact MCP reference'
    Assert-PropertySet -Object $artifactMcp -Expected @('mcpServers') -Label 'Artifact MCP wrapper'
    Assert-Equal @($artifactMcp.mcpServers.PSObject.Properties).Count 2 'Artifact MCP server count'
    Assert-Equal $artifactMcp.mcpServers.shadcn.command 'powershell.exe' 'Artifact Shadcn command'
    Assert-Equal $artifactMcp.mcpServers.'21st'.command 'powershell.exe' 'Artifact 21st command'
    Assert-Equal $artifactMcp.mcpServers.'21st'.env.API_KEY_21ST '${API_KEY_21ST}' 'Artifact 21st environment'
    if ((Get-Content -Raw -LiteralPath (Join-Path $claudeCandidate '.mcp.json')).IndexOf('21st.dev', [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Artifact Claude MCP exposes 21st remote URL.' }

    $launcherStart = New-Object Diagnostics.ProcessStartInfo
    $launcherStart.FileName = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $launcherStart.UseShellExecute = $false
    $launcherStart.CreateNoWindow = $true
    $launcherStart.RedirectStandardOutput = $true
    $launcherStart.RedirectStandardError = $true
    $launcherStart.Arguments = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $claudeCandidate 'security/claude/launch-shadcn.ps1'), '-ValidateOnly') | ForEach-Object {
        ConvertTo-TestWindowsNativeArgument -Value ([string]$_)
    }) -join ' '
    $launcherProcess = New-Object Diagnostics.Process
    $launcherProcess.StartInfo = $launcherStart
    try {
        if (-not $launcherProcess.Start()) { throw 'Hermetic launcher process did not start.' }
        $launcherStdout = $launcherProcess.StandardOutput.ReadToEnd()
        $launcherStderr = $launcherProcess.StandardError.ReadToEnd()
        $launcherProcess.WaitForExit()
        $launcherExitCode = $launcherProcess.ExitCode
    } finally { $launcherProcess.Dispose() }
    if ($launcherExitCode -ne 0) { throw 'Hermetic launcher validation failed.' }
    if ($launcherStdout.Trim().Length -ne 0) { throw 'Launcher validation wrote to stdout.' }
    $validation = $launcherStderr | ConvertFrom-Json
    Assert-Equal $validation.runtime 'locked-node' 'Launcher runtime mode'
    Assert-Equal $validation.nodeVersion '24.20.0' 'Launcher Node version'
    Assert-Equal $validation.npxEntrypoint 'node_modules/npm/bin/npx-cli.js' 'Launcher npx entrypoint'
    Assert-Equal (@($validation.arguments) -join "`n") (@('--yes', 'shadcn@4.19.0', 'mcp') -join "`n") 'Launcher package arguments'
    if (@($validation.environmentNames) -notcontains 'NODE_OPTIONS' -or @($validation.environmentNames) -notcontains 'NPM_CONFIG_USERCONFIG') { throw 'Launcher child environment contract is incomplete.' }
    Assert-Equal $validation.stdoutPassthrough $true 'Launcher stdout passthrough'
    Assert-Equal $validation.stderrPassthrough $true 'Launcher stderr passthrough'

    $facadeLauncherTest = Join-Path $repoRoot 'tests/test-21st-facade.ps1'
    if (-not (Test-Path -LiteralPath $facadeLauncherTest -PathType Leaf)) { throw 'Hermetic 21st facade runner is missing.' }
    $facadeTestResult = & $facadeLauncherTest -CandidateRoot $claudeCandidate 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Hermetic 21st facade runner failed: $facadeTestResult" }
    if ($facadeTestResult -notmatch 'PASS: hermetic MCP stdio/client') { throw 'Hermetic 21st facade runner output is incomplete.' }

    Write-Output 'PASS: common metadata matches Codex and Claude manifest drift is detected.'
    Write-Output 'PASS: Claude MCP has exactly Shadcn and the local 21st facade server.'
    Write-Output 'PASS: DevelopmentWorkingTree Claude candidate preserves common files byte-identically.'
    Write-Output 'PASS: structural artifact validation preserves Skills, notices, provenance and runtime lock.'
    Write-Output 'PASS: launcher resolved the pinned Node/npx contract and built Shadcn argv without starting MCP.'
    Write-Output 'PASS: hermetic 21st MCP stdio/client and launcher tests passed.'
    Write-Output 'NETWORK CALLS=0; SECRETS READ=0; MCP REAL=0'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
