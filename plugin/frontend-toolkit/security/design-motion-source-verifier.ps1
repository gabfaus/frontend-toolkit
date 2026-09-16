Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'design-motion-contract.ps1')

function ConvertTo-DesignMotionWindowsNativeArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s\"]') { return $Argument }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $slashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-DesignMotionGit {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $safeRoot = [IO.Path]::GetFullPath($RepositoryRoot).Replace('\', '/')
    $allArguments = @('-c', "safe.directory=$safeRoot", '-C', $RepositoryRoot) + @($Arguments)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $gitCommand = Get-Command git -ErrorAction Stop
    if ($gitCommand.CommandType -ne 'Application' -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) { throw 'The Git metadata utility is unavailable.' }
    $startInfo.FileName = [IO.Path]::GetFullPath($gitCommand.Source)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($allArguments | ForEach-Object { ConvertTo-DesignMotionWindowsNativeArgument ([string]$_) }) -join ' ')
    Set-DesignMotionGitChildEnvironment -StartInfo $startInfo
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutStream = New-Object IO.MemoryStream
    try {
        if (-not $process.Start()) { throw 'Git metadata process did not start.' }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdoutTask.Wait()
        $stderrTask.Wait()
        $process.WaitForExit()
        return [pscustomobject][ordered]@{
            exitCode = [int]$process.ExitCode
            stdoutBytes = $stdoutStream.ToArray()
            stderr = [string]$stderrTask.Result
        }
    } finally {
        $stdoutStream.Dispose()
        $process.Dispose()
    }
}

function Set-DesignMotionGitChildEnvironment {
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo)

    $environment = [ordered]@{}
    foreach ($name in @('SystemRoot', 'TEMP', 'TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
    }
    $environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $environment['GIT_CONFIG_GLOBAL'] = 'NUL'
    $environment['GIT_CONFIG_SYSTEM'] = 'NUL'
    $environment['GIT_OPTIONAL_LOCKS'] = '0'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    try {
        $variables = $StartInfo.EnvironmentVariables
        if ($null -eq $variables) { throw 'ProcessStartInfo environment dictionary is unavailable.' }
        $variables.Clear()
    } catch {
        $field = $StartInfo.GetType().GetField('environmentVariables', [Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -eq $field) { throw 'Unable to create the isolated Git metadata environment.' }
        $variables = New-Object Collections.Specialized.StringDictionary
        $field.SetValue($StartInfo, $variables)
        $variables.Clear()
    }
    foreach ($name in $environment.Keys) { $variables.Add([string]$name, [string]$environment[$name]) }
}

function Invoke-DesignMotionGitText {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-DesignMotionGit -RepositoryRoot $RepositoryRoot -Arguments $Arguments
    return [pscustomobject][ordered]@{
        exitCode = $result.exitCode
        stdout = [Text.Encoding]::UTF8.GetString([byte[]]$result.stdoutBytes)
        stderr = $result.stderr
    }
}

function Get-DesignMotionSha256 {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function ConvertTo-DesignMotionCanonicalLfBytes {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Bytes)

    $normalized = New-Object Collections.Generic.List[byte]
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -eq 13) {
            if ($index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) {
                [void]$normalized.Add(10)
                $index++
            } else {
                [void]$normalized.Add($Bytes[$index])
            }
        } else {
            [void]$normalized.Add($Bytes[$index])
        }
    }
    return $normalized.ToArray()
}

function ConvertTo-DesignMotionCrLfBytes {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$CanonicalLfBytes)

    $normalized = New-Object Collections.Generic.List[byte]
    foreach ($byte in $CanonicalLfBytes) {
        if ($byte -eq 10) { [void]$normalized.Add(13) }
        [void]$normalized.Add($byte)
    }
    return $normalized.ToArray()
}

function Get-DesignMotionByteHashSet {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Bytes)

    $canonical = ConvertTo-DesignMotionCanonicalLfBytes $Bytes
    $crlf = ConvertTo-DesignMotionCrLfBytes $canonical
    return [pscustomobject][ordered]@{
        rawSha256 = Get-DesignMotionSha256 $Bytes
        canonicalLfSha256 = Get-DesignMotionSha256 $canonical
        crlfNormalizedSha256 = Get-DesignMotionSha256 $crlf
        rawLength = $Bytes.Length
        canonicalLfLength = $canonical.Length
        crlfNormalizedLength = $crlf.Length
    }
}

function Test-DesignMotionByteEquality {
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Left,
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Test-DesignMotionContainsNul {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Bytes)

    foreach ($byte in $Bytes) {
        if ($byte -eq 0) { return $true }
    }
    return $false
}

function Compare-DesignMotionWorktreeToIndex {
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$IndexBytes,
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$WorktreeBytes
    )

    if (Test-DesignMotionByteEquality -Left $IndexBytes -Right $WorktreeBytes) { return 'EXACT' }

    # NUL-bearing content is binary for this contract. Binary bytes never get
    # newline tolerance, even when their remaining bytes happen to normalize.
    if ((Test-DesignMotionContainsNul $IndexBytes) -or (Test-DesignMotionContainsNul $WorktreeBytes)) {
        return $null
    }

    $indexLf = ConvertTo-DesignMotionCanonicalLfBytes $IndexBytes
    $worktreeLf = ConvertTo-DesignMotionCanonicalLfBytes $WorktreeBytes
    if (Test-DesignMotionByteEquality -Left $indexLf -Right $worktreeLf) { return 'CRLF_LF_EQUIVALENT' }
    return $null
}

function ConvertFrom-DesignMotionUtf8 {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Bytes)

    return [Text.Encoding]::UTF8.GetString($Bytes)
}

function ConvertTo-DesignMotionOriginKey {
    param([Parameter(Mandatory)][string]$Origin)

    $trimmed = $Origin.Trim()
    try {
        $uri = New-Object Uri($trimmed)
        if ($uri.Scheme -cne 'https' -or -not [string]::IsNullOrWhiteSpace($uri.UserInfo)) { return $trimmed.ToLowerInvariant() }
        $authority = $uri.Authority.ToLowerInvariant()
        $path = $uri.AbsolutePath.Trim('/')
        if ($path.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring(0, $path.Length - 4).TrimEnd('/') }
        $suffix = $uri.Query + $uri.Fragment
        return ("https://{0}/{1}{2}" -f $authority, $path, $suffix).TrimEnd('/')
    } catch {
        return $trimmed.TrimEnd('/').ToLowerInvariant()
    }
}

function Get-DesignMotionLockDependency {
    param(
        [Parameter(Mandatory)][object]$Lock,
        [Parameter(Mandatory)][ValidateSet('taste', 'review-animations', 'improve-animations')][string]$Operation
    )

    $dependencies = @($Lock.dependencies)
    if ($Operation -eq 'taste') {
        $matches = @($dependencies | Where-Object { $_.id -ceq 'taste-design-taste-frontend-v2' })
        if ($matches.Count -ne 1) { throw 'Taste dependency is absent or duplicated in design-motion.lock.json.' }
        return $matches[0]
    }
    $matches = @($dependencies | Where-Object { $_.id -ceq 'emil-animation-skills' })
    if ($matches.Count -ne 1) { throw 'Emil dependency is absent or duplicated in design-motion.lock.json.' }
    $approved = @($matches[0].approvedSkills | Where-Object { $_.skillName -ceq $Operation })
    if ($approved.Count -ne 1) { throw "Approved Emil entry is absent or duplicated: $Operation." }
    return [pscustomobject][ordered]@{
        dependency = $matches[0]
        entry = $approved[0]
    }
}

function Get-DesignMotionSourceFailure {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][bool]$Materialized,
        [Parameter(Mandatory)][string]$Reason,
        [string]$DependencyId = '',
        [string]$SourceRoot = ''
    )

    return [pscustomobject][ordered]@{
        verified = $false
        materialized = $Materialized
        verificationAttempted = $true
        dependencyId = $DependencyId
        operation = $Operation
        sourceRoot = $SourceRoot
        sourceFingerprint = $null
        representation = $null
        files = @()
        failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
        reason = (ConvertTo-FtkBoundedDiagnostic -Value $Reason -MaximumCharacters 2048)
    }
}

function Resolve-DesignMotionSourceRoot {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$Dependency,
        [AllowNull()][string]$SourceRoot
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
        Join-Path $RepoRoot ([string]$Dependency.checkoutPath)
    } else { $SourceRoot }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return $null }
    $candidateItem = Get-Item -LiteralPath $candidate -Force
    if ($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Design-motion source root cannot be a reparse point.' }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Design-motion source root cannot be a reparse point.' }
    return [IO.Path]::GetFullPath($resolved)
}

function Assert-DesignMotionRelativeSourcePath {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '[\\]' -or $RelativePath -match '(^|/)\.\.(/|$)' -or $RelativePath.StartsWith('/') -or
        $RelativePath -match '[\x00-\x1f]') {
        throw "Source path is not a canonical relative allowlisted path: $RelativePath."
    }
}

function ConvertFrom-DesignMotionUtf8Strict {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Bytes)

    $encoding = New-Object Text.UTF8Encoding($false, $true)
    return $encoding.GetString($Bytes)
}

function ConvertFrom-DesignMotionGitStatusBytes {
    param([AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][byte[]]$Bytes)

    if ($Bytes.Length -eq 0) { return @() }
    $text = ConvertFrom-DesignMotionUtf8Strict $Bytes
    if ($text.Length -eq 0 -or $text[$text.Length - 1] -ne [char]0) {
        throw 'Git status output is not NUL terminated.'
    }

    $segments = $text.Split([char]0)
    $entries = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt $segments.Count; $index++) {
        if ($index -eq $segments.Count - 1 -and [string]::IsNullOrEmpty($segments[$index])) { continue }
        $segment = [string]$segments[$index]
        if ($segment.Length -lt 4 -or $segment[2] -cne ' ' -or [string]::IsNullOrEmpty($segment.Substring(3))) {
            throw 'Git status output contains a malformed porcelain-v1 record.'
        }
        $status = $segment.Substring(0, 2)
        [void]$entries.Add([pscustomobject][ordered]@{
                indexStatus = $status[0]
                worktreeStatus = $status[1]
                path = $segment.Substring(3)
                status = $status
            })

        # Porcelain -z emits the old path as a second NUL-delimited field for
        # renames/copies. The status itself is already dirty; consume the field
        # without interpreting it as another status record.
        if ($status[0] -in @('R', 'C')) {
            $index++
            if ($index -ge $segments.Count - 1 -or [string]::IsNullOrEmpty($segments[$index])) {
                throw 'Git status rename/copy record is incomplete.'
            }
        }
    }
    return $entries.ToArray()
}

function Get-DesignMotionIndexBlob {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    Assert-DesignMotionRelativeSourcePath $RelativePath
    $result = Invoke-DesignMotionGit -RepositoryRoot $SourceRoot -Arguments @('ls-files', '--stage', '-z', '--', $RelativePath)
    if ($result.exitCode -ne 0) { throw "Git index lookup failed for $RelativePath." }
    $text = ConvertFrom-DesignMotionUtf8Strict ([byte[]]$result.stdoutBytes)
    if ($text.Length -eq 0 -or $text[$text.Length - 1] -ne [char]0) {
        throw "Git index lookup is not NUL terminated for $RelativePath."
    }
    $records = @($text.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($records.Count -ne 1) { throw "Git index does not contain exactly one stage-zero entry for $RelativePath." }

    $record = [string]$records[0]
    $tab = $record.IndexOf([char]9)
    if ($tab -lt 0 -or $record.Substring($tab + 1) -cne $RelativePath) {
        throw "Git index path does not match $RelativePath."
    }
    $metadata = $record.Substring(0, $tab)
    if ($metadata -notmatch '^(?<mode>[0-9]{6}) (?<object>[0-9a-fA-F]{40}) (?<stage>[0-3])$' -or $Matches.stage -ne '0') {
        throw "Git index entry is malformed or conflicted for $RelativePath."
    }
    if ($Matches.mode -notin @('100644', '100755')) {
        throw "Git index entry is not a regular file for $RelativePath."
    }

    $blob = Invoke-DesignMotionGit -RepositoryRoot $SourceRoot -Arguments @('cat-file', 'blob', $Matches.object)
    if ($blob.exitCode -ne 0) { throw "Git index blob read failed for $RelativePath." }
    return [pscustomobject][ordered]@{
        path = $RelativePath
        mode = $Matches.mode
        object = $Matches.object
        bytes = [byte[]]$blob.stdoutBytes
    }
}

function Get-DesignMotionSourceCleanliness {
    param([Parameter(Mandatory)][string]$SourceRoot)

    try {
        $statusResult = Invoke-DesignMotionGit -RepositoryRoot $SourceRoot -Arguments @('--no-optional-locks', 'status', '--porcelain=v1', '-z', '--untracked-files=all')
        if ($statusResult.exitCode -ne 0) {
            return [pscustomobject][ordered]@{
                clean = $false
                representation = 'DIRTY'
                statusEntries = @()
                reason = 'Git status failed in the isolated metadata environment.'
            }
        }

        $entries = @(ConvertFrom-DesignMotionGitStatusBytes ([byte[]]$statusResult.stdoutBytes))
        if ($entries.Count -eq 0) {
            return [pscustomobject][ordered]@{
                clean = $true
                representation = 'EXACT'
                statusEntries = @()
                reason = $null
            }
        }

        $representations = New-Object Collections.Generic.List[string]
        foreach ($entry in $entries) {
            if ($entry.indexStatus -cne ' ') {
                return [pscustomobject][ordered]@{
                    clean = $false
                    representation = 'DIRTY'
                    statusEntries = $entries
                    reason = "Index change is not clean-equivalent: $($entry.status) $($entry.path)"
                }
            }
            if ($entry.worktreeStatus -cne 'M') {
                return [pscustomobject][ordered]@{
                    clean = $false
                    representation = 'DIRTY'
                    statusEntries = $entries
                    reason = "Worktree status is not a regular modification: $($entry.status) $($entry.path)"
                }
            }

            $indexBlob = Get-DesignMotionIndexBlob -SourceRoot $SourceRoot -RelativePath ([string]$entry.path)
            $relativeForWindows = ([string]$entry.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $worktreePath = [IO.Path]::GetFullPath((Join-Path $SourceRoot $relativeForWindows))
            $rootPrefix = ([IO.Path]::GetFullPath($SourceRoot)).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
            if (-not $worktreePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject][ordered]@{
                    clean = $false
                    representation = 'DIRTY'
                    statusEntries = $entries
                    reason = "Worktree path escapes the source root: $($entry.path)"
                }
            }
            $worktreeItem = Get-Item -LiteralPath $worktreePath -Force
            if ($worktreeItem.PSIsContainer -or ($worktreeItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                return [pscustomobject][ordered]@{
                    clean = $false
                    representation = 'DIRTY'
                    statusEntries = $entries
                    reason = "Worktree path is not a regular non-reparse file: $($entry.path)"
                }
            }
            $worktreeBytes = [IO.File]::ReadAllBytes($worktreePath)
            $representation = Compare-DesignMotionWorktreeToIndex -IndexBytes $indexBlob.bytes -WorktreeBytes $worktreeBytes
            if ($null -eq $representation) {
                return [pscustomobject][ordered]@{
                    clean = $false
                    representation = 'DIRTY'
                    statusEntries = $entries
                    reason = "Worktree bytes are not exact or strict CRLF/LF-equivalent to the index blob: $($entry.path)"
                }
            }
            [void]$representations.Add($representation)
        }

        $aggregateRepresentation = if (@($representations | Where-Object { $_ -cne 'EXACT' }).Count -eq 0) {
            'EXACT'
        } else {
            'CRLF_LF_EQUIVALENT'
        }
        return [pscustomobject][ordered]@{
            clean = $true
            representation = $aggregateRepresentation
            statusEntries = $entries
            reason = $null
        }
    } catch {
        return [pscustomobject][ordered]@{
            clean = $false
            representation = 'DIRTY'
            statusEntries = @()
            reason = (ConvertTo-FtkBoundedDiagnostic -Value $_.Exception.Message -MaximumCharacters 2048)
        }
    }
}

function Get-DesignMotionGitTreeEntry {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $result = Invoke-DesignMotionGitText $SourceRoot @('ls-tree', '-r', '--full-tree', $Commit, '--', $RelativePath)
    if ($result.exitCode -ne 0) { throw "Git tree lookup failed for $RelativePath." }
    $line = @($result.stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    if ($line -notmatch '^(?<mode>[0-9]{6})\s+(?<type>blob|tree)\s+(?<object>[0-9a-f]{40})\t(?<path>.+)$') {
        throw "Git tree entry is malformed for $RelativePath."
    }
    return [pscustomobject][ordered]@{
        mode = $Matches.mode
        type = $Matches.type
        object = $Matches.object
        path = $Matches.path
    }
}

function Get-DesignMotionGitBlob {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $entry = Get-DesignMotionGitTreeEntry -SourceRoot $SourceRoot -Commit $Commit -RelativePath $RelativePath
    if ($null -eq $entry -or $entry.type -cne 'blob') { throw "Required source file is absent: $RelativePath." }
    if ($entry.mode -notin @('100644', '100755')) { throw "Required source file is not a regular file: $RelativePath." }
    $object = '{0}:{1}' -f $Commit, $RelativePath
    $result = Invoke-DesignMotionGit -RepositoryRoot $SourceRoot -Arguments @('cat-file', 'blob', $object)
    if ($result.exitCode -ne 0) { throw "Git blob read failed for $RelativePath." }
    return [pscustomobject][ordered]@{
        path = $RelativePath
        mode = $entry.mode
        bytes = [byte[]]$result.stdoutBytes
    }
}

function Get-DesignMotionRequiredSourceFiles {
    param(
        [Parameter(Mandatory)][ValidateSet('taste', 'review-animations', 'improve-animations')][string]$Operation,
        [Parameter(Mandatory)][object]$DependencyRecord,
        [Parameter(Mandatory)][object]$EntryRecord,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$Commit
    )

    if ($Operation -eq 'taste') {
        return @(
            [pscustomobject][ordered]@{ path = [string]$DependencyRecord.skillPath; role = 'skill-entry'; expectedSha256 = [string]$DependencyRecord.skillEntrySha256 }
            [pscustomobject][ordered]@{ path = [string]$DependencyRecord.licensePath; role = 'license'; expectedSha256 = [string]$DependencyRecord.licenseSha256 }
        )
    }
    $skillPath = [string]$EntryRecord.skillPath
    $files = New-Object Collections.Generic.List[object]
    [void]$files.Add([pscustomobject][ordered]@{ path = $skillPath; role = 'skill-entry'; expectedSha256 = [string]$EntryRecord.skillEntrySha256 })
    [void]$files.Add([pscustomobject][ordered]@{ path = [string]$DependencyRecord.licensePath; role = 'license'; expectedSha256 = [string]$DependencyRecord.licenseSha256 })

    if ($Operation -eq 'review-animations') {
        Assert-DesignMotionRelativeSourcePath $skillPath
        $skillBlob = Get-DesignMotionGitBlob -SourceRoot $SourceRoot -Commit $Commit -RelativePath $skillPath
        $skillText = ConvertFrom-DesignMotionUtf8 $skillBlob.bytes
        if ($skillText -match '(?i)STANDARDS\.md') {
            [void]$files.Add([pscustomobject][ordered]@{ path = 'skills/review-animations/STANDARDS.md'; role = 'referenced-standard'; expectedSha256 = $null })
        }
    } else {
        [void]$files.Add([pscustomobject][ordered]@{ path = 'skills/improve-animations/AUDIT.md'; role = 'referenced-audit'; expectedSha256 = $null })
        [void]$files.Add([pscustomobject][ordered]@{ path = 'skills/improve-animations/PLAN-TEMPLATE.md'; role = 'referenced-plan-template'; expectedSha256 = $null })
    }
    return @($files.ToArray())
}

function Invoke-DesignMotionSourceVerification {
    param(
        [Parameter(Mandatory)][ValidateSet('taste', 'review-animations', 'improve-animations')][string]$Operation,
        [string]$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')),
        [string]$LockPath = '',
        [AllowNull()][string]$SourceRoot,
        [switch]$AllowSyntheticLock
    )

    try {
        $resolvedRepoRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path)
        $usingSyntheticLock = -not [string]::IsNullOrWhiteSpace($LockPath)
        if ($usingSyntheticLock -and -not $AllowSyntheticLock) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -Reason 'A non-committed source lock override is denied outside hermetic test mode.'
        }
        if ($usingSyntheticLock) {
            if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
                return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -Reason 'design-motion.lock.json is unavailable.'
            }
            $lockText = Get-Content -Raw -LiteralPath $LockPath
        } else {
            $lockHeadResult = Invoke-DesignMotionGitText $resolvedRepoRoot @('rev-parse', '--verify', 'HEAD')
            if ($lockHeadResult.exitCode -ne 0) { return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -Reason 'The committed design-motion lock cannot establish HEAD.' }
            $lockBlob = Get-DesignMotionGitBlob -SourceRoot $resolvedRepoRoot -Commit $lockHeadResult.stdout.Trim() -RelativePath 'integrations/design-motion.lock.json'
            $lockText = ConvertFrom-DesignMotionUtf8 $lockBlob.bytes
        }
        $lock = $lockText | ConvertFrom-Json
        if ([int]$lock.schemaVersion -ne 1 -or [string]$lock.lane -cne 'design-motion') {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -Reason 'design-motion.lock.json has an unsupported identity.'
        }

        $selection = Get-DesignMotionLockDependency -Lock $lock -Operation $Operation
        if ($Operation -eq 'taste') {
            $dependency = $selection
            $entry = $selection
        } else {
            $dependency = $selection.dependency
            $entry = $selection.entry
        }
        $dependencyId = [string]$dependency.id
        if ([string]$dependency.upstream -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://[^\s]+$' -or
            [string]$dependency.commitSha -notmatch '^[0-9a-fA-F]{40}$' -or [string]::IsNullOrWhiteSpace([string]$dependency.ref)) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -DependencyId $dependencyId -Reason 'The source lock has malformed origin, ref, or exact pin metadata.'
        }
        $expectedSkillPath = switch ($Operation) {
            'taste' { 'skills/taste-skill/SKILL.md' }
            'review-animations' { 'skills/review-animations/SKILL.md' }
            'improve-animations' { 'skills/improve-animations/SKILL.md' }
        }
        $lockedSkillPath = if ($Operation -eq 'taste') { [string]$dependency.skillPath } else { [string]$entry.skillPath }
        if ($lockedSkillPath -cne $expectedSkillPath -or [string]$dependency.licensePath -cne 'LICENSE') {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -DependencyId $dependencyId -Reason 'The lock entry is outside the Phase 1 source allowlist.'
        }
        if ($Operation -eq 'taste') {
            if ([string]$dependency.selection -cne 'explicit-only' -or [bool]$dependency.defaultLoaded) {
                return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -DependencyId $dependencyId -Reason 'Taste lock selection is not explicit-only.'
            }
            foreach ($excludedPath in @($dependency.excludedSourcePaths)) {
                if ($expectedSkillPath -ceq [string]$excludedPath -or $expectedSkillPath.StartsWith(([string]$excludedPath).TrimEnd('/') + '/', [StringComparison]::Ordinal)) {
                    return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -DependencyId $dependencyId -Reason 'Taste source allowlist overlaps an excluded path.'
                }
            }
        } else {
            if (@($dependency.excludedSkillNames | Where-Object { $_ -ceq $Operation }).Count -gt 0 -or [bool]$entry.defaultLoaded) {
                return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -DependencyId $dependencyId -Reason 'Emil lock selection is excluded or default-loaded.'
            }
            $expectedMode = if ($Operation -eq 'review-animations') { 'verify-read-only' } else { 'diagnose-plan' }
            if ([string]$entry.mode -cne $expectedMode) {
                return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -DependencyId $dependencyId -Reason 'Emil lock mode is outside the Phase 1 contract.'
            }
        }
        $resolvedSourceRoot = Resolve-DesignMotionSourceRoot -RepoRoot $resolvedRepoRoot -Dependency $dependency -SourceRoot $SourceRoot
        if ($null -eq $resolvedSourceRoot) {
            $reportedSourceRoot = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { [string]$dependency.checkoutPath } else { $SourceRoot }
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$false -DependencyId $dependencyId -Reason 'The governed source checkout is not materialized.' -SourceRoot $reportedSourceRoot
        }

        $originResult = Invoke-DesignMotionGitText $resolvedSourceRoot @('config', '--get-all', 'remote.origin.url')
        if ($originResult.exitCode -ne 0) { return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The source checkout has no readable origin remote.' }
        $origins = @($originResult.stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        if ($origins.Count -ne 1 -or (ConvertTo-DesignMotionOriginKey $origins[0]) -cne (ConvertTo-DesignMotionOriginKey ([string]$dependency.upstream))) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The source origin does not match the governed authoritative origin.'
        }

        $headResult = Invoke-DesignMotionGitText $resolvedSourceRoot @('rev-parse', '--verify', 'HEAD')
        if ($headResult.exitCode -ne 0) { return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The source checkout has no readable HEAD.' }
        $head = $headResult.stdout.Trim()
        if ($head -notmatch '^[0-9a-fA-F]{40}$' -or $head -cne [string]$dependency.commitSha) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The source HEAD does not match the exact governed pin.'
        }

        $topLevelResult = Invoke-DesignMotionGitText $resolvedSourceRoot @('rev-parse', '--show-toplevel')
        if ($topLevelResult.exitCode -ne 0) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The source checkout root could not be established.'
        }
        $topLevel = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $topLevelResult.stdout.Trim()).Path)
        if ($topLevel -cne $resolvedSourceRoot) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The source path is not the root of the governed Git checkout.'
        }

        $cleanliness = Get-DesignMotionSourceCleanliness -SourceRoot $resolvedSourceRoot
        if (-not [bool]$cleanliness.clean) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason ("The source checkout is dirty: " + [string]$cleanliness.reason)
        }

        if ([string]$dependency.license -cne 'MIT' -or [string]::IsNullOrWhiteSpace([string]$dependency.licensePath)) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The governed license identity or path is not MIT/Licence-compatible.'
        }
        $required = @(Get-DesignMotionRequiredSourceFiles -Operation $Operation -DependencyRecord $dependency -EntryRecord $entry -SourceRoot $resolvedSourceRoot -Commit $head)
        $fileRecords = New-Object Collections.Generic.List[object]
        foreach ($spec in $required) {
            Assert-DesignMotionRelativeSourcePath ([string]$spec.path)
            if ([string]$spec.path -match '(^|/)animate(/|$)|RECIPES\.md$') {
                return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason "A Phase 1 source allowlist attempted to consume an excluded path: $($spec.path)."
            }
            $blob = Get-DesignMotionGitBlob -SourceRoot $resolvedSourceRoot -Commit $head -RelativePath ([string]$spec.path)
            $hashes = Get-DesignMotionByteHashSet $blob.bytes
            $representation = 'canonical-lf-and-crlf-normalized'
            $lockComparison = 'not-in-lock'
            $expected = if ([string]::IsNullOrWhiteSpace([string]$spec.expectedSha256)) { $null } else { [string]$spec.expectedSha256 }
            if ($null -ne $expected) {
                if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
                    return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason "The lock hash is malformed for $($spec.path)."
                }
                if ($expected -ieq $hashes.canonicalLfSha256) { $representation = 'canonical-lf'; $lockComparison = 'matched-canonical-lf' }
                elseif ($expected -ieq $hashes.crlfNormalizedSha256) { $representation = 'crlf-normalized'; $lockComparison = 'matched-crlf-normalized' }
                else {
                    return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason "The committed source hash does not match the lock for $($spec.path)."
                }
            }
            if ($spec.role -eq 'license') {
                $licenseText = ConvertFrom-DesignMotionUtf8 $blob.bytes
                if ($licenseText -notmatch '(?im)\bMIT License\b|Permission is hereby granted, free of charge') {
                    return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The committed license file does not contain the expected MIT identity.'
                }
            }
            [void]$fileRecords.Add([pscustomobject][ordered]@{
                    path = [string]$spec.path
                    role = [string]$spec.role
                    expectedSha256 = $expected
                    rawSha256 = $hashes.rawSha256
                    canonicalLfSha256 = $hashes.canonicalLfSha256
                    crlfNormalizedSha256 = $hashes.crlfNormalizedSha256
                    validatedRepresentation = $representation
                    lockComparison = $lockComparison
                    byteLength = $hashes.rawLength
                })
        }

        $fingerprintPayload = [ordered]@{
            schemaVersion = 1
            dependencyId = $dependencyId
            origin = (ConvertTo-DesignMotionOriginKey ([string]$dependency.upstream))
            ref = [string]$dependency.ref
            commitSha = $head.ToLowerInvariant()
            license = [ordered]@{ identity = [string]$dependency.license; path = [string]$dependency.licensePath }
            representationsCompared = @('canonical-lf', 'crlf-normalized')
            files = @($fileRecords.ToArray() | ForEach-Object {
                    [ordered]@{
                        path = $_.path
                        role = $_.role
                        expectedSha256 = $_.expectedSha256
                        rawSha256 = $_.rawSha256
                        canonicalLfSha256 = $_.canonicalLfSha256
                        crlfNormalizedSha256 = $_.crlfNormalizedSha256
                        validatedRepresentation = $_.validatedRepresentation
                        lockComparison = $_.lockComparison
                    }
                })
        }
        $fingerprintJson = ConvertTo-DesignMotionCanonicalJson $fingerprintPayload
        $fingerprint = Get-DesignMotionSha256 ([Text.Encoding]::UTF8.GetBytes($fingerprintJson))

        $originAfterResult = Invoke-DesignMotionGitText $resolvedSourceRoot @('config', '--get-all', 'remote.origin.url')
        $headAfterResult = Invoke-DesignMotionGitText $resolvedSourceRoot @('rev-parse', '--verify', 'HEAD')
        $cleanlinessAfter = Get-DesignMotionSourceCleanliness -SourceRoot $resolvedSourceRoot
        $headAfter = $headAfterResult.stdout.Trim()
        if ($originAfterResult.exitCode -ne 0 -or $originAfterResult.stdout.Trim() -cne $origins[0] -or
            $headAfterResult.exitCode -ne 0 -or $headAfter -cne $head -or
            -not [bool]$cleanlinessAfter.clean -or
            [string]$cleanlinessAfter.representation -cne [string]$cleanliness.representation) {
            return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$true -DependencyId $dependencyId -SourceRoot $resolvedSourceRoot -Reason 'The source checkout changed during verification.'
        }

        return [pscustomobject][ordered]@{
            verified = $true
            materialized = $true
            verificationAttempted = $true
            dependencyId = $dependencyId
            operation = $Operation
            sourceRoot = $resolvedSourceRoot
            origin = [string]$dependency.upstream
            pin = [string]$dependency.commitSha
            ref = [string]$dependency.ref
            clean = $true
            observedOrigin = $origins[0]
            originMatches = $true
            representation = 'canonical-lf-and-crlf-normalized'
            cleanliness = [pscustomobject][ordered]@{
                status = 'CLEAN'
                representation = [string]$cleanliness.representation
            }
            cleanlinessRepresentation = [string]$cleanliness.representation
            sourceFingerprint = $fingerprint
            files = @($fileRecords.ToArray())
            failureType = $null
            reason = $null
        }
    } catch {
        $materialized = $false
        try { $materialized = Test-Path -LiteralPath $SourceRoot -PathType Container } catch { $materialized = $false }
        return Get-DesignMotionSourceFailure -Operation $Operation -Materialized:$materialized -Reason $_.Exception.Message -SourceRoot ([string]$SourceRoot)
    }
}
