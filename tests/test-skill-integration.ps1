Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lockPath = Join-Path $repoRoot 'integrations/external.lock.json'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
$observedNames = @()

foreach ($dependency in $lock.dependencies) {
    $checkoutPath = Join-Path $repoRoot $dependency.checkoutPath
    $discoveryPath = Join-Path $repoRoot $dependency.discoveryPath
    $sourcePath = (Resolve-Path (Join-Path $repoRoot $dependency.skillSourcePath)).Path
    $skillPath = Join-Path $discoveryPath 'SKILL.md'
    $link = Get-Item -Force -LiteralPath $discoveryPath

    if ($link.LinkType -ne 'Junction') {
        throw "$($dependency.id) is not exposed through a junction."
    }
    $linkTarget = (Resolve-Path -LiteralPath $link.Target).Path
    if ($linkTarget -ne $sourcePath) {
        throw "$($dependency.id) junction target mismatch: $linkTarget"
    }
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        throw "$($dependency.id) has no accessible SKILL.md."
    }

    $checkoutSha = (& git -C $checkoutPath rev-parse HEAD).Trim()
    if ($checkoutSha -ne $dependency.commitSha) {
        throw "$($dependency.id) checkout SHA mismatch: $checkoutSha"
    }
    if (& git -C $checkoutPath status --porcelain) {
        throw "$($dependency.id) checkout is dirty."
    }
    $skillHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $skillPath).Hash.ToLowerInvariant()
    if ($skillHash -ne $dependency.skillEntrySha256) {
        throw "$($dependency.id) SKILL.md hash mismatch."
    }
    $licenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repoRoot $dependency.licenseFile)).Hash.ToLowerInvariant()
    if ($licenseHash -ne $dependency.licenseSha256) {
        throw "$($dependency.id) license hash mismatch."
    }

    $content = Get-Content -Raw -LiteralPath $skillPath
    foreach ($field in @('name', 'description', 'version', 'license')) {
        if ($content -notmatch "(?m)^${field}:\s*.+$") {
            throw "$($dependency.id) is missing required metadata: $field"
        }
    }

    $name = [regex]::Match($content, '(?m)^name:\s*(.+)$').Groups[1].Value.Trim()
    $version = [regex]::Match($content, '(?m)^version:\s*(.+)$').Groups[1].Value.Trim()
    if ($name -ne $dependency.id) {
        throw "Expected skill name $($dependency.id), found $name."
    }
    if ($version -ne $dependency.declaredVersion) {
        throw "Expected version $($dependency.declaredVersion), found $version."
    }
    $observedNames += $name

    if ($dependency.id -eq 'impeccable') {
        if (-not (Test-Path -LiteralPath (Join-Path $discoveryPath 'reference') -PathType Container)) {
            throw 'Impeccable references are not accessible.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $discoveryPath 'scripts') -PathType Container)) {
            throw 'Impeccable scripts are not accessible.'
        }
    }

    if ($dependency.id -eq 'img2threejs') {
        foreach ($directory in @('docs', 'forge', 'grimoire')) {
            if (-not (Test-Path -LiteralPath (Join-Path $discoveryPath $directory) -PathType Container)) {
                throw "img2threejs resource directory is not accessible: $directory"
            }
        }
    }
}

if (($observedNames | Sort-Object -Unique).Count -ne $observedNames.Count) {
    throw 'Skill names conflict.'
}
if (Test-Path -LiteralPath (Join-Path $repoRoot '.codex/hooks.json')) {
    throw 'An active project hook was found, but hooks are outside FTK-02A scope.'
}

if (Get-Command codex -ErrorAction SilentlyContinue) {
    $promptJson = & codex debug prompt-input 'Skill discovery contract check.' | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw 'codex debug prompt-input failed.'
    }
    foreach ($dependency in $lock.dependencies) {
        $expectedLine = "- $($dependency.discoveredName):"
        if (-not $promptJson.Contains($expectedLine)) {
            throw "Codex did not advertise the expected skill name: $($dependency.discoveredName)"
        }
    }
    Write-Output "PASS: Codex advertises expected names: $(($lock.dependencies.discoveredName) -join ', ')"
} else {
    Write-Output 'SKIP: Codex CLI is not on PATH; host discovery contract was not tested.'
}

Write-Output "PASS: $($observedNames.Count) repo-local skills are distinct and structurally accessible: $($observedNames -join ', ')"
Write-Output 'PASS: no .codex/hooks.json is active.'
