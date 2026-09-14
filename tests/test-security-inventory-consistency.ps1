Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
$expected = @(Get-FrontendToolkitSecurityModuleAllowlist | Sort-Object)
$sourceSecurity = @(Get-FrontendToolkitSourceFileAllowlist | Where-Object { $_ -like 'security/*' } | ForEach-Object { $_.Substring('security/'.Length) } | Sort-Object)
Assert-True (($sourceSecurity -join "`n") -ceq ($expected -join "`n")) 'Release source allowlist and security inventory disagree.'

$pluginRoot = Join-Path $repoRoot 'plugin/frontend-toolkit'
$workingTree = @(Get-ChildItem -LiteralPath (Join-Path $pluginRoot 'security') -File -Force | ForEach-Object Name | Sort-Object)
Assert-ExactStringSet -Name 'working-tree security inventory' -Actual $workingTree -Expected $expected

$reconcilerText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/reconcile-committed-head-locks.ps1')
Assert-True ($reconcilerText -match '\$requiredSecurity\s*=\s*@\(Get-FrontendToolkitSecurityModuleAllowlist\)') 'Reconciler is not bound to the canonical closed inventory.'
$packagingText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests/test-plugin-packaging.ps1')
Assert-True ($packagingText -match 'Get-FrontendToolkitSecurityModuleAllowlist') 'Plugin packaging test is not bound to the canonical closed inventory.'

$safeRepo = $repoRoot.Replace('\', '/')
$headPaths = @(& git -c "safe.directory=$safeRepo" -C $repoRoot ls-tree -r --name-only HEAD -- plugin/frontend-toolkit/security)
if ($LASTEXITCODE -ne 0) { throw 'Committed security tree inventory failed.' }
$headSecurity = @($headPaths | ForEach-Object { $_.Substring('plugin/frontend-toolkit/security/'.Length) } | Sort-Object)
Assert-ExactStringSet -Name 'committed-head security inventory' -Actual $headSecurity -Expected $expected
Assert-True ($expected.Count -eq 21) 'Converged security inventory is not exactly 21 reviewed modules.'
Write-Output 'PASS: reconciler, release-safety, plugin packaging and committed HEAD agree on the exact 21-module convergence security inventory.'
