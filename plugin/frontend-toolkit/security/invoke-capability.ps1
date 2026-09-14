[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
    [string]$ProjectRoot,
    [string]$ConfigPath,
    [string]$StatePath = '.img2threejs/state.json',
    [string]$Reference,
    [ValidateSet('generic','cs2','character')][string]$Profile = 'generic',
    [string]$Spec = '',
    [ValidateRange(1,100)][int]$MaxPerPass = 3,
    [ValidateRange(1,100)][int]$MaxTotal = 6,
    [string[]]$Step,
    [ValidateSet('done','skipped','pending')][string]$MarkStatus = 'done',
    [string[]]$Evidence,
    [string]$Reason = '',
    [AllowEmptyString()][string]$JsonText,
    [switch]$SkipSplat,
    [switch]$SkipBuild,
    [string]$Capability,
    [string]$InputPath,
    [string]$EventJson,
    [AllowEmptyString()][string]$Content,
    [ValidateSet('html','css','scss','sass','less','jsx','tsx','js','ts','vue','svelte','astro')][string]$ContentType,
    [string]$DetectorOptionsJson,
    [string]$Scope,
    [string]$Key,
    [string]$Mode,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Img2ThreejsLauncherBoundParameters = @{} + $PSBoundParameters

$executionContractPath = Join-Path $PSScriptRoot 'execution-contract.ps1'
if (-not (Test-Path -LiteralPath $executionContractPath -PathType Leaf)) { throw 'FTK execution contract is missing.' }
. $executionContractPath

function Assert-AllowedImg2ThreejsParameters {
    param([Parameter(Mandatory)][string[]]$Allowed)
    $common = @([Management.Automation.Cmdlet]::CommonParameters) + @([Management.Automation.Cmdlet]::OptionalCommonParameters)
    $unexpected = @($script:Img2ThreejsLauncherBoundParameters.Keys | Where-Object { $_ -notin $Allowed -and $_ -notin $common })
    if ($unexpected.Count) { throw ('Operation received unregistered inputs: ' + ($unexpected -join ', ')) }
}

function Throw-FtkPolicyRejection {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$AuthorizationDecision,
        [Parameter(Mandatory)][string]$Message
    )

    $capability = if ($Definition.skill) { [string]$Definition.skill } else { 'unknown' }
    $envelope = New-FtkPolicyRejectionEnvelope -Capability $capability -Operation $Operation `
        -AuthorizationDecision $AuthorizationDecision -Reason $Message
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['ftkExecutionEnvelope'] = $envelope
    throw $exception
}

$policyPath = Join-Path $PSScriptRoot 'effect-policy.json'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { throw 'FTK capability/effect policy is missing.' }
$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
if ($policy.architecture -ne 'mediated-adapter' -or $policy.unknownEffectPolicy -ne 'deny') {
    throw 'FTK capability boundary is not fail-closed.'
}
$definition = @($policy.operations | Where-Object id -CEQ $Operation)
if ($definition.Count -ne 1) { throw ('UNKNOWN operation is not registered and is denied: ' + $Operation) }
$definition = $definition[0]
foreach ($effect in @($definition.effects)) {
    if ($effect -notin @($policy.effectClasses) -or $effect -eq 'UNKNOWN') {
        throw ('UNKNOWN effect is fail-closed for operation: ' + $Operation)
    }
}
if ($definition.skill -ceq 'impeccable' -and $definition.status -cne 'enabled') {
    $allowed = @('Operation','PlanOnly')
    if ($Operation -in @('impeccable.live.loopback','impeccable.hooks.status','impeccable.hooks.enable','impeccable.hooks.disable','impeccable.hooks.ignore','impeccable.hooks.reset','impeccable.detector.local','impeccable.detector.project','impeccable.detector.csp','impeccable.detector.loopback','impeccable.paid-generation.fake','impeccable.paid-generation.upstream','impeccable.doctor.report')) {
        $allowed += 'ProjectRoot'
    }
    if ($Operation -ceq 'impeccable.detector.browser-file') {
        $allowed += @('ProjectRoot','InputPath','DetectorOptionsJson')
        if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($InputPath) -or
            [IO.Path]::IsPathRooted($InputPath) -or $InputPath -match '(^|[\\/])\.\.([\\/]|$)' -or
            [IO.Path]::GetExtension($InputPath).ToLowerInvariant() -notin @('.html','.htm')) {
            Throw-FtkInvalidInput -Capability $definition.skill -Operation $Operation `
                -Reason 'Browser-file detector requires one relative contained HTML InputPath and ProjectRoot.'
        }
        if ($DetectorOptionsJson -and $DetectorOptionsJson.Length -gt 65536) {
            Throw-FtkInvalidInput -Capability $definition.skill -Operation $Operation -Reason 'DetectorOptionsJson exceeds the 64 KiB limit.'
        }
    }
    if ($definition.skill -ceq 'impeccable') {
        try { Assert-AllowedImg2ThreejsParameters $allowed }
        catch { Throw-FtkInvalidInput -Capability $definition.skill -Operation $Operation -Reason $_.Exception.Message }
    } else { Assert-AllowedImg2ThreejsParameters $allowed }
    $decision = if ($definition.status.StartsWith('authorization-required', [StringComparison]::Ordinal)) {
        'authorization-required'
    } elseif ($definition.status.StartsWith('explicitly-denied', [StringComparison]::Ordinal)) {
        'denied'
    } else {
        'blocked'
    }
    if ($PlanOnly) {
        [pscustomobject][ordered]@{
            schemaVersion = $policy.schemaVersion
            operation = $definition.id
            skill = $definition.skill
            effects = @($definition.effects)
            authorizationDecision = $decision
            authorizationRequirement = $definition.authorizationRequirement
            handler = $definition.handler
            handlerInvoked = $false
            execution = New-FtkCapabilityExecutionEnvelope -Capability $definition.skill -Operation $definition.id `
                -PolicyStatus POLICY_REJECTION -AuthorizationDecision $decision
        } | ConvertTo-Json -Depth 8
        return
    }
    if ($decision -ceq 'authorization-required') {
        Throw-FtkPolicyRejection -Operation $Operation -Definition $definition `
            -AuthorizationDecision AUTHORIZATION_REQUIRED `
            -Message ('AUTHORIZATION_REQUIRED: no non-forgeable host grant is available for operation ' + $Operation + '.')
    }
    Throw-FtkPolicyRejection -Operation $Operation -Definition $definition `
        -AuthorizationDecision DENIED -Message ('Operation is not enabled: ' + $Operation)
}
if ($definition.status -ne 'enabled') {
    if ($PlanOnly) {
        $planDecision = if ($definition.status.StartsWith('authorization-required', [StringComparison]::Ordinal)) { 'AUTHORIZATION_REQUIRED' } else { 'DENIED' }
        [pscustomobject][ordered]@{
            schemaVersion = $policy.schemaVersion
            operation = $definition.id
            skill = $definition.skill
            capability = $definition.capability
            effects = @($definition.effects)
            availability = if ($definition.availability) { $definition.availability } else { 'blocked' }
            authorizationDecision = if ($definition.status.StartsWith('authorization-required', [StringComparison]::Ordinal)) { 'authorization-required' } else { 'denied' }
            authorizationRequirement = $definition.authorizationRequirement
            handler = $definition.handler
            handlerInvoked = $false
            externalCall = $false
            execution = New-FtkCapabilityExecutionEnvelope -Capability $definition.skill -Operation $definition.id `
                -PolicyStatus POLICY_REJECTION -AuthorizationDecision $planDecision
        } | ConvertTo-Json -Depth 12
        return
    }
    if ($definition.status.StartsWith('authorization-required', [StringComparison]::Ordinal)) {
        Throw-FtkPolicyRejection -Operation $Operation -Definition $definition `
            -AuthorizationDecision AUTHORIZATION_REQUIRED `
            -Message ('AUTHORIZATION_REQUIRED: no non-forgeable host grant is available for operation ' + $Operation + '.')
    }
    Throw-FtkPolicyRejection -Operation $Operation -Definition $definition `
        -AuthorizationDecision DENIED -Message ('Operation is not enabled: ' + $Operation)
}

if ($definition.handler -eq 'builtin.capability-summary') {
    Assert-AllowedImg2ThreejsParameters @('Operation')
    $skill = $policy.skills.PSObject.Properties[$definition.skill].Value
    [pscustomobject][ordered]@{
        schemaVersion = $policy.schemaVersion
        architecture = $policy.architecture
        operation = $definition.id
        skill = $definition.skill
        effect = $definition.effect
        effects = @($definition.effects)
        capabilities = @($skill.capabilities)
        upstreamExecuted = $false
    } | ConvertTo-Json -Depth 8
    return
}

if ($definition.skill -ceq 'img2threejs') { . (Join-Path $PSScriptRoot 'img2threejs-runner.ps1') }
if ($definition.skill -ceq 'impeccable') { . (Join-Path $PSScriptRoot 'impeccable-runner.ps1') }
switch ($definition.handler) {
    'ftk.impeccable.operation' {
        $allowed = @('Operation','PlanOnly')
        if ($Operation -ceq 'impeccable.context.local') { $allowed += @('ProjectRoot','Capability') }
        if ($Operation -in @('impeccable.detector.local','impeccable.detector.project')) { $allowed += @('ProjectRoot','InputPath','DetectorOptionsJson') }
        if ($Operation -ceq 'impeccable.detector.payload') { $allowed += @('Content','ContentType','DetectorOptionsJson') }
        if ($Operation -ceq 'impeccable.detector.csp') { $allowed += 'ProjectRoot' }
        if ($Operation -in @('impeccable.hooks.status','impeccable.doctor.report')) { $allowed += 'ProjectRoot' }
        if ($Operation -ceq 'impeccable.live.event-mediate') { $allowed += 'EventJson' }
        if ($Operation -ceq 'impeccable.concept.local-fallback') { $allowed += @('Scope','Key','Mode') }
        try { Assert-AllowedImg2ThreejsParameters $allowed }
        catch { Throw-FtkInvalidInput -Capability 'impeccable' -Operation $Operation -Reason $_.Exception.Message }
        $arguments = @{ Operation = $Operation; PlanOnly = $PlanOnly }
        if ($Operation -ceq 'impeccable.context.local') { $arguments.ProjectRoot = $ProjectRoot; $arguments.Capability = $Capability }
        if ($Operation -in @('impeccable.detector.local','impeccable.detector.project')) { $arguments.ProjectRoot = $ProjectRoot; $arguments.InputPath = $InputPath; $arguments.DetectorOptionsJson = $DetectorOptionsJson }
        if ($Operation -ceq 'impeccable.detector.payload') { $arguments.Content = $Content; $arguments.ContentType = $ContentType; $arguments.DetectorOptionsJson = $DetectorOptionsJson }
        if ($Operation -ceq 'impeccable.detector.csp') { $arguments.ProjectRoot = $ProjectRoot }
        if ($Operation -in @('impeccable.hooks.status','impeccable.doctor.report')) { $arguments.ProjectRoot = $ProjectRoot }
        if ($Operation -ceq 'impeccable.live.event-mediate') { $arguments.EventJson = $EventJson }
        if ($Operation -ceq 'impeccable.concept.local-fallback') { $arguments.Scope = $Scope; $arguments.Key = $Key; $arguments.Mode = $Mode }
        $result = Invoke-ImpeccableOperation @arguments
    }
    'ftk.img2threejs.glb-pipeline' {
        Assert-AllowedImg2ThreejsParameters @('Operation','ProjectRoot','ConfigPath','SkipSplat','SkipBuild','PlanOnly')
        if (-not $ProjectRoot -or -not $ConfigPath) { throw 'glb-pipeline requires ProjectRoot and ConfigPath.' }
        $result = Invoke-Img2ThreejsPipeline -ProjectRoot $ProjectRoot -ConfigPath $ConfigPath -SkipSplat:$SkipSplat -SkipBuild:$SkipBuild -PlanOnly:$PlanOnly
    }
    'ftk.img2threejs.project-code' {
        $allowed = @('Operation','ProjectRoot','PlanOnly')
        if ($Operation -eq 'img2threejs.codec-verify') { $allowed += 'ConfigPath' }
        Assert-AllowedImg2ThreejsParameters $allowed
        if (-not $ProjectRoot) { throw "$Operation requires ProjectRoot." }
        $result = Invoke-Img2ThreejsProjectCodeOperation -Operation $Operation -ProjectRoot $ProjectRoot -ConfigPath $ConfigPath -PlanOnly:$PlanOnly
    }
    'ftk.img2threejs.state' {
        $allowed = @('Operation','ProjectRoot','StatePath')
        if ($Operation -eq 'img2threejs.state.init') { $allowed += @('Reference','Profile','Spec','MaxPerPass','MaxTotal') }
        if ($Operation -eq 'img2threejs.state.mark') { $allowed += @('Step','MarkStatus','Evidence','Reason') }
        if ($Operation -in @('img2threejs.state.create','img2threejs.state.write','img2threejs.state.update')) { $allowed += 'JsonText' }
        Assert-AllowedImg2ThreejsParameters $allowed
        if (-not $ProjectRoot) { throw "$Operation requires ProjectRoot." }
        $result = Invoke-Img2ThreejsStateOperation -Operation $Operation -ProjectRoot $ProjectRoot -StatePath $StatePath `
            -Reference $Reference -Profile $Profile -Spec $Spec -MaxPerPass $MaxPerPass -MaxTotal $MaxTotal `
            -Step $Step -MarkStatus $MarkStatus -Evidence $Evidence -Reason $Reason -JsonText $JsonText
    }
    'ftk.request-only' {
        Assert-AllowedImg2ThreejsParameters @('Operation','PlanOnly')
        [pscustomobject][ordered]@{
            schemaVersion = $policy.schemaVersion
            architecture = $policy.architecture
            operation = $definition.id
            skill = $definition.skill
            capability = $definition.capability
            effects = @($definition.effects)
            availability = if ($definition.availability) { $definition.availability } else { 'available' }
            execution = 'not-performed'
            handlerInvoked = $false
            externalCall = $false
            requestOnly = $true
            authorizationDecision = 'request-created-no-effect-grant'
            authorizationRequirement = $definition.authorizationRequirement
            transport = $definition.transport
        } | ConvertTo-Json -Depth 12
        return
    }
    default { throw ('Unrecognized handler is denied for operation: ' + $Operation) }
}
$dedicated = Get-FtkPropertyValue $result 'dedicatedExecution'
$failureType = Get-FtkPropertyValue $dedicated 'failureType'
if (-not [string]::IsNullOrWhiteSpace([string]$failureType)) {
    $diagnostics = Get-FtkPropertyValue $dedicated 'diagnostics'
    $detail = $null
    foreach ($candidate in @(
        (Get-FtkPropertyValue $diagnostics 'message')
        (Get-FtkPropertyValue (Get-FtkPropertyValue $diagnostics 'outputContract') 'message')
        (Get-FtkPropertyValue (Get-FtkPropertyValue $diagnostics 'structuredStderr') 'error')
        ((@((Get-FtkPropertyValue $diagnostics 'stderr')) | Select-Object -First 1))
        (Get-FtkPropertyValue $diagnostics 'failureMessage')
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { $detail = [string]$candidate; break }
    }
    $message = 'DEDICATED_EXECUTION_FAILURE: ' + [string]$failureType
    if ($detail) { $message += ': ' + (ConvertTo-FtkBoundedDiagnostic -Value $detail -MaximumCharacters 2048) }
    $envelope = New-FtkCapabilityExecutionEnvelope -Capability $definition.skill -Operation $Operation `
        -PolicyStatus ALLOWED -AuthorizationDecision 'common-dispatcher-allowed' -DedicatedExecution $dedicated
    $exception = [InvalidOperationException]::new($message)
    $exception.Data['ftkExecutionEnvelope'] = $envelope
    throw $exception
}
$result | ConvertTo-Json -Depth 20
