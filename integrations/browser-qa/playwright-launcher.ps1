[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('open','goto','snapshot','screenshot','find','click','dblclick','fill','type','press','hover','select','check','uncheck','reload','go-back','go-forward','resize','tab-list','tab-new','tab-close','tab-select','dialog-accept','dialog-dismiss','console','requests','tracing-start','tracing-stop','recording-start','recording-stop','generate-locator','close')][string]$Action,
    [string]$Url,
    [ValidatePattern('^e\d+$')][string]$Ref,
    [AllowEmptyString()][string]$Text,
    [ValidateSet('debug','info','warning','error')][string]$Level,
    [ValidateSet('chromium','firefox','webkit','msedge')][string]$Browser = 'chromium',
    [ValidateRange(320, 3840)][int]$Width,
    [ValidateRange(240, 2160)][int]$Height,
    [ValidateRange(0, 100000)][int]$Index,
    [string]$OutputName,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$')][string]$SessionId,
    [string]$CliPath,
    [ValidateRange(1000, 600000)][int]$TimeoutMilliseconds = 120000,
    [switch]$PlanOnly,
    [switch]$TestOnlySyntheticCli
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'browser-qa-process.ps1')

$session = if ([string]::IsNullOrWhiteSpace($SessionId)) { [guid]::NewGuid().ToString('N') } else { $SessionId }
$sessionRoot = Assert-BrowserQaTempSessionRoot -SessionId $session
$script:hasText = $PSBoundParameters.ContainsKey('Text')
$script:hasWidth = $PSBoundParameters.ContainsKey('Width')
$script:hasHeight = $PSBoundParameters.ContainsKey('Height')
$script:hasIndex = $PSBoundParameters.ContainsKey('Index')
$script:normalizedUrl = ''
$script:normalizedOutputName = ''

function Assert-BrowserQaLoopbackUrl {
    param([Parameter(Mandatory)][string]$Value)
    try { $parsed = [Uri]$Value } catch { throw 'URL must be an absolute HTTP loopback URL.' }
    $hostName = $parsed.DnsSafeHost.Trim('[', ']').ToLowerInvariant()
    $isIpv6Loopback = $false
    try { $isIpv6Loopback = ([Net.IPAddress]::Parse($hostName)).Equals([Net.IPAddress]::IPv6Loopback) } catch { }
    if ($parsed.Scheme -cne 'http' -or ($hostName -notin @('localhost', '127.0.0.1') -and -not $isIpv6Loopback)) {
        throw 'Only HTTP loopback origins are allowed by the Playwright boundary.'
    }
    if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) { throw 'Credentials in a URL are denied.' }
    return $parsed.AbsoluteUri
}

function Assert-BrowserQaLauncherOutputName {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$ActionName)
    if ($Value -eq '.' -or $Value -eq '..' -or $Value.StartsWith('.') -or $Value -match '[\\/:*?"<>|]' -or
        $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'OutputName must be a safe basename.' }
    $stem = $Value.Split('.')[0].ToUpperInvariant()
    if ($stem -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'OutputName uses a reserved Windows device name.' }
    if ($ActionName -eq 'screenshot' -and $Value -notmatch '(?i)\.png$') { throw 'Screenshot OutputName must use the .png extension.' }
    return $Value
}

function Assert-BrowserQaSessionLease {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Session)
    $leasePath = Join-Path $Root 'session-lease.json'
    Assert-BrowserQaPathContained -Root $Root -Candidate $leasePath -Label 'Browser QA session lease' -MustExist | Out-Null
    if (Test-BrowserQaReparsePoint -Path $leasePath) { throw 'Browser QA session lease is a reparse point.' }
    try { $lease = Get-Content -Raw -LiteralPath $leasePath | ConvertFrom-Json } catch { throw 'Browser QA session lease is malformed.' }
    if ($lease.schemaVersion -ne 1 -or $lease.owner -cne 'ftk-playwright-launcher' -or $lease.sessionId -cne $Session) { throw 'Browser QA session lease owner mismatch.' }
}

function Assert-BrowserQaLauncherInputs {
    if ($Action -in @('open', 'goto', 'tab-new') -and [string]::IsNullOrWhiteSpace($Url)) { throw "$Action requires Url." }
    if ($Action -in @('open', 'goto', 'tab-new')) { $script:normalizedUrl = Assert-BrowserQaLoopbackUrl -Value $Url }
    if ($Action -in @('click', 'dblclick', 'hover', 'check', 'uncheck', 'generate-locator', 'fill', 'select') -and [string]::IsNullOrWhiteSpace($Ref)) { throw "$Action requires a snapshot Ref." }
    if ($Action -in @('find', 'fill', 'type', 'press', 'select') -and -not $script:hasText) { throw "$Action requires Text." }
    if ($Action -eq 'press' -and $Text -notin @('Tab', 'Shift+Tab', 'Enter', 'Space', 'Escape')) { throw 'press accepts only Tab, Shift+Tab, Enter, Space or Escape.' }
    if ($Action -eq 'resize' -and (-not $script:hasWidth -or -not $script:hasHeight)) { throw 'resize requires Width and Height.' }
    if ($Action -eq 'resize' -and ($Width -lt 320 -or $Width -gt 3840 -or $Height -lt 240 -or $Height -gt 2160)) { throw 'resize viewport is outside the bounded contract.' }
    if ($Action -eq 'tab-select' -and -not $script:hasIndex) { throw 'tab-select requires Index.' }
    if ($Action -notin @('open', 'goto', 'tab-new') -and $Url) { throw "$Action does not accept Url." }
    if ($Action -notin @('click', 'dblclick', 'hover', 'check', 'uncheck', 'generate-locator', 'fill', 'select') -and $Ref) { throw "$Action does not accept Ref." }
    if ($Action -notin @('snapshot', 'screenshot', 'tracing-stop', 'recording-start') -and $OutputName) { throw "$Action does not accept OutputName." }
    if ($OutputName) { $script:normalizedOutputName = Assert-BrowserQaLauncherOutputName -Value $OutputName -ActionName $Action }
    if ($Action -ne 'open' -and $Browser -ne 'chromium') { throw 'Browser is accepted only by open.' }
    if ($Text -and $Text.Length -gt 4096) { throw 'Text exceeds the bounded input length.' }
}

function New-BrowserQaCliArguments {
    $arguments = New-Object Collections.Generic.List[string]
    [void]$arguments.Add(('-s=' + $session))
    [void]$arguments.Add($Action)
    switch ($Action) {
        'open' { [void]$arguments.Add($script:normalizedUrl); [void]$arguments.Add(('--browser=' + $Browser)); [void]$arguments.Add('--no-headed') }
        'goto' { [void]$arguments.Add($script:normalizedUrl) }
        'tab-new' { [void]$arguments.Add($script:normalizedUrl) }
        'snapshot' { if ($script:normalizedOutputName) { [void]$arguments.Add('--filename'); [void]$arguments.Add($script:normalizedOutputName) } }
        'screenshot' { [void]$arguments.Add('--filename'); [void]$arguments.Add($script:normalizedOutputName) }
        'find' { [void]$arguments.Add($Text) }
        { $_ -in @('click', 'dblclick', 'hover', 'check', 'uncheck', 'generate-locator') } { [void]$arguments.Add($Ref) }
        'fill' { [void]$arguments.Add($Ref); [void]$arguments.Add($Text) }
        'type' { [void]$arguments.Add($Text) }
        'press' { [void]$arguments.Add($Text) }
        'select' { [void]$arguments.Add($Ref); [void]$arguments.Add($Text) }
        'resize' { [void]$arguments.Add([string]$Width); [void]$arguments.Add([string]$Height) }
        'tab-close' { if ($script:hasIndex) { [void]$arguments.Add([string]$Index) } }
        'tab-select' { [void]$arguments.Add([string]$Index) }
        'dialog-accept' { if ($Text) { [void]$arguments.Add('--text'); [void]$arguments.Add($Text) } }
        'console' { if ($Level) { [void]$arguments.Add($Level) } }
        'tracing-stop' { if ($script:normalizedOutputName) { [void]$arguments.Add('--filename'); [void]$arguments.Add($script:normalizedOutputName) } }
        'recording-start' { if ($script:normalizedOutputName) { [void]$arguments.Add('--filename'); [void]$arguments.Add($script:normalizedOutputName) } }
    }
    return $arguments.ToArray()
}

Assert-BrowserQaLauncherInputs
$argv = @(New-BrowserQaCliArguments)
$plan = [ordered]@{
    schemaVersion = 1
    operation = 'browser-qa.playwright'
    action = $Action
    cli = '@playwright/cli@0.1.19'
    executable = if ($CliPath) { [IO.Path]::GetFullPath($CliPath) } else { 'playwright-cli (resolution deferred)' }
    argv = @($argv | ForEach-Object {
        if ($Text -and $_ -eq $Text) { '<redacted-input>' }
        elseif ($_ -match '^https?://') { try { ([Uri]$_).GetLeftPart([UriPartial]::Path) } catch { '<redacted-url>' } }
        else { $_ }
    })
    workingDirectory = $sessionRoot
    environmentNames = @('SystemRoot', 'ComSpec', 'TEMP', 'TMP', 'FTK_BROWSER_QA_HOST_TEMP', 'PLAYWRIGHT_BROWSERS_PATH', 'PWTEST_DAEMON_SESSION_DIR', 'PWTEST_SERVER_REGISTRY', 'PWTEST_CLI_GLOBAL_CONFIG', 'PLAYWRIGHT_MCP_SANDBOX', 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD', 'PLAYWRIGHT_HTML_OPEN', 'NO_COLOR', 'NO_UPDATE_NOTIFIER')
    effects = @('BROWSER_EPHEMERAL', 'TEMP_OUTPUT', 'LOOPBACK_ONLY')
    arbitraryJavaScript = $false
    persistentState = $false
    browserDownloads = 0
    packageInstallation = $false
    headless = $true
    headlessControl = 'explicit-cli-flag'
    headlessFlag = '--no-headed'
    executed = $false
}
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 10
    return
}

$rootCreated = $false
$rootOwnedByInvocation = $false
$rootRemoved = $false
$cleanupStatus = 'INCOMPLETE'
$identity = $null
$result = $null
try {
    $baseRoot = Split-Path -Parent $sessionRoot
    [IO.Directory]::CreateDirectory($baseRoot) | Out-Null
    if ($Action -eq 'open') {
        if (Test-Path -LiteralPath $sessionRoot) { throw 'The requested Browser QA session id is already in use.' }
        [IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
        $rootCreated = $true
        $rootOwnedByInvocation = $true
        $leasePath = Join-Path $sessionRoot 'session-lease.json'
        [IO.File]::WriteAllText($leasePath, ([ordered]@{ schemaVersion = 1; owner = 'ftk-playwright-launcher'; sessionId = $session; createdBy = 'open' } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    } else {
        if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) { throw 'The requested Browser QA session lease is not open.' }
        Assert-BrowserQaSessionLease -Root $sessionRoot -Session $session
        if ($Action -eq 'close') { $rootOwnedByInvocation = $true }
    }
    Assert-BrowserQaPathContained -Root $baseRoot -Candidate $sessionRoot -Label 'Browser QA session root' | Out-Null
    $identity = Get-BrowserQaCliIdentity -ExplicitPath $CliPath -AllowSyntheticTestDouble:$TestOnlySyntheticCli
    $environment = New-BrowserQaChildEnvironment -SessionRoot $sessionRoot
    $child = Invoke-BrowserQaChildProcess -Executable $identity.executable -ArgumentList $argv `
        -WorkingDirectory $sessionRoot -Environment $environment -TimeoutMilliseconds $TimeoutMilliseconds -Operation 'browser-qa.playwright'
    $outputContractValid = $true
    $artifact = $null
    if ($child.processSucceeded -and $Action -eq 'screenshot') {
        try {
            Assert-BrowserQaPathContained -Root $sessionRoot -Candidate (Join-Path $sessionRoot $script:normalizedOutputName) -Label 'screenshot artifact' -MustExist | Out-Null
            $artifactItem = Get-Item -LiteralPath (Join-Path $sessionRoot $script:normalizedOutputName) -Force
            if ($artifactItem.Length -le 0 -or $artifactItem.Length -gt 20MB -or $artifactItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Screenshot artifact is invalid.' }
            $artifact = [ordered]@{ kind = 'screenshot'; basename = $script:normalizedOutputName; sizeBytes = $artifactItem.Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactItem.FullName).Hash; existsAtCapture = $true }
        } catch {
            $outputContractValid = $false
        }
    }
    $providerFailure = if (-not $outputContractValid) { 'OUTPUT_CONTRACT_FAILURE' } elseif ($identity.synthetic -and $child.processSucceeded) { 'DEPENDENCY_OR_RUNTIME_FAILURE' } else { $child.failureType }
    $childFailureMessage = Get-FtkPropertyValue -InputObject $child.diagnostics -Name 'failureMessage'
    $childForContract = New-FtkChildProcessObservation -Capability 'playwright-cli' -Operation 'browser-qa.playwright' `
        -Materialized:$child.materialized -Attempted:$child.attempted -ChildStarted:$child.childStarted -ExitCode $child.exitCode `
        -FailureType $providerFailure -FailureMessage $childFailureMessage -TimedOut:$child.timedOut `
        -StdoutText '' -StderrText '' -CaptureComplete:$child.diagnostics.captureComplete `
        -StdoutOverflowed:$child.diagnostics.stdoutOverflowed -StderrOverflowed:$child.diagnostics.stderrOverflowed `
        -EnvironmentNames @($environment.Keys) -Cleanup $child.cleanup -CleanupMechanism $child.cleanupMechanism `
        -CleanupGuaranteed:$child.cleanupGuaranteed -TimeoutMilliseconds $TimeoutMilliseconds -ProcessId $child.processId
    $dedicated = Complete-FtkDedicatedExecution -Capability 'playwright-cli' -Operation 'browser-qa.playwright' `
        -ChildObservation $childForContract -OutputContractValid:$outputContractValid `
        -OutputContractDiagnostic 'Playwright CLI output or screenshot artifact did not satisfy the bounded contract.'
    $plan.executed = $child.processSucceeded
    $plan.exitCode = $child.exitCode
    $result = [ordered]@{
        schemaVersion = 1
        kind = 'browser-qa-action-result'
        operation = 'browser-qa.playwright'
        action = $Action
        executed = $child.processSucceeded
        exitCode = $child.exitCode
        stdout = @($child.stdout)
        stderr = @($child.stderr)
        workingDirectory = $sessionRoot
        browserDownloads = 0
        packageInstallation = $false
        arbitraryJavaScript = $false
        persistentState = $false
        headless = $true
        cliIdentity = $identity
        dedicatedExecution = $dedicated
        artifact = $artifact
        sessionLease = [ordered]@{ owner = 'ftk-playwright-launcher'; sessionId = $session; retained = ($child.processSucceeded -and $Action -ne 'close'); cleanupRequired = ($child.processSucceeded -and $Action -ne 'close') }
        cleanup = [ordered]@{ status = 'INCOMPLETE'; sessionRootRemoved = $false; cleanupMechanism = 'windows-job-object-plus-session-root-finally'; cleanupGuaranteed = $false }
    }
} catch {
    $dedicated = New-FtkDedicatedExecutionResult -Capability 'playwright-cli' -Operation 'browser-qa.playwright' `
        -Materialized:($null -ne $identity) -Attempted:$true -ChildStarted:$false -Succeeded:$false -ExitCode $null `
        -FailureType 'DEPENDENCY_OR_RUNTIME_FAILURE' -Diagnostics ([ordered]@{ message = Get-BrowserQaBoundedDiagnostic -Value $_.Exception.Message -MaximumCharacters 2048 }) `
        -Evidence ([ordered]@{ source = 'browser-qa-launcher-precondition' })
    $result = [ordered]@{
        schemaVersion = 1
        kind = 'browser-qa-action-result'
        operation = 'browser-qa.playwright'
        action = $Action
        executed = $false
        exitCode = $null
        stdout = @()
        stderr = @()
        workingDirectory = $sessionRoot
        browserDownloads = 0
        packageInstallation = $false
        arbitraryJavaScript = $false
        persistentState = $false
        headless = $true
        cliIdentity = $identity
        dedicatedExecution = $dedicated
        artifact = $null
        sessionLease = [ordered]@{ owner = 'ftk-playwright-launcher'; sessionId = $session; retained = $false; cleanupRequired = $false }
        cleanup = [ordered]@{ status = 'INCOMPLETE'; sessionRootRemoved = $false; cleanupMechanism = 'windows-job-object-plus-session-root-finally'; cleanupGuaranteed = $false }
    }
} finally {
    $retainLease = $false
    if ($null -ne $result -and $result -is [Collections.IDictionary] -and $result.Contains('sessionLease')) { $retainLease = [bool]$result.sessionLease.retained }
    if ($rootOwnedByInvocation -and -not $retainLease -and (Test-Path -LiteralPath $sessionRoot)) {
        try {
            Assert-BrowserQaPathContained -Root (Split-Path -Parent $sessionRoot) -Candidate $sessionRoot -Label 'Browser QA cleanup root' | Out-Null
            [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($sessionRoot), $true)
            $rootRemoved = $true
            $cleanupStatus = 'COMPLETED_WITH_LIMITATION'
        } catch { $cleanupStatus = 'INCOMPLETE' }
    } elseif ($retainLease) {
        $cleanupStatus = 'EXPLICIT_CLOSE_REQUIRED'
    } elseif (-not $rootOwnedByInvocation) {
        $cleanupStatus = 'PRESERVED_EXISTING_LEASE'
    }
}

$result.cleanup.status = $cleanupStatus
$result.cleanup.sessionRootRemoved = $rootRemoved
$result | ConvertTo-Json -Depth 20
