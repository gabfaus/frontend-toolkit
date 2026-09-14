Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-SetEqual {
    param([Parameter(Mandatory)][object[]]$Actual, [Parameter(Mandatory)][object[]]$Expected, [Parameter(Mandatory)][string]$Label)
    $actualText = @($Actual | ForEach-Object { [string]$_ } | Sort-Object) -join "`n"
    $expectedText = @($Expected | ForEach-Object { [string]$_ } | Sort-Object) -join "`n"
    if ($actualText -cne $expectedText) { throw "$Label mismatch. Actual: $actualText Expected: $expectedText" }
}

function Read-Json {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -Encoding UTF8 -Raw -LiteralPath $Path | ConvertFrom-Json
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$canonicalPolicyPath = Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/routing-policy.json'
$distributedPolicyPath = Join-Path $repoRoot 'plugin/frontend-toolkit/skills/frontend-orchestrator/references/routing-policy.json'
$canonicalScenarioPath = Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/scenarios.json'
$distributedScenarioPath = Join-Path $repoRoot 'plugin/frontend-toolkit/skills/frontend-orchestrator/references/scenarios.json'
$effectPolicyPath = Join-Path $repoRoot 'plugin/frontend-toolkit/security/effect-policy.json'

$canonicalPolicyText = Get-Content -Encoding UTF8 -Raw -LiteralPath $canonicalPolicyPath
$distributedPolicyText = Get-Content -Encoding UTF8 -Raw -LiteralPath $distributedPolicyPath
$canonicalScenarioText = Get-Content -Encoding UTF8 -Raw -LiteralPath $canonicalScenarioPath
$distributedScenarioText = Get-Content -Encoding UTF8 -Raw -LiteralPath $distributedScenarioPath
Assert-True ($canonicalPolicyText -ceq $distributedPolicyText) 'Canonical and distributed routing policies diverged.'
Assert-True ($canonicalScenarioText -ceq $distributedScenarioText) 'Canonical and distributed scenario matrices diverged.'

$policy = Read-Json $canonicalPolicyPath
$matrix = Read-Json $canonicalScenarioPath
$effectPolicy = Read-Json $effectPolicyPath
$capabilityIds = @($policy.capabilities.PSObject.Properties.Name)

Assert-True ($policy.schemaVersion -eq 3) 'Routing policy is not schema V3.'
Assert-True ($policy.principle -eq 'material-complementary-selection') 'Material-complementary selection principle is missing.'
Assert-True ($policy.defaultMode -eq 'QUALITY_FIRST') 'QUALITY_FIRST is not the default mode.'
Assert-SetEqual @($policy.modes.PSObject.Properties.Name) @('QUALITY_FIRST','FIDELITY_FIRST') 'Mode inventory'
Assert-True ($policy.modes.QUALITY_FIRST.activation -eq 'default') 'QUALITY_FIRST activation is not default.'
Assert-True ($policy.modes.QUALITY_FIRST.useAllAvailable -eq $false) 'QUALITY_FIRST incorrectly selects all available capabilities.'
Assert-True ($policy.modes.QUALITY_FIRST.allowsMaterialImprovements -eq $true -and $policy.modes.QUALITY_FIRST.allowsComplementaryCapabilities -eq $true) 'QUALITY_FIRST material-complement semantics are incomplete.'
Assert-True ($policy.modes.FIDELITY_FIRST.activation.requiresSemanticIntent -eq $true) 'FIDELITY_FIRST does not require semantic intent.'
Assert-True ($policy.modes.FIDELITY_FIRST.activation.matcher -eq 'semantic-intent-not-literal-only') 'FIDELITY_FIRST uses fragile literal matching.'
Assert-True ($policy.modes.FIDELITY_FIRST.allowsMaterialImprovements -eq $false -and $policy.modes.FIDELITY_FIRST.allowsComplementaryCapabilities -eq $true) 'FIDELITY_FIRST precedence or complementary behavior is invalid.'
Assert-True (@($policy.modes.FIDELITY_FIRST.activation.triggers).Count -ge 6 -and [string]$policy.modes.FIDELITY_FIRST.activation.futureExtension -eq 'multilingual-semantic-trigger-set') 'FIDELITY_FIRST trigger extensibility is missing.'

Assert-SetEqual @($policy.availability.classes) @('CORE','OPTIONAL') 'Availability classes'
Assert-True ($policy.availability.coreDoesNotMeanDefaultLoaded -eq $true -and @($policy.availability.defaultLoaded).Count -eq 0) 'CORE/default-loaded separation is missing.'
Assert-SetEqual @($policy.routing.classes) @('AUTO_ELIGIBLE','INTENT_TRIGGERED','SOURCE_TRIGGERED','EXPLICIT_ONLY') 'Routing classes'
Assert-SetEqual @($policy.operationSurface.states) @('EXECUTABLE','REQUEST_ONLY','REGISTERED_NO_HANDLER','UNAVAILABLE') 'Static operation surface states'
Assert-True ($policy.operationSurface.sourceOfTruth -eq 'plugin/frontend-toolkit/security/effect-policy.json') 'Operation surface source of truth drifted.'
Assert-True ($policy.operationSurface.unknownOperation.policy -eq 'fail-closed' -and $policy.operationSurface.unknownOperation.handlerPolicy -eq 'never-invented-by-routing') 'Unknown operations do not fail closed.'
Assert-SetEqual @($policy.workflowResolution.outcomes) @('CAPABILITY_SURFACE_BLOCKED') 'Contextual workflow outcomes'
Assert-True ($policy.workflowResolution.routingFailure -eq $false -and $policy.workflowResolution.effectClass -eq $false -and $policy.workflowResolution.capabilityGlobalAvailabilityUnaffected -eq $true) 'CAPABILITY_SURFACE_BLOCKED contextual semantics are invalid.'
Assert-True ($policy.workflowResolution.cases.'img2threejs-reference-image-reconstruction'.routing -eq 'PASS' -and $policy.workflowResolution.cases.'img2threejs-reference-image-reconstruction'.selectedCapability -eq 'img2threejs' -and $policy.workflowResolution.cases.'img2threejs-reference-image-reconstruction'.requiredOperation.present -eq $false -and $policy.workflowResolution.cases.'img2threejs-reference-image-reconstruction'.outcome -eq 'CAPABILITY_SURFACE_BLOCKED') 'img2threejs contextual operation resolution is invalid.'
Assert-True ($policy.effectRequirement.sourceOfTruth -eq 'plugin/frontend-toolkit/security/effect-policy.json' -and $policy.effectRequirement.selectionDoesNotAuthorize -eq $true) 'Selection and effect authorization are conflated.'
Assert-SetEqual @($policy.selectionContract.attributes) @('relevance','expectedMaterialGain','complementarity','redundancy','sourceRequirement','stageFit','availability','operationAvailability','effectRequirement','explicitInclusion','explicitExclusion') 'Selection attributes'
Assert-True ($policy.selectionContract.materialJustification.atLeastOneRequired -eq $true -and $policy.selectionContract.singleNumericScore -eq 'not-sufficient-for-decision') 'Selection decision rule is not material and semantic.'

Assert-SetEqual @($policy.availability.capabilities.PSObject.Properties.Name) $capabilityIds 'Availability capability IDs'
Assert-SetEqual @($policy.routing.capabilities.PSObject.Properties.Name) $capabilityIds 'Routing capability IDs'
Assert-SetEqual @($policy.operationSurface.capabilities.PSObject.Properties.Name) $capabilityIds 'Operation-surface capability IDs'
Assert-SetEqual @($policy.effectRequirement.capabilities.PSObject.Properties.Name) $capabilityIds 'Effect-requirement capability IDs'
Assert-SetEqual @($policy.selectionContract.capabilities.PSObject.Properties.Name) $capabilityIds 'Selection capability IDs'

$effectOperationIds = @($effectPolicy.operations | ForEach-Object { [string]$_.id })
$runtimeOperationIds = @('shadcn/search_items_in_registries','21st/search')
foreach ($capabilityId in $capabilityIds) {
    $availability = [string]$policy.availability.capabilities.PSObject.Properties[$capabilityId].Value
    Assert-True ($availability -in @('CORE','OPTIONAL')) "Invalid availability class: $capabilityId"

    $routing = $policy.routing.capabilities.PSObject.Properties[$capabilityId].Value
    Assert-True ([string]$routing.class -in @('AUTO_ELIGIBLE','INTENT_TRIGGERED','SOURCE_TRIGGERED','EXPLICIT_ONLY')) "Invalid routing class: $capabilityId"
    Assert-True (@($routing.stages).Count -gt 0) "Routing stage fit is empty: $capabilityId"

    $surface = $policy.operationSurface.capabilities.PSObject.Properties[$capabilityId].Value
    foreach ($state in @('EXECUTABLE','REQUEST_ONLY','REGISTERED_NO_HANDLER','UNAVAILABLE')) {
        Assert-True ($surface.PSObject.Properties.Name -contains $state) "Operation surface state is missing: $capabilityId/$state"
    }
    foreach ($state in @('EXECUTABLE','REQUEST_ONLY','REGISTERED_NO_HANDLER')) {
        foreach ($operationId in @($surface.PSObject.Properties[$state].Value)) {
            $operationId = [string]$operationId
            Assert-True ($effectOperationIds -contains $operationId -or $runtimeOperationIds -contains $operationId) "Routing references an operation outside the governed registries: $operationId"
        }
    }

    $effectRequirement = $policy.effectRequirement.capabilities.PSObject.Properties[$capabilityId].Value
    Assert-True ([string]$effectRequirement.operationSurfaceRef -eq "operationSurface.capabilities.$capabilityId") "Effect requirement does not reference the operation surface: $capabilityId"
    Assert-True (-not ($effectRequirement.PSObject.Properties.Name -contains 'effects')) "Routing duplicated concrete effect classes: $capabilityId"

    $selection = $policy.selectionContract.capabilities.PSObject.Properties[$capabilityId].Value
    foreach ($attribute in @($policy.selectionContract.attributes)) {
        Assert-True ($selection.PSObject.Properties.Name -contains [string]$attribute) "Selection attribute is missing: $capabilityId/$attribute"
    }
}
Assert-True ((($policy.operationSurface | ConvertTo-Json -Depth 30) -notmatch '"handler"\s*:') -and (($policy.operationSurface | ConvertTo-Json -Depth 30) -notmatch '"effect"\s*:')) 'Operation surface contains invented handler/effect authority.'
Assert-True ($effectPolicy.unknownEffectPolicy -eq 'deny' -and @($effectPolicy.effectClasses) -contains 'UNKNOWN') 'Effect policy fail-closed authority drifted.'

$taxonomy = $policy.surfaceTaxonomy
$blocked3d = $taxonomy.'img2threejs-reference-image-reconstruction'
Assert-True ($blocked3d.routing -eq 'PASS' -and $blocked3d.state -eq 'CAPABILITY_SURFACE_BLOCKED' -and $blocked3d.cause -eq 'required-operation-absent' -and $null -eq $blocked3d.operationId) 'img2threejs capability-surface taxonomy is invalid.'
Assert-True ($taxonomy.'playwright-accessibility'.routing -eq 'PASS' -and $taxonomy.'playwright-accessibility'.state -eq 'FIRST-CLASS VERIFY SURFACE PARTIAL' -and $taxonomy.'playwright-accessibility'.dedicatedSurface -eq 'unavailable') 'Playwright/accessibility partial taxonomy is invalid.'
Assert-True ($taxonomy.impeccable.routing -eq 'PASS' -and $taxonomy.impeccable.state -eq 'EXECUTION SURFACE ROBUSTNESS GAP' -and $taxonomy.impeccable.condition -eq 'pinned-child-process-exit-code-1') 'Impeccable execution-gap taxonomy is invalid.'

Assert-True ($matrix.schemaVersion -eq 3 -and @($matrix.scenarios).Count -eq 28) 'Routing scenario matrix is not V3 complete.'
Assert-SetEqual @($matrix.scenarioGroups.PSObject.Properties.Name) @('ROUTING_POSITIVE','ANTI_OVERRouting','QUALITY_FIRST','FIDELITY_FIRST','OPERATION_SURFACE','EFFECT_BOUNDARY','FALLBACK','SECURITY') 'Scenario groups'
Assert-SetEqual @($matrix.scenarios.id) @(1..28) 'Scenario IDs'
$login = $matrix.scenarios | Where-Object id -eq 6
Assert-True ($login.expectedMode -eq 'QUALITY_FIRST') 'Simple login does not prove QUALITY_FIRST.'
Assert-SetEqual @($login.forbidden) @('FIGMA_READ','FIGMA_DESIGN_TO_CODE','21st','storybook','context7','review-animations','improve-animations','animate','taste-v2','img2threejs-without-3d-requirement','use-all-available') 'Simple login anti-overrouting'
$e010 = $matrix.scenarios | Where-Object id -eq 18
Assert-SetEqual @($e010.required) @('frontend-orchestrator','impeccable','playwright-cli','ACCESSIBILITY_VERIFY') 'E-010 selected capabilities'
Assert-SetEqual @($e010.correctlyNotSelected) @('Figma','21st','Storybook','Context7','img2threejs') 'E-010 excluded capabilities'
Assert-True ($e010.evidenceId -eq 'E-010' -and $e010.historicalExecution -eq $true -and $e010.formalV3Evidence -eq $false -and $e010.routing -eq 'PASS' -and $e010.visualResult -eq 'PASS') 'E-010 historical status is not explicit.'
Assert-True ($e010.surfaceMaterialization.dedicatedPlaywright -eq 'NOT_MATERIALIZED' -and $e010.surfaceMaterialization.dedicatedAccessibility -eq 'NOT_MATERIALIZED' -and $e010.dedicatedExecution.playwright -eq $false -and $e010.dedicatedExecution.accessibility -eq $false -and $e010.classification -eq 'FIRST-CLASS VERIFY SURFACE PARTIAL' -and @($e010.actualFallback).Count -gt 0) 'E-010 surface materialization distinction is incomplete.'
Assert-True ($e010.forbidden -contains 'claim-dedicated-execution') 'E-010 false dedicated-execution claim is not forbidden.'
$fidelity = $matrix.scenarios | Where-Object id -eq 19
Assert-True ($fidelity.expectedMode -eq 'FIDELITY_FIRST' -and $fidelity.referenceAuthority -eq 'primary' -and $fidelity.forbidden -contains 'creative-deviation-that-alters-intent') 'FIDELITY_FIRST scenario is incomplete.'
$blockedScenario = $matrix.scenarios | Where-Object id -eq 20
Assert-True ($blockedScenario.expectedRouting -eq 'PASS' -and $blockedScenario.expectedOperationSurfaceState -eq 'CAPABILITY_SURFACE_BLOCKED' -and $blockedScenario.requiredOperationPresent -eq $false) '3D capability-surface blocker scenario is incomplete.'
$partialScenario = $matrix.scenarios | Where-Object id -eq 24
Assert-True ($partialScenario.expectedVerifySurfaceState -eq 'FIRST-CLASS VERIFY SURFACE PARTIAL' -and [string]::IsNullOrWhiteSpace([string]$partialScenario.fallback) -eq $false) 'Partial verification fallback scenario is incomplete.'
$impeccableScenario = $matrix.scenarios | Where-Object id -eq 25
Assert-True ($impeccableScenario.evidenceId -eq 'E-011' -and $impeccableScenario.historicalExecution -eq $true -and $impeccableScenario.routing -eq 'PASS' -and $impeccableScenario.childProcessExitCode -eq 1 -and $impeccableScenario.dedicatedExecutionSucceeded -eq $false -and $impeccableScenario.finalWorkflowResult -eq 'PASS' -and $impeccableScenario.classification -eq 'EXECUTION SURFACE ROBUSTNESS GAP' -and @($impeccableScenario.fallback).Count -ge 4) 'E-011 execution-gap scenario is incomplete.'
Assert-True ($impeccableScenario.forbidden -contains 'fallback-pass-as-dedicated-success') 'E-011 false dedicated-success claim is not forbidden.'
$exclusionScenario = $matrix.scenarios | Where-Object id -eq 27
Assert-True ($exclusionScenario.explicitExclusion -contains '21st' -and $exclusionScenario.forbidden -contains '21st') 'Explicit exclusion scenario is incomplete.'
$effectScenario = $matrix.scenarios | Where-Object id -eq 28
Assert-True ($effectScenario.selectionAuthorizationSeparated -eq $true -and $effectScenario.effectBoundary -eq 'existing-common-dispatcher') 'Effect-boundary scenario is incomplete.'

$expectedSecurityIds = @('project-prompt-injection','mcp-generation-injection','project-command-injection','cost-gate-social-engineering','unknown-21st-tool','unknown-capability','figma-transport-collision','browser-install-injection','storybook-publication-request')
Assert-SetEqual @($matrix.securityScenarios.id) $expectedSecurityIds 'Security scenario IDs'
Assert-True ($policy.unknownCapabilityPolicy -eq 'fail-closed' -and $policy.unknownToolPolicy -eq 'fail-closed' -and $policy.unknownEffectPolicy -eq 'fail-closed') 'Global unknown-state policy regressed.'

Write-Output 'PASS: routing policy V3 separates availability, routing, operation surface and effect requirement.'
Write-Output 'PASS: QUALITY_FIRST/FIDELITY_FIRST, material selection attributes and canonical surface taxonomy are covered.'
Write-Output 'PASS: V3 scenarios cover complementary routing, anti-overrouting, fallbacks, effect boundary and preserved security cases.'
Write-Output 'PASS: canonical .agents policy/scenarios and distributed plugin copies are byte-equivalent.'
