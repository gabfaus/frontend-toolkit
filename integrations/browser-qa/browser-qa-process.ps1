Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FtkBrowserQaMaximumOutputCharacters = 262144
$script:FtkBrowserQaMaximumDiagnosticCharacters = 8192

# Reuse the canonical 03D execution envelope and failure taxonomy. This lane
# reads the shared contract but never edits or extends it.
$executionContractPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\plugin\frontend-toolkit\security\execution-contract.ps1'))
if (-not (Test-Path -LiteralPath $executionContractPath -PathType Leaf)) { throw 'FTK execution contract is missing.' }
. $executionContractPath

if ($null -eq ('Ftk.BrowserQa.BoundedStreamCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Ftk.BrowserQa {
    public sealed class BoundedStreamCapture {
        private readonly StreamReader reader;
        private readonly int maximumCharacters;
        private readonly object sync = new object();
        private readonly StringBuilder text = new StringBuilder();
        private int overflowed;

        public Task Completion { get; private set; }
        public bool Overflowed { get { return Interlocked.CompareExchange(ref overflowed, 0, 0) != 0; } }

        public BoundedStreamCapture(StreamReader reader, int maximumCharacters) {
            if (reader == null) throw new ArgumentNullException("reader");
            if (maximumCharacters < 1) throw new ArgumentOutOfRangeException("maximumCharacters");
            this.reader = reader;
            this.maximumCharacters = maximumCharacters;
            Completion = Task.Run((Func<Task>)CaptureAsync);
        }

        private async Task CaptureAsync() {
            var buffer = new char[8192];
            while (true) {
                var count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (count == 0) return;
                lock (sync) {
                    var remaining = maximumCharacters - text.Length;
                    if (remaining > 0) text.Append(buffer, 0, Math.Min(remaining, count));
                    if (count > Math.Max(remaining, 0)) Interlocked.Exchange(ref overflowed, 1);
                }
            }
        }

        public string GetText() {
            lock (sync) return text.ToString();
        }
    }

    public static class ProcessContainment {
        private const uint JobObjectLimitKillOnJobClose = 0x2000;
        private const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private static void ThrowLastError(string operation) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed.");
        }

        public static IntPtr CreateKillOnCloseJob() {
            var job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) ThrowLastError("CreateJobObject");
            var information = new ExtendedLimitInformation();
            information.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref information, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) {
                CloseHandle(job);
                ThrowLastError("SetInformationJobObject");
            }
            return job;
        }

        public static void Assign(IntPtr job, IntPtr process) {
            if (!AssignProcessToJobObject(job, process)) ThrowLastError("AssignProcessToJobObject");
        }

        public static bool Terminate(IntPtr job, uint exitCode) {
            return TerminateJobObject(job, exitCode);
        }

        public static bool Close(IntPtr job) {
            return CloseHandle(job);
        }
    }
}
'@
}

function Get-BrowserQaBoundedDiagnostic {
    param(
        [AllowNull()][object]$Value,
        [ValidateRange(1, 1048576)][int]$MaximumCharacters = $script:FtkBrowserQaMaximumDiagnosticCharacters
    )
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = [regex]::Replace($text, '(?i)\bBearer\s+\S+', 'Bearer [REDACTED]')
    $text = [regex]::Replace($text, '(?i)(password|passcode|secret|token|api[-_]?key|authorization|cookie|credential)\s*[:=]\s*[^\s,;]+', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return [regex]::Replace($match.Value, '(?i)([:=]\s*)[^\s,;]+$', '$1[REDACTED]')
    })
    $text = [regex]::Replace($text, '(?i)\b(?:sk|pk)-[A-Za-z0-9_-]{16,}', '[REDACTED]')
    $text = $text -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ''
    if ($text.Length -gt $MaximumCharacters) { return $text.Substring(0, $MaximumCharacters) + '...[truncated]' }
    return $text
}

function Get-BrowserQaDiagnosticLines {
    param([AllowNull()][object]$Value)
    $text = Get-BrowserQaBoundedDiagnostic -Value $Value -MaximumCharacters $script:FtkBrowserQaMaximumOutputCharacters
    if ([string]::IsNullOrEmpty($text)) { return @() }
    return @($text -split '\r?\n' | Where-Object { $_.Length -gt 0 } | ForEach-Object {
        Get-BrowserQaBoundedDiagnostic -Value $_ -MaximumCharacters 8192
    })
}

function ConvertTo-BrowserQaWindowsArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)
    if ($Value -match '[\x00\r\n]') { throw 'Native argv values may not contain NUL or line breaks.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ([int][char]$character -eq 92) { $backslashes++; continue }
        if ([int][char]$character -eq 34) {
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

function Test-BrowserQaReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-BrowserQaPathContained {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Label,
        [switch]$MustExist
    )
    $rootFull = [IO.Path]::GetFullPath($Root)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $rootPrefix = if ($rootFull.EndsWith([IO.Path]::DirectorySeparatorChar)) { $rootFull } else { $rootFull + [IO.Path]::DirectorySeparatorChar }
    if (-not $candidateFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped its canonical root."
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $candidateFull)) { throw "$Label does not exist." }
    if (Test-Path -LiteralPath $rootFull) {
        $rootItem = Get-Item -LiteralPath $rootFull -Force
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Label root is a reparse point." }
    }
    $cursor = [IO.Path]::GetDirectoryName($candidateFull)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-BrowserQaReparsePoint -Path $cursor) { throw "$Label has a reparse-point ancestor." }
        if ($cursor.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $next = [IO.Path]::GetDirectoryName($cursor)
        if ($next -eq $cursor) { break }
        $cursor = $next
    }
    if (Test-Path -LiteralPath $candidateFull) {
        $candidateItem = Get-Item -LiteralPath $candidateFull -Force
        if ($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Label is a reparse point." }
        $realRoot = (Resolve-Path -LiteralPath $rootFull).Path
        $realCandidate = (Resolve-Path -LiteralPath $candidateFull).Path
        $realPrefix = if ($realRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) { $realRoot } else { $realRoot + [IO.Path]::DirectorySeparatorChar }
        if (-not $realCandidate.StartsWith($realPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            -not $realCandidate.Equals($realRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label resolves outside its canonical root."
        }
    }
    return $candidateFull
}

function Assert-BrowserQaTempSessionRoot {
    param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$')][string]$SessionId)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $base = [IO.Path]::GetFullPath((Join-Path $temp 'ftk-playwright'))
    if (Test-BrowserQaReparsePoint -Path $base) { throw 'Browser QA temporary base is a reparse point.' }
    $root = [IO.Path]::GetFullPath((Join-Path $base $SessionId))
    Assert-BrowserQaPathContained -Root $base -Candidate $root -Label 'Browser QA session root' | Out-Null
    return $root
}

function Set-BrowserQaChildEnvironment {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment
    )
    try {
        $variables = $StartInfo.EnvironmentVariables
        $variables.Clear()
    } catch {
        $field = $StartInfo.GetType().GetField('environmentVariables', [Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -eq $field) { throw 'Unable to create the isolated Browser QA child environment.' }
        $variables = New-Object Collections.Specialized.StringDictionary
        $field.SetValue($StartInfo, $variables)
        $variables.Clear()
    }
    foreach ($name in $Environment.Keys) { $variables.Add([string]$name, [string]$Environment[$name]) }
}

function New-BrowserQaChildEnvironment {
    param([Parameter(Mandatory)][string]$SessionRoot)
    $environment = [ordered]@{}
    foreach ($name in @('SystemRoot', 'ComSpec')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
    }
    $hostTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $browserCache = [IO.Path]::GetFullPath((Join-Path $hostTemp 'browser-cache'))
    Assert-BrowserQaPathContained -Root $hostTemp -Candidate $browserCache -Label 'Playwright browser cache' | Out-Null
    $daemonRoot = [IO.Path]::GetFullPath((Join-Path $SessionRoot 'daemon'))
    $serverRegistry = [IO.Path]::GetFullPath((Join-Path $SessionRoot 'server-registry'))
    Assert-BrowserQaPathContained -Root $SessionRoot -Candidate $daemonRoot -Label 'Playwright daemon root' | Out-Null
    Assert-BrowserQaPathContained -Root $SessionRoot -Candidate $serverRegistry -Label 'Playwright server registry' | Out-Null
    $environment['TEMP'] = $SessionRoot
    $environment['TMP'] = $SessionRoot
    $environment['FTK_BROWSER_QA_HOST_TEMP'] = $hostTemp
    $environment['PLAYWRIGHT_BROWSERS_PATH'] = $browserCache
    $environment['PWTEST_DAEMON_SESSION_DIR'] = $daemonRoot
    $environment['PWTEST_SERVER_REGISTRY'] = $serverRegistry
    $environment['PWTEST_CLI_GLOBAL_CONFIG'] = $SessionRoot
    $sandboxOverride = [Environment]::GetEnvironmentVariable('PLAYWRIGHT_MCP_SANDBOX', 'Process')
    if ($sandboxOverride -and $sandboxOverride.ToLowerInvariant() -notin @('true', 'false')) {
        throw 'PLAYWRIGHT_MCP_SANDBOX must be an explicit true/false value when supplied.'
    }
    if ($sandboxOverride) { $environment['PLAYWRIGHT_MCP_SANDBOX'] = $sandboxOverride.ToLowerInvariant() }
    $environment['PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD'] = '1'
    $environment['PLAYWRIGHT_HTML_OPEN'] = 'never'
    $environment['NO_COLOR'] = '1'
    $environment['NO_UPDATE_NOTIFIER'] = '1'
    return $environment
}

function Stop-BrowserQaChildProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [IntPtr]$JobHandle = [IntPtr]::Zero
    )
    $jobTerminated = $false
    if ($JobHandle -ne [IntPtr]::Zero) {
        try { $jobTerminated = [Ftk.BrowserQa.ProcessContainment]::Terminate($JobHandle, 1) } catch { }
    }
    if (-not $jobTerminated) {
        try { if ($Process.HasExited) { return $true } } catch { return $false }
    }
    try {
        if (-not $jobTerminated -and -not $Process.HasExited) { [void]$Process.Kill() }
    } catch {
        if (-not $jobTerminated) { return $false }
    }
    try { return [bool]$Process.WaitForExit(5000) } catch { return $false }
}

function Invoke-BrowserQaChildProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Executable,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WorkingDirectory,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][ValidateRange(1000, 600000)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation
    )

    $attempted = $true
    $materialized = $false
    $childStarted = $false
    $timedOut = $false
    $failureType = $null
    $failureMessage = $null
    [Nullable[int]]$exitCode = $null
    $stdoutText = ''
    $stderrText = ''
    $stdoutOverflowed = $false
    $stderrOverflowed = $false
    $captureComplete = $true
    $cleanup = 'NOT_REQUIRED'
    $cleanupMechanism = 'none'
    $cleanupGuaranteed = $false
    [Nullable[int]]$processId = $null
    [IntPtr]$jobHandle = [IntPtr]::Zero
    $jobAssigned = $false
    $process = [Diagnostics.Process]::new()
    $stdoutCapture = $null
    $stderrCapture = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    try {
        if (-not (Test-Path -LiteralPath $Executable -PathType Leaf) -or
            -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            throw 'Browser QA child executable or working directory is unavailable.'
        }
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $Executable
        $start.WorkingDirectory = $WorkingDirectory
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
        $start.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-BrowserQaWindowsArgument -Value ([string]$_) }) -join ' ')
        Set-BrowserQaChildEnvironment -StartInfo $start -Environment $Environment
        $materialized = $true
        $jobHandle = [Ftk.BrowserQa.ProcessContainment]::CreateKillOnCloseJob()
        $cleanupMechanism = 'windows-job-object'
        $process.StartInfo = $start
        try {
            $childStarted = [bool]$process.Start()
            if ($childStarted) { $processId = $process.Id }
        } catch {
            $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
            $failureMessage = $_.Exception.Message
        }
        if (-not $childStarted -and $null -eq $failureType) {
            $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
            $failureMessage = 'Browser QA child process did not start.'
        }
        if ($childStarted) {
            $cleanup = 'INCOMPLETE'
            $captureComplete = $false
            $stdoutCapture = New-Object Ftk.BrowserQa.BoundedStreamCapture($process.StandardOutput, $script:FtkBrowserQaMaximumOutputCharacters)
            $stderrCapture = New-Object Ftk.BrowserQa.BoundedStreamCapture($process.StandardError, $script:FtkBrowserQaMaximumOutputCharacters)
            try {
                [Ftk.BrowserQa.ProcessContainment]::Assign($jobHandle, $process.Handle)
                $jobAssigned = $true
            } catch {
                $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
                $failureMessage = 'Browser QA child could not be assigned to the Windows Job Object.'
            }
            if (-not $jobAssigned) { [void](Stop-BrowserQaChildProcess -Process $process -JobHandle $jobHandle) }
            while (-not $process.HasExited -and -not $timedOut -and $null -eq $failureType) {
                if ($stdoutCapture.Overflowed -or $stderrCapture.Overflowed) {
                    $failureType = 'OUTPUT_CONTRACT_FAILURE'
                    $failureMessage = 'Browser QA child output exceeded the bounded contract.'
                    [void](Stop-BrowserQaChildProcess -Process $process -JobHandle $jobHandle)
                    break
                }
                $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
                if ($remaining -le 0) {
                    $timedOut = $true
                    $failureType = 'TIMEOUT'
                    $failureMessage = 'Browser QA child exceeded the governed timeout.'
                    [void](Stop-BrowserQaChildProcess -Process $process -JobHandle $jobHandle)
                } else {
                    [void]$process.WaitForExit([Math]::Min(50, $remaining))
                }
            }
            if ($stdoutCapture.Overflowed -or $stderrCapture.Overflowed) {
                $stdoutOverflowed = [bool]$stdoutCapture.Overflowed
                $stderrOverflowed = [bool]$stderrCapture.Overflowed
                if ($null -eq $failureType) {
                    $failureType = 'OUTPUT_CONTRACT_FAILURE'
                    $failureMessage = 'Browser QA child output exceeded the bounded contract.'
                }
                [void](Stop-BrowserQaChildProcess -Process $process -JobHandle $jobHandle)
            }
            if ($timedOut -or ($failureType -and -not $process.HasExited)) {
                [void](Stop-BrowserQaChildProcess -Process $process -JobHandle $jobHandle)
            }
            $stdoutComplete = $false
            $stderrComplete = $false
            try { $stdoutComplete = [bool]$stdoutCapture.Completion.Wait(5000) } catch { }
            try { $stderrComplete = [bool]$stderrCapture.Completion.Wait(5000) } catch { }
            $stdoutText = $stdoutCapture.GetText()
            $stderrText = $stderrCapture.GetText()
            $stdoutOverflowed = [bool]$stdoutCapture.Overflowed
            $stderrOverflowed = [bool]$stderrCapture.Overflowed
            $captureComplete = $stdoutComplete -and $stderrComplete
            if (-not $captureComplete -and $null -eq $failureType) {
                $failureType = 'OUTPUT_CONTRACT_FAILURE'
                $failureMessage = 'Browser QA child output streams were not fully drained.'
            }
            try { if ($process.HasExited) { $exitCode = $process.ExitCode } } catch { }
            if ($null -eq $failureType -and $null -ne $exitCode -and $exitCode -ne 0) {
                $failureType = 'UPSTREAM_EXECUTION_FAILURE'
                $failureMessage = "Browser QA child failed with exit code $exitCode."
            }
        }
    } catch {
        if ($null -eq $failureType) {
            $failureType = if (-not $materialized -or -not $childStarted) { 'DEPENDENCY_OR_RUNTIME_FAILURE' } else { 'UNKNOWN_FAILURE' }
            $failureMessage = $_.Exception.Message
        }
    } finally {
        if ($childStarted) {
            try {
                if (-not $process.HasExited) { [void](Stop-BrowserQaChildProcess -Process $process -JobHandle $jobHandle) }
                if ($jobHandle -ne [IntPtr]::Zero) {
                    $closed = [Ftk.BrowserQa.ProcessContainment]::Close($jobHandle)
                    $jobHandle = [IntPtr]::Zero
                    $cleanup = if ($jobAssigned -and $closed) { 'COMPLETED_WITH_LIMITATION' } else { 'INCOMPLETE' }
                } else { $cleanup = 'INCOMPLETE' }
            } catch { $cleanup = 'INCOMPLETE' }
        } elseif ($jobHandle -ne [IntPtr]::Zero) {
            try { [void][Ftk.BrowserQa.ProcessContainment]::Close($jobHandle) } catch { }
        }
        try { $process.Dispose() } catch { }
        $stopwatch.Stop()
    }

    if ($childStarted -and $cleanup -notin @('COMPLETED', 'COMPLETED_WITH_LIMITATION') -and $null -eq $failureType) {
        $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
        $failureMessage = 'Browser QA could not prove complete child cleanup.'
    }
    $childObservation = New-FtkChildProcessObservation -Capability 'playwright-cli' -Operation $Operation `
        -Materialized:$materialized -Attempted:$attempted -ChildStarted:$childStarted -ExitCode $exitCode `
        -FailureType $failureType -FailureMessage $failureMessage -TimedOut:$timedOut `
        -StdoutText $stdoutText -StderrText $stderrText -CaptureComplete:$captureComplete `
        -StdoutOverflowed:$stdoutOverflowed -StderrOverflowed:$stderrOverflowed `
        -EnvironmentNames @($Environment.Keys) -Cleanup $cleanup -CleanupMechanism $cleanupMechanism `
        -CleanupGuaranteed:$cleanupGuaranteed -TimeoutMilliseconds $TimeoutMilliseconds -ProcessId $processId
    return $childObservation
}

function Get-BrowserQaNodeIdentity {
    $toolchainPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\toolchain.lock.json'))
    if (-not (Test-Path -LiteralPath $toolchainPath -PathType Leaf)) { throw 'Node toolchain lock is missing.' }
    $toolchain = Get-Content -Raw -LiteralPath $toolchainPath | ConvertFrom-Json
    $nodeLock = @($toolchain.runtimes | Where-Object id -eq 'node' | Select-Object -First 1)
    if ($nodeLock.Count -ne 1) { throw 'Node 24.20.0 lock entry is missing.' }
    $expected = [string]$nodeLock[0].targetVersion
    $lockedPath = [Environment]::ExpandEnvironmentVariables(([string]$nodeLock[0].portableResolution).Replace('/', '\'))
    $candidates = New-Object Collections.Generic.List[string]
    try { if (Test-Path -LiteralPath $lockedPath -PathType Leaf) { [void]$candidates.Add($lockedPath) } } catch { }
    $command = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) { [void]$candidates.Add([IO.Path]::GetFullPath($command.Source)) }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $observed = ((& $candidate '--version' 2>$null | Select-Object -First 1) | Out-String).Trim()
            if ($observed -eq "v$expected") {
                $locked = [IO.Path]::GetFullPath($lockedPath).Equals([IO.Path]::GetFullPath($candidate), [StringComparison]::OrdinalIgnoreCase)
                $executableHash = $null
                try { $executableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash.ToLowerInvariant() } catch { }
                return [pscustomobject][ordered]@{
                    expectedVersion = $expected
                    observedVersion = $observed.TrimStart('v')
                    executable = [IO.Path]::GetFullPath($candidate)
                    provenanceStatus = if ($locked) { 'LOCKED_PORTABLE_PATH' } else { 'EXACT_VERSION_ENVIRONMENT_PATH' }
                    provenanceLimitation = if ($locked) { $null } else { 'The locked portable Node path was unavailable; an absolute environment-resolved node.exe with the exact version was used. Artifact provenance remains limited.' }
                    executableSha256 = $executableHash
                    executableHashStatus = if ($null -ne $executableHash) { 'OBSERVED_NOT_LOCK_COMPARABLE' } else { 'UNVERIFIED_BYTES' }
                    expectedArtifactSha256 = [string]$nodeLock[0].artifactSha256
                }
            }
        } catch { }
    }
    throw 'Node 24.20.0 is unavailable; automatic runtime installation is disabled.'
}

function Get-BrowserQaCliIdentity {
    param(
        [string]$ExplicitPath,
        [switch]$AllowSyntheticTestDouble
    )
    $path = $ExplicitPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $command = Get-Command 'playwright-cli' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command -or [string]::IsNullOrWhiteSpace($command.Source)) { throw 'The pinned playwright-cli command is unavailable; automatic installation is disabled.' }
        $path = $command.Source
    }
    $resolved = [IO.Path]::GetFullPath($path)
    if ([IO.Path]::GetFileName($resolved) -notmatch '^playwright-cli\.cmd$') { throw 'Only the package-owned playwright-cli.cmd entry is accepted.' }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or (Test-BrowserQaReparsePoint -Path $resolved)) { throw 'The pinned playwright-cli command is unavailable or a reparse point.' }
    $binDirectory = Split-Path -Parent $resolved
    if ((Split-Path -Leaf $binDirectory) -cne '.bin') { throw 'Playwright CLI executable provenance must come from a node_modules/.bin entry.' }
    $nodeModules = Split-Path -Parent $binDirectory
    $packageRoot = Join-Path $nodeModules '@playwright\cli'
    Assert-BrowserQaPathContained -Root $nodeModules -Candidate $packageRoot -Label 'Playwright CLI package root' -MustExist | Out-Null
    if (Test-BrowserQaReparsePoint -Path $packageRoot) { throw 'Playwright CLI package root is a reparse point.' }
    $packageJsonPath = Join-Path $packageRoot 'package.json'
    Assert-BrowserQaPathContained -Root $packageRoot -Candidate $packageJsonPath -Label 'Playwright CLI package manifest' -MustExist | Out-Null
    $package = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
    if ($package.name -cne '@playwright/cli' -or $package.version -cne '0.1.19') { throw 'Playwright CLI package identity/version mismatch.' }
    if ($package.license -and $package.license -cne 'Apache-2.0') { throw 'Playwright CLI package license mismatch.' }
    $entryRelative = if ($package.bin -is [string]) { [string]$package.bin } elseif ($null -ne $package.bin.PSObject.Properties['playwright-cli']) { [string]$package.bin.'playwright-cli' } elseif ($package.main) { [string]$package.main } else { 'cli.js' }
    if ($entryRelative -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($entryRelative)) { throw 'Playwright CLI package entry is not a safe relative path.' }
    $entryPath = Join-Path $packageRoot $entryRelative
    Assert-BrowserQaPathContained -Root $packageRoot -Candidate $entryPath -Label 'Playwright CLI entry' -MustExist | Out-Null
    if (Test-BrowserQaReparsePoint -Path $entryPath) { throw 'Playwright CLI entry is a reparse point.' }
    $wrapper = Get-Content -Raw -LiteralPath $resolved
    if ($wrapper -notmatch '(?i)@playwright[\\/]cli' -or $wrapper -notmatch '(?i)cli\.js') { throw 'Playwright CLI wrapper does not point to the package-owned entry.' }
    $lockPath = Join-Path $PSScriptRoot '..\browser-qa.lock.json'
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $expectedHash = [string]$lock.playwright.cli.cliEntrySha256
    $syntheticProperty = $package.PSObject.Properties['ftkSyntheticTestDouble']
    $synthetic = $null -ne $syntheticProperty -and [bool]$syntheticProperty.Value
    if ($synthetic -and -not $AllowSyntheticTestDouble) { throw 'Synthetic Playwright CLI test doubles require an explicit test-only switch.' }
    $actualHash = $null
    $hashStatus = 'UNVERIFIED_BYTES'
    try { $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entryPath).Hash.ToLowerInvariant() } catch { }
    if ($synthetic) { $hashStatus = 'SYNTHETIC_TEST_DOUBLE' }
    elseif ($actualHash -and $expectedHash -and $actualHash -cne $expectedHash.ToLowerInvariant()) { throw 'Playwright CLI entry hash mismatch.' }
    elseif ($actualHash -and $expectedHash) { $hashStatus = 'VERIFIED' }
    return [pscustomobject][ordered]@{
        expectedPackage = '@playwright/cli'
        expectedVersion = '0.1.19'
        packageName = [string]$package.name
        packageVersion = [string]$package.version
        packageRoot = [IO.Path]::GetFullPath($packageRoot)
        executable = $resolved
        entryPath = [IO.Path]::GetFullPath($entryPath)
        entrySha256 = $actualHash
        expectedEntrySha256 = $expectedHash
        entryHashStatus = $hashStatus
        executableProvenance = 'node_modules/.bin/package-owned-entry'
        synthetic = $synthetic
        limitation = if ($hashStatus -eq 'UNVERIFIED_BYTES') { 'CLI entry bytes could not be hashed stably; package identity and wrapper provenance were checked, but byte provenance remains limited.' } elseif ($synthetic) { 'Synthetic CLI test double is not real browser materialization.' } else { $null }
    }
}
