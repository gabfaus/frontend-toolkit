param([switch]$SkipDistribution)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Json([string]$Launcher, [string]$Operation, [string]$ProjectRoot, [string]$InputPath) {
    $raw = (& $Launcher -Operation $Operation -ProjectRoot $ProjectRoot -InputPath $InputPath -DetectorOptionsJson '{"profile":true}' | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Detector failed: $raw" }
    return ($raw | ConvertFrom-Json)
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
$sourceLauncher = Join-Path $securityRoot 'invoke-capability.ps1'
$runtimeModule = Join-Path $securityRoot 'impeccable-static-runtime.mjs'
$lock = Get-Content -Raw (Join-Path $repoRoot 'integrations/impeccable-static-html-dependencies.lock.json') | ConvertFrom-Json
$expectedPackages = @($lock.packages | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-impeccable-static-html-golden.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Executable golden differential test failed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-impeccable-static-html-dependencies.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'D3F snapshot anti-regression failed.' }
$runtimeText = Get-Content -Raw -LiteralPath $runtimeModule
Assert-True ($runtimeText -notmatch 'function\s+(parseDocument|selectAll|parseCss|computeStyles)|compatibility|fallback') 'Reduced compatibility semantics remain in the active runtime.'
$detectorText = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'impeccable-detector.mjs')
Assert-True ($detectorText -match 'assertFullStaticHtmlExecution' -and $detectorText -match 'staticRuntimeReports') 'Full canonical static-HTML execution gate is missing.'
Assert-True ($runtimeText -match 'registerHooks' -and $runtimeText -match 'EXPECTED_PACKAGES') 'Canonical closed loader is missing.'
Assert-True ($expectedPackages.Count -eq 13) 'Dedicated lock does not contain exactly 13 packages.'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-sr3i-runtime-' + [guid]::NewGuid().ToString('N'))
$secretName = 'FTK_SR3I_RUNTIME_SYNTHETIC_SECRET'
$oldSecret = [Environment]::GetEnvironmentVariable($secretName, 'Process')
$oldNodePath = [Environment]::GetEnvironmentVariable('NODE_PATH', 'Process')
$oldLocation = (Get-Location).Path
$candidateRoot = $null
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'node_modules'), (Join-Path $fixture 'parent/node_modules'), (Join-Path $fixture 'sibling-node_modules') -Force | Out-Null
    $fake = "throw new Error('project module shadow executed');"
    foreach ($name in @('htmlparser2','css-select','css-tree','domutils')) {
        $dir = Join-Path $fixture "node_modules/$name"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'index.js'), $fake, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $dir 'package.json'), '{"name":"' + $name + '","version":"0.0.0","exports":{".":"./index.js"}}', [Text.UTF8Encoding]::new($false))
    }
    New-Item -ItemType Directory -Path (Join-Path $fixture 'node_modules/package-shadow') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'node_modules/package-shadow/package.json'), '{"name":"package-shadow","imports":{"#canonical":"./evil.js"}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture 'package.json'), '{"name":"shadow-fixture","imports":{"#runtime":"./evil.mjs"},"exports":{"./*":"./evil/*"}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture 'vite.config.js'), "throw new Error('project code must remain data');", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture 'styles.css'), '.card { color: #777; background: #fff; } .card > .cta { color: #fff !important; background: #000; }', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture 'index.html'), '<!doctype html><html><head><style>.card { color: #555; }</style><link rel="stylesheet" href="styles.css"></head><body><main id="app" class="card"><section><button class="cta" aria-label="Go">Go</button></section></main></body></html>', [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable($secretName, 'synthetic-value-must-not-cross', 'Process')
    [Environment]::SetEnvironmentVariable('NODE_PATH', (Join-Path $fixture 'node_modules'), 'Process')
    Push-Location $fixture
    $before = @(Get-ChildItem -LiteralPath $fixture -Recurse -File -Force | ForEach-Object FullName | Sort-Object)
    $result = Invoke-Json $sourceLauncher 'impeccable.detector.local' $fixture 'index.html'
    $runtime = @($result.report.staticHtmlRuntime)
    Assert-True ($runtime.Count -eq 1 -and $runtime[0].loadedPackages.Count -eq 13) 'Canonical 13-package graph was not loaded.'
    $loadedNames = @($runtime[0].loadedPackages | Sort-Object)
    $expectedNames = @($lock.packages | ForEach-Object name | Sort-Object)
    Assert-True (($loadedNames -join ',') -ceq ($expectedNames -join ',')) 'Project or ambient module shadowing changed the loaded graph.'
    Assert-True ($runtime[0].quickSortLoaded -eq $false) 'source-map-js quick-sort was loaded.'
    Assert-True (@($runtime[0].resolvedSpecifiers | Where-Object { $_.path -match 'source-map-js/lib/source-map-generator' }).Count -gt 0) 'source-map-generator closure was not observed.'
    Assert-True (@($result.report.enginesExecuted) -contains 'static-html' -and @($result.report.linkedCss) -contains 'styles.css') 'Canonical HTML/CSS analysis did not execute.'
    Assert-True ($null -ne $result.findings -and $null -ne $result.summary -and $null -ne $result.safety) 'Typed structured output is incomplete.'
    Assert-True (-not $result.safety.networkAttempted -and -not $result.safety.writesPerformed -and -not $result.safety.projectCodeExecuted) 'Static runtime crossed an effect boundary.'
    Assert-True (-not $result.safety.parentSecretsInherited -and @($result.safety.childEnvironmentNames) -notcontains $secretName) 'Parent synthetic secret crossed the child boundary.'
    $after = @(Get-ChildItem -LiteralPath $fixture -Recurse -File -Force | ForEach-Object FullName | Sort-Object)
    Assert-True (($before -join [char]10) -ceq ($after -join [char]10)) 'Static runtime wrote into the project fixture.'
    $failed = $false
    try { Invoke-Json $sourceLauncher 'impeccable.detector.local' $fixture '../outside.css' | Out-Null } catch { $failed = $true }
    Assert-True $failed 'Input traversal was not rejected.'
    Pop-Location
    if (-not $SkipDistribution) {
        $candidateRoot = Join-Path ([IO.Path]::GetTempPath()) ('ftk-sr3i-candidate-' + [guid]::NewGuid().ToString('N'))
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1') -Destination (Join-Path $candidateRoot 'plugins/frontend-toolkit') -DevelopmentWorkingTree | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Ephemeral packaged candidate build failed.' }
        $candidateLauncher = Join-Path $candidateRoot 'plugins/frontend-toolkit/security/invoke-capability.ps1'
        $candidateResult = Invoke-Json $candidateLauncher 'impeccable.detector.local' $fixture 'index.html'
        $candidateRuntime = @($candidateResult.report.staticHtmlRuntime)
        Assert-True ($candidateRuntime.Count -eq 1 -and $candidateRuntime[0].loadedPackages.Count -eq 13) 'Packaged candidate did not use the canonical graph.'
        Assert-True ($candidateRuntime[0].moduleRoot -match 'third_party[\\/]static-html-dependencies[\\/]node_modules$') 'Packaged candidate resolved outside its module root.'
        $provenance = Get-Content -Raw (Join-Path $candidateRoot 'plugins/frontend-toolkit/SNAPSHOT_PROVENANCE.json') | ConvertFrom-Json
        Assert-True ($provenance.staticHtmlRuntime.packageCount -eq 13 -and $provenance.staticHtmlRuntime.bytes -eq 3696727 -and $provenance.staticHtmlRuntime.treeSha256 -ceq $lock.snapshot.treeSha256) 'Packaged runtime provenance drifted.'
        Assert-True (@($provenance.staticHtmlRuntime.licenses).Count -eq 13) 'Packaged runtime license inventory is incomplete.'
    }
    Write-Output 'PASS: canonical static-HTML runtime, closed resolution, shadowing resistance, containment, typed output, and ephemeral distribution.'
}
finally {
    if ((Get-Location).Path -ne $oldLocation) { Set-Location $oldLocation }
    [Environment]::SetEnvironmentVariable($secretName, $oldSecret, 'Process')
    [Environment]::SetEnvironmentVariable('NODE_PATH', $oldNodePath, 'Process')
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    if ($candidateRoot -and (Test-Path -LiteralPath $candidateRoot)) { Remove-Item -LiteralPath $candidateRoot -Recurse -Force }
}