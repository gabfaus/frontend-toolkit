param(
    [string]$CodexPath = $env:FTK_CODEX_PATH,
    [ValidateRange(1, 10)]
    [int[]]$ScenarioId = (1..10),
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileHashOrAbsent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<absent>' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-RouteMarker {
    param([Parameter(Mandatory)][string]$Output)
    $match = [regex]::Match($Output, '(?m)^FTK_ROUTE:\s*(?<route>[^\r\n]+)\s*$')
    if (-not $match.Success) { throw "Codex output has no FTK_ROUTE marker.`n$Output" }
    $capabilities = @($match.Groups['route'].Value.Split(',') | ForEach-Object {
        $selected = $_.Trim()
        if ($selected -match '^21st(?:[/.]search)?$') { '21st' }
        elseif ($selected -match '^shadcn(?:[/.]search_items_in_registries)?$') { 'shadcn' }
        else { $selected }
    })
    return ($capabilities -join ',')
}

function Assert-NoMcpCall {
    param([Parameter(Mandatory)][string]$Output)
    if ($Output -match '(?m)^mcp:\s+') { throw "Unexpected MCP call.`n$Output" }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = & (Join-Path $PSScriptRoot 'resolve-toolchain.ps1')
$policy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/routing-policy.json') | ConvertFrom-Json
$matrix = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/scenarios.json') | ConvertFrom-Json
$mcpLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/mcp.lock.json') | ConvertFrom-Json
$shadcn = $mcpLock.servers | Where-Object id -eq 'shadcn'
$twentyFirst = $mcpLock.servers | Where-Object id -eq '21st'

if ($toolchain.StableCodexVersion -ne '0.150.1') { throw 'FTK-04B requires Codex CLI 0.150.1.' }
if ($policy.principle -ne 'minimum-necessary-capabilities' -or $matrix.schemaVersion -ne 2 -or @($matrix.scenarios).Count -ne 17) { throw 'Versioned routing contract is invalid.' }
if (@($ScenarioId | Sort-Object -Unique).Count -ne @($ScenarioId).Count) { throw 'Scenario identifiers must be unique.' }
if (@($policy.capabilities.'21st'.defaultAllowedTools) -ne 'search') { throw '21st default allowlist is not search-only.' }
if ($shadcn.version -ne '4.19.0' -or $twentyFirst.authentication.envVar -ne 'API_KEY_21ST') { throw 'MCP locks do not match the approved baseline.' }
if (-not $CodexPath) { $CodexPath = $toolchain.StableCodexPath }
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
if (((& $CodexPath --version).Trim() -replace '^codex-cli\s+', '') -ne '0.150.1') { throw 'Unexpected Codex CLI version.' }

$credentialAvailable = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST','Process'))
if ($ValidateOnly) {
    [pscustomobject]@{
        Mode = 'validate-only'
        ScenarioCount = @($matrix.scenarios).Count
        CodexVersion = $toolchain.StableCodexVersion
        ShadcnVersion = $shadcn.version
        TwentyFirstTools = @('search')
        CredentialGate = if ($credentialAvailable) { 'available' } else { 'waiting' }
        Sandbox = 'danger-full-access'
    }
    return
}
if (-not $credentialAvailable) { throw 'FTK-04B requires API_KEY_21ST for the approved search-only scenario.' }

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $temporaryRoot ('frontend-toolkit-routing-' + [guid]::NewGuid().ToString('N'))
$profileName = 'ftk-routing-' + [guid]::NewGuid().ToString('N')
$profilePath = Join-Path $env:USERPROFILE ".codex/$profileName.config.toml"
$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = Get-FileHashOrAbsent $configPath
$userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path','Machine')
$processPathBefore = $env:PATH
$pythonPathBefore = $env:FTK_PYTHON_PATH
$nodeOptionsBefore = $env:NODE_OPTIONS
$npxPathBefore = $env:FTK_NPX_CLI_PATH
$profileHash = $null
$fixtureGitBefore = $null
$fixtureArtifactsCreated = $false
$fixtureRemoved = $false
$externalGitBefore = @{}
foreach ($checkout in @('external/impeccable','external/img2threejs')) {
    $externalGitBefore[$checkout] = (& git -C (Join-Path $repoRoot $checkout) status --porcelain=v1 --untracked-files=all | Out-String)
}
$results = @()

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $fixture '.agents/skills') -Force)
    & git init --quiet $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the synthetic routing fixture.' }
Copy-Item -LiteralPath (Join-Path $repoRoot '.agents/skills/frontend-orchestrator') -Destination (Join-Path $fixture '.agents/skills/frontend-orchestrator') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot '.agents/skills/impeccable') -Destination (Join-Path $fixture '.agents/skills/impeccable') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot '.agents/skills/img2threejs') -Destination (Join-Path $fixture '.agents/skills/img2threejs') -Recurse
    [IO.File]::WriteAllText((Join-Path $fixture 'components.json'), '{"$schema":"https://ui.shadcn.com/schema.json","style":"new-york","rsc":false,"tsx":true,"tailwind":{"config":"","css":"src/index.css","baseColor":"neutral","cssVariables":true,"prefix":""},"aliases":{"components":"@/components","utils":"@/lib/utils","ui":"@/components/ui","lib":"@/lib","hooks":"@/hooks"},"iconLibrary":"lucide"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture 'SCREEN.md'), "# Fixture sintética`n`nTela com cabeçalho, busca central e tabela de resultados.`n", [Text.UTF8Encoding]::new($false))
    $fixtureGitBefore = (& git -C $fixture status --porcelain=v1 --untracked-files=all | Out-String)

    $npxCli = Join-Path $toolchain.NodeDirectory 'node_modules/npm/bin/npx-cli.js'
    $portableNpxCli = $npxCli.Replace('\','/')
    $trustPath = $fixture.ToLowerInvariant().Replace('/','\')
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

    $env:PATH = "$($toolchain.NodeDirectory);$processPathBefore"
    $env:FTK_PYTHON_PATH = $toolchain.PythonPath
    $env:NODE_OPTIONS = '--use-system-ca'
    $env:FTK_NPX_CLI_PATH = $npxCli

    $list = (& $CodexPath -p $profileName mcp list --json | Out-String) | ConvertFrom-Json
    $disableOverrides = @()
    foreach ($inherited in @($list | Where-Object { $_.name -notin @('shadcn','21st') -and $_.enabled -eq $true })) {
        if ($inherited.name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Unsafe inherited MCP name.' }
        $disableOverrides += "mcp_servers.$($inherited.name).enabled=false"
    }
    $baseArgs = @('-p',$profileName)
    foreach ($override in $disableOverrides) { $baseArgs += @('-c',$override) }

    function Invoke-RoutingScenario {
        param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Prompt)
        $suffix = if ($Id -eq 10) {
            ' Use SYNTHETIC_REFERENCE.png como imagem de referência. Você pode criar estado e evidências somente dentro de .img2threejs/ nesta fixture efêmera. Não escreva em .agents/, nos checkouts das Skills ou fora da fixture. Valide o roteamento com a evidência mínima necessária; não é preciso concluir a reconstrução 3D. No fim, escreva em uma linha FTK_ROUTE: seguida apenas pelas capabilities efetivamente selecionadas, em ordem, separadas por vírgula. Não use 21st.'
        } else {
            ' Trabalhe somente com a fixture sintética e não altere arquivos. No fim, escreva em uma linha FTK_ROUTE: seguida apenas pelas capabilities efetivamente selecionadas, em ordem, separadas por vírgula; use none se nenhuma puder ser executada. Se houver gate, escreva também FTK_GATE: authorization-required.'
        }
        $args = @($baseArgs) + @('exec','--ephemeral','--sandbox','danger-full-access','--skip-git-repo-check','--cd',$fixture,($Prompt + $suffix))
        $stdoutPath = Join-Path $temporaryRoot ('ftk-routing-' + [guid]::NewGuid().ToString('N') + '.stdout.log')
        $stderrPath = Join-Path $temporaryRoot ('ftk-routing-' + [guid]::NewGuid().ToString('N') + '.stderr.log')
        $argumentLine = (($args | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' ')
        try {
            $process = Start-Process -FilePath $CodexPath -ArgumentList $argumentLine -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { [IO.File]::ReadAllText($stdoutPath) } else { '' }
            $stderr = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath) } else { '' }
            $output = ($stdout + [Environment]::NewLine + $stderr).Trim()
            $exitCode = $process.ExitCode
        } finally {
            if (Test-Path -LiteralPath $stdoutPath) { Remove-Item -LiteralPath $stdoutPath -Force }
            if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force }
        }
        if ($exitCode -ne 0) { throw "Scenario $Id failed with exit code $exitCode.`n$output" }
        return $output
    }

    $expectations = @{
        1 = @{ Route = 'impeccable'; Mcp = 'none' }
        2 = @{ Route = 'shadcn'; Mcp = 'shadcn-optional' }
        3 = @{ Route = '21st'; Mcp = '21st' }
        4 = @{ Route = 'img2threejs'; Mcp = 'none' }
        5 = @{ Route = 'impeccable'; Mcp = 'none' }
        6 = @{ Route = 'impeccable'; Mcp = 'none' }
        7 = @{ Route = 'none'; Mcp = 'none'; Gate = $true }
        8 = @{ Route = 'none'; Mcp = 'none'; Gate = $true }
        9 = @{ Route = 'shadcn'; Mcp = 'shadcn-optional' }
        10 = @{ Route = 'img2threejs,shadcn'; Mcp = 'shadcn-optional' }
    }

    foreach ($scenario in @($matrix.scenarios | Where-Object { $_.id -in $ScenarioId } | Sort-Object id)) {
        if ($scenario.id -eq 10) {
            Add-Type -AssemblyName System.Drawing
            $imagePath = Join-Path $fixture 'SYNTHETIC_REFERENCE.png'
            if (Test-Path -LiteralPath $imagePath) { throw 'Scenario 10 synthetic image already exists before setup.' }
            $bitmap = [Drawing.Bitmap]::new(256,256)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.Clear([Drawing.Color]::FromArgb(245,247,250))
                $graphics.FillEllipse([Drawing.Brushes]::LightGray,48,36,160,160)
                $graphics.FillRectangle([Drawing.Brushes]::SteelBlue,82,78,92,96)
                $graphics.FillPolygon([Drawing.Brushes]::CornflowerBlue,[Drawing.Point[]]@([Drawing.Point]::new(82,78),[Drawing.Point]::new(128,48),[Drawing.Point]::new(174,78),[Drawing.Point]::new(128,108)))
                $graphics.DrawRectangle([Drawing.Pens]::MidnightBlue,82,78,92,96)
                $bitmap.Save($imagePath,[Drawing.Imaging.ImageFormat]::Png)
            } finally {
                $graphics.Dispose()
                $bitmap.Dispose()
            }
        }
        $fixtureGitBefore = (& git -C $fixture status --porcelain=v1 --untracked-files=all | Out-String)
        $output = Invoke-RoutingScenario -Id $scenario.id -Prompt $scenario.prompt
        $expected = $expectations[[int]$scenario.id]
        $route = Get-RouteMarker $output
        if ($route -ne $expected.Route) { throw "Scenario $($scenario.id) route mismatch: expected $($expected.Route), found $route.`n$output" }
        if ($expected.Mcp -eq 'shadcn') {
            if ($output -notmatch 'mcp: shadcn/search_items_in_registries \(completed\)') { throw "Scenario $($scenario.id) did not complete Shadcn search.`n$output" }
        } elseif ($expected.Mcp -eq 'shadcn-optional') {
            if ($output -match '(?m)^mcp:\s+(?!shadcn/search_items_in_registries\b)') { throw "Scenario $($scenario.id) called an MCP outside optional Shadcn search.`n$output" }
        } elseif ($expected.Mcp -eq '21st') {
            if ($output -notmatch 'mcp: 21st/search \(completed\)') { throw "Scenario $($scenario.id) did not complete 21st search.`n$output" }
        } else { Assert-NoMcpCall $output }
        if ($output -match '(?m)^mcp:\s+21st/(?!search\b)') { throw "Scenario $($scenario.id) attempted a forbidden 21st operation.`n$output" }
        $gateRequired = $expected.ContainsKey('Gate') -and [bool]$expected.Gate
        if ($gateRequired -and $output -notmatch '(?m)^FTK_GATE:\s*authorization-required\s*$') { throw "Scenario $($scenario.id) did not stop at authorization gate.`n$output" }
        $results += [pscustomobject]@{ Id = [int]$scenario.id; Route = $route; Gate = $gateRequired }
    }

    $fixtureGitAfter = (& git -C $fixture status --porcelain=v1 --untracked-files=all | Out-String)
    if ($fixtureGitBefore -ne $fixtureGitAfter) {
        if ($ScenarioId -notcontains 10) { throw 'Routing scenarios mutated the synthetic fixture.' }
        $beforeLines = @($fixtureGitBefore -split "`r?`n" | Where-Object { $_ })
        $afterLines = @($fixtureGitAfter -split "`r?`n" | Where-Object { $_ })
        $addedLines = @(Compare-Object $beforeLines $afterLines | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)
        if (-not $addedLines.Count -or @($addedLines | Where-Object { $_ -notmatch '^\?\? \.img2threejs/' }).Count) {
            throw "Scenario 10 wrote outside .img2threejs/.`n$fixtureGitAfter"
        }
        if (-not (Get-ChildItem -LiteralPath (Join-Path $fixture '.img2threejs') -File -Recurse -ErrorAction SilentlyContinue)) {
            throw 'Scenario 10 selected img2threejs without creating confined state or evidence.'
        }
        $fixtureArtifactsCreated = $true
    }
} finally {
    $env:PATH = $processPathBefore
    $env:FTK_PYTHON_PATH = $pythonPathBefore
    $env:NODE_OPTIONS = $nodeOptionsBefore
    $env:FTK_NPX_CLI_PATH = $npxPathBefore
    if (Test-Path -LiteralPath $profilePath) {
        if ((Get-FileHashOrAbsent $profilePath) -ne $profileHash) { throw 'Routing profile changed concurrently; refusing teardown.' }
        Remove-Item -LiteralPath $profilePath -Force
    }
    if (Test-Path -LiteralPath $fixture) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixture)
        if (-not $resolvedFixture.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture teardown path.' }
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction Stop; break }
            catch { if ($attempt -eq 20) { throw }; Start-Sleep -Milliseconds 250 }
        }
        if (Test-Path -LiteralPath $resolvedFixture) { throw 'Synthetic fixture teardown was incomplete.' }
        $fixtureRemoved = $true
    }
    foreach ($checkout in @('external/impeccable','external/img2threejs')) {
        $externalGitAfter = (& git -C (Join-Path $repoRoot $checkout) status --porcelain=v1 --untracked-files=all | Out-String)
        if ($externalGitAfter -ne $externalGitBefore[$checkout]) { throw "External checkout changed during routing: $checkout" }
    }
}

if ((Get-FileHashOrAbsent $configPath) -ne $configHashBefore) { throw 'Codex user config changed during FTK-04B.' }
if ([Environment]::GetEnvironmentVariable('Path','User') -ne $userPathBefore) { throw 'Persistent user PATH changed during FTK-04B.' }
if ([Environment]::GetEnvironmentVariable('Path','Machine') -ne $machinePathBefore) { throw 'Persistent machine PATH changed during FTK-04B.' }

[pscustomobject]@{
    Mode = 'executed'
    ScenariosPassed = @($results).Count
    Results = $results
    CodexVersion = '0.150.1'
    TwentyFirstTools = @('search')
    PaidOrMutableCalls = 0
    FixtureMutation = if ($fixtureArtifactsCreated) { 'ephemeral-only-cleaned' } else { 'none' }
    FixtureTeardown = if ($fixtureRemoved) { 'complete' } else { 'not-created' }
    PersistentMutation = 'none'
}
