Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$browserRoot = Join-Path $repoRoot 'integrations/browser-qa'
$launcher = Join-Path $browserRoot 'playwright-launcher.ps1'
$sessionProvider = Join-Path $browserRoot 'browser-session-provider.ps1'
$providerModule = Join-Path $browserRoot 'browser-session-provider.mjs'
$contractModule = Join-Path $browserRoot 'browser-qa-contract.mjs'
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

function Write-Utf8 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-Json {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    Write-Utf8 -Path $Path -Text ($Value | ConvertTo-Json -Depth 30)
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

function Invoke-PowerShellJson {
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "PowerShell helper failed: $Script`n$output" }
    try { return ($output | ConvertFrom-Json) } catch { throw "Expected JSON from $Script`n$output" }
}

function Resolve-HermeticNode {
    $toolchain = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json
    $nodeLock = @($toolchain.runtimes | Where-Object id -eq 'node' | Select-Object -First 1)
    $expected = [string]$nodeLock[0].targetVersion
    $candidates = New-Object Collections.Generic.List[string]
    $locked = [Environment]::ExpandEnvironmentVariables(([string]$nodeLock[0].portableResolution).Replace('/', '\'))
    try { if (Test-Path -LiteralPath $locked -PathType Leaf) { [void]$candidates.Add($locked) } } catch { }
    $system = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $system) { [void]$candidates.Add([IO.Path]::GetFullPath($system.Source)) }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            $observed = ((& $candidate '--version' 2>$null | Select-Object -First 1) | Out-String).Trim()
            if ($observed -eq "v$expected") { return [IO.Path]::GetFullPath($candidate) }
        } catch { }
    }
    throw "Node $expected is unavailable for hermetic adapter tests."
}

function New-SyntheticPackage {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$EntryName, [Parameter(Mandatory)][string]$EntryText)
    $nodeModules = Join-Path $Root 'node_modules'
    $bin = Join-Path $nodeModules '.bin'
    $cliPackage = Join-Path $nodeModules '@playwright/cli'
    $playwrightPackage = Join-Path $nodeModules 'playwright'
    $corePackage = Join-Path $nodeModules 'playwright-core'
    New-Item -ItemType Directory -Force -Path $bin, $cliPackage, $playwrightPackage, $corePackage | Out-Null
    Write-Utf8 -Path (Join-Path $cliPackage 'package.json') -Text (@{
        name = '@playwright/cli'
        version = '0.1.19'
        license = 'Apache-2.0'
        bin = [ordered]@{ 'playwright-cli' = $EntryName }
        ftkSyntheticTestDouble = $true
    } | ConvertTo-Json -Depth 5)
    Write-Utf8 -Path (Join-Path $playwrightPackage 'package.json') -Text '{"name":"playwright","version":"1.63.0-alpha-2026-08-31"}'
    Write-Utf8 -Path (Join-Path $corePackage 'package.json') -Text '{"name":"playwright-core","version":"1.63.0-alpha-2026-08-31"}'
    Write-Utf8 -Path (Join-Path $cliPackage $EntryName) -Text $EntryText
    Write-Utf8 -Path (Join-Path $bin 'playwright-cli.cmd') -Text '@echo off`r`nrem @playwright\cli\cli.js`r`n'
    return [pscustomobject]@{
        root = $Root
        cliPath = Join-Path $bin 'playwright-cli.cmd'
        packageRoot = $cliPackage
        entryPath = Join-Path $cliPackage $EntryName
    }
}

function New-Transaction {
    param([switch]$ExternalRequests)
    $transactionUrl = if ($ExternalRequests) { 'http://127.0.0.1:4173/external' } else { 'http://127.0.0.1:4173/positive' }
    $navigationUrl = if ($ExternalRequests) { 'http://localhost:4173/external' } else { 'http://localhost:4173/positive' }
    $reference = if ($ExternalRequests) { 'synthetic-external' } else { 'synthetic-positive' }
    $fixture = if ($ExternalRequests) { 'tests/fixtures/browser-qa/negative-external-subrequests.html' } else { 'tests/fixtures/browser-qa/positive.html' }
    return [ordered]@{
        schemaVersion = 1
        operation = 'browser-qa.transaction'
        subject = [ordered]@{
            reference = $reference
            expectedViewport = [ordered]@{ width = 1280; height = 720 }
            motionExpectations = [ordered]@{ prefersReducedMotion = 'required' }
            fixture = $fixture
        }
        operations = @(
            [ordered]@{ operation = 'session.open'; browser = 'chromium'; url = $transactionUrl; viewport = [ordered]@{ width = 1280; height = 720 }; headless = $true; networkPolicy = [ordered]@{ externalSubrequests = 'deny' } }
            [ordered]@{ operation = 'navigate'; url = $navigationUrl }
            [ordered]@{ operation = 'viewport.resize'; width = 1280; height = 720 }
            [ordered]@{ operation = 'capture.dom'; maxNodes = 100 }
            [ordered]@{ operation = 'capture.ax'; maxNodes = 100 }
            [ordered]@{ operation = 'interaction'; action = 'Tab'; expectedFocus = 'unknown' }
            [ordered]@{ operation = 'capture.screenshot'; artifact = 'positive.png'; fullPage = $false }
            [ordered]@{ operation = 'capture.requests'; maxRequests = 50 }
            [ordered]@{ operation = 'session.close' }
        )
        requiredEvidence = @('dom', 'ax', 'screenshot', 'requests')
    }
}

function New-SyntheticBundle {
    param([ValidateSet('positive', 'unlabeled', 'focus', 'aria', 'external')][string]$Variant = 'positive')
    $controlName = if ($Variant -eq 'unlabeled') { '' } else { 'Part number' }
    $headingLevel = if ($Variant -eq 'unlabeled') { 3 } else { 2 }
    $focusStatus = if ($Variant -eq 'focus') { 'FAIL' } else { 'PASS' }
    $focusVisible = $Variant -ne 'focus'
    $ariaIssues = @(if ($Variant -eq 'aria') { @('aria-expanded must be boolean') } else { @() })
    $relationshipStatus = if ($Variant -eq 'aria') { 'FAIL' } else { 'PASS' }
    $externalObserved = @(if ($Variant -eq 'external') { @('https://example.com') } else { @() })
    $requestItems = @(if ($Variant -eq 'external') {
        @([ordered]@{ url = 'https://example.com/external.js'; origin = 'https://example.com'; loopback = $false; method = 'GET'; resourceType = 'script' })
    } else {
        @([ordered]@{ url = 'http://127.0.0.1:4173/positive'; origin = 'http://127.0.0.1:4173'; loopback = $true; method = 'GET'; resourceType = 'document' })
    })
    $heading = [ordered]@{ id = 'heading'; role = 'heading'; accessibleName = 'Honda part lookup'; level = 1; states = [ordered]@{}; children = @() }
    $subheading = [ordered]@{ id = 'subheading'; role = 'heading'; accessibleName = 'Search by part number'; level = $headingLevel; states = [ordered]@{}; children = @() }
    $field = [ordered]@{ id = 'field'; role = 'textbox'; accessibleName = $controlName; ref = 'e3'; states = [ordered]@{}; children = @() }
    $button = [ordered]@{ id = 'button'; role = 'button'; accessibleName = 'Search'; ref = 'e4'; states = [ordered]@{}; children = @() }
    $form = [ordered]@{ id = 'form'; role = 'form'; accessibleName = 'Search'; states = [ordered]@{}; children = @($field, $button) }
    $nav = [ordered]@{ id = 'nav'; role = 'navigation'; accessibleName = 'Primary navigation'; states = [ordered]@{}; children = @() }
    $main = [ordered]@{ id = 'main'; role = 'main'; accessibleName = 'Main'; states = [ordered]@{}; children = @($heading, $subheading, $nav, $form) }
    $focusAfter = [ordered]@{ id = 'field'; ref = 'e3'; role = 'textbox'; accessibleName = $controlName }
    $focusObservation = [ordered]@{
        id = 'focus-1'
        status = $focusStatus
        action = 'Tab'
        focusBefore = $null
        focusAfter = $focusAfter
        expectedBehavior = 'target'
        target = [ordered]@{ ref = 'e3'; role = 'textbox'; accessibleName = $controlName }
        focusVisible = $focusVisible
        focusVisibility = [ordered]@{ status = if ($focusVisible) { 'PASS' } else { 'FAIL' }; evidenceRefs = @('evidence.keyboardFocus.observations'); limitations = @() }
        evidenceRefs = @('evidence.keyboardFocus.observations[0]')
        limitations = @()
    }
    $evidence = [ordered]@{
        dom = [ordered]@{
            status = 'COMPLETE'
            evidenceRefs = @('evidence.dom.nodes')
            nodes = @($main)
            formRelationships = [ordered]@{ status = $relationshipStatus; evidenceRefs = @('evidence.dom.formRelationships'); limitations = @() }
            aria = [ordered]@{ status = if ($ariaIssues.Count) { 'FAIL' } else { 'PASS' }; evidenceRefs = @('evidence.dom.aria'); limitations = @() }
            ariaIssues = $ariaIssues
            limitations = @()
        }
        ax = [ordered]@{ status = 'COMPLETE'; dedicated = $true; supportVerified = $true; captureInvocation = [ordered]@{ operation = 'capture.ax'; command = 'snapshot'; fresh = $true; source = 'playwright-cli' }; evidenceRefs = @('evidence.ax.tree'); tree = @($main); limitations = @() }
        screenshots = @([ordered]@{ kind = 'screenshot'; basename = 'positive.png'; sizeBytes = 12; sha256 = ('a' * 64); viewport = [ordered]@{ width = 1280; height = 720 }; existsAtCapture = $true })
        requests = [ordered]@{
            status = if ($externalObserved.Count) { 'FAIL' } else { 'COMPLETE' }
            items = $requestItems
            externalSubrequests = [ordered]@{ observed = $externalObserved; blocked = @(); status = if ($externalObserved.Count) { 'VERIFICATION_FAILURE' } else { 'NO_EXTERNAL_OBSERVED' } }
            evidenceRefs = @('evidence.requests')
            limitations = @()
        }
        keyboardFocus = [ordered]@{ status = $focusStatus; observations = @($focusObservation); evidenceRefs = @('evidence.keyboardFocus.observations'); limitations = @() }
        motion = [ordered]@{ reducedMotion = [ordered]@{ status = 'PASS'; evidenceRefs = @('evidence.motion.reducedMotion'); limitations = @() }; limitations = @() }
        reflow = [ordered]@{ status = 'PASS'; evidenceRefs = @('evidence.reflow'); limitations = @() }
    }
    return [ordered]@{
        schemaVersion = 1
        kind = 'browser-evidence-bundle'
        capability = 'playwright-cli'
        operation = 'browser-qa.transaction'
        materialized = $false
        attempted = $true
        browserReady = $true
        sessionReady = $true
        succeeded = $true
        failureType = $null
        browser = [ordered]@{ engine = 'chromium'; headless = $true; headlessControl = 'explicit-cli-flag'; revision = $null; revisionStatus = 'UNVERIFIED'; revisionPinTracked = $false }
        session = [ordered]@{ state = 'CLOSED'; ephemeral = $true; persistentState = $false; currentUrl = 'http://127.0.0.1:4173/positive'; operationCount = 8 }
        viewport = [ordered]@{ width = 1280; height = 720 }
        networkPolicy = [ordered]@{ externalSubrequests = 'deny'; enforcement = 'post-capture-fail-closed'; interceptionAvailable = $false; externalObserved = ($externalObserved.Count -gt 0) }
        evidence = $evidence
        artifacts = $evidence.screenshots
        requiredEvidence = @('dom', 'ax', 'screenshot', 'requests', 'keyboardFocus')
        manualReview = [ordered]@{
            byCheck = [ordered]@{
                'reduced-motion' = [ordered]@{ status = 'PASS'; evidenceRefs = @('manual.reduced-motion'); limitations = @() }
                reflow = [ordered]@{ status = 'PASS'; evidenceRefs = @('manual.reflow'); limitations = @() }
            }
        }
        limitations = @('Hermetic fixture evidence; not real browser materialization.')
        outputContract = [ordered]@{ valid = $true; bounded = $true; rawHtmlIncluded = $false; arbitraryJavaScriptUsed = $false; artifactContainmentValidated = $true }
        synthetic = $true
        evidenceOrigin = 'hermetic-fixture'
    }
}

$script:node = Resolve-HermeticNode
$sourceFiles = @(Get-ChildItem -LiteralPath $browserRoot -File -Force)
Assert-True (Test-Path -LiteralPath $sessionProvider -PathType Leaf) 'Browser session provider is missing.'
Assert-True (Test-Path -LiteralPath $providerModule -PathType Leaf) 'Browser session provider module is missing.'
Assert-True (Test-Path -LiteralPath $contractModule -PathType Leaf) 'Browser QA contract module is missing.'
foreach ($sourceFile in $sourceFiles) {
    $text = Get-Content -Raw -LiteralPath $sourceFile.FullName
    Assert-True ($text -notmatch '(?i)npm\s+(install|i)|npx\s+.*install|playwright\s+install|browser\s+download') "Automatic installation/download wording or command found in $($sourceFile.Name)."
}

$cli = $lock.playwright.cli
Assert-True ($cli.id -eq '@playwright/cli' -and $cli.version -eq '0.1.19') 'Playwright CLI pin drifted.'
Assert-True ($cli.license -eq 'Apache-2.0' -and $cli.commitSha -eq '397ee39c83a651e1314cfb010b94e8a3aac11261') 'Playwright CLI license or official tag provenance drifted.'
Assert-True ($cli.integrity -eq 'sha512-eGXIsYa5D+dC6wHGf+9uEislhPGip1djK+yiNAD7BVsXN3WzzR1J4ClFAhYhyu7wSEFqhcPrqXAYeBJF1dKJ7A==') 'Playwright CLI registry integrity drifted.'
Assert-True ($null -eq $cli.registryGitHead -and $null -eq $cli.registryAttestation -and $cli.provenanceStatus -eq 'validated-with-public-metadata-caveat') 'Known Playwright CLI provenance caveat was hidden.'
Assert-True ($cli.dependencies.playwright -eq '1.63.0-alpha-2026-08-31' -and $cli.dependencies.'playwright-core' -eq '1.63.0-alpha-2026-08-31') 'Effective CLI dependency graph was silently normalized.'
Assert-True ($lock.playwright.stableLibraryTarget.version -eq '1.63.0' -and $lock.playwright.testMechanism.version -eq '1.63.0') 'Stable Playwright target drifted.'
    Assert-True ($lock.browserMaterialization.revisionPinTracked -and $lock.browserMaterialization.revision -eq '1243' -and $lock.browserMaterialization.browserVersion -eq '153.0.8010.12') 'Browser revision materialization record drifted.'
Assert-True ($lock.axe.version -eq '4.13.0' -and $lock.axe.classification -eq 'CONDITIONAL') 'axe conditional target drifted.'
Assert-True ($lock.chromeDevtools.version -eq '1.8.0' -and $lock.chromeDevtools.classification -eq 'OPTIONAL') 'Chrome DevTools optional target drifted.'

$mcpText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/.mcp.json')
Assert-True ($mcpText -notmatch '(?i)playwright|chrome-devtools') 'A Playwright or Chrome DevTools MCP appeared in normal distribution configuration.'
    Assert-True ($policy.defaults.headless -and $policy.defaults.isolated -and $policy.defaults.ephemeralBrowser -and $policy.headlessContract.flag -eq '--no-headed') 'Playwright defaults/headless contract drifted.'
Assert-True (-not $policy.defaults.arbitraryJavaScript -and -not $policy.defaults.automaticBrowserDownload -and -not $policy.defaults.automaticPackageInstallation) 'Playwright dangerous defaults are enabled.'
Assert-True (@($policy.blockedActions) -contains 'eval' -and @($policy.blockedActions) -contains 'run-code' -and @($policy.blockedActions) -contains 'attach') 'Arbitrary JavaScript or browser attachment is not blocked.'
Assert-True (@($policy.environmentAllowlist) -notcontains 'PATH' -and @($policy.environmentAllowlist) -notcontains 'HOME' -and @($policy.environmentAllowlist) -notcontains 'USERPROFILE') 'Playwright child environment inherited a broad path/profile variable.'
    Assert-True ($policy.networkBoundary.externalSubrequests -eq 'deny-or-fail-closed' -and $policy.browserIdentity.revisionPinTracked -and $policy.browserIdentity.revision -eq '1243') 'Network or browser identity contract drifted.'
Assert-True (-not $chromePolicy.defaults.javascriptEvaluation -and -not $chromePolicy.defaults.usageStatistics -and -not $chromePolicy.defaults.performanceCrux -and -not $chromePolicy.defaults.existingBrowserAttach) 'Chrome DevTools safety defaults drifted.'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests/fixtures/browser-qa/negative-external-subrequests.html')) -match 'https://example.com') 'External-subrequest fixture is missing.'

foreach ($scriptPath in @($launcher, $sessionProvider)) {
    $command = Get-Command $scriptPath
    foreach ($forbiddenParameter in @('Eval', 'RunCode', 'Persistent', 'Profile', 'Attach', 'StorageState', 'Arguments', 'RawCliArgs')) {
        Assert-True (-not $command.Parameters.ContainsKey($forbiddenParameter)) "Wrapper exposes forbidden parameter $forbiddenParameter."
    }
}
$plan = & $launcher -Action open -Url 'http://127.0.0.1:4173/synthetic' -SessionId 'synthetic-open' -PlanOnly | ConvertFrom-Json
Assert-True (-not $plan.executed -and $plan.browserDownloads -eq 0 -and -not $plan.packageInstallation -and $plan.headlessControl -eq 'explicit-cli-flag') 'Playwright action plan executed, enabled installation, or omitted explicit headless.'
Assert-True ($plan.workingDirectory.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) 'Playwright output escaped the OS temp directory.'
    Assert-True (@($plan.argv) -contains '--no-headed' -and @($plan.argv) -contains '-s=synthetic-open') 'Open action did not apply explicit headless or isolated session naming.'
Invoke-ExpectedFailure { & $launcher -Action open -Url 'https://example.com' -PlanOnly } 'loopback' 'external Playwright URL'
Invoke-ExpectedFailure { & $launcher -Action open -Url 'http://user:synthetic@127.0.0.1:4173' -PlanOnly } 'Credentials' 'URL credentials'
Invoke-ExpectedFailure { & $launcher -Action open -Url 'file:///tmp/page.html' -PlanOnly } 'loopback' 'file URL'
Invoke-ExpectedFailure { & $launcher -Action press -Text 'ArrowDown' -PlanOnly } 'press accepts only' 'arbitrary key'
Invoke-ExpectedFailure { & $launcher -Action screenshot -OutputName '..\escape.png' -PlanOnly } 'basename' 'artifact traversal'
Invoke-ExpectedFailure { & $launcher -Action resize -Width 100 -Height 100 -PlanOnly } 'ValidateRange|bounded|intervalo' 'viewport lower bound'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-browser-qa-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $transactionPath = Join-Path $fixture 'transaction.json'
    Write-Json -Path $transactionPath -Value (New-Transaction)
    $syntheticEntryText = @'
import fs from 'node:fs';
import path from 'node:path';
const statePath = path.join(process.cwd(), '.synthetic-session.json');
const rawArgs = process.argv.slice(2);
const sessionArgumentIndex = rawArgs.findIndex((value) => value.startsWith('-s='));
const actionIndex = sessionArgumentIndex >= 0 ? sessionArgumentIndex + 1 : 0;
const action = rawArgs[actionIndex];
const args = rawArgs.slice(actionIndex + 1);
const readState = () => JSON.parse(fs.readFileSync(statePath, 'utf8'));
const writeState = (value) => fs.writeFileSync(statePath, JSON.stringify(value));
const snapshot = () => {
  const state = readState();
  const focused = state.focus > 0 ? ' focused=true' : '';
  return [
    '- main "Main" [ref=m1]',
    '  - banner "Header" [ref=b1]',
    '  - navigation "Primary navigation" [ref=n1]',
    '    - link "Lookup" [ref=e1]',
    '  - heading "Honda part lookup" [level=1]',
    '  - heading "Search by part number" [level=2]',
    '  - form "Search" [ref=f1]',
    `    - textbox "Part number" [ref=e3${focused}]`,
    '    - button "Search" [ref=e4]',
  ].join('\n');
};
if (action === 'open') { writeState({ url: args[0], focus: 0 }); process.stdout.write('browserReady sessionReady\n'); }
else if (action === 'goto') { const state = readState(); state.url = args[0]; writeState(state); process.stdout.write('navigated\n'); }
else if (action === 'resize') { process.stdout.write('resized\n'); }
else if (action === 'snapshot') { process.stdout.write(JSON.stringify({ snapshot: snapshot() }) + '\n'); }
else if (action === 'press') { const state = readState(); state.focus = Math.min(1, state.focus + 1); writeState(state); process.stdout.write('pressed\n'); }
else if (action === 'click' || action === 'fill') { const state = readState(); state.focus = 1; writeState(state); process.stdout.write('interacted\n'); }
else if (action === 'screenshot') { const name = args[args.indexOf('--filename') + 1]; fs.writeFileSync(path.join(process.cwd(), name), Buffer.from('synthetic png bytes')); process.stdout.write('screenshot saved\n'); }
else if (action === 'requests') { const state = readState(); const requestUrl = state.url.endsWith('/external') ? 'https://example.com/external.js' : state.url; process.stdout.write(JSON.stringify({ requests: [{ url: requestUrl }] }) + '\n'); }
else if (action === 'close') { if (fs.existsSync(statePath)) fs.unlinkSync(statePath); process.stdout.write('closed\n'); }
else { process.stderr.write('unsupported action\n'); process.exitCode = 1; }
'@
    $syntheticInstall = New-SyntheticPackage -Root (Join-Path $fixture 'synthetic-install') -EntryName 'cli.js' -EntryText $syntheticEntryText
    $execution = Invoke-PowerShellJson -Script $sessionProvider -Arguments @('-InputPath', $transactionPath, '-SessionId', ('synthetic' + (Get-Random)), '-CliPath', $syntheticInstall.cliPath, '-TestOnlySyntheticCli')
    Assert-True ($execution.dedicatedExecution.attempted -and $execution.dedicatedExecution.childStarted) 'Provider child was not started for the synthetic transaction.'
    Assert-True ($execution.browserEvidenceBundle -and $execution.browserEvidenceBundle.browserReady -and $execution.browserEvidenceBundle.sessionReady) 'Synthetic readiness states were not captured.'
    Assert-True ($execution.browserEvidenceBundle.evidence.dom.status -eq 'COMPLETE' -and $execution.browserEvidenceBundle.evidence.ax.status -eq 'COMPLETE' -and $execution.browserEvidenceBundle.evidence.ax.dedicated -and $execution.browserEvidenceBundle.evidence.ax.captureInvocation.fresh) 'DOM/AX evidence path did not complete as separate captures.'
    Assert-True (@($execution.browserEvidenceBundle.evidence.screenshots).Count -eq 1 -and $execution.browserEvidenceBundle.evidence.screenshots[0].sha256.Length -eq 64) 'Screenshot artifact hash/metadata was not captured.'
    Assert-True ($execution.browserEvidenceBundle.evidence.requests.status -eq 'COMPLETE' -and -not $execution.browserEvidenceBundle.networkPolicy.externalObserved) 'Loopback request evidence was not captured safely.'
    Assert-True (@($execution.browserEvidenceBundle.evidence.keyboardFocus.observations).Count -eq 1) 'Keyboard/focus observation was not captured.'
    Assert-True (-not $execution.dedicatedExecution.succeeded -and $execution.browserEvidenceBundle.synthetic -and $execution.cleanup.sessionRootRemoved) 'Synthetic evidence was incorrectly reported as dedicated PASS or not cleaned.'
    Assert-True ($execution.nodeIdentity.observedVersion -eq '24.20.0' -and $execution.nodeIdentity.executableHashStatus -in @('OBSERVED_NOT_LOCK_COMPARABLE', 'UNVERIFIED_BYTES')) 'Provider did not report Node 24.20.0 identity truthfully.'
    Assert-True ($execution.cliIdentity.expectedPackage -eq '@playwright/cli' -and $execution.cliIdentity.expectedVersion -eq '0.1.19' -and $execution.cliIdentity.entryHashStatus -eq 'SYNTHETIC_TEST_DOUBLE') 'CLI package identity/provenance was not explicit.'

    $badCliRoot = Join-Path $fixture 'bad-cli'
    New-Item -ItemType Directory -Force -Path $badCliRoot | Out-Null
    $badCli = Join-Path $badCliRoot 'playwright-cli.cmd'
    Write-Utf8 -Path $badCli -Text '@echo off'
    $badIdentity = Invoke-PowerShellJson -Script $sessionProvider -Arguments @('-InputPath', $transactionPath, '-SessionId', ('bad' + (Get-Random)), '-CliPath', $badCli)
    Assert-True (-not $badIdentity.dedicatedExecution.childStarted -and $badIdentity.dedicatedExecution.failureType -eq 'DEPENDENCY_OR_RUNTIME_FAILURE' -and $badIdentity.cleanup.sessionRootRemoved) 'Arbitrary same-name CLI was not rejected before provider child execution.'

    $leaseSession = 'lease' + (Get-Random)
    $leaseOpen = Invoke-PowerShellJson -Script $launcher -Arguments @('-Action', 'open', '-Url', 'http://127.0.0.1:4173/lease', '-SessionId', $leaseSession, '-CliPath', $syntheticInstall.cliPath, '-TestOnlySyntheticCli')
    Assert-True ($leaseOpen.executed -and -not $leaseOpen.dedicatedExecution.succeeded -and $leaseOpen.sessionLease.retained -and $leaseOpen.cleanup.status -eq 'EXPLICIT_CLOSE_REQUIRED' -and (Test-Path -LiteralPath $leaseOpen.workingDirectory)) 'Launcher did not retain an explicitly owned shared session lease.'
    $leaseClose = Invoke-PowerShellJson -Script $launcher -Arguments @('-Action', 'close', '-SessionId', $leaseSession, '-CliPath', $syntheticInstall.cliPath, '-TestOnlySyntheticCli')
    Assert-True ($leaseClose.executed -and $leaseClose.cleanup.sessionRootRemoved -and -not (Test-Path -LiteralPath $leaseClose.workingDirectory)) 'Launcher close did not consume and remove the owned session lease.'

    $spamInstall = New-SyntheticPackage -Root (Join-Path $fixture 'spam-install') -EntryName 'cli.js' -EntryText 'process.exit(0);'
    $spamWrapper = @'
@echo off
for /L %%i in (1,1,40000) do @echo 1234567890123456789012345678901234567890
rem @playwright\cli\cli.js
'@
    Write-Utf8 -Path $spamInstall.cliPath -Text $spamWrapper
    $overflow = Invoke-PowerShellJson -Script $launcher -Arguments @('-Action', 'open', '-Url', 'http://127.0.0.1:4173/overflow', '-SessionId', ('overflow' + (Get-Random)), '-CliPath', $spamInstall.cliPath, '-TestOnlySyntheticCli')
    Assert-True ($overflow.dedicatedExecution.childStarted -and $overflow.dedicatedExecution.failureType -eq 'OUTPUT_CONTRACT_FAILURE' -and $overflow.dedicatedExecution.diagnostics.stdoutOverflowed) 'Bounded stdout overflow was not classified as OUTPUT_CONTRACT_FAILURE.'
    Assert-True ($overflow.cleanup.sessionRootRemoved -and -not $overflow.cleanup.cleanupGuaranteed) 'Overflow cleanup was not bounded/truthful.'

    $hangEntryText = @'
import fs from 'node:fs';
import path from 'node:path';
const statePath = path.join(process.cwd(), '.timeout-state.json');
const rawArgs = process.argv.slice(2);
const sessionArgumentIndex = rawArgs.findIndex((value) => value.startsWith('-s='));
const actionIndex = sessionArgumentIndex >= 0 ? sessionArgumentIndex + 1 : 0;
const action = rawArgs[actionIndex];
const count = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, 'utf8')).count : 0;
fs.writeFileSync(statePath, JSON.stringify({ count: count + 1 }));
if (count === 0) setInterval(() => {}, 1000);
else if (action === 'close') { fs.unlinkSync(statePath); process.stdout.write('closed\n'); }
'@
    $hangInstall = New-SyntheticPackage -Root (Join-Path $fixture 'hang-install') -EntryName 'hang.js' -EntryText $hangEntryText
    $timeoutExecution = Invoke-PowerShellJson -Script $sessionProvider -Arguments @('-InputPath', $transactionPath, '-SessionId', ('hang' + (Get-Random)), '-CliPath', $hangInstall.cliPath, '-TimeoutMilliseconds', '1000', '-TestOnlySyntheticCli')
    Assert-True ($timeoutExecution.dedicatedExecution.childStarted -and $timeoutExecution.dedicatedExecution.timedOut -and $timeoutExecution.dedicatedExecution.failureType -eq 'TIMEOUT') 'Synthetic provider timeout was not classified with childStarted=true.'
    Assert-True ($timeoutExecution.cleanup.sessionRootRemoved -and -not $timeoutExecution.cleanup.cleanupGuaranteed) 'Timeout cleanup was not bounded/truthful.'

    $innerTimeoutExecution = Invoke-PowerShellJson -Script $sessionProvider -Arguments @('-InputPath', $transactionPath, '-SessionId', ('innerhang' + (Get-Random)), '-CliPath', $hangInstall.cliPath, '-TimeoutMilliseconds', '60000', '-TestOnlySyntheticCli')
    Assert-True ($innerTimeoutExecution.dedicatedExecution.childStarted -and $innerTimeoutExecution.dedicatedExecution.timedOut -and $innerTimeoutExecution.dedicatedExecution.failureType -eq 'TIMEOUT' -and -not $innerTimeoutExecution.dedicatedExecution.succeeded) 'Provider-internal timeout was not propagated as timedOut=true.'
    Assert-True ($innerTimeoutExecution.browserEvidenceBundle.timedOut -and $innerTimeoutExecution.browserEvidenceBundle.failureType -eq 'TIMEOUT' -and $innerTimeoutExecution.browserEvidenceBundle.session.cleanup.attempted -and $innerTimeoutExecution.cleanup.sessionRootRemoved) 'Provider-internal timeout did not preserve typed partial evidence and deterministic cleanup.'

    $externalTransactionPath = Join-Path $fixture 'external-transaction.json'
    Write-Json -Path $externalTransactionPath -Value (New-Transaction -ExternalRequests)
    $externalExecution = Invoke-PowerShellJson -Script $sessionProvider -Arguments @('-InputPath', $externalTransactionPath, '-SessionId', ('external' + (Get-Random)), '-CliPath', $syntheticInstall.cliPath, '-TestOnlySyntheticCli')
    Assert-True ($externalExecution.dedicatedExecution.childStarted -and -not $externalExecution.dedicatedExecution.succeeded -and $externalExecution.dedicatedExecution.failureType -eq 'OUTPUT_CONTRACT_FAILURE') 'External subrequest did not fail closed at the lifecycle boundary.'
    Assert-True ($externalExecution.browserEvidenceBundle.evidence.requests.status -eq 'FAIL' -and @($externalExecution.browserEvidenceBundle.evidence.requests.externalSubrequests.observed) -contains 'https://example.com' -and $externalExecution.browserEvidenceBundle.session.cleanup.closeSucceeded -and $externalExecution.cleanup.sessionRootRemoved) 'External subrequest did not retain request evidence or complete bounded cleanup.'
    $externalEvidencePath = Join-Path $fixture 'external-evidence.json'
    Write-Json -Path $externalEvidencePath -Value $externalExecution.browserEvidenceBundle
    $externalReport = Invoke-NodeJson -Script $verify -Arguments @('--root', $fixture, '--input', 'external-evidence.json')
    Assert-True ($externalReport.status -eq 'FAIL' -and -not $externalReport.dedicatedPass) 'External evidence was accepted as an accessibility PASS.'

    $positiveBundle = New-SyntheticBundle -Variant positive
    $positiveObservation = [ordered]@{}
    foreach ($property in $positiveBundle.GetEnumerator()) { $positiveObservation[$property.Key] = $property.Value }
    $positiveObservation.status = 'PASS'
    $positivePath = Join-Path $fixture 'positive-evidence.json'
    Write-Json -Path $positivePath -Value $positiveObservation
    $positiveBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $positivePath).Hash
    $positiveReport = Invoke-NodeJson -Script $verify -Arguments @('--root', $fixture, '--input', 'positive-evidence.json')
    Assert-True ($positiveReport.status -eq 'INCOMPLETE' -and $positiveReport.syntheticEvidenceStatus -eq 'PASS' -and -not $positiveReport.dedicatedPass -and $positiveReport.callerStatusIgnored -and $positiveReport.manualReview.byCheckUsed) 'Synthetic evidence did not produce a bounded non-dedicated verifier result.'
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $positivePath).Hash -eq $positiveBefore -and $positiveReport.readOnly -and -not $positiveReport.codeModified) 'Accessibility verifier changed evidence or claimed a write.'

    $globalReviewBundle = New-SyntheticBundle -Variant positive
    $globalReviewBundle.manualReview = [ordered]@{ reviewed = $true }
    Write-Json -Path (Join-Path $fixture 'global-review.json') -Value $globalReviewBundle
    $globalReview = Invoke-NodeJson -Script $verify -Arguments @('--root', $fixture, '--input', 'global-review.json')
    Assert-True ($globalReview.status -eq 'UNKNOWN' -and -not $globalReview.manualReview.byCheckUsed) 'Global manualReview.reviewed remained sufficient authority.'

    foreach ($variant in @('unlabeled', 'focus', 'aria', 'external')) {
        $negativePath = Join-Path $fixture "$variant.json"
        Write-Json -Path $negativePath -Value (New-SyntheticBundle -Variant $variant)
        $negativeReport = Invoke-NodeJson -Script $verify -Arguments @('--root', $fixture, '--input', "$variant.json")
        Assert-True ($negativeReport.status -eq 'FAIL') "Negative accessibility fixture $variant did not fail closed."
    }

    $fabricated = [ordered]@{ kind = 'legacy-observation'; status = 'PASS'; checks = [ordered]@{ 'semantic-structure' = 'PASS'; 'form-labels' = 'PASS' }; manualReview = [ordered]@{ reviewed = $true }; axe = [ordered]@{ used = $true; status = 'PASS' } }
    Write-Json -Path (Join-Path $fixture 'fabricated.json') -Value $fabricated
    $fabricatedReport = Invoke-NodeJson -Script $verify -Arguments @('--root', $fixture, '--input', 'fabricated.json')
    Assert-True ($fabricatedReport.status -eq 'FAIL' -and $fabricatedReport.contractValid -eq $false -and $fabricatedReport.callerStatusIgnored -and -not $fabricatedReport.dedicatedPass -and -not $fabricatedReport.axe.scanExecuted) 'Fabricated PASS input was accepted as accessibility authority.'

    $malformedBundle = [ordered]@{ kind = 'browser-evidence-bundle'; status = 'PASS'; evidence = [ordered]@{} }
    Write-Json -Path (Join-Path $fixture 'malformed.json') -Value $malformedBundle
    $malformedReport = Invoke-NodeJson -Script $verify -Arguments @('--root', $fixture, '--input', 'malformed.json')
    Assert-True ($malformedReport.status -eq 'FAIL' -and $malformedReport.failureType -eq 'OUTPUT_CONTRACT_FAILURE') 'Malformed evidence did not fail closed.'
    Invoke-ExpectedFailure { & $script:node $verify --root $fixture --input '..\outside.json' 2>&1 | Out-String } 'temporary|basename|escaped|outside' 'accessibility input containment'

    $axeProject = Join-Path $fixture 'axe-project'
    New-Item -ItemType Directory -Force -Path $axeProject | Out-Null
    $axeMissing = Invoke-NodeJson -Script $axe -Arguments @('--root', $axeProject)
    Assert-True ($axeMissing.status -eq 'INCOMPLETE' -and -not $axeMissing.installAttempted -and -not $axeMissing.scanExecuted) 'Missing axe dependency did not fail closed without installation.'
    $axePackageRoot = Join-Path $axeProject 'node_modules/@axe-core/playwright'
    $playwrightPackageRoot = Join-Path $axeProject 'node_modules/playwright'
    New-Item -ItemType Directory -Force -Path $axePackageRoot, $playwrightPackageRoot | Out-Null
    Write-Utf8 -Path (Join-Path $axePackageRoot 'package.json') -Text '{"name":"@axe-core/playwright","version":"4.13.0"}'
    Write-Utf8 -Path (Join-Path $playwrightPackageRoot 'package.json') -Text '{"name":"playwright","version":"1.63.0"}'
    $axeAvailable = Invoke-NodeJson -Script $axe -Arguments @('--root', $axeProject)
    Assert-True ($axeAvailable.status -eq 'SUPPLEMENTARY_AVAILABLE' -and $axeAvailable.available -and -not $axeAvailable.scanExecuted -and -not $axeAvailable.installAttempted) 'axe availability was confused with a scan result.'

    $chromeConfig = Invoke-NodeJson -Script $chrome -Arguments @('--config')
    Assert-True (-not $chromeConfig.chromeStarted -and -not $chromeConfig.mcpRegistered -and $chromeConfig.policy.defaults.headless) 'Chrome DevTools config unexpectedly started a real browser/MCP.'
    Invoke-ExpectedFailure { & $script:node $chrome --tool evaluate_script 2>&1 | Out-String } 'not allowlisted|BLOCKED' 'Chrome arbitrary JavaScript'

    $preparedInput = Join-Path $fixture 'prepared.json'
    Write-Json -Path $preparedInput -Value (New-Transaction)
    $preparedCommand = Get-Command 'playwright-cli' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $preparedCommand) {
        Write-Output 'NOT_MATERIALIZED: pinned playwright-cli is not available; no installation/download attempted.'
    } else {
        $prepared = Invoke-PowerShellJson -Script $sessionProvider -Arguments @('-InputPath', $preparedInput, '-SessionId', ('prepared' + (Get-Random)), '-TimeoutMilliseconds', '10000')
        Assert-True ($prepared.browserDownloads -eq 0 -and -not $prepared.packageInstallation) 'Prepared integration attempted installation/download.'
        Assert-True (-not $prepared.dedicatedExecution.succeeded -or $prepared.browserEvidenceBundle.browser.revisionStatus -ne 'VERIFIED') 'Prepared integration claimed dedicated PASS without a verified browser revision.'
        Write-Output "PREPARED_RESULT: materialized=$($prepared.dedicatedExecution.materialized); childStarted=$($prepared.dedicatedExecution.childStarted); browserReady=$($prepared.browserEvidenceBundle.browserReady); sessionReady=$($prepared.browserEvidenceBundle.sessionReady); failureType=$($prepared.dedicatedExecution.failureType); browserRevisionStatus=$($prepared.browserEvidenceBundle.browser.revisionStatus)"
    }
} finally {
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true) }
}

$changed = @(git -c safe.directory="$repoRoot" diff --name-only)
$allowed = @(
    'integrations/browser-qa.lock.json',
    'integrations/browser-qa/accessibility-verify.mjs',
    'integrations/browser-qa/axe-conditional.mjs',
    'integrations/browser-qa/browser-qa-contract.mjs',
    'integrations/browser-qa/browser-qa-process.ps1',
    'integrations/browser-qa/browser-session-provider.mjs',
    'integrations/browser-qa/browser-session-provider.ps1',
    'integrations/browser-qa/playwright-launcher.ps1',
    'integrations/browser-qa/playwright-runtime-policy.json',
    'integrations/browser-qa/README.md',
    '.agents/skills/playwright-cli/SKILL.md',
    '.agents/skills/frontend-accessibility/SKILL.md',
    'tests/test-browser-qa.ps1'
)
foreach ($path in @($changed)) {
    Assert-True ($allowed -contains $path) "Unexpected non-03B file changed: $path"
}
$untracked = @(git -c safe.directory="$repoRoot" ls-files --others --exclude-standard)
foreach ($path in @($untracked)) {
    Assert-True ($allowed -contains $path -or $path -like 'tests/fixtures/browser-qa/*') "Unexpected untracked non-03B file: $path"
}

Write-Output 'PASS: Node 24.20.0 exact-version resolution, CLI package identity, pinned lock metadata, and provenance limitations are explicit.'
Write-Output 'PASS: typed loopback/headless/viewport/action/artifact boundaries reject external URLs, credentials, arbitrary keys, traversal, and unsafe wrappers.'
Write-Output 'PASS: shared 03D execution envelope, bounded output/deadline, Windows Job Object cleanup, childStarted, timeout, and truthful cleanup are exercised.'
Write-Output 'PASS: one synthetic provider transaction produces shared-session readiness, DOM/AX/screenshot/request/keyboard evidence without a real browser claim.'
Write-Output 'PASS: accessibility verifier derives granular checks from evidence, ignores fabricated PASS/global manual review, and keeps axe supplementary with scanExecuted=false.'
Write-Output 'PASS: normal MCP/routing surfaces remain untouched and no package/browser installation or network call was performed.'
