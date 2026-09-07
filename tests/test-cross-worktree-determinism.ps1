Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-CanonicalJson($Value) {
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$builder = Join-Path $repoRoot 'scripts/build-release-candidate.ps1'
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$sourceCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
$sourceTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}').Trim()
if ($sourceCommit -notmatch '^[0-9a-f]{40}$' -or $sourceTree -notmatch '^[0-9a-f]{40}$') {
    throw 'The source commit/tree could not be resolved.'
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-cross-worktree-' + [guid]::NewGuid().ToString('N'))
$secondWorktree = Join-Path $fixture 'second-worktree'
$firstCandidate = Join-Path $fixture 'candidate-main'
$secondCandidate = Join-Path $fixture 'candidate-second-worktree'
$firstZip = Join-Path $fixture 'candidate-main.zip'
$secondZip = Join-Path $fixture 'candidate-second-worktree.zip'
$worktreeCreated = $false

try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    Invoke-Git @('-C', $repoRoot, 'worktree', 'add', '--detach', '--quiet', $secondWorktree, $sourceCommit) | Out-Null
    $worktreeCreated = $true

    foreach ($dependency in @($externalLock.dependencies)) {
        $sourceCheckout = Join-Path $repoRoot $dependency.checkoutPath
        $targetCheckout = Join-Path $secondWorktree $dependency.checkoutPath
        if (-not (Test-Path -LiteralPath $sourceCheckout -PathType Container)) {
            throw "Pinned external checkout is missing in the primary worktree: $($dependency.id)"
        }
        New-Item -ItemType Directory -Path (Split-Path $targetCheckout) -Force | Out-Null
        Invoke-Git @('clone', '--quiet', '--local', '--no-hardlinks', $sourceCheckout, $targetCheckout) | Out-Null
        $targetHead = (Invoke-Git @('-C', $targetCheckout, 'rev-parse', 'HEAD') | Select-Object -First 1).Trim()
        Assert-True ($targetHead -ceq $dependency.commitSha) "Temporary checkout drifted for $($dependency.id)."
    }

    $secondCommit = (Invoke-Git @('-C', $secondWorktree, 'rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    $secondTree = (Invoke-Git @('-C', $secondWorktree, 'rev-parse', 'HEAD^{tree}') | Select-Object -First 1).Trim()
    Assert-True ($secondCommit -ceq $sourceCommit) 'The second worktree commit differs from the primary worktree.'
    Assert-True ($secondTree -ceq $sourceTree) 'The second worktree tree differs from the primary worktree.'

    & $builder -Destination $firstCandidate | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Primary cross-worktree candidate build failed.' }
    & (Join-Path $secondWorktree 'scripts/build-release-candidate.ps1') -Destination $secondCandidate | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Second cross-worktree candidate build failed.' }

    New-DeterministicZip -Root $firstCandidate -ZipPath $firstZip
    New-DeterministicZip -Root $secondCandidate -ZipPath $secondZip

    $firstManifest = Get-Content -Raw -LiteralPath (Join-Path $firstCandidate 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    $secondManifest = Get-Content -Raw -LiteralPath (Join-Path $secondCandidate 'RELEASE_MANIFEST.json') | ConvertFrom-Json
    Assert-True ($firstManifest.pluginTreeSha256 -ceq $secondManifest.pluginTreeSha256) 'CROSS-WORKTREE DETERMINISM: plugin tree differs.'
    Assert-True ($firstManifest.artifactTreeSha256 -ceq $secondManifest.artifactTreeSha256) 'CROSS-WORKTREE DETERMINISM: artifact tree differs.'
    Assert-True ((Get-CanonicalJson $firstManifest.pluginFiles) -ceq (Get-CanonicalJson $secondManifest.pluginFiles)) 'CROSS-WORKTREE DETERMINISM: plugin inventory differs.'
    Assert-True ((Get-CanonicalJson $firstManifest.artifactFiles) -ceq (Get-CanonicalJson $secondManifest.artifactFiles)) 'CROSS-WORKTREE DETERMINISM: artifact inventory differs.'
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $firstZip).Hash.ToLowerInvariant() -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath $secondZip).Hash.ToLowerInvariant()) 'CROSS-WORKTREE DETERMINISM: ZIP differs.'

    Write-Output "PASS: CROSS-WORKTREE DETERMINISM plugin=$($firstManifest.pluginTreeSha256) artifact=$($firstManifest.artifactTreeSha256)"
    Write-Output "PASS: CROSS-WORKTREE DETERMINISM ZIP=$((Get-FileHash -Algorithm SHA256 -LiteralPath $firstZip).Hash.ToLowerInvariant())"
} finally {
    if ($worktreeCreated) {
        Invoke-Git @('-C', $repoRoot, 'worktree', 'remove', '--force', $secondWorktree) | Out-Null
    }
    if (Test-Path -LiteralPath $fixture) {
        [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true)
    }
}

if (Test-Path -LiteralPath $fixture) { throw 'Cross-worktree fixture teardown failed.' }
