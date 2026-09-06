param(
    [Parameter(Mandatory)][ValidateSet('open','goto','snapshot','screenshot','find','click','dblclick','fill','type','press','hover','select','check','uncheck','reload','go-back','go-forward','resize','tab-list','tab-new','tab-close','tab-select','dialog-accept','dialog-dismiss','console','requests','tracing-start','tracing-stop','recording-start','recording-stop','generate-locator','close')][string]$Action,
    [string]$Url,
    [ValidatePattern('^e\d+$')][string]$Ref,
    [AllowEmptyString()][string]$Text,
    [ValidateSet('debug','info','warning','error')][string]$Level,
    [ValidateSet('chromium','firefox','webkit','msedge')][string]$Browser = 'chromium',
    [ValidateRange(1, 10000)][int]$Width,
    [ValidateRange(1, 10000)][int]$Height,
    [ValidateRange(0, 100000)][int]$Index,
    [ValidatePattern('^[^\\/:*?"<>|.][^\\/:*?"<>|]*$')][string]$OutputName,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$')][string]$SessionId,
    [string]$CliPath,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$policyPath = Join-Path $PSScriptRoot 'playwright-runtime-policy.json'
$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json

function Assert-LoopbackUrl {
    param([Parameter(Mandatory)][string]$Value)
    try { $parsed = [Uri]$Value } catch { throw 'URL must be an absolute HTTP loopback URL.' }
    if ($parsed.Scheme -cne 'http' -or $parsed.Host -notin @('localhost','127.0.0.1','[::1]')) {
        throw 'Only HTTP loopback origins are allowed by the Playwright boundary.'
    }
    if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) { throw 'Credentials in a URL are denied.' }
    return $parsed.AbsoluteUri
}

function Assert-SessionRoot {
    param([Parameter(Mandatory)][string]$Value)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $root = [IO.Path]::GetFullPath((Join-Path $temp ('ftk-playwright/' + $Value)))
    if (-not $root.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Session root escaped the OS temp directory.' }
    if (Test-Path -LiteralPath $root) {
        $item = Get-Item -LiteralPath $root -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Session root cannot be a reparse point.' }
    }
    return $root
}

function ConvertTo-WindowsNativeArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)
    if ($Value -match '[\x00\r\n]') { throw 'Native argv values may not contain NUL or line breaks.' }
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

function Resolve-PlaywrightCli {
    param([string]$ExplicitPath)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [IO.Path]::GetFullPath($ExplicitPath)
        if ([IO.Path]::GetFileName($resolved) -notmatch '^playwright-cli(\.cmd|\.exe)?$') { throw 'CliPath must name the pinned playwright-cli command.' }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'The pinned playwright-cli executable is unavailable.' }
        return $resolved
    }
    $command = Get-Command 'playwright-cli' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace($command.Source)) { throw 'The pinned playwright-cli command is unavailable; automatic package installation is disabled.' }
    if ([IO.Path]::GetFileName($command.Source) -notmatch '^playwright-cli(\.cmd|\.exe)?$') { throw 'Resolved command is not the pinned playwright-cli executable.' }
    return [IO.Path]::GetFullPath($command.Source)
}

function Add-ValueArgument {
    param([Collections.Generic.List[string]]$Arguments, [string]$Name, [string]$Value)
    if (-not [string]::IsNullOrEmpty($Value)) { [void]$Arguments.Add($Name); [void]$Arguments.Add($Value) }
}

function New-PlaywrightArguments {
    $arguments = [Collections.Generic.List[string]]::new()
    [void]$arguments.Add($Action)
    switch ($Action) {
        'open' { if ($Url) { [void]$arguments.Add((Assert-LoopbackUrl $Url)) } }
        'goto' { [void]$arguments.Add((Assert-LoopbackUrl $Url)) }
        'tab-new' { [void]$arguments.Add((Assert-LoopbackUrl $Url)) }
        'snapshot' { Add-ValueArgument $arguments '--filename' $OutputName }
        'screenshot' { Add-ValueArgument $arguments '--filename' $OutputName }
        'find' { [void]$arguments.Add($Text) }
        { $_ -in @('click','dblclick','hover','check','uncheck','generate-locator') } { [void]$arguments.Add($Ref) }
        'fill' { [void]$arguments.Add($Ref); [void]$arguments.Add($Text) }
        'type' { [void]$arguments.Add($Text) }
        'press' { [void]$arguments.Add($Text) }
        'select' { [void]$arguments.Add($Ref); [void]$arguments.Add($Text) }
        'resize' { [void]$arguments.Add([string]$Width); [void]$arguments.Add([string]$Height) }
        'tab-close' { if ($PSBoundParameters.ContainsKey('Index')) { [void]$arguments.Add([string]$Index) } }
        'tab-select' { [void]$arguments.Add([string]$Index) }
        'dialog-accept' { Add-ValueArgument $arguments '--text' $Text }
        'console' { if ($Level) { [void]$arguments.Add($Level) } }
        'tracing-stop' { Add-ValueArgument $arguments '--filename' $OutputName }
        'recording-start' { Add-ValueArgument $arguments '--filename' $OutputName }
    }
    if ($Action -eq 'open' -and $Browser -ne 'chromium') { [void]$arguments.Add(('--browser=' + $Browser)) }
    return $arguments.ToArray()
}

function Assert-ActionInputs {
    if ($Action -in @('goto','tab-new') -and [string]::IsNullOrWhiteSpace($Url)) { throw "$Action requires Url." }
    if ($Action -in @('click','dblclick','hover','check','uncheck','generate-locator','fill','select') -and [string]::IsNullOrWhiteSpace($Ref)) { throw "$Action requires a snapshot Ref." }
    if ($Action -in @('find','fill','type','press','select') -and -not $PSBoundParameters.ContainsKey('Text')) { throw "$Action requires Text." }
    if ($Action -eq 'resize' -and (-not $PSBoundParameters.ContainsKey('Width') -or -not $PSBoundParameters.ContainsKey('Height'))) { throw 'resize requires Width and Height.' }
    if ($Action -eq 'tab-select' -and -not $PSBoundParameters.ContainsKey('Index')) { throw 'tab-select requires Index.' }
    if ($Action -notin @('open','goto','tab-new') -and $Url) { throw "$Action does not accept Url." }
    if ($Action -notin @('click','dblclick','hover','check','uncheck','generate-locator','fill','select') -and $Ref) { throw "$Action does not accept Ref." }
    if ($Action -notin @('snapshot','screenshot','tracing-stop','recording-start') -and $OutputName) { throw "$Action does not accept OutputName." }
}

Assert-ActionInputs
$session = if ($SessionId) { $SessionId } else { [guid]::NewGuid().ToString('N') }
$sessionRoot = Assert-SessionRoot $session
$argv = @(New-PlaywrightArguments)
$resolvedCli = if ($PlanOnly) { if ($CliPath) { [IO.Path]::GetFullPath($CliPath) } else { 'playwright-cli (resolution deferred)' } } else { Resolve-PlaywrightCli $CliPath }
$reportedArgv = @($argv | ForEach-Object {
    if ($_ -eq $Text -and $PSBoundParameters.ContainsKey('Text')) { '<redacted-input>' }
    elseif ($_ -match '^https?://') { try { ([Uri]$_).GetLeftPart([UriPartial]::Path) } catch { '<redacted-url>' } }
    else { $_ }
})
$plan = [ordered]@{
    schemaVersion = 1
    operation = 'browser-qa.playwright'
    action = $Action
    cli = '@playwright/cli@0.1.19'
    executable = $resolvedCli
    argv = $reportedArgv
    workingDirectory = $sessionRoot
    environmentNames = @($policy.environmentAllowlist)
    effects = @('BROWSER_EPHEMERAL','TEMP_OUTPUT','LOOPBACK_ONLY')
    arbitraryJavaScript = $false
    persistentState = $false
    browserDownloads = 0
    packageInstallation = $false
    executed = $false
}
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 8
    return
}

[IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
$environment = [ordered]@{}
foreach ($name in @('SystemRoot','ComSpec')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
}
$environment['TEMP'] = $sessionRoot
$environment['TMP'] = $sessionRoot
foreach ($property in $policy.environmentValues.PSObject.Properties) { $environment[$property.Name] = [string]$property.Value }
$startInfo = New-Object Diagnostics.ProcessStartInfo
$startInfo.FileName = $resolvedCli
$startInfo.WorkingDirectory = $sessionRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.Arguments = (@($argv | ForEach-Object { ConvertTo-WindowsNativeArgument ([string]$_) }) -join ' ')
$startInfo.EnvironmentVariables.Clear()
foreach ($key in $environment.Keys) { $startInfo.EnvironmentVariables.Add([string]$key, [string]$environment[$key]) }
$process = New-Object Diagnostics.Process
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) { throw 'The pinned playwright-cli process did not start.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
} finally {
    $process.Dispose()
}
if ($exitCode -ne 0) { throw "Playwright CLI failed with exit code $exitCode." }
$plan.executed = $true
$plan.exitCode = $exitCode
$plan.stdout = @($stdout -split '\r?\n' | Where-Object { $_.Length -gt 0 })
$plan.stderr = @($stderr -split '\r?\n' | Where-Object { $_.Length -gt 0 })
if ($Action -eq 'close' -and (Test-Path -LiteralPath $sessionRoot)) {
    $item = Get-Item -LiteralPath $sessionRoot -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Session root became a reparse point before cleanup.' }
    [IO.Directory]::Delete($sessionRoot, $true)
}
$plan | ConvertTo-Json -Depth 8
