param(
    [string]$CodexPath = $env:FTK_CODEX_PATH,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileHashOrAbsent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<absent>' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = & (Join-Path $PSScriptRoot 'resolve-toolchain.ps1')
$mcpLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/mcp.lock.json') | ConvertFrom-Json
$server = $mcpLock.servers | Where-Object id -eq '21st'
if (-not $server -or $server.endpoint -ne 'https://21st.dev/api/mcp') { throw '21st MCP endpoint is not locked.' }
if ($server.authentication.envVar -ne 'API_KEY_21ST') { throw '21st credential environment variable is not locked.' }
if (-not $CodexPath) { $CodexPath = $toolchain.StableCodexPath }
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
$codexVersion = ((& $CodexPath --version).Trim() -replace '^codex-cli\s+', '')
if ($codexVersion -ne '0.150.1') { throw "Expected stable Codex 0.150.1, found $codexVersion at $CodexPath" }

$credentialAvailable = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST', 'Process'))
if ($ValidateOnly) {
    [pscustomobject]@{
        Mode = 'validate-only'
        CodexPath = $CodexPath
        CodexVersion = $codexVersion
        Endpoint = $server.endpoint
        CredentialGate = if ($credentialAvailable) { 'available' } else { 'waiting' }
        PersistentConfiguration = 'none'
    }
    exit 0
}
if (-not $credentialAvailable) {
    Write-Output 'FTK-03B aguardando API_KEY_21ST fornecida externamente.'
    exit 0
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $temporaryRoot ("frontend-toolkit-21st-stable-" + [guid]::NewGuid().ToString('N'))
$profileName = 'ftk-21st-' + [guid]::NewGuid().ToString('N')
$profilePath = Join-Path $env:USERPROFILE ".codex/$profileName.config.toml"
$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = Get-FileHashOrAbsent $configPath
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$processPathBefore = $env:PATH
$pythonPathBefore = $env:FTK_PYTHON_PATH
$profileHash = $null

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $fixture '.agents/skills') -Force)
    & git init --quiet $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the synthetic Git fixture.' }
    [void](New-Item -ItemType Junction -Path (Join-Path $fixture '.agents/skills/impeccable') -Target (Join-Path $repoRoot 'external/impeccable/plugin/skills/impeccable'))
    [void](New-Item -ItemType Junction -Path (Join-Path $fixture '.agents/skills/img2threejs') -Target (Join-Path $repoRoot 'external/img2threejs'))

    $profile = @"
[mcp_servers.node_repl]
enabled = false

[mcp_servers.shadcn]
command = "node"
args = ["disabled-for-ftk-03b"]
enabled = false

[mcp_servers.21st]
url = "https://21st.dev/api/mcp"
bearer_token_env_var = "API_KEY_21ST"
enabled = true
enabled_tools = ["search"]
startup_timeout_sec = 120
tool_timeout_sec = 120

[projects.'$($fixture.ToLowerInvariant().Replace('/', '\'))']
trust_level = "trusted"
"@
    [IO.File]::WriteAllText($profilePath, $profile, [Text.UTF8Encoding]::new($false))
    $profileHash = Get-FileHashOrAbsent $profilePath
    if ((Get-Content -Raw -LiteralPath $profilePath) -notmatch 'bearer_token_env_var\s*=\s*"API_KEY_21ST"') {
        throw 'Temporary profile does not reference API_KEY_21ST correctly.'
    }

    $listJson = (& $CodexPath -p $profileName mcp list --json | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Stable Codex could not list the temporary MCP profile.' }
    $list = $listJson | ConvertFrom-Json
    $registered = @($list | Where-Object name -eq '21st')
    if ($registered.Count -ne 1) { throw 'Temporary profile did not register exactly one 21st server.' }
    $serializedRegistration = $registered[0] | ConvertTo-Json -Depth 10
    if ($serializedRegistration -notmatch [regex]::Escape('https://21st.dev/api/mcp')) { throw 'Codex registration has the wrong 21st endpoint.' }
    $shadcnRegistration = @($list | Where-Object name -eq 'shadcn')
    if ($shadcnRegistration.Count -ne 1 -or $shadcnRegistration[0].enabled -ne $false) { throw 'Shadcn is not disabled in the FTK-03B profile.' }

    $disableOverrides = @()
    foreach ($inherited in @($list | Where-Object { $_.name -ne '21st' -and $_.enabled -eq $true })) {
        if ($inherited.name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Inherited MCP name cannot be safely overridden for the isolated test.' }
        $disableOverrides += "mcp_servers.$($inherited.name).enabled=false"
    }
    $isolatedListArgs = @('-p', $profileName)
    foreach ($override in $disableOverrides) { $isolatedListArgs += @('-c', $override) }
    $isolatedListArgs += @('mcp', 'list', '--json')
    $isolatedListJson = (& $CodexPath @isolatedListArgs | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Stable Codex could not validate the isolated MCP set.' }
    $enabledServers = @(($isolatedListJson | ConvertFrom-Json) | Where-Object enabled -eq $true)
    if ($enabledServers.Count -ne 1 -or $enabledServers[0].name -ne '21st') { throw 'FTK-03B test isolation did not leave only 21st enabled.' }

    $env:PATH = "$($toolchain.NodeDirectory);$processPathBefore"
    $env:FTK_PYTHON_PATH = $toolchain.PythonPath
    $prompt = 'Use exclusivamente o MCP 21st para pesquisar por componentes relacionados a dashboard. Não gere, instale, publique, edite ou exclua nada. Resuma somente os resultados da busca.'
    $execArgs = @('-p', $profileName)
    foreach ($override in $disableOverrides) { $execArgs += @('-c', $override) }
    $execArgs += @('exec', '--ephemeral', '--sandbox', 'danger-full-access', '--skip-git-repo-check', '--cd', $fixture, $prompt)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $CodexPath @execArgs 2>&1 | Out-String).TrimEnd()
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw "Stable Codex exec failed with exit code $exitCode.`n$output" }
    if ($output -notmatch 'mcp: 21st/search \(completed\)') { throw "Stable Codex output does not prove a completed 21st search.`n$output" }
    if ($output -match '(?m)^mcp:\s+21st/(?!search\b)') { throw 'Codex invoked a non-allowlisted 21st tool.' }
    if ($output -notmatch '(?i)dashboard') { throw 'Codex did not summarize dashboard search results.' }
    Write-Output $output
    [pscustomobject]@{
        CodexPath = $CodexPath
        CodexVersion = $codexVersion
        RegisteredServer = '21st'
        EnabledTools = @('search')
        ShadcnEnabled = $false
        EnabledServerCount = $enabledServers.Count
        McpCall = 'completed'
        PersistentMutation = 'none'
    }
} finally {
    $env:PATH = $processPathBefore
    $env:FTK_PYTHON_PATH = $pythonPathBefore
    if (Test-Path -LiteralPath $profilePath) {
        if ((Get-FileHashOrAbsent $profilePath) -ne $profileHash) { throw 'Temporary profile changed concurrently; refusing teardown.' }
        Remove-Item -LiteralPath $profilePath -Force
    }
    if (Test-Path -LiteralPath $fixture) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixture)
        if (-not $resolvedFixture.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture path: $resolvedFixture" }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

if ((Get-FileHashOrAbsent $configPath) -ne $configHashBefore) { throw 'Codex user config changed.' }
if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $userPathBefore) { throw 'Persistent user PATH changed.' }
if ([Environment]::GetEnvironmentVariable('Path', 'Machine') -ne $machinePathBefore) { throw 'Persistent machine PATH changed.' }
if (Test-Path -LiteralPath $profilePath) { throw 'Temporary 21st profile survived teardown.' }
