param(
    [string]$CodexPath = $env:FTK_CODEX_PATH,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = & (Join-Path $PSScriptRoot 'resolve-toolchain.ps1')
$mcpLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/mcp.lock.json') | ConvertFrom-Json
$shadcn = $mcpLock.servers | Where-Object id -eq 'shadcn'
if (-not $shadcn -or $shadcn.version -ne '4.19.0') { throw 'Shadcn MCP lock is not pinned to 4.19.0.' }
if (-not $CodexPath) { $CodexPath = $toolchain.StableCodexPath }
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
$codexVersion = ((& $CodexPath --version).Trim() -replace '^codex-cli\s+', '')
if ($codexVersion -ne '0.150.1') { throw "Expected stable Codex 0.150.1, found $codexVersion at $CodexPath" }

$npxCli = Join-Path $toolchain.NodeDirectory 'node_modules/npm/bin/npx-cli.js'
if (-not (Test-Path -LiteralPath $npxCli -PathType Leaf)) { throw "Pinned npx CLI not found: $npxCli" }

if ($ValidateOnly) {
    [pscustomobject]@{
        Mode = 'validate-only'
        CodexPath = $CodexPath
        CodexVersion = $codexVersion
        CodeModeHostPath = $toolchain.CodeModeHostPath
        ShadcnVersion = $shadcn.version
        NodePath = $toolchain.NodePath
        PersistentConfiguration = 'none'
    }
    exit 0
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $temporaryRoot ("frontend-toolkit-shadcn-stable-" + [guid]::NewGuid().ToString('N'))
$profileName = 'ftk-shadcn-' + [guid]::NewGuid().ToString('N')
$profilePath = Join-Path $env:USERPROFILE ".codex/$profileName.config.toml"
$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$processPathBefore = $env:PATH
$pythonPathBefore = $env:FTK_PYTHON_PATH
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $fixture '.agents/skills') -Force)
    & git init --quiet $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the synthetic Git fixture.' }
Copy-Item -LiteralPath (Join-Path $repoRoot '.agents/skills/impeccable') -Destination (Join-Path $fixture '.agents/skills/impeccable') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot '.agents/skills/img2threejs') -Destination (Join-Path $fixture '.agents/skills/img2threejs') -Recurse
    [IO.File]::WriteAllText((Join-Path $fixture 'components.json'), '{"$schema":"https://ui.shadcn.com/schema.json","style":"new-york","rsc":false,"tsx":true,"tailwind":{"config":"","css":"src/index.css","baseColor":"neutral","cssVariables":true,"prefix":""},"aliases":{"components":"@/components","utils":"@/lib/utils","ui":"@/components/ui","lib":"@/lib","hooks":"@/hooks"},"iconLibrary":"lucide"}', [Text.UTF8Encoding]::new($false))

    $portableNpxCli = $npxCli.Replace('\', '/')
    $trustPath = $fixture.ToLowerInvariant().Replace('/', '\')
    $profile = @"
[mcp_servers.node_repl]
enabled = false

[mcp_servers.shadcn]
command = "node"
args = ["$portableNpxCli", "--yes", "shadcn@4.19.0", "mcp"]
startup_timeout_sec = 120
env = { NODE_OPTIONS = "--use-system-ca" }

[projects.'$trustPath']
trust_level = "trusted"
"@
    [IO.File]::WriteAllText($profilePath, $profile, [Text.UTF8Encoding]::new($false))
    $env:PATH = "$($toolchain.NodeDirectory);$processPathBefore"
    $env:FTK_PYTHON_PATH = $toolchain.PythonPath
$prompt = 'Read only the SKILL.md files for $impeccable and $img2threejs, then use exclusively search_items_in_registries from the shadcn MCP to search for button in @shadcn. Also report node --version and FTK_PYTHON_PATH --version. Do not edit files, install components, use other MCPs, or activate hooks.'
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $CodexPath -p $profileName exec --ephemeral --sandbox danger-full-access --skip-git-repo-check --cd $fixture $prompt 2>&1 | Out-String).TrimEnd()
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw "Stable Codex exec failed with exit code $exitCode.`n$output" }
    if ($output -notmatch 'mcp: shadcn/search_items_in_registries \(completed\)' -or $output -notmatch '(?i)item.*button|button.*registry:ui') {
        throw "Stable Codex output does not prove a completed Shadcn query.`n$output"
    }
    if ($output -notmatch 'impeccable' -or $output -notmatch 'img2threejs') { throw 'Stable Codex did not confirm both Skills.' }
    Write-Output $output
    [pscustomobject]@{ CodexPath = $CodexPath; CodexVersion = $codexVersion; McpCall = 'completed'; PersistentMutation = 'none' }
} finally {
    $env:PATH = $processPathBefore
    $env:FTK_PYTHON_PATH = $pythonPathBefore
    if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath -Force }
    if (Test-Path -LiteralPath $fixture) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixture)
        if (-not $resolvedFixture.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture path: $resolvedFixture" }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

if ((Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash -ne $configHashBefore) { throw 'Codex user config changed.' }
if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $userPathBefore) { throw 'Persistent user PATH changed.' }
if ([Environment]::GetEnvironmentVariable('Path', 'Machine') -ne $machinePathBefore) { throw 'Persistent machine PATH changed.' }
