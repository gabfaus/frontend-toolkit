param(
    [string]$Prompt = 'Use $impeccable:impeccable and $img2threejs. Read only their SKILL.md files. Run node --version and then run the executable in FTK_PYTHON_PATH with --version. Do not create or edit files, install anything, authenticate, use MCPs, or run hooks. Return exactly four lines: impeccable discovered, img2threejs discovered, Node version, Python version.',
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BytesHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-FileState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Bytes = [byte[]]@(); Hash = '<absent>' }
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [pscustomobject]@{ Exists = $true; Bytes = $bytes; Hash = Get-BytesHash $bytes }
}

function Test-KnownTrustInsertion {
    param(
        [Parameter(Mandatory)][byte[]]$Before,
        [Parameter(Mandatory)][byte[]]$After,
        [Parameter(Mandatory)][string]$RepositoryPath
    )

    if ($After.Length -le $Before.Length) { return $false }
    $beforeText = [Text.Encoding]::UTF8.GetString($Before)
    $afterText = [Text.Encoding]::UTF8.GetString($After)
    $project = $RepositoryPath.ToLowerInvariant().Replace('/', '\')
    foreach ($newline in @("`n", "`r`n")) {
        $block = "[projects.'$project']${newline}trust_level = `"trusted`"${newline}"
        foreach ($sequence in @("${newline}${block}", "${block}${newline}")) {
            $first = $afterText.IndexOf($sequence, [StringComparison]::Ordinal)
            if ($first -lt 0 -or $first -ne $afterText.LastIndexOf($sequence, [StringComparison]::Ordinal)) {
                continue
            }
            $candidate = $afterText.Remove($first, $sequence.Length)
            if ($candidate -eq $beforeText) { return $true }
        }
    }
    return $false
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = & (Join-Path $PSScriptRoot 'resolve-toolchain.ps1')
if ($toolchain.NodeVersion -ne '24.20.0' -or $toolchain.PythonVersion -ne '3.14.7') {
    throw 'Resolved toolchain does not match the FTK-02 pin.'
}

$codexCommand = Get-Command codex -ErrorAction Stop
$configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$before = Get-FileState $configPath
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')

if ($ValidateOnly) {
    [pscustomobject]@{
        Mode = 'validate-only'
        NodePath = $toolchain.NodePath
        PythonPath = $toolchain.PythonPath
        ConfigHashBefore = $before.Hash
        ConfigHashAfter = $before.Hash
        ConfigMutation = 'none'
    }
    exit 0
}

$processPathBefore = $env:PATH
$pythonPathBefore = $env:FTK_PYTHON_PATH
$codexOutput = ''
$codexExitCode = -1
try {
    $env:PATH = "$($toolchain.NodeDirectory);$processPathBefore"
    $env:FTK_PYTHON_PATH = $toolchain.PythonPath
    $args = @(
        'exec', '--ephemeral', '--ignore-user-config',
        '--sandbox', 'danger-full-access', '--skip-git-repo-check', $Prompt
    )
    $codexOutput = (& $codexCommand.Source @args 2>&1 | Out-String).TrimEnd()
    $codexExitCode = $LASTEXITCODE
} finally {
    $env:PATH = $processPathBefore
    $env:FTK_PYTHON_PATH = $pythonPathBefore
}

$after = Get-FileState $configPath
$mutation = 'none'
if ($before.Hash -ne $after.Hash) {
    $knownInsertion = $before.Exists -and $after.Exists -and
        (Test-KnownTrustInsertion -Before $before.Bytes -After $after.Bytes -RepositoryPath $repoRoot)
    if (-not $knownInsertion) {
        throw "Codex user config changed in an unrecognized way; no restoration attempted. Before=$($before.Hash) After=$($after.Hash)"
    }

    Write-Warning "Codex inserted only the current repository trust block; restoring the byte-for-byte snapshot. Before=$($before.Hash) After=$($after.Hash)"
    $current = Get-FileState $configPath
    if ($current.Hash -ne $after.Hash) {
        throw 'Codex config changed again after detection; refusing to overwrite a possible concurrent user edit.'
    }
    [IO.File]::WriteAllBytes($configPath, $before.Bytes)
    $restored = Get-FileState $configPath
    if ($restored.Hash -ne $before.Hash) {
        throw "Failed to restore the original Codex config hash: expected $($before.Hash), found $($restored.Hash)"
    }
    $after = $restored
    $mutation = 'known-project-trust-insertion-restored'
}

if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $userPathBefore) {
    throw 'Persistent user PATH changed during the Codex test.'
}
if ([Environment]::GetEnvironmentVariable('Path', 'Machine') -ne $machinePathBefore) {
    throw 'Persistent machine PATH changed during the Codex test.'
}
if ($codexExitCode -ne 0) {
    throw "Codex test failed with exit code $codexExitCode.`n$codexOutput"
}

Write-Output $codexOutput
[pscustomobject]@{
    Mode = 'executed'
    NodePath = $toolchain.NodePath
    PythonPath = $toolchain.PythonPath
    ConfigHashBefore = $before.Hash
    ConfigHashAfter = $after.Hash
    ConfigMutation = $mutation
    PersistentPathMutation = 'none'
}
