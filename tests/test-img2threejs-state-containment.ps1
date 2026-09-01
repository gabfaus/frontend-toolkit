Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'plugin/frontend-toolkit/security/img2threejs-state-guard.ps1')

function New-SyntheticProject {
    param([string]$Fixture, [string]$Name)
    $project = Join-Path $Fixture $Name
    [IO.Directory]::CreateDirectory($project) | Out-Null
    return $project
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    try {
        $null = $Action.Invoke()
        throw ($Label + ' did not fail closed.')
    } catch {
        if ($_.Exception.Message -eq ($Label + ' did not fail closed.')) { throw }
        if ($_.Exception.Message -notmatch $Pattern) {
            throw ($Label + ' returned the wrong error: ' + $_.Exception.Message)
        }
    }
}

function Assert-TraceAdjacency {
    param([string[]]$Trace, [string]$Before, [string]$After, [string]$Label)
    $beforeIndex = [Array]::LastIndexOf($Trace, $Before)
    $afterIndex = [Array]::LastIndexOf($Trace, $After)
    if ($beforeIndex -lt 0 -or $afterIndex -ne ($beforeIndex + 1)) {
        throw ($Label + ' did not keep the recheck immediately before the effect.')
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-img2threejs-state-' + [guid]::NewGuid().ToString('N'))
$reparsePaths = New-Object 'System.Collections.Generic.List[string]'
try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $project = New-SyntheticProject -Fixture $fixture -Name 'allowed-project'

    $defaultJson = [ordered]@{ schemaVersion = 1; status = 'active' } | ConvertTo-Json -Compress
    $created = New-Img2ThreejsState -ProjectRoot $project -JsonText $defaultJson
    if ($created.CanonicalPath -cne (Join-Path $project '.img2threejs\state.json')) {
        throw 'Default state did not resolve to the authorized root.'
    }
    if ((Read-Img2ThreejsState -ProjectRoot $project).JsonText -cne $defaultJson) {
        throw 'Default state read did not preserve JSON.'
    }

    $nestedJson = [ordered]@{ nested = $true } | ConvertTo-Json -Compress
    $nested = Write-Img2ThreejsState -ProjectRoot $project -StatePath '.img2threejs/nested/state.json' -JsonText $nestedJson
    if ((Read-Img2ThreejsState -ProjectRoot $project -StatePath '.img2threejs/nested/state.json').JsonText -cne $nestedJson) {
        throw 'Nested state roundtrip failed.'
    }
    $deepPath = '.img2threejs/one/two/three/state.json'
    $deepJson = [ordered]@{ depth = 3 } | ConvertTo-Json -Compress
    Write-Img2ThreejsState -ProjectRoot $project -StatePath $deepPath -JsonText $deepJson | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $project '.img2threejs\one\two\three\state.json') -PathType Leaf)) {
        throw 'Multi-level nested state was not created.'
    }
    $updatedJson = [ordered]@{ schemaVersion = 1; status = 'complete' } | ConvertTo-Json -Compress
    $updated = Update-Img2ThreejsState -ProjectRoot $project -JsonText $updatedJson
    if ((Read-Img2ThreejsState -ProjectRoot $project).JsonText -cne $updatedJson) {
        throw 'State update did not replace the authorized target.'
    }
    Assert-TraceAdjacency -Trace @($nested.Trace) -Before 'pre-atomic-commit-recheck' -After 'atomic-commit-complete' -Label 'Nested write'
    Assert-TraceAdjacency -Trace @($updated.Trace) -Before 'pre-atomic-commit-recheck' -After 'atomic-commit-complete' -Label 'Update'
    Assert-TraceAdjacency -Trace @($nested.Trace) -Before 'pre-temporary-create-recheck' -After 'temporary-written' -Label 'Temporary write'
    if (@($updated.Trace)[-1] -cne 'post-write-verified') { throw 'Mutation lacked post-write verification.' }

    $contract = @(Get-Img2ThreejsStateOperationContract)
    $expectedOperations = @('init','status','mark','next','read','write','update')
    if (($contract.Operation -join ',') -cne ($expectedOperations -join ',')) {
        throw 'State operation contract drifted.'
    }
    if (($contract | Where-Object Operation -ceq 'mark').Access -cne 'update') {
        throw 'mark is not preserved through the guarded update contract.'
    }
    if (($contract | Where-Object Operation -ceq 'next').Access -cne 'read-update') {
        throw 'next is not preserved through the guarded read/update contract.'
    }

    $blockedProject = New-SyntheticProject -Fixture $fixture -Name 'blocked-project'
    $outside = Join-Path $fixture 'outside'
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $sentinel = Join-Path $outside 'sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'unchanged')
    $absolute = Join-Path $outside 'absolute.json'
    $blockedJson = [ordered]@{ blocked = $true } | ConvertTo-Json -Compress
    $blockedCases = @(
        @{ Path = '.img2threejs/../escape.json'; Pattern = 'Traversal'; Label = 'single traversal' }
        @{ Path = '.img2threejs/a/../../../escape.json'; Pattern = 'Traversal'; Label = 'multiple traversal' }
        @{ Path = $absolute; Pattern = 'Absolute'; Label = 'absolute external path' }
        @{ Path = 'other/state.json'; Pattern = 'start with'; Label = 'foreign project directory' }
        @{ Path = '.img2threejs-evil/state.json'; Pattern = 'start with'; Label = 'sibling-prefix confusion' }
        @{ Path = '.img2threejs/state.txt'; Pattern = '\.json'; Label = 'foreign extension' }
        @{ Path = '.img2threejs/state.json:stream'; Pattern = 'alternate data streams'; Label = 'alternate data stream' }
        @{ Path = 'C:relative.json'; Pattern = 'Drive-relative|Absolute'; Label = 'drive-relative path' }
        @{ Path = '\\server\share\state.json'; Pattern = 'Absolute|UNC'; Label = 'UNC path' }
    )
    foreach ($case in $blockedCases) {
        Assert-Throws -Action {
            Write-Img2ThreejsState -ProjectRoot $blockedProject -StatePath $case.Path -JsonText $blockedJson | Out-Null
        } -Pattern $case.Pattern -Label $case.Label
    }
    if (Test-Path -LiteralPath (Join-Path $blockedProject '.img2threejs')) {
        throw 'A write occurred before malicious state input validation completed.'
    }
    if ([IO.File]::ReadAllText($sentinel) -cne 'unchanged') { throw 'A blocked write changed the outside sentinel.' }

    $caseProject = New-SyntheticProject -Fixture $fixture -Name 'case-project'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Write-Img2ThreejsState -ProjectRoot $caseProject -StatePath '.IMG2THREEJS/Case/state.json' -JsonText $nestedJson | Out-Null
        if (-not (Test-Path -LiteralPath (Join-Path $caseProject '.img2threejs\Case\state.json') -PathType Leaf)) {
            throw 'Windows case-insensitive authorized-root handling failed.'
        }
    }

    $junctionProject = New-SyntheticProject -Fixture $fixture -Name 'junction-project'
    $junctionRoot = Join-Path $junctionProject '.img2threejs'
    [IO.Directory]::CreateDirectory($junctionRoot) | Out-Null
    $junction = Join-Path $junctionRoot 'escape'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    [void]$reparsePaths.Add($junction)
    Assert-Throws -Action {
        Write-Img2ThreejsState -ProjectRoot $junctionProject -StatePath '.img2threejs/escape/new/state.json' -JsonText $blockedJson | Out-Null
    } -Pattern 'Reparse points' -Label 'nonexistent target below outside-resolving ancestor'

    $ancestorProject = New-SyntheticProject -Fixture $fixture -Name 'ancestor-project'
    $ancestorRoot = Join-Path $ancestorProject '.img2threejs'
    $realParent = Join-Path $ancestorRoot 'real'
    [IO.Directory]::CreateDirectory($realParent) | Out-Null
    $ancestorJunction = Join-Path $realParent 'linked'
    New-Item -ItemType Junction -Path $ancestorJunction -Target $outside | Out-Null
    [void]$reparsePaths.Add($ancestorJunction)
    Assert-Throws -Action {
        Read-Img2ThreejsState -ProjectRoot $ancestorProject -StatePath '.img2threejs/real/linked/state.json' | Out-Null
    } -Pattern 'Reparse points' -Label 'reparse ancestor'

    $rootProject = New-SyntheticProject -Fixture $fixture -Name 'root-reparse-project'
    $rootJunction = Join-Path $rootProject '.img2threejs'
    New-Item -ItemType Junction -Path $rootJunction -Target $outside | Out-Null
    [void]$reparsePaths.Add($rootJunction)
    Assert-Throws -Action {
        Write-Img2ThreejsState -ProjectRoot $rootProject -JsonText $blockedJson | Out-Null
    } -Pattern 'Reparse points' -Label 'authorized root reparse'

    $physicalProject = New-SyntheticProject -Fixture $fixture -Name 'physical-project'
    $projectAlias = Join-Path $fixture 'project-alias'
    New-Item -ItemType Junction -Path $projectAlias -Target $physicalProject | Out-Null
    [void]$reparsePaths.Add($projectAlias)
    Assert-Throws -Action {
        Write-Img2ThreejsState -ProjectRoot $projectAlias -JsonText $blockedJson | Out-Null
    } -Pattern 'Reparse points' -Label 'project-root ancestor reparse'

    $symlinkCreated = $false
    $symlinkProject = New-SyntheticProject -Fixture $fixture -Name 'symlink-project'
    $symlinkRoot = Join-Path $symlinkProject '.img2threejs'
    [IO.Directory]::CreateDirectory($symlinkRoot) | Out-Null
    try {
        New-Item -ItemType SymbolicLink -Path (Join-Path $symlinkRoot 'escape') -Target $outside -ErrorAction Stop | Out-Null
        $symlinkCreated = $true
        [void]$reparsePaths.Add((Join-Path $symlinkRoot 'escape'))
        Assert-Throws -Action {
            Write-Img2ThreejsState -ProjectRoot $symlinkProject -StatePath '.img2threejs/escape/state.json' -JsonText $blockedJson | Out-Null
        } -Pattern 'Reparse points' -Label 'symbolic-link escape'
    } catch {
        if ($symlinkCreated) { throw }
    }

    Assert-Throws -Action {
        New-Img2ThreejsState -ProjectRoot $project -JsonText $blockedJson | Out-Null
    } -Pattern 'Refusing to overwrite' -Label 'init overwrite'
    Assert-Throws -Action {
        Update-Img2ThreejsState -ProjectRoot $project -StatePath '.img2threejs/missing.json' -JsonText $blockedJson | Out-Null
    } -Pattern 'Cannot update missing' -Label 'missing update'
    Assert-Throws -Action {
        Write-Img2ThreejsState -ProjectRoot $project -StatePath '.img2threejs/invalid.json' -JsonText '{invalid' | Out-Null
    } -Pattern 'valid JSON' -Label 'invalid JSON'

    $policy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/effect-policy.json') | ConvertFrom-Json
    foreach ($operation in @('img2threejs.state.init','img2threejs.state.status','img2threejs.state.mark','img2threejs.state.next','img2threejs.state.create','img2threejs.state.read','img2threejs.state.write','img2threejs.state.update')) {
        $definition = $policy.operations | Where-Object id -ceq $operation
        if ($definition.status -ne 'enabled' -or -not $definition.stateGuardRequired) {
            throw "$operation must be enabled only through the SR2D state guard."
        }
    }
} finally {
    foreach ($reparsePath in $reparsePaths) {
        if (Test-Path -LiteralPath $reparsePath) { [IO.Directory]::Delete($reparsePath, $false) }
    }
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete($fixture, $true) }
}

Write-Output 'PASS: default, nested, deep, read, create, write, and update state remain available inside .img2threejs.'
Write-Output 'PASS: traversal, absolute/foreign paths, prefix confusion, Windows path forms, and non-JSON targets fail closed before state writes.'
Write-Output 'PASS: authorized-root and descendant junction/symlink/reparse boundaries are rejected, including nonexistent targets.'
Write-Output 'PASS: mutating handlers recheck immediately before atomic commit and verify the canonical target after writing.'
Write-Output 'PASS: init/status/mark/next/create/read/write/update are enabled only through the SR2D guarded-operation contract.'
