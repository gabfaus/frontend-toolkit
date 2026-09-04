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

function Assert-ImpeccableIntegratedPolicyIdentity {
    $authorityPath = Join-Path $PSScriptRoot 'impeccable-authority-policy.json'
    $operationPath = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
    $artifactLockPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'external-skills.lock.json'
    foreach ($path in @($authorityPath, $operationPath, $artifactLockPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Impeccable integrated identity contract is incomplete.' }
    }
    $authority = Get-Content -Raw -LiteralPath $authorityPath | ConvertFrom-Json
    $operation = Get-Content -Raw -LiteralPath $operationPath | ConvertFrom-Json
    $artifact = Get-Content -Raw -LiteralPath $artifactLockPath | ConvertFrom-Json
    $locked = @($artifact.dependencies | Where-Object id -CEQ 'impeccable')
    if ($locked.Count -ne 1 -or
        $authority.upstream.commitSha -cne $operation.upstreamCommit -or
        $authority.upstream.commitSha -cne $locked[0].commitSha -or
        $authority.upstream.snapshotTreeSha256 -cne $locked[0].snapshotTreeSha256) {
        throw 'Impeccable authority, effect, or packaged source identity drifted.'
    }
    if ($authority.upstream.commitSha -cnotmatch '^[0-9a-f]{40}$' -or
        $authority.upstream.snapshotTreeSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $authority.upstream.skillEntrySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        @($authority.upstream.contractFiles).Count -ne 4 -or
        @($authority.upstream.contractFiles | Where-Object { $_.sha256 -cnotmatch '^[0-9a-f]{64}$' }).Count) {
        throw 'Impeccable authority fingerprint is malformed or incomplete.'
    }
    $upstreamRoot = Resolve-ImpeccablePinnedUpstreamRoot
    if (Test-Path -LiteralPath (Join-Path $upstreamRoot '.git')) {
        $safeRoot = $upstreamRoot.Replace('\', '/')
        $head = (& git -c "safe.directory=$safeRoot" -C $upstreamRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $head -cne $authority.upstream.commitSha) {
            throw 'Impeccable upstream HEAD does not match the authority fingerprint.'
        }
        if (& git -c "safe.directory=$safeRoot" -C $upstreamRoot status --porcelain) {
            throw 'Impeccable upstream checkout is dirty and cannot establish source identity.'
        }
    }
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
    $lockPath = Join-Path $PSScriptRoot '../integrations/toolchain.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { $lockPath = Join-Path $repoRoot 'integrations/toolchain.lock.json' }
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $node = @($lock.runtimes | Where-Object id -CEQ 'node')
    if ($node.Count -ne 1 -or $node[0].targetVersion -cne '24.20.0') { throw 'The fixed Impeccable Node runtime lock is unavailable or changed.' }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $runtime = Join-Path $localAppData 'Programs/FrontendToolkit/node-v24.20.0-win-x64/node.exe'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw 'The locked Node 24.20.0 runtime is unavailable.' }
    return [IO.Path]::GetFullPath($runtime)
}

function Resolve-ImpeccableStaticHtmlModuleRoot {
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $candidates = @(
        (Join-Path $PSScriptRoot '../third_party/static-html-dependencies/node_modules'),
        (Join-Path $repoRoot 'third_party/runtimes/impeccable-static-html/node_modules')
    )
    $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($existing.Count -ne 1) { throw 'Canonical static-HTML module root is missing or ambiguous.' }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $existing[0]).Path)
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Canonical static-HTML module root cannot be a reparse point.'
    }
    return $resolved
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
        [Parameter(Mandatory)][Collections.IDictionary]$Environment,
        [AllowEmptyString()][string]$StandardInputText
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $PSBoundParameters.ContainsKey('StandardInputText')
    $utf8 = New-Object Text.UTF8Encoding($false)
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
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
        if ($start.RedirectStandardInput) {
            $inputBytes = [Text.Encoding]::UTF8.GetBytes($StandardInputText)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Close()
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $diagnostic = $null
            try { $diagnostic = ($stderr | ConvertFrom-Json -ErrorAction Stop).error } catch { $diagnostic = $null }
            if ($diagnostic -and $diagnostic -is [string] -and $diagnostic.Length -le 512) {
                throw "Fixed Impeccable child failed: $diagnostic"
            }
            throw "Fixed Impeccable child failed with exit code $($process.ExitCode)."
        }
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

function Resolve-ImpeccablePinnedSkillRoot {
    $script = Resolve-ImpeccablePinnedScript -RelativePath 'scripts/detect.mjs'
    return [IO.Path]::GetFullPath((Split-Path (Split-Path $script -Parent) -Parent))
}

function Invoke-ImpeccableDetectorBoundary {
    param(
        [Parameter(Mandatory)][ValidateSet('impeccable.detector.local','impeccable.detector.project','impeccable.detector.payload','impeccable.detector.csp')][string]$Operation,
        [string]$ProjectRoot,
        [string]$InputPath,
        [AllowEmptyString()][string]$Content,
        [string]$ContentType,
        [string]$DetectorOptionsJson
    )
    Assert-ImpeccableIntegratedPolicyIdentity
    $detector = Join-Path $PSScriptRoot 'impeccable-detector.mjs'
    $staticRuntime = Join-Path $PSScriptRoot 'impeccable-static-runtime.mjs'
    $policy = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
    foreach ($path in @($detector, $staticRuntime, $policy)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A fixed Impeccable detector boundary file is unavailable or reparsed.'
        }
    }
    $skillRoot = Resolve-ImpeccablePinnedSkillRoot
    $request = [ordered]@{ operation = $Operation }
    if ($ProjectRoot) { $request.projectRoot = $ProjectRoot }
    if ($InputPath) { $request.inputPath = $InputPath }
    if ($PSBoundParameters.ContainsKey('Content')) { $request.content = $Content }
    if ($ContentType) { $request.contentType = $ContentType }
    if ($DetectorOptionsJson) {
        if ($DetectorOptionsJson.Length -gt 65536) { throw 'DetectorOptionsJson exceeds the 64 KiB limit.' }
        try { $request.options = $DetectorOptionsJson | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'DetectorOptionsJson must be valid JSON.' }
    }
    $requestJson = $request | ConvertTo-Json -Depth 16 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($requestJson) -gt 2097152) { throw 'Detector request exceeds the 2 MiB limit.' }

    $readRoots = @($PSScriptRoot, (Resolve-ImpeccablePinnedUpstreamRoot), $skillRoot, (Resolve-ImpeccableStaticHtmlModuleRoot))
    $packagedToolchainRoot = Join-Path $PSScriptRoot '../integrations'
    if (Test-Path -LiteralPath $packagedToolchainRoot -PathType Container) { $readRoots += $packagedToolchainRoot }
    if ($ProjectRoot) { $readRoots += $ProjectRoot }
    $arguments = @('--permission')
    foreach ($readRoot in $readRoots) { $arguments += "--allow-fs-read=$readRoot" }
    $staticRuntimeUrl = ([Uri]$staticRuntime).AbsoluteUri
    $arguments += @("--import=$staticRuntimeUrl", $detector, $policy, $skillRoot)
    $child = Invoke-ImpeccableChildProcess -Executable (Resolve-ImpeccableNodeRuntime) `
        -ArgumentList $arguments -WorkingDirectory $(if ($ProjectRoot) { $ProjectRoot } else { $PSScriptRoot }) `
        -Environment (New-ImpeccableChildEnvironment) -StandardInputText $requestJson
    if (@($child.stderr).Count) { throw 'Fixed Impeccable detector emitted unexpected stderr.' }
    $json = @($child.stdout) -join "`n"
    try { $result = $json | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Fixed Impeccable detector did not return typed JSON.' }
    if ($result.operation -cne $Operation -or $result.schemaVersion -ne 2 -or
        $result.safety.networkAttempted -ne $false -or $result.safety.writesPerformed -ne $false -or
        $result.safety.projectCodeExecuted -ne $false -or $result.safety.parentSecretsInherited -ne $false) {
        throw 'Fixed Impeccable detector returned an invalid safety contract.'
    }
    return $result
}

function Resolve-ImpeccableContainedInput {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath) -or [IO.Path]::IsPathRooted($InputPath) -or
        $InputPath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'InputPath must be a relative contained path.'
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $InputPath))
    if (-not (Test-ImpeccablePathWithinRoot $ProjectRoot $candidate)) { throw 'InputPath escapes ProjectRoot.' }
    Assert-ImpeccableNoExistingReparsePoint -Root $ProjectRoot -Candidate $candidate
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'InputPath must identify an existing file.' }
    $item = Get-Item -LiteralPath $candidate -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'InputPath cannot be a reparse point.' }
    if ($item.Extension.ToLowerInvariant() -notin @('.html','.css','.scss','.js','.jsx','.ts','.tsx','.vue','.svelte')) {
        throw 'InputPath extension is not registered for the local detector.'
    }
    if ($item.Length -gt 1048576) { throw 'InputPath exceeds the 1 MiB local detector limit.' }
    return $item.FullName
}

function Get-ImpeccableHookStatus {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    Assert-ImpeccableIntegratedPolicyIdentity
    return [pscustomobject][ordered]@{
        schemaVersion = 1; operation = 'impeccable.hooks.status'; effects = @('LOCAL_READ_ONLY')
        projectRoot = $ProjectRoot; source = 'ftk-declarative-hook-status'; ftkHooksEnabled = $false
        upstreamHookInspected = $false; mutationPerformed = $false; childStarted = $false; networkAttempted = $false
    }
}

function Get-ImpeccableBoundaryDoctor {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    Assert-ImpeccableIntegratedPolicyIdentity
    return [pscustomobject][ordered]@{
        schemaVersion = 1; operation = 'impeccable.doctor.report'; effects = @('LOCAL_READ_ONLY')
        projectRoot = $ProjectRoot; sourceIdentity = 'verified'; unknownPolicy = 'deny'
        hostAuthorizationBoundary = 'unavailable'; telemetryDefault = 'off'; updateCheckDefault = 'off'
        selfUpdate = 'denied'; mutationPerformed = $false; childStarted = $false; networkAttempted = $false
    }
}

function Invoke-ImpeccableContextExtractor {
    param(
        [Parameter(Mandatory)][ValidateSet('context','live-event')][string]$Mode,
        [string]$ProjectRoot,
        [string]$Capability,
        [string]$EventJson
    )
    Assert-ImpeccableIntegratedPolicyIdentity
    $extractor = Join-Path $PSScriptRoot 'impeccable-context-extractor.mjs'
    $mediator = Join-Path $PSScriptRoot 'impeccable-context-mediator.mjs'
    $authorityPolicy = Join-Path $PSScriptRoot 'impeccable-authority-policy.json'
    $operationPolicy = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
    foreach ($path in @($extractor, $mediator, $authorityPolicy, $operationPolicy)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A fixed Impeccable context boundary module is unavailable.' }
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'A fixed Impeccable context boundary module is a reparse point.'
        }
    }
    $arguments = @(
        $extractor, '--mode', $Mode,
        '--authorityPolicy', $authorityPolicy,
        '--operationPolicy', $operationPolicy,
        '--mediator', $mediator
    )
    if ($Mode -ceq 'context') { $arguments += @('--projectRoot', $ProjectRoot, '--capability', $Capability) }
    else { $arguments += @('--eventJson', $EventJson) }
    $child = Invoke-ImpeccableChildProcess -Executable (Resolve-ImpeccableNodeRuntime) `
        -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -Environment (New-ImpeccableChildEnvironment)
    try { return (($child.stdout -join "`n") | ConvertFrom-Json) }
    catch { throw 'The fixed Impeccable context boundary returned an invalid typed envelope.' }
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
        [string]$InputPath,
        [string]$Prompt,
        [string]$OutputPath,
        [ValidateSet('1024x1024','1536x1024','1024x1536')][string]$Size = '1536x1024',
        [string]$Scope,
        [string]$Key,
        [string]$Mode,
        [string]$TargetUrl,
        [string]$Capability,
        [string]$EventJson,
        [AllowEmptyString()][string]$Content,
        [ValidateSet('html','css','scss','sass','less','jsx','tsx','js','ts','vue','svelte','astro')][string]$ContentType,
        [string]$DetectorOptionsJson,
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

    if ($Operation -eq 'impeccable.context.local') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','ProjectRoot','Capability','PlanOnly')
        if (-not $canonicalProject) { throw 'Local context requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        if ([string]::IsNullOrWhiteSpace($Capability)) { throw 'Local context execution requires Capability.' }
        return Invoke-ImpeccableContextExtractor -Mode context -ProjectRoot $canonicalProject -Capability $Capability
    }

    if ($Operation -eq 'impeccable.detector.local') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','ProjectRoot','InputPath','DetectorOptionsJson','PlanOnly')
        if (-not $canonicalProject) { throw 'Local detector requires ProjectRoot.' }
        if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Local detector requires InputPath.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -ProjectRoot $canonicalProject -InputPath $InputPath -DetectorOptionsJson $DetectorOptionsJson
    }

    if ($Operation -eq 'impeccable.detector.project') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','ProjectRoot','InputPath','DetectorOptionsJson','PlanOnly')
        if (-not $canonicalProject) { throw 'Project detector requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -ProjectRoot $canonicalProject -InputPath $InputPath -DetectorOptionsJson $DetectorOptionsJson
    }

    if ($Operation -eq 'impeccable.detector.payload') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','Content','ContentType','DetectorOptionsJson','PlanOnly')
        if (-not $bound.ContainsKey('Content') -or [string]::IsNullOrWhiteSpace($ContentType)) { throw 'Payload detector requires typed Content and ContentType.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $null }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -Content $Content -ContentType $ContentType -DetectorOptionsJson $DetectorOptionsJson
    }

    if ($Operation -eq 'impeccable.detector.csp') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','ProjectRoot','PlanOnly')
        if (-not $canonicalProject) { throw 'CSP detector requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -ProjectRoot $canonicalProject
    }

    if ($Operation -eq 'impeccable.hooks.status') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','ProjectRoot','PlanOnly')
        if (-not $canonicalProject) { throw 'Hook status requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Get-ImpeccableHookStatus -ProjectRoot $canonicalProject
    }

    if ($Operation -eq 'impeccable.doctor.report') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','ProjectRoot','PlanOnly')
        if (-not $canonicalProject) { throw 'Doctor/report requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Get-ImpeccableBoundaryDoctor -ProjectRoot $canonicalProject
    }

    if ($Operation -eq 'impeccable.live.event-mediate') {
        Assert-ImpeccableAllowedParameters $bound @('Operation','EventJson','PlanOnly')
        if ([string]::IsNullOrWhiteSpace($EventJson) -or $EventJson.Length -gt 1048576) {
            throw 'Live event mediation requires bounded EventJson.'
        }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $null }
        return Invoke-ImpeccableContextExtractor -Mode live-event -EventJson $EventJson
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
