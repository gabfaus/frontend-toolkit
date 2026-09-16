Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DesignMotionContractSchemaVersion = 1
$script:DesignMotionFailureTypes = @(
    'INVALID_INPUT'
    'DEPENDENCY_OR_RUNTIME_FAILURE'
    'UPSTREAM_EXECUTION_FAILURE'
    'OUTPUT_CONTRACT_FAILURE'
    'TIMEOUT'
    'UNKNOWN_FAILURE'
)
$script:DesignMotionOperations = @('taste', 'review-animations', 'improve-animations', 'animate')
$script:DesignMotionSeverityValues = @('BLOCKER', 'HIGH', 'MEDIUM', 'LOW', 'INFO')
$script:DesignMotionForbiddenKeys = @(
    'outputpath'
    'planpath'
    'animationplanpath'
    'writepath'
    'projectroot'
    'projectpath'
    'browser'
    'network'
    'install'
    'installer'
    'command'
    'executable'
    'scriptpath'
    'subagent'
    'subagents'
)

function Get-DesignMotionProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return ,$null }
    if ($InputObject -is [Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return ,$InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return ,$null }
    return ,$property.Value
}

function Get-DesignMotionObjectKeys {
    param([Parameter(Mandatory)][object]$Value)

    if ($Value -is [Collections.IDictionary]) {
        return @($Value.Keys | ForEach-Object { [string]$_ })
    }
    return @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Test-DesignMotionPlainObject {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [array]) { return $false }
    if ($Value -is [Collections.IDictionary]) { return $true }
    return $Value.GetType().Name -eq 'PSCustomObject'
}

function Assert-DesignMotionPlainObject {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-DesignMotionPlainObject $Value)) {
        throw "$Label must be a JSON object."
    }
}

function Assert-DesignMotionExactKeys {
    param(
        [Parameter(Mandatory)][object]$Value,
        [AllowEmptyCollection()][string[]]$Required = @(),
        [AllowEmptyCollection()][string[]]$Optional = @(),
        [Parameter(Mandatory)][string]$Label
    )

    Assert-DesignMotionPlainObject $Value $Label
    $allowed = @($Required + $Optional)
    $keys = @(Get-DesignMotionObjectKeys $Value)
    foreach ($name in $Required) {
        if ($keys -notcontains $name) { throw "$Label is missing required key '$name'." }
    }
    foreach ($name in $keys) {
        if ($allowed -notcontains $name) { throw "$Label contains unknown key '$name'." }
    }
}

function Assert-DesignMotionInertJson {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Label,
        [int]$Depth = 0
    )

    if ($Depth -gt 20) { throw "$Label exceeds the maximum JSON nesting depth." }
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [decimal]) { return }
    if ($Value -is [single] -or $Value -is [double]) {
        if ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) {
            throw "$Label must not contain NaN or Infinity."
        }
        return
    }
    if ($Value -is [array]) {
        foreach ($item in $Value) { Assert-DesignMotionInertJson $item "$Label item" ($Depth + 1) }
        return
    }
    if (Test-DesignMotionPlainObject $Value) {
        foreach ($name in (Get-DesignMotionObjectKeys $Value)) {
            if ($name -in @('__proto__', 'prototype', 'constructor')) {
                throw "$Label contains a forbidden object key."
            }
            Assert-DesignMotionInertJson (Get-DesignMotionProperty $Value $name) "$Label.$name" ($Depth + 1)
        }
        return
    }
    throw "$Label contains a non-JSON value."
}

function Assert-DesignMotionNoForbiddenKeys {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Label,
        [int]$Depth = 0,
        [switch]$IgnoreEffects
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return }
    if ($Value -is [array]) {
        foreach ($item in $Value) { Assert-DesignMotionNoForbiddenKeys $item $Label ($Depth + 1) -IgnoreEffects:$IgnoreEffects }
        return
    }
    if (-not (Test-DesignMotionPlainObject $Value)) { return }
    foreach ($name in (Get-DesignMotionObjectKeys $Value)) {
        if ($IgnoreEffects -and $name -ceq 'effects') { continue }
        if ($script:DesignMotionForbiddenKeys -contains $name.ToLowerInvariant()) {
            throw "$Label contains an effect or persistence key that is outside the Phase 1 contract: $name."
        }
        Assert-DesignMotionNoForbiddenKeys (Get-DesignMotionProperty $Value $name) "$Label.$name" ($Depth + 1) -IgnoreEffects:$IgnoreEffects
    }
}

function Assert-DesignMotionStringArray {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowNull,
        [switch]$RequireNonEmpty
    )

    if ($null -eq $Value) {
        if ($AllowNull) { return }
        throw "$Label must be an array of strings."
    }
    if ($Value -isnot [array] -or @($Value | Where-Object { $_ -isnot [string] }).Count) {
        throw "$Label must be an array of strings."
    }
    if ($RequireNonEmpty -and @($Value).Count -eq 0) { throw "$Label must not be empty." }
    foreach ($item in $Value) {
        if ([string]::IsNullOrWhiteSpace([string]$item)) { throw "$Label must not contain empty strings." }
    }
}

function Assert-DesignMotionReference {
    param([Parameter(Mandatory)][object]$Reference)

    Assert-DesignMotionExactKeys $Reference @('id') @('kind', 'authority', 'uri', 'revision', 'label') 'context.approvedReference'
    $id = [string](Get-DesignMotionProperty $Reference 'id')
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'context.approvedReference.id must be a non-empty string.' }
    foreach ($name in @('kind', 'authority', 'uri', 'revision', 'label')) {
        $value = Get-DesignMotionProperty $Reference $name
        if ($null -ne $value -and $value -isnot [string]) { throw "context.approvedReference.$name must be a string when provided." }
    }
}

function Assert-DesignMotionAllowedDelta {
    param([AllowNull()][object]$Value)

    Assert-DesignMotionStringArray $Value 'context.allowedDelta'
    $allowed = @('none', 'timing-only', 'easing-only', 'duration-only', 'sequence-only', 'reduced-motion-only', 'direction-only')
    foreach ($item in $Value) { if ($item -notin $allowed) { throw "context.allowedDelta contains an unsupported delta: $item." } }
    if ($Value -contains 'none' -and @($Value).Count -gt 1) { throw 'context.allowedDelta=none cannot be combined with another delta.' }
}

function Assert-DesignMotionFidelityInput {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][object]$OperationInput,
        [Parameter(Mandatory)][object]$Context
    )

    if ([string](Get-DesignMotionProperty $Context 'routingMode') -ne 'FIDELITY_FIRST' -or $Operation -ne 'improve-animations') { return }
    $allowed = @(Get-DesignMotionProperty $Context 'allowedDelta')
    $checks = @(
        [pscustomobject]@{ field = 'timing'; delta = 'timing-only'; present = ($null -ne (Get-DesignMotionProperty $OperationInput 'timing')) }
        [pscustomobject]@{ field = 'easing'; delta = 'easing-only'; present = ($null -ne (Get-DesignMotionProperty $OperationInput 'easing')) }
        [pscustomobject]@{ field = 'duration'; delta = 'duration-only'; present = ($null -ne (Get-DesignMotionProperty $OperationInput 'duration')) }
        [pscustomobject]@{ field = 'sequence'; delta = 'sequence-only'; present = ($null -ne (Get-DesignMotionProperty $OperationInput 'sequence') -and @(Get-DesignMotionProperty $OperationInput 'sequence').Count -gt 0) }
        [pscustomobject]@{ field = 'reducedMotionRequirement'; delta = 'reduced-motion-only'; present = ($null -ne (Get-DesignMotionProperty $OperationInput 'reducedMotionRequirement')) }
    )
    foreach ($check in $checks) {
        if ($check.present -and $allowed -notcontains $check.delta) {
            throw "FIDELITY_FIRST input.$($check.field) exceeds context.allowedDelta."
        }
    }
}

function Assert-DesignMotionTargetValue {
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][string]$Label)

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Label must not be empty." }
        return
    }
    Assert-DesignMotionPlainObject $Value $Label
    Assert-DesignMotionInertJson $Value $Label
}

function Assert-DesignMotionContext {
    param([Parameter(Mandatory)][object]$Context)

    Assert-DesignMotionExactKeys $Context `
        @('routingMode', 'referenceAuthority', 'approvedReference', 'allowedDelta', 'target', 'constraints') @() 'context'
    Assert-DesignMotionInertJson $Context 'context'
    Assert-DesignMotionNoForbiddenKeys $Context 'context'

    $routingMode = [string](Get-DesignMotionProperty $Context 'routingMode')
    if ($routingMode -notin @('QUALITY_FIRST', 'FIDELITY_FIRST')) {
        throw 'context.routingMode must be QUALITY_FIRST or FIDELITY_FIRST.'
    }
    $authority = [string](Get-DesignMotionProperty $Context 'referenceAuthority')
    if ($authority -notin @('none', 'primary-authority')) {
        throw 'context.referenceAuthority must be none or primary-authority.'
    }
    $approved = Get-DesignMotionProperty $Context 'approvedReference'
    if ($authority -eq 'primary-authority' -and $null -eq $approved) {
        throw 'context.approvedReference is required when referenceAuthority is primary-authority.'
    }
    if ($routingMode -eq 'FIDELITY_FIRST' -and ($authority -ne 'primary-authority' -or $null -eq $approved)) {
        throw 'FIDELITY_FIRST requires referenceAuthority=primary-authority and approvedReference.'
    }
    if ($null -ne $approved) {
        Assert-DesignMotionPlainObject $approved 'context.approvedReference'
        Assert-DesignMotionReference $approved
    }
    Assert-DesignMotionAllowedDelta (Get-DesignMotionProperty $Context 'allowedDelta')
    Assert-DesignMotionPlainObject (Get-DesignMotionProperty $Context 'target') 'context.target'
    Assert-DesignMotionPlainObject (Get-DesignMotionProperty $Context 'constraints') 'context.constraints'
}

function Assert-DesignMotionFindingInput {
    param([Parameter(Mandatory)][object]$Finding, [Parameter(Mandatory)][string]$Label)

    Assert-DesignMotionExactKeys $Finding `
        @('id', 'target', 'category', 'severityHint', 'evidence') `
        @('currentState', 'recommendedState', 'rationale', 'limitations') $Label
    Assert-DesignMotionInertJson $Finding $Label
    Assert-DesignMotionNoForbiddenKeys $Finding $Label
    foreach ($name in @('id', 'category', 'severityHint')) {
        $value = [string](Get-DesignMotionProperty $Finding $name)
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$Label.$name must be a non-empty string." }
    }
    if ([string](Get-DesignMotionProperty $Finding 'severityHint').ToUpperInvariant() -notin $script:DesignMotionSeverityValues) {
        throw "$Label.severityHint is not a supported severity hint."
    }
    Assert-DesignMotionTargetValue (Get-DesignMotionProperty $Finding 'target') "$Label.target"
    Assert-DesignMotionStringArray (Get-DesignMotionProperty $Finding 'evidence') "$Label.evidence" -RequireNonEmpty
    foreach ($name in @('rationale', 'limitations')) {
        $value = Get-DesignMotionProperty $Finding $name
        if ($null -ne $value) { Assert-DesignMotionStringArray $value "$Label.$name" }
    }
    foreach ($name in @('currentState', 'recommendedState')) {
        $value = Get-DesignMotionProperty $Finding $name
        if ($null -ne $value) { Assert-DesignMotionPlainObject $value "$Label.$name" }
    }
}

function Assert-DesignMotionRequest {
    param([Parameter(Mandatory)][object]$Request)

    Assert-DesignMotionExactKeys $Request @('schemaVersion', 'operation', 'context', 'input') @() 'request'
    Assert-DesignMotionInertJson $Request 'request'
    Assert-DesignMotionNoForbiddenKeys $Request 'request'
    if ([int](Get-DesignMotionProperty $Request 'schemaVersion') -ne $script:DesignMotionContractSchemaVersion) {
        throw 'request.schemaVersion is unsupported.'
    }
    $operation = [string](Get-DesignMotionProperty $Request 'operation')
    if ($operation -notin $script:DesignMotionOperations) { throw "Unknown design-motion operation: $operation" }
    Assert-DesignMotionContext (Get-DesignMotionProperty $Request 'context')
    $requestInput = Get-DesignMotionProperty $Request 'input'
    Assert-DesignMotionPlainObject $requestInput 'request.input'

    switch ($operation) {
        'taste' {
            Assert-DesignMotionExactKeys $requestInput @() `
                @('explicitRequest', 'aestheticGap', 'surfaceType', 'designRead', 'designVariance', 'motionIntensity', 'visualDensity', 'direction', 'rationale', 'limitations') `
                'request.input'
            if ($null -ne (Get-DesignMotionProperty $requestInput 'explicitRequest') -and
                (Get-DesignMotionProperty $requestInput 'explicitRequest') -isnot [bool]) {
                throw 'request.input.explicitRequest must be boolean.'
            }
            $gap = Get-DesignMotionProperty $requestInput 'aestheticGap'
            if ($null -ne $gap) {
                Assert-DesignMotionExactKeys $gap @('material') @('description') 'request.input.aestheticGap'
                if ((Get-DesignMotionProperty $gap 'material') -isnot [bool]) { throw 'request.input.aestheticGap.material must be boolean.' }
                if ($null -ne (Get-DesignMotionProperty $gap 'description') -and
                    (Get-DesignMotionProperty $gap 'description') -isnot [string]) { throw 'request.input.aestheticGap.description must be a string.' }
            }
            $surface = Get-DesignMotionProperty $requestInput 'surfaceType'
            if ($null -ne $surface -and $surface -notin @('dashboard', 'table', 'multi-step', 'accessibility', 'responsive-layout', 'generic-ux', 'other')) {
                throw 'request.input.surfaceType is not a supported quality-first surface classification.'
            }
            $designRead = Get-DesignMotionProperty $requestInput 'designRead'
            if ($null -ne $designRead) { Assert-DesignMotionPlainObject $designRead 'request.input.designRead' }
            foreach ($name in @('designVariance', 'motionIntensity', 'visualDensity')) {
                $value = Get-DesignMotionProperty $requestInput $name
                if ($null -ne $value -and $value -isnot [string]) { throw "request.input.$name must be a string when provided." }
            }
            foreach ($name in @('direction', 'rationale', 'limitations')) {
                $value = Get-DesignMotionProperty $requestInput $name
                if ($null -ne $value) { Assert-DesignMotionStringArray $value "request.input.$name" }
            }
        }
        'review-animations' {
            Assert-DesignMotionExactKeys $requestInput @('motionRelevant') @('motion', 'findings') 'request.input'
            if ((Get-DesignMotionProperty $requestInput 'motionRelevant') -isnot [bool]) { throw 'request.input.motionRelevant must be boolean.' }
            $motion = Get-DesignMotionProperty $requestInput 'motion'
            if ($null -ne $motion) { Assert-DesignMotionPlainObject $motion 'request.input.motion' }
            if ((Get-DesignMotionProperty $requestInput 'motionRelevant') -eq $true) {
                if ($null -eq $motion) { throw 'request.input.motion is required when motionRelevant is true.' }
                Assert-DesignMotionExactKeys $motion @('evidence') @('existing', 'scope', 'source', 'summary') 'request.input.motion'
                Assert-DesignMotionStringArray (Get-DesignMotionProperty $motion 'evidence') 'request.input.motion.evidence' -RequireNonEmpty
                foreach ($name in @('existing', 'scope', 'source', 'summary')) {
                    $value = Get-DesignMotionProperty $motion $name
                    if ($name -ceq 'existing' -and $null -ne $value -and $value -isnot [bool]) { throw 'request.input.motion.existing must be boolean.' }
                    if ($name -ne 'existing' -and $null -ne $value -and $value -isnot [string]) { throw "request.input.motion.$name must be a string." }
                }
            }
            $findings = Get-DesignMotionProperty $requestInput 'findings'
            if ($null -ne $findings) {
                if ($findings -isnot [array]) { throw 'request.input.findings must be an array.' }
                for ($index = 0; $index -lt @($findings).Count; $index++) {
                    Assert-DesignMotionFindingInput $findings[$index] "request.input.findings[$index]"
                }
            }
        }
        'improve-animations' {
            Assert-DesignMotionExactKeys $requestInput @() `
                @('explicitRequest', 'concreteFinding', 'findingRefs', 'priority', 'timing', 'easing', 'duration', 'sequence', 'reducedMotionRequirement', 'acceptanceCriteria', 'limitations') `
                'request.input'
            if ($null -ne (Get-DesignMotionProperty $requestInput 'explicitRequest') -and
                (Get-DesignMotionProperty $requestInput 'explicitRequest') -isnot [bool]) {
                throw 'request.input.explicitRequest must be boolean.'
            }
            $finding = Get-DesignMotionProperty $requestInput 'concreteFinding'
            if ($null -ne $finding) { Assert-DesignMotionFindingInput $finding 'request.input.concreteFinding' }
            $refs = Get-DesignMotionProperty $requestInput 'findingRefs'
            if ($null -ne $refs) { Assert-DesignMotionStringArray $refs 'request.input.findingRefs' }
            foreach ($name in @('priority', 'easing')) {
                $value = Get-DesignMotionProperty $requestInput $name
                if ($null -ne $value -and $value -isnot [string]) { throw "request.input.$name must be a string when provided." }
            }
            $timing = Get-DesignMotionProperty $requestInput 'timing'
            if ($null -ne $timing) { Assert-DesignMotionPlainObject $timing 'request.input.timing' }
            $duration = Get-DesignMotionProperty $requestInput 'duration'
            if ($null -ne $duration -and ($duration -isnot [int] -and $duration -isnot [long] -and $duration -isnot [double] -and $duration -isnot [decimal])) {
                throw 'request.input.duration must be numeric when provided.'
            }
            $sequence = Get-DesignMotionProperty $requestInput 'sequence'
            if ($null -ne $sequence) { Assert-DesignMotionStringArray $sequence 'request.input.sequence' }
            $reduced = Get-DesignMotionProperty $requestInput 'reducedMotionRequirement'
            if ($null -ne $reduced) { Assert-DesignMotionPlainObject $reduced 'request.input.reducedMotionRequirement' }
            $criteria = Get-DesignMotionProperty $requestInput 'acceptanceCriteria'
            if ($null -ne $criteria) { Assert-DesignMotionStringArray $criteria 'request.input.acceptanceCriteria' }
            $limitations = Get-DesignMotionProperty $requestInput 'limitations'
            if ($null -ne $limitations) { Assert-DesignMotionStringArray $limitations 'request.input.limitations' }
        }
        'animate' {
            Assert-DesignMotionExactKeys $requestInput @() @() 'request.input'
        }
    }
    Assert-DesignMotionFidelityInput -Operation $operation -OperationInput $requestInput -Context (Get-DesignMotionProperty $Request 'context')
    return $true
}

function ConvertTo-DesignMotionSortedValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [array]) { return @($Value | ForEach-Object { ConvertTo-DesignMotionSortedValue $_ }) }
    if (Test-DesignMotionPlainObject $Value) {
        $ordered = [ordered]@{}
        $names = New-Object Collections.Generic.List[string]
        foreach ($name in @(Get-DesignMotionObjectKeys $Value)) { [void]$names.Add([string]$name) }
        $names.Sort([StringComparer]::Ordinal)
        foreach ($name in $names) {
            $ordered[$name] = ConvertTo-DesignMotionSortedValue (Get-DesignMotionProperty $Value $name)
        }
        return $ordered
    }
    throw 'Cannot canonicalize a non-JSON value.'
}

function ConvertTo-DesignMotionCanonicalJson {
    param([AllowNull()][object]$Value)

    Assert-DesignMotionInertJson $Value 'canonical value'
    return (ConvertTo-DesignMotionSortedValue $Value | ConvertTo-Json -Compress -Depth 50)
}

function ConvertTo-DesignMotionJsonClone {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    return (($Value | ConvertTo-Json -Compress -Depth 50) | ConvertFrom-Json)
}

function Assert-DesignMotionEffects {
    param([Parameter(Mandatory)][object]$Effects)

    Assert-DesignMotionExactKeys $Effects `
        @('network', 'browser', 'install', 'projectWrite', 'projectExecution', 'upstreamExecution', 'subagentInvocation') @() 'output.effects'
    foreach ($name in (Get-DesignMotionObjectKeys $Effects)) {
        $value = Get-DesignMotionProperty $Effects $name
        if (($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64] -and
             $value -isnot [uint16] -and $value -isnot [uint32] -and $value -isnot [uint64] -and $value -isnot [single] -and
             $value -isnot [double] -and $value -isnot [decimal]) -or [double]$value -ne 0) {
            throw "output.effects.$name must be the numeric value zero in Phase 1."
        }
    }
}

function Assert-DesignMotionOutputFinding {
    param([Parameter(Mandatory)][object]$Finding, [Parameter(Mandatory)][string]$Label)

    Assert-DesignMotionExactKeys $Finding `
        @('id', 'target', 'category', 'normalizedSeverity', 'evidence', 'currentState', 'recommendedState', 'rationale', 'limitations') @() $Label
    Assert-DesignMotionTargetValue (Get-DesignMotionProperty $Finding 'target') "$Label.target"
    foreach ($name in @('id', 'category')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-DesignMotionProperty $Finding $name))) { throw "$Label.$name must be non-empty." }
    }
    if ([string](Get-DesignMotionProperty $Finding 'normalizedSeverity') -notin $script:DesignMotionSeverityValues) {
        throw "$Label.normalizedSeverity is not a FTK-owned severity."
    }
    Assert-DesignMotionStringArray (Get-DesignMotionProperty $Finding 'evidence') "$Label.evidence" -RequireNonEmpty
    foreach ($name in @('rationale', 'limitations')) { Assert-DesignMotionStringArray (Get-DesignMotionProperty $Finding $name) "$Label.$name" }
    foreach ($name in @('currentState', 'recommendedState')) {
        $value = Get-DesignMotionProperty $Finding $name
        if ($null -ne $value) { Assert-DesignMotionPlainObject $value "$Label.$name" }
    }
}

function Assert-DesignMotionOutputContract {
    param(
        [Parameter(Mandatory)][object]$Output,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][ValidateSet('QUALITY_FIRST', 'FIDELITY_FIRST')][string]$ExpectedRoutingMode,
        [Parameter(Mandatory)][ValidateSet('none', 'primary-authority')][string]$ExpectedReferenceAuthority,
        [AllowNull()][object]$ExpectedApprovedReference = $null,
        [AllowEmptyCollection()][string[]]$ExpectedAllowedDelta = $null
    )

    Assert-DesignMotionPlainObject $Output 'output'
    Assert-DesignMotionInertJson $Output 'output'
    Assert-DesignMotionNoForbiddenKeys $Output 'output' -IgnoreEffects
    $common = @('schemaVersion', 'adapter', 'operation', 'status', 'routingMode', 'referenceAuthority', 'approvedReference', 'allowedDelta', 'sourceFingerprint', 'effects', 'limitations')
    $extra = switch ($Operation) {
        'taste' { @('designRead', 'designVariance', 'motionIntensity', 'visualDensity', 'direction', 'rationale') }
        'review-animations' { @('findings', 'decision') }
        'improve-animations' { @('plan') }
        default { throw 'animate has no Phase 1 output contract.' }
    }
    Assert-DesignMotionExactKeys $Output $common $extra 'output'
    if ([int](Get-DesignMotionProperty $Output 'schemaVersion') -ne $script:DesignMotionContractSchemaVersion) { throw 'output.schemaVersion is unsupported.' }
    if ([string](Get-DesignMotionProperty $Output 'adapter') -cne 'ftk-owned-design-motion-adapter') { throw 'output.adapter is not FTK-owned.' }
    if ([string](Get-DesignMotionProperty $Output 'operation') -cne $Operation) { throw 'output.operation does not match the request.' }
    if ([string](Get-DesignMotionProperty $Output 'sourceFingerprint') -cne $SourceFingerprint) { throw 'output.sourceFingerprint does not match verified source.' }
    if ([string](Get-DesignMotionProperty $Output 'routingMode') -notin @('QUALITY_FIRST', 'FIDELITY_FIRST')) { throw 'output.routingMode is invalid.' }
    if ([string](Get-DesignMotionProperty $Output 'referenceAuthority') -notin @('none', 'primary-authority')) { throw 'output.referenceAuthority is invalid.' }
    if ([string](Get-DesignMotionProperty $Output 'routingMode') -cne $ExpectedRoutingMode) { throw 'output.routingMode does not match the request.' }
    if ([string](Get-DesignMotionProperty $Output 'referenceAuthority') -cne $ExpectedReferenceAuthority) { throw 'output.referenceAuthority does not match the request.' }
    if ([string](Get-DesignMotionProperty $Output 'routingMode') -eq 'FIDELITY_FIRST' -and [string](Get-DesignMotionProperty $Output 'referenceAuthority') -cne 'primary-authority') {
        throw 'FIDELITY_FIRST output degraded its reference authority.'
    }
    if ([string](Get-DesignMotionProperty $Output 'sourceFingerprint') -notmatch '^[0-9a-f]{64}$') { throw 'output.sourceFingerprint must be a SHA-256 string.' }
    $actualAllowedDelta = Get-DesignMotionProperty $Output 'allowedDelta'
    Assert-DesignMotionStringArray $actualAllowedDelta 'output.allowedDelta'
    if ($PSBoundParameters.ContainsKey('ExpectedAllowedDelta')) {
        $expectedDeltaJson = ConvertTo-DesignMotionCanonicalJson $ExpectedAllowedDelta
        $actualDeltaJson = ConvertTo-DesignMotionCanonicalJson $actualAllowedDelta
        if ($expectedDeltaJson -cne $actualDeltaJson) { throw 'output.allowedDelta does not match the request.' }
    }
    if ($PSBoundParameters.ContainsKey('ExpectedApprovedReference')) {
        $expectedReferenceJson = if ($null -eq $ExpectedApprovedReference) { 'null' } else { ConvertTo-DesignMotionCanonicalJson $ExpectedApprovedReference }
        $actualReference = Get-DesignMotionProperty $Output 'approvedReference'
        $actualReferenceJson = if ($null -eq $actualReference) { 'null' } else { ConvertTo-DesignMotionCanonicalJson $actualReference }
        if ($expectedReferenceJson -cne $actualReferenceJson) { throw 'output.approvedReference does not match the request.' }
    }
    Assert-DesignMotionStringArray (Get-DesignMotionProperty $Output 'limitations') 'output.limitations'
    Assert-DesignMotionEffects (Get-DesignMotionProperty $Output 'effects')

    switch ($Operation) {
        'taste' {
            if ([string](Get-DesignMotionProperty $Output 'status') -notin @('ADVISORY', 'NOT_APPLICABLE')) { throw 'Taste output status is invalid.' }
            if ([string](Get-DesignMotionProperty $Output 'status') -eq 'ADVISORY') {
                Assert-DesignMotionPlainObject (Get-DesignMotionProperty $Output 'designRead') 'output.designRead'
            }
            foreach ($name in @('direction', 'rationale')) { Assert-DesignMotionStringArray (Get-DesignMotionProperty $Output $name) "output.$name" }
            foreach ($name in @('designVariance', 'motionIntensity', 'visualDensity')) {
                $value = Get-DesignMotionProperty $Output $name
                if ($null -ne $value -and $value -isnot [string]) { throw "output.$name must be a string or null." }
            }
        }
        'review-animations' {
            if ([string](Get-DesignMotionProperty $Output 'status') -notin @('COMPLETE', 'NOT_APPLICABLE')) { throw 'Review output status is invalid.' }
            if ([string](Get-DesignMotionProperty $Output 'decision') -notin @('APPROVE', 'BLOCK', 'NOT_APPLICABLE')) { throw 'Review decision is invalid.' }
            $findings = Get-DesignMotionProperty $Output 'findings'
            if ($findings -isnot [array]) { throw 'Review findings must be an array.' }
            for ($index = 0; $index -lt @($findings).Count; $index++) { Assert-DesignMotionOutputFinding $findings[$index] "output.findings[$index]" }
        }
        'improve-animations' {
            if ([string](Get-DesignMotionProperty $Output 'status') -notin @('PLAN', 'NOT_APPLICABLE')) { throw 'Improve output status is invalid.' }
            $plan = Get-DesignMotionProperty $Output 'plan'
            if ([string](Get-DesignMotionProperty $Output 'status') -eq 'NOT_APPLICABLE') {
                if ($null -ne $plan) { throw 'NOT_APPLICABLE improve output must not contain a plan.' }
            } else {
                Assert-DesignMotionExactKeys $plan `
                    @('findingRefs', 'priority', 'timing', 'easing', 'duration', 'sequence', 'reducedMotionRequirement', 'acceptanceCriteria', 'limitations', 'planPersistence') @() 'output.plan'
                Assert-DesignMotionStringArray (Get-DesignMotionProperty $plan 'findingRefs') 'output.plan.findingRefs'
                Assert-DesignMotionStringArray (Get-DesignMotionProperty $plan 'sequence') 'output.plan.sequence'
                Assert-DesignMotionStringArray (Get-DesignMotionProperty $plan 'acceptanceCriteria') 'output.plan.acceptanceCriteria'
                Assert-DesignMotionStringArray (Get-DesignMotionProperty $plan 'limitations') 'output.plan.limitations'
                if ([string](Get-DesignMotionProperty $plan 'planPersistence') -cne 'INLINE_ONLY') { throw 'Improve plan persistence must be INLINE_ONLY.' }
                $priority = Get-DesignMotionProperty $plan 'priority'
                if ($null -ne $priority -and $priority -isnot [string]) { throw 'output.plan.priority must be a string or null.' }
                foreach ($name in @('timing', 'reducedMotionRequirement')) {
                    $value = Get-DesignMotionProperty $plan $name
                    if ($null -ne $value) { Assert-DesignMotionPlainObject $value "output.plan.$name" }
                }
                foreach ($name in @('easing')) {
                    $value = Get-DesignMotionProperty $plan $name
                    if ($null -ne $value -and $value -isnot [string]) { throw "output.plan.$name must be a string or null." }
                }
                $duration = Get-DesignMotionProperty $plan 'duration'
                if ($null -ne $duration -and ($duration -isnot [int] -and $duration -isnot [long] -and $duration -isnot [double] -and $duration -isnot [decimal])) {
                    throw 'output.plan.duration must be numeric or null.'
                }
            }
        }
    }
    return $true
}

function Get-DesignMotionFailureTypes { return @($script:DesignMotionFailureTypes) }
function Get-DesignMotionContractSchemaVersion { return $script:DesignMotionContractSchemaVersion }
