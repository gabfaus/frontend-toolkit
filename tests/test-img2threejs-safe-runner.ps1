Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/external-prerequisite.ps1')
Assert-FtkExternalPrerequisite
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
. (Join-Path $securityRoot 'img2threejs-runner.ps1')

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    try { & $Action; throw "$Label did not fail closed." }
    catch {
        if ($_.Exception.Message -eq "$Label did not fail closed.") { throw }
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Label returned the wrong error: $($_.Exception.Message)" }
    }
}

function Write-SyntheticGlb {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][int]$NodeCount)
    $nodes = @(1..$NodeCount | ForEach-Object { @{} })
    $json = ([ordered]@{ asset = [ordered]@{ version = '2.0' }; nodes = $nodes } | ConvertTo-Json -Compress -Depth 5)
    while (($json.Length % 4) -ne 0) { $json += ' ' }
    $jsonBytes = [Text.Encoding]::UTF8.GetBytes($json)
    $length = 12 + 8 + $jsonBytes.Length
    $stream = New-Object IO.FileStream($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('glTF'))
        $writer.Write([uint32]2)
        $writer.Write([uint32]$length)
        $writer.Write([uint32]$jsonBytes.Length)
        $writer.Write([uint32]0x4E4F534A)
        $writer.Write($jsonBytes)
    } finally { $writer.Dispose(); $stream.Dispose() }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-img2threejs-runner-' + [guid]::NewGuid().ToString('N'))
try {
    $project = Join-Path $fixture 'project'
    [IO.Directory]::CreateDirectory((Join-Path $project 'public/mesh')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $project 'configs')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $project 'src/demos/subject')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'reference.png'), 'synthetic')
    [IO.File]::WriteAllText((Join-Path $project 'src/demos/subject/surfaceCodec.ts'), 'export function decodeSurfaces() { return []; }')
    Write-SyntheticGlb -LiteralPath (Join-Path $project 'public/mesh/subject.glb') -NodeCount 3
    [IO.File]::WriteAllText((Join-Path $project 'configs/regions.json'), '{"0":"body","2":"head"}')
    [IO.File]::WriteAllText((Join-Path $project 'configs/cells.json'), '{"0":0.02,"2":0.01}')
    [IO.File]::WriteAllText((Join-Path $project 'configs/sections.json'), '{"0":"BODY","2":"HEAD"}')
    [IO.File]::WriteAllText((Join-Path $project 'configs/spokes.json'), '{"0":32,"2":64}')

    $environmentProbe = Join-Path $project 'environment-probe.py'
    [IO.File]::WriteAllText($environmentProbe, @'
import json
import os
import sys

print(json.dumps({
    "allowed": os.environ.get("CHARACTER_DEMO_ID"),
    "argv": sys.argv[1:],
    "secret": os.environ.get("FTK_SR2D_SYNTHETIC_SECRET"),
}))
'@)
    $secretName = 'FTK_SR2D_SYNTHETIC_SECRET'
    $secretValue = 'synthetic-secret-must-not-cross-boundary'
    $originalSecret = [Environment]::GetEnvironmentVariable($secretName, 'Process')
    $originalCharacterDemo = [Environment]::GetEnvironmentVariable('CHARACTER_DEMO_ID', 'Process')
    try {
        [Environment]::SetEnvironmentVariable($secretName, $secretValue, 'Process')
        [Environment]::SetEnvironmentVariable('CHARACTER_DEMO_ID', 'parent-value', 'Process')
        $parentBefore = [Environment]::GetEnvironmentVariables('Process')
        $expectedNativeArgv = @('', 'space value', 'quote"value', 'trailing\')
        $probeOne = Invoke-Img2ThreejsTrustedNative python (@($environmentProbe) + $expectedNativeArgv) $project ([ordered]@{ CHARACTER_DEMO_ID = 'child-one' })
        $probeTwo = Invoke-Img2ThreejsTrustedNative python @($environmentProbe) $project ([ordered]@{ CHARACTER_DEMO_ID = 'child-two' })
        $parentAfter = [Environment]::GetEnvironmentVariables('Process')
        if ($parentBefore.Count -ne $parentAfter.Count) { throw 'Child launch changed parent environment size.' }
        foreach ($key in $parentBefore.Keys) {
            if (-not $parentAfter.Contains($key) -or [string]$parentAfter[$key] -cne [string]$parentBefore[$key]) {
                throw "Child launch changed parent environment value $key."
            }
        }
        $probeOneJson = $probeOne.stdout -join '' | ConvertFrom-Json
        $probeTwoJson = $probeTwo.stdout -join '' | ConvertFrom-Json
        if ($null -ne $probeOneJson.secret -or $null -ne $probeTwoJson.secret) { throw 'Synthetic parent secret crossed into a child.' }
        if ($probeOneJson.allowed -cne 'child-one' -or $probeTwoJson.allowed -cne 'child-two') { throw 'Independent child allowlists contaminated one another.' }
        if ((@($probeOneJson.argv) -join '|') -cne ($expectedNativeArgv -join '|')) { throw 'Windows native argv serialization changed a structural argument.' }
        $diagnostic = @($probeOne,$probeTwo) | ConvertTo-Json -Depth 6
        if ($diagnostic.Contains($secretValue)) { throw 'Synthetic secret appeared in runner diagnostics.' }
        $runnerSource = Get-Content -LiteralPath (Join-Path $securityRoot 'img2threejs-runner.ps1') -Raw
        if ($runnerSource -match 'SetEnvironmentVariable|GetEnvironmentVariables\(') { throw 'Runner still mutates or snapshots the parent environment.' }
    } finally {
        [Environment]::SetEnvironmentVariable($secretName, $originalSecret, 'Process')
        [Environment]::SetEnvironmentVariable('CHARACTER_DEMO_ID', $originalCharacterDemo, 'Process')
    }

    $allValues = [ordered]@{
        CHARACTER_GLB = 'public/mesh/subject.glb'
        CHARACTER_DIFFUSE = 'none'
        CHARACTER_DEMO_ID = 'subject'
        CHARACTER_NODES = '0 2'
        CHARACTER_LEVELS = 'x2 default'
        CHARACTER_BIN_DIR = 'public/head'
        CHARACTER_OUT_PREFIX = 'public/head/sdf-surfaces'
        CHARACTER_WORKDIR = 'work/head'
        CHARACTER_WORK_TAG = '-safe'
        CHARACTER_CODEC = 'src/demos/subject/surfaceCodec.ts'
        CHARACTER_CODEC_IMPORT = './surfaceCodec'
        CHARACTER_REGIONS_JSON = 'configs/regions.json'
        CHARACTER_CELL_SIZES_JSON = 'configs/cells.json'
        CHARACTER_SECTION_REGIONS_JSON = 'configs/sections.json'
        CHARACTER_SPOKES_JSON = 'configs/spokes.json'
        CHARACTER_CROSS_SECTIONS = 'src/demos/subject/crossSections.ts'
        CHARACTER_DEST_X2 = 'src/demos/subject/surfaceDataMedium.ts'
        CHARACTER_DEST_X3 = 'src/demos/subject/surfaceDataLow.ts'
        CHARACTER_DEST_DEFAULT = 'src/demos/subject/surfaceData.ts'
        CHARACTER_SLICES = '40'
        CHARACTER_ALLOW_BASELINE_UV = '1'
        CHARACTER_UV_SLACK = '0.002'
    }
    $envPath = Join-Path $project 'character.env'
    $envText = @($allValues.Keys | ForEach-Object { $_ + '="' + $allValues[$_] + '"' }) -join "`n"
    [IO.File]::WriteAllText($envPath, $envText)
    $jsonPath = Join-Path $project 'character.json'
    [IO.File]::WriteAllText($jsonPath, ($allValues | ConvertTo-Json -Depth 3))

    foreach ($configName in @('character.env','character.json')) {
        $parsed = ConvertFrom-Img2ThreejsGlbConfig -LiteralPath $configName -ProjectRoot $project
        if (@($parsed.values.PSObject.Properties).Count -ne 22) { throw "$configName did not preserve all 22 fields." }
        if ((@($parsed.values.CHARACTER_NODES) -join ',') -cne '0,2') { throw "$configName did not preserve node tokens." }
    }
    [IO.File]::WriteAllText($jsonPath, '{"CHARACTER_GLB":"x","CHARACTER_GLB":"y"}')
    Assert-Throws { ConvertFrom-Img2ThreejsGlbConfig 'character.json' $project | Out-Null } 'duplicate key' 'duplicate JSON config'
    [IO.File]::WriteAllText($jsonPath, '{"UNKNOWN_KEY":"x"}')
    Assert-Throws { ConvertFrom-Img2ThreejsGlbConfig 'character.json' $project | Out-Null } 'unknown key' 'unknown JSON config'
    [IO.File]::WriteAllText($envPath, "CHARACTER_GLB=`$(id)")
    Assert-Throws { ConvertFrom-Img2ThreejsGlbConfig 'character.env' $project | Out-Null } 'shell syntax' 'shell config syntax'
    [IO.File]::WriteAllText($envPath, $envText)

    $input = Get-Img2ThreejsValidatedPipelineInput -ProjectRoot $project -ConfigPath 'character.env'
    $plan = Invoke-Img2ThreejsPipeline -ProjectRoot $project -ConfigPath 'character.env' -SkipSplat -SkipBuild -PlanOnly
    if ($plan.commandStringConstructed) { throw 'Runner reported command-string construction.' }
    if ($plan.effects -notcontains 'PROJECT_CODE_EXECUTION') { throw 'GLB pipeline lost PROJECT_CODE_EXECUTION.' }
    if (@($plan.steps).Count -lt 5) { throw 'Legitimate GLB stages were not preserved.' }
    foreach ($stepPlan in @($plan.steps)) {
        if ([string]::IsNullOrWhiteSpace($stepPlan.executable) -or -not @($stepPlan.argv).Count) { throw 'A plan step lacks executable + argv.' }
        foreach ($secret in @('OPENAI_API_KEY','API_KEY_21ST','PATH','USERPROFILE','HOME')) {
            if ($stepPlan.environmentNames -contains $secret) { throw "Plan inherited forbidden environment name $secret." }
        }
    }
    $exportStep = @($plan.steps | Where-Object purpose -eq 'structural-json-export-surfaces')
    if ($exportStep.Count) { throw 'SkipSplat did not remove only the splat stage.' }
    $encode = $plan.steps | Where-Object purpose -eq 'encode-surfaces-x2'
    if ($encode.argv[-1] -cne 'x2') { throw 'Level enum was not a dedicated argv element.' }
    $codec = Invoke-Img2ThreejsProjectCodeOperation -Operation img2threejs.codec-verify -ProjectRoot $project -ConfigPath 'character.env' -PlanOnly
    $typescript = Invoke-Img2ThreejsProjectCodeOperation -Operation img2threejs.typescript-build -ProjectRoot $project -PlanOnly
    $vite = Invoke-Img2ThreejsProjectCodeOperation -Operation img2threejs.vite-build -ProjectRoot $project -PlanOnly
    foreach ($route in @($codec,$typescript,$vite)) {
        if ($route.effects -notcontains 'PROJECT_CODE_EXECUTION' -or -not $route.projectCodeExecutes) { throw 'A project-code route was downgraded.' }
        if ($route.networkRequirement -cne 'none') { throw 'PROJECT_CODE_EXECUTION implied network.' }
    }

    $launcher = Get-Command (Join-Path $securityRoot 'invoke-capability.ps1')
    foreach ($forbiddenParameter in @('Authorized','Executable','ArgumentList','Command','ScriptPath')) {
        if ($launcher.Parameters.ContainsKey($forbiddenParameter)) { throw "Launcher exposes forbidden parameter $forbiddenParameter." }
    }
    Assert-Throws { & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation 'not.registered' | Out-Null } 'UNKNOWN operation' 'unknown operation'
    Assert-Throws { & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation 'img2threejs.network-helper' | Out-Null } 'not enabled' 'network without separate route'
    Assert-Throws { & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation 'img2threejs.capability-summary' -SkipBuild | Out-Null } 'unregistered inputs' 'operation-specific input injection'

    $init = Invoke-Img2ThreejsStateOperation -Operation img2threejs.state.init -ProjectRoot $project -Reference 'reference.png'
    if ($init.exitCode -ne 0) { throw 'Guarded state init failed.' }
    $status = Invoke-Img2ThreejsStateOperation -Operation img2threejs.state.status -ProjectRoot $project
    if (($status.stdout -join '') -notmatch 'image-analysis') { throw 'Guarded state status lost the upstream contract.' }
    $launchedStatus = & (Join-Path $securityRoot 'invoke-capability.ps1') -Operation img2threejs.state.status -ProjectRoot $project | ConvertFrom-Json
    if (($launchedStatus.stdout -join '') -notmatch 'image-analysis') { throw 'Common launcher did not route status through the guarded boundary.' }
    Invoke-Img2ThreejsStateOperation -Operation img2threejs.state.mark -ProjectRoot $project -Step image-analysis -Evidence 'analysis.json' | Out-Null
    $next = Invoke-Img2ThreejsStateOperation -Operation img2threejs.state.next -ProjectRoot $project
    if (($next.stdout -join '') -notmatch 'reference-suitability') { throw 'Guarded state next did not advance the contract.' }
    Invoke-Img2ThreejsStateOperation -Operation img2threejs.state.init -ProjectRoot $project -StatePath '.img2threejs/nested/state.json' -Reference 'reference.png' | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $project '.img2threejs/nested/state.json') -PathType Leaf)) { throw 'Nested guarded state init failed.' }

    $policy = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'effect-policy.json') | ConvertFrom-Json
    if ($policy.effectClasses -notcontains 'PROJECT_CODE_EXECUTION') { throw 'Effect model lacks PROJECT_CODE_EXECUTION.' }
    foreach ($id in @('img2threejs.codec-verify','img2threejs.typescript-build','img2threejs.vite-build')) {
        $definition = $policy.operations | Where-Object id -CEQ $id
        if ($definition.effect -cne 'PROJECT_CODE_EXECUTION' -or $definition.status -cne 'enabled') { throw "$id manifest classification drifted." }
    }
    $pipelineDefinition = $policy.operations | Where-Object id -CEQ 'img2threejs.glb-pipeline'
    $expectedCharacterEnvironment = @((Get-Img2ThreejsGlbConfigSchema).Keys | Sort-Object)
    $manifestCharacterEnvironment = @($pipelineDefinition.environmentAllowlist | Where-Object { $_.StartsWith('CHARACTER_', [StringComparison]::Ordinal) } | Sort-Object)
    if (($expectedCharacterEnvironment -join ',') -cne ($manifestCharacterEnvironment -join ',')) {
        throw 'Pipeline environment manifest does not enumerate exactly the 22 CHARACTER keys.'
    }
    if (@($pipelineDefinition.environmentAllowlist | Where-Object { $_ -match '[*?]' }).Count) { throw 'Environment manifest contains a wildcard.' }
    foreach ($definition in @($policy.operations | Where-Object status -eq 'enabled')) {
        foreach ($name in @('id','effects','executableSource','allowedArgvStructure','projectPathInputs','outputBoundaries','environmentAllowlist','networkRequirement','projectCodeExecutes','validatorsRequired','stateGuardRequired')) {
            if ($null -eq $definition.PSObject.Properties[$name]) { throw "Enabled operation $($definition.id) lacks metadata $name." }
        }
    }
} finally {
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete($fixture, $true) }
}

Write-Output 'PASS: JSON and legacy config preserve all 22 fields while shell syntax, duplicates, and unknown keys fail closed.'
Write-Output 'PASS: GLB inventory and all four structural maps validate before a no-shell pipeline plan is produced.'
Write-Output 'PASS: codec, TypeScript, and Vite remain routable as PROJECT_CODE_EXECUTION with fixed runtime + argv and no implied network.'
Write-Output 'PASS: runner environment exposes only registered names; arbitrary executable/argv/authorization surfaces are absent.'
Write-Output 'PASS: ProcessStartInfo constructs a child-only allowlist; parent values and independent invocations remain isolated.'
Write-Output 'PASS: guarded default/nested init, status, mark, and next execute through canonical state paths.'
Write-Output 'DYNAMIC TEST NOT EXECUTED  PROJECT CODE STATIC/DEFENSIVE ROUTING PROPERTY VERIFIED'
