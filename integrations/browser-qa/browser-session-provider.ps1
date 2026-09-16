[CmdletBinding()]
param(
    [string]$InputPath,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$')][string]$SessionId,
    [string]$CliPath,
    [ValidateRange(1000, 600000)][int]$TimeoutMilliseconds = 120000,
    [switch]$PlanOnly,
    [switch]$TestOnlySyntheticCli
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'browser-qa-process.ps1')

$providerScript = Join-Path $PSScriptRoot 'browser-session-provider.mjs'
$session = if ([string]::IsNullOrWhiteSpace($SessionId)) { [guid]::NewGuid().ToString('N') } else { $SessionId }
$sessionRoot = Assert-BrowserQaTempSessionRoot -SessionId $session
$plan = [ordered]@{
    schemaVersion = 1
    operation = 'browser-qa.session'
    provider = 'integrations/browser-qa/browser-session-provider.mjs'
    inputName = 'transaction.json'
    sessionId = $session
    workingDirectory = $sessionRoot
    node = [ordered]@{ expectedVersion = '24.20.0'; resolution = 'deferred-until-execute' }
    cli = [ordered]@{ expectedPackage = '@playwright/cli'; expectedVersion = '0.1.19'; resolution = 'deferred-until-execute' }
    effects = @('BROWSER_EPHEMERAL', 'TEMP_OUTPUT', 'LOOPBACK_ONLY', 'LOCAL_READ_ONLY')
    operations = @('session.open', 'navigate', 'viewport.resize', 'capture.dom', 'capture.ax', 'capture.screenshot', 'capture.requests', 'interaction', 'session.close')
    headless = $true
    headlessControl = 'explicit-cli-flag-required'
    browserDownloads = 0
    packageInstallation = $false
    arbitraryJavaScript = $false
    persistentState = $false
    executed = $false
}

function New-BrowserQaEnvelope {
    param(
        [Parameter(Mandatory)][object]$DedicatedExecution,
        [AllowNull()][object]$Bundle = $null,
        [AllowNull()][object]$NodeIdentity = $null,
        [AllowNull()][object]$CliIdentity = $null,
        [Parameter(Mandatory)][string]$AuthorizationDecision,
        [Parameter(Mandatory)][bool]$RootRemoved,
        [Parameter(Mandatory)][string]$CleanupStatus
    )
    $envelope = New-FtkCapabilityExecutionEnvelope -Capability 'playwright-cli' -Operation 'browser-qa.session' `
        -PolicyStatus ALLOWED -AuthorizationDecision $AuthorizationDecision -DedicatedExecution $DedicatedExecution
    $result = [ordered]@{}
    foreach ($property in $envelope.PSObject.Properties) { $result[$property.Name] = $property.Value }
    $result.kind = 'browser-qa-execution-envelope'
    $result.provider = 'ftk-owned-browser-session-provider'
    $result.browserEvidenceBundle = $Bundle
    $result.nodeIdentity = $NodeIdentity
    $result.cliIdentity = $CliIdentity
    $result.cleanup = [ordered]@{
        status = $CleanupStatus
        sessionRootRemoved = $RootRemoved
        cleanupMechanism = 'windows-job-object-plus-session-root-finally'
        cleanupGuaranteed = $false
        limitation = 'Process.Start precedes Job Object assignment; descendant cleanup is bounded and truthful, not an absolute guarantee.'
    }
    return [pscustomobject]$result
}

if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 10
    return
}

function Assert-BrowserQaTransactionSource {
    param([Parameter(Mandatory)][string]$Path)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $source = [IO.Path]::GetFullPath($Path)
    $prefix = if ($temp.EndsWith([IO.Path]::DirectorySeparatorChar)) { $temp } else { $temp + [IO.Path]::DirectorySeparatorChar }
    if (-not $source.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Transaction input must be inside the OS temporary directory.' }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Transaction input does not exist.' }
    $item = Get-Item -LiteralPath $source -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -gt 2MB) { throw 'Transaction input must be a bounded regular file.' }
    $realTemp = (Resolve-Path -LiteralPath $temp).Path
    $realSource = (Resolve-Path -LiteralPath $source).Path
    $realPrefix = if ($realTemp.EndsWith([IO.Path]::DirectorySeparatorChar)) { $realTemp } else { $realTemp + [IO.Path]::DirectorySeparatorChar }
    if (-not $realSource.StartsWith($realPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Transaction input resolves outside the OS temporary directory.' }
    $cursor = [IO.Path]::GetDirectoryName($source)
    while (-not [string]::IsNullOrWhiteSpace($cursor) -and -not $cursor.Equals($temp, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-BrowserQaReparsePoint -Path $cursor) { throw 'Transaction input has a reparse-point ancestor.' }
        $next = [IO.Path]::GetDirectoryName($cursor)
        if ($next -eq $cursor) { break }
        $cursor = $next
    }
    return $source
}

$nodeIdentity = $null
$cliIdentity = $null
$dedicated = $null
$bundle = $null
$child = $null
$bundleTimedOut = $false
$effectiveTimedOut = $false
$rootCreated = $false
$rootRemoved = $false
$cleanupStatus = 'INCOMPLETE'
$inputValidationFailed = $false
$result = $null

try {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { $inputValidationFailed = $true; throw 'InputPath is required for Browser QA execution.' }
    $inputValidationFailed = $true
    $sourceInputPath = Assert-BrowserQaTransactionSource -Path $InputPath
    $inputValidationFailed = $false
    $baseRoot = Split-Path -Parent $sessionRoot
    if (Test-Path -LiteralPath $sessionRoot) { throw 'The requested Browser QA session id is already in use.' }
    [IO.Directory]::CreateDirectory($baseRoot) | Out-Null
    if (Test-BrowserQaReparsePoint -Path $baseRoot) { throw 'Browser QA temporary base became a reparse point.' }
    [IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
    $rootCreated = $true
    Assert-BrowserQaPathContained -Root $baseRoot -Candidate $sessionRoot -Label 'Browser QA session root' | Out-Null
    $inputPath = Join-Path $sessionRoot 'transaction.json'
    [IO.File]::Copy($sourceInputPath, $inputPath, $false)
    Assert-BrowserQaPathContained -Root $sessionRoot -Candidate $inputPath -Label 'Browser transaction input' -MustExist | Out-Null
    if (Test-BrowserQaReparsePoint -Path $inputPath) { throw 'Browser transaction input cannot be a reparse point.' }

    $nodeIdentity = Get-BrowserQaNodeIdentity
    $environment = New-BrowserQaChildEnvironment -SessionRoot $sessionRoot
    $preflight = Invoke-BrowserQaChildProcess -Executable $nodeIdentity.executable `
        -ArgumentList @($providerScript, '--validate-only', '--root', $sessionRoot, '--input', 'transaction.json') `
        -WorkingDirectory $sessionRoot -Environment $environment -TimeoutMilliseconds 10000 -Operation 'browser-qa.preflight'
    if (-not $preflight.processSucceeded) {
        $failureType = if ($preflight.exitCode -eq 2) { 'INVALID_INPUT' } else { 'DEPENDENCY_OR_RUNTIME_FAILURE' }
        $dedicated = New-FtkDedicatedExecutionResult -Capability 'playwright-cli' -Operation 'browser-qa.session' `
            -Materialized:$false -Attempted:$false -ChildStarted:$false -Succeeded:$false -ExitCode $null `
            -FailureType $failureType -Diagnostics ([ordered]@{ message = 'Typed transaction preflight was rejected before the Browser QA provider child.' }) `
            -Evidence ([ordered]@{ source = 'browser-qa-preflight'; diagnostics = $preflight.diagnostics })
        $result = New-BrowserQaEnvelope -DedicatedExecution $dedicated -AuthorizationDecision 'typed-input-preflight-rejected' `
            -RootRemoved:$false -CleanupStatus 'INCOMPLETE'
    } else {
        $cliIdentity = Get-BrowserQaCliIdentity -ExplicitPath $CliPath -AllowSyntheticTestDouble:$TestOnlySyntheticCli
        $providerArguments = New-Object Collections.Generic.List[string]
        [void]$providerArguments.Add($providerScript)
        [void]$providerArguments.Add('--root')
        [void]$providerArguments.Add($sessionRoot)
        [void]$providerArguments.Add('--input')
        [void]$providerArguments.Add('transaction.json')
        [void]$providerArguments.Add('--cli-entry')
        [void]$providerArguments.Add($cliIdentity.entryPath)
        [void]$providerArguments.Add('--cli-package-root')
        [void]$providerArguments.Add($cliIdentity.packageRoot)
        if ($cliIdentity.synthetic) { [void]$providerArguments.Add('--synthetic') }
        $child = Invoke-BrowserQaChildProcess -Executable $nodeIdentity.executable -ArgumentList $providerArguments.ToArray() `
            -WorkingDirectory $sessionRoot -Environment $environment -TimeoutMilliseconds $TimeoutMilliseconds -Operation 'browser-qa.session'
        $rawOutput = (@($child.stdout) -join [Environment]::NewLine).Trim()
        $outputContractValid = $true
        try {
            if ([string]::IsNullOrWhiteSpace($rawOutput)) { throw 'Browser QA provider returned no contract output.' }
            $bundle = $rawOutput | ConvertFrom-Json -ErrorAction Stop
            $requiredBundleFields = @('schemaVersion', 'kind', 'materialized', 'attempted', 'timedOut', 'browserReady', 'sessionReady', 'succeeded', 'browser', 'session', 'viewport', 'networkPolicy', 'evidence', 'outputContract')
            $bundleProperties = @($bundle.PSObject.Properties.Name)
            if (@($requiredBundleFields | Where-Object { $_ -notin $bundleProperties }).Count) { throw 'BrowserEvidenceBundle is missing required fields.' }
            if ($bundle.schemaVersion -ne 1 -or $bundle.kind -cne 'browser-evidence-bundle') { throw 'BrowserEvidenceBundle schema or kind is invalid.' }
            if ($bundle.evidence.dom -and @($bundle.evidence.dom.nodes).Count -gt 300) { throw 'DOM evidence exceeded the bounded node limit.' }
            if ($bundle.evidence.ax -and @($bundle.evidence.ax.tree).Count -gt 300) { throw 'AX evidence exceeded the bounded node limit.' }
            if (@($bundle.evidence.screenshots).Count -gt 8) { throw 'Screenshot evidence exceeded the bounded artifact limit.' }
            if (-not $bundle.outputContract.valid -or $bundle.outputContract.arbitraryJavaScriptUsed) { throw 'BrowserEvidenceBundle output contract is unsafe.' }
            $bundleTimedOut = [bool]$bundle.timedOut -or ([string]$bundle.failureType -eq 'TIMEOUT')
        } catch {
            $outputContractValid = $false
            $bundle = $null
        }
        $effectiveTimedOut = [bool]$child.timedOut -or $bundleTimedOut
        $providerFailureType = $null
        if ($effectiveTimedOut) { $providerFailureType = 'TIMEOUT' }
        elseif (-not $outputContractValid) { $providerFailureType = 'OUTPUT_CONTRACT_FAILURE' }
        elseif ($null -ne $bundle.failureType -and [string]$bundle.failureType -in @('INVALID_INPUT', 'DEPENDENCY_OR_RUNTIME_FAILURE', 'UPSTREAM_EXECUTION_FAILURE', 'OUTPUT_CONTRACT_FAILURE', 'TIMEOUT', 'UNKNOWN_FAILURE')) { $providerFailureType = [string]$bundle.failureType }
        elseif (-not [bool]$bundle.succeeded) { $providerFailureType = 'OUTPUT_CONTRACT_FAILURE' }
        $childFailureMessage = Get-FtkPropertyValue -InputObject $child.diagnostics -Name 'failureMessage'
        if ($effectiveTimedOut -and [string]::IsNullOrWhiteSpace([string]$childFailureMessage)) { $childFailureMessage = 'Browser QA transaction exceeded the governed timeout.' }
        $childForContract = New-FtkChildProcessObservation -Capability 'playwright-cli' -Operation 'browser-qa.session' `
            -Materialized:$child.materialized -Attempted:$child.attempted -ChildStarted:$child.childStarted -ExitCode $child.exitCode `
            -FailureType $providerFailureType -FailureMessage $childFailureMessage -TimedOut:$effectiveTimedOut `
            -StdoutText '' -StderrText '' -CaptureComplete:$child.diagnostics.captureComplete `
            -StdoutOverflowed:$child.diagnostics.stdoutOverflowed -StderrOverflowed:$child.diagnostics.stderrOverflowed `
            -EnvironmentNames @($environment.Keys) -Cleanup $child.cleanup -CleanupMechanism $child.cleanupMechanism `
            -CleanupGuaranteed:$child.cleanupGuaranteed -TimeoutMilliseconds $TimeoutMilliseconds -ProcessId $child.processId
        $dedicated = Complete-FtkDedicatedExecution -Capability 'playwright-cli' -Operation 'browser-qa.session' `
            -ChildObservation $childForContract -OutputContractValid:$outputContractValid `
            -OutputContractDiagnostic 'BrowserEvidenceBundle was absent, malformed, or untrusted.'
        $plan.executed = $true
        $plan.node = $nodeIdentity
        $plan.cli = $cliIdentity
        $plan.exitCode = $child.exitCode
        $result = New-BrowserQaEnvelope -DedicatedExecution $dedicated -Bundle $bundle -NodeIdentity $nodeIdentity -CliIdentity $cliIdentity `
            -AuthorizationDecision '03b-local-foundation-typed-provider' -RootRemoved:$false -CleanupStatus 'INCOMPLETE'
        if (-not $outputContractValid) {
            $result | Add-Member -NotePropertyName providerDiagnostics -NotePropertyValue ([ordered]@{ stdout = @($child.diagnostics.stdout); stderr = @($child.diagnostics.stderr) }) -Force
        }
    }
} catch {
    $observedBundleFailure = Get-FtkPropertyValue -InputObject $bundle -Name 'failureType'
    $catchChildStarted = if ($null -ne $child) { [bool]$child.childStarted } else { $false }
    $catchAttempted = if ($null -ne $child) { [bool]$child.attempted } else { $null -ne $nodeIdentity }
    $catchMaterialized = if ($null -ne $child) { [bool]$child.materialized } else { $null -ne $nodeIdentity }
    [Nullable[int]]$catchExitCode = if ($null -ne $child) { $child.exitCode } else { $null }
    $catchTimedOut = [bool]$effectiveTimedOut -or ($null -ne $child -and [bool]$child.timedOut) -or ([string]$observedBundleFailure -eq 'TIMEOUT')
    $failureType = if ($catchTimedOut) { 'TIMEOUT' }
        elseif ($catchChildStarted -and [string]$observedBundleFailure -in @('UPSTREAM_EXECUTION_FAILURE', 'OUTPUT_CONTRACT_FAILURE', 'UNKNOWN_FAILURE')) { [string]$observedBundleFailure }
        elseif ($inputValidationFailed -and -not $catchAttempted -and -not $_.Exception.Data.Contains('ftkExecutionEnvelope')) { 'INVALID_INPUT' }
        else { 'DEPENDENCY_OR_RUNTIME_FAILURE' }
    $catchDiagnostics = [ordered]@{ message = Get-BrowserQaBoundedDiagnostic -Value $_.Exception.Message -MaximumCharacters 2048 }
    if ($null -ne $child) { $catchDiagnostics.child = $child.diagnostics }
    $dedicated = New-FtkDedicatedExecutionResult -Capability 'playwright-cli' -Operation 'browser-qa.session' `
        -Materialized:$catchMaterialized -Attempted:$catchAttempted -ChildStarted:$catchChildStarted -Succeeded:$false -ExitCode $catchExitCode `
        -FailureType $failureType -TimedOut:$catchTimedOut -Diagnostics $catchDiagnostics `
        -Evidence ([ordered]@{ source = 'browser-qa-session-provider-exception'; child = if ($null -eq $child) { $null } else { $child.evidence } })
    $result = New-BrowserQaEnvelope -DedicatedExecution $dedicated -Bundle $bundle -NodeIdentity $nodeIdentity -CliIdentity $cliIdentity `
        -AuthorizationDecision '03b-local-foundation-precondition-failed' -RootRemoved:$false -CleanupStatus 'INCOMPLETE'
} finally {
    if ($rootCreated -and (Test-Path -LiteralPath $sessionRoot)) {
        try {
            Assert-BrowserQaPathContained -Root (Split-Path -Parent $sessionRoot) -Candidate $sessionRoot -Label 'Browser QA cleanup root' | Out-Null
            [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($sessionRoot), $true)
            $rootRemoved = $true
            $cleanupStatus = 'COMPLETED_WITH_LIMITATION'
        } catch {
            $cleanupStatus = 'INCOMPLETE'
        }
    } elseif (-not $rootCreated) {
        $rootRemoved = $true
        $cleanupStatus = 'NOT_REQUIRED'
    }
}

if ($null -eq $result) {
    $dedicated = New-FtkDedicatedExecutionResult -Capability 'playwright-cli' -Operation 'browser-qa.session' `
        -Materialized:$false -Attempted:$true -ChildStarted:$false -Succeeded:$false -ExitCode $null `
        -FailureType 'UNKNOWN_FAILURE' -Diagnostics ([ordered]@{ message = 'Browser QA provider did not produce a result.' })
    $result = New-BrowserQaEnvelope -DedicatedExecution $dedicated -AuthorizationDecision 'provider-result-missing' `
        -RootRemoved:$rootRemoved -CleanupStatus $cleanupStatus
}
$result.cleanup.sessionRootRemoved = $rootRemoved
$result.cleanup.status = $cleanupStatus
$result | ConvertTo-Json -Depth 20
