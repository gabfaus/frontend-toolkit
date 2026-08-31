Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
$policyPath = Join-Path $securityRoot 'effect-policy.json'
$launcherPath = Join-Path $securityRoot 'invoke-capability.ps1'
$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json

$expectedEffects = @('LOCAL_READ_ONLY','LOCAL_PROJECT_WRITE','LOOPBACK_EPHEMERAL','NETWORK_PASSIVE','TELEMETRY','PAID_GENERATION','EXTERNAL_MUTATION','UNKNOWN')
if ((@($policy.effectClasses) -join ',') -cne ($expectedEffects -join ',')) { throw 'Effect classes drifted.' }
if ($policy.unknownEffectPolicy -ne 'deny') { throw 'UNKNOWN is not fail-closed.' }

$command = Get-Command $launcherPath
$parameters = @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters })
if (($parameters -join ',') -ne 'Operation') { throw "Launcher exposes unexpected parameters: $($parameters -join ',')" }
$launcherText = Get-Content -Raw -LiteralPath $launcherPath
foreach ($forbidden in @('Invoke-Expression','Start-Process','ScriptBlock','& $definition','cmd.exe','bash -c','pwsh -Command')) {
    if ($launcherText.Contains($forbidden)) { throw "Launcher contains an arbitrary execution surface: $forbidden" }
}

$summary = & $launcherPath -Operation 'impeccable.capability-summary' | ConvertFrom-Json
if ($summary.effect -ne 'LOCAL_READ_ONLY' -or $summary.upstreamExecuted) { throw 'Safe capability summary behavior drifted.' }
$blocked = $false
try { & $launcherPath -Operation 'not.registered' | Out-Null } catch { $blocked = $_.Exception.Message -match 'UNKNOWN operation' }
if (-not $blocked) { throw 'Unknown operation was not denied.' }
$blocked = $false
try { & $launcherPath -Operation 'impeccable.paid-generation' | Out-Null } catch { $blocked = $_.Exception.Message -match 'not enabled' }
if (-not $blocked) { throw 'Deferred paid operation was not denied.' }
$blocked = $false
try { & $launcherPath -Operation 'img2threejs.network-helper' | Out-Null } catch { $blocked = $_.Exception.Message -match 'UNKNOWN effect' }
if (-not $blocked) { throw 'Registered UNKNOWN effect was not denied.' }

foreach ($skillName in @('impeccable','img2threejs')) {
    $capabilities = @($policy.skills.$skillName.capabilities)
    if (-not $capabilities.Count) { throw "$skillName capabilities are missing." }
}

Write-Output 'PASS: capability/effect manifest has all eight classes and UNKNOWN fail-closed.'
Write-Output 'PASS: common launcher accepts only registered operation IDs and has no arbitrary-script entrypoint.'
Write-Output 'PASS: legitimate capability summaries remain available while deferred effects remain closed.'
