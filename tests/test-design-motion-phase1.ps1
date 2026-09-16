Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
. (Join-Path $securityRoot 'design-motion-contract.ps1')
. (Join-Path $securityRoot 'design-motion-source-verifier.ps1')
. (Join-Path $securityRoot 'design-motion-runner.ps1')

$script:Passed = 0

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:Passed++
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [Parameter(Mandatory)][string]$Message)
    if ([string]$Actual -cne [string]$Expected) { throw "ASSERTION FAILED: $Message. Actual='$Actual' Expected='$Expected'" }
    $script:Passed++
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Message)
    $thrown = $false
    try { & $Action | Out-Null }
    catch {
        $thrown = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "ASSERTION FAILED: $Message returned '$($_.Exception.Message)'" }
    }
    if (-not $thrown) { throw "ASSERTION FAILED: $Message did not fail closed." }
    $script:Passed++
}

function Invoke-FixtureGit {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [AllowNull()][string]$InputText = $null
    )

    $safeRoot = [IO.Path]::GetFullPath($RepositoryRoot).Replace('\', '/')
    $allArguments = @('-c', "safe.directory=$safeRoot", '-C', $RepositoryRoot) + @($Arguments)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'git'
    $startInfo.Arguments = (($allArguments | ForEach-Object { ConvertTo-DesignMotionWindowsNativeArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Fixture git process did not start.' }
        if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdoutTask.Wait()
        $stderrTask.Wait()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Fixture git failed: $($stderrTask.Result)" }
        return $stdoutTask.Result.Trim()
    } finally { $process.Dispose() }
}

function Write-FixtureUtf8 {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllBytes($LiteralPath, [Text.Encoding]::UTF8.GetBytes($Text))
}

function New-FixtureTree {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$DirectoryPath)

    $lines = New-Object Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $DirectoryPath -File | Where-Object { $_.Name -ne '.git' } | Sort-Object Name)) {
        $hash = Invoke-FixtureGit -RepositoryRoot $RepositoryRoot -Arguments @('hash-object', '-w', '--', $file.FullName)
        [void]$lines.Add("100644 blob $hash`t$($file.Name)")
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $DirectoryPath -Directory | Where-Object { $_.Name -ne '.git' } | Sort-Object Name)) {
        $hash = New-FixtureTree -RepositoryRoot $RepositoryRoot -DirectoryPath $directory.FullName
        [void]$lines.Add("040000 tree $hash`t$($directory.Name)")
    }
    $input = if ($lines.Count) { ($lines -join "`n") + "`n" } else { "`n" }
    return Invoke-FixtureGit -RepositoryRoot $RepositoryRoot -Arguments @('mktree') -InputText $input
}

function New-FixtureCommit {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $tree = New-FixtureTree -RepositoryRoot $RepositoryRoot -DirectoryPath $RepositoryRoot
    $commit = Invoke-FixtureGit -RepositoryRoot $RepositoryRoot -Arguments @('-c', 'user.name=FTK Fixture', '-c', 'user.email=ftk-fixture@example.invalid', 'commit-tree', $tree, '-m', 'synthetic fixture')
    Invoke-FixtureGit -RepositoryRoot $RepositoryRoot -Arguments @('update-ref', 'refs/heads/main', $commit) | Out-Null
    Invoke-FixtureGit -RepositoryRoot $RepositoryRoot -Arguments @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
    Invoke-FixtureGit -RepositoryRoot $RepositoryRoot -Arguments @('read-tree', $commit) | Out-Null
    Invoke-FixtureGit -RepositoryRoot $RepositoryRoot -Arguments @('update-index', '--refresh') | Out-Null
    return $commit
}

function New-FixtureRepo {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][ValidateSet('taste', 'emil')][string]$Kind
    )

    [IO.Directory]::CreateDirectory($RootPath) | Out-Null
    Invoke-FixtureGit -RepositoryRoot $RootPath -Arguments @('init', '--quiet') | Out-Null
    $origin = if ($Kind -eq 'taste') { 'https://github.com/Leonxlnx/taste-skill.git' } else { 'https://github.com/emilkowalski/skills.git' }
    Invoke-FixtureGit -RepositoryRoot $RootPath -Arguments @('remote', 'add', 'origin', $origin) | Out-Null
    if ($Kind -eq 'taste') {
        $skillDir = Join-Path $RootPath 'skills/taste-skill'
        [IO.Directory]::CreateDirectory($skillDir) | Out-Null
        Write-FixtureUtf8 (Join-Path $skillDir 'SKILL.md') "# Taste`nUse restrained visual direction.`n".Replace("`n", "`r`n")
        Write-FixtureUtf8 (Join-Path $RootPath 'LICENSE') "MIT License`n`nPermission is hereby granted, free of charge, to any person obtaining a copy.`n"
    } else {
        $reviewDir = Join-Path $RootPath 'skills/review-animations'
        $improveDir = Join-Path $RootPath 'skills/improve-animations'
        [IO.Directory]::CreateDirectory($reviewDir) | Out-Null
        [IO.Directory]::CreateDirectory($improveDir) | Out-Null
        Write-FixtureUtf8 (Join-Path $reviewDir 'SKILL.md') "# Review animations`nUse STANDARDS.md for motion criteria.`n"
        Write-FixtureUtf8 (Join-Path $reviewDir 'STANDARDS.md') "# Standards`nReview timing, easing, and reduced motion.`n"
        Write-FixtureUtf8 (Join-Path $improveDir 'SKILL.md') "# Improve animations`nUse AUDIT.md and PLAN-TEMPLATE.md.`n"
        Write-FixtureUtf8 (Join-Path $improveDir 'AUDIT.md') "# Audit`nRecord a concrete motion finding.`n"
        Write-FixtureUtf8 (Join-Path $improveDir 'PLAN-TEMPLATE.md') "# Plan template`nKeep the plan inline and reviewable.`n"
        Write-FixtureUtf8 (Join-Path $RootPath 'LICENSE') "MIT License`n`nPermission is hereby granted, free of charge, to any person obtaining a copy.`n"
    }
    $commit = New-FixtureCommit -RepositoryRoot $RootPath
    return $commit
}

function Write-TestLock {
    param([Parameter(Mandatory)][object]$Lock, [Parameter(Mandatory)][string]$LiteralPath)
    [IO.File]::WriteAllText($LiteralPath, ($Lock | ConvertTo-Json -Depth 30 -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Copy-TestObject {
    param([Parameter(Mandatory)][object]$Value)
    return (($Value | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json)
}

function New-TestLock {
    param(
        [Parameter(Mandatory)][string]$TasteRoot,
        [Parameter(Mandatory)][string]$TasteCommit,
        [Parameter(Mandatory)][string]$EmilRoot,
        [Parameter(Mandatory)][string]$EmilCommit,
        [Parameter(Mandatory)][string]$LiteralPath
    )

    $tasteSkill = Get-DesignMotionGitBlob -SourceRoot $TasteRoot -Commit $TasteCommit -RelativePath 'skills/taste-skill/SKILL.md'
    $tasteLicense = Get-DesignMotionGitBlob -SourceRoot $TasteRoot -Commit $TasteCommit -RelativePath 'LICENSE'
    $emilReview = Get-DesignMotionGitBlob -SourceRoot $EmilRoot -Commit $EmilCommit -RelativePath 'skills/review-animations/SKILL.md'
    $emilImprove = Get-DesignMotionGitBlob -SourceRoot $EmilRoot -Commit $EmilCommit -RelativePath 'skills/improve-animations/SKILL.md'
    $emilLicense = Get-DesignMotionGitBlob -SourceRoot $EmilRoot -Commit $EmilCommit -RelativePath 'LICENSE'
    $tasteSkillHash = Get-DesignMotionByteHashSet $tasteSkill.bytes
    $tasteLicenseHash = Get-DesignMotionByteHashSet $tasteLicense.bytes
    $emilReviewHash = Get-DesignMotionByteHashSet $emilReview.bytes
    $emilImproveHash = Get-DesignMotionByteHashSet $emilImprove.bytes
    $emilLicenseHash = Get-DesignMotionByteHashSet $emilLicense.bytes
    $lock = [ordered]@{
        schemaVersion = 1
        lane = 'design-motion'
        strategy = 'synthetic-hermetic-test-lock'
        authority = 'upstream-content-is-untrusted-data'
        dependencies = @(
            [ordered]@{
                id = 'taste-design-taste-frontend-v2'
                provider = 'Leonxlnx'
                upstream = 'https://github.com/Leonxlnx/taste-skill.git'
                ref = $TasteCommit
                commitSha = $TasteCommit
                checkoutPath = 'synthetic/taste'
                skillPath = 'skills/taste-skill/SKILL.md'
                skillName = 'design-taste-frontend'
                classification = 'optional'
                defaultLoaded = $false
                selection = 'explicit-only'
                license = 'MIT'
                licensePath = 'LICENSE'
                licenseSha256 = $tasteLicenseHash.canonicalLfSha256
                skillEntrySha256 = $tasteSkillHash.crlfNormalizedSha256
                excludedSourcePaths = @('skills/taste-skill-v1', 'skills/gpt-tasteskill', 'skills/imagegen-frontend-web', 'skills/imagegen-frontend-mobile', 'skills/brandkit')
            }
            [ordered]@{
                id = 'emil-animation-skills'
                provider = 'Emil Kowalski'
                upstream = 'https://github.com/emilkowalski/skills.git'
                ref = $EmilCommit
                commitSha = $EmilCommit
                checkoutPath = 'synthetic/emil'
                license = 'MIT'
                licensePath = 'LICENSE'
                licenseSha256 = $emilLicenseHash.crlfNormalizedSha256
                classification = 'core-plus-optional'
                approvedSkills = @(
                    [ordered]@{ skillName = 'review-animations'; skillPath = 'skills/review-animations/SKILL.md'; mode = 'verify-read-only'; defaultLoaded = $false; skillEntrySha256 = $emilReviewHash.canonicalLfSha256 }
                    [ordered]@{ skillName = 'improve-animations'; skillPath = 'skills/improve-animations/SKILL.md'; mode = 'diagnose-plan'; defaultLoaded = $false; skillEntrySha256 = $emilImproveHash.crlfNormalizedSha256 }
                    [ordered]@{ skillName = 'animate'; skillPath = 'skills/animate/SKILL.md'; mode = 'explicit-project-write'; defaultLoaded = $false; skillEntrySha256 = ('0' * 64) }
                )
                excludedSkillNames = @('emil-design-eng', 'pick-ui-library', 'prototype', 'find-animation-opportunities', 'apple-design', 'animation-vocabulary', 'ask-sonner', 'animate-expo', 'write-swift')
            }
        )
    }
    Write-TestLock -Lock $lock -LiteralPath $LiteralPath
    return $lock
}

function New-TestContext {
    param(
        [ValidateSet('QUALITY_FIRST', 'FIDELITY_FIRST')][string]$RoutingMode = 'QUALITY_FIRST',
        [ValidateSet('none', 'primary-authority')][string]$ReferenceAuthority = 'none',
        [AllowNull()][object]$ApprovedReference = $null
    )
    return [ordered]@{
        routingMode = $RoutingMode
        referenceAuthority = $ReferenceAuthority
        approvedReference = $ApprovedReference
        allowedDelta = @('timing-only')
        target = [ordered]@{ kind = 'component'; id = 'hero-button' }
        constraints = [ordered]@{ reducedMotion = $true; maxDurationMs = 400 }
    }
}

function New-TestRequest {
    param([Parameter(Mandatory)][string]$Operation, [AllowNull()][object]$OperationInput, [object]$Context = (New-TestContext))
    if ($null -eq $OperationInput -and $Operation -ceq 'animate') { $OperationInput = [ordered]@{} }
    $request = [ordered]@{ schemaVersion = 1; operation = $Operation; context = $Context; input = $OperationInput }
    return (($request | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json)
}

function Assert-EnvelopeEffectIsolation {
    param([Parameter(Mandatory)][object]$Envelope)
    $result = $Envelope.finalWorkflowResult
    if ($null -ne $result -and $null -ne $result.effects) {
        foreach ($name in @('network', 'browser', 'install', 'projectWrite', 'projectExecution', 'upstreamExecution', 'subagentInvocation')) {
            Assert-Equal -Actual $result.effects.$name -Expected 0 -Message "effect $name remained zero"
        }
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-design-motion-phase1-' + [guid]::NewGuid().ToString('N'))
try {
    $tasteRoot = Join-Path $fixture 'synthetic/taste'
    $emilRoot = Join-Path $fixture 'synthetic/emil'
    $lockPath = Join-Path $fixture 'design-motion.lock.json'
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'synthetic')) | Out-Null
    $tasteCommit = New-FixtureRepo -RootPath $tasteRoot -Kind taste
    $emilCommit = New-FixtureRepo -RootPath $emilRoot -Kind emil
    $lock = New-TestLock -TasteRoot $tasteRoot -TasteCommit $tasteCommit -EmilRoot $emilRoot -EmilCommit $emilCommit -LiteralPath $lockPath

    # SOURCE: origin, pin, clean checkout, LF/CRLF representations, and deterministic fingerprints.
    $tasteSource = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-True $tasteSource.verified 'correct origin/pin/clean source verifies'
    Assert-True $tasteSource.clean 'clean source state is recorded'
    Assert-Equal $tasteSource.cleanliness.representation 'EXACT' 'source verification records exact cleanliness representation'
    Assert-Equal $tasteSource.cleanlinessRepresentation 'EXACT' 'source verification exposes cleanliness representation'
    Assert-Equal $tasteSource.files[0].validatedRepresentation 'crlf-normalized' 'CRLF lock representation is recognized'
    Assert-Equal $tasteSource.files[1].validatedRepresentation 'canonical-lf' 'LF lock representation is recognized'
    Assert-True ($tasteSource.sourceFingerprint -match '^[0-9a-f]{64}$') 'sourceFingerprint is SHA-256'
    $tasteSourceAgain = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-Equal $tasteSourceAgain.sourceFingerprint $tasteSource.sourceFingerprint 'sourceFingerprint is deterministic'
    $reviewSource = Invoke-DesignMotionSourceVerification -Operation review-animations -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -AllowSyntheticLock
    $improveSource = Invoke-DesignMotionSourceVerification -Operation improve-animations -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -AllowSyntheticLock
    Assert-True $reviewSource.verified 'review source verifies'
    Assert-True $improveSource.verified 'improve source verifies'
    Assert-True (@($reviewSource.files | Where-Object { $_.path -ceq 'skills/review-animations/STANDARDS.md' }).Count -eq 1) 'referenced STANDARDS.md is fingerprinted'
    Assert-True (@($improveSource.files | Where-Object { $_.path -in @('skills/improve-animations/AUDIT.md', 'skills/improve-animations/PLAN-TEMPLATE.md') }).Count -eq 2) 'improve auxiliary files are fingerprinted'
    Assert-True (@($improveSource.files | Where-Object { $_.path -match 'RECIPES\.md|skills/animate/' }).Count -eq 0) 'animate and RECIPES.md are outside Phase 1 fingerprint'

    # CLEANLINESS: explicit isolated status parsing, index authority, strict
    # CRLF/LF equivalence, and fail-closed non-equivalent changes.
    $cleanlinessRoot = Join-Path $fixture 'synthetic/cleanliness-lf'
    [IO.Directory]::CreateDirectory($cleanlinessRoot) | Out-Null
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('init', '--quiet') | Out-Null
    Write-FixtureUtf8 (Join-Path $cleanlinessRoot 'sample.txt') "alpha`n beta`n"
    Write-FixtureUtf8 (Join-Path $cleanlinessRoot 'missing.txt') 'tracked missing file'
    [IO.File]::WriteAllBytes((Join-Path $cleanlinessRoot 'binary.bin'), [byte[]]@(0, 10, 1, 255))
    $cleanlinessCommit = New-FixtureCommit -RepositoryRoot $cleanlinessRoot
    $samplePath = Join-Path $cleanlinessRoot 'sample.txt'
    $sampleBlob = Get-DesignMotionGitBlob -SourceRoot $cleanlinessRoot -Commit $cleanlinessCommit -RelativePath 'sample.txt'
    $missingPath = Join-Path $cleanlinessRoot 'missing.txt'
    $binaryPath = Join-Path $cleanlinessRoot 'binary.bin'

    $exactLf = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True $exactLf.clean 'LF blob and LF worktree are clean'
    Assert-Equal $exactLf.representation 'EXACT' 'LF blob and LF worktree record EXACT'

    [IO.File]::WriteAllBytes($samplePath, [Text.Encoding]::UTF8.GetBytes("alpha`r`n beta`r`n"))
    $crlfEquivalent = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True $crlfEquivalent.clean 'LF blob and CRLF worktree are clean-equivalent'
    Assert-Equal $crlfEquivalent.representation 'CRLF_LF_EQUIVALENT' 'LF blob and CRLF worktree record CRLF_LF_EQUIVALENT'

    [IO.File]::WriteAllBytes($samplePath, [Text.Encoding]::UTF8.GetBytes("alpha`r`n BETTA`r`n"))
    $realMutationWithCrlf = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $realMutationWithCrlf.clean) 'real content mutation plus CRLF remains dirty'
    [IO.File]::WriteAllBytes($samplePath, $sampleBlob.bytes)

    $stagedBytes = [Text.Encoding]::UTF8.GetBytes("staged-only`n")
    [IO.File]::WriteAllBytes($samplePath, $stagedBytes)
    $stagedObject = Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('hash-object', '-w', '--', $samplePath)
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--add', '--cacheinfo', "100644,$stagedObject,sample.txt") | Out-Null
    $staged = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $staged.clean) 'staged modification remains dirty'
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('read-tree', $cleanlinessCommit) | Out-Null
    [IO.File]::WriteAllBytes($samplePath, $sampleBlob.bytes)
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--refresh') | Out-Null

    Remove-Item -LiteralPath $samplePath -Force
    $deleted = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $deleted.clean) 'deleted tracked file remains dirty'
    [IO.File]::WriteAllBytes($samplePath, $sampleBlob.bytes)
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--refresh') | Out-Null

    Remove-Item -LiteralPath $missingPath -Force
    $missing = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $missing.clean) 'missing tracked file remains dirty'
    [IO.File]::WriteAllText($missingPath, 'tracked missing file', (New-Object Text.UTF8Encoding($false)))
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--refresh') | Out-Null

    Write-FixtureUtf8 (Join-Path $cleanlinessRoot 'untracked.txt') 'untracked'
    $untracked = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $untracked.clean) 'untracked file remains dirty'
    Remove-Item -LiteralPath (Join-Path $cleanlinessRoot 'untracked.txt') -Force

    $renamedObject = Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('hash-object', '-w', '--', $samplePath)
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--remove', '--', 'sample.txt') | Out-Null
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--add', '--cacheinfo', "100644,$renamedObject,renamed.txt") | Out-Null
    Move-Item -LiteralPath $samplePath -Destination (Join-Path $cleanlinessRoot 'renamed.txt')
    $renamed = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $renamed.clean) 'rename remains dirty'
    Move-Item -LiteralPath (Join-Path $cleanlinessRoot 'renamed.txt') -Destination $samplePath
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('read-tree', $cleanlinessCommit) | Out-Null
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--refresh') | Out-Null

    [IO.File]::WriteAllBytes($binaryPath, [byte[]]@(0, 13, 10, 1, 255))
    $binary = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $binary.clean) 'binary modification remains dirty without newline tolerance'
    [IO.File]::WriteAllBytes($binaryPath, [byte[]]@(0, 10, 1, 255))
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--refresh') | Out-Null

    [IO.File]::WriteAllBytes($samplePath, [Text.Encoding]::UTF8.GetBytes("alpha`r beta`n"))
    $loneCr = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessRoot
    Assert-True (-not $loneCr.clean) 'lone CR is not newline-equivalent'
    [IO.File]::WriteAllBytes($samplePath, $sampleBlob.bytes)
    Invoke-FixtureGit -RepositoryRoot $cleanlinessRoot -Arguments @('update-index', '--refresh') | Out-Null

    $cleanlinessCrlfRoot = Join-Path $fixture 'synthetic/cleanliness-crlf'
    [IO.Directory]::CreateDirectory($cleanlinessCrlfRoot) | Out-Null
    Invoke-FixtureGit -RepositoryRoot $cleanlinessCrlfRoot -Arguments @('init', '--quiet') | Out-Null
    Invoke-FixtureGit -RepositoryRoot $cleanlinessCrlfRoot -Arguments @('config', 'core.autocrlf', 'false') | Out-Null
    $crlfTextPath = Join-Path $cleanlinessCrlfRoot 'sample.txt'
    [IO.File]::WriteAllBytes($crlfTextPath, [Text.Encoding]::UTF8.GetBytes("alpha`r`n beta`r`n"))
    $cleanlinessCrlfCommit = New-FixtureCommit -RepositoryRoot $cleanlinessCrlfRoot
    $exactCrlf = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessCrlfRoot
    Assert-True $exactCrlf.clean 'CRLF blob and CRLF worktree are clean'
    Assert-Equal $exactCrlf.representation 'EXACT' 'CRLF blob and CRLF worktree record EXACT'
    [IO.File]::WriteAllBytes($crlfTextPath, [Text.Encoding]::UTF8.GetBytes("alpha`n beta`n"))
    $crlfBlobLfWorktree = Get-DesignMotionSourceCleanliness -SourceRoot $cleanlinessCrlfRoot
    Assert-True $crlfBlobLfWorktree.clean 'CRLF blob and LF worktree are clean-equivalent'
    Assert-Equal $crlfBlobLfWorktree.representation 'CRLF_LF_EQUIVALENT' 'CRLF blob and LF worktree record CRLF_LF_EQUIVALENT'
    Invoke-FixtureGit -RepositoryRoot $cleanlinessCrlfRoot -Arguments @('read-tree', $cleanlinessCrlfCommit) | Out-Null
    [IO.File]::WriteAllBytes($crlfTextPath, [Text.Encoding]::UTF8.GetBytes("alpha`r`n beta`r`n"))
    Invoke-FixtureGit -RepositoryRoot $cleanlinessCrlfRoot -Arguments @('update-index', '--refresh') | Out-Null

    $wrongOriginLock = Copy-TestObject $lock
    $wrongOriginLock.dependencies[0].upstream = 'https://example.invalid/wrong.git'
    $wrongOriginPath = Join-Path $fixture 'wrong-origin.lock.json'
    Write-TestLock $wrongOriginLock $wrongOriginPath
    $wrongOrigin = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $wrongOriginPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-True (-not $wrongOrigin.verified) 'wrong origin fails closed'

    $wrongPinLock = Copy-TestObject $lock
    $wrongPinLock.dependencies[0].commitSha = '0' * 40
    $wrongPinPath = Join-Path $fixture 'wrong-pin.lock.json'
    Write-TestLock $wrongPinLock $wrongPinPath
    $wrongPin = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $wrongPinPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-True (-not $wrongPin.verified) 'wrong pin fails closed'

    $wrongHashLock = Copy-TestObject $lock
    $wrongHashLock.dependencies[0].skillEntrySha256 = '0' * 64
    $wrongHashPath = Join-Path $fixture 'wrong-hash.lock.json'
    Write-TestLock $wrongHashLock $wrongHashPath
    $wrongHash = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $wrongHashPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-True (-not $wrongHash.verified) 'wrong committed source hash fails closed'

    $missingEntryLock = Copy-TestObject $lock
    $missingEntryLock.dependencies[0].skillPath = 'skills/taste-skill/MISSING.md'
    $missingEntryPath = Join-Path $fixture 'missing-entry.lock.json'
    Write-TestLock $missingEntryLock $missingEntryPath
    $missingEntry = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $missingEntryPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-True (-not $missingEntry.verified) 'missing allowlisted entry fails closed'

    Write-FixtureUtf8 (Join-Path $tasteRoot 'LICENSE') "dirty source"
    $dirty = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-True (-not $dirty.verified) 'dirty checkout fails closed'
    $licenseBlob = Get-DesignMotionGitBlob -SourceRoot $tasteRoot -Commit $tasteCommit -RelativePath 'LICENSE'
    [IO.File]::WriteAllBytes((Join-Path $tasteRoot 'LICENSE'), $licenseBlob.bytes)

    $missingSource = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot (Join-Path $fixture 'not-materialized') -AllowSyntheticLock
    Assert-True (-not $missingSource.materialized -and -not $missingSource.verified) 'missing source is NOT_MATERIALIZED'
    $wrongRoot = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot (Join-Path $tasteRoot 'skills') -AllowSyntheticLock
    Assert-True (-not $wrongRoot.verified) 'a Git subdirectory is not accepted as the checkout root'
    $traversalLock = Copy-TestObject $lock
    $traversalLock.dependencies[0].skillPath = '../LICENSE'
    $traversalPath = Join-Path $fixture 'traversal.lock.json'
    Write-TestLock $traversalLock $traversalPath
    $traversal = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot -LockPath $traversalPath -SourceRoot $tasteRoot -AllowSyntheticLock
    Assert-True (-not $traversal.verified) 'source path traversal fails closed'

    # TASTE: advisory eligibility, default non-applicability, invalid input, and fidelity guard.
    $project = Join-Path $fixture 'project'
    [IO.Directory]::CreateDirectory($project) | Out-Null
    $projectSentinel = Join-Path $project 'sentinel.txt'
    Write-FixtureUtf8 $projectSentinel 'project must remain unchanged'
    $projectBefore = (Get-FileHash -LiteralPath $projectSentinel -Algorithm SHA256).Hash
    $tasteInput = [ordered]@{
        explicitRequest = $true
        surfaceType = 'other'
        aestheticGap = [ordered]@{ material = $false; description = 'explicit request is sufficient' }
        designRead = [ordered]@{ composition = 'centered'; hierarchy = 'clear'; style = 'restrained' }
        designVariance = 'low'
        motionIntensity = 'restrained'
        visualDensity = 'balanced'
        direction = @('Use short, purposeful transitions.')
        rationale = @('The request asks for a distinct motion direction.')
        limitations = @()
    }
    $tasteResult = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-True $tasteResult.dedicatedExecution.childStarted 'Taste child starts after source verification'
    Assert-True $tasteResult.dedicatedExecution.succeeded 'valid Taste advisory succeeds'
    Assert-Equal $tasteResult.finalWorkflowResult.status 'ADVISORY' 'Taste returns advisory status'
    Assert-Equal $tasteResult.finalWorkflowResult.sourceFingerprint $tasteResult.sourceFingerprint 'Taste preserves sourceFingerprint'
    Assert-Equal $tasteResult.finalWorkflowResult.referenceAuthority 'none' 'Taste preserves quality-first reference authority'
    Assert-Equal $tasteResult.policy.status 'POLICY_REJECTION' 'local pre-integration envelope does not claim dispatcher authorization'
    Assert-Equal $tasteResult.integration.operationSurface 'REQUEST_ONLY' 'local operation remains request-only before shared integration'
    Assert-True $tasteResult.sourceVerification.verified 'execution envelope preserves verified source metadata'
    Assert-Equal $tasteResult.dedicatedExecution.evidence.sourceFingerprint $tasteResult.sourceFingerprint 'dedicated evidence preserves sourceFingerprint'
    Assert-True ($tasteResult.dedicatedExecution.evidence.child.environmentNames -contains 'DO_NOT_TRACK') 'child environment is deterministic and allowlisted'
    foreach ($forbiddenEnvironment in @('PATH', 'HOME', 'USERPROFILE', 'OPENAI_API_KEY', 'API_KEY_21ST')) {
        Assert-True ($tasteResult.dedicatedExecution.evidence.child.environmentNames -notcontains $forbiddenEnvironment) "child environment excludes $forbiddenEnvironment"
    }
    Assert-EnvelopeEffectIsolation $tasteResult
    Assert-Equal (Get-FileHash -LiteralPath $projectSentinel -Algorithm SHA256).Hash $projectBefore 'Taste does not write the project'

    $tasteNotApplicable = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' ([ordered]@{ explicitRequest = $false; surfaceType = 'dashboard'; aestheticGap = [ordered]@{ material = $false } })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-Equal $tasteNotApplicable.finalWorkflowResult.status 'NOT_APPLICABLE' 'Taste is not a default dashboard capability'
    Assert-True $tasteNotApplicable.dedicatedExecution.succeeded 'not-applicable Taste is still a truthful read-only result'

    $tasteInvalid = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' ([ordered]@{ explicitRequest = $true; unknown = 'rejected' })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-Equal $tasteInvalid.dedicatedExecution.failureType 'INVALID_INPUT' 'invalid Taste input is rejected before child'
    Assert-True (-not $tasteInvalid.dedicatedExecution.childStarted) 'invalid Taste input cannot start child'

    $fidelityMissing = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput (New-TestContext -RoutingMode FIDELITY_FIRST -ReferenceAuthority primary-authority -ApprovedReference $null)) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-Equal $fidelityMissing.dedicatedExecution.failureType 'INVALID_INPUT' 'FIDELITY_FIRST requires approvedReference'
    Assert-True (-not $fidelityMissing.dedicatedExecution.childStarted) 'missing fidelity reference cannot start child'
    $fidelityEmpty = New-TestContext -RoutingMode FIDELITY_FIRST -ReferenceAuthority primary-authority -ApprovedReference ([ordered]@{})
    $fidelityEmptyResult = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput $fidelityEmpty) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-Equal $fidelityEmptyResult.dedicatedExecution.failureType 'INVALID_INPUT' 'empty approved reference is rejected'
    $badDeltaContext = New-TestContext
    $badDeltaContext.allowedDelta = @('creative-change')
    $badDeltaResult = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput $badDeltaContext) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-Equal $badDeltaResult.dedicatedExecution.failureType 'INVALID_INPUT' 'unknown allowedDelta is rejected'
    $fidelityContext = New-TestContext -RoutingMode FIDELITY_FIRST -ReferenceAuthority primary-authority -ApprovedReference ([ordered]@{ kind = 'primary'; id = 'design-reference-1'; authority = 'human-approved' })
    $fidelityResult = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput $fidelityContext) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-Equal $fidelityResult.finalWorkflowResult.routingMode 'FIDELITY_FIRST' 'FIDELITY_FIRST is preserved'
    Assert-Equal $fidelityResult.finalWorkflowResult.referenceAuthority 'primary-authority' 'primary authority is preserved'
    Assert-Equal $fidelityResult.finalWorkflowResult.allowedDelta[0] 'timing-only' 'allowedDelta is preserved'
    $noDeltaFidelityContext = New-TestContext -RoutingMode FIDELITY_FIRST -ReferenceAuthority primary-authority -ApprovedReference ([ordered]@{ kind = 'primary'; id = 'design-reference-no-delta'; authority = 'human-approved' })
    $noDeltaFidelityContext.allowedDelta = @()
    $noDeltaFidelity = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput $noDeltaFidelityContext) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-True $noDeltaFidelity.dedicatedExecution.succeeded 'empty allowedDelta is valid as a no-delta fidelity guard'
    Assert-Equal @($noDeltaFidelity.finalWorkflowResult.allowedDelta).Count 0 'empty allowedDelta is preserved'

    # REVIEW: relevant motion, structured finding, normalized severity, and approve/block.
    $reviewFinding = [ordered]@{
        id = 'motion-001'
        target = 'hero-button'
        category = 'timing'
        severityHint = 'high'
        evidence = @('Current transition blocks feedback for the primary action.')
        currentState = [ordered]@{ durationMs = 600; easing = 'linear' }
        recommendedState = [ordered]@{ durationMs = 180; easing = 'ease-out' }
        rationale = @('The interaction should acknowledge input sooner.')
        limitations = @()
    }
    $reviewRequest = New-TestRequest 'review-animations' ([ordered]@{ motionRelevant = $true; motion = [ordered]@{ source = 'structured-observation'; existing = $true; evidence = @('Existing transition is present on the primary action.') }; findings = @($reviewFinding) })
    $reviewResult = Invoke-DesignMotionOperation -Request $reviewRequest -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-True $reviewResult.dedicatedExecution.succeeded 'valid motion review succeeds'
    Assert-Equal $reviewResult.finalWorkflowResult.status 'COMPLETE' 'review returns structured completion'
    Assert-Equal $reviewResult.finalWorkflowResult.findings[0].normalizedSeverity 'HIGH' 'review severity is FTK-normalized'
    Assert-Equal $reviewResult.finalWorkflowResult.decision 'BLOCK' 'material high finding justifies BLOCK'
    Assert-True ($reviewResult.finalWorkflowResult.PSObject.Properties.Name -notcontains 'browser') 'review does not claim browser execution'
    Assert-True (($reviewResult.finalWorkflowResult.limitations -join ' ') -match 'no browser') 'review limitation states no browser claim'
    $reviewMissingEvidence = Invoke-DesignMotionOperation -Request (New-TestRequest 'review-animations' ([ordered]@{ motionRelevant = $true; motion = [ordered]@{ existing = $true }; findings = @() })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-Equal $reviewMissingEvidence.dedicatedExecution.failureType 'INVALID_INPUT' 'review without motion evidence is rejected before child'
    $badSeverity = Copy-TestObject $reviewFinding
    $badSeverity.severityHint = 'not-a-severity'
    $reviewBadSeverity = Invoke-DesignMotionOperation -Request (New-TestRequest 'review-animations' ([ordered]@{ motionRelevant = $true; motion = [ordered]@{ existing = $true; evidence = @('Existing motion evidence.') }; findings = @($badSeverity) })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-Equal $reviewBadSeverity.dedicatedExecution.failureType 'INVALID_INPUT' 'invalid severity hint is rejected before child'
    # The adapter owns severity normalization; exercise APPROVE through a fresh low-severity request.
    $lowFinding = Copy-TestObject $reviewFinding
    $lowFinding.severityHint = 'low'
    $reviewApprove = Invoke-DesignMotionOperation -Request (New-TestRequest 'review-animations' ([ordered]@{ motionRelevant = $true; motion = [ordered]@{ existing = $true; evidence = @('Existing transition is present on the primary action.') }; findings = @($lowFinding) })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-Equal $reviewApprove.finalWorkflowResult.decision 'APPROVE' 'non-material finding justifies APPROVE'
    $reviewNotApplicable = Invoke-DesignMotionOperation -Request (New-TestRequest 'review-animations' ([ordered]@{ motionRelevant = $false; findings = @() })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-Equal $reviewNotApplicable.finalWorkflowResult.status 'NOT_APPLICABLE' 'review is not selected without relevant motion'

    # IMPROVE: concrete finding, explicit request, no-trigger result, plan-only and reduced motion.
    $improveInput = [ordered]@{
        concreteFinding = $reviewFinding
        findingRefs = @('motion-001')
        explicitRequest = $false
        priority = 'HIGH'
        timing = [ordered]@{ trigger = 'pointer-up'; start = 0; end = 180 }
        easing = 'ease-out'
        duration = 180
        sequence = @('acknowledge input', 'settle control')
        reducedMotionRequirement = [ordered]@{ required = $true; alternative = 'instant state change' }
        acceptanceCriteria = @('Primary action feedback is perceptible within 200ms.', 'Reduced motion removes travel.')
        limitations = @()
    }
    $improveResult = Invoke-DesignMotionOperation -Request (New-TestRequest 'improve-animations' $improveInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-True $improveResult.dedicatedExecution.succeeded 'concrete finding produces improve plan'
    Assert-Equal $improveResult.finalWorkflowResult.status 'PLAN' 'improve returns PLAN'
    Assert-Equal $improveResult.finalWorkflowResult.plan.planPersistence 'INLINE_ONLY' 'improve plan is inline only'
    Assert-True $improveResult.finalWorkflowResult.plan.reducedMotionRequirement.required 'improve carries reduced-motion requirement'
    Assert-True ($improveResult.finalWorkflowResult.PSObject.Properties.Name -notcontains 'outputPath') 'improve has no output path'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $project 'animation-plans'))) 'improve does not create plan directory'
    $improveExplicit = Invoke-DesignMotionOperation -Request (New-TestRequest 'improve-animations' ([ordered]@{ explicitRequest = $true; findingRefs = @(); acceptanceCriteria = @('Human reviews the proposed sequence.'); sequence = @('review') })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-Equal $improveExplicit.finalWorkflowResult.status 'PLAN' 'explicit improve request produces a plan'
    $improveNotApplicable = Invoke-DesignMotionOperation -Request (New-TestRequest 'improve-animations' ([ordered]@{ explicitRequest = $false; findingRefs = @(); acceptanceCriteria = @() })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-Equal $improveNotApplicable.finalWorkflowResult.status 'NOT_APPLICABLE' 'improve without finding or request is not applicable'
    $improveRefsOnly = Invoke-DesignMotionOperation -Request (New-TestRequest 'improve-animations' ([ordered]@{ explicitRequest = $false; findingRefs = @('unresolved-ref'); acceptanceCriteria = @() })) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $emilRoot -HermeticTestMode
    Assert-Equal $improveRefsOnly.finalWorkflowResult.status 'NOT_APPLICABLE' 'unresolved finding reference does not authorize a plan'
    $preintegration = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot
    Assert-Equal $preintegration.dedicatedExecution.failureType 'DEPENDENCY_OR_RUNTIME_FAILURE' 'synthetic lock override is denied outside hermetic mode'
    Assert-True (-not $preintegration.dedicatedExecution.childStarted) 'pre-integration lock denial cannot start child'

    # EXECUTION: start/failure/timeout/bounded output/childStarted/final workflow truthfulness.
    $childFailure = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode -TestHarness -TestBehavior fail
    Assert-True $childFailure.dedicatedExecution.childStarted 'child failure reports childStarted=true'
    Assert-Equal $childFailure.dedicatedExecution.failureType 'UPSTREAM_EXECUTION_FAILURE' 'semantic adapter failure uses existing taxonomy'
    Assert-Equal $childFailure.finalWorkflowResult.status 'FAILED' 'failed child does not report successful workflow'
    $timeout = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode -TimeoutMilliseconds 50 -TestHarness -TestBehavior timeout
    Assert-True $timeout.dedicatedExecution.childStarted 'timeout reports childStarted=true'
    Assert-Equal $timeout.dedicatedExecution.failureType 'TIMEOUT' 'timeout uses TIMEOUT taxonomy'
    Assert-True $timeout.dedicatedExecution.timedOut 'timeout sets timedOut=true'
    Assert-True $timeout.dedicatedExecution.evidence.child.cleanupGuaranteed 'timeout cleanup is guaranteed'
    $malformed = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode -TestHarness -TestBehavior malformed
    Assert-Equal $malformed.dedicatedExecution.failureType 'OUTPUT_CONTRACT_FAILURE' 'malformed output fails contract'
    $stdoutOverflow = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode -TestHarness -TestBehavior stdout-overflow
    Assert-Equal $stdoutOverflow.dedicatedExecution.failureType 'OUTPUT_CONTRACT_FAILURE' 'oversized stdout fails bounded contract'
    $stderrOverflow = Invoke-DesignMotionOperation -Request (New-TestRequest 'taste' $tasteInput) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode -TestHarness -TestBehavior stderr-overflow
    Assert-Equal $stderrOverflow.dedicatedExecution.failureType 'OUTPUT_CONTRACT_FAILURE' 'oversized stderr fails bounded contract'
    Assert-True (-not $tasteInvalid.dedicatedExecution.childStarted -and $tasteResult.dedicatedExecution.childStarted) 'childStarted is truthful across pre-child and child paths'

    # ANIMATE: registered but fail-closed, with no inferred authorization or write handler.
    $animate = Invoke-DesignMotionOperation -Request (New-TestRequest 'animate' ([ordered]@{})) -RepoRoot $repoRoot -LockPath $lockPath -SourceRoot $tasteRoot -HermeticTestMode
    Assert-Equal $animate.finalWorkflowResult.status 'REGISTERED_NO_HANDLER' 'animate is blocked in Phase 1'
    Assert-Equal $animate.finalWorkflowResult.authorization 'PHASE_2_BLOCKED' 'animate has an explicit Phase 2 boundary'
    Assert-True (-not $animate.dedicatedExecution.childStarted -and -not $animate.dedicatedExecution.attempted) 'animate does not start a child or infer authorization'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $project 'animation-plans'))) 'animate has no write handler'

    # EFFECTS: structural assurance that the child is FTK-only and no network/install/write surface exists.
    $adapterText = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'design-motion-adapter.mjs')
    $runnerText = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'design-motion-runner.ps1')
    $verifierText = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'design-motion-source-verifier.ps1')
    Assert-True ($adapterText -notmatch 'child_process|node:(fs|http|https|net)|fetch\s*\(|writeFile|mkdir|npm\s+install') 'adapter has no network, browser, install, or filesystem-write surface'
    Assert-True ($adapterText -match 'process\.stdin' -and $adapterText -notmatch '\beval\s*\(|new Function') 'adapter only consumes stdin and does not evaluate code'
    Assert-True ($runnerText -match "FileName = .*git" -or $verifierText -match "FileName = .*git") 'only Git metadata utility is used outside the FTK adapter'
    Assert-True ($runnerText -notmatch 'Invoke-Expression|Start-Process|npm\s+install|Invoke-WebRequest|WebClient|HttpClient') 'runner has no shell, installer, or network fallback'
    Assert-True ($verifierText -notmatch 'Invoke-WebRequest|Invoke-RestMethod|WebClient|HttpClient|curl|wget') 'source verifier has no runtime network path'
    Assert-Equal (Get-FileHash -LiteralPath $projectSentinel -Algorithm SHA256).Hash $projectBefore 'all Phase 1 operations preserve project bytes'

    # Prepared real-source evidence is reported, never cloned implicitly.
    $preparedTaste = Invoke-DesignMotionSourceVerification -Operation taste -RepoRoot $repoRoot
    $preparedEmil = Invoke-DesignMotionSourceVerification -Operation review-animations -RepoRoot $repoRoot
    $preparedTasteState = if ($preparedTaste.verified) { 'VERIFIED' } elseif ($preparedTaste.materialized) { 'MATERIALIZED_BUT_UNVERIFIED' } else { 'NOT_MATERIALIZED' }
    $preparedEmilState = if ($preparedEmil.verified) { 'VERIFIED' } elseif ($preparedEmil.materialized) { 'MATERIALIZED_BUT_UNVERIFIED' } else { 'NOT_MATERIALIZED' }
    Write-Output ("PREPARED_REAL_SOURCE taste={0} emil={1}" -f $preparedTasteState, $preparedEmilState)
    Write-Output ("PASS: $script:Passed hermetic Phase 1 design-motion assertions")
} finally {
    if (Test-Path -LiteralPath $fixture) {
        foreach ($item in @(Get-ChildItem -LiteralPath $fixture -Force -Recurse -ErrorAction SilentlyContinue)) {
            try { $item.Attributes = [IO.FileAttributes]::Normal } catch { }
        }
        try { [IO.Directory]::Delete($fixture, $true) } catch { Write-Warning ("Fixture cleanup limitation: " + $_.Exception.Message) }
    }
}
