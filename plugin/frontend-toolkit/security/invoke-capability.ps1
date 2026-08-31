[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$policyPath = Join-Path $PSScriptRoot 'effect-policy.json'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw 'FTK capability/effect policy is missing.'
}
$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
if ($policy.architecture -ne 'mediated-adapter' -or $policy.unknownEffectPolicy -ne 'deny') {
    throw 'FTK capability boundary is not fail-closed.'
}

$definition = @($policy.operations | Where-Object id -CEQ $Operation)
if ($definition.Count -ne 1) {
    throw ('UNKNOWN operation is not registered and is denied: ' + $Operation)
}
$definition = $definition[0]
if ($definition.effect -notin @($policy.effectClasses) -or $definition.effect -eq 'UNKNOWN') {
    throw ('UNKNOWN effect is fail-closed for operation: ' + $Operation)
}
if ($definition.status -ne 'enabled') {
    throw ('Operation is not enabled: ' + $Operation)
}
if ($definition.handler -ne 'builtin.capability-summary') {
    throw ('Unrecognized handler is denied for operation: ' + $Operation)
}

$skill = $policy.skills.PSObject.Properties[$definition.skill].Value
[pscustomobject][ordered]@{
    schemaVersion = $policy.schemaVersion
    architecture = $policy.architecture
    operation = $definition.id
    skill = $definition.skill
    effect = $definition.effect
    capabilities = @($skill.capabilities)
    upstreamExecuted = $false
} | ConvertTo-Json -Depth 5
