Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'plugin/frontend-toolkit/security/img2threejs-foundation.ps1')

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    try { & $Action; throw "$Label did not fail closed." }
    catch {
        if ($_.Exception.Message -notmatch $Pattern -and $_.Exception.Message -eq "$Label did not fail closed.") { throw }
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Label returned the wrong error: $($_.Exception.Message)" }
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-img2threejs-foundation-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $fixture 'project'
    $configName = 'character.env'
    $config = Join-Path $project $configName
try {
    New-Item -ItemType Directory -Path $project | Out-Null
    @'
CHARACTER_GLB="public/mesh/subject.glb"
CHARACTER_DEMO_ID="subject"
CHARACTER_NODES="0 2 9"
CHARACTER_LEVELS="x2 default"
CHARACTER_SECTION_REGIONS_JSON="${IMG2THREEJS_SHOWCASE_ROOT}/configs/regions.json"
CHARACTER_SPOKES_JSON="configs/spokes.json"
CHARACTER_CROSS_SECTIONS="src/demos/subject/crossSections.ts"
CHARACTER_ALLOW_BASELINE_UV="1"
'@ | Set-Content -LiteralPath $config -Encoding utf8

    $parsed = ConvertFrom-Img2ThreejsGlbConfig -LiteralPath $configName -ProjectRoot $project
    if ($parsed.schemaVersion -ne 1) { throw 'Structural config schema version drifted.' }
    if ((@($parsed.values.CHARACTER_NODES) -join ',') -cne '0,2,9') { throw 'Node list was not structurally parsed.' }
    if ((@($parsed.values.CHARACTER_LEVELS) -join ',') -cne 'x2,default') { throw 'Level list was not structurally parsed.' }
    if (-not $parsed.values.CHARACTER_ALLOW_BASELINE_UV) { throw 'Explicit UV opt-in was not preserved.' }
    if ($parsed.environment.CHARACTER_SECTION_REGIONS_JSON -cne 'configs/regions.json') { throw 'Root placeholder was not structurally resolved.' }
    $schema = Get-Img2ThreejsGlbConfigSchema
    if (@($schema.Keys).Count -ne 22) { throw 'CHARACTER_* schema inventory drifted.' }
    if ($schema.CHARACTER_CODEC.Access -cne 'execute-project-code') { throw 'Project codec execution is misclassified.' }
    $pipelineRoot = Join-Path $repoRoot 'external/img2threejs/integrations/glb_character_pipeline'
    $upstreamFields = @(Get-ChildItem $pipelineRoot -Recurse -File |
        Where-Object { $_.Extension -in '.sh','.py','.mjs','.env' } |
        ForEach-Object { [regex]::Matches((Get-Content -Raw -LiteralPath $_.FullName), '\bCHARACTER_[A-Z0-9_]+\b') } |
        ForEach-Object Value |
        Sort-Object -Unique)
    if (($upstreamFields -join ',') -cne (@($schema.Keys | Sort-Object) -join ',')) {
        throw 'The structural schema does not exactly cover the pinned upstream CHARACTER_* inventory.'
    }

    $malicious = @(
        @{ Text = "CHARACTER_GLB=x`nCHARACTER_DEMO_ID=x`nCHARACTER_NODES=0`nCHARACTER_LEVELS=default`nEVIL_KEY=1"; Pattern = 'unknown key'; Label = 'unknown key' }
        @{ Text = "CHARACTER_GLB=`$(id)`nCHARACTER_DEMO_ID=x`nCHARACTER_NODES=0`nCHARACTER_LEVELS=default"; Pattern = 'shell syntax'; Label = 'command substitution' }
        @{ Text = "CHARACTER_GLB=../outside.glb`nCHARACTER_DEMO_ID=x`nCHARACTER_NODES=0`nCHARACTER_LEVELS=default"; Pattern = 'escapes'; Label = 'config traversal' }
        @{ Text = "CHARACTER_GLB=x`nCHARACTER_GLB=y`nCHARACTER_DEMO_ID=x`nCHARACTER_NODES=0`nCHARACTER_LEVELS=default"; Pattern = 'duplicates'; Label = 'duplicate key' }
        @{ Text = "CHARACTER_GLB=x`nCHARACTER_DEMO_ID=x`nCHARACTER_NODES=0;touch`nCHARACTER_LEVELS=default"; Pattern = 'non-negative integers'; Label = 'node reparsing' }
        @{ Text = "export CHARACTER_GLB=x`nCHARACTER_DEMO_ID=x`nCHARACTER_NODES=0`nCHARACTER_LEVELS=default"; Pattern = 'structural KEY=VALUE'; Label = 'export statement' }
    )
    foreach ($case in $malicious) {
        $case.Text | Set-Content -LiteralPath $config -Encoding utf8
        Assert-Throws { ConvertFrom-Img2ThreejsGlbConfig -LiteralPath $configName -ProjectRoot $project | Out-Null } $case.Pattern $case.Label
    }
    Assert-Throws { ConvertFrom-Img2ThreejsGlbConfig -LiteralPath '..\outside.env' -ProjectRoot $project | Out-Null } 'escapes' 'config path traversal'

    $defaultState = Resolve-Img2ThreejsStatePath -ProjectRoot $project -StatePath '.img2threejs/state.json'
    $nestedState = Resolve-Img2ThreejsStatePath -ProjectRoot $project -StatePath '.img2threejs/nested/state.json'
    if (-not (Test-Img2ThreejsPathWithinRoot -Root (Join-Path $project '.img2threejs') -Candidate $defaultState)) { throw 'Default state escaped.' }
    if (-not (Test-Img2ThreejsPathWithinRoot -Root (Join-Path $project '.img2threejs') -Candidate $nestedState)) { throw 'Nested state escaped.' }
    Assert-Throws { Resolve-Img2ThreejsStatePath -ProjectRoot $project -StatePath '.img2threejs/../../outside.json' | Out-Null } 'escapes' 'state traversal'
    Assert-Throws { Resolve-Img2ThreejsStatePath -ProjectRoot $project -StatePath (Join-Path $fixture 'absolute.json') | Out-Null } 'Absolute' 'absolute state'
    Assert-Throws { Resolve-Img2ThreejsStatePath -ProjectRoot $project -StatePath 'other/state.json' | Out-Null } 'start with' 'foreign state root'
    Assert-Throws { Resolve-Img2ThreejsStatePath -ProjectRoot $project -StatePath '.img2threejs/state.txt' | Out-Null } '\.json' 'non-JSON state'

    $authorizedStateRoot = Join-Path $project '.img2threejs'
    $outside = Join-Path $fixture 'outside'
    New-Item -ItemType Directory -Path $authorizedStateRoot,$outside | Out-Null
    $junction = Join-Path $authorizedStateRoot 'junction-out'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-Throws { Resolve-Img2ThreejsStatePath -ProjectRoot $project -StatePath '.img2threejs/junction-out/state.json' | Out-Null } 'Reparse points' 'junction state escape'

    $policy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/effect-policy.json') | ConvertFrom-Json
    if (($policy.operations | Where-Object id -ceq 'img2threejs.glb-pipeline').effect -cne 'PROJECT_CODE_EXECUTION') {
        throw 'The integrated GLB pipeline must be PROJECT_CODE_EXECUTION.'
    }
    foreach ($operation in @('img2threejs.state.init','img2threejs.state.status','img2threejs.state.mark','img2threejs.state.next')) {
        if (($policy.operations | Where-Object id -ceq $operation).status -ne 'enabled') { throw "$operation was not integrated." }
    }
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -Recurse -Force -LiteralPath $fixture }
}

Write-Output 'PASS: structural schema exactly covers all 22 pinned CHARACTER_* fields and rejects reparsing inputs.'
Write-Output 'PASS: canonical state resolution preserves default/nested state and rejects absolute, traversal, and foreign-root targets.'
Write-Output 'PASS: SR2D operation manifest integrates guarded state and classifies the GLB pipeline as PROJECT_CODE_EXECUTION.'
