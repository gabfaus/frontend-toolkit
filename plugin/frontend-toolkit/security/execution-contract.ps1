Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is an FTK-owned contract. It is intentionally independent from the
# capability/effect registry so future first-class execution surfaces can
# compose the same states without gaining a new effect class.
$script:FtkExecutionContractSchemaVersion = 1
$script:FtkDedicatedExecutionDefaultTimeoutMilliseconds = 120000
$script:FtkDedicatedExecutionMaximumTimeoutMilliseconds = 600000
$script:FtkDedicatedExecutionMaximumOutputCharacters = 262144
$script:FtkDedicatedExecutionFailureTypes = @(
    'INVALID_INPUT'
    'DEPENDENCY_OR_RUNTIME_FAILURE'
    'UPSTREAM_EXECUTION_FAILURE'
    'OUTPUT_CONTRACT_FAILURE'
    'TIMEOUT'
    'UNKNOWN_FAILURE'
)

function Get-FtkDedicatedExecutionDefaultTimeoutMilliseconds {
    return $script:FtkDedicatedExecutionDefaultTimeoutMilliseconds
}

function Get-FtkDedicatedExecutionMaximumTimeoutMilliseconds {
    return $script:FtkDedicatedExecutionMaximumTimeoutMilliseconds
}

function Get-FtkDedicatedExecutionMaximumOutputCharacters {
    return $script:FtkDedicatedExecutionMaximumOutputCharacters
}

function Get-FtkDedicatedExecutionFailureTypes {
    return @($script:FtkDedicatedExecutionFailureTypes)
}

function Get-FtkPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-FtkBoundedDiagnostic {
    param(
        [AllowNull()][object]$Value,
        [ValidateRange(1, 1048576)][int]$MaximumCharacters = 4096,
        [string[]]$RedactValues = @()
    )

    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    foreach ($secret in @($RedactValues)) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $text = $text.Replace($secret, '[REDACTED]')
        }
    }
    $text = [regex]::Replace($text, '(?i)\bBearer\s+\S+', 'Bearer [REDACTED]')
    # A sensitive identifier may have a separated suffix (for example,
    # token_extra), but a normal word such as tokenizer must not match.
    $sensitiveIdentifier = '(?:access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|proxy[_-]?authorization|authorization|www[_-]?authenticate|x[_-]?(?:api[_-]?key|auth[_-]?token)|id[_-]?token|private[_-]?key|password|cookie|credential|secret|token|key)(?:[_-][A-Za-z0-9]+)*'
    $namedSecretPattern = '(?i)(?<prefix>(?<![A-Za-z0-9_-])' + $sensitiveIdentifier + '(?![A-Za-z0-9_-])[ \t]*[:=][ \t]*)(?<value>"[^"]*"|''[^'']*''|Bearer[ \t]+[^\s,;"'']+|[^\s,;"'']+)'
    $text = [regex]::Replace($text, $namedSecretPattern, [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $value = $match.Groups['value'].Value
            if ($value -in @('""', "''") -or $value -ceq '[REDACTED]') { return $match.Value }
            return $match.Groups['prefix'].Value + '[REDACTED]'
        })
    $text = [regex]::Replace($text, '(?i)\b(?:sk|pk)-[A-Za-z0-9_-]{16,}', '[REDACTED]')
    $text = $text -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ''
    if ($text.Length -gt $MaximumCharacters) {
        return $text.Substring(0, $MaximumCharacters) + '...[truncated]'
    }
    return $text
}

function ConvertTo-FtkDiagnosticLines {
    param(
        [AllowNull()][object]$Value,
        [string[]]$RedactValues = @()
    )

    $text = ConvertTo-FtkBoundedDiagnostic -Value $Value -MaximumCharacters (Get-FtkDedicatedExecutionMaximumOutputCharacters) -RedactValues $RedactValues
    if ([string]::IsNullOrEmpty($text)) { return @() }
    return @($text -split '\r?\n' | Where-Object { $_.Length -gt 0 } | ForEach-Object {
        ConvertTo-FtkBoundedDiagnostic -Value $_ -MaximumCharacters 8192 -RedactValues $RedactValues
    })
}

function Get-FtkStructuredStderrDiagnostic {
    param(
        [AllowNull()][string]$StderrText,
        [string[]]$RedactValues = @()
    )

    if ([string]::IsNullOrWhiteSpace($StderrText)) { return $null }
    try {
        $parsed = $StderrText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    $fields = [ordered]@{}
    foreach ($name in @('error','message','code','type')) {
        $value = Get-FtkPropertyValue -InputObject $parsed -Name $name
        if ($null -ne $value) {
            $fields[$name] = ConvertTo-FtkBoundedDiagnostic -Value $value -MaximumCharacters 512 -RedactValues $RedactValues
        }
    }
    if (-not $fields.Count) { return $null }
    return [pscustomobject]$fields
}

function New-FtkDedicatedExecutionResult {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][bool]$Materialized,
        [Parameter(Mandatory)][bool]$Attempted,
        [Parameter(Mandatory)][bool]$ChildStarted,
        [Parameter(Mandatory)][bool]$Succeeded,
        [AllowNull()][Nullable[int]]$ExitCode = $null,
        [AllowNull()][string]$FailureType = $null,
        [bool]$TimedOut = $false,
        [AllowNull()][Collections.IDictionary]$Diagnostics = $null,
        [AllowNull()][Collections.IDictionary]$Evidence = $null
    )

    $normalizedFailureType = if ([string]::IsNullOrWhiteSpace([string]$FailureType)) { $null } else { [string]$FailureType }
    if ($null -ne $normalizedFailureType -and $normalizedFailureType -notin $script:FtkDedicatedExecutionFailureTypes) {
        throw "Unknown dedicated execution failure type is denied: $normalizedFailureType"
    }
    if ($ChildStarted -and (-not $Materialized -or -not $Attempted)) {
        throw 'Dedicated execution state is inconsistent: a started child must be materialized and attempted.'
    }
    if ($Attempted -and -not $Materialized) {
        throw 'Dedicated execution state is inconsistent: an attempted execution must be materialized.'
    }
    if ($Attempted -and -not $ChildStarted -and $null -eq $normalizedFailureType) {
        throw 'Dedicated execution state is inconsistent: a non-started attempt requires a failure type.'
    }
    if ($normalizedFailureType -eq 'INVALID_INPUT' -and ($Attempted -or $ChildStarted)) {
        throw 'INVALID_INPUT must be rejected before the child process starts.'
    }
    if ($TimedOut -and $normalizedFailureType -cne 'TIMEOUT') {
        throw 'Timed-out execution must use the TIMEOUT failure type.'
    }
    if ($normalizedFailureType -eq 'TIMEOUT' -and -not $TimedOut) {
        throw 'TIMEOUT must set timedOut=true.'
    }
    if (-not $Attempted -and $normalizedFailureType -notin @($null, 'INVALID_INPUT', 'DEPENDENCY_OR_RUNTIME_FAILURE')) {
        throw 'A NOT_ATTEMPTED execution may only carry INVALID_INPUT or DEPENDENCY_OR_RUNTIME_FAILURE.'
    }
    if ($normalizedFailureType -in @('UPSTREAM_EXECUTION_FAILURE','OUTPUT_CONTRACT_FAILURE','TIMEOUT') -and -not $ChildStarted) {
        throw "$normalizedFailureType requires childStarted=true."
    }
    if (-not $ChildStarted -and $null -ne $ExitCode) {
        throw 'An exit code is only valid after the child process starts.'
    }
    if ($Succeeded -and ($null -ne $normalizedFailureType -or -not $ChildStarted -or $ExitCode -ne 0 -or $TimedOut)) {
        throw 'Dedicated execution success requires a started child, exit code 0, valid output, and no failure.'
    }
    if ($Attempted -and -not $Succeeded -and $null -eq $normalizedFailureType) {
        throw 'A FAILED dedicated execution requires a failure type.'
    }
    if ($normalizedFailureType -and $Succeeded) { throw 'A failed dedicated execution cannot also be successful.' }

    $normalizedDiagnostics = if ($null -eq $Diagnostics) { [ordered]@{} } else { $Diagnostics }
    $normalizedEvidence = if ($null -eq $Evidence) { [ordered]@{} } else { $Evidence }
    $resultState = if (-not $Attempted) { 'NOT_ATTEMPTED' } elseif ($Succeeded) { 'SUCCEEDED' } else { 'FAILED' }
    $materializationState = if ($Materialized) { 'MATERIALIZED' } else { 'NOT_MATERIALIZED' }
    $attemptState = if ($Attempted) { 'ATTEMPTED' } else { 'NOT_ATTEMPTED' }

    return [pscustomobject][ordered]@{
        schemaVersion = $script:FtkExecutionContractSchemaVersion
        capability = $Capability
        operation = $Operation
        materialization = $materializationState
        materialized = $Materialized
        attempt = $attemptState
        attempted = $Attempted
        childStarted = $ChildStarted
        dedicatedExecutionResult = $resultState
        succeeded = $Succeeded
        exitCode = $ExitCode
        failureType = $normalizedFailureType
        timedOut = $TimedOut
        diagnostics = $normalizedDiagnostics
        evidence = $normalizedEvidence
    }
}

function New-FtkNotAttemptedDedicatedExecution {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
        [AllowNull()][string]$FailureType = $null
    )

    return New-FtkDedicatedExecutionResult -Capability $Capability -Operation $Operation `
        -Materialized:$false -Attempted:$false -ChildStarted:$false -Succeeded:$false `
        -ExitCode $null -FailureType $FailureType -Diagnostics ([ordered]@{
            message = ConvertTo-FtkBoundedDiagnostic -Value $Reason -MaximumCharacters 1024
        }) -Evidence ([ordered]@{
            source = 'ftk-dedicated-execution-contract'
            reason = ConvertTo-FtkBoundedDiagnostic -Value $Reason -MaximumCharacters 512
        })
}

function New-FtkInvalidInputEnvelope {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason
    )

    $dedicated = New-FtkNotAttemptedDedicatedExecution -Capability $Capability -Operation $Operation `
        -Reason $Reason -FailureType INVALID_INPUT
    return New-FtkCapabilityExecutionEnvelope -Capability $Capability -Operation $Operation `
        -PolicyStatus ALLOWED -AuthorizationDecision 'invalid-input-rejected-before-child' `
        -DedicatedExecution $dedicated
}

function Throw-FtkInvalidInput {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason
    )

    $envelope = New-FtkInvalidInputEnvelope -Capability $Capability -Operation $Operation -Reason $Reason
    $message = 'INVALID_INPUT: ' + (ConvertTo-FtkBoundedDiagnostic -Value $Reason -MaximumCharacters 2048)
    $exception = [InvalidOperationException]::new($message)
    $exception.Data['ftkExecutionEnvelope'] = $envelope
    throw $exception
}

function New-FtkChildProcessObservation {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][bool]$Materialized,
        [Parameter(Mandatory)][bool]$Attempted,
        [Parameter(Mandatory)][bool]$ChildStarted,
        [AllowNull()][Nullable[int]]$ExitCode = $null,
        [AllowNull()][string]$FailureType = $null,
        [AllowNull()][string]$FailureMessage = $null,
        [bool]$TimedOut = $false,
        [AllowNull()][string]$StdoutText = '',
        [AllowNull()][string]$ContractStdoutText = $null,
        [switch]$IncludeContractOutput,
        [AllowNull()][string]$StderrText = '',
        [bool]$CaptureComplete = $true,
        [bool]$StdoutOverflowed = $false,
        [bool]$StderrOverflowed = $false,
        [string[]]$EnvironmentNames = @(),
        [string[]]$RedactValues = @(),
        [ValidateSet('NOT_REQUIRED','COMPLETED','COMPLETED_WITH_LIMITATION','INCOMPLETE')][string]$Cleanup = 'NOT_REQUIRED',
        [ValidateNotNullOrEmpty()][string]$CleanupMechanism = 'none',
        [bool]$CleanupGuaranteed = $false,
        [int]$TimeoutMilliseconds = 0,
        [AllowNull()][Nullable[int]]$ProcessId = $null
    )

    $normalizedFailureType = if ([string]::IsNullOrWhiteSpace([string]$FailureType)) { $null } else { [string]$FailureType }
    $stdout = ConvertTo-FtkDiagnosticLines -Value $StdoutText -RedactValues $RedactValues
    $stderr = ConvertTo-FtkDiagnosticLines -Value $StderrText -RedactValues $RedactValues
    $maximumOutputCharacters = Get-FtkDedicatedExecutionMaximumOutputCharacters
    $boundedStdout = ConvertTo-FtkBoundedDiagnostic -Value $StdoutText -MaximumCharacters $maximumOutputCharacters -RedactValues $RedactValues
    $boundedStderr = ConvertTo-FtkBoundedDiagnostic -Value $StderrText -MaximumCharacters $maximumOutputCharacters -RedactValues $RedactValues
    $structured = Get-FtkStructuredStderrDiagnostic -StderrText $boundedStderr -RedactValues $RedactValues
    $diagnostics = [ordered]@{
        stdout = @($stdout)
        stderr = @($stderr)
        structuredStderr = $structured
        stdoutCharacters = $boundedStdout.Length
        stderrCharacters = $boundedStderr.Length
        stdoutBounded = $true
        stderrBounded = $true
        stdoutOverflowed = $StdoutOverflowed
        stderrOverflowed = $StderrOverflowed
        stdoutTruncated = ($StdoutOverflowed -or ([string]$StdoutText).Length -gt $maximumOutputCharacters)
        stderrTruncated = ($StderrOverflowed -or ([string]$StderrText).Length -gt $maximumOutputCharacters)
        captureComplete = $CaptureComplete
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureMessage)) {
        $diagnostics.failureMessage = ConvertTo-FtkBoundedDiagnostic -Value $FailureMessage -MaximumCharacters 2048 -RedactValues $RedactValues
    }
    $evidence = [ordered]@{
        source = 'ftk-impeccable-child-process'
        processId = $ProcessId
        environmentNames = @($EnvironmentNames | Sort-Object -Unique)
        cleanup = $Cleanup
        cleanupMechanism = $CleanupMechanism
        cleanupGuaranteed = $CleanupGuaranteed
        captureComplete = $CaptureComplete
        timeoutMilliseconds = $TimeoutMilliseconds
        timeoutGoverned = ($TimeoutMilliseconds -gt 0)
    }
    $result = [ordered]@{
        schemaVersion = $script:FtkExecutionContractSchemaVersion
        kind = 'dedicated-child-observation'
        capability = $Capability
        operation = $Operation
        materialized = $Materialized
        attempted = $Attempted
        childStarted = $ChildStarted
        exitCode = $ExitCode
        failureType = $normalizedFailureType
        timedOut = $TimedOut
        processSucceeded = ($ChildStarted -and -not $TimedOut -and $ExitCode -eq 0 -and $null -eq $normalizedFailureType)
        stdout = @($stdout)
        stderr = @($stderr)
        diagnostics = $diagnostics
        evidence = $evidence
        cleanup = $Cleanup
        cleanupMechanism = $CleanupMechanism
        cleanupGuaranteed = $CleanupGuaranteed
        processId = $ProcessId
        executableClass = 'locked-node'
        commandStringConstructed = $false
        environmentNames = @($EnvironmentNames | Sort-Object -Unique)
    }
    if ($IncludeContractOutput -and $null -ne $ContractStdoutText) { $result.contractStdout = $ContractStdoutText }
    return [pscustomobject]$result
}

function Complete-FtkDedicatedExecution {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][object]$ChildObservation,
        [bool]$OutputContractValid = $true,
        [AllowNull()][string]$OutputContractDiagnostic = ''
    )

    $childStarted = [bool](Get-FtkPropertyValue $ChildObservation 'childStarted')
    $attempted = [bool](Get-FtkPropertyValue $ChildObservation 'attempted')
    $materialized = [bool](Get-FtkPropertyValue $ChildObservation 'materialized')
    $timedOut = [bool](Get-FtkPropertyValue $ChildObservation 'timedOut')
    $childDiagnostics = Get-FtkPropertyValue $ChildObservation 'diagnostics'
    $stdoutTruncated = [bool](Get-FtkPropertyValue $childDiagnostics 'stdoutTruncated')
    $stderrTruncated = [bool](Get-FtkPropertyValue $childDiagnostics 'stderrTruncated')
    $stdoutOverflowed = [bool](Get-FtkPropertyValue $childDiagnostics 'stdoutOverflowed')
    $stderrOverflowed = [bool](Get-FtkPropertyValue $childDiagnostics 'stderrOverflowed')
    if ($OutputContractValid -and ($stdoutTruncated -or $stderrTruncated -or $stdoutOverflowed -or $stderrOverflowed)) {
        $OutputContractValid = $false
        $OutputContractDiagnostic = 'Dedicated child output exceeded the bounded contract limit.'
    }
    $exitCodeValue = Get-FtkPropertyValue $ChildObservation 'exitCode'
    [Nullable[int]]$exitCode = if ($null -eq $exitCodeValue -or [string]::IsNullOrWhiteSpace([string]$exitCodeValue)) { $null } else { [int]$exitCodeValue }
    $observedFailure = Get-FtkPropertyValue $ChildObservation 'failureType'
    if ([string]::IsNullOrWhiteSpace([string]$observedFailure)) { $observedFailure = $null }
    if ($observedFailure -and $observedFailure -notin $script:FtkDedicatedExecutionFailureTypes) { $observedFailure = 'UNKNOWN_FAILURE' }

    $failureType = $observedFailure
    if ($null -eq $failureType) {
        if ($timedOut) { $failureType = 'TIMEOUT' }
        elseif (-not $childStarted) { $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE' }
        elseif ($null -eq $exitCode -or $exitCode -ne 0) { $failureType = 'UPSTREAM_EXECUTION_FAILURE' }
        elseif (-not $OutputContractValid) { $failureType = 'OUTPUT_CONTRACT_FAILURE' }
    }
    $succeeded = ($null -eq $failureType -and $childStarted -and $exitCode -eq 0 -and $OutputContractValid)
    $diagnostics = [ordered]@{}
    foreach ($name in @('stdout','stderr','structuredStderr','stdoutCharacters','stderrCharacters','stdoutBounded','stderrBounded','stdoutOverflowed','stderrOverflowed','stdoutTruncated','stderrTruncated','captureComplete','failureMessage')) {
        $value = Get-FtkPropertyValue $childDiagnostics $name
        if ($null -ne $value) { $diagnostics[$name] = $value }
    }
    if (-not $OutputContractValid) {
        $diagnostics.outputContract = [ordered]@{
            valid = $false
            message = ConvertTo-FtkBoundedDiagnostic -Value $OutputContractDiagnostic -MaximumCharacters 2048
        }
    }
    $childEvidence = Get-FtkPropertyValue $ChildObservation 'evidence'
    $evidence = [ordered]@{
        source = 'ftk-dedicated-execution-contract'
        child = if ($null -eq $childEvidence) { [ordered]@{} } else { $childEvidence }
        outputContractValid = $OutputContractValid
        childCleanup = Get-FtkPropertyValue $ChildObservation 'cleanup'
    }
    return New-FtkDedicatedExecutionResult -Capability $Capability -Operation $Operation `
        -Materialized:$materialized -Attempted:$attempted -ChildStarted:$childStarted `
        -Succeeded:$succeeded -ExitCode $exitCode -FailureType $failureType -TimedOut:$timedOut `
        -Diagnostics $diagnostics -Evidence $evidence
}

function New-FtkCapabilityExecutionEnvelope {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][ValidateSet('ALLOWED','POLICY_REJECTION')][string]$PolicyStatus,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AuthorizationDecision,
        [AllowNull()][object]$DedicatedExecution = $null,
        [AllowNull()][object]$FallbackResult = $null,
        [AllowNull()][object]$RoutingResult = $null,
        [AllowNull()][object]$FinalWorkflowResult = $null
    )

    $dedicated = if ($null -eq $DedicatedExecution) {
        New-FtkNotAttemptedDedicatedExecution -Capability $Capability -Operation $Operation -Reason 'Dedicated execution was not invoked by this layer.'
    } else { $DedicatedExecution }
    $envelope = [ordered]@{
        schemaVersion = $script:FtkExecutionContractSchemaVersion
        capability = $Capability
        operation = $Operation
        policy = [ordered]@{
            status = $PolicyStatus
            authorizationDecision = $AuthorizationDecision
            source = 'frontend-toolkit-common-dispatcher'
        }
        dedicatedExecution = $dedicated
        materialized = [bool](Get-FtkPropertyValue $dedicated 'materialized')
        attempted = [bool](Get-FtkPropertyValue $dedicated 'attempted')
        childStarted = [bool](Get-FtkPropertyValue $dedicated 'childStarted')
        succeeded = [bool](Get-FtkPropertyValue $dedicated 'succeeded')
        exitCode = Get-FtkPropertyValue $dedicated 'exitCode'
        failureType = Get-FtkPropertyValue $dedicated 'failureType'
        timedOut = [bool](Get-FtkPropertyValue $dedicated 'timedOut')
        diagnostics = Get-FtkPropertyValue $dedicated 'diagnostics'
        evidence = Get-FtkPropertyValue $dedicated 'evidence'
        fallback = $FallbackResult
        finalWorkflowResult = $FinalWorkflowResult
    }
    if ($null -ne $RoutingResult) { $envelope.routing = $RoutingResult }
    return [pscustomobject]$envelope
}

function New-FtkPolicyRejectionEnvelope {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Capability,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AuthorizationDecision,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason
    )

    $dedicated = New-FtkNotAttemptedDedicatedExecution -Capability $Capability -Operation $Operation -Reason $Reason
    return New-FtkCapabilityExecutionEnvelope -Capability $Capability -Operation $Operation `
        -PolicyStatus POLICY_REJECTION -AuthorizationDecision $AuthorizationDecision -DedicatedExecution $dedicated
}

function Add-FtkDedicatedExecutionMetadata {
    param(
        [Parameter(Mandatory)][object]$OperationResult,
        [Parameter(Mandatory)][object]$DedicatedExecution
    )

    $capability = [string](Get-FtkPropertyValue $DedicatedExecution 'capability')
    $operation = [string](Get-FtkPropertyValue $DedicatedExecution 'operation')
    $executionEnvelope = New-FtkCapabilityExecutionEnvelope -Capability $capability -Operation $operation `
        -PolicyStatus ALLOWED -AuthorizationDecision 'common-dispatcher-allowed' `
        -DedicatedExecution $DedicatedExecution
    if ($OperationResult -is [Collections.IDictionary]) {
        $OperationResult['dedicatedExecution'] = $DedicatedExecution
        $OperationResult['execution'] = $executionEnvelope
        return [pscustomobject]$OperationResult
    }
    Add-Member -InputObject $OperationResult -MemberType NoteProperty -Name dedicatedExecution -Value $DedicatedExecution -Force
    Add-Member -InputObject $OperationResult -MemberType NoteProperty -Name execution -Value $executionEnvelope -Force
    return $OperationResult
}
