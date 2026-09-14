Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [Parameter(Mandatory)][string]$Message)
    if ($Actual -cne $Expected) { throw "$Message Actual=[$Actual] Expected=[$Expected]" }
}

function Invoke-SyntheticChild {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyCollection()][string[]]$ScriptArguments = @(),
        [Parameter(Mandatory)][string]$Operation,
        [ValidateRange(0, 600000)][int]$TimeoutMilliseconds = 5000,
        [AllowNull()][string]$StandardInputText = $null
    )

    $powershell = (Get-Command powershell.exe).Source
    $environment = New-ImpeccableChildEnvironment
    $invokeParameters = @{
        Executable = $powershell
        ArgumentList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath) + @($ScriptArguments)
        WorkingDirectory = Split-Path -Parent $ScriptPath
        Environment = $environment
        Operation = $Operation
        TimeoutMilliseconds = $TimeoutMilliseconds
        ReturnResult = $true
    }
    if ($null -ne $StandardInputText) { $invokeParameters.StandardInputText = $StandardInputText }
    return Invoke-ImpeccableChildProcess @invokeParameters
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
. (Join-Path $securityRoot 'impeccable-runner.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-impeccable-execution-' + [guid]::NewGuid().ToString('N'))
$originalSecret = [Environment]::GetEnvironmentVariable('FTK_SYNTHETIC_PARENT_SECRET', 'Process')

try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $successScript = Join-Path $fixture 'success.ps1'
    $stderrJsonScript = Join-Path $fixture 'stderr-json.ps1'
    $stderrMalformedScript = Join-Path $fixture 'stderr-malformed.ps1'
    $stdoutVolumeScript = Join-Path $fixture 'stdout-volume.ps1'
    $stderrVolumeScript = Join-Path $fixture 'stderr-volume.ps1'
    $bothVolumeScript = Join-Path $fixture 'both-volume.ps1'
    $boundaryScript = Join-Path $fixture 'boundary.ps1'
    $exactBoundaryScript = Join-Path $fixture 'exact-boundary.ps1'
    $timeoutScript = Join-Path $fixture 'timeout.ps1'
    $timeoutOutputScript = Join-Path $fixture 'timeout-output.ps1'
    $descendantScript = Join-Path $fixture 'descendant.ps1'
    $postAssignmentDescendantScript = Join-Path $fixture 'post-assignment-descendant.ps1'
    $environmentScript = Join-Path $fixture 'environment.ps1'

    [IO.File]::WriteAllText($successScript, @'
param([string]$Argument)
[Console]::Out.WriteLine((@{ status = 'ok'; argument = $Argument } | ConvertTo-Json -Compress))
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrJsonScript, @'
[Console]::Error.WriteLine((@{ error = 'synthetic upstream failure'; code = 'E_SYNTHETIC' } | ConvertTo-Json -Compress))
exit 1
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrMalformedScript, @'
[Console]::Error.WriteLine('malformed stderr that is not JSON')
exit 1
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stdoutVolumeScript, @'
[Console]::Out.WriteLine('o' * 400000)
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrVolumeScript, @'
[Console]::Error.WriteLine('e' * 400000)
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($bothVolumeScript, @'
[Console]::Out.WriteLine('o' * 400000)
[Console]::Error.WriteLine('e' * 400000)
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($boundaryScript, @'
[Console]::Out.Write('o' * 262143)
[Console]::Error.Write('e' * 262143)
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($exactBoundaryScript, @'
[Console]::Out.Write('o' * 262144)
[Console]::Error.Write('e' * 262144)
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($timeoutScript, @'
Start-Sleep -Seconds 10
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($timeoutOutputScript, @'
[Console]::Out.WriteLine('timeout-output')
Start-Sleep -Seconds 10
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($descendantScript, @'
$descendant = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru
[Console]::Out.WriteLine($descendant.Id)
Start-Sleep -Seconds 5
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($postAssignmentDescendantScript, @'
if ([Console]::In.ReadLine() -ne 'start') { exit 2 }
$descendant = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru
[Console]::Out.WriteLine($descendant.Id)
Start-Sleep -Seconds 30
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($environmentScript, @'
Get-ChildItem Env: | ForEach-Object { [Console]::Out.WriteLine($_.Name) }
'@, [Text.UTF8Encoding]::new($false))

    $taxonomy = @(Get-FtkDedicatedExecutionFailureTypes)
    Assert-Equal ($taxonomy -join '|') 'INVALID_INPUT|DEPENDENCY_OR_RUNTIME_FAILURE|UPSTREAM_EXECUTION_FAILURE|OUTPUT_CONTRACT_FAILURE|TIMEOUT|UNKNOWN_FAILURE' 'Dedicated failure taxonomy drifted.'
    Assert-Equal (Get-FtkDedicatedExecutionDefaultTimeoutMilliseconds) 120000 'FTK default timeout drifted.'
    $maximumOutputCharacters = Get-FtkDedicatedExecutionMaximumOutputCharacters
    Assert-Equal $maximumOutputCharacters 262144 'FTK output limit drifted.'

    $sanitizationFixture = @'
TOKEN=synthetic-token-value
token: synthetic-token-value-2
token_extra=synthetic-token-extra-value
token_extra: "synthetic-token-extra-quoted-value"
ACCESS_TOKEN=synthetic-access-value
refresh_token = "synthetic-refresh-value"
api_key=synthetic-api-value
API_KEY_EXTRA=synthetic-api-extra-value
api_key_extra=synthetic-api-extra-value-2
key=synthetic-key-value
key_extra=synthetic-key-extra-value
secret: synthetic-secret-value
secret_extra=synthetic-secret-extra-value
client_secret='synthetic-client-secret-value'
client_secret_extra=synthetic-client-secret-extra-value
Authorization: Bearer bearer-fixture
authorization_extra=synthetic-authorization-extra-value
API-KEY=synthetic-api-dash-key-value
Bearer bearer-fixture
token=
key=""
secret=''
token=[REDACTED]
tokenizer=keep-tokenizer
keynote=keep-keynote
monkey=keep-monkey
secretary=keep-secretary
environment=synthetic-explicit-environment-value
'@
    $sanitized = ConvertTo-FtkBoundedDiagnostic -Value $sanitizationFixture -MaximumCharacters 8192 `
        -RedactValues @('synthetic-explicit-environment-value')
    foreach ($rawSecret in @('synthetic-token-value','synthetic-token-value-2','synthetic-token-extra-value','synthetic-token-extra-quoted-value','synthetic-access-value','synthetic-refresh-value','synthetic-api-value','synthetic-api-extra-value','synthetic-api-extra-value-2','synthetic-key-value','synthetic-key-extra-value','synthetic-secret-value','synthetic-secret-extra-value','synthetic-client-secret-value','synthetic-client-secret-extra-value','synthetic-authorization-extra-value','synthetic-api-dash-key-value','bearer-fixture','synthetic-explicit-environment-value')) {
        Assert-True (-not $sanitized.Contains($rawSecret)) "Sanitizer leaked fixture value: $rawSecret"
    }
    Assert-True ($sanitized -match '(?im)^token=\r?$' -and $sanitized -match '(?im)^key=""\r?$' -and $sanitized -match "(?im)^secret=''\r?$") 'Sanitizer changed empty secret values.'
    Assert-True ($sanitized -match '(?im)^token_extra=\[REDACTED\]\r?$' -and
        $sanitized -match '(?im)^token_extra:\s+\[REDACTED\]\r?$' -and
        $sanitized -match '(?im)^key_extra=\[REDACTED\]\r?$' -and
        $sanitized -match '(?im)^secret_extra=\[REDACTED\]\r?$' -and
        $sanitized -match '(?im)^api_key_extra=\[REDACTED\]\r?$' -and
        $sanitized -match '(?im)^client_secret_extra=\[REDACTED\]\r?$' -and
        $sanitized -match '(?im)^authorization_extra=\[REDACTED\]\r?$' -and
        $sanitized -match '(?im)^API-KEY=\[REDACTED\]\r?$') 'Sensitive identifier suffix families were not sanitized.'
    Assert-True ($sanitized -match '(?im)^tokenizer=keep-tokenizer\r?$' -and $sanitized -match '(?im)^keynote=keep-keynote\r?$' -and $sanitized -match '(?im)^monkey=keep-monkey\r?$' -and $sanitized -match '(?im)^secretary=keep-secretary\r?$') 'Sanitizer destroyed false-positive controls.'
    Assert-True ($sanitized -match '(?im)^Bearer \[REDACTED\]\r?$' -and $sanitized -match '(?im)^Authorization(?:\s*[:=])\s*\[REDACTED\]\r?$') 'Bearer or authorization-like values were not sanitized.'
    $environmentProbe = [ordered]@{
        TOKENIZER = 'synthetic-tokenizer'
        KEYNOTE = 'synthetic-keynote'
        MONKEY = 'synthetic-monkey'
        FTK_PARENT_SECRET = 'synthetic-environment-secret'
    }
    $environmentSensitiveValues = @(Get-ImpeccableSensitiveEnvironmentValues -Environment $environmentProbe)
    Assert-True ($environmentSensitiveValues -contains 'synthetic-environment-secret' -and
        $environmentSensitiveValues -notcontains 'synthetic-tokenizer' -and
        $environmentSensitiveValues -notcontains 'synthetic-keynote' -and
        $environmentSensitiveValues -notcontains 'synthetic-monkey') 'Environment secret-name matching used substring false positives.'

    $argument = 'space "quote" and trailing\'
    $successChild = Invoke-SyntheticChild -ScriptPath $successScript -ScriptArguments @($argument) `
        -Operation 'impeccable.synthetic.success'
    Assert-True ($successChild.materialized -and $successChild.attempted -and $successChild.childStarted) 'Successful child state was not preserved.'
    Assert-Equal $successChild.exitCode 0 'Successful child exit code was not preserved.'
    Assert-True ($successChild.processSucceeded -and $successChild.cleanup -ceq 'COMPLETED_WITH_LIMITATION' -and
        -not $successChild.cleanupGuaranteed) 'Successful child did not report truthful cleanup semantics.'
    $successPayload = ($successChild.stdout -join "
") | ConvertFrom-Json
    Assert-Equal $successPayload.argument $argument 'Windows argv serialization lost the synthetic argument.'
    $success = Complete-FtkDedicatedExecution -Capability impeccable -Operation impeccable.synthetic.success `
        -ChildObservation $successChild
    Assert-True ($success.succeeded -and $success.dedicatedExecutionResult -ceq 'SUCCEEDED' -and $success.failureType -eq $null) 'Valid dedicated execution was not successful.'
    $successEnvelope = New-FtkCapabilityExecutionEnvelope -Capability impeccable -Operation impeccable.synthetic.success `
        -PolicyStatus ALLOWED -AuthorizationDecision common-dispatcher-allowed -DedicatedExecution $success
    Assert-True ($successEnvelope.policy.status -ceq 'ALLOWED' -and $successEnvelope.dedicatedExecution.succeeded) 'Authorization/policy and dedicated execution were not composed separately.'

    # The legacy observation fields remain available to existing valid callers.
    $legacyCompatible = Invoke-ImpeccableChildProcess -Executable (Get-Command powershell.exe).Source `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$successScript,'legacy') -WorkingDirectory $fixture `
        -Environment (New-ImpeccableChildEnvironment) -Operation 'impeccable.synthetic.legacy' -TimeoutMilliseconds 5000
    Assert-True ($legacyCompatible.stdout -and $legacyCompatible.stderr -is [array] -and $legacyCompatible.exitCode -eq 0) 'Existing child observation fields are not compatible.'

    $stderrJsonChild = Invoke-SyntheticChild -ScriptPath $stderrJsonScript -Operation 'impeccable.synthetic.stderr-json'
    Assert-True ($stderrJsonChild.childStarted -and $stderrJsonChild.exitCode -eq 1 -and $stderrJsonChild.failureType -ceq 'UPSTREAM_EXECUTION_FAILURE') 'Non-zero child was not classified as upstream failure.'
    Assert-True (-not $stderrJsonChild.processSucceeded -and $stderrJsonChild.diagnostics.structuredStderr.error -ceq 'synthetic upstream failure' -and $stderrJsonChild.diagnostics.structuredStderr.code -ceq 'E_SYNTHETIC') 'Structured stderr was not captured safely.'
    $stderrJsonResult = Complete-FtkDedicatedExecution -Capability impeccable -Operation impeccable.synthetic.stderr-json -ChildObservation $stderrJsonChild
    Assert-True (-not $stderrJsonResult.succeeded -and $stderrJsonResult.exitCode -eq 1 -and $stderrJsonResult.failureType -ceq 'UPSTREAM_EXECUTION_FAILURE') 'Upstream failure was converted to success.'

    $stderrMalformedChild = Invoke-SyntheticChild -ScriptPath $stderrMalformedScript -Operation 'impeccable.synthetic.stderr-malformed'
    Assert-True ($stderrMalformedChild.failureType -ceq 'UPSTREAM_EXECUTION_FAILURE' -and $null -eq $stderrMalformedChild.diagnostics.structuredStderr) 'Malformed stderr crashed parsing or changed the failure class.'

    $boundaryChild = Invoke-SyntheticChild -ScriptPath $boundaryScript -Operation 'impeccable.synthetic.boundary'
    Assert-True ($boundaryChild.childStarted -and $boundaryChild.exitCode -eq 0 -and $boundaryChild.diagnostics.captureComplete -and
        $boundaryChild.diagnostics.stdoutCharacters -eq 262143 -and $boundaryChild.diagnostics.stderrCharacters -eq 262143 -and
        -not $boundaryChild.diagnostics.stdoutTruncated -and -not $boundaryChild.diagnostics.stderrTruncated) 'Output immediately below the limit was not captured exactly.'
    $boundaryResult = Complete-FtkDedicatedExecution -Capability impeccable -Operation impeccable.synthetic.boundary -ChildObservation $boundaryChild
    Assert-True ($boundaryResult.succeeded -and $boundaryResult.failureType -eq $null) 'Output immediately below the limit was rejected.'

    $exactBoundaryChild = Invoke-SyntheticChild -ScriptPath $exactBoundaryScript -Operation 'impeccable.synthetic.exact-boundary'
    Assert-True ($exactBoundaryChild.childStarted -and $exactBoundaryChild.exitCode -eq 0 -and $exactBoundaryChild.diagnostics.stdoutCharacters -eq 262144 -and
        $exactBoundaryChild.diagnostics.stderrCharacters -eq 262144 -and -not $exactBoundaryChild.diagnostics.stdoutTruncated -and
        -not $exactBoundaryChild.diagnostics.stderrTruncated) 'Output exactly at the limit was not accepted.'
    $exactBoundaryResult = Complete-FtkDedicatedExecution -Capability impeccable -Operation impeccable.synthetic.exact-boundary -ChildObservation $exactBoundaryChild
    Assert-True ($exactBoundaryResult.succeeded -and $exactBoundaryResult.failureType -eq $null) 'Output exactly at the limit was rejected.'

    foreach ($case in @(
        @{ Script = $stdoutVolumeScript; Operation = 'impeccable.synthetic.stdout-overflow'; Stream = 'stdout' },
        @{ Script = $stderrVolumeScript; Operation = 'impeccable.synthetic.stderr-overflow'; Stream = 'stderr' },
        @{ Script = $bothVolumeScript; Operation = 'impeccable.synthetic.both-overflow'; Stream = 'both' }
    )) {
        $overflowChild = Invoke-SyntheticChild -ScriptPath $case.Script -Operation $case.Operation -TimeoutMilliseconds 10000
        $expectedStdoutOverflow = $case.Stream -in @('stdout','both')
        $expectedStderrOverflow = $case.Stream -in @('stderr','both')
        $overflowDetected = [bool]($overflowChild.diagnostics.stdoutOverflowed -or $overflowChild.diagnostics.stderrOverflowed)
        $streamOverflowContractValid = if ($case.Stream -ceq 'both') {
            $overflowDetected
        } else {
            $overflowChild.diagnostics.stdoutOverflowed -eq $expectedStdoutOverflow -and
                $overflowChild.diagnostics.stderrOverflowed -eq $expectedStderrOverflow
        }
        Assert-True ($overflowChild.childStarted -and $overflowChild.failureType -ceq 'OUTPUT_CONTRACT_FAILURE' -and $overflowChild.cleanup -ceq 'COMPLETED_WITH_LIMITATION' -and
            -not $overflowChild.cleanupGuaranteed -and
            -not $overflowChild.processSucceeded -and
            $overflowChild.diagnostics.captureComplete -and $overflowChild.diagnostics.stdoutCharacters -le $maximumOutputCharacters -and
            $overflowChild.diagnostics.stderrCharacters -le $maximumOutputCharacters -and
            $streamOverflowContractValid) "Output overflow was not bounded/fail-closed for $($case.Stream)."
        $overflowResult = Complete-FtkDedicatedExecution -Capability impeccable -Operation $case.Operation -ChildObservation $overflowChild
        Assert-True (-not $overflowResult.succeeded -and $overflowResult.failureType -ceq 'OUTPUT_CONTRACT_FAILURE') "Output overflow changed result semantics for $($case.Stream)."
    }

    $timeoutChild = Invoke-SyntheticChild -ScriptPath $timeoutScript -Operation 'impeccable.synthetic.timeout' -TimeoutMilliseconds 250
    Assert-True ($timeoutChild.childStarted -and $timeoutChild.timedOut -and $timeoutChild.failureType -ceq 'TIMEOUT' -and
        $timeoutChild.cleanup -ceq 'COMPLETED_WITH_LIMITATION' -and -not $timeoutChild.cleanupGuaranteed) 'Timeout did not report truthful cleanup semantics.'
    if ($timeoutChild.processId) {
        Assert-True (-not (Get-Process -Id $timeoutChild.processId -ErrorAction SilentlyContinue)) 'Timed-out child process remained alive.'
    }
    $zeroTimeoutChild = Invoke-SyntheticChild -ScriptPath $timeoutOutputScript -Operation 'impeccable.synthetic.timeout-zero' -TimeoutMilliseconds 0
    Assert-True ($zeroTimeoutChild.childStarted -and $zeroTimeoutChild.timedOut -and $zeroTimeoutChild.failureType -ceq 'TIMEOUT' -and
        $zeroTimeoutChild.cleanup -ceq 'COMPLETED_WITH_LIMITATION' -and -not $zeroTimeoutChild.cleanupGuaranteed) 'Zero timeout did not fail closed with truthful cleanup semantics.'
    $maximumTimeoutChild = Invoke-SyntheticChild -ScriptPath $successScript -Operation 'impeccable.synthetic.timeout-maximum' -TimeoutMilliseconds 600000
    Assert-True ($maximumTimeoutChild.childStarted -and $maximumTimeoutChild.exitCode -eq 0 -and
        $maximumTimeoutChild.cleanup -ceq 'COMPLETED_WITH_LIMITATION' -and -not $maximumTimeoutChild.cleanupGuaranteed) 'Maximum supported timeout changed truthful cleanup semantics.'

    $descendantChild = Invoke-SyntheticChild -ScriptPath $descendantScript -Operation 'impeccable.synthetic.descendant' -TimeoutMilliseconds 3000
    Assert-True ($descendantChild.childStarted -and $descendantChild.timedOut -and $descendantChild.failureType -ceq 'TIMEOUT' -and
        $descendantChild.cleanup -ceq 'COMPLETED_WITH_LIMITATION' -and $descendantChild.cleanupMechanism -ceq 'windows-job-object' -and
        -not $descendantChild.cleanupGuaranteed) 'Pre-assignment race fixture received a false process-tree guarantee.'
    $descendantPid = [int](($descendantChild.contractStdout -split '\r?\n' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1))
    $descendantStillRunning = $null -ne (Get-Process -Id $descendantPid -ErrorAction SilentlyContinue)
    Assert-True ($descendantPid -gt 0) "Race fixture did not report its descendant PID. parentPID=$($descendantChild.processId)"
    if ($descendantStillRunning) { Write-Output 'PASS: immediate descendant race remains explicitly non-guaranteed when the descendant escapes assignment.' }

    $postAssignmentChild = Invoke-SyntheticChild -ScriptPath $postAssignmentDescendantScript `
        -Operation 'impeccable.synthetic.post-assignment-descendant' -TimeoutMilliseconds 3000 -StandardInputText 'start'
    Assert-True ($postAssignmentChild.childStarted -and $postAssignmentChild.timedOut -and
        $postAssignmentChild.failureType -ceq 'TIMEOUT' -and $postAssignmentChild.cleanup -ceq 'COMPLETED_WITH_LIMITATION' -and
        $postAssignmentChild.cleanupMechanism -ceq 'windows-job-object' -and -not $postAssignmentChild.cleanupGuaranteed) `
        'Post-assignment descendant did not preserve the limited cleanup contract.'
    $postAssignmentDescendantPid = [int](($postAssignmentChild.contractStdout -split '\r?\n' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1))
    $postAssignmentParentRunning = $null -ne (Get-Process -Id $postAssignmentChild.processId -ErrorAction SilentlyContinue)
    $postAssignmentDescendantRunning = $null -ne (Get-Process -Id $postAssignmentDescendantPid -ErrorAction SilentlyContinue)
    Assert-True ($postAssignmentDescendantPid -gt 0 -and -not $postAssignmentParentRunning -and -not $postAssignmentDescendantRunning) `
        "Job Object did not terminate the parent and post-assignment descendant. parentPID=$($postAssignmentChild.processId) descendantPID=$postAssignmentDescendantPid"

    $dependencyChild = Invoke-ImpeccableChildProcess -Executable (Join-Path $fixture 'missing-runtime.exe') `
        -ArgumentList @() -WorkingDirectory $fixture -Environment (New-ImpeccableChildEnvironment) `
        -Operation 'impeccable.synthetic.missing-runtime' -TimeoutMilliseconds 1000 -ReturnResult
    Assert-True ($dependencyChild.failureType -ceq 'DEPENDENCY_OR_RUNTIME_FAILURE' -and $dependencyChild.attempted -and -not $dependencyChild.childStarted -and $null -eq $dependencyChild.exitCode) 'Missing runtime was not classified as a dependency/runtime failure.'
    $dependencyNotMaterialized = New-FtkNotAttemptedDedicatedExecution -Capability impeccable `
        -Operation impeccable.synthetic.missing-dependency -Reason 'synthetic pinned runtime unavailable' -FailureType DEPENDENCY_OR_RUNTIME_FAILURE
    Assert-True (-not $dependencyNotMaterialized.materialized -and -not $dependencyNotMaterialized.attempted -and -not $dependencyNotMaterialized.childStarted) 'Pre-materialization dependency failure state is invalid.'

    $invalid = Invoke-ImpeccableDetectorBoundary -Operation impeccable.detector.local -ProjectRoot $fixture -InputPath '../escape.css'
    Assert-True ($invalid.dedicatedExecution.materialized -eq $false -and $invalid.dedicatedExecution.failureType -ceq 'INVALID_INPUT' -and
        -not $invalid.dedicatedExecution.attempted -and -not $invalid.dedicatedExecution.childStarted -and
        $invalid.dedicatedExecution.dedicatedExecutionResult -ceq 'NOT_ATTEMPTED') 'Invalid input was not rejected before child start.'
    foreach ($invalidCase in @(
        @{ Result = Invoke-ImpeccableOperation -Operation 'impeccable.paid-generation.fake' -Prompt '' -OutputPath 'empty.png'; Label = 'empty fake prompt' },
        @{ Result = Invoke-ImpeccableOperation -Operation 'impeccable.context.local' -Capability critique; Label = 'missing context project' },
        @{ Result = Invoke-ImpeccableOperation -Operation 'impeccable.detector.payload' -Content 'body'; Label = 'missing payload content type' },
        @{ Result = Invoke-ImpeccableOperation -Operation 'impeccable.paid-generation.fake' -ProjectRoot $fixture -Prompt 'synthetic' -OutputPath '../escape.png'; Label = 'fake output traversal' }
    )) {
        Assert-True ($invalidCase.Result.materialized -eq $false -and $invalidCase.Result.attempted -eq $false -and
            $invalidCase.Result.childStarted -eq $false -and $invalidCase.Result.dedicatedExecution.dedicatedExecutionResult -ceq 'NOT_ATTEMPTED' -and
            $invalidCase.Result.failureType -ceq 'INVALID_INPUT' -and $invalidCase.Result.dedicatedExecution.failureType -ceq 'INVALID_INPUT') "$($invalidCase.Label) did not return the typed INVALID_INPUT envelope."
    }

    $malformedObservation = New-FtkChildProcessObservation -Capability impeccable -Operation impeccable.synthetic.malformed-output `
        -Materialized:$true -Attempted:$true -ChildStarted:$true -ExitCode 0 -StdoutText 'not-json' `
        -EnvironmentNames @('SystemRoot','TEMP','TMP') -Cleanup COMPLETED -TimeoutMilliseconds 5000
    $malformed = Complete-FtkDedicatedExecution -Capability impeccable -Operation impeccable.synthetic.malformed-output `
        -ChildObservation $malformedObservation -OutputContractValid:$false -OutputContractDiagnostic 'malformed output'
    Assert-True (-not $malformed.succeeded -and $malformed.failureType -ceq 'OUTPUT_CONTRACT_FAILURE' -and $malformed.exitCode -eq 0) 'Malformed output was not classified separately from process failure.'

    $validContext = Invoke-ImpeccableContextExtractor -Mode context -ProjectRoot $fixture -Capability critique
    $contextPayload = [ordered]@{}
    foreach ($name in @('schemaVersion','sourceFingerprint','data','advisory','requestedOperations','events')) { $contextPayload[$name] = $validContext.$name }
    $validContextJson = $contextPayload | ConvertTo-Json -Depth 30 -Compress
    $validContextObservation = New-FtkChildProcessObservation -Capability impeccable -Operation impeccable.context.local `
        -Materialized:$true -Attempted:$true -ChildStarted:$true -ExitCode 0 -StdoutText $validContextJson `
        -ContractStdoutText $validContextJson -IncludeContractOutput -EnvironmentNames @('SystemRoot','TEMP','TMP') `
        -Cleanup COMPLETED -TimeoutMilliseconds 5000
    $validContextResult = Complete-ImpeccableContextChildResult -Operation impeccable.context.local -Child $validContextObservation
    Assert-True ($validContextResult.dedicatedExecution.succeeded -and $validContextResult.requestedOperations[0].requestedOperationId -ceq 'impeccable.context.local') 'Valid context output was not accepted by the real context result path.'

    $contextVariants = @(
        @{ Label = 'invalid JSON'; Json = 'not-json'; Stderr = '' },
        @{ Label = 'shape wrong'; Json = (@{ unexpected = $true } | ConvertTo-Json -Compress); Stderr = '' },
        @{ Label = 'missing required field'; Json = (([ordered]@{ schemaVersion = $contextPayload.schemaVersion; sourceFingerprint = $contextPayload.sourceFingerprint; advisory = $contextPayload.advisory; requestedOperations = $contextPayload.requestedOperations; events = $contextPayload.events } | ConvertTo-Json -Depth 30 -Compress)); Stderr = '' },
        @{ Label = 'wrong field type'; Json = (([ordered]@{ schemaVersion = $contextPayload.schemaVersion; sourceFingerprint = $contextPayload.sourceFingerprint; data = 'wrong-type'; advisory = $contextPayload.advisory; requestedOperations = $contextPayload.requestedOperations; events = $contextPayload.events } | ConvertTo-Json -Depth 30 -Compress)); Stderr = '' },
        @{ Label = 'unexpected stderr'; Json = $validContextJson; Stderr = 'unexpected context stderr' }
    )
    foreach ($variant in $contextVariants) {
        $variantObservation = New-FtkChildProcessObservation -Capability impeccable -Operation impeccable.context.local `
            -Materialized:$true -Attempted:$true -ChildStarted:$true -ExitCode 0 -StdoutText $variant.Json `
            -ContractStdoutText $variant.Json -IncludeContractOutput -StderrText $variant.Stderr `
            -EnvironmentNames @('SystemRoot','TEMP','TMP') -Cleanup COMPLETED -TimeoutMilliseconds 5000
        $variantResult = Complete-ImpeccableContextChildResult -Operation impeccable.context.local -Child $variantObservation
        Assert-True (-not $variantResult.dedicatedExecution.succeeded -and $variantResult.dedicatedExecution.dedicatedExecutionResult -ceq 'FAILED' -and
            $variantResult.dedicatedExecution.failureType -ceq 'OUTPUT_CONTRACT_FAILURE' -and $variantResult.dedicatedExecution.exitCode -eq 0) "$($variant.Label) context output was accepted as dedicated success."
    }

    $unknown = New-FtkDedicatedExecutionResult -Capability impeccable -Operation impeccable.synthetic.unknown `
        -Materialized:$true -Attempted:$true -ChildStarted:$true -Succeeded:$false -ExitCode $null `
        -FailureType UNKNOWN_FAILURE -Evidence ([ordered]@{ source = 'synthetic-last-resort' })
    Assert-Equal $unknown.failureType 'UNKNOWN_FAILURE' 'Unknown fallback classification was not fail-closed.'
    try {
        New-FtkDedicatedExecutionResult -Capability impeccable -Operation impeccable.synthetic.impossible `
            -Materialized:$true -Attempted:$true -ChildStarted:$true -Succeeded:$false -ExitCode 0 | Out-Null
        throw 'constructor accepted the invalid failed state.'
    } catch { Assert-True ($_.Exception.Message -match 'FAILED dedicated execution requires a failure type') 'FAILED without failureType was accepted.' }
    try {
        New-FtkDedicatedExecutionResult -Capability impeccable -Operation impeccable.synthetic.impossible-success `
            -Materialized:$true -Attempted:$true -ChildStarted:$true -Succeeded:$true -ExitCode 0 -FailureType UNKNOWN_FAILURE | Out-Null
        throw 'constructor accepted the invalid succeeded state.'
    } catch { Assert-True ($_.Exception.Message -match '(?i)success|successful') 'SUCCEEDED with failureType was accepted.' }
    try {
        New-FtkDedicatedExecutionResult -Capability impeccable -Operation impeccable.synthetic.impossible-not-attempted `
            -Materialized:$false -Attempted:$false -ChildStarted:$false -Succeeded:$false -FailureType UPSTREAM_EXECUTION_FAILURE | Out-Null
        throw 'constructor accepted the invalid not-attempted state.'
    } catch { Assert-True ($_.Exception.Message -match 'NOT_ATTEMPTED') 'NOT_ATTEMPTED accepted an invalid failure type.' }
    foreach ($invalidStartedFailure in @('UPSTREAM_EXECUTION_FAILURE','TIMEOUT','OUTPUT_CONTRACT_FAILURE')) {
        try {
            New-FtkDedicatedExecutionResult -Capability impeccable -Operation "impeccable.synthetic.invalid.$invalidStartedFailure" `
                -Materialized:$true -Attempted:$true -ChildStarted:$false -Succeeded:$false `
                -FailureType $invalidStartedFailure -TimedOut:($invalidStartedFailure -ceq 'TIMEOUT') | Out-Null
            throw "$invalidStartedFailure accepted childStarted=false."
        } catch { Assert-True ($_.Exception.Message -match 'childStarted=true') "$invalidStartedFailure did not require childStarted=true." }
    }
    $legitimateStartFailure = New-FtkDedicatedExecutionResult -Capability impeccable -Operation impeccable.synthetic.start-failure `
        -Materialized:$true -Attempted:$true -ChildStarted:$false -Succeeded:$false `
        -FailureType DEPENDENCY_OR_RUNTIME_FAILURE
    Assert-True ($legitimateStartFailure.attempted -and -not $legitimateStartFailure.childStarted -and
        $legitimateStartFailure.failureType -ceq 'DEPENDENCY_OR_RUNTIME_FAILURE') 'Process.Start failure state was rejected or changed.'

    [Environment]::SetEnvironmentVariable('FTK_SYNTHETIC_PARENT_SECRET', 'synthetic-parent-secret', 'Process')
    $environmentChild = Invoke-SyntheticChild -ScriptPath $environmentScript -Operation 'impeccable.synthetic.environment'
    Assert-True ($environmentChild.environmentNames -notcontains 'FTK_SYNTHETIC_PARENT_SECRET' -and ($environmentChild.stdout -notcontains 'FTK_SYNTHETIC_PARENT_SECRET')) 'Parent secret environment crossed the child boundary.'
    Assert-True (($environmentChild | ConvertTo-Json -Depth 20) -notmatch 'synthetic-parent-secret') 'Child diagnostics exposed the synthetic parent secret.'

    $routingPolicy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/scenarios.json') | ConvertFrom-Json
    $historical = @($routingPolicy.scenarios | Where-Object id -eq 25)[0]
    Assert-Equal $historical.evidenceId 'E-011' 'Canonical E-011 fixture is missing.'
    $e011Project = Join-Path $fixture 'e011-project'
    [IO.Directory]::CreateDirectory($e011Project) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $e011Project '.impeccable')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $e011Project 'ui.css'), '.cta { color: red; }', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $e011Project '.impeccable/config.json'), '{ invalid-json', [Text.UTF8Encoding]::new($false))
    $e011Exception = $null
    try {
        & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation 'impeccable.detector.local' `
            -ProjectRoot $e011Project -InputPath 'ui.css' | Out-Null
    } catch { $e011Exception = $_.Exception }
    $e011DispatcherEnvelope = if ($null -ne $e011Exception) { $e011Exception.Data['ftkExecutionEnvelope'] } else { $null }
    Assert-True ($null -ne $e011DispatcherEnvelope) 'E-011 did not use the real dispatcher failure envelope.'
    $e011Dedicated = $e011DispatcherEnvelope.dedicatedExecution
    Assert-True ($e011Dedicated.materialized -and $e011Dedicated.attempted -and $e011Dedicated.childStarted -and
        $e011Dedicated.exitCode -eq 1 -and -not $e011Dedicated.succeeded -and
        $e011Dedicated.failureType -ceq 'UPSTREAM_EXECUTION_FAILURE') 'E-011 real dispatcher/runner path did not preserve the upstream exit-one contract.'
    $e011Routing = [ordered]@{ status = 'PASS'; selectedCapability = 'Impeccable'; evidenceId = 'E-011' }
    $e011Fallback = [ordered]@{ status = 'SUCCEEDED'; source = 'degraded-local'; dedicatedFailureRetained = $true; evidenceReduction = 'fallback-is-not-dedicated-success' }
    $e011 = New-FtkCapabilityExecutionEnvelope -Capability impeccable -Operation impeccable.detector.local `
        -PolicyStatus ALLOWED -AuthorizationDecision common-dispatcher-allowed -DedicatedExecution $e011Dedicated `
        -RoutingResult $e011Routing -FallbackResult $e011Fallback -FinalWorkflowResult PASS
    Assert-True ($e011.routing.status -ceq 'PASS' -and $e011.dedicatedExecution.attempted -and $e011.dedicatedExecution.exitCode -eq 1 -and
        -not $e011.dedicatedExecution.succeeded -and $e011.fallback.status -ceq 'SUCCEEDED' -and
        $e011.fallback.dedicatedFailureRetained -and $e011.finalWorkflowResult -ceq 'PASS' -and -not $e011.succeeded) 'E-011 did not preserve routing, dedicated execution, fallback and final workflow as separate states.'

    $dispatcherInvalid = $null
    try { & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation 'impeccable.context.local' -Capability critique | Out-Null }
    catch { $dispatcherInvalid = $_.Exception.Data['ftkExecutionEnvelope'] }
    Assert-True ($dispatcherInvalid.dedicatedExecution.failureType -ceq 'INVALID_INPUT' -and -not $dispatcherInvalid.attempted -and
        -not $dispatcherInvalid.childStarted -and $dispatcherInvalid.dedicatedExecution.dedicatedExecutionResult -ceq 'NOT_ATTEMPTED') 'Dispatcher context validation lost the INVALID_INPUT envelope.'

    $dispatcherTraversal = $null
    try { & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation 'impeccable.detector.local' -ProjectRoot $fixture -InputPath '../escape.css' | Out-Null }
    catch { $dispatcherTraversal = $_.Exception.Data['ftkExecutionEnvelope'] }
    Assert-True ($dispatcherTraversal.dedicatedExecution.failureType -ceq 'INVALID_INPUT' -and -not $dispatcherTraversal.attempted -and
        -not $dispatcherTraversal.childStarted -and $dispatcherTraversal.dedicatedExecution.dedicatedExecutionResult -ceq 'NOT_ATTEMPTED') 'Dispatcher traversal validation lost the INVALID_INPUT envelope.'

    $policyRejection = $null
    try { & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation 'impeccable.paid-generation.upstream' | Out-Null }
    catch { $policyRejection = $_.Exception.Data['ftkExecutionEnvelope'] }
    Assert-True ($null -ne $policyRejection -and $policyRejection.policy.status -ceq 'POLICY_REJECTION' -and
        $policyRejection.policy.authorizationDecision -ceq 'AUTHORIZATION_REQUIRED' -and
        -not $policyRejection.attempted -and -not $policyRejection.childStarted -and
        $policyRejection.dedicatedExecution.dedicatedExecutionResult -ceq 'NOT_ATTEMPTED' -and
        $null -eq $policyRejection.dedicatedExecution.failureType) 'Policy rejection was confused with dedicated child failure.'

    Write-Output 'PASS: typed Impeccable dedicated execution contract preserves success, compatibility, exit code and output-contract validation.'
    Write-Output 'PASS: concurrent bounded stdout/stderr capture, structured/malformed diagnostics and deterministic timeout cleanup are covered.'
    Write-Output 'PASS: dependency, invalid-input, policy-rejection and UNKNOWN states fail closed without false dedicated success.'
    Write-Output 'PASS: E-011 preserves routing PASS, dedicated failure, honest fallback and final workflow PASS as separate evidence.'
    Write-Output 'DYNAMIC TEST EXECUTED  SYNTHETIC LOCAL CHILDREN ONLY  NO UPSTREAM, NETWORK, CREDENTIAL OR PAID OPERATION'
} finally {
    [Environment]::SetEnvironmentVariable('FTK_SYNTHETIC_PARENT_SECRET', $originalSecret, 'Process')
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete($fixture, $true) }
}
