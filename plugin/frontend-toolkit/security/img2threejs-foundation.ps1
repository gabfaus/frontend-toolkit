Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-Img2ThreejsGlbNodeInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    $item = Get-Item -Force -LiteralPath $LiteralPath -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'CHARACTER_GLB must be a file.' }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'CHARACTER_GLB cannot be a reparse point.'
    }
    $stream = New-Object IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $header = New-Object byte[] 20
        if ($stream.Read($header, 0, $header.Length) -ne $header.Length) { throw 'CHARACTER_GLB has a truncated header.' }
        if ([Text.Encoding]::ASCII.GetString($header, 0, 4) -cne 'glTF') { throw 'CHARACTER_GLB does not have glTF magic.' }
        if ([BitConverter]::ToUInt32($header, 4) -ne 2) { throw 'Only binary glTF version 2 is supported.' }
        $declaredLength = [BitConverter]::ToUInt32($header, 8)
        if ($declaredLength -ne $item.Length) { throw 'CHARACTER_GLB declared length does not match the file length.' }
        $jsonLength = [BitConverter]::ToUInt32($header, 12)
        $jsonType = [BitConverter]::ToUInt32($header, 16)
        if ($jsonType -ne 0x4E4F534A) { throw 'CHARACTER_GLB first chunk is not JSON.' }
        if ($jsonLength -lt 2 -or $jsonLength -gt 16MB -or (20L + $jsonLength) -gt $item.Length) {
            throw 'CHARACTER_GLB JSON chunk is outside the FTK resource boundary.'
        }
        $bytes = New-Object byte[] $jsonLength
        if ($stream.Read($bytes, 0, $bytes.Length) -ne $bytes.Length) { throw 'CHARACTER_GLB JSON chunk is truncated.' }
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $jsonText = $utf8.GetString($bytes).TrimEnd([char[]]@(0x20,0x00,0x09,0x0A,0x0D))
        try { $document = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop }
        catch { throw ('CHARACTER_GLB JSON chunk is invalid: ' + $_.Exception.Message) }
        $nodeCount = @($document.nodes).Count
        if ($nodeCount -eq 0) { return @() }
        return @(0..($nodeCount - 1))
    } finally {
        $stream.Dispose()
    }
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
