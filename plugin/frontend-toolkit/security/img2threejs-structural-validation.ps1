Set-StrictMode -Version Latest

$script:Img2ThreejsStructuralMaxBytes = 1MB
$script:Img2ThreejsStructuralMaxEntries = 4096
$script:Img2ThreejsStructuralMaxLabelLength = 64

function Skip-Img2ThreejsJsonWhitespace {
    param([Parameter(Mandatory)][hashtable]$State)

    while ($State.Index -lt $State.Length) {
        $code = [int][char]$State.Text[$State.Index]
        if ($code -notin @(0x20, 0x09, 0x0A, 0x0D)) { break }
        $State.Index++
    }
}

function Read-Img2ThreejsJsonString {
    param([Parameter(Mandatory)][hashtable]$State)

    if ($State.Index -ge $State.Length -or $State.Text[$State.Index] -ne '"') {
        throw "Expected a JSON string at character $($State.Index)."
    }
    $State.Index++
    $builder = New-Object System.Text.StringBuilder
    while ($State.Index -lt $State.Length) {
        $character = $State.Text[$State.Index]
        $State.Index++
        if ($character -eq '"') { return $builder.ToString() }
        if ([int][char]$character -lt 0x20) {
            throw 'JSON strings cannot contain unescaped control characters.'
        }
        if ([int][char]$character -ne 0x5C) {
            [void]$builder.Append($character)
            continue
        }

        if ($State.Index -ge $State.Length) { throw 'The JSON string ends inside an escape sequence.' }
        $escape = $State.Text[$State.Index]
        $State.Index++
        switch ($escape) {
            '"' { [void]$builder.Append('"'); continue }
            '\' { [void]$builder.Append([char]0x5C); continue }
            '/' { [void]$builder.Append('/'); continue }
            'b' { [void]$builder.Append([char]0x08); continue }
            'f' { [void]$builder.Append([char]0x0C); continue }
            'n' { [void]$builder.Append([char]0x0A); continue }
            'r' { [void]$builder.Append([char]0x0D); continue }
            't' { [void]$builder.Append([char]0x09); continue }
            'u' {
                if ($State.Index + 4 -gt $State.Length) { throw 'The JSON string has a truncated Unicode escape.' }
                $hex = $State.Text.Substring($State.Index, 4)
                if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw 'The JSON string has an invalid Unicode escape.' }
                $State.Index += 4
                $unit = [Convert]::ToInt32($hex, 16)
                if ($unit -ge 0xD800 -and $unit -le 0xDBFF) {
                    if ($State.Index + 6 -gt $State.Length -or
                        [int][char]$State.Text[$State.Index] -ne 0x5C -or
                        $State.Text[$State.Index + 1] -ne 'u') {
                        throw 'A high surrogate in a JSON string must be followed by a low surrogate.'
                    }
                    $lowHex = $State.Text.Substring($State.Index + 2, 4)
                    if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw 'The JSON string has an invalid low surrogate.' }
                    $low = [Convert]::ToInt32($lowHex, 16)
                    if ($low -lt 0xDC00 -or $low -gt 0xDFFF) { throw 'The JSON string has an invalid low surrogate.' }
                    $State.Index += 6
                    $codePoint = 0x10000 + (($unit - 0xD800) * 0x400) + ($low - 0xDC00)
                    [void]$builder.Append([char]::ConvertFromUtf32($codePoint))
                    continue
                }
                if ($unit -ge 0xDC00 -and $unit -le 0xDFFF) { throw 'A JSON string cannot contain an unpaired low surrogate.' }
                [void]$builder.Append([char]$unit)
                continue
            }
            default { throw "The JSON string has an unsupported escape sequence: \$escape" }
        }
    }
    throw 'The JSON string is truncated.'
}

function Read-Img2ThreejsJsonScalar {
    param([Parameter(Mandatory)][hashtable]$State)

    if ($State.Index -ge $State.Length) { throw 'The JSON value is truncated.' }
    $character = $State.Text[$State.Index]
    if ($character -eq '"') {
        return [pscustomobject]@{ Kind = 'String'; Value = (Read-Img2ThreejsJsonString -State $State) }
    }
    if ($character -in @('{','[')) {
        throw 'Nested JSON objects and arrays are denied; the structural map has maximum depth 1.'
    }
    foreach ($literal in @(
        @{ Text = 'true'; Kind = 'Boolean'; Value = $true },
        @{ Text = 'false'; Kind = 'Boolean'; Value = $false },
        @{ Text = 'null'; Kind = 'Null'; Value = $null }
    )) {
        if ($State.Index + $literal.Text.Length -le $State.Length -and
            $State.Text.Substring($State.Index, $literal.Text.Length) -ceq $literal.Text) {
            $State.Index += $literal.Text.Length
            return [pscustomobject]@{ Kind = $literal.Kind; Value = $literal.Value }
        }
    }

    $remaining = $State.Text.Substring($State.Index)
    $match = [regex]::Match($remaining, '\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
    if (-not $match.Success) { throw "Invalid JSON scalar at character $($State.Index)." }
    $lexeme = $match.Value
    $State.Index += $lexeme.Length
    $number = 0.0
    if (-not [double]::TryParse($lexeme, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw 'JSON numbers must be finite and representable.'
    }
    $integer = 0L
    if ($lexeme -cnotmatch '[.eE]' -and [long]::TryParse($lexeme, [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$integer)) {
        return [pscustomobject]@{ Kind = 'Integer'; Value = $integer }
    }
    return [pscustomobject]@{ Kind = 'Number'; Value = $number }
}

function ConvertFrom-Img2ThreejsStrictJsonObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'The structural JSON input must be a file.' }
    if ($item.Length -gt $script:Img2ThreejsStructuralMaxBytes) {
        throw "The structural JSON input exceeds $script:Img2ThreejsStructuralMaxBytes bytes."
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -gt $script:Img2ThreejsStructuralMaxBytes) {
        throw "The structural JSON input exceeds $script:Img2ThreejsStructuralMaxBytes bytes."
    }
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    try { $text = $utf8.GetString($bytes) }
    catch [Text.DecoderFallbackException] { throw 'The structural JSON input is not valid UTF-8.' }
    if ($text.Length -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    $state = @{ Text = $text; Index = 0; Length = $text.Length }
    Skip-Img2ThreejsJsonWhitespace -State $state
    if ($state.Index -ge $state.Length -or $state.Text[$state.Index] -ne '{') {
        throw 'The structural JSON root must be an object.'
    }
    $state.Index++
    $entries = New-Object System.Collections.Generic.List[object]
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    Skip-Img2ThreejsJsonWhitespace -State $state
    if ($state.Index -lt $state.Length -and $state.Text[$state.Index] -eq '}') {
        $state.Index++
    } else {
        while ($true) {
            $key = Read-Img2ThreejsJsonString -State $state
            if (-not $keys.Add($key)) { throw "The structural JSON contains duplicate key '$key'." }
            if ($entries.Count -ge $script:Img2ThreejsStructuralMaxEntries) {
                throw "The structural JSON exceeds $script:Img2ThreejsStructuralMaxEntries entries."
            }
            Skip-Img2ThreejsJsonWhitespace -State $state
            if ($state.Index -ge $state.Length -or $state.Text[$state.Index] -ne ':') {
                throw "Expected ':' after JSON key '$key'."
            }
            $state.Index++
            Skip-Img2ThreejsJsonWhitespace -State $state
            $value = Read-Img2ThreejsJsonScalar -State $state
            $entries.Add([pscustomobject]@{ Key = $key; Scalar = $value })
            Skip-Img2ThreejsJsonWhitespace -State $state
            if ($state.Index -ge $state.Length) { throw 'The structural JSON object is truncated.' }
            if ($state.Text[$state.Index] -eq '}') { $state.Index++; break }
            if ($state.Text[$state.Index] -ne ',') { throw 'Expected a comma or closing brace in the structural JSON object.' }
            $state.Index++
            Skip-Img2ThreejsJsonWhitespace -State $state
        }
    }
    Skip-Img2ThreejsJsonWhitespace -State $state
    if ($state.Index -ne $state.Length) { throw 'The structural JSON contains trailing garbage.' }
    return $entries.ToArray()
}

function Assert-Img2ThreejsNodeKey {
    param([Parameter(Mandatory)][string]$Key)

    if ($Key -cnotmatch '^(0|[1-9][0-9]{0,9})$') { throw "Unknown or non-canonical node key '$Key'." }
    $node = 0L
    if (-not [long]::TryParse($Key, [ref]$node) -or $node -gt [int]::MaxValue) {
        throw "Node key '$Key' exceeds the supported node identifier range."
    }
    return [int]$node
}

function Assert-Img2ThreejsRegionLabel {
    param([Parameter(Mandatory)]$Scalar)

    if ($Scalar.Kind -cne 'String') { throw 'A regions value must be a string.' }
    $value = [string]$Scalar.Value
    if (-not $value.Normalize([Text.NormalizationForm]::FormC).Equals($value, [StringComparison]::Ordinal)) {
        throw 'A regions value must use canonical Unicode NFC normalization.'
    }
    if ($value.Length -lt 1 -or $value.Length -gt $script:Img2ThreejsStructuralMaxLabelLength -or
        $value -cnotmatch '^[\p{Ll}][\p{Ll}\p{Nd}_-]*$') {
        throw 'A regions value must be a lowercase data identifier using letters, digits, underscore, or hyphen.'
    }
    return $value
}

function Assert-Img2ThreejsSectionRegionLabel {
    param([Parameter(Mandatory)]$Scalar)

    if ($Scalar.Kind -cne 'String') { throw 'A section-regions value must be a string.' }
    $value = [string]$Scalar.Value
    if ($value.Length -lt 1 -or $value.Length -gt $script:Img2ThreejsStructuralMaxLabelLength -or
        $value -cnotmatch '^[A-Z][A-Z0-9_]*$') {
        throw 'A section-regions value must be an uppercase ASCII TypeScript identifier component.'
    }
    return $value
}

function Assert-Img2ThreejsSpokeCount {
    param([Parameter(Mandatory)]$Scalar)

    if ($Scalar.Kind -cne 'Integer') { throw 'A spokes value must be a JSON integer.' }
    $value = [long]$Scalar.Value
    if ($value -lt 3 -or $value -gt 4096) { throw 'A spokes value must be between 3 and 4096.' }
    return [int]$value
}

function Assert-Img2ThreejsCellSize {
    param([Parameter(Mandatory)]$Scalar)

    if ($Scalar.Kind -notin @('Integer','Number')) { throw 'A cell-sizes value must be a JSON number.' }
    $value = [double]$Scalar.Value
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0.0 -or $value -gt 1.0) {
        throw 'A cell-sizes value must be finite and greater than 0 through 1 metre.'
    }
    return $value
}

function ConvertFrom-Img2ThreejsNodeMap {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateSet('Regions','CellSizes','SectionRegions','Spokes')][string]$Kind,
        [switch]$RequireEntries
    )

    $entries = @(ConvertFrom-Img2ThreejsStrictJsonObject -LiteralPath $LiteralPath)
    if ($RequireEntries -and -not $entries.Count) { throw "$Kind cannot be an empty object." }
    $values = [ordered]@{}
    foreach ($entry in $entries) {
        $node = Assert-Img2ThreejsNodeKey -Key $entry.Key
        switch ($Kind) {
            'Regions' { $value = Assert-Img2ThreejsRegionLabel -Scalar $entry.Scalar }
            'CellSizes' { $value = Assert-Img2ThreejsCellSize -Scalar $entry.Scalar }
            'SectionRegions' { $value = Assert-Img2ThreejsSectionRegionLabel -Scalar $entry.Scalar }
            'Spokes' { $value = Assert-Img2ThreejsSpokeCount -Scalar $entry.Scalar }
        }
        $values[[string]$node] = $value
    }
    return $values
}

function ConvertFrom-Img2ThreejsRegionsJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)
    return ConvertFrom-Img2ThreejsNodeMap -LiteralPath $LiteralPath -Kind Regions
}

function ConvertFrom-Img2ThreejsCellSizesJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)
    return ConvertFrom-Img2ThreejsNodeMap -LiteralPath $LiteralPath -Kind CellSizes
}

function ConvertFrom-Img2ThreejsSectionRegionsJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)
    return ConvertFrom-Img2ThreejsNodeMap -LiteralPath $LiteralPath -Kind SectionRegions -RequireEntries
}

function ConvertFrom-Img2ThreejsSpokesJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)
    return ConvertFrom-Img2ThreejsNodeMap -LiteralPath $LiteralPath -Kind Spokes -RequireEntries
}

function Get-Img2ThreejsCharacterNodeSet {
    param([Parameter(Mandatory)][AllowEmptyCollection()][long[]]$CharacterNodes)

    if (-not $CharacterNodes.Count) { throw 'CHARACTER_NODES cannot be empty.' }
    if ($CharacterNodes.Count -gt $script:Img2ThreejsStructuralMaxEntries) {
        throw "CHARACTER_NODES exceeds $script:Img2ThreejsStructuralMaxEntries entries."
    }
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($node in $CharacterNodes) {
        if ($node -lt 0 -or $node -gt [int]::MaxValue) { throw 'CHARACTER_NODES contains an invalid node identifier.' }
        if (-not $set.Add([int]$node)) { throw "CHARACTER_NODES contains duplicate node $node." }
    }
    return $set
}

function Assert-Img2ThreejsMapSubset {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Map,
        [Parameter(Mandatory)]$AllowedNodes,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($key in $Map.Keys) {
        if (-not $AllowedNodes.Contains([int]$key)) {
            throw "$Name references node $key, which is absent from CHARACTER_NODES."
        }
    }
}

function Assert-Img2ThreejsSameNodeKeys {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Left,
        [Parameter(Mandatory)][Collections.IDictionary]$Right
    )
    $leftKeys = @($Left.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    $rightKeys = @($Right.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    if (($leftKeys -join ',') -cne ($rightKeys -join ',')) {
        throw 'CHARACTER_SECTION_REGIONS_JSON and CHARACTER_SPOKES_JSON must reference exactly the same nodes.'
    }
}

function ConvertFrom-Img2ThreejsStructuralData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][long[]]$CharacterNodes,
        [string]$RegionsPath,
        [string]$CellSizesPath,
        [string]$SectionRegionsPath,
        [string]$SpokesPath
    )

    $nodeSet = Get-Img2ThreejsCharacterNodeSet -CharacterNodes $CharacterNodes
    $hasRegions = -not [string]::IsNullOrEmpty($RegionsPath)
    $hasCellSizes = -not [string]::IsNullOrEmpty($CellSizesPath)
    $hasSectionRegions = -not [string]::IsNullOrEmpty($SectionRegionsPath)
    $hasSpokes = -not [string]::IsNullOrEmpty($SpokesPath)
    if ($hasSectionRegions -ne $hasSpokes) {
        throw 'Stage 1 requires both CHARACTER_SECTION_REGIONS_JSON and CHARACTER_SPOKES_JSON.'
    }

    $regions = if ($hasRegions) { ConvertFrom-Img2ThreejsRegionsJson -LiteralPath $RegionsPath } else { $null }
    $cellSizes = if ($hasCellSizes) { ConvertFrom-Img2ThreejsCellSizesJson -LiteralPath $CellSizesPath } else { $null }
    $sectionRegions = if ($hasSectionRegions) { ConvertFrom-Img2ThreejsSectionRegionsJson -LiteralPath $SectionRegionsPath } else { $null }
    $spokes = if ($hasSpokes) { ConvertFrom-Img2ThreejsSpokesJson -LiteralPath $SpokesPath } else { $null }

    if ($null -ne $regions) { Assert-Img2ThreejsMapSubset -Map $regions -AllowedNodes $nodeSet -Name 'CHARACTER_REGIONS_JSON' }
    if ($null -ne $cellSizes) { Assert-Img2ThreejsMapSubset -Map $cellSizes -AllowedNodes $nodeSet -Name 'CHARACTER_CELL_SIZES_JSON' }
    if ($null -ne $sectionRegions) { Assert-Img2ThreejsSameNodeKeys -Left $sectionRegions -Right $spokes }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        characterNodes = @($CharacterNodes | ForEach-Object { [int]$_ })
        regions = $regions
        cellSizes = $cellSizes
        sectionRegions = $sectionRegions
        spokes = $spokes
    }
}
