Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'img2threejs-foundation.ps1')
. (Join-Path $PSScriptRoot 'img2threejs-structural-validation.ps1')
. (Join-Path $PSScriptRoot 'img2threejs-state-guard.ps1')

function Resolve-Img2ThreejsRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('node','python')][string]$Name)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'The current FTK runtime policy only registers windows-x64 runtimes.'
    }
    $policy = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'img2threejs-runtime-policy.json') | ConvertFrom-Json
    $definition = $policy.runtimes.'windows-x64'.$Name
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $path = [IO.Path]::GetFullPath((Join-Path $localAppData $definition.relativeToLocalAppData))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The pinned FTK $Name runtime is not installed at its registered path."
    }
    return $path
}

function Resolve-Img2ThreejsPinnedUpstreamRoot {
    [CmdletBinding()]
    param()

    $pluginRoot = Split-Path -Parent $PSScriptRoot
    $distribution = Join-Path $pluginRoot 'third_party/upstreams/img2threejs'
    if (Test-Path -LiteralPath $distribution -PathType Container) {
        return (Resolve-Path -LiteralPath $distribution).Path
    }
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $development = Join-Path $repoRoot 'external/img2threejs'
    if (Test-Path -LiteralPath $development -PathType Container) {
        return (Resolve-Path -LiteralPath $development).Path
    }
    throw 'The pinned img2threejs upstream payload is unavailable.'
}

function New-Img2ThreejsMinimumEnvironment {
    [CmdletBinding()]
    param(
        [ValidateSet('node','python')][string]$Runtime,
        [Collections.IDictionary]$Additional
    )

    $policy = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'img2threejs-runtime-policy.json') | ConvertFrom-Json
    $environment = [ordered]@{}
    foreach ($name in @($policy.baseEnvironment)) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrEmpty($value)) { $environment[$name] = $value }
    }
    if ($Runtime -eq 'python') {
        foreach ($property in $policy.pythonEnvironment.PSObject.Properties) {
            $environment[$property.Name] = [string]$property.Value
        }
    }
    if ($null -ne $Additional) {
        $allowedAdditional = @((Get-Img2ThreejsGlbConfigSchema).Keys) + @('IMG2THREEJS_SHOWCASE_ROOT')
        foreach ($name in $Additional.Keys) {
            if ($name -cnotin $allowedAdditional) {
                throw "Unregistered img2threejs environment name: $name"
            }
            $environment[$name] = [string]$Additional[$name]
        }
    }
    foreach ($forbidden in @($policy.forbiddenInheritedEnvironment)) {
        if ($environment.Contains($forbidden)) { throw "Forbidden inherited environment name: $forbidden" }
    }
    return $environment
}

function ConvertTo-Img2ThreejsWindowsNativeArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    if ($Value -match '[\x00\r\n]') { throw 'Native argv values may not contain NUL or line breaks.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Img2ThreejsTrustedNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('node','python')][string]$Runtime,
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Collections.IDictionary]$Environment
    )

    $executable = Resolve-Img2ThreejsRuntime -Name $Runtime
    $workingRoot = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $WorkingDirectory
    $minimum = New-Img2ThreejsMinimumEnvironment -Runtime $Runtime -Additional $Environment

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.WorkingDirectory = $workingRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (@($ArgumentList | ForEach-Object {
        ConvertTo-Img2ThreejsWindowsNativeArgument -Value ([string]$_)
    }) -join ' ')
    $startInfo.EnvironmentVariables.Clear()
    foreach ($key in $minimum.Keys) {
        $startInfo.EnvironmentVariables.Add([string]$key, [string]$minimum[$key])
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "$Runtime process did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    $stdout = @($stdoutText -split '\r?\n' | Where-Object { $_.Length -gt 0 })
    $stderr = @($stderrText -split '\r?\n' | Where-Object { $_.Length -gt 0 })
    if ($exitCode -ne 0) { throw "$Runtime operation failed with exit code $exitCode." }
    return [pscustomobject][ordered]@{
        executable = $executable
        argv = @($ArgumentList)
        stdout = $stdout
        stderr = $stderr
        exitCode = $exitCode
    }
}

function New-Img2ThreejsPlanStep {
    param(
        [Parameter(Mandatory)][ValidateSet('node','python')][string]$Runtime,
        [Parameter(Mandatory)][string[]]$Argv,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$EnvironmentNames,
        [Parameter(Mandatory)][string]$Purpose,
        [ValidateSet('base','character')][string]$EnvironmentProfile = 'base'
    )
    $reportedEnvironment = @($EnvironmentNames)
    if ($Runtime -eq 'python') { $reportedEnvironment += @('PYTHONIOENCODING','PYTHONDONTWRITEBYTECODE','PYTHONNOUSERSITE') }
    return [pscustomobject][ordered]@{
        runtime = $Runtime
        executable = Resolve-Img2ThreejsRuntime -Name $Runtime
        argv = @($Argv)
        workingDirectory = $WorkingDirectory
        environmentNames = @($reportedEnvironment | Sort-Object -Unique)
        environmentProfile = $EnvironmentProfile
        purpose = $Purpose
    }
}

function Get-Img2ThreejsPipelinePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PipelineInput,
        [switch]$SkipSplat,
        [switch]$SkipBuild,
        [switch]$AllowMissingDependencies
    )

    $pipeline = 'integrations/glb_character_pipeline'
    $pythonRoot = $pipeline + '/python'
    $nodeRoot = $pipeline + '/node'
    $environmentNames = @('SystemRoot','TEMP','TMP') + @($PipelineInput.environment.Keys)
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $hasCrossSections = -not [string]::IsNullOrEmpty([string]$PipelineInput.config.values.CHARACTER_CROSS_SECTIONS)
    $hasSections = -not [string]::IsNullOrEmpty([string]$PipelineInput.config.values.CHARACTER_SECTION_REGIONS_JSON)
    $hasSpokes = -not [string]::IsNullOrEmpty([string]$PipelineInput.config.values.CHARACTER_SPOKES_JSON)
    if ($hasCrossSections -and $hasSections -and $hasSpokes) {
        $script = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($pythonRoot + '/build_cross_sections.py')
        $steps.Add((New-Img2ThreejsPlanStep python @($script) $PipelineInput.projectRoot $environmentNames 'structural-json-build-cross-sections' character))
        if ($PipelineInput.config.values.CHARACTER_ALLOW_BASELINE_UV) {
            $script = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($pythonRoot + '/bake_atlas_uvs.py')
            $steps.Add((New-Img2ThreejsPlanStep python @($script) $PipelineInput.projectRoot $environmentNames 'structural-json-bake-atlas-uvs' character))
        }
    }
    if (-not $SkipSplat) {
        $script = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($pythonRoot + '/export_sdf_surfaces.py')
        $argv = @($script) + @($PipelineInput.config.values.CHARACTER_NODES | ForEach-Object { [string]$_ })
        $steps.Add((New-Img2ThreejsPlanStep python $argv $PipelineInput.projectRoot $environmentNames 'structural-json-export-surfaces' character))
    }
    foreach ($level in @($PipelineInput.config.values.CHARACTER_LEVELS)) {
        $surfaceBin = if ($level -eq 'default') {
            Join-Path ([string]$PipelineInput.config.values.CHARACTER_BIN_DIR) 'sdf-surfaces.bin'
        } else {
            Join-Path ([string]$PipelineInput.config.values.CHARACTER_BIN_DIR) ("sdf-surfaces-$level.bin")
        }
        $dest = switch ($level) {
            'x2' { if ($PipelineInput.config.values.CHARACTER_DEST_X2) { [string]$PipelineInput.config.values.CHARACTER_DEST_X2 } else { Join-Path $PipelineInput.projectRoot "src/demos/$($PipelineInput.config.values.CHARACTER_DEMO_ID)/surfaceDataMedium.ts" } }
            'x3' { if ($PipelineInput.config.values.CHARACTER_DEST_X3) { [string]$PipelineInput.config.values.CHARACTER_DEST_X3 } else { Join-Path $PipelineInput.projectRoot "src/demos/$($PipelineInput.config.values.CHARACTER_DEMO_ID)/surfaceDataLow.ts" } }
            default { if ($PipelineInput.config.values.CHARACTER_DEST_DEFAULT) { [string]$PipelineInput.config.values.CHARACTER_DEST_DEFAULT } else { Join-Path $PipelineInput.projectRoot "src/demos/$($PipelineInput.config.values.CHARACTER_DEMO_ID)/surfaceData.ts" } }
        }
        if (-not (Test-Img2ThreejsPathWithinRoot $PipelineInput.projectRoot $dest)) { throw 'A derived surface module escaped the project.' }
        $verify = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/verify_cells.mjs')
        $encode = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/encode_surfaces.mjs')
        $emit = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/emit_surface_module.mjs')
        $steps.Add((New-Img2ThreejsPlanStep node @($verify,$surfaceBin,[string]$PipelineInput.config.values.CHARACTER_GLB) $PipelineInput.projectRoot $environmentNames "verify-cells-$level" character))
        $steps.Add((New-Img2ThreejsPlanStep node @('--max-old-space-size=8192',$encode,[string]$level) $PipelineInput.projectRoot $environmentNames "encode-surfaces-$level" character))
        $steps.Add((New-Img2ThreejsPlanStep node @($emit,[string]$level,$dest) $PipelineInput.projectRoot $environmentNames "emit-surface-module-$level" character))
    }
    $steps.Add((Get-Img2ThreejsCodecPlan -PipelineInput $PipelineInput -AllowMissingDependencies:$AllowMissingDependencies))
    foreach ($level in @($PipelineInput.config.values.CHARACTER_LEVELS)) {
        $verifyRoundtrip = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/verify_roundtrip.mjs')
        $steps.Add((New-Img2ThreejsPlanStep node @('--max-old-space-size=8192',$verifyRoundtrip,[string]$level) $PipelineInput.projectRoot $environmentNames "verify-roundtrip-$level" character))
    }
    if (-not $SkipBuild) {
        $steps.Add((Get-Img2ThreejsProjectBuildPlan -ProjectRoot $PipelineInput.projectRoot -Tool typescript -AllowMissingDependencies:$AllowMissingDependencies))
        $steps.Add((Get-Img2ThreejsProjectBuildPlan -ProjectRoot $PipelineInput.projectRoot -Tool vite -AllowMissingDependencies:$AllowMissingDependencies))
        $capture = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/capture-character.mjs')
        $captureOut = Resolve-Img2ThreejsContainedPath -Root $PipelineInput.projectRoot -RelativePath ("work/cmp/pipeline-check$($PipelineInput.config.values.CHARACTER_WORK_TAG)")
        $captureArgv = @($capture,'--base','http://127.0.0.1:5200/img2threejs-showcase/','--demo',[string]$PipelineInput.config.values.CHARACTER_DEMO_ID,'--out',$captureOut)
        $steps.Add((New-Img2ThreejsPlanStep node $captureArgv $PipelineInput.projectRoot @('SystemRoot','TEMP','TMP') 'loopback-capture-with-bin-isolation'))
    }
    return $steps.ToArray()
}

function Assert-Img2ThreejsStructuralInputsNow {
    param([Parameter(Mandatory)]$PipelineInput)
    $null = ConvertFrom-Img2ThreejsStructuralData `
        -CharacterNodes @($PipelineInput.config.values.CHARACTER_NODES) `
        -RegionsPath ([string]$PipelineInput.config.values.CHARACTER_REGIONS_JSON) `
        -CellSizesPath ([string]$PipelineInput.config.values.CHARACTER_CELL_SIZES_JSON) `
        -SectionRegionsPath ([string]$PipelineInput.config.values.CHARACTER_SECTION_REGIONS_JSON) `
        -SpokesPath ([string]$PipelineInput.config.values.CHARACTER_SPOKES_JSON)
}

function Invoke-Img2ThreejsCaptureWithIsolation {
    param([Parameter(Mandatory)]$PipelineInput, [Parameter(Mandatory)]$Step)
    $bin = [string]$PipelineInput.config.values.CHARACTER_BIN_DIR
    $runtimeRoot = Join-Path $PipelineInput.projectRoot '.img2threejs/runtime'
    Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $runtimeRoot
    [IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
    Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $runtimeRoot
    $backup = Join-Path $runtimeRoot ('bin-' + [guid]::NewGuid().ToString('N'))
    $moved = $false
    try {
        if (Test-Path -LiteralPath $bin) {
            Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $bin
            Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $backup
            [IO.Directory]::Move($bin, $backup)
            $moved = $true
        }
        return Invoke-Img2ThreejsTrustedNative -Runtime node -ArgumentList @($Step.argv) `
            -WorkingDirectory $PipelineInput.projectRoot -Environment ([ordered]@{})
    } finally {
        if ($moved) {
            Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $backup
            if (Test-Path -LiteralPath $bin) {
                throw 'Capture isolation could not restore CHARACTER_BIN_DIR because the target was recreated concurrently.'
            }
            [IO.Directory]::Move($backup, $bin)
            Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $bin
        }
    }
}

function Invoke-Img2ThreejsPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$SkipSplat,
        [switch]$SkipBuild,
        [switch]$PlanOnly
    )

    $pipelineInput = Get-Img2ThreejsValidatedPipelineInput -ProjectRoot $ProjectRoot -ConfigPath $ConfigPath
    $steps = @(Get-Img2ThreejsPipelinePlan -PipelineInput $pipelineInput -SkipSplat:$SkipSplat -SkipBuild:$SkipBuild -AllowMissingDependencies:$PlanOnly)
    if ($PlanOnly) {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            operation = 'img2threejs.glb-pipeline'
            effects = @('LOCAL_PROJECT_WRITE','PROJECT_CODE_EXECUTION') + $(if (-not $SkipBuild) { @('LOOPBACK_EPHEMERAL') } else { @() })
            projectCodeExecutes = $true
            networkRequirement = 'none-external; fixed-loopback-only-when-build-enabled'
            commandStringConstructed = $false
            steps = $steps
        }
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    $codecStep = $steps | Where-Object purpose -eq 'compile-contained-codec-and-check-contract'
    $codecOutputIndex = [Array]::IndexOf([object[]]$codecStep.argv, '--output')
    if ($codecOutputIndex -lt 0) { throw 'Codec plan lacks its fixed output slot.' }
    $codecBundle = $codecStep.argv[$codecOutputIndex + 1]
    try {
        foreach ($step in $steps) {
            if ($step.purpose.StartsWith('structural-json-', [StringComparison]::Ordinal)) {
                Assert-Img2ThreejsStructuralInputsNow -PipelineInput $pipelineInput
            }
            if ($step.purpose -eq 'loopback-capture-with-bin-isolation') {
                $results.Add((Invoke-Img2ThreejsCaptureWithIsolation -PipelineInput $pipelineInput -Step $step))
                continue
            }
            $environment = if ($step.environmentProfile -eq 'character') {
                $copy = [ordered]@{}
                foreach ($key in $pipelineInput.environment.Keys) { $copy[$key] = $pipelineInput.environment[$key] }
                if ($step.purpose.StartsWith('verify-roundtrip-', [StringComparison]::Ordinal)) {
                    $copy['CHARACTER_CODEC'] = $codecBundle
                }
                $copy
            } else { [ordered]@{} }
            $results.Add((Invoke-Img2ThreejsTrustedNative -Runtime $step.runtime -ArgumentList @($step.argv) `
                -WorkingDirectory $pipelineInput.projectRoot -Environment $environment))
        }
    } finally {
        if (Test-Path -LiteralPath $codecBundle -PathType Leaf) {
            Assert-Img2ThreejsNoExistingReparsePoint -Root $pipelineInput.projectRoot -Candidate $codecBundle
            [IO.File]::Delete($codecBundle)
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        operation = 'img2threejs.glb-pipeline'
        executed = $true
        stepCount = $results.Count
        commandStringConstructed = $false
    }
}

function Invoke-Img2ThreejsProjectCodeOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('img2threejs.codec-verify','img2threejs.typescript-build','img2threejs.vite-build')][string]$Operation,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ConfigPath,
        [switch]$PlanOnly
    )
    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    if ($Operation -eq 'img2threejs.codec-verify') {
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) { throw 'codec-verify requires ConfigPath.' }
        $pipelineInput = Get-Img2ThreejsValidatedPipelineInput -ProjectRoot $project -ConfigPath $ConfigPath
        $step = Get-Img2ThreejsCodecPlan -PipelineInput $pipelineInput -AllowMissingDependencies:$PlanOnly
    } else {
        $tool = if ($Operation -eq 'img2threejs.typescript-build') { 'typescript' } else { 'vite' }
        $step = Get-Img2ThreejsProjectBuildPlan -ProjectRoot $project -Tool $tool -AllowMissingDependencies:$PlanOnly
    }
    if ($PlanOnly) {
        return [pscustomobject][ordered]@{ schemaVersion = 1; operation = $Operation; effects = @('PROJECT_CODE_EXECUTION','LOCAL_PROJECT_WRITE'); projectCodeExecutes = $true; networkRequirement = 'none'; commandStringConstructed = $false; steps = @($step) }
    }
    $result = Invoke-Img2ThreejsTrustedNative -Runtime node -ArgumentList @($step.argv) -WorkingDirectory $project -Environment ([ordered]@{})
    if ($Operation -eq 'img2threejs.codec-verify') {
        $outputIndex = [Array]::IndexOf([object[]]$step.argv, '--output')
        if ($outputIndex -ge 0) {
            $output = $step.argv[$outputIndex + 1]
            if (Test-Path -LiteralPath $output -PathType Leaf) {
                Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $output
                [IO.File]::Delete($output)
            }
        }
    }
    return $result
}

function Assert-Img2ThreejsStateScalar {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name, [int]$MaxLength = 512)
    if ($Value.Length -gt $MaxLength -or $Value -match '[\x00-\x1f\x7f]') {
        throw "$Name contains controls or exceeds $MaxLength characters."
    }
}

function Assert-Img2ThreejsStoredProjectPaths {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$JsonText)
    $state = ConvertFrom-Json -InputObject $JsonText -ErrorAction Stop
    foreach ($name in @('reference','spec')) {
        $value = [string]$state.artifacts.$name
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ([IO.Path]::IsPathRooted($value)) {
            $candidate = [IO.Path]::GetFullPath($value)
            if (-not (Test-Img2ThreejsPathWithinRoot -Root $ProjectRoot -Candidate $candidate)) {
                throw "Stored state artifacts.$name escapes the project."
            }
            Assert-Img2ThreejsNoExistingReparsePoint -Root $ProjectRoot -Candidate $candidate
        } else {
            $null = Resolve-Img2ThreejsContainedPath -Root $ProjectRoot -RelativePath $value
        }
    }
}

function Invoke-Img2ThreejsStateOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet(
            'img2threejs.state.init','img2threejs.state.status','img2threejs.state.mark','img2threejs.state.next',
            'img2threejs.state.create','img2threejs.state.read','img2threejs.state.write','img2threejs.state.update'
        )][string]$Operation,
        [Parameter(Mandatory)][string]$ProjectRoot,
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
        [AllowEmptyString()][string]$JsonText
    )

    if ($MaxPerPass -gt $MaxTotal) { throw 'State loop limits require MaxPerPass <= MaxTotal.' }
    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    switch ($Operation) {
        'img2threejs.state.create' { return New-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath -JsonText $JsonText }
        'img2threejs.state.read' { return Read-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath }
        'img2threejs.state.write' { return Write-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath -JsonText $JsonText }
        'img2threejs.state.update' { return Update-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath -JsonText $JsonText }
    }

    $pythonEnvironment = [ordered]@{}
    $stateScript = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath 'forge/state.py'
    if ($Operation -eq 'img2threejs.state.init') {
        if ([string]::IsNullOrWhiteSpace($Reference)) { throw 'state.init requires Reference.' }
        $referencePath = Resolve-Img2ThreejsContainedPath -Root $project -RelativePath $Reference
        if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) { throw 'State reference does not exist.' }
        $specPath = if ($Spec) { Resolve-Img2ThreejsContainedPath -Root $project -RelativePath $Spec } else { '' }
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath -CreateAuthorizedRoot
        if (Test-Path -LiteralPath $approved.CanonicalPath) { throw 'Refusing to overwrite existing img2threejs state.' }
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath -CreateAuthorizedRoot
        $argv = @($stateScript,'init','--state',$approved.CanonicalPath,'--reference',$referencePath,'--profile',$Profile,'--max-per-pass',[string]$MaxPerPass,'--max-total',[string]$MaxTotal)
        if ($specPath) { $argv += @('--spec',$specPath) }
        $result = Invoke-Img2ThreejsTrustedNative python $argv $project $pythonEnvironment
        $verified = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        if (-not (Test-Path -LiteralPath $verified.CanonicalPath -PathType Leaf)) { throw 'state.init failed post-mutation verification.' }
        return $result
    }

    $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
    if (-not (Test-Path -LiteralPath $approved.CanonicalPath -PathType Leaf)) { throw 'Img2threejs state file does not exist.' }
    if ($Operation -eq 'img2threejs.state.status') {
        return Invoke-Img2ThreejsTrustedNative python @($stateScript,'status','--state',$approved.CanonicalPath,'--json') $project $pythonEnvironment
    }
    if ($Operation -eq 'img2threejs.state.mark') {
        if (-not @($Step).Count) { throw 'state.mark requires at least one Step.' }
        foreach ($value in @($Step)) {
            if ($value -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'State step identifiers must be lowercase slugs.' }
        }
        foreach ($value in @($Evidence)) { Assert-Img2ThreejsStateScalar $value 'Evidence' }
        Assert-Img2ThreejsStateScalar $Reason 'Reason'
        $argv = @($stateScript,'mark') + @($Step) + @('--state',$approved.CanonicalPath,'--status',$MarkStatus)
        foreach ($value in @($Evidence)) { $argv += @('--evidence',$value) }
        if ($Reason) { $argv += @('--reason',$Reason) }
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        $result = Invoke-Img2ThreejsTrustedNative python $argv $project $pythonEnvironment
        $verified = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        if (-not (Test-Path -LiteralPath $verified.CanonicalPath -PathType Leaf)) { throw 'state.mark failed post-mutation verification.' }
        return $result
    }
    if ($Operation -eq 'img2threejs.state.next') {
        $read = Read-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath
        Assert-Img2ThreejsStoredProjectPaths -ProjectRoot $project -JsonText $read.JsonText
        $nextScript = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath 'forge/next.py'
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        $result = Invoke-Img2ThreejsTrustedNative python @($nextScript,'--state',$approved.CanonicalPath) $project $pythonEnvironment
        $verified = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        if (-not (Test-Path -LiteralPath $verified.CanonicalPath -PathType Leaf)) { throw 'state.next failed post-operation verification.' }
        return $result
    }
    throw "Unhandled state operation: $Operation"
}

function Resolve-Img2ThreejsPinnedUpstreamFile {
    param([Parameter(Mandatory)][string]$RelativePath, [switch]$AllowMissing)
    $root = Resolve-Img2ThreejsPinnedUpstreamRoot
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $root -Candidate $candidate)) {
        throw 'A registered upstream path escaped the pinned img2threejs root.'
    }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $root -Candidate $candidate
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "A required pinned img2threejs file is unavailable: $RelativePath"
    }
    return $candidate
}

function ConvertTo-Img2ThreejsChildEnvironment {
    param([Parameter(Mandatory)]$Config)
    $schema = Get-Img2ThreejsGlbConfigSchema
    $environment = [ordered]@{}
    foreach ($key in $schema.Keys) {
        $value = $Config.values.PSObject.Properties[$key].Value
        $definition = $schema[$key]
        if ($definition.Kind -in @('project-path','project-code-path','optional-project-path','diffuse-path') -and
            -not ([string]$value -in @('','none','neutral','embedded','glb'))) {
            $environment[$key] = [string]$value
        } elseif ($definition.Kind -eq 'node-list' -or $definition.Kind -eq 'level-list') {
            $environment[$key] = (@($value) -join ' ')
        } elseif ($definition.Kind -eq 'opt-in-flag') {
            $environment[$key] = if ($value) { '1' } else { '' }
        } else {
            $environment[$key] = [string]$Config.environment.PSObject.Properties[$key].Value
        }
    }
    $environment['IMG2THREEJS_SHOWCASE_ROOT'] = $Config.projectRoot
    return $environment
}

function Get-Img2ThreejsValidatedPipelineInput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$ConfigPath)

    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    $config = ConvertFrom-Img2ThreejsGlbConfig -LiteralPath $ConfigPath -ProjectRoot $project
    $glbNodes = @(Get-Img2ThreejsGlbNodeInventory -LiteralPath $config.values.CHARACTER_GLB)
    $null = Assert-Img2ThreejsConfiguredNodesExist -CharacterNodes @($config.values.CHARACTER_NODES) -GlbNodes $glbNodes
    $structural = ConvertFrom-Img2ThreejsStructuralData `
        -CharacterNodes @($config.values.CHARACTER_NODES) `
        -RegionsPath ([string]$config.values.CHARACTER_REGIONS_JSON) `
        -CellSizesPath ([string]$config.values.CHARACTER_CELL_SIZES_JSON) `
        -SectionRegionsPath ([string]$config.values.CHARACTER_SECTION_REGIONS_JSON) `
        -SpokesPath ([string]$config.values.CHARACTER_SPOKES_JSON)
    $codec = [string]$config.values.CHARACTER_CODEC
    if (-not (Test-Path -LiteralPath $codec -PathType Leaf) -or [IO.Path]::GetExtension($codec) -notin @('.ts','.tsx','.js','.mjs')) {
        throw 'CHARACTER_CODEC must resolve to an existing supported project-code entrypoint.'
    }
    $null = Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $codec
    $childEnvironment = ConvertTo-Img2ThreejsChildEnvironment -Config $config
    Write-Output -NoEnumerate ([pscustomobject][ordered]@{
        projectRoot = $project
        config = $config
        structural = $structural
        environment = $childEnvironment
    })
}

function Resolve-Img2ThreejsProjectToolEntrypoint {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('typescript','vite')][string]$Tool,
        [switch]$AllowMissing
    )
    $relative = if ($Tool -eq 'typescript') { 'node_modules/typescript/bin/tsc' } else { 'node_modules/vite/bin/vite.js' }
    $path = Resolve-Img2ThreejsContainedPath -Root $ProjectRoot -RelativePath $relative
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Tool is not already resolved inside the project; the runner will not download it."
    }
    return $path
}

function Get-Img2ThreejsCodecPlan {
    param([Parameter(Mandatory)]$PipelineInput, [switch]$AllowMissingDependencies)
    $upstream = Resolve-Img2ThreejsPinnedUpstreamRoot
    $esbuild = Resolve-Img2ThreejsPinnedUpstreamFile `
        -RelativePath 'integrations/glb_character_pipeline/node/node_modules/esbuild/lib/main.js' `
        -AllowMissing:$AllowMissingDependencies
    $mediator = Join-Path $PSScriptRoot 'img2threejs-codec-mediator.mjs'
    $output = Join-Path $PipelineInput.projectRoot ('.img2threejs/runtime/codec-' + [guid]::NewGuid().ToString('N') + '.mjs')
    $argv = @(
        $mediator,
        '--project-root', $PipelineInput.projectRoot,
        '--codec', [string]$PipelineInput.config.values.CHARACTER_CODEC,
        '--output', $output,
        '--esbuild-module', $esbuild,
        '--upstream-root', $upstream,
        '--execute-contract'
    )
    return New-Img2ThreejsPlanStep -Runtime node -Argv $argv -WorkingDirectory $PipelineInput.projectRoot `
        -EnvironmentNames @('SystemRoot','TEMP','TMP') -Purpose 'compile-contained-codec-and-check-contract'
}

function Get-Img2ThreejsProjectBuildPlan {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('typescript','vite')][string]$Tool,
        [switch]$AllowMissingDependencies
    )
    $entrypoint = Resolve-Img2ThreejsProjectToolEntrypoint -ProjectRoot $ProjectRoot -Tool $Tool -AllowMissing:$AllowMissingDependencies
    $argv = if ($Tool -eq 'typescript') { @($entrypoint, '--noEmit') } else { @($entrypoint, 'build') }
    return New-Img2ThreejsPlanStep -Runtime node -Argv $argv -WorkingDirectory $ProjectRoot `
        -EnvironmentNames @('SystemRoot','TEMP','TMP') -Purpose ($Tool + '-project-build')
}
