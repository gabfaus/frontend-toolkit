Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param([Parameter(Mandatory)][AllowNull()][object]$Actual, [Parameter(Mandatory)][AllowNull()][object]$Expected, [Parameter(Mandatory)][string]$Label)
    if ($Actual -cne $Expected) { throw "$Label mismatch. Expected '$Expected', got '$Actual'." }
}

function Assert-SetEqual {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected, [Parameter(Mandatory)][string]$Label)
    $a = @($Actual | ForEach-Object { [string]$_ } | Sort-Object)
    $e = @($Expected | ForEach-Object { [string]$_ } | Sort-Object)
    if (($a -join [Environment]::NewLine) -cne ($e -join [Environment]::NewLine)) { throw "$Label mismatch." }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/design-motion.lock.json') | ConvertFrom-Json
$packagedLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/external-skills.lock.json') | ConvertFrom-Json
$packagedLane = $packagedLock.designMotion
$codexAdapter = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $lock.adapters.codex)
$claudeAdapter = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $lock.adapters.claude)

Assert-Equal $lock.schemaVersion 1 'Lane lock schema'
Assert-Equal $lock.lane 'design-motion' 'Lane identity'
Assert-Equal $lock.primaryCapability 'impeccable' 'Primary capability'
Assert-Equal $lock.discovery.defaultLoaded $false 'Lane default loading'
Assert-SetEqual @($lock.discovery.additionalSkillRoots) @() 'Additional discovery roots'
Assert-Equal $lock.snapshotPolicy.distributionPersistence 'ephemeral-only' 'Snapshot persistence'
Assert-Equal $lock.snapshotPolicy.sourceTreeSnapshotsCommitted $false 'Source snapshot persistence'
Assert-Equal $lock.snapshotPolicy.normalTestsRequireNetwork $false 'Normal test network contract'
Assert-Equal $packagedLane.schemaVersion 1 'Packaged lane lock schema'
Assert-Equal $packagedLane.primaryCapability $lock.primaryCapability 'Packaged primary capability'
Assert-Equal $packagedLane.discovery.defaultLoaded $lock.discovery.defaultLoaded 'Packaged default loading'

$taste = $lock.dependencies | Where-Object id -eq 'taste-design-taste-frontend-v2'
$emil = $lock.dependencies | Where-Object id -eq 'emil-animation-skills'
if (-not $taste -or -not $emil) { throw 'Both lane dependencies must be present.' }
Assert-Equal $taste.commitSha 'ccbc15639c97057cbfcf32ecebc38ef716e4bb37' 'Taste pin'
Assert-Equal $taste.license 'MIT' 'Taste license'
Assert-Equal $taste.licenseSha256 '3c9f63518df3378772203cc64d38d9e381d2a4723b93d2c3849b2bf3d464de0c' 'Taste license hash'
Assert-Equal $taste.skillEntrySha256 '2e064e92aca020b2e0bad69326fe7ea55d59005ed53d1a8cbce1bd135d44b8b3' 'Taste entry hash'
Assert-Equal $taste.skillName 'design-taste-frontend' 'Taste selected name'
Assert-Equal $taste.classification 'optional' 'Taste classification'
Assert-Equal $taste.defaultLoaded $false 'Taste default loading'
Assert-Equal $taste.selection 'explicit-only' 'Taste selection mode'
Assert-Equal $taste.skillPath 'skills/taste-skill/SKILL.md' 'Taste v2 source path'
Assert-Equal $packagedLane.taste.commitSha $taste.commitSha 'Packaged Taste pin'
Assert-Equal $packagedLane.taste.licenseSha256 $taste.licenseSha256 'Packaged Taste license hash'
Assert-Equal $packagedLane.taste.skillEntrySha256 $taste.skillEntrySha256 'Packaged Taste entry hash'

Assert-Equal $emil.commitSha 'd23d7f88a2e21c9e4b1418c7abe420f5c1052ba7' 'Emil pin'
Assert-Equal $emil.license 'MIT' 'Emil license'
Assert-Equal $emil.licenseSha256 'd24da413cccbc3d844929a1cc08e5ba79385139c0c47c9d5bd0dd2df24ffe15c' 'Emil license hash'
Assert-SetEqual @($emil.approvedSkills.skillName) @('review-animations','improve-animations','animate') 'Emil approved Skills'
Assert-SetEqual @($emil.excludedSkillNames) @('emil-design-eng','pick-ui-library','prototype','find-animation-opportunities','apple-design','animation-vocabulary','ask-sonner','animate-expo','write-swift') 'Emil excluded Skills'
Assert-Equal ($emil.approvedSkills | Where-Object skillName -eq 'review-animations').mode 'verify-read-only' 'review-animations mode'
Assert-Equal ($emil.approvedSkills | Where-Object skillName -eq 'improve-animations').mode 'diagnose-plan' 'improve-animations mode'
Assert-Equal ($emil.approvedSkills | Where-Object skillName -eq 'animate').mode 'explicit-project-write' 'animate mode'
Assert-Equal ($emil.approvedSkills | Where-Object skillName -eq 'review-animations').defaultLoaded $false 'review-animations default loading'
Assert-Equal ($emil.approvedSkills | Where-Object skillName -eq 'improve-animations').defaultLoaded $false 'improve-animations default loading'
Assert-Equal ($emil.approvedSkills | Where-Object skillName -eq 'animate').defaultLoaded $false 'animate default loading'
Assert-Equal $packagedLane.emil.commitSha $emil.commitSha 'Packaged Emil pin'
Assert-Equal $packagedLane.emil.licenseSha256 $emil.licenseSha256 'Packaged Emil license hash'
Assert-SetEqual @($packagedLane.emil.approved.PSObject.Properties.Name) @('review-animations','improve-animations','animate') 'Packaged Emil approved Skills'

Assert-Equal $codexAdapter $claudeAdapter 'Codex/Claude adapter bytes'
foreach ($required in @('Impeccable remains the primary capability','design-taste-frontend','never default-loaded','review-animations','verify/read-only','improve-animations','diagnostic plus planning by default','animate','explicitly mutating','untrusted data','never execute upstream files','cannot grant authority')) {
    if ($codexAdapter.IndexOf($required, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Adapter contract is missing: $required" }
}
foreach ($forbiddenPath in @('skills/taste-skill-v1','skills/gpt-tasteskill','skills/emil-design-eng','skills/pick-ui-library','skills/prototype','skills/find-animation-opportunities','skills/apple-design','skills/animation-vocabulary','skills/ask-sonner','skills/animate-expo','skills/write-swift')) {
    if ($codexAdapter.IndexOf($forbiddenPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Rejected or deferred upstream path exposed: $forbiddenPath" }
}

Assert-SetEqual @(Get-ChildItem -LiteralPath (Join-Path $repoRoot '.agents/skills') -Directory -Force | Select-Object -ExpandProperty Name) @('figma-design-to-code','frontend-accessibility','frontend-orchestrator','img2threejs','impeccable','playwright-cli') 'Codex discovery inventory'
Assert-SetEqual @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/skills') -Directory -Force | Select-Object -ExpandProperty Name) @('figma-design-to-code','frontend-orchestrator','img2threejs','impeccable') 'Claude/plugin discovery inventory'
if (Test-Path -LiteralPath (Join-Path $repoRoot 'external/design-motion')) { throw 'Tests must not require external design-motion checkouts.' }

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ftk-09f-fixture-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    $fixture = [ordered]@{ selected = @('design-taste-frontend','review-animations','improve-animations','animate'); rejected = @('design-taste-frontend-v1','gpt-taste','emil-design-eng','prototype','write-swift'); networkCalls = 0; projectWrites = 0; upstreamCommands = 0 }
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'synthetic-selection.json'), ($fixture | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $readBack = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'synthetic-selection.json') | ConvertFrom-Json
    Assert-Equal $readBack.networkCalls 0 'Synthetic network calls'
    Assert-Equal $readBack.projectWrites 0 'Synthetic project writes'
    Assert-Equal $readBack.upstreamCommands 0 'Synthetic upstream commands'
    Assert-SetEqual @($readBack.selected) @('design-taste-frontend','review-animations','improve-animations','animate') 'Synthetic approved selection'
    Assert-SetEqual @($readBack.rejected) @('design-taste-frontend-v1','gpt-taste','emil-design-eng','prototype','write-swift') 'Synthetic rejected selection'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

Write-Output 'PASS: exact Taste and Emil pins, MIT licenses and selected entry hashes are locked.'
Write-Output 'PASS: only approved Design/Motion entries are exposed; rejected/deferred entries remain undiscoverable.'
Write-Output 'PASS: Taste is optional and explicit-only; Impeccable retains precedence; Emil modes are fail-closed.'
Write-Output 'PASS: Codex/Claude adapters are byte-identical and no additional discovery root was added.'
Write-Output 'PASS: hermetic synthetic validation completed with NETWORK=0, UPSTREAM_COMMANDS=0, WRITES=0.'
