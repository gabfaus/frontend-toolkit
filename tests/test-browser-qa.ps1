Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$browserRoot = Join-Path $repoRoot 'integrations/browser-qa'
$launcher = Join-Path $browserRoot 'playwright-launcher.ps1'
$verify = Join-Path $browserRoot 'accessibility-verify.mjs'
$axe = Join-Path $browserRoot 'axe-conditional.mjs'
$chrome = Join-Path $browserRoot 'chrome-devtools-boundary.mjs'
$policy = Get-Content -Raw -LiteralPath (Join-Path $browserRoot 'playwright-runtime-policy.json') | ConvertFrom-Json
$chromePolicy = Get-Content -Raw -LiteralPath (Join-Path $browserRoot 'chrome-devtools-policy.json') | ConvertFrom-Json
$lock = Get-Content -Raw -LiteralPath (Join-Path $browserRoot '..\browser-qa.lock.json') | ConvertFrom-Json

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Context)
    $output = ''
    $exitCode = 0
    try {
        $output = (& $ScriptBlock 2>&1 | Out-String)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } catch {
        $output += ($_ | Out-String)
        $exitCode = 1
    }
    Assert-True ($exitCode -ne 0 -and $output -match $Pattern) "Expected failure did not occur: $Context`n$output"
}

function Invoke-NodeJson {
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & $script:node $Script @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Node helper failed: $Script`n$output" }
    return ($output | ConvertFrom-Json)
}

$toolchain = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json
$pinnedNode = [Environment]::ExpandEnvironmentVariables(($toolchain.runtimes | Where-Object id -eq 'node').portableResolution)
$nodeCommand = if (Test-Path -LiteralPath $pinnedNode -PathType Leaf) { $pinnedNode } else { (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if ([string]::IsNullOrWhiteSpace($nodeCommand) -or -not (Test-Path -LiteralPath $nodeCommand -PathType Leaf)) { throw 'The pinned Node.js runtime is required for the hermetic Browser QA adapter tests.' }
$script:node = $nodeCommand

$sourceFiles = @(Get-ChildItem -LiteralPath $browserRoot -File -Force)
foreach ($sourceFile in $sourceFiles) {
    $text = Get-Content -Raw -LiteralPath $sourceFile.FullName
    Assert-True ($text -notmatch '@latest') "Floating latest tag found in $($sourceFile.Name)."
}

$cli = $lock.playwright.cli
Assert-True ($cli.id -eq '@playwright/cli' -and $cli.version -eq '0.1.19') 'Playwright CLI pin drifted.'
Assert-True ($cli.license -eq 'Apache-2.0' -and $cli.commitSha -eq '397ee39c83a651e1314cfb010b94e8a3aac11261') 'Playwright CLI license or official tag provenance drifted.'
Assert-True ($cli.integrity -eq 'sha512-eGXIsYa5D+dC6wHGf+9uEislhPGip1djK+yiNAD7BVsXN3WzzR1J4ClFAhYhyu7wSEFqhcPrqXAYeBJF1dKJ7A==') 'Playwright CLI registry integrity drifted.'
Assert-True ($cli.officialSkillSha256 -eq '1a609c93bff3eea9ab99fed93c0334c851fdc39fb6ac5335551bfb87c171d57c') 'Official Playwright Skill hash drifted.'
Assert-True ($null -eq $cli.registryGitHead -and $null -eq $cli.registryAttestation -and $cli.provenanceStatus -eq 'validated-with-public-metadata-caveat') 'Known Playwright CLI provenance caveat was hidden.'
Assert-True ($cli.upstreamConfirmed -and $cli.tarballIntegrityConfirmed -and $cli.sourceTagConfirmed -and $cli.trustedPublisherProvenance -eq 'ABSENT' -and $cli.sigstoreSlsaProvenance -eq 'ABSENT' -and $cli.upstreamIssue.id -eq 'microsoft/playwright#42500' -and $cli.upstreamIssue.statusAtValidation -eq 'OPEN' -and $cli.upstreamIssue.tamperingEvidence -eq 'none observed or reported' -and $cli.releaseDecisionRequired) 'Playwright CLI supply-chain freeze is incomplete.'
Assert-True ($cli.dependencies.playwright -eq '1.63.0-alpha-2026-08-31' -and $cli.dependencies.'playwright-core' -eq '1.63.0-alpha-2026-08-31') 'Effective CLI dependency graph was silently normalized.'
Assert-True ($lock.playwright.stableLibraryTarget.version -eq '1.63.0' -and $lock.playwright.stableLibraryTarget.commitSha -eq '1b025d7e20a026371cd5f98ba0cdce48892737c8') 'Stable Playwright target drifted.'
Assert-True ($lock.playwright.testMechanism.version -eq '1.63.0' -and $lock.playwright.testMechanism.noAutomaticInstallation) 'Playwright Test preservation contract drifted.'
Assert-True ($lock.axe.version -eq '4.13.0' -and $lock.axe.classification -eq 'CONDITIONAL' -and $lock.axe.license -eq 'MPL-2.0') 'axe conditional target drifted.'
Assert-True ($lock.chromeDevtools.version -eq '1.8.0' -and $lock.chromeDevtools.classification -eq 'OPTIONAL' -and $lock.chromeDevtools.noNormalMcpRegistration) 'Chrome DevTools optional target drifted.'

$mcpText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/.mcp.json')
Assert-True ($mcpText -notmatch '(?i)playwright|chrome-devtools') 'A Playwright or Chrome DevTools MCP appeared in normal distribution configuration.'
Assert-True ($policy.defaults.headless -and $policy.defaults.isolated -and $policy.defaults.ephemeralBrowser) 'Playwright defaults are not headless/isolated/ephemeral.'
Assert-True (-not $policy.defaults.arbitraryJavaScript -and -not $policy.defaults.automaticBrowserDownload -and -not $policy.defaults.automaticPackageInstallation) 'Playwright dangerous defaults are enabled.'
Assert-True (@($policy.blockedActions) -contains 'eval' -and @($policy.blockedActions) -contains 'run-code' -and @($policy.blockedActions) -contains 'attach') 'Arbitrary JavaScript or browser attachment is not blocked.'
Assert-True (@($policy.environmentAllowlist) -notcontains 'PATH' -and @($policy.environmentAllowlist) -notcontains 'HOME' -and @($policy.environmentAllowlist) -notcontains 'USERPROFILE') 'Playwright child environment inherited a broad path/profile variable.'
Assert-True (@($policy.environmentAllowlist) -contains 'NO_UPDATE_NOTIFIER' -and $policy.environmentValues.NO_UPDATE_NOTIFIER -eq '1' -and $policy.defaults.externalTraffic -eq $false) 'Playwright update checks were not disabled in the child policy.'
Assert-True (-not $chromePolicy.defaults.javascriptEvaluation -and -not $chromePolicy.defaults.usageStatistics -and -not $chromePolicy.defaults.performanceCrux -and -not $chromePolicy.defaults.existingBrowserAttach) 'Chrome DevTools safety defaults drifted.'
Assert-True ($chromePolicy.registration -eq 'absent-from-normal-distribution' -and @($chromePolicy.allowedTools) -notcontains 'evaluate_script') 'Chrome DevTools JavaScript/MCP boundary drifted.'

$command = Get-Command $launcher
foreach ($forbiddenParameter in @('Eval','RunCode','Persistent','Profile','Attach','StorageState','Arguments')) {
    Assert-True (-not $command.Parameters.ContainsKey($forbiddenParameter)) "Launcher exposes forbidden parameter $forbiddenParameter."
}
$plan = & $launcher -Action open -Url 'http://127.0.0.1:4173/synthetic' -SessionId 'synthetic-open' -PlanOnly | ConvertFrom-Json
Assert-True (-not $plan.executed -and $plan.browserDownloads -eq 0 -and -not $plan.packageInstallation) 'Playwright plan executed or enabled installation.'
Assert-True ($plan.workingDirectory.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) 'Playwright output escaped the OS temp directory.'
Assert-True (-not $plan.arbitraryJavaScript -and -not $plan.persistentState) 'Playwright plan enabled an unsafe state or JavaScript route.'
Invoke-ExpectedFailure { & $launcher -Action open -Url 'https://example.com' -PlanOnly } 'loopback' 'external Playwright URL'
Invoke-ExpectedFailure { & $launcher -Action open -Url 'http://user:synthetic@127.0.0.1:4173' -PlanOnly } 'Credentials' 'URL credentials'
Invoke-ExpectedFailure { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Action eval -PlanOnly } '(?s).*' 'eval unexpectedly entered the standard launcher path'
$missingCli = Join-Path (Join-Path ([IO.Path]::GetTempPath()) ('ftk-09h-missing-' + [guid]::NewGuid().ToString('N'))) 'playwright-cli.cmd'
Invoke-ExpectedFailure { & $launcher -Action open -Url 'http://127.0.0.1:4173' -SessionId 'missing-cli' -CliPath $missingCli } 'unavailable' 'missing CLI fail-closed'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-09h-browser-qa-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $observations = Join-Path $fixture 'observations'
    New-Item -ItemType Directory -Path $observations | Out-Null
    $mockRoot = Join-Path $fixture 'mock-cli'
    New-Item -ItemType Directory -Path $mockRoot | Out-Null
    $mockCli = Join-Path $mockRoot 'playwright-cli.cmd'
    $mockText = @('@echo off','echo MOCK_CLI','echo TEMP=%TEMP%','echo PATH=%PATH%','echo USERPROFILE=%USERPROFILE%','echo ARGS=%*','exit /b 0') -join [Environment]::NewLine
    [IO.File]::WriteAllText($mockCli, $mockText, (New-Object Text.UTF8Encoding($false)))
    $mockPlan = & $launcher -Action snapshot -SessionId ('mock' + (Get-Random)) -CliPath $mockCli -OutputName 'snapshot.yml' | ConvertFrom-Json
    Assert-True ($mockPlan.executed -and $mockPlan.stdout -contains 'MOCK_CLI') 'ProcessStartInfo did not execute the synthetic CLI mock.'
    Assert-True (@($mockPlan.stdout) -contains 'PATH=' -and @($mockPlan.stdout) -contains 'USERPROFILE=') 'Playwright child did not clear PATH/profile state.'
    Assert-True (@(@($mockPlan.stdout) | Where-Object { $_ -like 'TEMP=*' -and $_ -notlike 'TEMP=%TEMP%' }).Count -gt 0) 'Playwright child did not receive a dedicated TEMP directory.'
    $checkIds = @('wcag22','semanticHtml','landmarksHeadings','keyboard','focus','formsLabelsErrors','aria','contrastNonText','zoomReflow','prefersReducedMotion','motionAccessibility','screenReaderReasoning')
    $goodChecks = [ordered]@{}
    foreach ($checkId in $checkIds) { $goodChecks[$checkId] = 'PASS' }
    $goodPath = Join-Path $observations 'good.json'
    $good = [ordered]@{ checks = $goodChecks; manualReview = [ordered]@{ reviewed = $true }; axe = [ordered]@{ used = $false } } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($goodPath, $good, (New-Object Text.UTF8Encoding($false)))
    $goodBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $goodPath).Hash
    $goodReport = Invoke-NodeJson $verify @('--root', $fixture, '--input', 'observations/good.json')
    Assert-True ($goodReport.status -eq 'PASS' -and $goodReport.readOnly -and -not $goodReport.codeModified -and $goodReport.browserStarted -eq $false) 'Accessibility VERIFY did not produce a read-only PASS.'
    Assert-True ($goodReport.manualReviewRequired -and $goodReport.manualReviewCompleted) 'Accessibility manual review state was not represented.'
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $goodPath).Hash -eq $goodBefore) 'Accessibility VERIFY modified its input.'

    $failChecks = [ordered]@{}
    foreach ($checkId in $checkIds) { $failChecks[$checkId] = if ($checkId -eq 'keyboard') { 'FAIL' } else { 'PASS' } }
    $failPath = Join-Path $observations 'fail.json'
    [IO.File]::WriteAllText($failPath, ([ordered]@{ checks = $failChecks; manualReview = [ordered]@{ reviewed = $true } } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $failReport = Invoke-NodeJson $verify @('--root', $fixture, '--input', 'observations/fail.json')
    Assert-True ($failReport.status -eq 'FAIL') 'Accessibility VERIFY did not preserve a deterministic FAIL.'

    $incompletePath = Join-Path $observations 'incomplete.json'
    [IO.File]::WriteAllText($incompletePath, ([ordered]@{ checks = [ordered]@{ semanticHtml = 'PASS' } } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $incompleteReport = Invoke-NodeJson $verify @('--root', $fixture, '--input', 'observations/incomplete.json')
    Assert-True ($incompleteReport.status -eq 'INCOMPLETE') 'Missing accessibility evidence did not produce INCOMPLETE.'

    $unknownPath = Join-Path $observations 'unknown.json'
    [IO.File]::WriteAllText($unknownPath, ([ordered]@{ checks = $goodChecks } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $unknownReport = Invoke-NodeJson $verify @('--root', $fixture, '--input', 'observations/unknown.json')
    Assert-True ($unknownReport.status -eq 'UNKNOWN') 'Unreviewed non-deterministic accessibility evidence did not produce UNKNOWN.'
    Invoke-ExpectedFailure { & $script:node $verify --root $fixture --input '..\outside.json' 2>&1 | Out-String } 'escaped|outside' 'accessibility input containment'

    $project = Join-Path $fixture 'project'
    New-Item -ItemType Directory -Path $project | Out-Null
    $axeMissing = Invoke-NodeJson $axe @('--root', $project)
    Assert-True ($axeMissing.status -eq 'INCOMPLETE' -and -not $axeMissing.installAttempted -and -not $axeMissing.scanExecuted) 'Missing axe dependency did not fail closed without installation.'
    $axePackageRoot = Join-Path $project 'node_modules/@axe-core/playwright'
    $playwrightPackageRoot = Join-Path $project 'node_modules/playwright'
    New-Item -ItemType Directory -Path $axePackageRoot, $playwrightPackageRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $axePackageRoot 'package.json'), '{"name":"@axe-core/playwright","version":"4.13.0"}', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $playwrightPackageRoot 'package.json'), '{"name":"playwright","version":"1.63.0"}', (New-Object Text.UTF8Encoding($false)))
    $axeAvailable = Invoke-NodeJson $axe @('--root', $project)
    Assert-True ($axeAvailable.status -eq 'PASS' -and $axeAvailable.available -and -not $axeAvailable.scanExecuted -and -not $axeAvailable.installAttempted) 'Compatible axe was not classified as available-only.'
    [IO.File]::WriteAllText((Join-Path $axePackageRoot 'package.json'), '{"name":"@axe-core/playwright","version":"4.12.0"}', (New-Object Text.UTF8Encoding($false)))
    $axeWrong = Invoke-NodeJson $axe @('--root', $project)
    Assert-True ($axeWrong.status -eq 'UNKNOWN') 'Wrong axe version did not fail closed as UNKNOWN.'

    $chromeConfig = Invoke-NodeJson $chrome @('--config')
    Assert-True (-not $chromeConfig.chromeStarted -and -not $chromeConfig.mcpRegistered -and $chromeConfig.policy.defaults.headless) 'Chrome DevTools config unexpectedly started a real browser/MCP.'
    $chromeAllowed = Invoke-NodeJson $chrome @('--tool','list_pages')
    Assert-True ($chromeAllowed.status -eq 'PASS' -and -not $chromeAllowed.chromeStarted) 'Chrome DevTools allowlist route was not dry-run.'
    Invoke-ExpectedFailure { & $script:node $chrome --tool evaluate_script 2>&1 | Out-String } 'not allowlisted|BLOCKED' 'Chrome arbitrary JavaScript'
    Invoke-ExpectedFailure { & $script:node $chrome --tool navigate_page --url 'https://example.com' 2>&1 | Out-String } 'loopback|BLOCKED' 'Chrome external URL'
} finally {
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true) }
}

Write-Output 'PASS: pinned Playwright/axe/Chrome provenance and the public metadata caveat are recorded without floating versions.'
Write-Output 'PASS: Playwright launcher is typed, loopback-only, child-isolated, temporary, no-install, no-download and rejects dangerous commands.'
Write-Output 'PASS: ACCESSIBILITY_VERIFY is read-only and distinguishes PASS, FAIL, INCOMPLETE and UNKNOWN with manual-review gating.'
Write-Output 'PASS: axe remains conditional and Chrome DevTools remains optional dry-run configuration with JS/telemetry/CrUX disabled.'
Write-Output 'PASS: normal MCP configuration contains neither Playwright MCP nor Chrome DevTools MCP.'
