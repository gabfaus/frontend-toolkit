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
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Img2ThreejsLauncherBoundParameters = @{} + $PSBoundParameters

function Assert-AllowedImg2ThreejsParameters {
    param([Parameter(Mandatory)][string[]]$Allowed)
    $common = @([Management.Automation.Cmdlet]::CommonParameters) + @([Management.Automation.Cmdlet]::OptionalCommonParameters)
    $unexpected = @($script:Img2ThreejsLauncherBoundParameters.Keys | Where-Object { $_ -notin $Allowed -and $_ -notin $common })
    if ($unexpected.Count) { throw ('Operation received unregistered inputs: ' + ($unexpected -join ', ')) }
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
if ($definition.status -ne 'enabled') { throw ('Operation is not enabled: ' + $Operation) }

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

. (Join-Path $PSScriptRoot 'img2threejs-runner.ps1')
switch ($definition.handler) {
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
    default { throw ('Unrecognized handler is denied for operation: ' + $Operation) }
}
$result | ConvertTo-Json -Depth 20
