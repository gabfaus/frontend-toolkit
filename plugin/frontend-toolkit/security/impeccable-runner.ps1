Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ImpeccableOperationPolicy {
    $path = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Impeccable operation policy is missing.' }
    $policy = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ($policy.architecture -cne 'ftk-owned-external-effects-mediation' -or
        $policy.unknownOperationPolicy -cne 'deny' -or $policy.unknownEffectPolicy -cne 'deny') {
        throw 'Impeccable operation policy is not fail closed.'
    }
    return $policy
}

function Get-ImpeccableRegisteredOperation {
    param([Parameter(Mandatory)][string]$Operation)
    $policy = Get-ImpeccableOperationPolicy
    $definitions = @($policy.operations | Where-Object id -CEQ $Operation)
    if ($definitions.Count -ne 1) { throw "UNKNOWN Impeccable operation is denied: $Operation" }
    $knownEffects = @('LOCAL_READ_ONLY','LOCAL_PROJECT_WRITE','LOOPBACK_EPHEMERAL','NETWORK_PASSIVE','TELEMETRY','PAID_GENERATION','EXTERNAL_MUTATION','PROJECT_CODE_EXECUTION')
    foreach ($effect in @($definitions[0].effects)) {
        if ($effect -notin $knownEffects -or $effect -ceq 'UNKNOWN') { throw "UNKNOWN effect is denied for operation: $Operation" }
    }
    return $definitions[0]
}

function Assert-ImpeccableAllowedParameters {
    param([Parameter(Mandatory)][Collections.IDictionary]$BoundParameters, [Parameter(Mandatory)][string[]]$Allowed)
    $common = @([Management.Automation.Cmdlet]::CommonParameters) + @([Management.Automation.Cmdlet]::OptionalCommonParameters)
    $unexpected = @($BoundParameters.Keys | Where-Object { $_ -notin $Allowed -and $_ -notin $common })
    if ($unexpected.Count) { throw ('Operation received unregistered inputs: ' + ($unexpected -join ', ')) }
}

function Resolve-ImpeccableCanonicalProjectRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { throw 'ProjectRoot must be an existing directory.' }
    $resolved = (Resolve-Path -LiteralPath $ProjectRoot).Path
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'ProjectRoot cannot be a reparse point.'
    }
    return [IO.Path]::GetFullPath($resolved)
}

function Test-ImpeccablePathWithinRoot {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Candidate)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidatePath = [IO.Path]::GetFullPath($Candidate)
    return $candidatePath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $candidatePath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ImpeccableNoExistingReparsePoint {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Candidate)
    $rootPath = [IO.Path]::GetFullPath($Root)
    $candidatePath = [IO.Path]::GetFullPath($Candidate)
    if (-not (Test-ImpeccablePathWithinRoot $rootPath $candidatePath)) { throw 'Path escapes its authorized root.' }
    $relative = $candidatePath.Substring($rootPath.Length).TrimStart([char[]]@([char]92, [char]47))
    $cursor = $rootPath
    foreach ($segment in @($relative -split '[\\/]')) {
        if (-not $segment -or $segment -eq '.') { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Path crosses a reparse point.'
            }
        } else { break }
    }
}

function Resolve-ImpeccableGeneratedOutput {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$OutputPath)
    if ([IO.Path]::IsPathRooted($OutputPath) -or $OutputPath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'OutputPath must be a relative contained filename.'
    }
    if ($OutputPath -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:png|svg)$') {
        throw 'OutputPath must be a simple .png or .svg filename.'
    }
    $root = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.impeccable/ftk-generated'))
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $OutputPath))
    if (-not (Test-ImpeccablePathWithinRoot $root $candidate)) { throw 'OutputPath escapes the generated-output boundary.' }
    Assert-ImpeccableNoExistingReparsePoint -Root $ProjectRoot -Candidate $root
    Assert-ImpeccableNoExistingReparsePoint -Root $ProjectRoot -Candidate $candidate
    return [pscustomobject][ordered]@{ Root = $root; Path = $candidate }
}

function Resolve-ImpeccableNodeRuntime {
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json
    $node = @($lock.runtimes | Where-Object id -CEQ 'node')
    if ($node.Count -ne 1 -or $node[0].targetVersion -cne '24.20.0') { throw 'The fixed Impeccable Node runtime lock is unavailable or changed.' }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $runtime = Join-Path $localAppData 'Programs/FrontendToolkit/node-v24.20.0-win-x64/node.exe'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw 'The locked Node 24.20.0 runtime is unavailable.' }
    return [IO.Path]::GetFullPath($runtime)
}

function Resolve-ImpeccablePinnedUpstreamRoot {
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $snapshot = Join-Path (Split-Path $PSScriptRoot -Parent) 'third_party/upstreams/impeccable'
    if (Test-Path -LiteralPath $snapshot -PathType Container) { return (Resolve-Path -LiteralPath $snapshot).Path }

    # DevelopmentWorkingTree fallback: diagnostic/test input only, never release evidence.
    $mainWorktree = Join-Path (Split-Path $repoRoot -Parent) 'frontend-toolkit'
    $checkout = Join-Path $mainWorktree 'external/impeccable'
    if (-not (Test-Path -LiteralPath $checkout -PathType Container)) { throw 'Pinned Impeccable upstream is unavailable.' }
    $lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
    $entry = @($lock.dependencies | Where-Object id -CEQ 'impeccable')
    if ($entry.Count -ne 1 -or $entry[0].commitSha -cne '63b04e2530f5c7b41ea83c133daab24f34912456') {
        throw 'Pinned Impeccable upstream lock does not match the reviewed commit.'
    }
    return (Resolve-Path -LiteralPath $checkout).Path
}

function Resolve-ImpeccablePinnedScript {
    param([Parameter(Mandatory)][string]$RelativePath)
    $root = Resolve-ImpeccablePinnedUpstreamRoot
    $skillRoot = Join-Path $root '.agent/skills/impeccable'
    if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
        $skillRoot = Join-Path $root 'plugin/skills/impeccable'
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $skillRoot $RelativePath))
    if (-not (Test-ImpeccablePathWithinRoot $skillRoot $candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'Registered upstream Impeccable script is unavailable or escaped its root.'
    }
    Assert-ImpeccableNoExistingReparsePoint -Root $skillRoot -Candidate $candidate
    return $candidate
}

function New-ImpeccableChildEnvironment {
    param([Collections.IDictionary]$Additional = ([ordered]@{}))
    $environment = [ordered]@{}
    foreach ($name in @('SystemRoot','TEMP','TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
    }
    $environment['IMPECCABLE_NO_UPDATE_CHECK'] = '1'
    $environment['IMPECCABLE_NO_TELEMETRY'] = '1'
    $environment['DO_NOT_TRACK'] = '1'
    foreach ($name in $Additional.Keys) {
        if ($name -notin @('IMPECCABLE_IMAGE_GEN_FAKE')) { throw "Child environment name is not registered: $name" }
        $environment[$name] = [string]$Additional[$name]
    }
    return $environment
}

function ConvertTo-ImpeccableWindowsNativeArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)
    if ($Value -match '[\x00\r\n]') { throw 'Native argv values may not contain NUL or line breaks.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes) { [void]$builder.Append(('\' * $backslashes)); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-ImpeccableChildProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.Arguments = (@($ArgumentList | ForEach-Object {
        ConvertTo-ImpeccableWindowsNativeArgument -Value ([string]$_)
    }) -join ' ')
    $start.EnvironmentVariables.Clear()
    foreach ($name in $Environment.Keys) { $start.EnvironmentVariables.Add([string]$name, [string]$Environment[$name]) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Failed to start fixed Impeccable child.' }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Fixed Impeccable child failed with exit code $($process.ExitCode)." }
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            stdout = @($stdout -split "`r?`n" | Where-Object { $_ })
            stderr = @($stderr -split "`r?`n" | Where-Object { $_ })
            executableClass = 'locked-node'
            commandStringConstructed = $false
            environmentNames = @($Environment.Keys)
        }
    } finally { $process.Dispose() }
}

function New-ImpeccableOperationPlan {
    param([Parameter(Mandatory)]$Definition, [string]$ProjectRoot)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        operation = $Definition.id
        effects = @($Definition.effects)
        defaultState = $Definition.defaultState
        handler = $Definition.scriptHandler
        projectRoot = $ProjectRoot
        endpointRequirements = $Definition.endpointRequirements
        persistentEffect = [bool]$Definition.persistentEffect
        projectCodeExecution = [bool]$Definition.projectCodeExecution
        authorizationRequirement = $Definition.authorizationRequirement
        childEnvironmentNames = @($Definition.childEnvironmentAllowlist)
        childStarted = $false
        networkAttempted = $false
    }
}

function Invoke-ImpeccableOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [string]$ProjectRoot,
        [string]$Prompt,
        [string]$OutputPath,
        [ValidateSet('1024x1024','1536x1024','1024x1536')][string]$Size = '1536x1024',
        [string]$Scope,
        [string]$Key,
        [string]$Mode,
        [string]$TargetUrl,
        [switch]$PlanOnly
    )
    $bound = @{} + $PSBoundParameters
    $definition = Get-ImpeccableRegisteredOperation -Operation $Operation
    $canonicalProject = if ($ProjectRoot) { Resolve-ImpeccableCanonicalProjectRoot $ProjectRoot } else { $null }

    if ($Operation -eq 'impeccable.concept.local-fallback') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','Scope','Key','Mode','PlanOnly')
        if ($Scope -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $Key -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
            throw 'Local concept fallback requires validated Scope and Key.'
        }
        return [pscustomobject][ordered]@{
            schemaVersion = 1; operation = $Operation; effects = @('LOCAL_READ_ONLY'); source = 'degraded-local'
            scope = $Scope; key = $Key; mode = $Mode; networkAttempted = $false; telemetrySent = $false; childStarted = $false
        }
    }

    if ($Operation -eq 'impeccable.paid-generation.fake') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','ProjectRoot','Prompt','OutputPath','Size','PlanOnly')
        if (-not $canonicalProject) { throw 'Fake generation requires ProjectRoot.' }
        if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt.Length -gt 4000 -or $Prompt -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
            throw 'Prompt is empty, contains controls, or exceeds 4000 characters.'
        }
        if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'Fake generation requires OutputPath.' }
        $output = Resolve-ImpeccableGeneratedOutput $canonicalProject $OutputPath
        if ($PlanOnly) {
            $plan = New-ImpeccableOperationPlan $definition $canonicalProject
            $plan | Add-Member -NotePropertyName outputPath -NotePropertyValue $output.Path
            return $plan
        }
        [IO.Directory]::CreateDirectory($output.Root) | Out-Null
        Assert-ImpeccableNoExistingReparsePoint -Root $canonicalProject -Candidate $output.Root
        if (Test-Path -LiteralPath $output.Path) { throw 'Refusing to overwrite an existing generated output.' }
        $script = Resolve-ImpeccablePinnedScript 'scripts/generate-image.mjs'
        $environment = New-ImpeccableChildEnvironment ([ordered]@{ IMPECCABLE_IMAGE_GEN_FAKE = '1' })
        $result = Invoke-ImpeccableChildProcess -Executable (Resolve-ImpeccableNodeRuntime) `
            -ArgumentList @($script,'--prompt',$Prompt,'--out',$output.Path,'--size',$Size) `
            -WorkingDirectory $canonicalProject -Environment $environment
        Assert-ImpeccableNoExistingReparsePoint -Root $canonicalProject -Candidate $output.Path
        if (-not (Test-Path -LiteralPath $output.Path -PathType Leaf)) { throw 'Fake generation did not create its contained output.' }
        return [pscustomobject][ordered]@{
            schemaVersion = 1; operation = $Operation; effects = @('LOCAL_PROJECT_WRITE'); outputPath = $output.Path
            fake = $true; paid = $false; networkAttempted = $false; childStarted = $true; child = $result
        }
    }

    $allowed = @('Operation','PlanOnly')
    if (@($definition.allowedInputs) -contains 'ProjectRoot') { $allowed += 'ProjectRoot' }
    if (@($definition.allowedInputs) -contains 'TargetUrl') { $allowed += 'TargetUrl' }
    Assert-ImpeccableAllowedParameters $bound $allowed
    if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
    throw "Operation $Operation is registered but blocked at the direct runner boundary: $($definition.authorizationRequirement)"
}
