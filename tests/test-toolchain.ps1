param(
    [string]$NodePath = (Join-Path $env:LOCALAPPDATA 'Programs\FrontendToolkit\node-v24.20.0-win-x64\node.exe'),
    [string]$PythonPath = (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json

foreach ($path in @($NodePath, $PythonPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Runtime not found: $path"
    }
}

$nodeVersion = (& $NodePath --version).TrimStart('v')
$pythonVersion = (& $PythonPath -c 'import platform; print(platform.python_version())').Trim()
if ($nodeVersion -ne '24.20.0') { throw "Expected Node 24.20.0, found $nodeVersion" }
if ($pythonVersion -ne '3.14.7') { throw "Expected Python 3.14.7, found $pythonVersion" }

$expected = @{
    node = $nodeVersion
    python = $pythonVersion
}
foreach ($runtime in $toolchain.runtimes) {
    if ($runtime.observedVersion -ne $expected[$runtime.id]) {
        throw "Lock mismatch for $($runtime.id)."
    }
}

& (Join-Path $PSScriptRoot 'test-skill-integration.ps1')

foreach ($checkout in @('external/impeccable', 'external/img2threejs')) {
    $dirty = & git -C (Join-Path $repoRoot $checkout) status --porcelain
    if ($dirty) { throw "External checkout is dirty: $checkout" }
}
if (Test-Path -LiteralPath (Join-Path $repoRoot '.codex/hooks.json')) { throw 'Hook unexpectedly active.' }
if (Test-Path -LiteralPath (Join-Path $repoRoot '.codex/config.toml')) { throw 'Project MCP/config unexpectedly present.' }

Write-Output "PASS: Node $nodeVersion and Python $pythonVersion match the toolchain lock."
Write-Output 'PASS: external checkouts are clean; hooks and project MCP config are absent.'
