Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Img2ThreejsStatePathComparison {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Get-Img2ThreejsStatePathSegments {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $full = [IO.Path]::GetFullPath($LiteralPath).TrimEnd([char[]]@([char]92, [char]47))
    return @($full -split '[\\/]')
}

function Test-Img2ThreejsStatePathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate,
        [switch]$AllowRoot
    )
    $rootParts = @(Get-Img2ThreejsStatePathSegments -LiteralPath $Root)
    $candidateParts = @(Get-Img2ThreejsStatePathSegments -LiteralPath $Candidate)
    if ($candidateParts.Count -lt $rootParts.Count) { return $false }
    if (-not $AllowRoot -and $candidateParts.Count -eq $rootParts.Count) { return $false }
    $comparison = Get-Img2ThreejsStatePathComparison
    for ($index = 0; $index -lt $rootParts.Count; $index++) {
        if (-not $candidateParts[$index].Equals($rootParts[$index], $comparison)) { return $false }
    }
    return $true
}

function Get-Img2ThreejsStateExistingItem {
    param([Parameter(Mandatory)][string]$LiteralPath)
    return Get-Item -Force -LiteralPath $LiteralPath -ErrorAction SilentlyContinue
}

function Assert-Img2ThreejsStateItemNotReparse {
    param([Parameter(Mandatory)]$Item)
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('Reparse points are denied in the img2threejs state boundary: ' + $Item.FullName)
    }
}

function Assert-Img2ThreejsStateBoundaryComponents {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([char]92, [char]47))
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $rootFull -Candidate $candidateFull -AllowRoot)) {
        throw 'The img2threejs state boundary candidate is outside its authorized root.'
    }
    $rootParts = @(Get-Img2ThreejsStatePathSegments -LiteralPath $rootFull)
    $candidateParts = @(Get-Img2ThreejsStatePathSegments -LiteralPath $candidateFull)
    $current = $rootFull
    $item = Get-Img2ThreejsStateExistingItem -LiteralPath $current
    if ($null -ne $item) { Assert-Img2ThreejsStateItemNotReparse -Item $item }
    for ($index = $rootParts.Count; $index -lt $candidateParts.Count; $index++) {
        $current = Join-Path $current $candidateParts[$index]
        $item = Get-Img2ThreejsStateExistingItem -LiteralPath $current
        if ($null -ne $item) { Assert-Img2ThreejsStateItemNotReparse -Item $item }
    }
}

function Resolve-Img2ThreejsCanonicalProjectRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw 'The img2threejs project root must be an existing directory.'
    }
    $projectFull = [IO.Path]::GetFullPath($ProjectRoot)
    $pathRoot = [IO.Path]::GetPathRoot($projectFull)
    $current = $pathRoot
    $relativeParts = @($projectFull.Substring($pathRoot.Length) -split '[\\/]' | Where-Object { $_ })
    foreach ($part in $relativeParts) {
        $current = Join-Path $current $part
        $ancestorItem = Get-Img2ThreejsStateExistingItem -LiteralPath $current
        if ($null -ne $ancestorItem) { Assert-Img2ThreejsStateItemNotReparse -Item $ancestorItem }
    }
    $projectItem = Get-Item -Force -LiteralPath $projectFull
    Assert-Img2ThreejsStateItemNotReparse -Item $projectItem
    return (Resolve-Path -LiteralPath $projectItem.FullName).Path.TrimEnd([char[]]@([char]92, [char]47))
}

function Assert-Img2ThreejsStateInput {
    param([Parameter(Mandatory)][string]$StatePath)
    if ([string]::IsNullOrWhiteSpace($StatePath)) { throw 'The img2threejs state path cannot be empty.' }
    if ([IO.Path]::IsPathRooted($StatePath) -or $StatePath.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw ('Absolute or UNC img2threejs state paths are denied: ' + $StatePath)
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $StatePath.Contains(':')) {
        throw ('Drive-relative paths and alternate data streams are denied: ' + $StatePath)
    }
    $normalized = $StatePath.Replace([char]92, [char]47)
    $parts = @($normalized -split '/')
    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[-1])) {
        throw 'The state path must name a JSON file below .img2threejs/.'
    }
    if (-not $parts[0].Equals('.img2threejs', (Get-Img2ThreejsStatePathComparison))) {
        throw 'The state path must be relative to the project and start with .img2threejs/.'
    }
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -in @('.', '..')) {
            throw ('Traversal, empty, and dot path segments are denied: ' + $StatePath)
        }
    }
    if ([IO.Path]::GetExtension($parts[-1]) -cne '.json') {
        throw 'An img2threejs state target must have a .json extension.'
    }
    return [pscustomobject]@{
        Normalized = ($parts -join '/')
        RelativeBelowRoot = (($parts | Select-Object -Skip 1) -join [IO.Path]::DirectorySeparatorChar)
    }
}

function Initialize-Img2ThreejsAuthorizedStateRoot {
    param(
        [Parameter(Mandatory)][string]$CanonicalProjectRoot,
        [switch]$Create
    )
    $authorizedLexical = [IO.Path]::GetFullPath((Join-Path $CanonicalProjectRoot '.img2threejs'))
    if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $CanonicalProjectRoot -Candidate $authorizedLexical)) {
        throw 'The authorized img2threejs state root escapes the project root.'
    }
    $rootItem = Get-Img2ThreejsStateExistingItem -LiteralPath $authorizedLexical
    if ($null -eq $rootItem) {
        if (-not $Create) { throw 'The authorized img2threejs state root does not exist.' }
        $projectAgain = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $CanonicalProjectRoot
        if (-not $projectAgain.Equals($CanonicalProjectRoot, (Get-Img2ThreejsStatePathComparison))) {
            throw 'The canonical project root changed before state-root creation.'
        }
        [IO.Directory]::CreateDirectory($authorizedLexical) | Out-Null
        $rootItem = Get-Item -Force -LiteralPath $authorizedLexical
    }
    if (-not $rootItem.PSIsContainer) { throw 'The authorized img2threejs state root must be a directory.' }
    Assert-Img2ThreejsStateItemNotReparse -Item $rootItem
    $authorizedCanonical = (Resolve-Path -LiteralPath $rootItem.FullName).Path.TrimEnd([char[]]@([char]92, [char]47))
    if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $CanonicalProjectRoot -Candidate $authorizedCanonical)) {
        throw 'The physical img2threejs state root is outside the project root.'
    }
    Assert-Img2ThreejsStateBoundaryComponents -Root $authorizedCanonical -Candidate $authorizedCanonical
    return $authorizedCanonical
}

function Add-Img2ThreejsStateTrace {
    param([System.Collections.IList]$Trace, [Parameter(Mandatory)][string]$Event)
    if ($null -ne $Trace) { [void]$Trace.Add($Event) }
}

function Resolve-Img2ThreejsStateTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$StatePath,
        [switch]$CreateAuthorizedRoot,
        [System.Collections.IList]$Trace
    )
    $input = Assert-Img2ThreejsStateInput -StatePath $StatePath
    Add-Img2ThreejsStateTrace -Trace $Trace -Event 'input-validated'
    $projectCanonical = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    $authorizedRoot = Initialize-Img2ThreejsAuthorizedStateRoot -CanonicalProjectRoot $projectCanonical -Create:$CreateAuthorizedRoot
    $candidateLexical = [IO.Path]::GetFullPath((Join-Path $authorizedRoot $input.RelativeBelowRoot))
    if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $authorizedRoot -Candidate $candidateLexical)) {
        throw ('The img2threejs state path escapes its authorized root: ' + $StatePath)
    }
    Assert-Img2ThreejsStateBoundaryComponents -Root $authorizedRoot -Candidate $candidateLexical
    $candidateItem = Get-Img2ThreejsStateExistingItem -LiteralPath $candidateLexical
    if ($null -ne $candidateItem) {
        Assert-Img2ThreejsStateItemNotReparse -Item $candidateItem
        $candidateCanonical = (Resolve-Path -LiteralPath $candidateItem.FullName).Path
    } else {
        $ancestor = Split-Path -Parent $candidateLexical
        $missing = New-Object 'System.Collections.Generic.List[string]'
        while ($null -eq (Get-Img2ThreejsStateExistingItem -LiteralPath $ancestor)) {
            $missing.Insert(0, (Split-Path -Leaf $ancestor))
            $parent = Split-Path -Parent $ancestor
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $ancestor) {
                throw 'No existing ancestor was found inside the authorized state root.'
            }
            $ancestor = $parent
        }
        Assert-Img2ThreejsStateBoundaryComponents -Root $authorizedRoot -Candidate $ancestor
        $ancestorCanonical = (Resolve-Path -LiteralPath $ancestor).Path
        if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $authorizedRoot -Candidate $ancestorCanonical -AllowRoot)) {
            throw 'The nearest existing state ancestor resolves outside the authorized root.'
        }
        $rebuiltParent = $ancestorCanonical
        foreach ($segment in $missing) {
            if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or $segment.Contains(':')) {
                throw 'An invalid segment was found while rebuilding the state target.'
            }
            $rebuiltParent = Join-Path $rebuiltParent $segment
        }
        $candidateCanonical = [IO.Path]::GetFullPath((Join-Path $rebuiltParent (Split-Path -Leaf $candidateLexical)))
    }
    if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $authorizedRoot -Candidate $candidateCanonical)) {
        throw 'The canonical img2threejs state target is outside the authorized root.'
    }
    $parentCanonical = [IO.Path]::GetFullPath((Split-Path -Parent $candidateCanonical))
    if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $authorizedRoot -Candidate $parentCanonical -AllowRoot)) {
        throw 'The canonical img2threejs state parent is outside the authorized root.'
    }
    Assert-Img2ThreejsStateBoundaryComponents -Root $authorizedRoot -Candidate $candidateCanonical
    Add-Img2ThreejsStateTrace -Trace $Trace -Event 'canonical-target-approved'
    return [pscustomobject][ordered]@{
        ProjectRoot = $projectCanonical
        AuthorizedRoot = $authorizedRoot
        CanonicalPath = $candidateCanonical
        ParentPath = $parentCanonical
        RelativePath = $input.Normalized
    }
}

function Resolve-Img2ThreejsInternalStatePath {
    param(
        [Parameter(Mandatory)][string]$AuthorizedRoot,
        [Parameter(Mandatory)][string]$Candidate
    )
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not (Test-Img2ThreejsStatePathWithinRoot -Root $AuthorizedRoot -Candidate $candidateFull)) {
        throw 'An internal img2threejs state path escaped the authorized root.'
    }
    Assert-Img2ThreejsStateBoundaryComponents -Root $AuthorizedRoot -Candidate $candidateFull
    return $candidateFull
}

function Ensure-Img2ThreejsStateParent {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][System.Collections.IList]$Trace
    )
    while ($true) {
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $ProjectRoot -StatePath $StatePath -CreateAuthorizedRoot -Trace $Trace
        if (Test-Path -LiteralPath $approved.ParentPath -PathType Container) { return $approved }
        $ancestor = $approved.ParentPath
        $missing = New-Object 'System.Collections.Generic.List[string]'
        while (-not (Test-Path -LiteralPath $ancestor -PathType Container)) {
            $missing.Insert(0, (Split-Path -Leaf $ancestor))
            $ancestor = Split-Path -Parent $ancestor
        }
        $nextDirectory = Join-Path $ancestor $missing[0]
        Resolve-Img2ThreejsInternalStatePath -AuthorizedRoot $approved.AuthorizedRoot -Candidate $nextDirectory | Out-Null
        Add-Img2ThreejsStateTrace -Trace $Trace -Event 'pre-directory-create-recheck'
        [IO.Directory]::CreateDirectory($nextDirectory) | Out-Null
        $created = Get-Item -Force -LiteralPath $nextDirectory
        Assert-Img2ThreejsStateItemNotReparse -Item $created
        Add-Img2ThreejsStateTrace -Trace $Trace -Event 'directory-created-and-verified'
    }
}

function Assert-Img2ThreejsJsonText {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$JsonText)
    try { $null = ConvertFrom-Json -InputObject $JsonText -ErrorAction Stop }
    catch { throw ('Img2threejs state content must be valid JSON: ' + $_.Exception.Message) }
}

function Get-Img2ThreejsStateOperationContract {
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Operation = 'init'; Access = 'create'; Handler = 'ftk.state.create'; UpstreamPhase = 'SR2D' }
        [pscustomobject]@{ Operation = 'status'; Access = 'read'; Handler = 'ftk.state.read'; UpstreamPhase = 'SR2D' }
        [pscustomobject]@{ Operation = 'mark'; Access = 'update'; Handler = 'ftk.state.update'; UpstreamPhase = 'SR2D' }
        [pscustomobject]@{ Operation = 'next'; Access = 'read-update'; Handler = 'ftk.state.read/ftk.state.update'; UpstreamPhase = 'SR2D' }
        [pscustomobject]@{ Operation = 'read'; Access = 'read'; Handler = 'ftk.state.read'; UpstreamPhase = 'SR2C' }
        [pscustomobject]@{ Operation = 'write'; Access = 'upsert'; Handler = 'ftk.state.write'; UpstreamPhase = 'SR2C' }
        [pscustomobject]@{ Operation = 'update'; Access = 'update'; Handler = 'ftk.state.update'; UpstreamPhase = 'SR2C' }
    )
}

function Read-Img2ThreejsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$StatePath = '.img2threejs/state.json'
    )
    $trace = New-Object 'System.Collections.Generic.List[string]'
    $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $ProjectRoot -StatePath $StatePath -Trace $trace
    if (-not (Test-Path -LiteralPath $approved.CanonicalPath -PathType Leaf)) {
        throw ('Img2threejs state file does not exist: ' + $StatePath)
    }
    $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $ProjectRoot -StatePath $StatePath -Trace $trace
    Add-Img2ThreejsStateTrace -Trace $trace -Event 'pre-read-recheck'
    return [pscustomobject][ordered]@{
        Operation = 'read'
        CanonicalPath = $approved.CanonicalPath
        JsonText = [IO.File]::ReadAllText($approved.CanonicalPath, [Text.Encoding]::UTF8)
        Trace = @($trace)
    }
}

function Write-Img2ThreejsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$StatePath = '.img2threejs/state.json',
        [AllowEmptyString()][Parameter(Mandatory)][string]$JsonText,
        [ValidateSet('Create','Write','Update')][string]$Mode = 'Write'
    )
    Assert-Img2ThreejsJsonText -JsonText $JsonText
    $trace = New-Object 'System.Collections.Generic.List[string]'
    $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $ProjectRoot -StatePath $StatePath -CreateAuthorizedRoot -Trace $trace
    $exists = Test-Path -LiteralPath $approved.CanonicalPath -PathType Leaf
    if ($Mode -eq 'Create' -and $exists) { throw ('Refusing to overwrite existing img2threejs state: ' + $StatePath) }
    if ($Mode -eq 'Update' -and -not $exists) { throw ('Cannot update missing img2threejs state: ' + $StatePath) }

    $approved = Ensure-Img2ThreejsStateParent -ProjectRoot $ProjectRoot -StatePath $StatePath -Trace $trace
    $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $ProjectRoot -StatePath $StatePath -CreateAuthorizedRoot -Trace $trace
    $temporary = Join-Path $approved.ParentPath ('.' + [IO.Path]::GetFileName($approved.CanonicalPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $temporary = Resolve-Img2ThreejsInternalStatePath -AuthorizedRoot $approved.AuthorizedRoot -Candidate $temporary
    Add-Img2ThreejsStateTrace -Trace $trace -Event 'pre-temporary-create-recheck'
    $backup = $null
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($JsonText)
    try {
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        Add-Img2ThreejsStateTrace -Trace $trace -Event 'temporary-written'

        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $ProjectRoot -StatePath $StatePath -CreateAuthorizedRoot -Trace $trace
        $temporary = Resolve-Img2ThreejsInternalStatePath -AuthorizedRoot $approved.AuthorizedRoot -Candidate $temporary
        $existsNow = Test-Path -LiteralPath $approved.CanonicalPath -PathType Leaf
        if ($Mode -eq 'Create' -and $existsNow) { throw ('Refusing to overwrite existing img2threejs state: ' + $StatePath) }
        if ($Mode -eq 'Update' -and -not $existsNow) { throw ('Cannot update missing img2threejs state: ' + $StatePath) }
        if ($existsNow) {
            $backup = Join-Path $approved.ParentPath ('.' + [IO.Path]::GetFileName($approved.CanonicalPath) + '.' + [guid]::NewGuid().ToString('N') + '.bak')
            $backup = Resolve-Img2ThreejsInternalStatePath -AuthorizedRoot $approved.AuthorizedRoot -Candidate $backup
        }
        Add-Img2ThreejsStateTrace -Trace $trace -Event 'pre-atomic-commit-recheck'
        if ($existsNow) { [IO.File]::Replace($temporary, $approved.CanonicalPath, $backup) }
        else { [IO.File]::Move($temporary, $approved.CanonicalPath) }
        Add-Img2ThreejsStateTrace -Trace $trace -Event 'atomic-commit-complete'
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
            $safeBackup = Resolve-Img2ThreejsInternalStatePath -AuthorizedRoot $approved.AuthorizedRoot -Candidate $backup
            [IO.File]::Delete($safeBackup)
        }

        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $ProjectRoot -StatePath $StatePath -Trace $trace
        if (-not (Test-Path -LiteralPath $approved.CanonicalPath -PathType Leaf)) {
            throw 'The img2threejs state target failed post-write verification.'
        }
        Add-Img2ThreejsStateTrace -Trace $trace -Event 'post-write-verified'
        return [pscustomobject][ordered]@{
            Operation = $Mode.ToLowerInvariant()
            CanonicalPath = $approved.CanonicalPath
            BytesWritten = $bytes.Length
            Trace = @($trace)
        }
    } finally {
        if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            try {
                $safeTemporary = Resolve-Img2ThreejsInternalStatePath -AuthorizedRoot $approved.AuthorizedRoot -Candidate $temporary
                [IO.File]::Delete($safeTemporary)
            } catch {
                # Never delete a temporary path that no longer passes containment.
            }
        }
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
            try {
                $safeBackup = Resolve-Img2ThreejsInternalStatePath -AuthorizedRoot $approved.AuthorizedRoot -Candidate $backup
                [IO.File]::Delete($safeBackup)
            } catch {
                # Never delete a backup path that no longer passes containment.
            }
        }
    }
}

function New-Img2ThreejsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$StatePath = '.img2threejs/state.json',
        [AllowEmptyString()][Parameter(Mandatory)][string]$JsonText
    )
    return Write-Img2ThreejsState -ProjectRoot $ProjectRoot -StatePath $StatePath -JsonText $JsonText -Mode Create
}

function Update-Img2ThreejsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$StatePath = '.img2threejs/state.json',
        [AllowEmptyString()][Parameter(Mandatory)][string]$JsonText
    )
    return Write-Img2ThreejsState -ProjectRoot $ProjectRoot -StatePath $StatePath -JsonText $JsonText -Mode Update
}
