param(
    [Parameter(Mandatory)]
    [string]$CandidateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][hashtable]$Environment
    )

    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables.Clear()
    foreach ($name in $Environment.Keys) {
        $start.EnvironmentVariables[$name] = [string]$Environment[$name]
    }
    $start.Arguments = (@($Arguments | ForEach-Object {
        ConvertTo-TestWindowsNativeArgument -Value ([string]$_)
    }) -join ' ')

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start $FileName." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

function Add-IfPresent {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrEmpty($value)) { $Environment[$Name] = $value }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$candidatePath = (Resolve-Path -LiteralPath $CandidateRoot).Path
$toolchain = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json
$nodeRuntime = @($toolchain.runtimes | Where-Object id -eq 'node')
if ($nodeRuntime.Count -ne 1) { throw 'Node runtime lock entry is missing or ambiguous.' }
if ($nodeRuntime[0].targetVersion -ne '24.20.0' -or $nodeRuntime[0].observedVersion -ne '24.20.0') {
    throw 'The hermetic facade test requires locked Node 24.20.0.'
}
$nodePath = [Environment]::ExpandEnvironmentVariables($nodeRuntime[0].portableResolution.Replace('/', '\'))
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) { throw 'Governed Node executable is missing.' }

$facadePath = Join-Path $candidatePath 'security/claude/21st-facade.mjs'
$launcherPath = Join-Path $candidatePath 'security/claude/launch-21st-facade.ps1'
$preloadPath = Join-Path $repoRoot 'tests/fixtures/21st-fetch-preload.mjs'
$testPath = Join-Path $repoRoot 'tests/test-21st-facade.mjs'
foreach ($path in @($facadePath, $launcherPath, $preloadPath, $testPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required hermetic test file is missing: $path" }
}

$baseEnvironment = @{}
foreach ($name in @('SystemRoot', 'LOCALAPPDATA', 'TEMP', 'TMP', 'PATH', 'ComSpec', 'PATHEXT')) {
    Add-IfPresent -Environment $baseEnvironment -Name $name
}
$nodeResult = Invoke-CapturedProcess -FileName $nodePath -Arguments @(
    $testPath, $nodePath, $facadePath, $preloadPath
) -Environment $baseEnvironment
if ($nodeResult.ExitCode -ne 0) {
    throw ("Hermetic facade tests failed. STDOUT: {0} STDERR: {1}" -f $nodeResult.Stdout, $nodeResult.Stderr)
}
if ($nodeResult.Stdout -notmatch 'PASS: local MCP tools/list exposes exactly search') {
    throw 'Hermetic facade test output is incomplete.'
}
if ($nodeResult.Stdout.Contains('mh03b-synthetic-key') -or $nodeResult.Stderr.Contains('mh03b-synthetic-key')) {
    throw 'Synthetic credential leaked from the hermetic facade test process.'
}

$launcherResult = Invoke-CapturedProcess -FileName (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $launcherPath, '-ValidateOnly'
) -Environment $baseEnvironment
if ($launcherResult.ExitCode -ne 0) {
    throw ("Facade launcher validation failed. STDOUT: {0} STDERR: {1}" -f $launcherResult.Stdout, $launcherResult.Stderr)
}
if ($launcherResult.Stdout.Trim().Length -ne 0) { throw 'Facade launcher validation polluted stdout.' }
$launcherValidation = $launcherResult.Stderr | ConvertFrom-Json
if ($launcherValidation.runtime -ne 'locked-node' -or $launcherValidation.nodeVersion -ne '24.20.0') {
    throw 'Facade launcher did not validate the locked Node runtime.'
}
if (@($launcherValidation.environmentNames) -contains 'API_KEY_21ST') {
    throw 'Facade launcher validation reported an inherited API key.'
}

Write-Output 'PASS: hermetic MCP stdio/client, mock HTTP and fail-closed facade cases passed.'
Write-Output 'PASS: facade launcher validated locked Node and minimal child environment.'
Write-Output 'MCP RUNTIME NETWORK CALLS=0; DEPENDENCY RESOLUTION NETWORK=not used by this runner; SECRETS READ=0'
