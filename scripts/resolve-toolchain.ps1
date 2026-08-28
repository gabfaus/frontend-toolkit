param(
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-PortablePath {
    param([Parameter(Mandatory)][string]$Value)

    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    return $expanded.Replace('/', [IO.Path]::DirectorySeparatorChar)
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lockPath = Join-Path $repoRoot 'integrations/toolchain.lock.json'
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Toolchain lock not found: $lockPath"
}

$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
$runtimeById = @{}
foreach ($runtime in $lock.runtimes) {
    if ($runtimeById.ContainsKey($runtime.id)) {
        throw "Duplicate runtime in toolchain lock: $($runtime.id)"
    }
    $runtimeById[$runtime.id] = $runtime
}
foreach ($requiredId in @('node', 'python')) {
    if (-not $runtimeById.ContainsKey($requiredId)) {
        throw "Required runtime missing from toolchain lock: $requiredId"
    }
}

$nodePath = Expand-PortablePath $runtimeById.node.portableResolution
$pythonPath = Expand-PortablePath $runtimeById.python.portableResolution
foreach ($runtimePath in @($nodePath, $pythonPath)) {
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw "Pinned runtime executable not found: $runtimePath"
    }
}

$nodeVersion = (& $nodePath --version).Trim().TrimStart('v')
$pythonVersion = (& $pythonPath -c 'import platform; print(platform.python_version())').Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Python runtime failed validation: $pythonPath"
}
if ($nodeVersion -ne $runtimeById.node.targetVersion) {
    throw "Node version mismatch: expected $($runtimeById.node.targetVersion), found $nodeVersion at $nodePath"
}
if ($pythonVersion -ne $runtimeById.python.targetVersion) {
    throw "Python version mismatch: expected $($runtimeById.python.targetVersion), found $pythonVersion at $pythonPath"
}
if ($runtimeById.node.observedVersion -ne $nodeVersion -or $runtimeById.python.observedVersion -ne $pythonVersion) {
    throw 'Observed runtime versions no longer match integrations/toolchain.lock.json.'
}

$result = [pscustomobject]@{
    NodePath = $nodePath
    NodeDirectory = Split-Path -Parent $nodePath
    NodeVersion = $nodeVersion
    PythonPath = $pythonPath
    PythonVersion = $pythonVersion
    Architecture = $lock.architecture
    LockPath = $lockPath
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 3
} else {
    $result
}
