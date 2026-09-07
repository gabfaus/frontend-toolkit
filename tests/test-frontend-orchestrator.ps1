Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileHashOrAbsent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<absent>' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-ExactSet {
    param(
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][object[]]$Actual,
        [Parameter(Mandatory)][string]$Label
    )
    if (@(Compare-Object @($Expected | Sort-Object) @($Actual | Sort-Object)).Count) {
        throw "$Label mismatch."
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$skillRoot = Join-Path $repoRoot '.agents/skills/frontend-orchestrator'
$skillPath = Join-Path $skillRoot 'SKILL.md'
$routingPath = Join-Path $skillRoot 'references/routing.md'
$costPath = Join-Path $skillRoot 'references/cost-policy.md'
$policyPath = Join-Path $skillRoot 'references/routing-policy.json'
$scenariosPath = Join-Path $skillRoot 'references/scenarios.json'

if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { throw 'frontend-orchestrator SKILL.md is missing.' }
$skillDirectory = Get-Item -Force -LiteralPath $skillRoot
if ($skillDirectory.LinkType) { throw 'frontend-orchestrator must be owned repo-local content, not a link.' }

$skill = Get-Content -Raw -LiteralPath $skillPath
$frontmatter = [regex]::Match($skill, '(?s)\A---\r?\n(?<yaml>.*?)\r?\n---\r?\n')
if (-not $frontmatter.Success) { throw 'Skill frontmatter is invalid.' }
$name = [regex]::Match($frontmatter.Groups['yaml'].Value, '(?m)^name:\s*(.+)$').Groups[1].Value.Trim()
$description = [regex]::Match($frontmatter.Groups['yaml'].Value, '(?m)^description:\s*(.+)$').Groups[1].Value.Trim()
if ($name -ne 'frontend-orchestrator') { throw "Unexpected Skill name: $name" }
if ([string]::IsNullOrWhiteSpace($description) -or $description -notmatch '(?i)route|routing') { throw 'Skill description does not define its routing purpose.' }
$topLevelKeys = @([regex]::Matches($frontmatter.Groups['yaml'].Value, '(?m)^([a-zA-Z0-9-]+):(?:\s|$)') | ForEach-Object { $_.Groups[1].Value })
Assert-ExactSet @('name','description','metadata') $topLevelKeys 'Skill frontmatter keys'
if ($name -notmatch '^[a-z0-9-]+$' -or $name.StartsWith('-') -or $name.EndsWith('-') -or $name.Contains('--') -or $name.Length -gt 64) {
    throw 'Skill name violates quick_validate naming constraints.'
}
if ($description.Length -gt 1024 -or $description.Contains('<') -or $description.Contains('>')) {
    throw 'Skill description violates quick_validate constraints.'
}
if ($frontmatter.Groups['yaml'].Value -notmatch '(?m)^  short-description:\s*\S') { throw 'Skill short-description metadata is missing.' }
if ($skill -match '(?m)^\s*\[TODO:[^\r\n]*\]\s*$') { throw 'Skill contains an unfinished scaffold placeholder.' }

$referenceMatches = [regex]::Matches($skill, '\]\((references/[^)]+)\)')
$referencedFiles = @($referenceMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-ExactSet @('references/cost-policy.md','references/routing-policy.json','references/routing.md','references/scenarios.json') $referencedFiles 'Skill reference inventory'
foreach ($relativeReference in $referencedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $relativeReference) -PathType Leaf)) {
        throw "Skill reference is inaccessible: $relativeReference"
    }
}

$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
if ($policy.schemaVersion -ne 2 -or $policy.skill -ne 'frontend-orchestrator') { throw 'Routing policy identity is invalid.' }
if ($policy.principle -ne 'minimum-necessary-capabilities') { throw 'Minimum-capability principle is missing.' }
$capabilityNames = @($policy.capabilities.PSObject.Properties.Name)
Assert-ExactSet @('21st','ACCESSIBILITY_IMPLEMENT','ACCESSIBILITY_VERIFY','FIGMA_DESIGN_TO_CODE','FIGMA_READ','FIGMA_WRITE','animate','axe','chrome-devtools','context7','impeccable','improve-animations','img2threejs','playwright-cli','review-animations','shadcn','storybook','taste-v2') $capabilityNames 'Capability inventory'
if ($policy.capabilities.impeccable.role -ne 'primary-design-ux-authority') { throw 'Impeccable routing role is invalid.' }
if ($policy.capabilities.impeccable.entrypoint -ne 'ftk-owned-adapter-to-common-dispatcher' -or
    $policy.capabilities.impeccable.selectionMeaning -ne 'requested-operation-only' -or
    $policy.capabilities.impeccable.authorizationInference -ne 'deny' -or
    $policy.capabilities.impeccable.unknownOperationPolicy -ne 'deny') {
    throw 'Impeccable integrated routing boundary is incomplete.'
}
if ($policy.capabilities.shadcn.priorityRule -ne 'official-components-first') { throw 'Shadcn official-component priority is invalid.' }
if ($policy.capabilities.img2threejs.activation -ne 'explicit-or-clearly-implied-3d-only') { throw 'img2threejs activation policy is invalid.' }

$twentyFirst = $policy.capabilities.'21st'
Assert-ExactSet @('search') @($twentyFirst.defaultAllowedTools) '21st default allowlist'
$approvalClasses = @('metered','generation','ai-credits','copy-install-quota','retrieval-quota','mutation','publish','edit','delete','bookmark-or-list','account-or-profile','uncertain')
Assert-ExactSet $approvalClasses @($twentyFirst.explicitAuthorizationRequiredFor) '21st authorization classes'
if ($twentyFirst.unclassifiedToolPolicy -ne 'do-not-execute-without-explicit-authorization') { throw 'Unclassified 21st tools do not fail closed.' }
if ($policy.intentPrecedence[0].id -ne 'explicit-user-intent') { throw 'Explicit user intent is not highest priority.' }
Assert-ExactSet @('impeccable-unavailable','shadcn-unavailable','21st-unavailable','img2threejs-unavailable','figma-unavailable','browser-qa-unavailable','context7-unavailable','storybook-ineligible') @($policy.fallbacks.id) 'Fallback inventory'
if (@($policy.combinations | Where-Object mandatoryAll -eq $true).Count) { throw 'A workflow incorrectly requires all capabilities.' }

$routing = Get-Content -Raw -LiteralPath $routingPath
$cost = Get-Content -Raw -LiteralPath $costPath
if ($routing -notmatch '(?i)Prefer Shadcn' -or $routing -notmatch '(?i)Never query 21st merely') { throw 'Human-readable Shadcn/21st policy is incomplete.' }
if ($cost -notmatch '(?i)default allowlist contains only' -or $cost -notmatch '(?i)explicit authorization required' -or $cost -notmatch '(?i)do not execute') { throw 'Human-readable 21st cost gate is incomplete.' }

$matrix = Get-Content -Raw -LiteralPath $scenariosPath | ConvertFrom-Json
if ($matrix.schemaVersion -ne 2 -or @($matrix.scenarios).Count -ne 17) { throw 'Scenario matrix must contain ten versioned cases.' }
Assert-ExactSet @(1..17) @($matrix.scenarios.id) 'Scenario identifiers'
if (@($matrix.scenarios.id | Sort-Object -Unique).Count -ne 17) { throw 'Scenario identifiers are not unique.' }

$case1 = $matrix.scenarios | Where-Object id -eq 1
$case2 = $matrix.scenarios | Where-Object id -eq 2
$case3 = $matrix.scenarios | Where-Object id -eq 3
$case4 = $matrix.scenarios | Where-Object id -eq 4
$case5 = $matrix.scenarios | Where-Object id -eq 5
$case7 = $matrix.scenarios | Where-Object id -eq 7
$case8 = $matrix.scenarios | Where-Object id -eq 8
$case9 = $matrix.scenarios | Where-Object id -eq 9
$case10 = $matrix.scenarios | Where-Object id -eq 10
Assert-ExactSet @('impeccable') @($case1.required) 'Case 1 route'
Assert-ExactSet @('shadcn') @($case2.required) 'Case 2 route'
Assert-ExactSet @('21st/search') @($case3.required) 'Case 3 route'
Assert-ExactSet @('img2threejs') @($case4.required) 'Case 4 route'
if ($case5.forbidden -notcontains 'invoke-all-by-default') { throw 'Case 5 does not enforce minimum capability.' }
if ($case7.authorizationRequiredFor -notcontains 'ai-credits' -or $case7.forbidden -notcontains '21st/generate-before-authorization') { throw 'Case 7 metered gate is invalid.' }
if ($case8.authorizationRequiredFor -notcontains 'quota-or-effect') { throw 'Case 8 install/copy gate is invalid.' }
if ($case9.forbidden -notcontains '21st') { throw 'Case 9 does not honor Shadcn-only intent.' }
Assert-ExactSet @('img2threejs','shadcn') @($case10.required) 'Case 10 route'

foreach ($forbidden in @(
    '.codex/hooks.json','.codex/config.toml','.mcp.json','.codex-plugin/plugin.json',
    '.agents/skills/21st-cli-use','.agents/skills/21st-ai','.agents/skills/21st-registry','.agents/skills/21st-design-sync',
    '.agents/skills/jpisnice','node_modules/@21st-dev','node_modules/@21st-dev/magic'
)) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $forbidden)) { throw "Forbidden orchestrator artifact found: $forbidden" }
}

& (Join-Path $PSScriptRoot 'test-skill-integration.ps1')
$toolchain = & (Join-Path $repoRoot 'scripts/resolve-toolchain.ps1')
if ($toolchain.StableCodexVersion -ne '0.150.1') { throw 'Stable Codex 0.150.1 is required for discovery.' }
$configPath = Join-Path $env:USERPROFILE '.codex/config.toml'
$configHashBefore = Get-FileHashOrAbsent $configPath
$userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path','Machine')
$processPathBefore = $env:PATH
$pythonPathBefore = $env:FTK_PYTHON_PATH
try {
    $env:PATH = "$(Split-Path -Parent $toolchain.StableCodexPath);$processPathBefore"
    $env:FTK_PYTHON_PATH = $toolchain.PythonPath
    Push-Location $repoRoot
    try {
        $prompt = (& $toolchain.StableCodexPath debug prompt-input 'Frontend orchestrator discovery contract.' | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'Codex Skill discovery failed.' }
    } finally { Pop-Location }
} finally {
    $env:PATH = $processPathBefore
    $env:FTK_PYTHON_PATH = $pythonPathBefore
}

foreach ($expectedName in @('frontend-orchestrator','figma-design-to-code','frontend-accessibility','playwright-cli','impeccable','img2threejs')) {
    if (-not $prompt.Contains(("- " + $expectedName + ":"))) { throw "Codex did not advertise Skill: $expectedName" }
}
if ((Get-FileHashOrAbsent $configPath) -ne $configHashBefore) { throw 'Codex user config changed during orchestrator discovery.' }
if ([Environment]::GetEnvironmentVariable('Path','User') -ne $userPathBefore) { throw 'Persistent user PATH changed.' }
if ([Environment]::GetEnvironmentVariable('Path','Machine') -ne $machinePathBefore) { throw 'Persistent machine PATH changed.' }

Write-Output 'PASS: frontend-orchestrator metadata, references and machine-readable routing policy validated.'
Write-Output 'PASS: versioned scenario contracts cover minimum capability, staged routing, user intent, fallbacks and authorization gates.'
Write-Output 'PASS: Codex CLI 0.150.1 discovers the six approved FTK-owned Skills without changing user configuration.'
