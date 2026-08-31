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

function Assert-CompletedCall {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string[]]$ForbiddenPatterns
    )
    if ($Output -notmatch [regex]::Escape("mcp: $Expected (completed)")) {
        throw "Codex output does not prove completed MCP call $Expected.`n$Output"
    }
    foreach ($pattern in $ForbiddenPatterns) {
        if ($Output -match $pattern) { throw "Codex invoked a forbidden MCP tool during $Expected.`n$Output" }
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = & (Join-Path $PSScriptRoot 'resolve-toolchain.ps1')
$mcpLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/mcp.lock.json') | ConvertFrom-Json
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$shadcn = $mcpLock.servers | Where-Object id -eq 'shadcn'
$twentyFirst = $mcpLock.servers | Where-Object id -eq '21st'
if ($shadcn.version -ne '4.19.0') { throw 'Combined test requires shadcn 4.19.0.' }
if ($twentyFirst.endpoint -ne 'https://21st.dev/api/mcp' -or $twentyFirst.authentication.envVar -ne 'API_KEY_21ST') { throw 'Combined test requires the locked 21st endpoint and credential reference.' }
if (-not $CodexPath) { $CodexPath = $toolchain.StableCodexPath }
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
$codexVersion = ((& $CodexPath --version).Trim() -replace '^codex-cli\s+', '')
if ($codexVersion -ne '0.150.1') { throw "Expected stable Codex 0.150.1, found $codexVersion." }
if (-not (Test-Path -LiteralPath $toolchain.CodeModeHostPath -PathType Leaf)) { throw 'Stable Codex code-mode host is missing.' }

$credentialAvailable = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST', 'Process'))
if ($ValidateOnly) {
    [pscustomobject]@{
        Mode = 'validate-only'
        CodexVersion = $codexVersion
        CodeModeHost = $toolchain.CodeModeHostPath
        ShadcnVersion = $shadcn.version
        TwentyFirstEndpoint = $twentyFirst.endpoint
        CredentialGate = if ($credentialAvailable) { 'available' } else { 'waiting' }
    }
    exit 0
}
if (-not $credentialAvailable) {
    Write-Output 'FTK-03C aguardando API_KEY_21ST fornecida externamente.'
    exit 0
}

$npxCli = Join-Path $toolchain.NodeDirectory 'node_modules/npm/bin/npx-cli.js'
if (-not (Test-Path -LiteralPath $npxCli -PathType Leaf)) { throw 'Pinned npx CLI is missing.' }
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $temporaryRoot ("frontend-toolkit-combined-" + [guid]::NewGuid().ToString('N'))
$profileName = 'ftk-combined-' + [guid]::NewGuid().ToString('N')
$profilePath = Join-Path $env:USERPROFILE ".codex/$profileName.config.toml"
$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = Get-FileHashOrAbsent $configPath
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$processPathBefore = $env:PATH
$pythonPathBefore = $env:FTK_PYTHON_PATH
$nodeOptionsBefore = $env:NODE_OPTIONS
$npxPathBefore = $env:FTK_NPX_CLI_PATH
$profileHash = $null
$fixtureGitBefore = $null
$result = $null

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $fixture '.agents/skills') -Force)
    & git init --quiet $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the combined synthetic fixture.' }
Copy-Item -LiteralPath (Join-Path $repoRoot '.agents/skills/impeccable') -Destination (Join-Path $fixture '.agents/skills/impeccable') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot '.agents/skills/img2threejs') -Destination (Join-Path $fixture '.agents/skills/img2threejs') -Recurse
    [IO.File]::WriteAllText((Join-Path $fixture 'components.json'), '{"$schema":"https://ui.shadcn.com/schema.json","style":"new-york","rsc":false,"tsx":true,"tailwind":{"config":"","css":"src/index.css","baseColor":"neutral","cssVariables":true,"prefix":""},"aliases":{"components":"@/components","utils":"@/lib/utils","ui":"@/components/ui","lib":"@/lib","hooks":"@/hooks"},"iconLibrary":"lucide"}', [Text.UTF8Encoding]::new($false))
    $fixtureGitBefore = (& git -C $fixture status --porcelain=v1 --untracked-files=all | Out-String)

    $env:PATH = "$($toolchain.NodeDirectory);$processPathBefore"
    $env:FTK_PYTHON_PATH = $toolchain.PythonPath
    $env:NODE_OPTIONS = '--use-system-ca'
    $env:FTK_NPX_CLI_PATH = $npxCli
    Push-Location $fixture
    try {
        $shadcnRaw = & $toolchain.NodePath (Join-Path $repoRoot 'tests/helpers/shadcn-mcp-smoke.mjs') | Out-String
        if ($LASTEXITCODE -ne 0) { throw 'Combined Shadcn tools/list failed.' }
        $twentyFirstRaw = & $toolchain.NodePath (Join-Path $repoRoot 'tests/helpers/21st-mcp-smoke.mjs') | Out-String
        if ($LASTEXITCODE -ne 0) { throw 'Combined 21st tools/list failed.' }
    } finally { Pop-Location }
    $shadcnDirect = $shadcnRaw | ConvertFrom-Json
    $twentyFirstDirect = $twentyFirstRaw | ConvertFrom-Json
    $shadcnTools = @($shadcnDirect.tools.name)
    $twentyFirstTools = @($twentyFirstDirect.tools.name)
    $lockedTwentyFirstTools = @(
        @($twentyFirst.observedToolSurface.discoveryReadOnly) +
        @($twentyFirst.observedToolSurface.retrieval) +
        @($twentyFirst.observedToolSurface.accountUsageReadOnly) +
        @($twentyFirst.observedToolSurface.generationMetered) +
        @($twentyFirst.observedToolSurface.mutationWrite)
    )
    $twentyFirstDrift = @(Compare-Object ($lockedTwentyFirstTools | Sort-Object) ($twentyFirstTools | Sort-Object))
    if ($twentyFirstDrift.Count) {
        $summary = $twentyFirstDrift | ForEach-Object { "$($_.SideIndicator)$($_.InputObject)" }
        throw "21st tool inventory drifted from FTK-03B; lock was not changed: $($summary -join ', ')"
    }
    $expectedShadcnTools = @('get_project_registries','list_items_in_registries','search_items_in_registries','view_items_in_registries','get_item_examples_from_registries','get_add_command_for_items','get_audit_checklist')
    if (@(Compare-Object ($expectedShadcnTools | Sort-Object) ($shadcnTools | Sort-Object)).Count) { throw 'Shadcn tool inventory drifted from the approved seven-tool surface.' }

    $portableNpxCli = $npxCli.Replace('\', '/')
    $trustPath = $fixture.ToLowerInvariant().Replace('/', '\')
    $profile = @"
[mcp_servers.node_repl]
enabled = false

[mcp_servers.shadcn]
command = "node"
args = ["$portableNpxCli", "--yes", "shadcn@4.19.0", "mcp"]
startup_timeout_sec = 120
tool_timeout_sec = 120
env = { NODE_OPTIONS = "--use-system-ca" }
enabled = true
enabled_tools = ["search_items_in_registries"]

[mcp_servers.21st]
url = "https://21st.dev/api/mcp"
bearer_token_env_var = "API_KEY_21ST"
startup_timeout_sec = 120
tool_timeout_sec = 120
enabled = true
enabled_tools = ["search"]

[projects.'$trustPath']
trust_level = "trusted"
"@
    [IO.File]::WriteAllText($profilePath, $profile, [Text.UTF8Encoding]::new($false))
    $profileHash = Get-FileHashOrAbsent $profilePath
    $profileText = Get-Content -Raw -LiteralPath $profilePath
    if ($profileText -notmatch 'bearer_token_env_var\s*=\s*"API_KEY_21ST"' -or $profileText -match '(?i)--api-key') { throw 'Combined profile violates the credential contract.' }

    $listJson = (& $CodexPath -p $profileName mcp list --json | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Stable Codex could not list the combined profile.' }
    $list = $listJson | ConvertFrom-Json
    foreach ($requiredServer in @('shadcn','21st')) {
        $registration = @($list | Where-Object name -eq $requiredServer)
        if ($registration.Count -ne 1 -or $registration[0].enabled -ne $true) { throw "Combined profile did not enable $requiredServer exactly once." }
    }
    $disableOverrides = @()
    foreach ($inherited in @($list | Where-Object { $_.name -notin @('shadcn','21st') -and $_.enabled -eq $true })) {
        if ($inherited.name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Inherited MCP name cannot be safely disabled for the combined test.' }
        $disableOverrides += "mcp_servers.$($inherited.name).enabled=false"
    }
    $baseArgs = @('-p', $profileName)
    foreach ($override in $disableOverrides) { $baseArgs += @('-c', $override) }
    $isolatedListJson = (& $CodexPath @baseArgs mcp list --json | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Stable Codex could not validate the combined isolated server set.' }
    $enabledServers = @((($isolatedListJson | ConvertFrom-Json) | Where-Object enabled -eq $true).name | Sort-Object)
    if (@(Compare-Object @('21st','shadcn') $enabledServers).Count) { throw 'A third MCP remained enabled in the combined fixture.' }

    Push-Location $fixture
    try {
        $skillPrompt = (& $CodexPath @baseArgs debug prompt-input 'Combined capability discovery contract.' | Out-String)
    } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Combined Skill discovery failed.' }
    foreach ($dependency in $externalLock.dependencies) {
        if (-not $skillPrompt.Contains("- $($dependency.discoveredName):")) { throw "Combined fixture did not advertise Skill $($dependency.discoveredName)." }
    }

    function Invoke-CombinedPrompt {
        param([Parameter(Mandatory)][string]$Prompt)
        $args = @($baseArgs) + @('exec','--ephemeral','--sandbox','danger-full-access','--skip-git-repo-check','--cd',$fixture,$Prompt)
        $preference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $text = (& $CodexPath @args 2>&1 | Out-String).TrimEnd()
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $preference }
        if ($exitCode -ne 0) { throw "Combined Codex exec failed with exit code $exitCode.`n$text" }
        return $text
    }

    $shadcnPrompt = 'Use exclusivamente o MCP shadcn para procurar o componente button no registry oficial. Não use 21st e não modifique arquivos.'
    $shadcnOutput = Invoke-CombinedPrompt $shadcnPrompt
    Assert-CompletedCall -Output $shadcnOutput -Expected 'shadcn/search_items_in_registries' -ForbiddenPatterns @('(?m)^mcp:\s+21st/')

    $twentyFirstPrompt = 'Use exclusivamente o MCP 21st para pesquisar componentes relacionados a dashboard. Use somente busca gratuita/read-only. Não use Shadcn. Não gere, instale, copie, publique, edite, exclua ou faça bookmark.'
    $twentyFirstOutput = Invoke-CombinedPrompt $twentyFirstPrompt
    Assert-CompletedCall -Output $twentyFirstOutput -Expected '21st/search' -ForbiddenPatterns @('(?m)^mcp:\s+shadcn/','(?m)^mcp:\s+21st/(?!search\b)')

    $sequentialPrompt = 'Primeiro use Shadcn para localizar o componente button oficial. Depois use 21st somente em modo search para encontrar inspiração relacionada a button. Não instale, gere, copie ou modifique nada.'
    $sequentialOutput = Invoke-CombinedPrompt $sequentialPrompt
    Assert-CompletedCall -Output $sequentialOutput -Expected 'shadcn/search_items_in_registries' -ForbiddenPatterns @('(?m)^mcp:\s+21st/(?!search\b)')
    Assert-CompletedCall -Output $sequentialOutput -Expected '21st/search' -ForbiddenPatterns @('(?m)^mcp:\s+shadcn/(?!search_items_in_registries\b)')
    $shadcnStarted = $sequentialOutput.IndexOf('mcp: shadcn/search_items_in_registries started', [StringComparison]::Ordinal)
    $shadcnCompleted = $sequentialOutput.IndexOf('mcp: shadcn/search_items_in_registries (completed)', [StringComparison]::Ordinal)
    $twentyFirstStarted = $sequentialOutput.IndexOf('mcp: 21st/search started', [StringComparison]::Ordinal)
    $twentyFirstCompleted = $sequentialOutput.IndexOf('mcp: 21st/search (completed)', [StringComparison]::Ordinal)
    if (-not (0 -le $shadcnStarted -and $shadcnStarted -lt $shadcnCompleted -and $shadcnCompleted -lt $twentyFirstStarted -and $twentyFirstStarted -lt $twentyFirstCompleted)) {
        throw "Combined sequential call order was not Shadcn then 21st.`n$sequentialOutput"
    }

    $fixtureGitAfter = (& git -C $fixture status --porcelain=v1 --untracked-files=all | Out-String)
    if ($fixtureGitBefore -ne $fixtureGitAfter) { throw 'Combined Codex tests mutated the synthetic fixture.' }
    $result = [pscustomobject]@{
        Mode = 'executed'
        CodexVersion = $codexVersion
        CredentialGate = 'available'
        Skills = @($externalLock.dependencies.discoveredName)
        EnabledServers = $enabledServers
        ShadcnToolCount = $shadcnTools.Count
        ShadcnTools = $shadcnTools
        TwentyFirstToolCount = $twentyFirstTools.Count
        TwentyFirstTools = $twentyFirstTools
        TwentyFirstSnapshotComparison = 'identical-to-ftk-03b'
        Namespaces = @('shadcn/search_items_in_registries','21st/search')
        ShadcnTest = 'passed'
        TwentyFirstTest = 'passed-search-only'
        SequentialTest = 'passed-shadcn-then-21st'
        PaidOrMutableCalls = 0
        FixtureMutation = 'none'
        PersistentMutation = 'none'
    }
} finally {
    $env:PATH = $processPathBefore
    $env:FTK_PYTHON_PATH = $pythonPathBefore
    $env:NODE_OPTIONS = $nodeOptionsBefore
    $env:FTK_NPX_CLI_PATH = $npxPathBefore
    if (Test-Path -LiteralPath $profilePath) {
        if ((Get-FileHashOrAbsent $profilePath) -ne $profileHash) { throw 'Combined profile changed concurrently; refusing teardown.' }
        Remove-Item -LiteralPath $profilePath -Force
    }
    if (Test-Path -LiteralPath $fixture) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixture)
        if (-not $resolvedFixture.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe combined fixture path: $resolvedFixture" }
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction Stop
                break
            } catch {
                if ($attempt -eq 20) { throw }
                Start-Sleep -Milliseconds 250
            }
        }
    }
}

if ((Get-FileHashOrAbsent $configPath) -ne $configHashBefore) { throw 'Codex user config changed during combined validation.' }
if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $userPathBefore) { throw 'Persistent user PATH changed during combined validation.' }
if ([Environment]::GetEnvironmentVariable('Path', 'Machine') -ne $machinePathBefore) { throw 'Persistent machine PATH changed during combined validation.' }
if (Test-Path -LiteralPath $profilePath) { throw 'Combined profile survived teardown.' }
Write-Output $result
