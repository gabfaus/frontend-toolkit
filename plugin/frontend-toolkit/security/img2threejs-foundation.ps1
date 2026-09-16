Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Img2ThreejsGlbMaximumBytes = 512MB
$script:Img2ThreejsGlbMaximumJsonBytes = 16MB
$script:Img2ThreejsHedsMaximumBytes = 512MB
$script:Img2ThreejsHedsMaximumHeaderBytes = 64KB
$script:Img2ThreejsNpyMaximumHeaderBytes = 64KB
$script:Img2ThreejsTypescriptMaximumBytes = 16MB
$script:Img2ThreejsVerifierMaximumBytes = 1MB
$script:Img2ThreejsMaximumSourceFiles = 200000
$script:Img2ThreejsMaximumSourceBytes = 2GB

function Get-Img2ThreejsGlbConfigSchema {
    [CmdletBinding()]
    param()

    [ordered]@{
        CHARACTER_GLB                  = @{ Kind = 'project-path'; Required = $true;  Access = 'read' }
        CHARACTER_DIFFUSE              = @{ Kind = 'diffuse-path'; Required = $false; Access = 'read';  Default = 'work/baseline-textures/01-texture_diffuse.png' }
        CHARACTER_DEMO_ID              = @{ Kind = 'slug';         Required = $true }
        CHARACTER_NODES                = @{ Kind = 'node-list';    Required = $true }
        CHARACTER_LEVELS               = @{ Kind = 'level-list';   Required = $true }
        CHARACTER_BIN_DIR              = @{ Kind = 'project-path'; Required = $false; Access = 'read-write'; Default = 'public/head' }
        CHARACTER_OUT_PREFIX           = @{ Kind = 'project-path'; Required = $false; Access = 'write'; Default = 'public/head/sdf-surfaces' }
        CHARACTER_WORKDIR              = @{ Kind = 'project-path'; Required = $false; Access = 'write'; Default = 'work/head' }
        CHARACTER_WORK_TAG             = @{ Kind = 'work-tag';     Required = $false; Default = '' }
        CHARACTER_CODEC                = @{ Kind = 'project-code-path'; Required = $false; Access = 'execute-project-code'; Default = 'src/demos/girl-character/surfaceCodec.ts' }
        CHARACTER_CODEC_IMPORT         = @{ Kind = 'module-import'; Required = $false; Default = './surfaceCodec' }
        CHARACTER_REGIONS_JSON         = @{ Kind = 'optional-project-path'; Required = $false; Access = 'read'; Default = '' }
        CHARACTER_CELL_SIZES_JSON      = @{ Kind = 'optional-project-path'; Required = $false; Access = 'read'; Default = '' }
        CHARACTER_SECTION_REGIONS_JSON = @{ Kind = 'optional-project-path'; Required = $false; Access = 'read'; Default = '' }
        CHARACTER_SPOKES_JSON          = @{ Kind = 'optional-project-path'; Required = $false; Access = 'read'; Default = '' }
        CHARACTER_CROSS_SECTIONS       = @{ Kind = 'optional-project-path'; Required = $false; Access = 'write'; Default = '' }
        CHARACTER_DEST_X2              = @{ Kind = 'optional-project-path'; Required = $false; Access = 'write'; Default = '' }
        CHARACTER_DEST_X3              = @{ Kind = 'optional-project-path'; Required = $false; Access = 'write'; Default = '' }
        CHARACTER_DEST_DEFAULT         = @{ Kind = 'optional-project-path'; Required = $false; Access = 'write'; Default = '' }
        CHARACTER_SLICES               = @{ Kind = 'positive-integer'; Required = $false; Default = '40' }
        CHARACTER_ALLOW_BASELINE_UV    = @{ Kind = 'opt-in-flag'; Required = $false; Default = '' }
        CHARACTER_UV_SLACK             = @{ Kind = 'unit-float'; Required = $false; Default = '0.002' }
    }
}

function Get-Img2ThreejsPathComparison {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Assert-Img2ThreejsSafeRelativePathSyntax {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Name = 'img2threejs path'
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "$Name cannot be empty."
    }
    if ($RelativePath -match '[\x00-\x1f\x7f*?"<>|;&`$]') {
        throw "$Name contains an unsafe path character."
    }
    if ($RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\') -or
        $RelativePath -match '^[A-Za-z]:') {
        throw "$Name must be relative."
    }
    $normalized = $RelativePath.Replace([char]92, [char]47)
    $parts = @($normalized -split '/')
    if (@($parts | Where-Object { $_ -eq '..' }).Count) {
        throw "$Name escapes its authorized root through traversal."
    }
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.') {
            throw "$Name contains an empty or current-directory segment."
        }
        if ($part.EndsWith('.') -or $part.EndsWith(' ')) {
            throw "$Name contains a Windows-ambiguous segment."
        }
        if ($part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "$Name contains a reserved Windows device name."
        }
    }
    return $normalized
}

function Test-Img2ThreejsPathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate
    )

    $separator = [IO.Path]::DirectorySeparatorChar
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([char]92, [char]47))
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $comparison = Get-Img2ThreejsPathComparison
    return $candidateFull.Equals($rootFull, $comparison) -or
        $candidateFull.StartsWith($rootFull + $separator, $comparison)
}

function Assert-Img2ThreejsNoExistingReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([char]92, [char]47))
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $relative = $candidateFull.Substring($rootFull.Length).TrimStart([char[]]@([char]92, [char]47))
    $current = $rootFull
    $parts = if ($relative) { $relative -split '[\\/]' } else { @() }
    foreach ($part in @('.') + @($parts)) {
        if ($part -ne '.') { $current = Join-Path $current $part }
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -Force -LiteralPath $current
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Reparse points are not allowed in an img2threejs path boundary: ' + $current)
        }
    }
}

function Resolve-Img2ThreejsContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$RequireJsonLeaf
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'The img2threejs boundary root must be an existing directory.'
    }
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'An img2threejs relative path cannot be empty.'
    }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw ('Absolute img2threejs paths are denied: ' + $RelativePath)
    }
    $null = Assert-Img2ThreejsSafeRelativePathSyntax -RelativePath $RelativePath -Name 'img2threejs relative path'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $RelativePath.Contains(':')) {
        throw ('Drive-relative paths and alternate data streams are denied: ' + $RelativePath)
    }

    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([char[]]@([char]92, [char]47))
    $candidateFull = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $rootFull -Candidate $candidateFull) -or
        $candidateFull.Equals($rootFull, (Get-Img2ThreejsPathComparison))) {
        throw ('The img2threejs path escapes its authorized root: ' + $RelativePath)
    }
    if ($RequireJsonLeaf -and [IO.Path]::GetExtension($candidateFull) -cne '.json') {
        throw 'An img2threejs state target must have a .json extension.'
    }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $rootFull -Candidate $candidateFull
    return $candidateFull
}

function Resolve-Img2ThreejsStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$StatePath
    )

    if ([IO.Path]::IsPathRooted($StatePath)) {
        throw ('Absolute img2threejs state paths are denied: ' + $StatePath)
    }
    $normalized = $StatePath.Replace([char]92, [char]47)
    if (-not ($normalized -ceq '.img2threejs' -or $normalized.StartsWith('.img2threejs/', [StringComparison]::Ordinal))) {
        throw 'The state path must be relative to the project and start with .img2threejs/.'
    }
    $stateRelative = $normalized.Substring('.img2threejs'.Length).TrimStart('/')
    $authorizedRoot = Join-Path $ProjectRoot '.img2threejs'
    if (-not (Test-Path -LiteralPath $authorizedRoot)) {
        # Resolution remains non-mutating. A future enabled handler must create this root itself,
        # then call this function again immediately before opening or replacing the state file.
        $projectFull = (Resolve-Path -LiteralPath $ProjectRoot).Path
        $authorizedFull = [IO.Path]::GetFullPath((Join-Path $projectFull '.img2threejs'))
        if (-not (Test-Img2ThreejsPathWithinRoot -Root $projectFull -Candidate $authorizedFull)) {
            throw 'The authorized state root escapes the project root.'
        }
        if (-not $stateRelative) { throw 'The state path must name a JSON file below .img2threejs/.' }
        $candidate = [IO.Path]::GetFullPath((Join-Path $authorizedFull $stateRelative))
        if (-not (Test-Img2ThreejsPathWithinRoot -Root $authorizedFull -Candidate $candidate)) {
            throw ('The img2threejs state path escapes its authorized root: ' + $StatePath)
        }
        if ([IO.Path]::GetExtension($candidate) -cne '.json') {
            throw 'An img2threejs state target must have a .json extension.'
        }
        Assert-Img2ThreejsNoExistingReparsePoint -Root $projectFull -Candidate $authorizedFull
        return $candidate
    }
    return Resolve-Img2ThreejsContainedPath -Root $authorizedRoot -RelativePath $stateRelative -RequireJsonLeaf
}

function ConvertFrom-Img2ThreejsConfigScalar {
    param(
        [Parameter(Mandatory)][string]$RawValue,
        [Parameter(Mandatory)][int]$LineNumber
    )

    $value = $RawValue.Trim()
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or
        ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
        $quote = $value[0]
        $value = $value.Substring(1, $value.Length - 2)
        if ($value.Contains([string]$quote)) {
            throw "Config line $LineNumber contains an embedded quote; escapes are intentionally unsupported."
        }
    } elseif ($value -match '[\s#]') {
        throw "Config line $LineNumber must quote values containing whitespace or #."
    }
    if ($value.Contains('`') -or $value.Contains('$(') -or $value.Contains("`n") -or $value.Contains("`r")) {
        throw "Config line $LineNumber contains shell syntax or a multiline value."
    }
    if ($value -match '[\x00-\x1f\x7f]') { throw "Config line $LineNumber contains a control character." }
    return $value
}

function ConvertFrom-Img2ThreejsJsonGlbConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Get-Command ConvertFrom-Img2ThreejsStrictJsonObject -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'img2threejs-structural-validation.ps1')
    }
    $rawValues = [ordered]@{}
    foreach ($entry in @(ConvertFrom-Img2ThreejsStrictJsonObject -LiteralPath $LiteralPath)) {
        if ($entry.Scalar.Kind -cne 'String') {
            throw "JSON config key $($entry.Key) must have a string value."
        }
        $value = [string]$entry.Scalar.Value
        if ($value -match '[\x00-\x1f\x7f]') { throw "JSON config key $($entry.Key) contains a control character." }
        $rawValues[$entry.Key] = $value
    }
    return $rawValues
}

function Get-Img2ThreejsRawGlbConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ([IO.Path]::GetExtension($LiteralPath) -ceq '.json') {
        return ConvertFrom-Img2ThreejsJsonGlbConfig -LiteralPath $LiteralPath
    }
    $rawValues = [ordered]@{}
    $lines = @(Get-Content -LiteralPath $LiteralPath)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineNumber = $index + 1
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $match = [regex]::Match($line, '^([A-Z][A-Z0-9_]*)=(.*)$')
        if (-not $match.Success) { throw "Config line $lineNumber is not a structural KEY=VALUE assignment." }
        $key = $match.Groups[1].Value
        if ($rawValues.Contains($key)) { throw "Config line $lineNumber duplicates key $key." }
        $rawValues[$key] = ConvertFrom-Img2ThreejsConfigScalar -RawValue $match.Groups[2].Value -LineNumber $lineNumber
    }
    return $rawValues
}

function ConvertFrom-Img2ThreejsGlbConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $projectFull = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $configFull = Resolve-Img2ThreejsContainedPath -Root $projectFull -RelativePath $LiteralPath
    if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) {
        throw ('img2threejs config does not exist: ' + $LiteralPath)
    }
    $schema = Get-Img2ThreejsGlbConfigSchema
    $rawValues = Get-Img2ThreejsRawGlbConfig -LiteralPath $configFull
    foreach ($key in @($rawValues.Keys)) {
        if (-not $schema.Contains($key)) { throw "Config uses unknown key $key." }
    }

    foreach ($key in $schema.Keys) {
        $definition = $schema[$key]
        if (-not $rawValues.Contains($key) -and $definition.ContainsKey('Default')) {
            $rawValues[$key] = [string]$definition.Default
        }
        if ($definition.Required -and (-not $rawValues.Contains($key) -or [string]::IsNullOrWhiteSpace($rawValues[$key]))) {
            throw ('Missing required img2threejs config key: ' + $key)
        }
    }

    $typed = [ordered]@{}
    $environment = [ordered]@{}
    foreach ($key in $schema.Keys) {
        if (-not $rawValues.Contains($key)) { continue }
        $definition = $schema[$key]
        $value = [string]$rawValues[$key]
        switch ($definition.Kind) {
            { $_ -in @('project-path','project-code-path','optional-project-path','diffuse-path') } {
                if ($definition.Kind -eq 'diffuse-path' -and $value -in @('none','neutral','embedded','glb')) {
                    $typed[$key] = $value
                    $environment[$key] = $value
                    break
                }
                if (-not $value -and $definition.Kind -eq 'optional-project-path') {
                    $typed[$key] = ''
                    $environment[$key] = ''
                    break
                }
                $placeholder = '${IMG2THREEJS_SHOWCASE_ROOT}'
                if ($value.StartsWith($placeholder, [StringComparison]::Ordinal)) {
                    $value = $value.Substring($placeholder.Length).TrimStart([char]92, [char]47)
                } elseif ($value.Contains('$')) {
                    throw ($key + ' contains an unsupported variable expansion.')
                }
                $resolved = Resolve-Img2ThreejsContainedPath -Root $projectFull -RelativePath $value
                $typed[$key] = $resolved
                $environment[$key] = $value.Replace([char]92, [char]47)
                break
            }
            'slug' {
                if ($value -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "$key must be a lowercase filesystem-safe slug." }
                $typed[$key] = $value; $environment[$key] = $value; break
            }
            'node-list' {
                $tokens = @($value -split ' ' | Where-Object { $_ })
                if (-not $tokens.Count -or @($tokens | Where-Object { $_ -cnotmatch '^(0|[1-9][0-9]*)$' }).Count) {
                    throw "$key must be a space-separated list of non-negative integers."
                }
                $nodes = @($tokens | ForEach-Object { [int]$_ })
                if (@($nodes | Sort-Object -Unique).Count -ne $nodes.Count) { throw "$key cannot contain duplicate nodes." }
                $typed[$key] = $nodes; $environment[$key] = ($nodes -join ' '); break
            }
            'level-list' {
                $levels = @($value -split ' ' | Where-Object { $_ })
                if (-not $levels.Count -or @($levels | Where-Object { $_ -notin @('x2','x3','default') }).Count) {
                    throw "$key may contain only x2, x3, and default."
                }
                if (@($levels | Sort-Object -Unique).Count -ne $levels.Count) { throw "$key cannot contain duplicate levels." }
                $typed[$key] = $levels; $environment[$key] = ($levels -join ' '); break
            }
            'module-import' {
                if ($value -cnotmatch '^\./[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $value -match '(^|/)\.\.(/|$)') {
                    throw "$key must be a relative ./ module specifier without traversal."
                }
                $typed[$key] = $value; $environment[$key] = $value; break
            }
            'work-tag' {
                if ($value -and $value -cnotmatch '^-[a-z0-9][a-z0-9._-]{0,63}$') { throw "$key must be empty or a filesystem-safe -tag." }
                $typed[$key] = $value; $environment[$key] = $value; break
            }
            'positive-integer' {
                $number = 0
                if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1 -or $number -gt 4096) {
                    throw "$key must be an integer between 1 and 4096."
                }
                $typed[$key] = $number; $environment[$key] = [string]$number; break
            }
            'opt-in-flag' {
                if ($value -notin @('','1')) { throw "$key must be empty or exactly 1." }
                $typed[$key] = ($value -eq '1'); $environment[$key] = $value; break
            }
            'unit-float' {
                $number = 0.0
                if (-not [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
                    [double]::IsNaN($number) -or [double]::IsInfinity($number) -or
                    $number -lt 0.0 -or $number -gt 1.0) {
                    throw "$key must be a number between 0 and 1 using invariant notation."
                }
                $typed[$key] = $number; $environment[$key] = $number.ToString([Globalization.CultureInfo]::InvariantCulture); break
            }
            default { throw ('Unhandled img2threejs schema kind: ' + $definition.Kind) }
        }
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        projectRoot = $projectFull
        values = [pscustomobject]$typed
        environment = [pscustomobject]$environment
    }
}

function Get-Img2ThreejsObjectProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-Img2ThreejsExactBytes {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Count,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    if ($Count -lt 0 -or $Count -gt [int]::MaxValue) { throw $FailureMessage }
    $bytes = New-Object byte[] ([int]$Count)
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -le 0) { throw $FailureMessage }
        $offset += $read
    }
    return ,$bytes
}

function Resolve-Img2ThreejsGlbReadPath {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$ProjectRoot
    )

    $item = Get-Item -Force -LiteralPath $LiteralPath -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'CHARACTER_GLB must be a file.' }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'CHARACTER_GLB cannot be a reparse point.'
    }
    $canonical = (Resolve-Path -LiteralPath $item.FullName).Path
    if ($ProjectRoot) {
        $project = (Resolve-Path -LiteralPath $ProjectRoot).Path
        if (-not (Test-Img2ThreejsPathWithinRoot -Root $project -Candidate $canonical)) {
            throw 'CHARACTER_GLB escapes the authorized project root.'
        }
        Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $canonical
    }
    return $canonical
}

function Get-Img2ThreejsGlbStructuralDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$ProjectRoot
    )

    $canonical = Resolve-Img2ThreejsGlbReadPath -LiteralPath $LiteralPath -ProjectRoot $ProjectRoot
    $item = Get-Item -Force -LiteralPath $canonical
    if ($item.Length -lt 20 -or $item.Length -gt $script:Img2ThreejsGlbMaximumBytes) {
        throw 'CHARACTER_GLB is outside the FTK size boundary.'
    }

    $stream = New-Object IO.FileStream($canonical, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $chunks = New-Object 'System.Collections.Generic.List[object]'
    $jsonBytes = $null
    $binLength = 0L
    $jsonOffset = $null
    $binOffset = $null
    try {
        $header = Read-Img2ThreejsExactBytes -Stream $stream -Count 12 -FailureMessage 'CHARACTER_GLB has a truncated header.'
        if ([Text.Encoding]::ASCII.GetString($header, 0, 4) -cne 'glTF') {
            throw 'CHARACTER_GLB does not have glTF magic.'
        }
        if ([BitConverter]::ToUInt32($header, 4) -ne 2) {
            throw 'Only binary glTF version 2 is supported.'
        }
        $declaredLength = [uint64][BitConverter]::ToUInt32($header, 8)
        if ($declaredLength -ne [uint64]$item.Length) {
            throw 'CHARACTER_GLB declared length does not match the file length.'
        }

        $offset = 12L
        $chunkIndex = 0
        while ($offset -lt $declaredLength) {
            if ($declaredLength - $offset -lt 8) { throw 'CHARACTER_GLB has a truncated chunk header.' }
            $chunkHeader = Read-Img2ThreejsExactBytes -Stream $stream -Count 8 -FailureMessage 'CHARACTER_GLB has a truncated chunk header.'
            $chunkLength = [uint64][BitConverter]::ToUInt32($chunkHeader, 0)
            $chunkType = [uint32][BitConverter]::ToUInt32($chunkHeader, 4)
            if (($chunkLength % 4) -ne 0) { throw 'CHARACTER_GLB chunk length is not 4-byte aligned.' }
            $next = $offset + 8L + $chunkLength
            if ($next -gt $declaredLength) { throw 'CHARACTER_GLB chunk bounds exceed the declared file length.' }
            $record = [pscustomobject][ordered]@{
                index = $chunkIndex
                offset = $offset
                length = $chunkLength
                type = $chunkType
            }
            $chunks.Add($record)

            if ($chunkType -eq [uint32]0x4E4F534A) {
                if ($chunkIndex -ne 0) { throw 'CHARACTER_GLB JSON chunk must be first.' }
                if ($null -ne $jsonBytes) { throw 'CHARACTER_GLB contains more than one JSON chunk.' }
                if ($chunkLength -lt 2 -or $chunkLength -gt $script:Img2ThreejsGlbMaximumJsonBytes) {
                    throw 'CHARACTER_GLB JSON chunk is outside the FTK resource boundary.'
                }
                $jsonOffset = $offset + 8L
                $jsonBytes = Read-Img2ThreejsExactBytes -Stream $stream -Count $chunkLength -FailureMessage 'CHARACTER_GLB JSON chunk is truncated.'
            } elseif ($chunkType -eq [uint32]0x004E4942) {
                if ($null -ne $binOffset) { throw 'CHARACTER_GLB contains more than one BIN chunk.' }
                $binOffset = $offset + 8L
                $binLength = [int64]$chunkLength
                $null = $stream.Seek([int64]$chunkLength, [IO.SeekOrigin]::Current)
            } else {
                $null = $stream.Seek([int64]$chunkLength, [IO.SeekOrigin]::Current)
            }
            $offset = $next
            $chunkIndex++
        }

        if ($stream.Position -ne [int64]$declaredLength) { throw 'CHARACTER_GLB parser did not consume the declared file length.' }
        if ($null -eq $jsonBytes) { throw 'CHARACTER_GLB does not contain a JSON chunk.' }
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        try { $jsonText = $utf8.GetString($jsonBytes) }
        catch [Text.DecoderFallbackException] { throw 'CHARACTER_GLB JSON chunk is not valid UTF-8.' }
        $jsonText = $jsonText.TrimEnd([char[]]@(0x20,0x00,0x09,0x0A,0x0D))
        try { $document = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop }
        catch { throw ('CHARACTER_GLB JSON chunk is invalid: ' + $_.Exception.Message) }
        if ($null -eq $document -or $document -is [ValueType] -or $document -is [string]) {
            throw 'CHARACTER_GLB JSON root must be an object.'
        }
        $asset = Get-Img2ThreejsObjectProperty -InputObject $document -Name 'asset'
        $assetVersion = Get-Img2ThreejsObjectProperty -InputObject $asset -Name 'version'
        if ($null -eq $assetVersion -or [string]$assetVersion -cne '2.0') {
            throw 'CHARACTER_GLB asset.version must be exactly 2.0.'
        }

        return [pscustomobject][ordered]@{
            path = $canonical
            fileLength = [int64]$item.Length
            declaredLength = [int64]$declaredLength
            document = $document
            jsonText = $jsonText
            jsonOffset = $jsonOffset
            jsonLength = $jsonBytes.Length
            binOffset = $binOffset
            binLength = $binLength
            chunks = $chunks.ToArray()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-Img2ThreejsGlbComponentSize {
    param([Parameter(Mandatory)][int]$ComponentType)
    switch ($ComponentType) {
        5120 { return 1 }
        5121 { return 1 }
        5122 { return 2 }
        5123 { return 2 }
        5125 { return 4 }
        5126 { return 4 }
        default { throw "Unsupported glTF accessor componentType: $ComponentType" }
    }
}

function Get-Img2ThreejsGlbTypeComponentCount {
    param([Parameter(Mandatory)][string]$Type)
    switch ($Type) {
        'SCALAR' { return 1 }
        'VEC2' { return 2 }
        'VEC3' { return 3 }
        'VEC4' { return 4 }
        'MAT2' { return 4 }
        'MAT3' { return 9 }
        'MAT4' { return 16 }
        default { throw "Unsupported glTF accessor type: $Type" }
    }
}

function Assert-Img2ThreejsFiniteNumber {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Name)
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "$Name must be a finite number."
    }
    return $number
}

function ConvertTo-Img2ThreejsGlbInteger {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name,
        [long]$Minimum = 0
    )
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "$Name must be a JSON integer." }
    $number = 0L
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        $floating = [double]$Value
        if ([double]::IsNaN($floating) -or [double]::IsInfinity($floating) -or [Math]::Truncate($floating) -ne $floating) { throw "$Name must be a JSON integer." }
    }
    try { $number = [long]$Value } catch { throw "$Name must be a JSON integer." }
    if ($number -lt $Minimum) { throw "$Name is below the supported minimum." }
    return $number
}

function Get-Img2ThreejsGlbBufferViewInfo {
    param(
        [Parameter(Mandatory)]$Glb,
        [Parameter(Mandatory)][int]$BufferViewIndex,
        [Parameter(Mandatory)][string]$Purpose
    )

    $bufferViews = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'bufferViews')
    $buffers = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'buffers')
    if ($BufferViewIndex -lt 0 -or $BufferViewIndex -ge $bufferViews.Count) {
        throw "$Purpose references an invalid bufferView index."
    }
    if (-not $buffers.Count -or $null -eq $Glb.binOffset) { throw "$Purpose requires an embedded BIN chunk." }
    $view = $bufferViews[$BufferViewIndex]
    $viewExtensions = Get-Img2ThreejsObjectProperty -InputObject $view -Name 'extensions'
    if ($null -ne (Get-Img2ThreejsObjectProperty -InputObject $viewExtensions -Name 'EXT_meshopt_compression')) {
        throw "$Purpose uses an unsupported compressed bufferView format: EXT_meshopt_compression."
    }
    $bufferIndex = Get-Img2ThreejsObjectProperty -InputObject $view -Name 'buffer'
    $bufferIndex = ConvertTo-Img2ThreejsGlbInteger -Value $bufferIndex -Name "$Purpose buffer index"
    if ($bufferIndex -ne 0 -or $bufferIndex -ge $buffers.Count) { throw "$Purpose references an unsupported buffer index." }
    $buffer = $buffers[$bufferIndex]
    $bufferUri = Get-Img2ThreejsObjectProperty -InputObject $buffer -Name 'uri'
    if (-not [string]::IsNullOrEmpty([string]$bufferUri)) { throw "$Purpose references an external buffer URI." }
    $bufferLength = ConvertTo-Img2ThreejsGlbInteger -Value (Get-Img2ThreejsObjectProperty -InputObject $buffer -Name 'byteLength') -Name "$Purpose buffer byteLength"
    if ($bufferLength -gt $Glb.binLength) { throw "$Purpose buffer byteLength exceeds the embedded BIN chunk." }
    $offsetValue = Get-Img2ThreejsObjectProperty -InputObject $view -Name 'byteOffset'
    $viewOffset = if ($null -eq $offsetValue) { 0L } else { ConvertTo-Img2ThreejsGlbInteger -Value $offsetValue -Name "$Purpose byteOffset" }
    $viewLength = ConvertTo-Img2ThreejsGlbInteger -Value (Get-Img2ThreejsObjectProperty -InputObject $view -Name 'byteLength') -Name "$Purpose byteLength" -Minimum 1
    if ($viewOffset + $viewLength -gt $bufferLength -or
        $viewOffset + $viewLength -gt $Glb.binLength) {
        throw "$Purpose bufferView bounds are invalid."
    }
    return [pscustomobject][ordered]@{ index = $BufferViewIndex; offset = $viewOffset; length = $viewLength; bufferLength = $bufferLength }
}

function Get-Img2ThreejsGlbAccessorInfo {
    param(
        [Parameter(Mandatory)]$Glb,
        [Parameter(Mandatory)][int]$AccessorIndex,
        [Parameter(Mandatory)][string]$Purpose,
        [string]$ExpectedType,
        [switch]$RequireMinMax
    )

    $accessors = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'accessors')
    if ($AccessorIndex -lt 0 -or $AccessorIndex -ge $accessors.Count) { throw "$Purpose references an invalid accessor index." }
    $accessor = $accessors[$AccessorIndex]
    $extensions = Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'extensions'
    foreach ($unsupported in @('EXT_meshopt_compression')) {
        if ($null -ne (Get-Img2ThreejsObjectProperty -InputObject $extensions -Name $unsupported)) {
            throw "$Purpose uses an unsupported compressed accessor format: $unsupported."
        }
    }
    if ($null -ne (Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'sparse')) {
        throw "$Purpose uses sparse accessors, which the Phase 1 parser cannot process."
    }
    $type = [string](Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'type')
    if ($ExpectedType -and $type -cne $ExpectedType) { throw "$Purpose must use accessor type $ExpectedType." }
    $componentType = [int](ConvertTo-Img2ThreejsGlbInteger -Value (Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'componentType') -Name "$Purpose componentType")
    $componentSize = Get-Img2ThreejsGlbComponentSize -ComponentType $componentType
    $componentCount = Get-Img2ThreejsGlbTypeComponentCount -Type $type
    $count = ConvertTo-Img2ThreejsGlbInteger -Value (Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'count') -Name "$Purpose count" -Minimum 1
    if ($count -gt 100000000) { throw "$Purpose has an invalid accessor count." }
    $viewIndex = Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'bufferView'
    if ($null -eq $viewIndex) { throw "$Purpose accessor has no bufferView." }
    $view = Get-Img2ThreejsGlbBufferViewInfo -Glb $Glb -BufferViewIndex ([int]$viewIndex) -Purpose $Purpose
    $accessorOffsetValue = Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'byteOffset'
    $accessorOffset = if ($null -eq $accessorOffsetValue) { 0L } else { ConvertTo-Img2ThreejsGlbInteger -Value $accessorOffsetValue -Name "$Purpose byteOffset" }
    $elementBytes = [long]$componentSize * $componentCount
    $strideValue = Get-Img2ThreejsObjectProperty -InputObject $Glb.document.bufferViews[[int]$viewIndex] -Name 'byteStride'
    $stride = if ($null -eq $strideValue) { $elementBytes } else { ConvertTo-Img2ThreejsGlbInteger -Value $strideValue -Name "$Purpose byteStride" -Minimum 1 }
    if ($stride -lt $elementBytes -or $stride -gt 255) { throw "$Purpose has an invalid byteStride." }
    $requiredBytes = $stride * ($count - 1L) + $elementBytes
    if ($accessorOffset -lt 0 -or $accessorOffset + $requiredBytes -gt $view.length) {
        throw "$Purpose accessor payload exceeds its bufferView bounds."
    }
    if ($RequireMinMax) {
        $minimum = @(Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'min')
        $maximum = @(Get-Img2ThreejsObjectProperty -InputObject $accessor -Name 'max')
        if ($minimum.Count -lt $componentCount -or $maximum.Count -lt $componentCount) {
            throw "$Purpose requires POSITION min/max metadata."
        }
        for ($index = 0; $index -lt $componentCount; $index++) {
            $minValue = Assert-Img2ThreejsFiniteNumber -Value $minimum[$index] -Name "$Purpose.min[$index]"
            $maxValue = Assert-Img2ThreejsFiniteNumber -Value $maximum[$index] -Name "$Purpose.max[$index]"
            if ($minValue -gt $maxValue) { throw "$Purpose has inverted min/max bounds." }
        }
    }
    return [pscustomobject][ordered]@{
        index = $AccessorIndex
        type = $type
        componentType = $componentType
        componentSize = $componentSize
        componentCount = $componentCount
        count = $count
        bufferView = $view.index
        byteOffset = $accessorOffset
        byteLength = $requiredBytes
    }
}

function Assert-Img2ThreejsGlbPipelineGeometry {
    param(
        [Parameter(Mandatory)]$Glb,
        [Parameter(Mandatory)][int[]]$CharacterNodes,
        [switch]$RequireNormal,
        [switch]$RequireTexCoord
    )

    $nodes = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'nodes')
    $meshes = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'meshes')
    foreach ($nodeIndex in $CharacterNodes) {
        if ($nodeIndex -lt 0 -or $nodeIndex -ge $nodes.Count) { throw "CHARACTER_NODES references missing node $nodeIndex." }
        $node = $nodes[$nodeIndex]
        $meshIndexValue = Get-Img2ThreejsObjectProperty -InputObject $node -Name 'mesh'
        if ($null -eq $meshIndexValue) { throw "Configured GLB node $nodeIndex has no mesh." }
        $meshIndex = [int](ConvertTo-Img2ThreejsGlbInteger -Value $meshIndexValue -Name "node $nodeIndex mesh index")
        if ($meshIndex -lt 0 -or $meshIndex -ge $meshes.Count) { throw "Configured GLB node $nodeIndex references a missing mesh." }
        $primitives = @(Get-Img2ThreejsObjectProperty -InputObject $meshes[$meshIndex] -Name 'primitives')
        if (-not $primitives.Count) { throw "Configured GLB node $nodeIndex has no mesh primitives." }
        foreach ($primitive in $primitives) {
            $extensions = Get-Img2ThreejsObjectProperty -InputObject $primitive -Name 'extensions'
            foreach ($unsupported in @('KHR_draco_mesh_compression','EXT_meshopt_compression')) {
                if ($null -ne (Get-Img2ThreejsObjectProperty -InputObject $extensions -Name $unsupported)) {
                    throw "Configured GLB node $nodeIndex uses unsupported compressed geometry: $unsupported."
                }
            }
            $attributes = Get-Img2ThreejsObjectProperty -InputObject $primitive -Name 'attributes'
            $positionIndex = Get-Img2ThreejsObjectProperty -InputObject $attributes -Name 'POSITION'
            if ($null -eq $positionIndex) { throw "Configured GLB node $nodeIndex primitive lacks POSITION." }
            $null = Get-Img2ThreejsGlbAccessorInfo -Glb $Glb -AccessorIndex ([int](ConvertTo-Img2ThreejsGlbInteger -Value $positionIndex -Name "node $nodeIndex POSITION accessor")) `
                -Purpose "node $nodeIndex POSITION" -ExpectedType 'VEC3' -RequireMinMax
            if ($RequireNormal) {
                $normalIndex = Get-Img2ThreejsObjectProperty -InputObject $attributes -Name 'NORMAL'
                if ($null -eq $normalIndex) { throw "Configured GLB node $nodeIndex primitive lacks NORMAL." }
                $null = Get-Img2ThreejsGlbAccessorInfo -Glb $Glb -AccessorIndex ([int](ConvertTo-Img2ThreejsGlbInteger -Value $normalIndex -Name "node $nodeIndex NORMAL accessor")) `
                    -Purpose "node $nodeIndex NORMAL" -ExpectedType 'VEC3'
            }
            if ($RequireTexCoord) {
                $uvIndex = Get-Img2ThreejsObjectProperty -InputObject $attributes -Name 'TEXCOORD_0'
                if ($null -eq $uvIndex) { throw "Configured GLB node $nodeIndex primitive lacks TEXCOORD_0." }
                $null = Get-Img2ThreejsGlbAccessorInfo -Glb $Glb -AccessorIndex ([int](ConvertTo-Img2ThreejsGlbInteger -Value $uvIndex -Name "node $nodeIndex TEXCOORD_0 accessor")) `
                    -Purpose "node $nodeIndex TEXCOORD_0" -ExpectedType 'VEC2'
            }
            $indicesIndex = Get-Img2ThreejsObjectProperty -InputObject $primitive -Name 'indices'
            if ($null -ne $indicesIndex) {
                $indexInfo = Get-Img2ThreejsGlbAccessorInfo -Glb $Glb -AccessorIndex ([int](ConvertTo-Img2ThreejsGlbInteger -Value $indicesIndex -Name "node $nodeIndex index accessor")) `
                    -Purpose "node $nodeIndex indices" -ExpectedType 'SCALAR'
                if ($indexInfo.componentType -notin @(5121,5123,5125)) { throw "Configured GLB node $nodeIndex uses a non-unsigned index accessor." }
            }
        }
    }
}

function Assert-Img2ThreejsGlbEmbeddedDiffuse {
    param([Parameter(Mandatory)]$Glb)

    $images = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'images')
    if (-not $images.Count) { throw 'CHARACTER_DIFFUSE=glb requires at least one embedded GLB image.' }
    $validImage = $false
    foreach ($image in $images) {
        $uri = Get-Img2ThreejsObjectProperty -InputObject $image -Name 'uri'
        if (-not [string]::IsNullOrEmpty([string]$uri)) { throw 'CHARACTER_DIFFUSE=glb forbids external image URIs.' }
        $viewIndex = Get-Img2ThreejsObjectProperty -InputObject $image -Name 'bufferView'
        $mimeType = [string](Get-Img2ThreejsObjectProperty -InputObject $image -Name 'mimeType')
        if ($null -eq $viewIndex -or $mimeType -notin @('image/png','image/jpeg','image/webp')) {
            throw 'CHARACTER_DIFFUSE=glb requires an image bufferView and a supported MIME type.'
        }
        $null = Get-Img2ThreejsGlbBufferViewInfo -Glb $Glb -BufferViewIndex ([int](ConvertTo-Img2ThreejsGlbInteger -Value $viewIndex -Name 'embedded image bufferView')) -Purpose 'embedded GLB image'
        $validImage = $true
    }
    if (-not $validImage) { throw 'CHARACTER_DIFFUSE=glb has no valid embedded image.' }

    $textures = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'textures')
    $materials = @(Get-Img2ThreejsObjectProperty -InputObject $Glb.document -Name 'materials')
    if (-not $materials.Count) { throw 'CHARACTER_DIFFUSE=glb requires a material using the embedded image.' }
    $referenced = $false
    foreach ($material in $materials) {
        $pbr = Get-Img2ThreejsObjectProperty -InputObject $material -Name 'pbrMetallicRoughness'
        $baseColor = Get-Img2ThreejsObjectProperty -InputObject $pbr -Name 'baseColorTexture'
        $textureIndex = Get-Img2ThreejsObjectProperty -InputObject $baseColor -Name 'index'
        if ($null -eq $textureIndex) { continue }
        $textureIndex = ConvertTo-Img2ThreejsGlbInteger -Value $textureIndex -Name 'GLB material texture index'
        if ($textureIndex -ge $textures.Count) { throw 'GLB material references a missing texture.' }
        $sourceIndex = Get-Img2ThreejsObjectProperty -InputObject $textures[[int]$textureIndex] -Name 'source'
        $sourceIndex = ConvertTo-Img2ThreejsGlbInteger -Value $sourceIndex -Name 'GLB texture image index'
        if ($sourceIndex -ge $images.Count) {
            throw 'GLB base-color texture references a missing image.'
        }
        $referenced = $true
    }
    if (-not $referenced) { throw 'CHARACTER_DIFFUSE=glb has no material referencing an embedded image.' }
}

function Get-Img2ThreejsGlbNodeInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$ProjectRoot,
        [int[]]$CharacterNodes,
        [switch]$RequirePipelineGeometry,
        [switch]$RequireBin,
        [switch]$RequireNormal,
        [switch]$RequireTexCoord,
        [ValidateSet('none','neutral','embedded','glb','external')][string]$DiffuseMode = 'none'
    )

    $glb = Get-Img2ThreejsGlbStructuralDocument -LiteralPath $LiteralPath -ProjectRoot $ProjectRoot
    $nodes = @(Get-Img2ThreejsObjectProperty -InputObject $glb.document -Name 'nodes')
    if ($RequirePipelineGeometry) {
        if (-not $RequireBin) { $RequireBin = $true }
        if (-not $RequireNormal) { $RequireNormal = $true }
        if (@($CharacterNodes).Count -eq 0) { throw 'Strict GLB validation requires CHARACTER_NODES.' }
        if ($RequireBin -and $null -eq $glb.binOffset) { throw 'The procedural GLB contract requires a BIN chunk.' }
        Assert-Img2ThreejsGlbPipelineGeometry -Glb $glb -CharacterNodes @($CharacterNodes) `
            -RequireNormal:$RequireNormal -RequireTexCoord:$RequireTexCoord
        if ($DiffuseMode -eq 'glb') { Assert-Img2ThreejsGlbEmbeddedDiffuse -Glb $glb }
    } elseif ($RequireBin -and $null -eq $glb.binOffset) {
        throw 'The requested GLB contract requires a BIN chunk.'
    }
    if ($null -eq $nodes -or $nodes.Count -eq 0) { return @() }
    return @(0..($nodes.Count - 1))
}

function Assert-Img2ThreejsConfiguredNodesExist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int[]]$CharacterNodes,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$GlbNodes
    )

    $inventory = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($node in $GlbNodes) { [void]$inventory.Add($node) }
    foreach ($node in $CharacterNodes) {
        if (-not $inventory.Contains($node)) {
            throw "CHARACTER_NODES references node $node, which is absent from the GLB node inventory."
        }
    }
}

function Resolve-Img2ThreejsPlanningContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$Name = 'img2threejs output root'
    )

    $project = (Resolve-Path -LiteralPath $ProjectRoot).Path.TrimEnd([char[]]@([char]92, [char]47))
    $candidatePath = if ([IO.Path]::IsPathRooted($Candidate)) {
        [IO.Path]::GetFullPath($Candidate)
    } else {
        [IO.Path]::GetFullPath((Join-Path $project $Candidate))
    }
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $project -Candidate $candidatePath) -or
        $candidatePath.Equals($project, (Get-Img2ThreejsPathComparison))) {
        throw "$Name must be a strict descendant of the authorized project root."
    }
    $null = Assert-Img2ThreejsSafeRelativePathSyntax -RelativePath ($candidatePath.Substring($project.Length).TrimStart([char]92, [char]47)) -Name $Name
    Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $candidatePath
    return $candidatePath
}

function Get-Img2ThreejsProceduralInputContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $project = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $config = ConvertFrom-Img2ThreejsGlbConfig -LiteralPath $ConfigPath -ProjectRoot $project
    $output = Resolve-Img2ThreejsPlanningContainedPath -ProjectRoot $project -Candidate $OutputRoot
    $diffuse = [string]$config.values.CHARACTER_DIFFUSE
    $diffuseMode = if ($diffuse -in @('none','neutral','embedded','glb')) { $diffuse } else { 'external' }
    if ($diffuseMode -eq 'external') {
        if (-not (Test-Path -LiteralPath $diffuse -PathType Leaf)) { throw 'CHARACTER_DIFFUSE must resolve to an existing project file.' }
        Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $diffuse
    }
    $glbPath = [string]$config.values.CHARACTER_GLB
    $nodes = @($config.values.CHARACTER_NODES | ForEach-Object { [int]$_ })
    $glbNodes = @(Get-Img2ThreejsGlbNodeInventory -LiteralPath $glbPath -ProjectRoot $project `
        -CharacterNodes $nodes -RequirePipelineGeometry -RequireBin -RequireNormal `
        -RequireTexCoord:($diffuseMode -in @('embedded','glb','external')) -DiffuseMode $diffuseMode)
    $null = Assert-Img2ThreejsConfiguredNodesExist -CharacterNodes $nodes -GlbNodes $glbNodes
    $null = ConvertFrom-Img2ThreejsStructuralData `
        -CharacterNodes $nodes `
        -RegionsPath ([string]$config.values.CHARACTER_REGIONS_JSON) `
        -CellSizesPath ([string]$config.values.CHARACTER_CELL_SIZES_JSON) `
        -SectionRegionsPath ([string]$config.values.CHARACTER_SECTION_REGIONS_JSON) `
        -SpokesPath ([string]$config.values.CHARACTER_SPOKES_JSON)
    $codec = [string]$config.values.CHARACTER_CODEC
    if (-not (Test-Path -LiteralPath $codec -PathType Leaf) -or
        [IO.Path]::GetExtension($codec) -notin @('.ts','.tsx','.js','.mjs')) {
        throw 'CHARACTER_CODEC must resolve to an existing supported project-code entrypoint.'
    }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $codec
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        capability = 'img2threejs'
        semanticMode = 'procedural-assisted-reconstruction'
        route = 'GLB-FIRST'
        operation = 'img2threejs.glb-procedural'
        projectRoot = $project
        outputRoot = $output
        config = $config
        glb = [pscustomobject][ordered]@{
            path = $glbPath
            nodes = $nodes
            inventory = $glbNodes
            diffuseMode = $diffuseMode
            requiresBin = $true
            requiresNormal = $true
            requiresTexCoord = ($diffuseMode -in @('embedded','glb','external'))
        }
        limitations = @(
            'Phase 1 validates a GLB-first procedural contract; it does not claim automatic image-to-model generation.'
            'Phase 1 does not execute upstream pipeline stages or materialize real procedural artifacts.'
        )
    }
}

function ConvertTo-Img2ThreejsNativeArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    if ($Value -match '[\x00\r\n]') { throw 'A trusted native argument cannot contain NUL or line breaks.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes) { [void]$builder.Append(('\' * $backslashes)); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Read-Img2ThreejsBoundedGitStream {
    param([Parameter(Mandatory)][IO.Stream]$Stream, [int]$MaximumCharacters = 1MB)
    $reader = New-Object IO.StreamReader($Stream, (New-Object Text.UTF8Encoding($false, $false)), $true, 4096, $true)
    $builder = New-Object Text.StringBuilder
    $buffer = New-Object char[] 4096
    $discarded = 0L
    try {
        while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $remaining = $MaximumCharacters - $builder.Length
            if ($remaining -le 0) { $discarded += $read; continue }
            if ($read -le $remaining) { [void]$builder.Append($buffer, 0, $read) }
            else { [void]$builder.Append($buffer, 0, $remaining); $discarded += ($read - $remaining) }
        }
    } finally { $reader.Dispose() }
    return [pscustomobject][ordered]@{ text = $builder.ToString(); discardedCharacters = $discarded }
}

function Invoke-Img2ThreejsReadOnlyGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('origin','head','tree','status')][string]$Operation,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    Assert-Img2ThreejsNoExistingReparsePoint -Root $repo -Candidate $repo
    $git = Get-Command git.exe -ErrorAction Stop
    $arguments = switch ($Operation) {
        'origin' { @('--no-optional-locks','-c','core.fsmonitor=false','-c','core.untrackedCache=false','-C',$repo,'config','--get','remote.origin.url') }
        'head' { @('--no-optional-locks','-c','core.fsmonitor=false','-c','core.untrackedCache=false','-C',$repo,'rev-parse','HEAD') }
        'tree' { @('--no-optional-locks','-c','core.fsmonitor=false','-c','core.untrackedCache=false','-C',$repo,'rev-parse','HEAD^{tree}') }
        'status' { @('--no-optional-locks','-c','core.fsmonitor=false','-c','core.untrackedCache=false','-C',$repo,'status','--porcelain=v1','--untracked-files=all') }
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $git.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-Img2ThreejsNativeArgument -Value ([string]$_) }) -join ' ')
    $flags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
    $legacyField = [Diagnostics.ProcessStartInfo].GetField('environmentVariables', $flags)
    $gitEnvironment = [ordered]@{
        SystemRoot = [Environment]::GetEnvironmentVariable('SystemRoot','Process')
        TEMP = [Environment]::GetEnvironmentVariable('TEMP','Process')
        TMP = [Environment]::GetEnvironmentVariable('TMP','Process')
        GIT_OPTIONAL_LOCKS = '0'
        GIT_TERMINAL_PROMPT = '0'
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = 'NUL'
    }
    if ($null -ne $legacyField) {
        $dictionary = New-Object Collections.Specialized.StringDictionary
        foreach ($key in $gitEnvironment.Keys) { if ($gitEnvironment[$key]) { $dictionary.Add($key, [string]$gitEnvironment[$key]) } }
        $legacyField.SetValue($startInfo, $dictionary)
    } else {
        $modernField = [Diagnostics.ProcessStartInfo].GetField('environment', $flags)
        if ($null -ne $modernField) {
            $dictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($key in $gitEnvironment.Keys) { if ($gitEnvironment[$key]) { $dictionary[$key] = [string]$gitEnvironment[$key] } }
            $modernField.SetValue($startInfo, $dictionary)
        } else {
            try {
                $startInfo.EnvironmentVariables.Clear()
                foreach ($key in $gitEnvironment.Keys) { if ($gitEnvironment[$key]) { $startInfo.EnvironmentVariables.Add($key, [string]$gitEnvironment[$key]) } }
            } catch { throw 'The read-only Git verifier could not construct an isolated environment: ' + $_.Exception.Message }
        }
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'The read-only Git provenance process did not start.' }
        $stdoutCapture = Read-Img2ThreejsBoundedGitStream -Stream $process.StandardOutput.BaseStream
        $stderrCapture = Read-Img2ThreejsBoundedGitStream -Stream $process.StandardError.BaseStream
        $process.WaitForExit()
        if ($stdoutCapture.discardedCharacters -gt 0 -or $stderrCapture.discardedCharacters -gt 0) { throw 'Git provenance output exceeded its bounded diagnostic limit.' }
        $stdout = $stdoutCapture.text
        $stderr = $stderrCapture.text
        if ($process.ExitCode -ne 0) {
            $detail = if ([string]::IsNullOrWhiteSpace($stderr)) { "exit code $($process.ExitCode)" } else { $stderr.Trim() }
            throw "Git provenance operation $Operation failed: $detail"
        }
        return $stdout.Trim()
    } finally {
        $process.Dispose()
    }
}

function Get-Img2ThreejsExternalLockEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$LockPath
    )

    $repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    $path = if ($LockPath) { [IO.Path]::GetFullPath($LockPath) } else { Join-Path $repo 'integrations/external.lock.json' }
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $repo -Candidate $path)) { throw 'The img2threejs external lock must be contained in the repository.' }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $repo -Candidate $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The tracked img2threejs external lock is unavailable.' }
    try { $lock = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -ErrorAction Stop }
    catch { throw ('The tracked img2threejs external lock is invalid JSON: ' + $_.Exception.Message) }
    $matches = @($lock.dependencies | Where-Object { [string]$_.id -ceq 'img2threejs' })
    if ($matches.Count -ne 1) { throw 'The tracked external lock must contain exactly one img2threejs entry.' }
    $entry = $matches[0]
    foreach ($name in @('upstream','ref','commitSha','checkoutPath','licenseFile','licenseSha256','upstreamSkillSourcePath','upstreamSkillEntrySha256','adapterPath','adapterEntrySha256','upstreamSnapshotPath','snapshotTreeSha256')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Img2ThreejsObjectProperty -InputObject $entry -Name $name))) {
            throw "The tracked img2threejs lock entry lacks $name."
        }
    }
    return $entry
}

function Get-Img2ThreejsTextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-Img2ThreejsFileSha256 {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = New-Object IO.FileStream($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Get-Img2ThreejsCanonicalTextFileSha256 {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $source = [IO.File]::ReadAllBytes($LiteralPath)
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    for ($index = 0; $index -lt $source.Length; $index++) {
        if ($source[$index] -eq 13 -and $index + 1 -lt $source.Length -and $source[$index + 1] -eq 10) {
            [void]$bytes.Add(10)
            $index++
        } else {
            [void]$bytes.Add($source[$index])
        }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes.ToArray())) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-Img2ThreejsCanonicalTreeSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $canonicalRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([char[]]@([char]92, [char]47))
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $totalBytes = 0L
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($canonicalRoot)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ($item.PSIsContainer -and $item.Name -ceq '.git') { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('The provenance tree contains a reparse point: ' + $item.FullName)
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            if ($entries.Count -ge $script:Img2ThreejsMaximumSourceFiles) { throw 'The provenance tree exceeds the file-count boundary.' }
            $totalBytes += [int64]$item.Length
            if ($totalBytes -gt $script:Img2ThreejsMaximumSourceBytes) { throw 'The provenance tree exceeds the byte boundary.' }
            $relative = $item.FullName.Substring($canonicalRoot.Length).TrimStart([char]92, [char]47).Replace([char]92, [char]47)
            $entries.Add($relative + '|' + (Get-Img2ThreejsFileSha256 -LiteralPath $item.FullName))
        }
    }
    $sorted = [string[]]$entries.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return Get-Img2ThreejsTextSha256 -Text ($sorted -join "`n")
}

function Get-Img2ThreejsProvenanceFileCheck {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Name,
        [switch]$CanonicalText
    )

    $repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    $candidate = [IO.Path]::GetFullPath((Join-Path $repo $RelativePath))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $repo -Candidate $candidate)) {
        return [pscustomobject][ordered]@{ name = $Name; path = $RelativePath; exists = $false; valid = $false; actualSha256 = $null; reason = 'path escapes repository' }
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return [pscustomobject][ordered]@{ name = $Name; path = $RelativePath; exists = $false; valid = $false; actualSha256 = $null; reason = 'file absent' }
    }
    try {
        Assert-Img2ThreejsNoExistingReparsePoint -Root $repo -Candidate $candidate
        $actual = if ($CanonicalText) { Get-Img2ThreejsCanonicalTextFileSha256 -LiteralPath $candidate } else { Get-Img2ThreejsFileSha256 -LiteralPath $candidate }
    }
    catch { return [pscustomobject][ordered]@{ name = $Name; path = $RelativePath; exists = $true; valid = $false; actualSha256 = $null; reason = $_.Exception.Message } }
    return [pscustomobject][ordered]@{
        name = $Name
        path = $RelativePath
        exists = $true
        expectedSha256 = ([string]$ExpectedSha256).ToLowerInvariant()
        actualSha256 = $actual
        valid = $actual -ceq ([string]$ExpectedSha256).ToLowerInvariant()
        reason = if ($actual -ceq ([string]$ExpectedSha256).ToLowerInvariant()) { $null } else { 'sha256 mismatch' }
    }
}

function Test-Img2ThreejsSourceProvenance {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot,
        [string]$LockPath,
        [string]$ExpectedFingerprint
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    }
    $repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    try { $entry = Get-Img2ThreejsExternalLockEntry -RepositoryRoot $repo -LockPath $LockPath }
    catch {
        return [pscustomobject][ordered]@{
            materialized = $false; valid = $false; failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE';
            sourceFingerprint = $null; canonicalPath = $null; authority = $null;
            checks = [ordered]@{ lock = [pscustomobject]@{ valid = $false; reason = $_.Exception.Message } };
            reason = $_.Exception.Message
        }
    }

    $expectedSource = [IO.Path]::GetFullPath((Join-Path $repo ([string]$entry.checkoutPath)))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $repo -Candidate $expectedSource)) {
        throw 'The tracked img2threejs checkoutPath escapes the repository.'
    }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $repo -Candidate $expectedSource
    if (-not (Test-Path -LiteralPath $expectedSource -PathType Container)) {
        return [pscustomobject][ordered]@{
            materialized = $false; valid = $false; failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE';
            sourceFingerprint = $null; canonicalPath = $expectedSource; authority = $entry;
            checks = [ordered]@{ source = [pscustomobject]@{ exists = $false; valid = $true; state = 'NOT_MATERIALIZED'; reason = 'pinned source is absent, not corrupt' } };
            reason = 'The pinned img2threejs source is not materialized.'
        }
    }

    $checks = [ordered]@{}
    $allValid = $true
    try {
        $top = Invoke-Img2ThreejsReadOnlyGit -Operation head -RepositoryRoot $expectedSource
        $origin = Invoke-Img2ThreejsReadOnlyGit -Operation origin -RepositoryRoot $expectedSource
        $tree = Invoke-Img2ThreejsReadOnlyGit -Operation tree -RepositoryRoot $expectedSource
        $status = Invoke-Img2ThreejsReadOnlyGit -Operation status -RepositoryRoot $expectedSource
        $checks.repository = [pscustomobject]@{ valid = $true; canonicalPath = $expectedSource; clean = [string]::IsNullOrEmpty($status) }
        $checks.origin = [pscustomobject]@{ expected = [string]$entry.upstream; actual = $origin; valid = $origin -ceq [string]$entry.upstream }
        $checks.head = [pscustomobject]@{ expected = ([string]$entry.commitSha).ToLowerInvariant(); actual = $top.ToLowerInvariant(); valid = $top -ieq [string]$entry.commitSha }
        $checks.tree = [pscustomobject]@{ actual = $tree; expected = $null; valid = $true; state = 'NOT_LOCKED' }
        foreach ($propertyName in @('treeSha','treeObjectSha','observedTreeSha')) {
            $expectedTree = [string](Get-Img2ThreejsObjectProperty -InputObject $entry -Name $propertyName)
            if ($expectedTree) {
                $checks.tree.expected = $expectedTree.ToLowerInvariant()
                $checks.tree.valid = $tree -ieq $expectedTree
                $checks.tree.state = 'LOCKED'
                break
            }
        }
        $checks.status = [pscustomobject]@{ actual = $status; valid = [string]::IsNullOrEmpty($status) }
        if (-not $checks.origin.valid -or -not $checks.head.valid -or -not $checks.tree.valid -or -not $checks.status.valid) { $allValid = $false }
    } catch {
        $checks.repository = [pscustomobject]@{ valid = $false; canonicalPath = $expectedSource; clean = $false; reason = $_.Exception.Message }
        $checks.origin = [pscustomobject]@{ expected = [string]$entry.upstream; actual = $null; valid = $false }
        $checks.head = [pscustomobject]@{ expected = ([string]$entry.commitSha).ToLowerInvariant(); actual = $null; valid = $false }
        $checks.tree = [pscustomobject]@{ actual = $null; expected = $null; valid = $false; state = 'UNAVAILABLE' }
        $checks.status = [pscustomobject]@{ actual = $null; valid = $false }
        $allValid = $false
    }

    $license = Get-Img2ThreejsProvenanceFileCheck -RepositoryRoot $repo -RelativePath ([string]$entry.licenseFile) `
        -ExpectedSha256 ([string]$entry.licenseSha256) -Name 'license'
    $adapterSkillPath = Join-Path ([string]$entry.adapterPath) 'SKILL.md'
    $adapter = Get-Img2ThreejsProvenanceFileCheck -RepositoryRoot $repo -RelativePath $adapterSkillPath `
        -ExpectedSha256 ([string]$entry.adapterEntrySha256) -Name 'adapter-skill' -CanonicalText
    $upstreamSkillRoot = [IO.Path]::GetFullPath((Join-Path $repo ([string]$entry.upstreamSkillSourcePath)))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $repo -Candidate $upstreamSkillRoot)) {
        throw 'The tracked upstream skill path escapes the repository.'
    }
    $upstreamSkillPath = if (Test-Path -LiteralPath $upstreamSkillRoot -PathType Leaf) { $upstreamSkillRoot } else { Join-Path $upstreamSkillRoot 'SKILL.md' }
    $upstreamSkillRelative = $upstreamSkillPath.Substring($repo.Length).TrimStart([char]92, [char]47)
    $upstreamSkill = Get-Img2ThreejsProvenanceFileCheck -RepositoryRoot $repo -RelativePath $upstreamSkillRelative `
        -ExpectedSha256 ([string]$entry.upstreamSkillEntrySha256) -Name 'upstream-skill'
    $checks.files = @($license,$adapter,$upstreamSkill)
    if (@($checks.files | Where-Object { -not $_.valid }).Count) { $allValid = $false }

    $snapshot = [IO.Path]::GetFullPath((Join-Path $repo ([string]$entry.upstreamSnapshotPath)))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $repo -Candidate $snapshot)) { throw 'The tracked snapshot path escapes the repository.' }
    $snapshotExists = Test-Path -LiteralPath $snapshot
    $snapshotCheck = [ordered]@{
        path = [string]$entry.upstreamSnapshotPath
        exists = $snapshotExists
        required = $false
        status = if ($snapshotExists) { 'PRESENT' } else { 'NOT_MATERIALIZED' }
        valid = $true
        expectedSha256 = ([string]$entry.snapshotTreeSha256).ToLowerInvariant()
        actualSha256 = $null
        reason = if ($snapshotExists) { $null } else { 'The distribution-only upstream snapshot is not materialized.' }
    }
    if ($snapshotExists) {
        try {
            $snapshotItem = Get-Item -Force -LiteralPath $snapshot
            if (-not $snapshotItem.PSIsContainer) { throw 'The upstream snapshot must be a directory.' }
            Assert-Img2ThreejsNoExistingReparsePoint -Root $repo -Candidate $snapshot
            $actualSnapshot = Get-Img2ThreejsCanonicalTreeSha256 -Root $snapshot
            $snapshotCheck.actualSha256 = $actualSnapshot
            $snapshotCheck.valid = $actualSnapshot -ceq $snapshotCheck.expectedSha256
            $snapshotCheck.status = if ($snapshotCheck.valid) { 'VALID' } else { 'INVALID' }
            if (-not $snapshotCheck.valid) { $snapshotCheck.reason = 'The upstream snapshot tree hash does not match the lock.' }
        } catch {
            $snapshotCheck.valid = $false
            $snapshotCheck.status = 'INVALID'
            $snapshotCheck.reason = $_.Exception.Message
        }
    }
    $checks.snapshot = [pscustomobject]$snapshotCheck
    if (-not $snapshotCheck.valid) { $allValid = $false }

    $fingerprintInput = [ordered]@{
        id = 'img2threejs'; ref = [string]$entry.ref; origin = [string]$entry.upstream;
        checkoutPath = [string]$entry.checkoutPath; head = $checks.head.actual;
        tree = $checks.tree.actual; statusClean = $checks.status.valid;
        license = $license.actualSha256; adapter = $adapter.actualSha256; upstreamSkill = $upstreamSkill.actualSha256;
        snapshot = $snapshotCheck.actualSha256; snapshotRequired = [bool]$snapshotCheck.required; snapshotStatus = [string]$snapshotCheck.status
    }
    $fingerprint = Get-Img2ThreejsTextSha256 -Text (ConvertTo-Json $fingerprintInput -Compress -Depth 8)
    if ($ExpectedFingerprint -and $fingerprint -cne $ExpectedFingerprint.ToLowerInvariant()) {
        $allValid = $false
        $checks.fingerprint = [pscustomobject]@{ expected = $ExpectedFingerprint.ToLowerInvariant(); actual = $fingerprint; valid = $false }
    } else {
        $checks.fingerprint = [pscustomobject]@{ expected = if ($ExpectedFingerprint) { $ExpectedFingerprint.ToLowerInvariant() } else { $null }; actual = $fingerprint; valid = $true }
    }
    return [pscustomobject][ordered]@{
        materialized = $true
        valid = $allValid
        failureType = if ($allValid) { $null } else { 'DEPENDENCY_OR_RUNTIME_FAILURE' }
        sourceFingerprint = $fingerprint
        canonicalPath = $expectedSource
        authority = $entry
        checks = $checks
        reason = if ($allValid) { $null } else { 'Pinned img2threejs source provenance did not validate.' }
    }
}

function Assert-Img2ThreejsSourceFingerprint {
    param(
        [Parameter(Mandatory)]$Provenance,
        [Parameter(Mandatory)][string]$ExpectedFingerprint
    )
    if (-not $Provenance.materialized -or -not $Provenance.valid -or
        [string]::IsNullOrWhiteSpace([string]$Provenance.sourceFingerprint) -or
        [string]$Provenance.sourceFingerprint -cne $ExpectedFingerprint.ToLowerInvariant()) {
        throw 'The img2threejs source fingerprint does not match the authorized prerequisite.'
    }
}

function Test-Img2ThreejsHedsArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    try {
        $item = Get-Item -Force -LiteralPath $LiteralPath -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HEDS artifact must be a regular file.' }
        if ($item.Length -lt 16 -or $item.Length -gt $script:Img2ThreejsHedsMaximumBytes) { throw 'HEDS artifact is outside the FTK size boundary.' }
        $stream = New-Object IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $prefix = Read-Img2ThreejsExactBytes -Stream $stream -Count 16 -FailureMessage 'HEDS header is truncated.'
            if ([Text.Encoding]::ASCII.GetString($prefix, 0, 4) -cne 'HEDS') { throw 'HEDS magic is invalid.' }
            if ([BitConverter]::ToUInt32($prefix, 4) -ne 3) { throw 'Only HEDS version 3 is supported.' }
            $headerLength = [int64][BitConverter]::ToUInt32($prefix, 8)
            $declaredLength = [int64][BitConverter]::ToUInt32($prefix, 12)
            if ($headerLength -lt 2 -or $headerLength -gt $script:Img2ThreejsHedsMaximumHeaderBytes) { throw 'HEDS header length is outside the FTK boundary.' }
            if ($declaredLength -ne $item.Length) { throw 'HEDS declared length does not match the file length.' }
            if (16L + $headerLength -gt $item.Length) { throw 'HEDS header exceeds the file length.' }
            $headerBytes = Read-Img2ThreejsExactBytes -Stream $stream -Count $headerLength -FailureMessage 'HEDS header JSON is truncated.'
            $utf8 = New-Object Text.UTF8Encoding($false, $true)
            try { $headerText = $utf8.GetString($headerBytes) }
            catch [Text.DecoderFallbackException] { throw 'HEDS header JSON is not valid UTF-8.' }
            $headerText = $headerText.TrimEnd([char[]]@(0x20,0x00,0x09,0x0A,0x0D))
            try { $header = ConvertFrom-Json -InputObject $headerText -ErrorAction Stop }
            catch { throw ('HEDS header JSON is invalid: ' + $_.Exception.Message) }
            if ($null -eq $header -or $header -is [ValueType] -or $header -is [string]) { throw 'HEDS header root must be an object.' }
            $headerVersion = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'version'
            if ($null -ne $headerVersion -and [int]$headerVersion -ne 3) { throw 'HEDS header JSON version is not 3.' }
            $headerEnd = 16L + $headerLength
            $sectionsValue = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'sections'
            if ($null -eq $sectionsValue) { $sectionsValue = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'payloads' }
            if ($null -eq $sectionsValue) { $sectionsValue = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'nodes' }
            $sections = @($sectionsValue)
            if (-not $sections.Count) {
                $singleOffset = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'payloadOffset'
                $singleLength = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'payloadLength'
                if ($null -ne $singleOffset -and $null -ne $singleLength) {
                    $sections = @([pscustomobject][ordered]@{ offset = $singleOffset; length = $singleLength })
                }
            }
            if (-not $sections.Count) { throw 'HEDS v3 header has no bounded payload sections.' }
            $declaredCount = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'sectionCount'
            if ($null -eq $declaredCount) { $declaredCount = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'nodeCount' }
            if ($null -ne $declaredCount -and [int]$declaredCount -ne $sections.Count) { throw 'HEDS section count is inconsistent.' }
            $ranges = New-Object 'System.Collections.Generic.List[object]'
            foreach ($section in $sections) {
                $offsetValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'offset'
                if ($null -eq $offsetValue) { $offsetValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'byteOffset' }
                $lengthValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'length'
                if ($null -eq $lengthValue) { $lengthValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'byteLength' }
                if ($null -eq $offsetValue -or $null -eq $lengthValue) { throw 'HEDS section lacks offset/length.' }
                $offset = [int64]$offsetValue
                $length = [int64]$lengthValue
                if ($offset -lt $headerEnd -or $length -le 0 -or $offset + $length -gt $item.Length) { throw 'HEDS section bounds are invalid.' }
                $vertexCountValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'vertexCount'
                $indexCountValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'indexCount'
                if ($null -ne $vertexCountValue -and ([long]$vertexCountValue -lt 1 -or [long]$vertexCountValue -gt 100000000)) { throw 'HEDS vertex count is outside the FTK boundary.' }
                if ($null -ne $indexCountValue -and ([long]$indexCountValue -lt 0 -or [long]$indexCountValue -gt 300000000)) { throw 'HEDS index count is outside the FTK boundary.' }
                $indexOffsetValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'indexOffset'
                $indexLengthValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'indexLength'
                if ($null -ne $indexOffsetValue -or $null -ne $indexLengthValue) {
                    if ($null -eq $indexOffsetValue -or $null -eq $indexLengthValue) { throw 'HEDS index range is incomplete.' }
                    $indexOffset = [int64]$indexOffsetValue
                    $indexLength = [int64]$indexLengthValue
                    if ($indexOffset -lt $offset -or $indexLength -le 0 -or $indexOffset + $indexLength -gt $offset + $length) { throw 'HEDS index range exceeds its section.' }
                }
                $indexMaxValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'indexMax'
                if ($null -ne $indexMaxValue -and $null -ne $vertexCountValue -and ([long]$indexMaxValue -lt 0 -or [long]$indexMaxValue -ge [long]$vertexCountValue)) {
                    throw 'HEDS indexMax is outside the declared vertex range.'
                }
                $indicesValue = Get-Img2ThreejsObjectProperty -InputObject $section -Name 'indices'
                $indices = New-Object 'System.Collections.Generic.List[object]'
                if ($null -ne $indicesValue -and -not ($indicesValue -is [PSCustomObject] -and @($indicesValue.PSObject.Properties).Count -eq 0)) {
                    foreach ($indexValue in @($indicesValue)) { $indices.Add($indexValue) }
                }
                if ($indices.Count -and $null -ne $vertexCountValue) {
                    foreach ($index in $indices) {
                        if ([long]$index -lt 0 -or [long]$index -ge [long]$vertexCountValue) { throw 'HEDS index is outside the declared vertex range.' }
                    }
                }
                $ranges.Add([pscustomobject]@{ offset = $offset; length = $length; end = $offset + $length })
            }
            $orderedRanges = @($ranges.ToArray() | Sort-Object offset)
            for ($index = 1; $index -lt $orderedRanges.Count; $index++) {
                if ($orderedRanges[$index - 1].end -gt $orderedRanges[$index].offset) { throw 'HEDS payload sections overlap.' }
            }
            $payloadOffset = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'payloadOffset'
            $payloadLength = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'payloadLength'
            if ($null -ne $payloadOffset -or $null -ne $payloadLength) {
                if ($null -eq $payloadOffset -or $null -eq $payloadLength -or
                    [int64]$payloadOffset -ne $orderedRanges[0].offset -or
                    [int64]$payloadLength -ne ($item.Length - [int64]$payloadOffset)) {
                    throw 'HEDS declared payload length is inconsistent.'
                }
            }
            $lastEnd = $orderedRanges[-1].end
            $allowTrailingValue = Get-Img2ThreejsObjectProperty -InputObject $header -Name 'allowTrailingBytes'
            $allowTrailing = $false
            if ($null -ne $allowTrailingValue) {
                if ($allowTrailingValue -isnot [bool]) { throw 'HEDS allowTrailingBytes must be a JSON boolean.' }
                $allowTrailing = [bool]$allowTrailingValue
            }
            if (-not $allowTrailing -and $lastEnd -ne $item.Length) { throw 'HEDS contains unexpected trailing bytes.' }
            return [pscustomobject][ordered]@{
                valid = $true; validator = 'HEDS-v3-structural'; format = 'HEDS-v3-json-header';
                version = 3; headerBytes = $headerLength; sections = $sections.Count;
                bytes = [int64]$item.Length
            }
        } finally { $stream.Dispose() }
    } catch {
        return [pscustomobject][ordered]@{ valid = $false; validator = 'HEDS-v3-structural'; reason = $_.Exception.Message }
    }
}

function Assert-Img2ThreejsHedsArtifact {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $result = Test-Img2ThreejsHedsArtifact -LiteralPath $LiteralPath
    if (-not $result.valid) { throw [string]$result.reason }
    return $result
}

function Get-Img2ThreejsBoundedUtf8Text {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][long]$MaximumBytes
    )
    $item = Get-Item -Force -LiteralPath $LiteralPath -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The text artifact must be a regular file.' }
    if ($item.Length -gt $MaximumBytes) { throw 'The text artifact exceeds the FTK size boundary.' }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try { $text = $utf8.GetString($bytes) }
    catch [Text.DecoderFallbackException] { throw 'The text artifact is not valid UTF-8.' }
    if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function Test-Img2ThreejsTypescriptArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateSet('x2','x3','default')][string]$ExpectedLevel,
        [string]$ReferencedBinaryPath
    )

    try {
        $text = Get-Img2ThreejsBoundedUtf8Text -LiteralPath $LiteralPath -MaximumBytes $script:Img2ThreejsTypescriptMaximumBytes
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'Generated TypeScript is empty.' }
        if ($text -match '(?i)\b(?:eval|require\s*\(|import\s*\()') { throw 'Generated TypeScript contains executable/import-only validation bypasses.' }
        if ($text -notmatch '(?s)\bschemaVersion\s*:\s*1\b' -or $text -notmatch '(?s)\b(?:metadata|meta)\s*:') {
            throw 'Generated TypeScript lacks the required schema metadata.'
        }
        $levelPattern = '(?is)\b(?:level|detailLevel|surfaceLevel)\s*:\s*[''\"]' + [regex]::Escape($ExpectedLevel) + '[''\"]'
        if ($text -notmatch $levelPattern) { throw "Generated TypeScript does not declare level $ExpectedLevel." }
        $payloadMatch = [regex]::Match($text, '(?is)\b(?:base64|payloadBase64|encoded)\s*:\s*[''\"](?<payload>[A-Za-z0-9+/\r\n]+={0,2})[''\"]')
        if (-not $payloadMatch.Success -or $payloadMatch.Groups['payload'].Value.Replace("`r",'').Replace("`n",'').Length -lt 4) {
            throw 'Generated TypeScript lacks a bounded base64 payload.'
        }
        $correspondence = 'not-provided'
        if ($ReferencedBinaryPath) {
            if (-not (Test-Path -LiteralPath $ReferencedBinaryPath -PathType Leaf)) { throw 'Referenced binary artifact is absent.' }
            $binaryHash = Get-Img2ThreejsFileSha256 -LiteralPath $ReferencedBinaryPath
            $hashMatch = [regex]::Match($text, '(?is)\bsourceSha256\s*:\s*[''\"](?<hash>[0-9a-f]{64})[''\"]')
            if ($hashMatch.Success) {
                if ($hashMatch.Groups['hash'].Value.ToLowerInvariant() -cne $binaryHash) { throw 'Generated TypeScript sourceSha256 does not match its referenced binary.' }
                $correspondence = 'sha256'
            }
        }
        return [pscustomobject][ordered]@{ valid = $true; validator = 'TypeScript-structural'; level = $ExpectedLevel; payload = 'base64'; correspondence = $correspondence }
    } catch {
        return [pscustomobject][ordered]@{ valid = $false; validator = 'TypeScript-structural'; reason = $_.Exception.Message }
    }
}

function Assert-Img2ThreejsTypescriptArtifact {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateSet('x2','x3','default')][string]$ExpectedLevel,
        [string]$ReferencedBinaryPath
    )
    $result = Test-Img2ThreejsTypescriptArtifact -LiteralPath $LiteralPath -ExpectedLevel $ExpectedLevel -ReferencedBinaryPath $ReferencedBinaryPath
    if (-not $result.valid) { throw [string]$result.reason }
    return $result
}

function Test-Img2ThreejsNpyArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$ExpectedDtype
    )

    try {
        $item = Get-Item -Force -LiteralPath $LiteralPath -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'NPY artifact must be a regular file.' }
        if ($item.Length -lt 12 -or $item.Length -gt 512MB) { throw 'NPY artifact is outside the FTK size boundary.' }
        $stream = New-Object IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $magic = Read-Img2ThreejsExactBytes -Stream $stream -Count 6 -FailureMessage 'NPY magic is truncated.'
            if ($magic[0] -ne [byte]0x93 -or ([Text.Encoding]::ASCII.GetString($magic, 1, 5) -cne 'NUMPY')) { throw 'NPY magic is invalid.' }
            $version = Read-Img2ThreejsExactBytes -Stream $stream -Count 2 -FailureMessage 'NPY version is truncated.'
            $major = [int]$version[0]
            if ($major -notin @(1,2,3)) { throw "Unsupported NPY version: $major.$($version[1])" }
            $lengthBytes = if ($major -eq 1) { 2 } else { 4 }
            $headerLengthBytes = Read-Img2ThreejsExactBytes -Stream $stream -Count $lengthBytes -FailureMessage 'NPY header length is truncated.'
            $headerLength = if ($lengthBytes -eq 2) { [int64][BitConverter]::ToUInt16($headerLengthBytes, 0) } else { [int64][BitConverter]::ToUInt32($headerLengthBytes, 0) }
            if ($headerLength -lt 2 -or $headerLength -gt $script:Img2ThreejsNpyMaximumHeaderBytes) { throw 'NPY header is outside the FTK boundary.' }
            $header = Read-Img2ThreejsExactBytes -Stream $stream -Count $headerLength -FailureMessage 'NPY header is truncated.'
            $encoding = New-Object Text.UTF8Encoding($false, $true)
            try { $headerText = $encoding.GetString($header) } catch { throw 'NPY header is not valid UTF-8.' }
            $headerText = $headerText.Trim()
            $descrMatch = [regex]::Match($headerText, '(?is)[''\"]descr[''\"]\s*:\s*[''\"](?<descr>[^''\"]+)[''\"]')
            $fortranMatch = [regex]::Match($headerText, '(?is)[''\"]fortran_order[''\"]\s*:\s*(?<order>True|False)')
            $shapeMatch = [regex]::Match($headerText, '(?is)[''\"]shape[''\"]\s*:\s*\((?<shape>[^)]*)\)')
            if (-not $descrMatch.Success -or -not $fortranMatch.Success -or -not $shapeMatch.Success) { throw 'NPY header lacks descr, fortran_order, or shape.' }
            $descr = $descrMatch.Groups['descr'].Value
            $dtypeMatch = [regex]::Match($descr, '^[<>=|](?<kind>[biuf])(?<size>[1248])$')
            if (-not $dtypeMatch.Success) { throw "NPY dtype is unsupported: $descr" }
            if ($ExpectedDtype -and $descr.ToLowerInvariant() -cne $ExpectedDtype.ToLowerInvariant()) { throw "NPY dtype $descr does not match expected $ExpectedDtype." }
            $shapeParts = @($shapeMatch.Groups['shape'].Value.Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if (-not $shapeParts.Count -or $shapeParts.Count -gt 8) { throw 'NPY shape rank is outside the FTK boundary.' }
            $elementCount = 1L
            foreach ($part in $shapeParts) {
                $dimension = 0L
                if (-not [long]::TryParse($part.Trim(), [ref]$dimension) -or $dimension -lt 1 -or $dimension -gt 100000000) { throw 'NPY shape contains an invalid dimension.' }
                $elementCount *= $dimension
                if ($elementCount -gt 100000000) { throw 'NPY shape exceeds the FTK element boundary.' }
            }
            $itemSize = [int]$dtypeMatch.Groups['size'].Value
            $expectedPayload = $elementCount * $itemSize
            $payloadOffset = 6L + 2L + $lengthBytes + $headerLength
            if ($payloadOffset + $expectedPayload -ne $item.Length) { throw 'NPY payload length is inconsistent with shape and dtype.' }
            return [pscustomobject][ordered]@{ valid = $true; validator = 'NPY-structural'; version = "$major.$($version[1])"; dtype = $descr; shape = @($shapeParts | ForEach-Object { [int64]$_.Trim() }); bytes = [int64]$item.Length }
        } finally { $stream.Dispose() }
    } catch {
        return [pscustomobject][ordered]@{ valid = $false; validator = 'NPY-structural'; reason = $_.Exception.Message }
    }
}

function Assert-Img2ThreejsNpyArtifact {
    param([Parameter(Mandatory)][string]$LiteralPath, [string]$ExpectedDtype)
    $result = Test-Img2ThreejsNpyArtifact -LiteralPath $LiteralPath -ExpectedDtype $ExpectedDtype
    if (-not $result.valid) { throw [string]$result.reason }
    return $result
}

function Test-Img2ThreejsVerifierEvidence {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Stdout,
        [AllowNull()][object[]]$Stderr,
        [int]$ExitCode = 0
    )

    $text = ((@($Stdout) + @($Stderr)) | ForEach-Object { [string]$_ }) -join "`n"
    if ($ExitCode -ne 0) { return [pscustomobject][ordered]@{ valid = $false; validator = 'verifier-evidence'; state = 'FAIL'; reason = "verifier exit code $ExitCode" } }
    if ($text -match '(?im)(^|\s)(FAIL|FAILED|ERROR)(?:\s|:|$)|status\s*[:=]\s*fail') {
        return [pscustomobject][ordered]@{ valid = $false; validator = 'verifier-evidence'; state = 'FAIL'; reason = 'verifier evidence contains FAIL/ERROR.' }
    }
    if ($text -notmatch '(?im)(^|\s)(PASS|PASSED|OK)(?:\s|:|$)|status\s*[:=]\s*(?:pass|ok)|0\s+collisions') {
        return [pscustomobject][ordered]@{ valid = $false; validator = 'verifier-evidence'; state = 'UNKNOWN'; reason = 'exit code 0 had no affirmative verifier evidence.' }
    }
    return [pscustomobject][ordered]@{ valid = $true; validator = 'verifier-evidence'; state = 'PASS'; reason = $null }
}

function Assert-Img2ThreejsVerifierEvidence {
    param([AllowNull()][object[]]$Stdout, [AllowNull()][object[]]$Stderr, [int]$ExitCode = 0)
    $result = Test-Img2ThreejsVerifierEvidence -Stdout $Stdout -Stderr $Stderr -ExitCode $ExitCode
    if (-not $result.valid) { throw [string]$result.reason }
    return $result
}
