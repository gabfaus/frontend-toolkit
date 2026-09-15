Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/external-prerequisite.ps1')
Assert-FtkExternalPrerequisite
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
. (Join-Path $securityRoot 'impeccable-runner.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Label)
    try { & $Action; throw "$Label did not fail closed." }
    catch {
        if ($_.Exception.Message -eq "$Label did not fail closed.") { throw }
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Label returned the wrong error: $($_.Exception.Message)" }
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-impeccable-effects-' + [guid]::NewGuid().ToString('N'))
$secretName = 'FTK_SR3B_SYNTHETIC_SECRET'
$secretValue = 'synthetic-parent-secret-must-not-cross'
$originalSecret = [Environment]::GetEnvironmentVariable($secretName, 'Process')
try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $project = Join-Path $fixture 'project'
    [IO.Directory]::CreateDirectory($project) | Out-Null

    $policyPath = Join-Path $securityRoot 'impeccable-operation-policy.json'
    $policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
    Assert-True ($policy.unknownOperationPolicy -ceq 'deny' -and $policy.unknownEffectPolicy -ceq 'deny') 'Policy is not fail closed.'
    $expectedEffects = @('LOCAL_READ_ONLY','LOCAL_PROJECT_WRITE','LOOPBACK_EPHEMERAL','NETWORK_PASSIVE','TELEMETRY','PAID_GENERATION','EXTERNAL_MUTATION','PROJECT_CODE_EXECUTION','UNKNOWN')
    Assert-True ((@($policy.effectClasses) -join '|') -ceq ($expectedEffects -join '|')) 'Effect model is incomplete or reordered.'
    $operationIds = @($policy.operations.id)
    Assert-True ($operationIds.Count -eq @($operationIds | Sort-Object -Unique).Count) 'Operation IDs are not unique.'
    foreach ($operation in @($policy.operations)) {
        foreach ($field in @('id','scriptHandler','effects','allowedInputs','projectPathInputs','outputBoundaries','endpointRequirements','childEnvironmentAllowlist','persistentEffect','projectCodeExecution','capabilityDescription','defaultState','authorizationRequirement')) {
            Assert-True ($null -ne $operation.PSObject.Properties[$field]) "Operation $($operation.id) lacks $field."
        }
        Assert-True (-not ([string]$operation.id).Contains('*')) "Operation $($operation.id) contains a wildcard."
        Assert-True (@($operation.effects) -notcontains 'UNKNOWN') "Operation $($operation.id) retained UNKNOWN."
    }

    $upstreamRoot = Resolve-ImpeccablePinnedUpstreamRoot
    $upstreamSkillRoot = Join-Path $upstreamRoot '.agent/skills/impeccable'
    if (-not (Test-Path -LiteralPath $upstreamSkillRoot -PathType Container)) { $upstreamSkillRoot = Join-Path $upstreamRoot 'plugin/skills/impeccable' }
    $actualEntrypoints = @(Get-ChildItem -LiteralPath (Join-Path $upstreamSkillRoot 'scripts') -File |
        Where-Object Extension -in @('.mjs','.js') | ForEach-Object { 'scripts/' + $_.Name } | Sort-Object)
    $inventoryPaths = @($policy.entrypointInventory.path | Where-Object { $_ -like 'scripts/*' } | Sort-Object)
    $unregistered = @($actualEntrypoints | Where-Object { $_ -notin $inventoryPaths })
    Assert-True ($unregistered.Count -eq 0) ('Upstream entrypoints are unregistered: ' + ($unregistered -join ', '))
    foreach ($entry in @($policy.entrypointInventory)) {
        Assert-True (-not ([string]$entry.path).Contains('*')) "Entrypoint inventory contains a wildcard: $($entry.path)"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.unmappedBehavior)) "Entrypoint $($entry.path) lacks explicit unmapped behavior."
        foreach ($id in @($entry.operations)) { Assert-True ($operationIds -ccontains $id) "Entrypoint $($entry.path) maps unknown operation $id." }
    }

    Assert-Throws { Get-ImpeccableRegisteredOperation 'impeccable.not-registered' | Out-Null } 'UNKNOWN Impeccable operation' 'unknown operation'
    $runnerSource = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'impeccable-runner.ps1')
    foreach ($forbidden in @('Invoke-Expression','--authorized','approved=true')) {
        Assert-True ($runnerSource -notmatch [regex]::Escape($forbidden)) "Runner exposes forbidden surface $forbidden."
    }
    Assert-True ($runnerSource -match 'ProcessStartInfo') 'Runner does not use ProcessStartInfo.'
    Assert-True ($runnerSource -notmatch 'SetEnvironmentVariable') 'Runner mutates parent environment.'

    $contextPlan = Invoke-ImpeccableOperation -Operation 'impeccable.context.local' -ProjectRoot $project -PlanOnly
    Assert-True (-not $contextPlan.networkAttempted -and -not $contextPlan.childStarted) 'Local context attempted update/network execution.'
    Assert-True (@($contextPlan.childEnvironmentNames) -ccontains 'IMPECCABLE_NO_UPDATE_CHECK') 'Local context does not force update checks off.'
    Assert-True (@($contextPlan.childEnvironmentNames) -ccontains 'IMPECCABLE_NO_TELEMETRY') 'Local context does not default telemetry off.'

    $fallback = Invoke-ImpeccableOperation -Operation 'impeccable.concept.local-fallback' -Scope surface -Key seed-1 -Mode balanced
    Assert-True ($fallback.source -ceq 'degraded-local' -and -not $fallback.networkAttempted -and -not $fallback.telemetrySent) 'Local concept fallback was not preserved offline.'

    $updatePlan = Invoke-ImpeccableOperation -Operation 'impeccable.update-check' -PlanOnly
    Assert-True ($updatePlan.effects -ccontains 'NETWORK_PASSIVE') 'Update check lost NETWORK_PASSIVE.'
    Assert-True (-not $updatePlan.persistentEffect -and $updatePlan.endpointRequirements -match '/api/version') 'Update check gained cache/self-update behavior.'
    Assert-Throws { Invoke-ImpeccableOperation -Operation 'impeccable.update-check' | Out-Null } 'host NETWORK_PASSIVE grant' 'update without host authorization'
    Assert-Throws { Invoke-ImpeccableOperation -Operation 'impeccable.self-update' | Out-Null } 'not a runtime capability' 'self update'

    $remotePlan = Invoke-ImpeccableOperation -Operation 'impeccable.concept.remote-roll' -PlanOnly
    $telemetryPlan = Invoke-ImpeccableOperation -Operation 'impeccable.telemetry.choice' -PlanOnly
    Assert-True ($remotePlan.effects -cnotcontains 'TELEMETRY') 'Remote concept permission implies telemetry.'
    Assert-True ($telemetryPlan.effects -ccontains 'TELEMETRY' -and $telemetryPlan.effects -ccontains 'NETWORK_PASSIVE') 'Telemetry is not a separate network operation.'
    Assert-Throws { Invoke-ImpeccableOperation -Operation 'impeccable.concept.remote-roll' | Out-Null } 'host NETWORK_PASSIVE grant' 'concept roll without authorization'

    $loopbackPlan = Invoke-ImpeccableOperation -Operation 'impeccable.live.loopback' -ProjectRoot $project -PlanOnly
    Assert-True ($loopbackPlan.endpointRequirements -match '127\.0\.0\.1' -and $loopbackPlan.effects -ccontains 'LOOPBACK_EPHEMERAL') 'Live loopback contract drifted.'
    Assert-True ($loopbackPlan.effects -ccontains 'PROJECT_CODE_EXECUTION' -and $loopbackPlan.effects -cnotcontains 'NETWORK_PASSIVE') 'PROJECT_CODE_EXECUTION implied external network.'
    $externalLiveInput = Invoke-ImpeccableOperation -Operation 'impeccable.live.loopback' -ProjectRoot $project -TargetUrl 'http://0.0.0.0:8400' -PlanOnly
    Assert-True ($externalLiveInput.dedicatedExecution.failureType -ceq 'INVALID_INPUT' -and -not $externalLiveInput.attempted -and
        -not $externalLiveInput.childStarted -and $externalLiveInput.dedicatedExecution.dedicatedExecutionResult -ceq 'NOT_ATTEMPTED') 'External live bind did not return a typed INVALID_INPUT envelope.'
    $externalLive = Invoke-ImpeccableOperation -Operation 'impeccable.live.external' -PlanOnly
    Assert-True ($externalLive.defaultState -ceq 'explicitly-denied') 'External live is not explicitly denied.'

    $hookStatus = Invoke-ImpeccableOperation -Operation 'impeccable.hooks.status' -ProjectRoot $project -PlanOnly
    $hookEnable = Invoke-ImpeccableOperation -Operation 'impeccable.hooks.enable' -ProjectRoot $project -PlanOnly
    Assert-True (-not $hookStatus.persistentEffect -and $hookStatus.effects -ccontains 'LOCAL_READ_ONLY') 'Hook status is not read-only.'
    Assert-True ($hookEnable.persistentEffect -and $hookEnable.effects -ccontains 'LOCAL_PROJECT_WRITE' -and -not $hookEnable.childStarted) 'Hook mutation was automatic or misclassified.'
    Assert-Throws { Invoke-ImpeccableOperation -Operation 'impeccable.hooks.enable' -ProjectRoot $project | Out-Null } 'persistent project-write grant' 'automatic hook enable'

    $node = Resolve-ImpeccableNodeRuntime
    $networkClient = (Resolve-Path (Join-Path $securityRoot 'impeccable-network-client.mjs')).Path
    $networkClientUrl = [Uri]::new($networkClient).AbsoluteUri
    $networkProbe = @'
const client = await import(process.argv[2]);
let calls = [];
globalThis.fetch = async () => { throw new Error('REAL_NETWORK_FORBIDDEN'); };
const mock = async (url, options) => {
  calls.push({ url, method: options.method, body: options.body || null });
  if (url.endsWith('/api/version')) return new Response(JSON.stringify({ latestVersion: '4.1.3' }), { status: 200 });
  if (url.includes('/api/roll?')) return new Response(JSON.stringify({ challengers: [{ id: 'safe-card' }] }), { status: 200 });
  if (url.endsWith('/api/chosen')) return new Response('{}', { status: 200 });
  if (url.endsWith('/worlds/cards/safe-card.webp')) return new Response(new Uint8Array([1,2,3]), { status: 200 });
  throw new Error('UNEXPECTED_MOCK_ENDPOINT');
};
const expectBlocked = (fn, pattern) => { try { fn(); throw new Error('DID_NOT_BLOCK'); } catch (error) { if (!pattern.test(error.message)) throw error; } };
expectBlocked(() => client.buildRequest('impeccable.update-check', { url: 'https://example.invalid' }), /unregistered input/);
expectBlocked(() => client.buildRequest('impeccable.unknown', {}), /unknown operation/);
expectBlocked(() => client.buildRequest('impeccable.concept.card-fetch', { cardAsset: '../escape.webp' }), /invalid cardAsset/);
const update = await client.executeNetworkOperation('impeccable.update-check', {}, { transport: mock });
const roll = await client.executeNetworkOperation('impeccable.concept.remote-roll', { scope: 'surface', key: 'seed-1' }, { transport: mock });
const card = await client.executeNetworkOperation('impeccable.concept.card-fetch', { cardAsset: 'safe-card.webp' }, { transport: mock });
const telemetry = await client.executeNetworkOperation('impeccable.telemetry.choice', { chosenId: 'safe-card', kind: 'challenger' }, { transport: mock });
let paidBlocked = false;
try { await client.executeNetworkOperation('impeccable.paid-generation.upstream', { variant: 'generations' }, { transport: mock }); } catch (error) { paidBlocked = /dedicated host-authorized/.test(error.message); }
console.log(JSON.stringify({ calls, update, roll, cardBytes: card.byteLength, telemetry, paidBlocked }));
'@
    $networkProbePath = Join-Path $fixture 'network-probe.mjs'
    [IO.File]::WriteAllText($networkProbePath, $networkProbe, [Text.UTF8Encoding]::new($false))
    $networkResult = Invoke-ImpeccableChildProcess -Executable $node `
        -ArgumentList @($networkProbePath,$networkClientUrl) `
        -WorkingDirectory $project -Environment (New-ImpeccableChildEnvironment)
    $networkJson = ($networkResult.stdout -join '') | ConvertFrom-Json
    Assert-True (@($networkJson.calls).Count -eq 4) 'Hermetic network client made an unexpected number of mock calls.'
    Assert-True ($networkJson.calls[0].url -ceq 'https://impeccable.style/api/version') 'Update check used an unknown endpoint.'
    Assert-True ($networkJson.update.latestVersion -ceq '4.1.3' -and -not $networkJson.update.updatePerformed -and -not $networkJson.update.cacheWritten) 'Update result is not typed/no-update/no-cache.'
    Assert-True ($networkJson.roll.source -ceq 'remote' -and -not $networkJson.roll.telemetrySent) 'Remote concept roll coupled telemetry.'
    Assert-True ($networkJson.cardBytes -eq 3 -and $networkJson.telemetry.accepted -and $networkJson.paidBlocked) 'Card, telemetry, or paid boundary failed.'

    $conceptScript = Resolve-ImpeccablePinnedScript 'scripts/concept-seed.mjs'
    $conceptUrl = [Uri]::new($conceptScript).AbsoluteUri
    $telemetryProbe = @'
let calls = 0;
globalThis.fetch = async () => { calls += 1; return { ok: true }; };
const module = await import(process.argv[2]);
const sent = await module.pingChosen({ chosenId: 'safe-card', kind: 'challenger' });
console.log(JSON.stringify({ calls, sent }));
'@
    $telemetryProbePath = Join-Path $fixture 'telemetry-probe.mjs'
    [IO.File]::WriteAllText($telemetryProbePath, $telemetryProbe, [Text.UTF8Encoding]::new($false))
    foreach ($environment in @(
        [ordered]@{ SystemRoot = $env:SystemRoot; TEMP = $env:TEMP; TMP = $env:TMP; IMPECCABLE_NO_TELEMETRY = '1' },
        [ordered]@{ SystemRoot = $env:SystemRoot; TEMP = $env:TEMP; TMP = $env:TMP; DO_NOT_TRACK = '1' }
    )) {
        $probe = Invoke-ImpeccableChildProcess -Executable $node `
            -ArgumentList @($telemetryProbePath,$conceptUrl) `
            -WorkingDirectory $project -Environment $environment
        $probeJson = ($probe.stdout -join '') | ConvertFrom-Json
        Assert-True ($probeJson.calls -eq 0 -and -not $probeJson.sent) 'An upstream telemetry flag failed to suppress pingChosen.'
    }

    [Environment]::SetEnvironmentVariable($secretName, $secretValue, 'Process')
    $parentBefore = [Environment]::GetEnvironmentVariable($secretName, 'Process')
    $fake = Invoke-ImpeccableOperation -Operation 'impeccable.paid-generation.fake' -ProjectRoot $project `
        -Prompt 'Synthetic routing proof only' -OutputPath 'routing-proof.png' -Size '1024x1024'
    $parentAfter = [Environment]::GetEnvironmentVariable($secretName, 'Process')
    Assert-True ($parentBefore -ceq $parentAfter) 'Fake generation changed the parent environment.'
    Assert-True ($fake.fake -and -not $fake.paid -and -not $fake.networkAttempted -and $fake.childStarted -and $fake.dedicatedExecution.succeeded) 'Fake generation did not prove the zero-cost route.'
    Assert-True (Test-Path -LiteralPath $fake.outputPath -PathType Leaf) 'Fake generation did not create its contained output.'
    Assert-True (@($fake.child.environmentNames) -cnotcontains $secretName -and @($fake.child.environmentNames) -cnotcontains 'OPENAI_API_KEY') 'Parent or paid secret crossed into fake child.'
    Assert-True (-not (($fake | ConvertTo-Json -Depth 10).Contains($secretValue))) 'Runner diagnostics leaked the synthetic secret.'
    $escapingOutput = Invoke-ImpeccableOperation -Operation 'impeccable.paid-generation.fake' -ProjectRoot $project -Prompt ok -OutputPath '../escape.png'
    Assert-True ($escapingOutput.dedicatedExecution.failureType -ceq 'INVALID_INPUT' -and -not $escapingOutput.attempted -and
        -not $escapingOutput.childStarted -and $escapingOutput.dedicatedExecution.dedicatedExecutionResult -ceq 'NOT_ATTEMPTED') 'Escaping output did not return a typed INVALID_INPUT envelope.'

    $beforePaid = @(Get-ChildItem -Recurse -File $project | Select-Object -ExpandProperty FullName)
    Assert-Throws { Invoke-ImpeccableOperation -Operation 'impeccable.paid-generation.upstream' -ProjectRoot $project | Out-Null } 'host spend grant' 'paid generation without authorization'
    $afterPaid = @(Get-ChildItem -Recurse -File $project | Select-Object -ExpandProperty FullName)
    Assert-True (($beforePaid -join '|') -ceq ($afterPaid -join '|')) 'Blocked paid generation created output.'

    Assert-True ($runnerSource -notmatch '(?im)^\s*(?:npm|npx)\s') 'Runner installs or invokes dependencies.'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'impeccable-network-client.mjs')) -notmatch 'child_process') 'Network client starts subprocesses.'
} finally {
    [Environment]::SetEnvironmentVariable($secretName, $originalSecret, 'Process')
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete($fixture, $true) }
}

Write-Output 'PASS 1-6: entrypoints/operations are explicit, UNKNOWN denies, argv is structural, child env is minimal, parent secrets stay isolated, and diagnostics redact by omission.'
Write-Output 'PASS 7-12: telemetry defaults off, both upstream flags suppress pingChosen, opt-in is separate, local context cannot update, version check is endpoint-bound/no-cache, and self-update is denied.'
Write-Output 'PASS 13-19: concept network denial preserves local fallback, remote roll and telemetry are separate, paid denial has zero effects, fake routing costs zero, and arbitrary URL/endpoint/output escape are blocked.'
Write-Output 'PASS 20-23: external live bind is blocked, loopback is explicit, hook mutations are never automatic, and PROJECT_CODE_EXECUTION does not imply NETWORK.'
Write-Output 'PASS 24-26: all HTTP is mocked, no paid operation ran, and no dependency install path executed.'
Write-Output 'DYNAMIC TEST EXECUTED  HERMETIC MOCKS ONLY  NO EXTERNAL NETWORK OR PAID OPERATION'
