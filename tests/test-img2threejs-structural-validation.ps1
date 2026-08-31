Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$modulePath = Join-Path $repoRoot 'plugin/frontend-toolkit/security/img2threejs-structural-validation.ps1'
. $modulePath

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    try { & $Action; throw "$Label did not fail closed." }
    catch {
        if ($_.Exception.Message -eq "$Label did not fail closed.") { throw }
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Label returned the wrong error: $($_.Exception.Message)" }
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-img2threejs-structural-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    function Write-Fixture {
        param([string]$Name, [string]$Text)
        $path = Join-Path $fixture $Name
        $Text | Set-Content -LiteralPath $path -Encoding UTF8 -NoNewline
        return $path
    }

    $regions = Write-Fixture 'regions.json' '{"0":"torso","9":"cabe\u00e7a"}'
    $cells = Write-Fixture 'cells.json' '{"0":1,"9":0.0015}'
    $sectionRegions = Write-Fixture 'section-regions.json' '{"0":"BODY","2":"LEFT_ARM","9":"HEAD","10":"KNEE_PADS"}'
    $spokes = Write-Fixture 'spokes.json' '{"0":3,"2":64,"9":192,"10":4096}'
    $parsed = ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @(0,9) -RegionsPath $regions `
        -CellSizesPath $cells -SectionRegionsPath $sectionRegions -SpokesPath $spokes
    if ($parsed.schemaVersion -ne 1) { throw 'Structural schema version drifted.' }
    $expectedUnicodeRegion = 'cabe' + [char]0x00E7 + 'a'
    if ($parsed.regions['9'] -cne $expectedUnicodeRegion) { throw 'Legitimate NFC Unicode region data was not preserved.' }
    if ($parsed.cellSizes['9'] -ne 0.0015) { throw 'Legitimate fractional cell size was not preserved.' }
    if ($parsed.spokes['0'] -ne 3 -or $parsed.spokes['10'] -ne 4096) { throw 'Spoke boundaries were not preserved.' }
    if ($parsed.sectionRegions['2'] -cne 'LEFT_ARM') { throw 'Multiple Stage 1 nodes were not preserved.' }

    $minimalRegions = Write-Fixture 'minimal-regions.json' '{}'
    $minimalCells = Write-Fixture 'minimal-cells.json' '{}'
    $minimal = ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @(7) -RegionsPath $minimalRegions -CellSizesPath $minimalCells
    if ($null -eq $minimal.regions -or $null -eq $minimal.cellSizes) { throw 'Present empty optional maps became absent.' }
    if ($minimal.regions.Count -ne 0 -or $minimal.cellSizes.Count -ne 0) { throw 'Legitimate empty optional maps changed.' }

    $duplicate = Write-Fixture 'duplicate.json' '{"0":"torso","0":"head"}'
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $duplicate | Out-Null } 'duplicate key' 'duplicate JSON key'
    $unknown = Write-Fixture 'unknown.json' '{"node":"torso"}'
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $unknown | Out-Null } 'Unknown or non-canonical' 'unknown property'
    $arrayRoot = Write-Fixture 'array-root.json' '[]'
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $arrayRoot | Out-Null } 'root must be an object' 'wrong root type'

    $wrongRegionType = Write-Fixture 'wrong-region-type.json' '{"0":7}'
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $wrongRegionType | Out-Null } 'must be a string' 'wrong region type'
    $wrongCellType = Write-Fixture 'wrong-cell-type.json' '{"0":"0.1"}'
    Assert-Throws { ConvertFrom-Img2ThreejsCellSizesJson $wrongCellType | Out-Null } 'must be a JSON number' 'wrong cell type'
    $wrongSectionType = Write-Fixture 'wrong-section-type.json' '{"0":true}'
    Assert-Throws { ConvertFrom-Img2ThreejsSectionRegionsJson $wrongSectionType | Out-Null } 'must be a string' 'wrong section type'
    $floatSpoke = Write-Fixture 'float-spoke.json' '{"0":3.0}'
    Assert-Throws { ConvertFrom-Img2ThreejsSpokesJson $floatSpoke | Out-Null } 'JSON integer' 'non-integer spoke'

    foreach ($case in @(
        @{ Name = 'cell-zero.json'; Text = '{"0":0}'; Function = 'Cell'; Pattern = 'greater than 0' },
        @{ Name = 'cell-negative.json'; Text = '{"0":-0.1}'; Function = 'Cell'; Pattern = 'greater than 0' },
        @{ Name = 'cell-high.json'; Text = '{"0":1.0001}'; Function = 'Cell'; Pattern = 'through 1' },
        @{ Name = 'spoke-low.json'; Text = '{"0":2}'; Function = 'Spoke'; Pattern = 'between 3 and 4096' },
        @{ Name = 'spoke-high.json'; Text = '{"0":4097}'; Function = 'Spoke'; Pattern = 'between 3 and 4096' }
    )) {
        $path = Write-Fixture $case.Name $case.Text
        if ($case.Function -eq 'Cell') {
            Assert-Throws { ConvertFrom-Img2ThreejsCellSizesJson $path | Out-Null } $case.Pattern $case.Name
        } else {
            Assert-Throws { ConvertFrom-Img2ThreejsSpokesJson $path | Out-Null } $case.Pattern $case.Name
        }
    }

    foreach ($key in @('01','-1','+1','2147483648')) {
        $invalidId = Write-Fixture ('invalid-id-' + [guid]::NewGuid().ToString('N') + '.json') ('{"' + $key + '":3}')
        Assert-Throws { ConvertFrom-Img2ThreejsSpokesJson $invalidId | Out-Null } '(non-canonical|range)' "invalid identifier $key"
    }

    $danglingRegion = Write-Fixture 'dangling-region.json' '{"2":"arm"}'
    Assert-Throws { ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @(0,1) -RegionsPath $danglingRegion | Out-Null } 'absent from CHARACTER_NODES' 'nonexistent Stage 2 node'
    $danglingCell = Write-Fixture 'dangling-cell.json' '{"4":0.002}'
    Assert-Throws { ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @(0,1) -CellSizesPath $danglingCell | Out-Null } 'absent from CHARACTER_NODES' 'cell-size CHARACTER_NODES inconsistency'
    Assert-Throws { ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @(0,0) | Out-Null } 'duplicate node' 'duplicate CHARACTER_NODES'
    Assert-Throws { ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @() | Out-Null } 'cannot be empty' 'empty CHARACTER_NODES'

    $mismatchRegions = Write-Fixture 'mismatch-section.json' '{"0":"BODY","1":"ARM"}'
    $mismatchSpokes = Write-Fixture 'mismatch-spokes.json' '{"0":64}'
    Assert-Throws { ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @(0) -SectionRegionsPath $mismatchRegions -SpokesPath $mismatchSpokes | Out-Null } 'exactly the same nodes' 'internal Stage 1 reference mismatch'
    Assert-Throws { ConvertFrom-Img2ThreejsStructuralData -CharacterNodes @(0) -SectionRegionsPath $mismatchRegions | Out-Null } 'requires both' 'half-configured Stage 1'
    $emptyObject = Write-Fixture 'empty.json' '{}'
    Assert-Throws { ConvertFrom-Img2ThreejsSectionRegionsJson $emptyObject | Out-Null } 'cannot be an empty object' 'empty required Stage 1 map'

    $tooManyPairs = 0..4096 | ForEach-Object { '"' + $_ + '":3' }
    $tooMany = Write-Fixture 'too-many.json' ('{' + ($tooManyPairs -join ',') + '}')
    Assert-Throws { ConvertFrom-Img2ThreejsSpokesJson $tooMany | Out-Null } 'exceeds 4096 entries' 'excessive cardinality'
    $nested = Write-Fixture 'nested.json' '{"0":{"nested":{"again":3}}}'
    Assert-Throws { ConvertFrom-Img2ThreejsSpokesJson $nested | Out-Null } 'maximum depth 1' 'excessive depth'
    $control = Write-Fixture 'control.json' '{"0":"head\u0001"}'
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $control | Out-Null } 'lowercase data identifier' 'escaped control character'
    $rawControlText = '{"0":"head' + [char]0x01 + '"}'
    $rawControl = Write-Fixture 'raw-control.json' $rawControlText
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $rawControl | Out-Null } 'unescaped control' 'raw control character'
    $oversized = Write-Fixture 'oversized.json' ('{' + (' ' * (1MB + 1)) + '}')
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $oversized | Out-Null } 'exceeds 1048576 bytes' 'oversized JSON'
    $invalidUtf8 = Join-Path $fixture 'invalid-utf8.json'
    [IO.File]::WriteAllBytes($invalidUtf8, [byte[]]@(0x7B,0x22,0x30,0x22,0x3A,0x22,0xC3,0x28,0x22,0x7D))
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $invalidUtf8 | Out-Null } 'not valid UTF-8' 'invalid UTF-8'
    $truncated = Write-Fixture 'truncated.json' '{"0":"torso"'
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $truncated | Out-Null } 'truncated' 'truncated JSON'
    $trailing = Write-Fixture 'trailing.json' '{"0":"torso"} garbage'
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $trailing | Out-Null } 'trailing garbage' 'trailing garbage'
    foreach ($token in @('NaN','Infinity','-Infinity')) {
        $nonFinite = Write-Fixture ('nonfinite-' + [guid]::NewGuid().ToString('N') + '.json') ('{"0":' + $token + '}')
        Assert-Throws { ConvertFrom-Img2ThreejsCellSizesJson $nonFinite | Out-Null } 'Invalid JSON scalar' "non-finite token $token"
    }

    $decomposed = Write-Fixture 'decomposed.json' "{`"0`":`"cabec$([char]0x0327)a`"}"
    Assert-Throws { ConvertFrom-Img2ThreejsRegionsJson $decomposed | Out-Null } 'NFC normalization' 'non-canonical Unicode'

    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell AST parser rejected the module: $($errors[0].Message)" }
    $moduleText = Get-Content -Raw -LiteralPath $modulePath
    foreach ($forbidden in @('Invoke-Expression','Start-Process','Invoke-WebRequest','Invoke-RestMethod','Import-Module','Add-Type','System.Diagnostics.Process','powershell.exe','pwsh.exe','cmd.exe','bash')) {
        if ($moduleText.Contains($forbidden)) { throw "Structural validator contains forbidden execution/network surface: $forbidden" }
    }
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -Recurse -Force -LiteralPath $fixture }
}

Write-Output 'PASS: strict parser rejects duplicate keys, invalid syntax/types, nesting, trailing data, controls, and excessive cardinality.'
Write-Output 'PASS: all four upstream-derived maps preserve legitimate minimal/full data and enforce identifiers and numeric boundaries.'
Write-Output 'PASS: Stage 2 maps are consistent with CHARACTER_NODES and Stage 1 region/spoke references match exactly.'
Write-Output 'PASS: validator AST is valid and exposes no shell, module, subprocess, or network execution surface.'
