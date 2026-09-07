Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-CanonicalTextHash {
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    $normalized = $text.Replace(([string][char]13 + [string][char]10), [string][char]10).Replace([string][char]13, [string][char]10)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}


$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$discoveryRoot = Join-Path $repoRoot '.agents/skills'
$pluginSkills = Join-Path $repoRoot 'plugin/frontend-toolkit/skills'
$lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json

$discovered = @(Get-ChildItem -LiteralPath $discoveryRoot -Directory -Force | Sort-Object Name)
if (($discovered.Name -join ',') -ne 'figma-design-to-code,frontend-accessibility,frontend-orchestrator,img2threejs,impeccable,playwright-cli') {
    throw "Repo discovery inventory drifted: $($discovered.Name -join ',')"
}
if (@(Get-ChildItem -LiteralPath $discoveryRoot -Recurse -Filter SKILL.md -File).Count -ne 6) {
    throw 'A nested or duplicate SKILL.md exists below the discovery root.'
}

foreach ($directory in $discovered) {
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Discovered Skill is a reparse point: $($directory.Name)" }
    if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'SKILL.md') -PathType Leaf)) { throw "Discovered Skill lacks SKILL.md: $($directory.Name)" }
}

foreach ($dependency in $lock.dependencies) {
    $checkout = (Resolve-Path (Join-Path $repoRoot $dependency.checkoutPath)).Path
    $safeCheckout = $checkout.Replace('\', '/')
    $head = (& git -c "safe.directory=$safeCheckout" -C $checkout rev-parse HEAD).Trim()
    if ($head -ne $dependency.commitSha) { throw "$($dependency.id) checkout SHA mismatch." }
    if (& git -c "safe.directory=$safeCheckout" -C $checkout status --porcelain) { throw "$($dependency.id) checkout is dirty." }

    $upstreamEntry = Join-Path (Join-Path $repoRoot $dependency.upstreamSkillSourcePath) 'SKILL.md'
    $upstreamHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $upstreamEntry).Hash.ToLowerInvariant()
    if ($upstreamHash -ne $dependency.upstreamSkillEntrySha256) { throw "$($dependency.id) upstream SKILL.md hash mismatch." }

    $adapter = Join-Path (Join-Path $repoRoot $dependency.adapterPath) 'SKILL.md'
    $pluginAdapter = Join-Path (Join-Path $repoRoot ('plugin/frontend-toolkit/' + $dependency.distributionAdapterPath)) 'SKILL.md'
    foreach ($path in @($adapter, $pluginAdapter)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$($dependency.id) adapter is missing: $path" }
        if ((Get-CanonicalTextHash $path) -ne $dependency.adapterEntrySha256) {
            throw "$($dependency.id) adapter hash mismatch: $path"
        }
        if ((Get-CanonicalTextHash $path) -eq (Get-CanonicalTextHash $upstreamEntry)) {
            throw "$($dependency.id) adapter is an upstream SKILL.md copy."
        }
    }
    if ([IO.File]::ReadAllBytes($adapter).Length -ne [IO.File]::ReadAllBytes($pluginAdapter).Length -or
        (Get-CanonicalTextHash $adapter) -ne (Get-CanonicalTextHash $pluginAdapter)) {
        throw "$($dependency.id) source and plugin adapters diverged."
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot '.codex/hooks.json')) { throw 'Hooks remain outside the approved architecture.' }
Write-Output 'PASS: exactly six approved physical FTK-owned Skills are discoverable; upstream roots remain absent.'
Write-Output 'PASS: upstream SKILL.md files remain pinned, byte-verified and outside the discovery root.'
Write-Output 'PASS: source and plugin adapters have separate, matching provenance.'
