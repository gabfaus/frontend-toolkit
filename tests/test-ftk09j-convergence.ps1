Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ExactSet {
    param([Parameter(Mandatory)][object[]]$Actual, [Parameter(Mandatory)][object[]]$Expected, [Parameter(Mandatory)][string]$Label)
    $actualText = @($Actual | ForEach-Object { [string]$_ } | Sort-Object) -join [Environment]::NewLine
    $expectedText = @($Expected | ForEach-Object { [string]$_ } | Sort-Object) -join [Environment]::NewLine
    if ($actualText -cne $expectedText) { throw "$Label mismatch." }
}

function Invoke-PowerShellFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    $output = ''
    $exitCode = 0
    try {
        $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } catch {
        $output += ($_ | Out-String)
        $exitCode = 1
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$routingPath = Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/routing-policy.json'
$pluginRoutingPath = Join-Path $repoRoot 'plugin/frontend-toolkit/skills/frontend-orchestrator/references/routing-policy.json'
$routing = Get-Content -Raw -LiteralPath $routingPath | ConvertFrom-Json
$pluginRouting = Get-Content -Raw -LiteralPath $pluginRoutingPath | ConvertFrom-Json
$effectPolicy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/effect-policy.json') | ConvertFrom-Json
$dispatcher = Join-Path $repoRoot 'plugin/frontend-toolkit/security/invoke-capability.ps1'
$browserLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/browser-qa.lock.json') | ConvertFrom-Json
$convergenceLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/ftk-09j-convergence.lock.json') | ConvertFrom-Json
$figmaPolicy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/figma-operation-policy.json') | ConvertFrom-Json
$contextPolicy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/context7-operation-policy.json') | ConvertFrom-Json
$storybookLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/storybook.lock.json') | ConvertFrom-Json
$storybookAdapter = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/security/storybook-adapter.mjs')
$normalMcpText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/.mcp.json')
$normalMcp = $normalMcpText | ConvertFrom-Json
$claudeMcp = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'claude/mcp.json') | ConvertFrom-Json

Assert-True ($routing.schemaVersion -eq 3 -and ($routing.stageModel -join ',') -eq 'PLAN,EXECUTE,VERIFY') 'Routing V3 PLAN/EXECUTE/VERIFY contract is missing.'
Assert-True ($routing.principle -eq 'material-complementary-selection' -and $routing.defaultMode -eq 'QUALITY_FIRST') 'Material selection/default mode contract is missing.'
Assert-True (($routing.modes.PSObject.Properties.Name | Sort-Object) -join ',' -eq 'FIDELITY_FIRST,QUALITY_FIRST') 'Routing modes are incomplete.'
Assert-True ($routing.modes.QUALITY_FIRST.useAllAvailable -eq $false -and $routing.modes.QUALITY_FIRST.allowsMaterialImprovements -eq $true) 'QUALITY_FIRST is incorrectly defined.'
Assert-True ($routing.modes.FIDELITY_FIRST.activation.requiresSemanticIntent -eq $true -and $routing.modes.FIDELITY_FIRST.activation.matcher -eq 'semantic-intent-not-literal-only') 'FIDELITY_FIRST activation is not semantic.'
Assert-True ($routing.availability.coreDoesNotMeanDefaultLoaded -eq $true -and @($routing.availability.defaultLoaded).Count -eq 0) 'CORE/default loading separation is missing.'
Assert-ExactSet @($routing.availability.classes) @('CORE','OPTIONAL') 'Availability classes'
Assert-ExactSet @($routing.routing.classes) @('AUTO_ELIGIBLE','INTENT_TRIGGERED','SOURCE_TRIGGERED','EXPLICIT_ONLY') 'Routing classes'
Assert-ExactSet @($routing.operationSurface.states) @('EXECUTABLE','REQUEST_ONLY','REGISTERED_NO_HANDLER','UNAVAILABLE') 'Static operation surface states'
Assert-True ($routing.operationSurface.sourceOfTruth -eq 'plugin/frontend-toolkit/security/effect-policy.json' -and $routing.operationSurface.unknownOperation.policy -eq 'fail-closed') 'Operation surface fail-closed boundary is missing.'
Assert-ExactSet @($routing.workflowResolution.outcomes) @('CAPABILITY_SURFACE_BLOCKED') 'Contextual workflow outcomes'
Assert-True ($routing.workflowResolution.routingFailure -eq $false -and $routing.workflowResolution.effectClass -eq $false -and $routing.workflowResolution.capabilityGlobalAvailabilityUnaffected -eq $true) 'Contextual CAPABILITY_SURFACE_BLOCKED semantics are invalid.'
Assert-True ($routing.effectRequirement.sourceOfTruth -eq 'plugin/frontend-toolkit/security/effect-policy.json' -and $routing.effectRequirement.selectionDoesNotAuthorize -eq $true) 'Effect selection/authorization separation is missing.'
Assert-True ($routing.selectionContract.materialJustification.atLeastOneRequired -eq $true -and $routing.selectionContract.singleNumericScore -eq 'not-sufficient-for-decision') 'Material selection contract is incomplete.'
Assert-True ($routing.normalMode.preserved -eq $true) 'Normal/orchestrated mode was not preserved.'
Assert-True ($routing.discovery.defaultLoaded.Count -eq 0 -and $routing.discovery.additionalSkillRoots.Count -eq 0) 'Default discovery is not selective.'
Assert-True ($routing.discovery.simultaneousLoadPolicy -match 'distinct-required-result') 'Simultaneous load policy is missing.'
Assert-True (($routing | ConvertTo-Json -Depth 30) -eq ($pluginRouting | ConvertTo-Json -Depth 30)) 'Codex/plugin routing policies diverged.'
Assert-True ($routing.unknownCapabilityPolicy -eq 'fail-closed' -and $routing.unknownToolPolicy -eq 'fail-closed' -and $routing.unknownEffectPolicy -eq 'fail-closed') 'Unknown routing state is not fail-closed.'

$expectedCodexSkills = @('figma-design-to-code','frontend-accessibility','frontend-orchestrator','img2threejs','impeccable','playwright-cli')
$expectedPluginSkills = @('figma-design-to-code','frontend-orchestrator','img2threejs','impeccable')
Assert-ExactSet @($routing.discovery.codexSkillAllowlist) $expectedCodexSkills 'Codex discovery allowlist'
Assert-ExactSet @($routing.discovery.pluginSkillAllowlist) $expectedPluginSkills 'Plugin discovery allowlist'
Assert-ExactSet @($routing.stageRoutes.PLAN.candidates) @('21st','FIGMA_READ','context7','impeccable','img2threejs','shadcn','storybook','taste-v2','improve-animations') 'PLAN candidates'
Assert-ExactSet @($routing.stageRoutes.EXECUTE.preserved) @('21st/search','img2threejs','shadcn') 'EXECUTE preserved capabilities'
Assert-ExactSet @($routing.stageRoutes.EXECUTE.explicitOnly) @('ACCESSIBILITY_IMPLEMENT','FIGMA_DESIGN_TO_CODE','animate') 'EXECUTE explicit capabilities'
Assert-ExactSet @($routing.stageRoutes.VERIFY.core) @('ACCESSIBILITY_VERIFY','playwright-cli','review-animations') 'VERIFY core capabilities'
Assert-ExactSet @($routing.stageRoutes.VERIFY.conditional) @('axe') 'VERIFY conditional capabilities'
Assert-ExactSet @($routing.stageRoutes.VERIFY.optional) @('chrome-devtools') 'VERIFY optional capabilities'

$requiredOperations = @(
    'design-motion.taste-v2','design-motion.review-animations','design-motion.improve-animations','design-motion.animate',
    'figma.read','figma.design-to-code','figma.write','browser-qa.playwright','browser-qa.chrome-devtools',
    'accessibility.verify','accessibility.implement','accessibility.axe',
    'context7.resolve-library-id','context7.query-docs','storybook.detect','storybook.docs','storybook.preview',
    'storybook.testing','storybook.remote-review','storybook.publication',
    'img2threejs.glb-procedural','img2threejs.glb-procedural.execute'
)
foreach ($operationId in $requiredOperations) {
    $definition = @($effectPolicy.operations | Where-Object id -CEQ $operationId)
    Assert-True ($definition.Count -eq 1) "Common operation missing or ambiguous: $operationId"
    Assert-True (@($definition[0].effects).Count -gt 0 -and @($definition[0].effects | Where-Object { $_ -eq 'UNKNOWN' }).Count -eq 0) "Common operation effect is invalid: $operationId"
    if ($definition[0].status -eq 'enabled') {
        Assert-True ($definition[0].handler -eq 'ftk.request-only') "Enabled common operation bypasses request-only dispatcher: $operationId"
    } else {
        Assert-True ($definition[0].status -match '^authorization-required' -and $definition[0].handler -eq 'none') "Effectful common operation is not authorization-gated: $operationId"
    }
}
Assert-True ($effectPolicy.unknownEffectPolicy -eq 'deny' -and @($effectPolicy.effectClasses) -contains 'UNKNOWN') 'Common effect policy is not fail-closed.'

$phase1 = @($effectPolicy.operations | Where-Object id -CEQ 'img2threejs.glb-procedural')
$phase2 = @($effectPolicy.operations | Where-Object id -CEQ 'img2threejs.glb-procedural.execute')
$pipeline = @($effectPolicy.operations | Where-Object id -CEQ 'img2threejs.glb-pipeline')
$preview = @($effectPolicy.operations | Where-Object { $_.id -match '^img2threejs\..*preview' })
Assert-True ($phase1.Count -eq 1 -and $phase2.Count -eq 1 -and $preview.Count -eq 0) '03C operation registration is ambiguous or invented a preview surface.'
Assert-True ($phase1[0].status -eq 'enabled' -and $phase1[0].handler -eq 'ftk.request-only' -and
    $phase1[0].effect -eq 'LOCAL_READ_ONLY' -and (@($phase1[0].effects) -join ',') -eq 'LOCAL_READ_ONLY' -and
    $phase1[0].projectCodeExecutes -eq $false -and $phase1[0].networkRequirement -eq 'none') '03C Phase 1 is not a local request-only contract.'
Assert-True ($phase2[0].status -match '^authorization-required' -and $phase2[0].handler -eq 'none' -and
    $phase2[0].projectCodeExecutes -eq $false -and $phase2[0].executableSource -match 'not registered') '03C Phase 2 exposed an executable handler or grant.'
Assert-True ($pipeline[0].handler -eq 'ftk.img2threejs.glb-pipeline' -and $pipeline[0].status -eq 'enabled' -and
    $pipeline[0].projectCodeExecutes -eq $true -and (@($pipeline[0].effects) -join ',') -eq 'LOCAL_PROJECT_WRITE,PROJECT_CODE_EXECUTION,LOOPBACK_EPHEMERAL') 'Existing GLB pipeline changed during 03C convergence.'
Assert-ExactSet @($routing.operationSurface.capabilities.img2threejs.EXECUTABLE) @('img2threejs.capability-summary','img2threejs.glb-pipeline','img2threejs.codec-verify','img2threejs.typescript-build','img2threejs.vite-build','img2threejs.state.init','img2threejs.state.status','img2threejs.state.mark','img2threejs.state.next','img2threejs.state.create','img2threejs.state.read','img2threejs.state.write','img2threejs.state.update') 'Existing img2threejs executable operations'
Assert-ExactSet @($routing.operationSurface.capabilities.img2threejs.REQUEST_ONLY) @('img2threejs.glb-procedural') '03C Phase 1 routing state'
Assert-ExactSet @($routing.operationSurface.capabilities.img2threejs.REGISTERED_NO_HANDLER) @('img2threejs.glb-procedural.execute','img2threejs.network-helper') '03C Phase 2 routing state'
Assert-True (@($routing.operationSurface.capabilities.img2threejs.UNAVAILABLE).Count -eq 0) '03C preview routing state is not unavailable.'

$figmaPlan = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','figma.read','-PlanOnly')
Assert-True ($figmaPlan.ExitCode -eq 0) 'Figma request-only plan failed.'
$figmaPlanJson = $figmaPlan.Output | ConvertFrom-Json
Assert-True ($figmaPlanJson.handlerInvoked -eq $false -and $figmaPlanJson.externalCall -eq $false) 'Figma plan granted an effect.'
$figmaRequest = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','figma.read')
Assert-True ($figmaRequest.ExitCode -eq 0) 'Figma request-only dispatch failed.'
$figmaRequestJson = $figmaRequest.Output | ConvertFrom-Json
Assert-True ($figmaRequestJson.requestOnly -and $figmaRequestJson.execution -eq 'not-performed') 'Figma dispatch was not request-only.'

$contextRequest = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','context7.query-docs')
Assert-True ($contextRequest.ExitCode -eq 0) 'Context7 request-only dispatch failed.'
$contextRequestJson = $contextRequest.Output | ConvertFrom-Json
Assert-True ($contextRequestJson.requestOnly -and $contextRequestJson.externalCall -eq $false) 'Context7 dispatch escaped the facade boundary.'

$phase1Request = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','img2threejs.glb-procedural')
Assert-True ($phase1Request.ExitCode -eq 0) 'img2threejs Phase 1 request-only dispatch failed.'
$phase1RequestJson = $phase1Request.Output | ConvertFrom-Json
Assert-True ($phase1RequestJson.requestOnly -and $phase1RequestJson.execution -eq 'not-performed' -and
    $phase1RequestJson.handlerInvoked -eq $false -and $phase1RequestJson.externalCall -eq $false) '03C Phase 1 selection granted execution.'

$phase2Plan = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','img2threejs.glb-procedural.execute','-PlanOnly')
Assert-True ($phase2Plan.ExitCode -eq 0) 'img2threejs Phase 2 blocked plan failed.'
$phase2PlanJson = $phase2Plan.Output | ConvertFrom-Json
Assert-True ($phase2PlanJson.authorizationDecision -eq 'authorization-required' -and $phase2PlanJson.handler -eq 'none' -and
    $phase2PlanJson.handlerInvoked -eq $false -and $phase2PlanJson.externalCall -eq $false) '03C Phase 2 inherited executable authorization.'

$authPlan = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','design-motion.animate','-PlanOnly')
Assert-True ($authPlan.ExitCode -eq 0 -and ($authPlan.Output | ConvertFrom-Json).authorizationDecision -eq 'authorization-required') 'Animate authorization plan drifted.'
$authRun = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','accessibility.implement')
Assert-True ($authRun.ExitCode -ne 0 -and $authRun.Output -match 'AUTHORIZATION_REQUIRED') 'Accessibility implementation did not fail closed.'
$unknownRun = Invoke-PowerShellFile -Path $dispatcher -Arguments @('-Operation','future.unknown')
Assert-True ($unknownRun.ExitCode -ne 0 -and $unknownRun.Output -match 'UNKNOWN operation') 'Unknown operation did not fail closed.'

Assert-ExactSet @($figmaPolicy.transports.PSObject.Properties.Name) @('desktop','remote') 'Figma transports'
Assert-True ($figmaPolicy.serverSelection.activeServerIdsMustBeExactlyOne -and $figmaPolicy.serverSelection.rejectMultipleActiveServers) 'Figma transport collision is not rejected.'
Assert-ExactSet @($contextPolicy.exposedTools.name) @('query-docs','resolve-library-id') 'Context7 facade tools'
Assert-True ($contextPolicy.upstream.integration -match 'direct-MCP-exposure-rejected' -and $contextPolicy.unknownToolPolicy -eq 'deny' -and $contextPolicy.dataBoundary.cache -eq 'disabled') 'Context7 facade boundary drifted.'
Assert-True ($storybookLock.installation -eq 'never-automatic' -and $storybookLock.runtimeStartup -eq 'never-automatic' -and @($storybookLock.blockedScopes) -contains 'chromatic') 'Storybook conditional policy drifted.'
Assert-True ($storybookAdapter -notmatch 'npm install|npx .*storybook|chromatic publish') 'Storybook adapter contains an automatic install/publication path.'

Assert-ExactSet @($normalMcp.mcpServers.PSObject.Properties.Name) @('21st','shadcn') 'Normal Codex MCP inventory'
Assert-ExactSet @($claudeMcp.mcpServers.PSObject.Properties.Name) @('21st','shadcn') 'Normal Claude MCP inventory'
Assert-True ($normalMcpText -notmatch '(?i)playwright|chrome-devtools|context7|storybook|figma') 'Normal Codex MCP silently activated conditional transports.'
Assert-True ($browserLock.playwright.cli.version -eq '0.1.19' -and $browserLock.playwright.cli.supplyChainException.sourceIntegration -eq 'ACCEPT_WITH_RESTRICTIONS' -and $convergenceLock.playwrightSupplyChain.releaseAcceptance -eq 'PENDING_FINAL_RELEASE_REVIEW') 'Playwright supply-chain exception state is missing.'
Assert-True ($browserLock.playwright.cli.supplyChainException.issueStatusAtValidation -eq 'OPEN' -and $browserLock.playwright.cli.dependencies.playwright -eq '1.63.0-alpha-2026-08-31' -and $browserLock.playwright.cli.dependencies.'playwright-core' -eq '1.63.0-alpha-2026-08-31') 'Playwright alpha dependency disclosure drifted.'

. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$pluginRoot = Join-Path $repoRoot 'plugin/frontend-toolkit'
Assert-ApprovedSourceComposition -RepoRoot $repoRoot -PluginSource $pluginRoot -FileAllowlist @(Get-FrontendToolkitSourceFileAllowlist) -DirectoryAllowlist @(Get-FrontendToolkitSourceDirectoryAllowlist) -AllowWorkingTree

foreach ($externalCallMarker in @('fetch(', 'npm install', 'npx --yes', 'playwright-mcp')) {
    if ($normalMcpText -match [regex]::Escape($externalCallMarker)) { throw "Normal MCP includes an external call marker: $externalCallMarker" }
}
Write-Output 'PASS: FTK-09J PLAN/EXECUTE/VERIFY routing and contextual loading are machine-readable and mirrored across adapters.'
Write-Output 'PASS: common request-only dispatcher preserves effect mediation; unknown and authorization-required paths fail closed.'
Write-Output 'PASS: Figma, Context7, Storybook, Browser QA and Playwright supply-chain boundaries remain conditional and explicit.'
Write-Output 'PASS: Codex/Claude normal MCP inventories stay separate and conditional transports are not silently activated.'
Write-Output 'PASS: source-tree plugin composition matches its explicit distribution allowlist.'
