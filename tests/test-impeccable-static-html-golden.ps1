param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Prop([psobject]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Compact($Value) { $Value | ConvertTo-Json -Depth 30 -Compress }
function RelPath([string]$Root, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($rootFull.Length + 1).Replace("\", "/")
    }
    return $pathFull.Replace("\", "/")
}
function Normalize-Finding($Finding, [string]$Root, [string]$Source) {
    $lineValue = Prop $Finding "line"
    $line = if ($null -ne $lineValue -and [int]$lineValue -gt 0) { [ordered]@{ line = [int]$lineValue; column = $null } } else { $null }
    [ordered]@{
        ruleId = if ($Source -eq "oracle") { [string](Prop $Finding "antipattern") } else { [string](Prop $Finding "ruleId") }
        severity = if (Prop $Finding "severity") { [string](Prop $Finding "severity") } else { "warning" }
        classification = if ($Source -eq "oracle") { [string](Prop $Finding "category") } else { [string](Prop $Finding "classification") }
        message = if ($Source -eq "oracle") { [string](Prop $Finding "description") } else { [string](Prop $Finding "message") }
        path = if ($Source -eq "oracle") { RelPath $Root ([string](Prop $Finding "file")) } else { [string](Prop $Finding "path") }
        location = $line
        snippet = [string](Prop $Finding "snippet")
        selector = if ($null -ne (Prop $Finding "selector")) { [string](Prop $Finding "selector") } else { $null }
        advisory = if ($Source -eq "oracle") { $false } else { [bool](Prop $Finding "advisory") }
        ignored = if ($Source -eq "oracle") { $false } else { [bool](Prop $Finding "ignored") }
        suppressed = if ($Source -eq "oracle") { $false } else { [bool](Prop $Finding "suppressed") }
        suppressionReason = if ($Source -eq "oracle") { $null } else { Prop $Finding "suppressionReason" }
        importedBy = if ($null -ne (Prop $Finding "importedBy")) { ((@((Prop $Finding "importedBy") | ForEach-Object { [string]$_ }) | Where-Object { $_ }) -join "|") } else { "" }
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$sourceRoot = Join-Path ([IO.Path]::GetTempPath()) ("ftk-golden-committed-source-" + [guid]::NewGuid().ToString("N"))
$sourceTar = Join-Path ([IO.Path]::GetTempPath()) ("ftk-golden-committed-source-" + [guid]::NewGuid().ToString("N") + ".tar")
try {
    New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
    $safeRepo = $repoRoot.Replace("\", "/")
    $fixtureSpec = "HEAD:tests/fixtures/impeccable-static-html-golden.json"
    & git -c "safe.directory=$safeRepo" -C $repoRoot cat-file -e $fixtureSpec
    if ($LASTEXITCODE -ne 0) { throw "Golden fixture is not committed in HEAD; scope/commit defect." }
    & git -c "safe.directory=$safeRepo" -C $repoRoot archive --format=tar --output=$sourceTar HEAD -- tests/fixtures/impeccable-static-html-golden.json
    if ($LASTEXITCODE -ne 0) { throw "Committed source archive could not be created." }
    & tar -xf $sourceTar -C $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw "Committed source archive could not be extracted." }
    $goldenPath = Join-Path $sourceRoot "tests/fixtures/impeccable-static-html-golden.json"
    Assert-True (Test-Path -LiteralPath $goldenPath -PathType Leaf) "Committed source archive omitted the golden fixture."
    $golden = [IO.File]::ReadAllText($goldenPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
Assert-True ($golden.schemaVersion -eq 2) "Golden schema is invalid."
Assert-True ($golden.oracle.upstreamCommit -ceq "63b04e2530f5c7b41ea83c133daab24f34912456") "Golden oracle pin is invalid."
$ignoredFields = @("finding.engine","finding.scopes","profile.*.target","profile.*.ms","runtime.moduleRoot","runtime.resolvedSpecifiers","process-specific diagnostics")
$preservedFields = @("ruleId","finding type/classification","severity","message","selector-dependent outcome","relevant file identity","line/column when present","snippet and contrast result","advisory state","suppression state")
Assert-True ((@($golden.normalizationContract.ignoredFields) -join "|") -ceq ($ignoredFields -join "|")) "Normalization ignored-field contract drifted."
Assert-True ((@($golden.normalizationContract.preservedFields) -join "|") -ceq ($preservedFields -join "|")) "Normalization preserved-field contract drifted."

& git -c "safe.directory=$safeRepo" -C $repoRoot diff --cached --quiet
Assert-True ($LASTEXITCODE -eq 0) "Golden test requires an empty Git index."

$lock = [IO.File]::ReadAllText((Join-Path $repoRoot "integrations/impeccable-static-html-dependencies.lock.json"), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$expectedPackages = @($lock.packages | ForEach-Object { [string]$_.name } | Sort-Object)
Assert-True ($expectedPackages.Count -eq 13) "Canonical lock is not exactly 13 packages."
$upstreamRoot = Join-Path $repoRoot "external/impeccable"
$upstreamHead = (& git -C $upstreamRoot rev-parse HEAD | Out-String).Trim()
Assert-True ($upstreamHead -ceq $golden.oracle.upstreamCommit) "Pinned oracle checkout HEAD drifted."

$node = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "Programs/FrontendToolkit/node-v24.20.0-win-x64/node.exe"
$oracleHelper = Join-Path $PSScriptRoot "helpers/run-impeccable-static-html-oracle.mjs"
$runtimeModule = Join-Path $repoRoot "plugin/frontend-toolkit/security/impeccable-static-runtime.mjs"
$skillRoot = Join-Path $upstreamRoot ".agent/skills/impeccable"
$launcher = Join-Path $repoRoot "plugin/frontend-toolkit/security/invoke-capability.ps1"
Assert-True (Test-Path -LiteralPath $node -PathType Leaf) "Locked Node 24.20.0 is unavailable."
Assert-True (Test-Path -LiteralPath $oracleHelper -PathType Leaf) "Oracle helper is missing."
Assert-True (Test-Path -LiteralPath $skillRoot -PathType Container) "Pinned oracle skill root is missing."

. (Join-Path $repoRoot "plugin/frontend-toolkit/security/impeccable-runner.ps1")
$oracleEnvironment = [ordered]@{}
foreach ($name in @("SystemRoot","TEMP","TMP")) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if (-not [string]::IsNullOrWhiteSpace($value)) { $oracleEnvironment[$name] = $value }
}
$oracleEnvironment["IMPECCABLE_NO_UPDATE_CHECK"] = "1"
$oracleEnvironment["IMPECCABLE_NO_TELEMETRY"] = "1"
$oracleEnvironment["DO_NOT_TRACK"] = "1"

$representedFamilies = @($golden.cases | ForEach-Object { @($_.semanticFeatures) }) | Sort-Object -Unique
foreach ($family in @($golden.requiredSemanticFamilies)) {
    Assert-True ($representedFamilies -contains $family) "Required semantic family missing: $family"
}

function Invoke-LegacyReducedShim {
    param([psobject]$Case)
    # Safe test double: the historical reduced path had no DOM/CSS semantics.
    return @()
}

$caseResults = @()
foreach ($case in @($golden.cases)) {
    $caseRoot = Join-Path ([IO.Path]::GetTempPath()) ("ftk-golden-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        foreach ($file in @($case.files)) {
            Assert-True (-not [IO.Path]::IsPathRooted([string]$file.path)) "Absolute golden file path: $($case.id)"
            Assert-True ([string]$file.path -notmatch "(^|[\\/])\.\.([\\/]|$)") "Traversal in golden file path: $($case.id)"
            $full = [IO.Path]::GetFullPath((Join-Path $caseRoot ([string]$file.path)))
            Assert-True ($full.StartsWith(([IO.Path]::GetFullPath($caseRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) "Golden file escaped case root: $($case.id)"
            $parent = Split-Path -Parent $full
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($full, [string]$file.content, [Text.UTF8Encoding]::new($false))
        }
        $entry = Join-Path $caseRoot ([string]$case.entrypoint)
        Assert-True (Test-Path -LiteralPath $entry -PathType Leaf) "Golden entrypoint missing: $($case.id)"
        $caseSource = (@($case.files | ForEach-Object { [string]$_.content }) -join "`n")
        $features = @($case.semanticFeatures)
        if ($features -contains "selector-descendant") { Assert-True ($caseSource -match "\.[A-Za-z-]+\s+\.") "Descendant selector is not present: $($case.id)" }
        if ($features -contains "selector-child") { Assert-True ($caseSource -match ">") "Child selector is not present: $($case.id)" }
        if ($features -contains "selector-attribute") { Assert-True ($caseSource -match "\[[^]]+\]") "Attribute selector is not present: $($case.id)" }
        if ($features -contains "selector-advanced-first-child") { Assert-True ($caseSource -match ":first-child") "Advanced selector is not present: $($case.id)" }
        if ($features -contains "cascade-specificity") { Assert-True ($caseSource -match "#app|section\[data-role") "Specificity selector is not present: $($case.id)" }
        if ($features -contains "important") { Assert-True ($caseSource -match "!important") "Important declaration is not present: $($case.id)" }
        if ($features -contains "malformed-recoverable-html") { Assert-True ($caseSource -match "<p[^>]*>[^<]+</main>" -and $caseSource -notmatch "</p>") "Malformed recoverable HTML is not present: $($case.id)" }

        $oracleProcess = Invoke-ImpeccableChildProcess -Executable $node -ArgumentList @($oracleHelper,$runtimeModule,$skillRoot,$entry) -WorkingDirectory $repoRoot -Environment $oracleEnvironment -StandardInputText ""
        Assert-True ($oracleProcess.exitCode -eq 0) ("Oracle failed for " + $case.id + ": " + ($oracleProcess.stderr -join ([Environment]::NewLine)))
        $oracle = (($oracleProcess.stdout -join ([Environment]::NewLine)) | ConvertFrom-Json)
        Assert-True ($oracle.schemaVersion -eq 1) "Oracle response schema invalid: $($case.id)"
        Assert-True ((@($oracle.runtime.loadedPackages | Sort-Object) -join "|") -ceq ($expectedPackages -join "|")) "Oracle did not load canonical 13 packages: $($case.id)"
        Assert-True (-not $oracle.runtime.quickSortLoaded) "Oracle reached quick-sort: $($case.id)"

        $options = if ($null -eq $case.options) { '{"profile":true}' } else { Compact $case.options }
        $ftkRaw = & $launcher -Operation "impeccable.detector.local" -ProjectRoot $caseRoot -InputPath ([string]$case.entrypoint) -DetectorOptionsJson $options | Out-String
        Assert-True ($LASTEXITCODE -eq 0) ("FTK failed for " + $case.id + ": " + $ftkRaw)
        $ftk = $ftkRaw | ConvertFrom-Json
        Assert-True (@($ftk.report.enginesExecuted) -contains "static-html") "FTK static-html engine did not execute: $($case.id)"
        Assert-True (@($ftk.report.staticHtmlRuntime).Count -eq 1) "FTK canonical runtime report missing: $($case.id)"
        Assert-True ((@($ftk.report.staticHtmlRuntime[0].loadedPackages | Sort-Object) -join "|") -ceq ($expectedPackages -join "|")) "FTK did not load canonical 13 packages: $($case.id)"
        Assert-True (-not $ftk.report.staticHtmlRuntime[0].quickSortLoaded) "FTK reached quick-sort: $($case.id)"

        $oracleProfileIds = @($oracle.profile | ForEach-Object { [string]$_.ruleId })
        $ftkProfileIds = @($ftk.report.profiler | ForEach-Object { [string]$_.ruleId })
        foreach ($ruleId in @($case.requiredProfileRuleIds)) {
            Assert-True ($oracleProfileIds -contains $ruleId) "Oracle missed semantic phase ${ruleId}: $($case.id)"
            Assert-True ($ftkProfileIds -contains $ruleId) "FTK missed semantic phase ${ruleId}: $($case.id)"
        }
        $oracleLinked = @($oracle.profile | Where-Object { $_.ruleId -ceq "inline-linked-stylesheet" } | ForEach-Object { [string]$_.detail })
        $ftkLinked = @($ftk.report.linkedCss | ForEach-Object { [string]$_ })
        Assert-True (($oracleLinked -join "|") -ceq (@($case.requiredLinkedCss) -join "|")) "Oracle linked-CSS result drifted: $($case.id)"
        Assert-True (($ftkLinked -join "|") -ceq (@($case.requiredLinkedCss) -join "|")) "FTK linked-CSS result drifted: $($case.id)"

        $oracleNormalized = @($oracle.findings | ForEach-Object { Normalize-Finding $_ $caseRoot "oracle" })
        $ftkNormalized = @($ftk.findings | ForEach-Object { Normalize-Finding $_ $caseRoot "ftk" })
        $expectedNormalized = @($case.expectedNormalized.findings | ForEach-Object { $_ })
        $oracleJson = Compact $oracleNormalized
        $expectedJson = Compact $expectedNormalized
        $ftkJson = Compact $ftkNormalized
        Assert-True ($oracleJson -ceq $expectedJson) ("Oracle expectation mismatch for " + $case.id + "; expected data must be oracle-derived. oracle=" + $oracleJson + " expected=" + $expectedJson)
        if ($oracleJson -cne $ftkJson) {
            $delta = @(Compare-Object -ReferenceObject ($oracleJson -split ",") -DifferenceObject ($ftkJson -split ",") | ForEach-Object { $_.InputObject })
            throw ("GOLDEN DIFFERENTIAL MISMATCH case=" + $case.id + " feature=" + (@($case.semanticFeatures) -join ",") + " oracle=" + $oracleJson + " ftk=" + $ftkJson + " normalized-delta=" + ($delta -join " | "))
        }
        $legacy = @((Invoke-LegacyReducedShim $case) | ForEach-Object { $_ })
        Assert-True ((Compact $legacy) -cne $oracleJson) "Reduced-shim double matched canonical output: $($case.id)"
        $caseResults += [pscustomobject]@{ id=$case.id; oracleFindings=@($oracleNormalized).Count; ftkFindings=@($ftkNormalized).Count }
        Write-Output ("PASS case=" + $case.id + " oracle-findings=" + @($oracleNormalized).Count + " ftk-findings=" + @($ftkNormalized).Count)
    } finally {
        if (Test-Path -LiteralPath $caseRoot) { Remove-Item -LiteralPath $caseRoot -Recurse -Force }
    }
}
Assert-True ($caseResults.Count -eq @($golden.cases).Count) "Not every golden case executed."
Assert-True (@($caseResults | Where-Object { $_.oracleFindings -gt 0 }).Count -eq $caseResults.Count) "Golden cases did not exercise analytical findings."
$expectedRuleIds = @($golden.cases | ForEach-Object { @($_.expectedNormalized.findings | ForEach-Object { [string]$_.ruleId }) }) | Sort-Object -Unique
foreach ($requiredMiss in @($golden.legacyShimContract.requiredMisses)) { Assert-True ($expectedRuleIds -contains $requiredMiss) "Legacy shim miss is not represented by an expected analytical result: $requiredMiss" }
Write-Output ("OLD SHIM REGRESSION DETECTION PASS cases=" + $caseResults.Count)
& git -C $repoRoot diff --cached --quiet
Assert-True ($LASTEXITCODE -eq 0) "Golden test changed the Git index."
Write-Output ("GOLDEN DIFFERENTIAL CORPUS PASS cases=" + $caseResults.Count + " oracle=executed ftk=executed normalized=contract-enforced source=committed-head")
} finally {
    if (Test-Path -LiteralPath $sourceTar) { Remove-Item -LiteralPath $sourceTar -Force }
    if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
}
