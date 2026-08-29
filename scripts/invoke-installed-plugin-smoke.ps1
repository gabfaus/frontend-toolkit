param(
    [string]$CodexHome,
    [string]$Workspace,
    [string]$CodexPath,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json
if (-not $CodexPath) { $CodexPath = [Environment]::ExpandEnvironmentVariables(($toolchain.runtimes | Where-Object id -eq 'codex-cli').portableResolution) }
if (((& $CodexPath --version).Trim() -replace '^codex-cli\s+', '') -ne '0.150.1') { throw 'Unexpected Codex CLI version.' }

$prompts = [ordered]@{
    orchestrator = 'Qual componente oficial você recomenda para abrir um formulário em um modal? Não indiquei uma ferramenta explicitamente.'
    shadcn = 'Na fixture sintética, confirme com uma consulta read-only ao registry oficial qual componente serve para abrir um formulário em um modal.'
    twentyFirst = 'Procure inspiração para componentes de dashboard moderno. Não indiquei uma ferramenta explicitamente.'
    img2threejs = 'Quero transformar esta imagem em um asset para usar com Three.js.'
    costGate = 'Use o 21st AI para gerar três variantes.'
}
if ($ValidateOnly) {
    Write-Output 'PASS: installed-plugin smoke contract covers orchestrator, Shadcn, 21st/search, img2threejs and cost gate.'
    return
}

if (-not $CodexHome -or -not $Workspace) { throw 'CodexHome and Workspace are required outside ValidateOnly.' }
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$codexHomePath = [IO.Path]::GetFullPath($CodexHome)
$workspacePath = [IO.Path]::GetFullPath($Workspace)
foreach ($path in @($codexHomePath, $workspacePath)) {
    if (-not $path.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Path must stay under TEMP: $path" }
}
if (-not (Test-Path -LiteralPath (Join-Path $codexHomePath 'auth.json'))) { throw 'Official isolated authentication is required. Do not copy auth.json.' }

$oldCodexHome = $env:CODEX_HOME
$oldPath = $env:PATH
$nodeDirectory = [Environment]::ExpandEnvironmentVariables(($toolchain.runtimes | Where-Object id -eq 'node').portableResolution)
$nodeDirectory = Split-Path $nodeDirectory
$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configBefore = if (Test-Path -LiteralPath $configPath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash } else { '<absent>' }
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')

function Invoke-Smoke {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Prompt, [string]$Image)
    $stdout = Join-Path $temporaryRoot ("ftk05c-$Name-" + [guid]::NewGuid().ToString('N') + '.stdout')
    $stderr = Join-Path $temporaryRoot ("ftk05c-$Name-" + [guid]::NewGuid().ToString('N') + '.stderr')
    $arguments = @('exec', '--strict-config', '--ephemeral', '--approve-for-me', '--skip-git-repo-check', '--cd', $workspacePath, $Prompt)
    if ($Image) { $arguments += @('--image', $Image) }
    $argumentLine = (($arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' ')
    try {
        $process = Start-Process -FilePath $CodexPath -ArgumentList $argumentLine -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $output = [IO.File]::ReadAllText($stdout) + [Environment]::NewLine + [IO.File]::ReadAllText($stderr)
        if ($process.ExitCode -ne 0) { throw "$Name exited with $($process.ExitCode)." }
        return $output
    } finally {
        if (Test-Path -LiteralPath $stdout) { Remove-Item -LiteralPath $stdout -Force }
        if (Test-Path -LiteralPath $stderr) { Remove-Item -LiteralPath $stderr -Force }
    }
}

try {
    $env:CODEX_HOME = $codexHomePath
    $env:PATH = "$nodeDirectory;$oldPath"
    & $CodexPath login status | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Isolated ChatGPT authentication is unavailable.' }

    $pluginList = & $CodexPath plugin list --json | ConvertFrom-Json
    $installed = @($pluginList.installed | Where-Object name -eq 'frontend-toolkit')
    if ($installed.Count -ne 1) { throw 'Frontend Toolkit is not installed exactly once.' }

    $one = Invoke-Smoke -Name 'orchestrator' -Prompt ($prompts.orchestrator + ' Use o Frontend Toolkit instalado, não altere arquivos e escreva FTK_SKILL: frontend-orchestrator e FTK_ROUTE: shadcn.')
    if ($one -notmatch '(?m)^FTK_SKILL:\s*frontend-orchestrator\s*[.]?\s*$' -or $one -notmatch '(?m)^FTK_ROUTE:\s*shadcn\s*[.]?\s*$' -or $one -match '(?m)^mcp:\s+21st/') { throw 'Orchestrator smoke failed.' }

    $two = Invoke-Smoke -Name 'shadcn' -Prompt ($prompts.shadcn + ' Use o Frontend Toolkit instalado, não altere arquivos e escreva FTK_ROUTE: shadcn.')
    if ($two -notmatch 'mcp:\s*shadcn/search_items_in_registries\s*\(completed\)' -or $two -match '(?m)^mcp:\s+21st/') { throw 'Shadcn smoke failed.' }

    $credentialAvailable = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('API_KEY_21ST', 'Process'))
    if ($credentialAvailable) {
        $three = Invoke-Smoke -Name '21st' -Prompt ($prompts.twentyFirst + ' Use o Frontend Toolkit instalado, não use web search, não copie nem instale código, não altere arquivos e escreva FTK_ROUTE: 21st.')
        if ($three -notmatch 'mcp:\s*21st/search\s*\(completed\)' -or $three -match '(?m)^mcp:\s*21st/(?!search\b)') { throw '21st search-only smoke failed.' }
    }

    Add-Type -AssemblyName System.Drawing
    $imagePath = Join-Path $workspacePath 'synthetic.png'
    $bitmap = [Drawing.Bitmap]::new(64, 64)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.Clear([Drawing.Color]::White); $graphics.FillRectangle([Drawing.Brushes]::SteelBlue, 12, 12, 40, 40); $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png) } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $before = (& git -C $workspacePath status --porcelain=v1 --untracked-files=all | Out-String)
    $four = Invoke-Smoke -Name 'img2threejs' -Image $imagePath -Prompt ($prompts.img2threejs + ' Use o Frontend Toolkit instalado; crie apenas .img2threejs/SMOKE.md, não execute a pipeline longa e escreva FTK_ROUTE: img2threejs.')
    if ($four -notmatch '(?m)^FTK_ROUTE:\s*img2threejs\s*[.]?\s*$' -or $four -match '(?m)^mcp:\s+') { throw 'img2threejs smoke failed.' }
    $after = (& git -C $workspacePath status --porcelain=v1 --untracked-files=all | Out-String)
    $added = @(Compare-Object @($before -split "`r?`n" | Where-Object { $_ }) @($after -split "`r?`n" | Where-Object { $_ }) | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)
    if (-not $added.Count -or @($added | Where-Object { $_ -notmatch '^\?\? \.img2threejs/' }).Count) { throw 'img2threejs wrote outside its confined state directory.' }

    $five = Invoke-Smoke -Name 'cost-gate' -Prompt ($prompts.costGate + ' Não concedo autorização para custo, quota, geração ou mutação. Não chame MCP e escreva FTK_ROUTE: 21st e FTK_GATE: authorization-required.')
    if ($five -notmatch '(?m)^FTK_GATE:\s*authorization-required\s*[.]?\s*$' -or $five -match '(?m)^mcp:\s+') { throw '21st cost gate failed.' }

    [pscustomobject]@{ Orchestrator = 'pass'; Shadcn = 'read-only-pass'; TwentyFirst = if ($credentialAvailable) { 'search-only-pass' } else { 'credential-gated' }; Img2threejs = 'confined-pass'; CostGate = 'pass'; PaidOrMutable21stCalls = 0 }
} finally {
    $env:CODEX_HOME = $oldCodexHome
    $env:PATH = $oldPath
}

$configAfter = if (Test-Path -LiteralPath $configPath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash } else { '<absent>' }
if ($configBefore -ne $configAfter) { throw 'Primary Codex config changed.' }
if ($userPathBefore -ne [Environment]::GetEnvironmentVariable('Path', 'User')) { throw 'User PATH changed.' }
if ($machinePathBefore -ne [Environment]::GetEnvironmentVariable('Path', 'Machine')) { throw 'Machine PATH changed.' }
