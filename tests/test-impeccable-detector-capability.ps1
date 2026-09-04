Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
$launcher = Join-Path $securityRoot 'invoke-capability.ps1'
$operationPolicyPath = Join-Path $securityRoot 'impeccable-operation-policy.json'
$effectPolicyPath = Join-Path $securityRoot 'effect-policy.json'
$detectorPath = Join-Path $securityRoot 'impeccable-detector.mjs'
$staticRuntimePath = Join-Path $securityRoot 'impeccable-static-runtime.mjs'
$upstreamSkillRoot = Join-Path $repoRoot 'external/impeccable/plugin/skills/impeccable'
$upstreamRoot = Join-Path $repoRoot 'external/impeccable'
$goldenTest = Join-Path $PSScriptRoot 'test-impeccable-static-html-golden.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $goldenTest | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Static HTML Full Engine capability cannot be promoted without a passing golden differential test.' }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    try { & $Action; throw "$Label did not fail closed." }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Label failed for the wrong reason: $($_.Exception.Message)" }
    }
}

function Invoke-Detector {
    param([hashtable]$Arguments, [string]$Label = '')
    try {
        $json = (& $launcher @Arguments | Out-String)
        return $json | ConvertFrom-Json
    } catch {
        throw "Detector invocation failed for $($Arguments.Operation) $Label`: $($_.Exception.Message)"
    }
}

function Get-FixtureState {
    param([string]$Root)
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
            Sort-Object FullName |
            ForEach-Object { '{0}|{1}' -f $_.FullName.Substring($Root.Length), (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash }
    ) -join "`n"
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-CanonicalLfBytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $stream = New-Object IO.MemoryStream
    try {
        for ($index = 0; $index -lt $Bytes.Length; $index++) {
            if ($Bytes[$index] -eq 13 -and $index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) {
                $stream.WriteByte(10)
                $index++
            } else {
                if ($Bytes[$index] -eq 13) { throw 'Reviewed upstream module contains a non-canonical lone CR byte.' }
                $stream.WriteByte($Bytes[$index])
            }
        }
        return $stream.ToArray()
    } finally { $stream.Dispose() }
}

function Get-PinnedGitBlob {
    param([Parameter(Mandatory)][string]$GitPath, [Parameter(Mandatory)][string]$Commit)
    $spec = $Commit + ':' + $GitPath
    $oid = (& git -C $upstreamRoot rev-parse $spec | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $oid -notmatch '^[0-9a-f]{40}$') { throw "Unable to resolve pinned Git blob: $GitPath" }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command git -ErrorAction Stop).Source
    $start.WorkingDirectory = $upstreamRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.Arguments = '-C ' + $upstreamRoot + ' cat-file blob ' + $oid
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $memory = New-Object IO.MemoryStream
    try {
        if (-not $process.Start()) { throw "Unable to start git cat-file for $GitPath" }
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git cat-file failed for $($GitPath): $stderr" }
        return [pscustomobject]@{ Oid = $oid; Bytes = $memory.ToArray() }
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

$operationPolicy = Get-Content -Raw -LiteralPath $operationPolicyPath | ConvertFrom-Json
$effectPolicy = Get-Content -Raw -LiteralPath $effectPolicyPath | ConvertFrom-Json
$registryPath = Join-Path $upstreamSkillRoot 'scripts/detector/registry/antipatterns.mjs'
$autocrlf = (& git -C $upstreamRoot config --get core.autocrlf | Out-String).Trim()
Assert-True ($autocrlf -ceq 'true') 'The drift fixture no longer proves the required core.autocrlf=true checkout.'
$registryBlob = Get-PinnedGitBlob 'plugin/skills/impeccable/scripts/detector/registry/antipatterns.mjs' $operationPolicy.detectorContract.upstreamCommit
$registryText = [Text.Encoding]::UTF8.GetString($registryBlob.Bytes)
$registryIds = @([regex]::Matches($registryText, "(?m)^\s+id:\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
$expectedIds = @($operationPolicy.detectorContract.canonicalRuleIds)
Assert-True ($expectedIds.Count -eq 59) 'Pinned fixture sanity changed; identity comparison below remains authoritative.'
Assert-True (($registryIds -join "`n") -ceq ($expectedIds -join "`n")) 'Safe detector canonical rule identities differ from pinned upstream.'
Assert-True ((Get-Sha256Hex $registryBlob.Bytes) -ceq $operationPolicy.detectorContract.registrySha256) 'Canonical pinned registry blob fingerprint drifted.'
$crlfDifferences = 0
foreach ($entry in @($operationPolicy.detectorContract.moduleFingerprints)) {
    $modulePath = Join-Path $upstreamSkillRoot $entry.path
    Assert-True (Test-Path -LiteralPath $modulePath -PathType Leaf) "Fingerprint module is missing: $($entry.path)"
    $gitPath = 'plugin/skills/impeccable/' + $entry.path.Replace('\', '/')
    $blob = Get-PinnedGitBlob $gitPath $operationPolicy.detectorContract.upstreamCommit
    $canonicalHash = Get-Sha256Hex $blob.Bytes
    $worktreeBytes = [IO.File]::ReadAllBytes($modulePath)
    $worktreeHash = Get-Sha256Hex $worktreeBytes
    $normalizedHash = Get-Sha256Hex (Get-CanonicalLfBytes $worktreeBytes)
    Assert-True ($blob.Oid -ceq $entry.gitBlob) "Pinned Git object drifted: $($entry.path)"
    Assert-True ($canonicalHash -ceq $entry.sha256) "Runtime policy does not contain the canonical blob SHA-256: $($entry.path)"
    Assert-True ($normalizedHash -ceq $canonicalHash) "CRLF checkout does not normalize to the pinned canonical blob: $($entry.path)"
    if ($worktreeHash -cne $canonicalHash) {
        $crlfDifferences++
        Assert-True ($entry.sha256 -cne $worktreeHash) "Runtime policy incorrectly contains the worktree CRLF hash: $($entry.path)"
    }
}
Assert-True ($crlfDifferences -gt 0) 'DevelopmentWorkingTree no longer supplies the required CRLF-vs-canonical anti-regression fixture.'
Assert-True (Test-Path -LiteralPath $staticRuntimePath -PathType Leaf) 'Canonical static HTML runtime loader is missing.'

$localOperations = @('impeccable.detector.local','impeccable.detector.project','impeccable.detector.payload','impeccable.detector.csp')
foreach ($operation in $localOperations) {
    $specific = @($operationPolicy.operations | Where-Object id -CEQ $operation)
    $common = @($effectPolicy.operations | Where-Object id -CEQ $operation)
    Assert-True ($specific.Count -eq 1 -and $common.Count -eq 1) "Detector policy registration is not unique: $operation"
    Assert-True ((@($specific[0].effects) -join ',') -ceq 'LOCAL_READ_ONLY') "Specific detector effects drifted: $operation"
    Assert-True ($common[0].status -ceq 'enabled' -and (@($common[0].effects) -join ',') -ceq 'LOCAL_READ_ONLY') "Common detector effects drifted: $operation"
}
foreach ($operation in @('impeccable.detector.loopback','impeccable.detector.external')) {
    $definition = @($effectPolicy.operations | Where-Object id -CEQ $operation)
    Assert-True ($definition.Count -eq 1 -and $definition[0].status -cne 'enabled') "$operation became executable without authorization."
}
$browserSpecific = @($operationPolicy.operations | Where-Object id -CEQ 'impeccable.detector.browser-file')
$browserCommon = @($effectPolicy.operations | Where-Object id -CEQ 'impeccable.detector.browser-file')
Assert-True ($browserSpecific.Count -eq 1 -and $browserCommon.Count -eq 1) 'Browser-file capability is not represented exactly once in both policies.'
Assert-True ((@($browserSpecific[0].effects) -join ',') -ceq 'LOCAL_READ_ONLY,PROJECT_CODE_EXECUTION') 'Browser-file effects do not match actual file:// browser behavior.'
Assert-True ((@($browserCommon[0].effects) -join ',') -ceq 'LOCAL_READ_ONLY,PROJECT_CODE_EXECUTION' -and $browserCommon[0].status -cne 'enabled') 'Browser-file became executable without a real host authorization boundary.'

$runnerText = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'impeccable-runner.ps1')
$detectorText = Get-Content -Raw -LiteralPath $detectorPath
Assert-True ($runnerText -match "--permission" -and $runnerText -match "--allow-fs-read=" -and $runnerText -notmatch "--allow-fs-write" -and $runnerText -notmatch "--allow-child-process") 'Node permission boundary no longer denies write/child effects.'
Assert-True ($detectorText -notmatch '\bfetch\s*\(' -and $detectorText -notmatch 'node:(?:http|https|net|tls|child_process)' -and $detectorText -notmatch '\beval\s*\(') 'FTK detector acquired network, process, or eval surface.'
Assert-True ($runnerText -notmatch "id = 'inline-style'|id = 'suppressed-focus'|id = 'important-overuse'") 'The reduced three-regex substitute returned.'
Assert-True ($runnerText -match '--import=' -and $runnerText -match 'impeccable-static-runtime\.mjs') 'The pinned static-HTML import graph is no longer mediated by the FTK runtime.'
Assert-True ($detectorText -match 'upstream\.detectHtml' -and $detectorText -notmatch "phase:\s*'page-patterns'.*html-patterns") 'Static-HTML regressed to a synthetic label or partial pattern scan.'
Assert-True ($detectorText -notmatch 'upstream\.detectCsp') 'CSP regressed to a second upstream walker outside the governed read path.'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-impeccable-detector-' + [Guid]::NewGuid().ToString('N'))
$outside = Join-Path ([IO.Path]::GetTempPath()) ('ftk-impeccable-outside-' + [Guid]::NewGuid().ToString('N'))
$limitFixtures = [Collections.Generic.List[string]]::new()
New-Item -ItemType Directory -Path (Join-Path $fixture 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixture '.impeccable') -Force | Out-Null
New-Item -ItemType Directory -Path $outside -Force | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $fixture 'package.json') -Encoding UTF8 -Value '{"name":"synthetic-detector-fixture"}'
    Set-Content -LiteralPath (Join-Path $fixture 'vite.config.js') -Encoding UTF8 -Value "throw new Error('project config must remain data'); export default {}"
    Set-Content -LiteralPath (Join-Path $fixture 'index.html') -Encoding UTF8 -Value '<!doctype html><html><head><link rel="stylesheet" href="styles.css"></head><body><section class="outer"><main class="card inner"><h1>Primary</h1><h3>Skipped heading</h3><p>Low contrast text</p></main></section></body></html>'
    Set-Content -LiteralPath (Join-Path $fixture 'styles.css') -Encoding UTF8 -Value '.outer { background-color: #eeeeee; border-radius: 12px; padding: 2px; } .outer .card { color: #777777; background-color: #888888; border-left: 6px solid #ff0000; border-radius: 12px; font-family: Inter, sans-serif; padding: 2px; }'
    Set-Content -LiteralPath (Join-Path $fixture 'imports.css') -Encoding UTF8 -Value '@import "./styles.css";'
    Set-Content -LiteralPath (Join-Path $fixture 'src/theme.scss') -Encoding UTF8 -Value '$accent: red; .theme { color: $accent; }'
    Set-Content -LiteralPath (Join-Path $fixture 'src/use.scss') -Encoding UTF8 -Value '@use "./theme";'
    Set-Content -LiteralPath (Join-Path $fixture 'src/forward.scss') -Encoding UTF8 -Value '@forward "./theme";'
    Set-Content -LiteralPath (Join-Path $fixture 'ignored.css') -Encoding UTF8 -Value '.ignored { animation: bounce 1s infinite; }'
    Set-Content -LiteralPath (Join-Path $fixture 'src/app.jsx') -Encoding UTF8 -Value "import '../styles.css'; export function App() { return <main className='card'>Synthetic</main>; }"
    Set-Content -LiteralPath (Join-Path $fixture 'middleware.ts') -Encoding UTF8 -Value "headers.set('Content-Security-Policy', policy);"
    Set-Content -LiteralPath (Join-Path $fixture 'DESIGN.md') -Encoding UTF8 -Value @'
---
colors:
  ink: "#111111"
typography:
  body:
    family: "Arial"
rounded:
  small: "4px"
---
# Synthetic design system
'@
    Set-Content -LiteralPath (Join-Path $fixture '.impeccable/config.json') -Encoding UTF8 -Value '{"hook":{"designSystem":{"enabled":false},"advisoryRules":"exclude"},"detector":{"ignoreRules":["side-tab"],"ignoreFiles":["ignored.css"],"ignoreValues":[{"rule":"overused-font","value":"Inter","files":["styles.css"]}],"designSystem":{"enabled":true},"advisoryRules":"include"}}'
    Set-Content -LiteralPath (Join-Path $outside 'escape.css') -Encoding UTF8 -Value '.escape { border-left: 8px solid red; }'

    $before = Get-FixtureState $fixture
    $env:FTK_DETECTOR_SYNTHETIC_SECRET = 'synthetic-not-a-secret'

    $local = Invoke-Detector @{ Operation='impeccable.detector.local'; ProjectRoot=$fixture; InputPath='styles.css'; DetectorOptionsJson='{"useProjectConfig":false,"profile":true,"viewport":{"width":390,"height":844}}' }
    Assert-True ($local.schemaVersion -eq 2 -and $local.ruleCatalog.Count -eq $expectedIds.Count) 'Local detector did not return the typed canonical catalog.'
    Assert-True ((@($local.ruleCatalog.id) -join "`n") -ceq ($expectedIds -join "`n")) 'Local detector catalog identity drifted.'
    Assert-True (@($local.findings.ruleId) -ccontains 'side-tab') 'Canonical side-tab rule did not execute on a real upstream fixture.'
    Assert-True (@($local.findings.ruleId) -ccontains 'overused-font') 'Canonical type rule did not execute.'
    Assert-True ($local.report.designSystem.applied -eq $true -and $local.report.viewport.width -eq 390 -and $local.report.viewportApplication -ceq 'browser-file-operation-only') 'Design system or honest viewport applicability was not preserved.'
    Assert-True (@($local.report.profiler).Count -gt 0 -and @($local.report.enginesExecuted) -ccontains 'regex') 'Profiler/report semantics were not preserved.'
    Assert-True (($local.safety.childEnvironmentNames -join ',') -notmatch 'FTK_DETECTOR_SYNTHETIC_SECRET') 'A parent environment name reached the detector child.'

    $html = Invoke-Detector @{ Operation='impeccable.detector.local'; ProjectRoot=$fixture; InputPath='index.html'; DetectorOptionsJson='{"useProjectConfig":false,"profile":true}' }
    Assert-True (@($html.report.linkedCss) -ccontains 'styles.css') 'Contained linked CSS was not analyzed.'
    Assert-True (@($html.findings.ruleId) -ccontains 'side-tab') 'HTML plus linked CSS did not execute canonical analytics.'
    Assert-True (@($html.report.enginesExecuted) -ccontains 'static-html') 'The pinned pure-static HTML engine did not execute.'
    Assert-True (@($html.findings.ruleId) -ccontains 'skipped-heading') 'Static-HTML DOM structure semantics were not executed.'
    Assert-True (@($html.findings.ruleId) -ccontains 'low-contrast') 'Static-HTML selector, cascade, computed-style, or contrast semantics were not executed.'
    Assert-True (@($html.report.profiler | Where-Object { $_.phase -in @('parse-html','selector-match','compute-style') }).Count -gt 0) 'Static-HTML profiler does not prove real DOM/cascade execution.'

    $project = Invoke-Detector @{ Operation='impeccable.detector.project'; ProjectRoot=$fixture; DetectorOptionsJson='{"profile":true}' }
    Assert-True ($project.report.fileCount -ge 9 -and $project.report.importGraph.edges -ge 4) 'Project import graph lost CSS @import, Sass @use, or Sass @forward semantics.'
    Assert-True ($project.report.framework.name -ceq 'Vite' -and $project.report.framework.probe -ceq 'not-performed') 'Static framework detection was lost or probed loopback.'
    Assert-True (@($project.suppressedFindings | Where-Object { $_.ruleId -ceq 'side-tab' -and $_.suppressionReason -ceq 'project-config' }).Count -gt 0) 'Config ignore semantics were not preserved as typed suppression.'
    Assert-True (@($project.findings.path | Where-Object { $_ -match 'ignored\.css' }).Count -eq 0) 'ignoreFiles semantics were not preserved.'
    Assert-True ($project.report.effectiveConfig.designSystemEnabled -eq $true -and $project.report.effectiveConfig.advisoryRules -ceq 'include') 'Detector config no longer overrides overlapping legacy hook values.'
    Assert-True ($project.report.effectiveConfig.ignoreValueCount -eq 1 -and @($project.suppressedFindings | Where-Object { $_.ruleId -ceq 'overused-font' -and $_.path -ceq 'styles.css' }).Count -gt 0) 'ignoreValues semantics were not preserved.'

    $layout = Invoke-Detector @{ Operation='impeccable.detector.local'; ProjectRoot=$fixture; InputPath='index.html'; DetectorOptionsJson='{"useProjectConfig":false,"scopes":["layout"]}' }
    Assert-True (@($layout.findings).Count -gt 0 -and @($layout.findings | Where-Object { @($_.scopes) -notcontains 'layout' }).Count -eq 0) 'Layout scope admitted a non-layout rule or did not execute.'

    $catalog = @{}; foreach ($rule in @($html.ruleCatalog)) { $catalog[$rule.id] = @($rule.engineFamilies) }
    Assert-True (($catalog['side-tab'] -join ',') -ceq 'regex,static-html,browser') 'Representative regex/static/browser family mapping drifted.'
    Assert-True (($catalog['nested-cards'] -join ',') -ceq 'static-html,browser') 'Representative static/browser family mapping drifted.'
    Assert-True (($catalog['script-error'] -join ',') -ceq 'browser') 'Representative browser-only family mapping drifted.'
    Assert-True (($catalog['low-contrast'] -join ',') -ceq 'static-html,browser,visual') 'Representative visual family mapping drifted.'

    $projectRaw = Invoke-Detector @{ Operation='impeccable.detector.project'; ProjectRoot=$fixture; DetectorOptionsJson='{"useProjectConfig":false}' }
    Assert-True (@($projectRaw.findings | Where-Object ruleId -CEQ 'side-tab' | Select-Object -ExpandProperty path -Unique).Count -ge 2) 'Upstream project semantics no longer distinguish direct CSS from HTML-linked CSS findings.'
    Assert-True (@($projectRaw.findings | Where-Object ruleId -CEQ 'side-tab' | Group-Object path | Where-Object Count -gt 1).Count -eq 0) 'Direct and linked CSS analysis introduced duplicate side-tab findings within the same upstream source path.'

    $scoped = Invoke-Detector @{ Operation='impeccable.detector.payload'; Content='.card { border-left: 6px solid red; font-family: Inter; }'; ContentType='css'; DetectorOptionsJson='{"scopes":["type"]}' } 'scope'
    Assert-True (@($scoped.findings.ruleId) -ccontains 'overused-font') 'Type scope removed an applicable canonical rule.'
    Assert-True (@($scoped.suppressedFindings | Where-Object { $_.ruleId -ceq 'side-tab' -and $_.suppressionReason -ceq 'scope' }).Count -gt 0) 'Scope suppression was not represented.'

    $inline = Invoke-Detector @{ Operation='impeccable.detector.payload'; Content='.card { border-left: 6px solid red; } /* impeccable-disable-line side-tab */'; ContentType='css' } 'inline-ignore'
    Assert-True (@($inline.suppressedFindings | Where-Object suppressionReason -CEQ 'inline-ignore').Count -gt 0) 'Inline ignore semantics were not preserved.'

    $advisoryText = '<!doctype html><html><body>one &mdash; two &mdash; three &mdash; four &mdash; five &mdash; six &mdash; seven &mdash; eight &mdash; nine</body></html>'
    $advisory = Invoke-Detector @{ Operation='impeccable.detector.payload'; Content=$advisoryText; ContentType='html' } 'advisory'
    Assert-True (@($advisory.findings | Where-Object { $_.ruleId -ceq 'em-dash-overuse' -and $_.advisory }).Count -eq 1) 'Advisory classification was not preserved.'
    Assert-True ($advisory.summary.resultCode -eq 0 -and $advisory.summary.advisory -ge 1) 'Advisory finding incorrectly changed result semantics.'

    $csp = Invoke-Detector @{ Operation='impeccable.detector.csp'; ProjectRoot=$fixture }
    Assert-True ($csp.analysis.shape -ceq 'middleware' -and @($csp.analysis.signals) -ccontains 'middleware.ts') 'Pinned CSP detection semantics were not restored.'
    Assert-True ((@($csp.report.extensionContract) -join ',') -ceq '.astro,.cjs,.cts,.html,.js,.jsx,.mjs,.mts,.svelte,.ts,.tsx,.vue') 'CSP execution extension contract diverges from its governed walker.'

    Assert-Throws { & $launcher -Operation impeccable.detector.local -ProjectRoot $fixture -InputPath '..\escape.css' | Out-Null } 'relative path|escapes' 'Traversal containment'
    Assert-Throws { & $launcher -Operation impeccable.detector.local -ProjectRoot $fixture -InputPath (Join-Path $outside 'escape.css') | Out-Null } 'relative path|absolute|escapes' 'Absolute outside-root containment'
    Assert-Throws { & $launcher -Operation impeccable.detector.local -ProjectRoot $fixture -InputPath ('..\' + (Split-Path -Leaf $outside) + '\escape.css') | Out-Null } 'relative path|escapes' 'Sibling-prefix containment'
    Assert-Throws { & $launcher -Operation impeccable.detector.payload -Content ('x' * 1048577) -ContentType css | Out-Null } 'limit|exceeds' 'Payload resource limit'
    Assert-Throws { & $launcher -Operation impeccable.detector.payload -Content '.x{}' -ContentType css -DetectorOptionsJson '{"unknown":true}' | Out-Null } 'exit code|unknown' 'Unknown option'

    Set-Content -LiteralPath (Join-Path $fixture 'escape.html') -Encoding UTF8 -Value ('<link rel="stylesheet" href="../' + (Split-Path -Leaf $outside) + '/escape.css">')
    Assert-Throws { & $launcher -Operation impeccable.detector.local -ProjectRoot $fixture -InputPath 'escape.html' | Out-Null } 'escapes|outside|exit code' 'Linked CSS escape containment'
    Remove-Item -LiteralPath (Join-Path $fixture 'escape.html')
    Set-Content -LiteralPath (Join-Path $fixture 'src/escape-import.css') -Encoding UTF8 -Value ('@import "../../' + (Split-Path -Leaf $outside) + '/escape.css";')
    Assert-Throws { & $launcher -Operation impeccable.detector.project -ProjectRoot $fixture -DetectorOptionsJson '{"useProjectConfig":false}' | Out-Null } 'escapes|outside|exit code' 'Import graph escape containment'
    Remove-Item -LiteralPath (Join-Path $fixture 'src/escape-import.css')

    $junction = Join-Path $fixture 'linked-outside'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-Throws { & $launcher -Operation impeccable.detector.project -ProjectRoot $fixture | Out-Null } 'reparse|junction|exit code' 'Reparse containment'
    [IO.Directory]::Delete($junction)

    $cspCount = Join-Path ([IO.Path]::GetTempPath()) ('ftk-csp-count-' + [Guid]::NewGuid().ToString('N')); $limitFixtures.Add($cspCount); New-Item -ItemType Directory -Path $cspCount | Out-Null
    1..201 | ForEach-Object { Set-Content -LiteralPath (Join-Path $cspCount ("f$_.js")) -Encoding UTF8 -Value 'const x = 1;' }
    Assert-Throws { & $launcher -Operation impeccable.detector.csp -ProjectRoot $cspCount | Out-Null } 'file-count|file count|exit code' 'CSP file-count limit'

    $cspBytes = Join-Path ([IO.Path]::GetTempPath()) ('ftk-csp-bytes-' + [Guid]::NewGuid().ToString('N')); $limitFixtures.Add($cspBytes); New-Item -ItemType Directory -Path $cspBytes | Out-Null
    $block = New-Object byte[] 65536; 1..129 | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $cspBytes ("f$_.js")), $block) }
    Assert-Throws { & $launcher -Operation impeccable.detector.csp -ProjectRoot $cspBytes | Out-Null } 'total byte|total-byte|exit code' 'CSP total-byte limit'

    $cspDepth = Join-Path ([IO.Path]::GetTempPath()) ('ftk-csp-depth-' + [Guid]::NewGuid().ToString('N')); $limitFixtures.Add($cspDepth); $deep = $cspDepth
    1..7 | ForEach-Object { $deep = Join-Path $deep "d$_"; New-Item -ItemType Directory -Path $deep -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $deep 'middleware.ts') -Encoding UTF8 -Value "headers.set('Content-Security-Policy', policy);"
    Assert-Throws { & $launcher -Operation impeccable.detector.csp -ProjectRoot $cspDepth | Out-Null } 'depth|exit code' 'CSP depth limit'

    $cspReparse = Join-Path ([IO.Path]::GetTempPath()) ('ftk-csp-reparse-' + [Guid]::NewGuid().ToString('N')); $limitFixtures.Add($cspReparse); New-Item -ItemType Directory -Path $cspReparse | Out-Null
    $cspJunction = Join-Path $cspReparse 'outside'; New-Item -ItemType Junction -Path $cspJunction -Target $outside | Out-Null
    Assert-Throws { & $launcher -Operation impeccable.detector.csp -ProjectRoot $cspReparse | Out-Null } 'reparse|junction|exit code' 'CSP reparse containment'
    [IO.Directory]::Delete($cspJunction)

    $browserPlan = (& $launcher -Operation impeccable.detector.browser-file -ProjectRoot $fixture -InputPath 'index.html' -DetectorOptionsJson '{"viewport":{"width":390,"height":844}}' -PlanOnly | Out-String) | ConvertFrom-Json
    Assert-True ($browserPlan.handlerInvoked -eq $false -and $browserPlan.authorizationDecision -ceq 'authorization-required') 'Browser-file plan started a handler without host authorization.'
    Assert-Throws { & $launcher -Operation impeccable.detector.browser-file -ProjectRoot $fixture -InputPath 'index.html' | Out-Null } 'AUTHORIZATION_REQUIRED|not enabled' 'Browser-file unauthorized execution'

    foreach ($operation in @('impeccable.detector.loopback','impeccable.detector.external')) {
        $plan = (& $launcher -Operation $operation -PlanOnly | Out-String) | ConvertFrom-Json
        Assert-True ($plan.handlerInvoked -eq $false -and $plan.authorizationDecision -in @('authorization-required','blocked')) "$operation plan started a handler."
        Assert-Throws { & $launcher -Operation $operation | Out-Null } 'AUTHORIZATION_REQUIRED|not enabled' "$operation unauthorized execution"
    }

    $after = Get-FixtureState $fixture
    Assert-True ($before -ceq $after) 'Detector mutated the synthetic project.'
    Assert-True ($local.safety.networkAttempted -eq $false -and $project.safety.writesPerformed -eq $false -and $project.safety.projectCodeExecuted -eq $false) 'Detector safety evidence drifted.'
} finally {
    Remove-Item Env:FTK_DETECTOR_SYNTHETIC_SECRET -ErrorAction SilentlyContinue
    $junction = Join-Path $fixture 'linked-outside'
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force }
    foreach ($root in $limitFixtures) { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

Write-Output 'PASS: Impeccable detector preserves the pinned canonical registry and mediated local file/project/payload/CSP semantics without widening effects.'
