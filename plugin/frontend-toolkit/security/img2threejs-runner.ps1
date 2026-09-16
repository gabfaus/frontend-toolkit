Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'img2threejs-foundation.ps1')
. (Join-Path $PSScriptRoot 'img2threejs-structural-validation.ps1')
. (Join-Path $PSScriptRoot 'img2threejs-state-guard.ps1')
. (Join-Path $PSScriptRoot 'execution-contract.ps1')

function Resolve-Img2ThreejsRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('node','python')][string]$Name)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'The current FTK runtime policy only registers windows-x64 runtimes.'
    }
    $policy = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'img2threejs-runtime-policy.json') | ConvertFrom-Json
    $definition = $policy.runtimes.'windows-x64'.$Name
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $path = [IO.Path]::GetFullPath((Join-Path $localAppData $definition.relativeToLocalAppData))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The pinned FTK $Name runtime is not installed at its registered path."
    }
    return $path
}

function Resolve-Img2ThreejsPinnedUpstreamRoot {
    [CmdletBinding()]
    param()

    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $provenance = Test-Img2ThreejsSourceProvenance -RepositoryRoot $repoRoot
    if (-not $provenance.materialized) { throw 'The pinned img2threejs upstream payload is unavailable: source is not materialized.' }
    if (-not $provenance.valid) { throw ('The pinned img2threejs upstream payload failed provenance verification: ' + $provenance.reason) }
    return [string]$provenance.canonicalPath
}

function New-Img2ThreejsMinimumEnvironment {
    [CmdletBinding()]
    param(
        [ValidateSet('node','python')][string]$Runtime,
        [Collections.IDictionary]$Additional
    )

    $policy = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'img2threejs-runtime-policy.json') | ConvertFrom-Json
    $environment = [ordered]@{}
    foreach ($name in @($policy.baseEnvironment)) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrEmpty($value)) { $environment[$name] = $value }
    }
    if ($Runtime -eq 'python') {
        foreach ($property in $policy.pythonEnvironment.PSObject.Properties) {
            $environment[$property.Name] = [string]$property.Value
        }
    }
    if ($null -ne $Additional) {
        $allowedAdditional = @((Get-Img2ThreejsGlbConfigSchema).Keys) + @('IMG2THREEJS_SHOWCASE_ROOT')
        foreach ($name in $Additional.Keys) {
            if ($name -cnotin $allowedAdditional) {
                throw "Unregistered img2threejs environment name: $name"
            }
            $environment[$name] = [string]$Additional[$name]
        }
    }
    foreach ($forbidden in @($policy.forbiddenInheritedEnvironment)) {
        if ($environment.Contains($forbidden)) { throw "Forbidden inherited environment name: $forbidden" }
    }
    return $environment
}

function ConvertTo-Img2ThreejsWindowsNativeArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    if ($Value -match '[\x00\r\n]') { throw 'Native argv values may not contain NUL or line breaks.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

if ($null -eq ('FtkImg2ThreejsJobObjectNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class FtkImg2ThreejsJobObjectNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
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
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(
        IntPtr hJob,
        int JobObjectInfoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo,
        uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public static IntPtr CreateKillOnCloseJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = 0x2000;
        bool configured = SetInformationJobObject(
            job,
            9,
            ref limits,
            (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
        if (!configured)
        {
            CloseHandle(job);
            return IntPtr.Zero;
        }
        return job;
    }
}

public sealed class FtkImg2ThreejsBoundedStream : IDisposable
{
    private readonly Stream stream;
    private readonly int maximumCharacters;
    private readonly object gate = new object();
    private readonly StringBuilder text = new StringBuilder();
    private Task completion;
    private long discardedCharacters;
    private bool truncated;
    private string error;

    public FtkImg2ThreejsBoundedStream(Stream stream, int maximumCharacters)
    {
        if (stream == null) throw new ArgumentNullException("stream");
        if (maximumCharacters < 1) throw new ArgumentOutOfRangeException("maximumCharacters");
        this.stream = stream;
        this.maximumCharacters = maximumCharacters;
    }

    public void Start()
    {
        completion = Task.Factory.StartNew(ReadLoop, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    private void ReadLoop()
    {
        try
        {
            using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(false, false), true, 4096, true))
            {
                char[] buffer = new char[4096];
                int read;
                while ((read = reader.Read(buffer, 0, buffer.Length)) > 0)
                {
                    lock (gate)
                    {
                        int remaining = maximumCharacters - text.Length;
                        if (remaining <= 0)
                        {
                            discardedCharacters += read;
                            truncated = true;
                        }
                        else if (read <= remaining)
                        {
                            text.Append(buffer, 0, read);
                        }
                        else
                        {
                            text.Append(buffer, 0, remaining);
                            discardedCharacters += read - remaining;
                            truncated = true;
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            lock (gate) { error = ex.GetType().Name + ": " + ex.Message; }
        }
    }

    public bool Wait(int milliseconds)
    {
        return completion != null && completion.Wait(milliseconds);
    }

    public string Text
    {
        get { lock (gate) { return text.ToString(); } }
    }

    public string[] Lines
    {
        get { return Text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries); }
    }

    public int Characters
    {
        get { lock (gate) { return text.Length; } }
    }

    public long DiscardedCharacters
    {
        get { lock (gate) { return discardedCharacters; } }
    }

    public bool Truncated
    {
        get { lock (gate) { return truncated; } }
    }

    public string Error
    {
        get { lock (gate) { return error; } }
    }

    public void Dispose()
    {
        try { stream.Dispose(); } catch { }
    }
}
'@
}

function New-Img2ThreejsBoundedStreamState {
    param([Parameter(Mandatory)][int]$MaximumCharacters)
    return @{
        Gate = New-Object object
        Text = New-Object Text.StringBuilder
        Captured = 0
        Discarded = 0
        Truncated = $false
        Done = New-Object Threading.ManualResetEvent($false)
        MaximumCharacters = $MaximumCharacters
    }
}

function Add-Img2ThreejsBoundedStreamLine {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Line)
    $segment = $Line + "`n"
    [Threading.Monitor]::Enter($State.Gate)
    try {
        $remaining = [int]$State.MaximumCharacters - [int]$State.Captured
        if ($remaining -le 0) {
            $State.Discarded += $segment.Length
            $State.Truncated = $true
            return
        }
        if ($segment.Length -le $remaining) {
            [void]$State.Text.Append($segment)
            $State.Captured += $segment.Length
        } else {
            [void]$State.Text.Append($segment.Substring(0, $remaining))
            $State.Captured += $remaining
            $State.Discarded += ($segment.Length - $remaining)
            $State.Truncated = $true
        }
    } finally { [Threading.Monitor]::Exit($State.Gate) }
}

function Get-Img2ThreejsBoundedStreamSnapshot {
    param([Parameter(Mandatory)][hashtable]$State)
    [Threading.Monitor]::Enter($State.Gate)
    try {
        $text = $State.Text.ToString()
        return [pscustomobject][ordered]@{
            text = $text
            lines = @($text -split '\r?\n' | Where-Object { $_.Length -gt 0 })
            characters = [int]$State.Captured
            discardedCharacters = [int64]$State.Discarded
            truncated = [bool]$State.Truncated
        }
    } finally { [Threading.Monitor]::Exit($State.Gate) }
}

function New-Img2ThreejsCleanupReport {
    param(
        [bool]$JobObjectAvailable,
        [bool]$JobAssigned,
        [bool]$Terminated,
        [bool]$HandleClosed,
        [string]$Limitation
    )
    $guaranteed = $JobObjectAvailable -and $JobAssigned -and $Terminated -and $HandleClosed
    return [pscustomobject][ordered]@{
        mechanism = if ($JobObjectAvailable) { 'windows-job-object' } else { 'process-only-fallback' }
        jobObjectAvailable = $JobObjectAvailable
        processAssigned = $JobAssigned
        descendantsTerminated = $Terminated
        jobObjectHandleDisposed = $HandleClosed
        cleanupGuaranteed = $guaranteed
        limitation = $Limitation
    }
}

function Set-Img2ThreejsChildEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment
    )

    # Windows PowerShell 5.1 can expose both PATH and Path in the parent
    # environment. The public getter then throws while constructing its
    # case-insensitive dictionary. Seed this instance with an empty dictionary
    # first; this never mutates, snapshots, or restores the parent environment.
    $flags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
    $legacyField = [Diagnostics.ProcessStartInfo].GetField('environmentVariables', $flags)
    if ($null -ne $legacyField) {
        $dictionary = New-Object Collections.Specialized.StringDictionary
        foreach ($key in $Environment.Keys) { $dictionary.Add([string]$key, [string]$Environment[$key]) }
        $legacyField.SetValue($StartInfo, $dictionary)
        return
    }
    $modernField = [Diagnostics.ProcessStartInfo].GetField('environment', $flags)
    if ($null -ne $modernField) {
        $dictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $Environment.Keys) { $dictionary[[string]$key] = [string]$Environment[$key] }
        $modernField.SetValue($StartInfo, $dictionary)
        return
    }
    try {
        $StartInfo.EnvironmentVariables.Clear()
        foreach ($key in $Environment.Keys) { $StartInfo.EnvironmentVariables.Add([string]$key, [string]$Environment[$key]) }
    } catch { throw 'The runtime cannot construct an isolated child environment: ' + $_.Exception.Message }
}

function Invoke-Img2ThreejsRobustChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('node','python','synthetic')][string]$Runtime,
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Collections.IDictionary]$Environment,
        [ValidateRange(1,600000)][int]$TimeoutMilliseconds = 120000,
        [switch]$ExpectVerifierEvidence,
        [switch]$SyntheticFixture,
        [string]$SyntheticScriptPath
    )

    if ($TimeoutMilliseconds -gt (Get-FtkDedicatedExecutionMaximumTimeoutMilliseconds)) {
        throw "Timeout exceeds the FTK maximum of $(Get-FtkDedicatedExecutionMaximumTimeoutMilliseconds) milliseconds."
    }
    $executable = $null
    $argv = @()
    try {
        $workingRoot = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $WorkingDirectory
        $additional = if ($null -eq $Environment) { [ordered]@{} } else { $Environment }
        $environmentRuntime = if ($Runtime -eq 'python') { 'python' } else { 'node' }
        $minimum = New-Img2ThreejsMinimumEnvironment -Runtime $environmentRuntime -Additional $additional
        if ($Runtime -eq 'synthetic') {
            if (-not $SyntheticFixture -or [string]::IsNullOrWhiteSpace($SyntheticScriptPath)) {
                throw 'Synthetic child execution requires the explicit SyntheticFixture gate and a script path.'
            }
            $syntheticItem = Get-Item -Force -LiteralPath $SyntheticScriptPath -ErrorAction Stop
            if ($syntheticItem.PSIsContainer -or ($syntheticItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Synthetic child script must be a regular file.' }
            $syntheticPath = (Resolve-Path -LiteralPath $syntheticItem.FullName).Path
            if (-not (Test-Img2ThreejsPathWithinRoot -Root $workingRoot -Candidate $syntheticPath)) { throw 'Synthetic child script escaped its working root.' }
            Assert-Img2ThreejsNoExistingReparsePoint -Root $workingRoot -Candidate $syntheticPath
            $executable = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'The synthetic PowerShell runtime is unavailable.' }
            $argv = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$syntheticPath) + @($ArgumentList)
        } else {
            $executable = Resolve-Img2ThreejsRuntime -Name $Runtime
            $argv = @($ArgumentList)
        }
    } catch {
        return [pscustomobject][ordered]@{
            attempted = $true; childStarted = $false; succeeded = $false; exitCode = $null;
            failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'; timedOut = $false; stdout = @(); stderr = @();
            stdoutText = ''; stderrText = ''; stdoutTruncated = $false; stderrTruncated = $false;
            stdoutCaptureComplete = $true; stderrCaptureComplete = $true; captureComplete = $true;
            stdoutDiscardedCharacters = 0; stderrDiscardedCharacters = 0; executable = $executable; argv = @($argv);
            cleanup = New-Img2ThreejsCleanupReport -JobObjectAvailable:$false -JobAssigned:$false -Terminated:$false -HandleClosed:$false `
                -Limitation 'Child was not started because a precondition or registered runtime was unavailable.';
            verifierEvidence = $null;
            observation = [pscustomobject]@{ valid = $false; reason = $_.Exception.Message }
        }
    }

    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $executable
        $startInfo.WorkingDirectory = $workingRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Arguments = (@($argv | ForEach-Object { ConvertTo-Img2ThreejsWindowsNativeArgument -Value ([string]$_) }) -join ' ')
        Set-Img2ThreejsChildEnvironment -StartInfo $startInfo -Environment $minimum
        $maximumOutput = Get-FtkDedicatedExecutionMaximumOutputCharacters
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
    } catch {
        return [pscustomobject][ordered]@{
            attempted = $true; childStarted = $false; succeeded = $false; exitCode = $null;
            failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'; timedOut = $false; stdout = @(); stderr = @();
            stdoutText = ''; stderrText = ''; stdoutTruncated = $false; stderrTruncated = $false;
            stdoutCaptureComplete = $true; stderrCaptureComplete = $true; captureComplete = $true;
            stdoutDiscardedCharacters = 0; stderrDiscardedCharacters = 0; executable = $executable; argv = @($argv);
            cleanup = New-Img2ThreejsCleanupReport -JobObjectAvailable:$false -JobAssigned:$false -Terminated:$false -HandleClosed:$false `
                -Limitation 'Child was not started because the isolated process boundary could not be constructed.';
            verifierEvidence = $null;
            observation = [pscustomobject]@{ valid = $false; reason = $_.Exception.Message }
        }
    }
    $job = [IntPtr]::Zero
    $jobAvailable = $false
    $jobAssigned = $false
    $jobTerminated = $false
    $jobClosed = $false
    $cleanupLimitation = $null
    $childStarted = $false
    $timedOut = $false
    $exitCode = $null
    $stdoutReader = $null
    $stderrReader = $null
    $stdoutCaptureComplete = $false
    $stderrCaptureComplete = $false
    $observationFailure = $null
    try {
        try {
            $job = [FtkImg2ThreejsJobObjectNative]::CreateKillOnCloseJob()
            $jobAvailable = $job -ne [IntPtr]::Zero
            if (-not $jobAvailable) { $cleanupLimitation = 'Windows Job Object could not be created or configured.' }
        } catch { $cleanupLimitation = 'Windows Job Object API was unavailable: ' + $_.Exception.Message }

        try {
            if (-not $process.Start()) { throw "$Runtime process did not start." }
            $childStarted = $true
        } catch {
            $observationFailure = $_.Exception.Message
        }
        if ($childStarted) {
            if ($jobAvailable) {
                try {
                    $jobAssigned = [FtkImg2ThreejsJobObjectNative]::AssignProcessToJobObject($job, $process.Handle)
                    if (-not $jobAssigned) { $cleanupLimitation = 'Child could not be assigned to the Windows Job Object.'; $jobAvailable = $false }
                } catch { $cleanupLimitation = 'Child Job Object assignment failed: ' + $_.Exception.Message; $jobAvailable = $false }
            }
            $stdoutReader = New-Object FtkImg2ThreejsBoundedStream -ArgumentList @($process.StandardOutput.BaseStream, [int]$maximumOutput)
            $stderrReader = New-Object FtkImg2ThreejsBoundedStream -ArgumentList @($process.StandardError.BaseStream, [int]$maximumOutput)
            $stdoutReader.Start()
            $stderrReader.Start()
            if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                $timedOut = $true
                if ($jobAssigned) {
                    $jobTerminated = [FtkImg2ThreejsJobObjectNative]::TerminateJobObject($job, 124)
                } else {
                    try { $process.Kill(); $jobTerminated = $true } catch { $cleanupLimitation = 'Process-only timeout cleanup failed: ' + $_.Exception.Message }
                }
            } elseif ($jobAssigned) {
                # Kill-on-close is not enough while the handle is still open: close any
                # descendants that outlive the main process before draining the pipes.
                $jobTerminated = [FtkImg2ThreejsJobObjectNative]::TerminateJobObject($job, 0)
            } else {
                $jobTerminated = $true
            }
            $null = $process.WaitForExit(5000)
            $stdoutCaptureComplete = $stdoutReader.Wait(5000)
            $stderrCaptureComplete = $stderrReader.Wait(5000)
            if ($process.HasExited) { $exitCode = [int]$process.ExitCode }
        }
    } catch {
        $observationFailure = $_.Exception.Message
    } finally {
        if ($childStarted -and -not $process.HasExited) {
            if ($jobAssigned) {
                try { $jobTerminated = [FtkImg2ThreejsJobObjectNative]::TerminateJobObject($job, 125) } catch { $cleanupLimitation = 'Final Job Object termination failed: ' + $_.Exception.Message }
            } else {
                try { $process.Kill(); $jobTerminated = $true } catch { $cleanupLimitation = 'Final process cleanup failed: ' + $_.Exception.Message }
            }
            $null = $process.WaitForExit(5000)
        }
        if ($job -ne [IntPtr]::Zero) {
            try { $jobClosed = [FtkImg2ThreejsJobObjectNative]::CloseHandle($job) } catch { $cleanupLimitation = 'Job Object handle disposal failed: ' + $_.Exception.Message }
        }
        if ($null -ne $stdoutReader) { $stdoutReader.Dispose(); if (-not $stdoutCaptureComplete) { $stdoutCaptureComplete = $stdoutReader.Wait(1000) } }
        if ($null -ne $stderrReader) { $stderrReader.Dispose(); if (-not $stderrCaptureComplete) { $stderrCaptureComplete = $stderrReader.Wait(1000) } }
        $process.Dispose()
    }

    $stdout = if ($null -eq $stdoutReader) {
        [pscustomobject][ordered]@{ text = ''; lines = @(); characters = 0; discardedCharacters = 0; truncated = $false; error = $null }
    } else {
        [pscustomobject][ordered]@{ text = $stdoutReader.Text; lines = @($stdoutReader.Lines); characters = $stdoutReader.Characters; discardedCharacters = $stdoutReader.DiscardedCharacters; truncated = $stdoutReader.Truncated; error = $stdoutReader.Error }
    }
    $stderr = if ($null -eq $stderrReader) {
        [pscustomobject][ordered]@{ text = ''; lines = @(); characters = 0; discardedCharacters = 0; truncated = $false; error = $null }
    } else {
        [pscustomobject][ordered]@{ text = $stderrReader.Text; lines = @($stderrReader.Lines); characters = $stderrReader.Characters; discardedCharacters = $stderrReader.DiscardedCharacters; truncated = $stderrReader.Truncated; error = $stderrReader.Error }
    }
    if ($null -eq $observationFailure -and (-not $stdoutCaptureComplete -or -not $stderrCaptureComplete)) {
        $observationFailure = 'Bounded stdout/stderr capture did not complete within the cleanup window.'
    }
    if ($null -eq $observationFailure -and ($stdout.error -or $stderr.error)) { $observationFailure = (($stdout.error,$stderr.error) | Where-Object { $_ }) -join '; ' }
    if ($jobAssigned -and -not $jobTerminated) {
        if (-not $cleanupLimitation) { $cleanupLimitation = 'Owned Job Object termination was not confirmed.' }
        if ($null -eq $observationFailure) { $observationFailure = 'Owned process-tree cleanup was not confirmed.' }
    }
    if ($jobAssigned -and -not $jobClosed) {
        if (-not $cleanupLimitation) { $cleanupLimitation = 'Owned Job Object handle disposal was not confirmed.' }
        if ($null -eq $observationFailure) { $observationFailure = 'Owned Job Object handle disposal was not confirmed.' }
    }
    $failureType = $null
    $succeeded = $false
    $verifier = $null
    if (-not $childStarted) {
        $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
    } elseif ($timedOut) {
        $failureType = 'TIMEOUT'
    } elseif ($null -ne $observationFailure) {
        $failureType = 'UNKNOWN_FAILURE'
    } elseif ($null -eq $exitCode) {
        $failureType = 'UNKNOWN_FAILURE'
    } elseif ($exitCode -ne 0) {
        $failureType = 'UPSTREAM_EXECUTION_FAILURE'
    } elseif ($ExpectVerifierEvidence -and ($stdout.truncated -or $stderr.truncated)) {
        $verifier = [pscustomobject][ordered]@{ valid = $false; validator = 'verifier-evidence'; state = 'UNKNOWN'; reason = 'verifier evidence was truncated by the stream bound.' }
        $failureType = 'OUTPUT_CONTRACT_FAILURE'
    } elseif ($ExpectVerifierEvidence) {
        $verifier = Test-Img2ThreejsVerifierEvidence -Stdout $stdout.lines -Stderr $stderr.lines -ExitCode $exitCode
        if (-not $verifier.valid) { $failureType = 'OUTPUT_CONTRACT_FAILURE' }
    }
    if ($childStarted -and $null -eq $failureType) { $succeeded = $true }
    return [pscustomobject][ordered]@{
        attempted = $true
        childStarted = $childStarted
        succeeded = $succeeded
        exitCode = $exitCode
        failureType = $failureType
        timedOut = $timedOut
        stdoutCaptureComplete = $stdoutCaptureComplete
        stderrCaptureComplete = $stderrCaptureComplete
        captureComplete = ($stdoutCaptureComplete -and $stderrCaptureComplete)
        stdout = @($stdout.lines)
        stderr = @($stderr.lines)
        stdoutText = $stdout.text
        stderrText = $stderr.text
        stdoutTruncated = $stdout.truncated
        stderrTruncated = $stderr.truncated
        stdoutDiscardedCharacters = $stdout.discardedCharacters
        stderrDiscardedCharacters = $stderr.discardedCharacters
        executable = $executable
        argv = @($argv)
        cleanup = New-Img2ThreejsCleanupReport -JobObjectAvailable:$jobAvailable -JobAssigned:$jobAssigned `
            -Terminated:$jobTerminated -HandleClosed:$jobClosed -Limitation $cleanupLimitation
        verifierEvidence = $verifier
        observation = if ($null -ne $observationFailure) { [pscustomobject]@{ valid = $false; reason = $observationFailure } } else { [pscustomobject]@{ valid = $true } }
    }
}

function Invoke-Img2ThreejsTrustedNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('node','python')][string]$Runtime,
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Collections.IDictionary]$Environment,
        [switch]$ExpectVerifierEvidence
    )

    $result = Invoke-Img2ThreejsRobustChild -Runtime $Runtime -ArgumentList @($ArgumentList) `
        -WorkingDirectory $WorkingDirectory -Environment $Environment -ExpectVerifierEvidence:$ExpectVerifierEvidence
    if (-not $result.succeeded) {
        $detail = if ($result.failureType -eq 'TIMEOUT') { 'timed out' } elseif ($null -ne $result.exitCode) { "exit code $($result.exitCode)" } else { [string]$result.observation.reason }
        throw "$Runtime operation failed: $detail."
    }
    return [pscustomobject][ordered]@{
        executable = $result.executable
        argv = @($ArgumentList)
        stdout = @($result.stdout)
        stderr = @($result.stderr)
        exitCode = $result.exitCode
        stdoutTruncated = $result.stdoutTruncated
        stderrTruncated = $result.stderrTruncated
        cleanup = $result.cleanup
    }
}

function New-Img2ThreejsPlanStep {
    param(
        [Parameter(Mandatory)][ValidateSet('node','python')][string]$Runtime,
        [Parameter(Mandatory)][string[]]$Argv,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$EnvironmentNames,
        [Parameter(Mandatory)][string]$Purpose,
        [ValidateSet('base','character')][string]$EnvironmentProfile = 'base'
    )
    $reportedEnvironment = @($EnvironmentNames)
    if ($Runtime -eq 'python') { $reportedEnvironment += @('PYTHONIOENCODING','PYTHONDONTWRITEBYTECODE','PYTHONNOUSERSITE') }
    return [pscustomobject][ordered]@{
        runtime = $Runtime
        executable = Resolve-Img2ThreejsRuntime -Name $Runtime
        argv = @($Argv)
        workingDirectory = $WorkingDirectory
        environmentNames = @($reportedEnvironment | Sort-Object -Unique)
        environmentProfile = $EnvironmentProfile
        purpose = $Purpose
    }
}

function Get-Img2ThreejsPipelinePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PipelineInput,
        [switch]$SkipSplat,
        [switch]$SkipBuild,
        [switch]$AllowMissingDependencies
    )

    $pipeline = 'integrations/glb_character_pipeline'
    $pythonRoot = $pipeline + '/python'
    $nodeRoot = $pipeline + '/node'
    $environmentNames = @('SystemRoot','TEMP','TMP') + @($PipelineInput.environment.Keys)
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $hasCrossSections = -not [string]::IsNullOrEmpty([string]$PipelineInput.config.values.CHARACTER_CROSS_SECTIONS)
    $hasSections = -not [string]::IsNullOrEmpty([string]$PipelineInput.config.values.CHARACTER_SECTION_REGIONS_JSON)
    $hasSpokes = -not [string]::IsNullOrEmpty([string]$PipelineInput.config.values.CHARACTER_SPOKES_JSON)
    if ($hasCrossSections -and $hasSections -and $hasSpokes) {
        $script = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($pythonRoot + '/build_cross_sections.py')
        $steps.Add((New-Img2ThreejsPlanStep python @($script) $PipelineInput.projectRoot $environmentNames 'structural-json-build-cross-sections' character))
        if ($PipelineInput.config.values.CHARACTER_ALLOW_BASELINE_UV) {
            $script = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($pythonRoot + '/bake_atlas_uvs.py')
            $steps.Add((New-Img2ThreejsPlanStep python @($script) $PipelineInput.projectRoot $environmentNames 'structural-json-bake-atlas-uvs' character))
        }
    }
    if (-not $SkipSplat) {
        $script = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($pythonRoot + '/export_sdf_surfaces.py')
        $argv = @($script) + @($PipelineInput.config.values.CHARACTER_NODES | ForEach-Object { [string]$_ })
        $steps.Add((New-Img2ThreejsPlanStep python $argv $PipelineInput.projectRoot $environmentNames 'structural-json-export-surfaces' character))
    }
    foreach ($level in @($PipelineInput.config.values.CHARACTER_LEVELS)) {
        $surfaceBin = if ($level -eq 'default') {
            Join-Path ([string]$PipelineInput.config.values.CHARACTER_BIN_DIR) 'sdf-surfaces.bin'
        } else {
            Join-Path ([string]$PipelineInput.config.values.CHARACTER_BIN_DIR) ("sdf-surfaces-$level.bin")
        }
        $dest = switch ($level) {
            'x2' { if ($PipelineInput.config.values.CHARACTER_DEST_X2) { [string]$PipelineInput.config.values.CHARACTER_DEST_X2 } else { Join-Path $PipelineInput.projectRoot "src/demos/$($PipelineInput.config.values.CHARACTER_DEMO_ID)/surfaceDataMedium.ts" } }
            'x3' { if ($PipelineInput.config.values.CHARACTER_DEST_X3) { [string]$PipelineInput.config.values.CHARACTER_DEST_X3 } else { Join-Path $PipelineInput.projectRoot "src/demos/$($PipelineInput.config.values.CHARACTER_DEMO_ID)/surfaceDataLow.ts" } }
            default { if ($PipelineInput.config.values.CHARACTER_DEST_DEFAULT) { [string]$PipelineInput.config.values.CHARACTER_DEST_DEFAULT } else { Join-Path $PipelineInput.projectRoot "src/demos/$($PipelineInput.config.values.CHARACTER_DEMO_ID)/surfaceData.ts" } }
        }
        if (-not (Test-Img2ThreejsPathWithinRoot $PipelineInput.projectRoot $dest)) { throw 'A derived surface module escaped the project.' }
        $verify = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/verify_cells.mjs')
        $encode = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/encode_surfaces.mjs')
        $emit = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/emit_surface_module.mjs')
        $steps.Add((New-Img2ThreejsPlanStep node @($verify,$surfaceBin,[string]$PipelineInput.config.values.CHARACTER_GLB) $PipelineInput.projectRoot $environmentNames "verify-cells-$level" character))
        $steps.Add((New-Img2ThreejsPlanStep node @('--max-old-space-size=8192',$encode,[string]$level) $PipelineInput.projectRoot $environmentNames "encode-surfaces-$level" character))
        $steps.Add((New-Img2ThreejsPlanStep node @($emit,[string]$level,$dest) $PipelineInput.projectRoot $environmentNames "emit-surface-module-$level" character))
    }
    $steps.Add((Get-Img2ThreejsCodecPlan -PipelineInput $PipelineInput -AllowMissingDependencies:$AllowMissingDependencies))
    foreach ($level in @($PipelineInput.config.values.CHARACTER_LEVELS)) {
        $verifyRoundtrip = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/verify_roundtrip.mjs')
        $steps.Add((New-Img2ThreejsPlanStep node @('--max-old-space-size=8192',$verifyRoundtrip,[string]$level) $PipelineInput.projectRoot $environmentNames "verify-roundtrip-$level" character))
    }
    if (-not $SkipBuild) {
        $steps.Add((Get-Img2ThreejsProjectBuildPlan -ProjectRoot $PipelineInput.projectRoot -Tool typescript -AllowMissingDependencies:$AllowMissingDependencies))
        $steps.Add((Get-Img2ThreejsProjectBuildPlan -ProjectRoot $PipelineInput.projectRoot -Tool vite -AllowMissingDependencies:$AllowMissingDependencies))
        $capture = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath ($nodeRoot + '/capture-character.mjs')
        $captureOut = Resolve-Img2ThreejsContainedPath -Root $PipelineInput.projectRoot -RelativePath ("work/cmp/pipeline-check$($PipelineInput.config.values.CHARACTER_WORK_TAG)")
        $captureArgv = @($capture,'--base','http://127.0.0.1:5200/img2threejs-showcase/','--demo',[string]$PipelineInput.config.values.CHARACTER_DEMO_ID,'--out',$captureOut)
        $steps.Add((New-Img2ThreejsPlanStep node $captureArgv $PipelineInput.projectRoot @('SystemRoot','TEMP','TMP') 'loopback-capture-with-bin-isolation'))
    }
    return $steps.ToArray()
}

function Assert-Img2ThreejsStructuralInputsNow {
    param([Parameter(Mandatory)]$PipelineInput)
    $null = ConvertFrom-Img2ThreejsStructuralData `
        -CharacterNodes @($PipelineInput.config.values.CHARACTER_NODES) `
        -RegionsPath ([string]$PipelineInput.config.values.CHARACTER_REGIONS_JSON) `
        -CellSizesPath ([string]$PipelineInput.config.values.CHARACTER_CELL_SIZES_JSON) `
        -SectionRegionsPath ([string]$PipelineInput.config.values.CHARACTER_SECTION_REGIONS_JSON) `
        -SpokesPath ([string]$PipelineInput.config.values.CHARACTER_SPOKES_JSON)
}

function Invoke-Img2ThreejsCaptureWithIsolation {
    param([Parameter(Mandatory)]$PipelineInput, [Parameter(Mandatory)]$Step)
    $bin = [string]$PipelineInput.config.values.CHARACTER_BIN_DIR
    $runtimeRoot = Join-Path $PipelineInput.projectRoot '.img2threejs/runtime'
    Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $runtimeRoot
    [IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
    Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $runtimeRoot
    Assert-Img2ThreejsNoExistingReparsePoint -Root $PipelineInput.projectRoot -Candidate $bin
    if (Test-Path -LiteralPath $bin) {
        throw 'Refusing to move or overwrite pre-existing CHARACTER_BIN_DIR during capture.'
    }
    return Invoke-Img2ThreejsTrustedNative -Runtime node -ArgumentList @($Step.argv) `
        -WorkingDirectory $PipelineInput.projectRoot -Environment ([ordered]@{})
}

function Invoke-Img2ThreejsPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$SkipSplat,
        [switch]$SkipBuild,
        [switch]$PlanOnly
    )

    $pipelineInput = Get-Img2ThreejsValidatedPipelineInput -ProjectRoot $ProjectRoot -ConfigPath $ConfigPath
    $steps = @(Get-Img2ThreejsPipelinePlan -PipelineInput $pipelineInput -SkipSplat:$SkipSplat -SkipBuild:$SkipBuild -AllowMissingDependencies:$PlanOnly)
    if ($PlanOnly) {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            operation = 'img2threejs.glb-pipeline'
            effects = @('LOCAL_PROJECT_WRITE','PROJECT_CODE_EXECUTION') + $(if (-not $SkipBuild) { @('LOOPBACK_EPHEMERAL') } else { @() })
            projectCodeExecutes = $true
            networkRequirement = 'none-external; fixed-loopback-only-when-build-enabled'
            commandStringConstructed = $false
            steps = $steps
        }
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    $codecStep = $steps | Where-Object purpose -eq 'compile-contained-codec-and-check-contract'
    $codecOutputIndex = [Array]::IndexOf([object[]]$codecStep.argv, '--output')
    if ($codecOutputIndex -lt 0) { throw 'Codec plan lacks its fixed output slot.' }
    $codecBundle = $codecStep.argv[$codecOutputIndex + 1]
    if (Test-Path -LiteralPath $codecBundle) { throw 'Refusing to overwrite a pre-existing codec bundle.' }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $pipelineInput.projectRoot -Candidate $codecBundle
    $codecOwned = $true
    try {
        foreach ($step in $steps) {
            if ($step.purpose.StartsWith('structural-json-', [StringComparison]::Ordinal)) {
                Assert-Img2ThreejsStructuralInputsNow -PipelineInput $pipelineInput
            }
            if ($step.purpose -eq 'loopback-capture-with-bin-isolation') {
                $results.Add((Invoke-Img2ThreejsCaptureWithIsolation -PipelineInput $pipelineInput -Step $step))
                continue
            }
            $environment = if ($step.environmentProfile -eq 'character') {
                $copy = [ordered]@{}
                foreach ($key in $pipelineInput.environment.Keys) { $copy[$key] = $pipelineInput.environment[$key] }
                if ($step.purpose.StartsWith('verify-roundtrip-', [StringComparison]::Ordinal)) {
                    $copy['CHARACTER_CODEC'] = $codecBundle
                }
                $copy
            } else { [ordered]@{} }
            $expectVerifier = $step.purpose.StartsWith('verify-cells-', [StringComparison]::Ordinal)
            $results.Add((Invoke-Img2ThreejsTrustedNative -Runtime $step.runtime -ArgumentList @($step.argv) `
                -WorkingDirectory $pipelineInput.projectRoot -Environment $environment -ExpectVerifierEvidence:$expectVerifier))
        }
    } finally {
        if ($codecOwned -and (Test-Path -LiteralPath $codecBundle -PathType Leaf)) {
            Assert-Img2ThreejsNoExistingReparsePoint -Root $pipelineInput.projectRoot -Candidate $codecBundle
            [IO.File]::Delete($codecBundle)
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        operation = 'img2threejs.glb-pipeline'
        executed = $true
        stepCount = $results.Count
        commandStringConstructed = $false
    }
}

function Invoke-Img2ThreejsProjectCodeOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('img2threejs.codec-verify','img2threejs.typescript-build','img2threejs.vite-build')][string]$Operation,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ConfigPath,
        [switch]$PlanOnly
    )
    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    if ($Operation -eq 'img2threejs.codec-verify') {
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) { throw 'codec-verify requires ConfigPath.' }
        $pipelineInput = Get-Img2ThreejsValidatedPipelineInput -ProjectRoot $project -ConfigPath $ConfigPath
        $step = Get-Img2ThreejsCodecPlan -PipelineInput $pipelineInput -AllowMissingDependencies:$PlanOnly
    } else {
        $tool = if ($Operation -eq 'img2threejs.typescript-build') { 'typescript' } else { 'vite' }
        $step = Get-Img2ThreejsProjectBuildPlan -ProjectRoot $project -Tool $tool -AllowMissingDependencies:$PlanOnly
    }
    if ($PlanOnly) {
        return [pscustomobject][ordered]@{ schemaVersion = 1; operation = $Operation; effects = @('PROJECT_CODE_EXECUTION','LOCAL_PROJECT_WRITE'); projectCodeExecutes = $true; networkRequirement = 'none'; commandStringConstructed = $false; steps = @($step) }
    }
    $outputOwned = $false
    if ($Operation -eq 'img2threejs.codec-verify') {
        $outputIndex = [Array]::IndexOf([object[]]$step.argv, '--output')
        if ($outputIndex -ge 0) {
            $outputCandidate = $step.argv[$outputIndex + 1]
            if (Test-Path -LiteralPath $outputCandidate) { throw 'Refusing to overwrite a pre-existing codec bundle.' }
            Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $outputCandidate
            $outputOwned = $true
        }
    }
    try {
        $result = Invoke-Img2ThreejsTrustedNative -Runtime node -ArgumentList @($step.argv) -WorkingDirectory $project -Environment ([ordered]@{})
    } finally {
        if ($Operation -eq 'img2threejs.codec-verify') {
            $outputIndex = [Array]::IndexOf([object[]]$step.argv, '--output')
            if ($outputOwned -and $outputIndex -ge 0) {
                $output = $step.argv[$outputIndex + 1]
                if (Test-Path -LiteralPath $output -PathType Leaf) {
                    Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $output
                    [IO.File]::Delete($output)
                }
            }
        }
    }
    return $result
}

function Assert-Img2ThreejsStateScalar {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name, [int]$MaxLength = 512)
    if ($Value.Length -gt $MaxLength -or $Value -match '[\x00-\x1f\x7f]') {
        throw "$Name contains controls or exceeds $MaxLength characters."
    }
}

function Assert-Img2ThreejsStoredProjectPaths {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$JsonText)
    $state = ConvertFrom-Json -InputObject $JsonText -ErrorAction Stop
    foreach ($name in @('reference','spec')) {
        $value = [string]$state.artifacts.$name
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ([IO.Path]::IsPathRooted($value)) {
            $candidate = [IO.Path]::GetFullPath($value)
            if (-not (Test-Img2ThreejsPathWithinRoot -Root $ProjectRoot -Candidate $candidate)) {
                throw "Stored state artifacts.$name escapes the project."
            }
            Assert-Img2ThreejsNoExistingReparsePoint -Root $ProjectRoot -Candidate $candidate
        } else {
            $null = Resolve-Img2ThreejsContainedPath -Root $ProjectRoot -RelativePath $value
        }
    }
}

function Invoke-Img2ThreejsStateOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet(
            'img2threejs.state.init','img2threejs.state.status','img2threejs.state.mark','img2threejs.state.next',
            'img2threejs.state.create','img2threejs.state.read','img2threejs.state.write','img2threejs.state.update'
        )][string]$Operation,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$StatePath = '.img2threejs/state.json',
        [string]$Reference,
        [ValidateSet('generic','cs2','character')][string]$Profile = 'generic',
        [string]$Spec = '',
        [ValidateRange(1,100)][int]$MaxPerPass = 3,
        [ValidateRange(1,100)][int]$MaxTotal = 6,
        [string[]]$Step,
        [ValidateSet('done','skipped','pending')][string]$MarkStatus = 'done',
        [string[]]$Evidence,
        [string]$Reason = '',
        [AllowEmptyString()][string]$JsonText
    )

    if ($MaxPerPass -gt $MaxTotal) { throw 'State loop limits require MaxPerPass <= MaxTotal.' }
    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    switch ($Operation) {
        'img2threejs.state.create' { return New-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath -JsonText $JsonText }
        'img2threejs.state.read' { return Read-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath }
        'img2threejs.state.write' { return Write-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath -JsonText $JsonText }
        'img2threejs.state.update' { return Update-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath -JsonText $JsonText }
    }

    $pythonEnvironment = [ordered]@{}
    $stateScript = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath 'forge/state.py'
    if ($Operation -eq 'img2threejs.state.init') {
        if ([string]::IsNullOrWhiteSpace($Reference)) { throw 'state.init requires Reference.' }
        $referencePath = Resolve-Img2ThreejsContainedPath -Root $project -RelativePath $Reference
        if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) { throw 'State reference does not exist.' }
        $specPath = if ($Spec) { Resolve-Img2ThreejsContainedPath -Root $project -RelativePath $Spec } else { '' }
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath -CreateAuthorizedRoot
        if (Test-Path -LiteralPath $approved.CanonicalPath) { throw 'Refusing to overwrite existing img2threejs state.' }
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath -CreateAuthorizedRoot
        $argv = @($stateScript,'init','--state',$approved.CanonicalPath,'--reference',$referencePath,'--profile',$Profile,'--max-per-pass',[string]$MaxPerPass,'--max-total',[string]$MaxTotal)
        if ($specPath) { $argv += @('--spec',$specPath) }
        $result = Invoke-Img2ThreejsTrustedNative python $argv $project $pythonEnvironment
        $verified = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        if (-not (Test-Path -LiteralPath $verified.CanonicalPath -PathType Leaf)) { throw 'state.init failed post-mutation verification.' }
        return $result
    }

    $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
    if (-not (Test-Path -LiteralPath $approved.CanonicalPath -PathType Leaf)) { throw 'Img2threejs state file does not exist.' }
    if ($Operation -eq 'img2threejs.state.status') {
        return Invoke-Img2ThreejsTrustedNative python @($stateScript,'status','--state',$approved.CanonicalPath,'--json') $project $pythonEnvironment
    }
    if ($Operation -eq 'img2threejs.state.mark') {
        if (-not @($Step).Count) { throw 'state.mark requires at least one Step.' }
        foreach ($value in @($Step)) {
            if ($value -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'State step identifiers must be lowercase slugs.' }
        }
        foreach ($value in @($Evidence)) { Assert-Img2ThreejsStateScalar $value 'Evidence' }
        Assert-Img2ThreejsStateScalar $Reason 'Reason'
        $argv = @($stateScript,'mark') + @($Step) + @('--state',$approved.CanonicalPath,'--status',$MarkStatus)
        foreach ($value in @($Evidence)) { $argv += @('--evidence',$value) }
        if ($Reason) { $argv += @('--reason',$Reason) }
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        $result = Invoke-Img2ThreejsTrustedNative python $argv $project $pythonEnvironment
        $verified = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        if (-not (Test-Path -LiteralPath $verified.CanonicalPath -PathType Leaf)) { throw 'state.mark failed post-mutation verification.' }
        return $result
    }
    if ($Operation -eq 'img2threejs.state.next') {
        $read = Read-Img2ThreejsState -ProjectRoot $project -StatePath $StatePath
        Assert-Img2ThreejsStoredProjectPaths -ProjectRoot $project -JsonText $read.JsonText
        $nextScript = Resolve-Img2ThreejsPinnedUpstreamFile -RelativePath 'forge/next.py'
        $approved = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        $result = Invoke-Img2ThreejsTrustedNative python @($nextScript,'--state',$approved.CanonicalPath) $project $pythonEnvironment
        $verified = Resolve-Img2ThreejsStateTarget -ProjectRoot $project -StatePath $StatePath
        if (-not (Test-Path -LiteralPath $verified.CanonicalPath -PathType Leaf)) { throw 'state.next failed post-operation verification.' }
        return $result
    }
    throw "Unhandled state operation: $Operation"
}

function Resolve-Img2ThreejsPinnedUpstreamFile {
    param([Parameter(Mandatory)][string]$RelativePath, [switch]$AllowMissing)
    $root = Resolve-Img2ThreejsPinnedUpstreamRoot
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $root -Candidate $candidate)) {
        throw 'A registered upstream path escaped the pinned img2threejs root.'
    }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $root -Candidate $candidate
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "A required pinned img2threejs file is unavailable: $RelativePath"
    }
    return $candidate
}

function ConvertTo-Img2ThreejsChildEnvironment {
    param([Parameter(Mandatory)]$Config)
    $schema = Get-Img2ThreejsGlbConfigSchema
    $environment = [ordered]@{}
    foreach ($key in $schema.Keys) {
        $value = $Config.values.PSObject.Properties[$key].Value
        $definition = $schema[$key]
        if ($definition.Kind -in @('project-path','project-code-path','optional-project-path','diffuse-path') -and
            -not ([string]$value -in @('','none','neutral','embedded','glb'))) {
            $environment[$key] = [string]$value
        } elseif ($definition.Kind -eq 'node-list' -or $definition.Kind -eq 'level-list') {
            $environment[$key] = (@($value) -join ' ')
        } elseif ($definition.Kind -eq 'opt-in-flag') {
            $environment[$key] = if ($value) { '1' } else { '' }
        } else {
            $environment[$key] = [string]$Config.environment.PSObject.Properties[$key].Value
        }
    }
    $environment['IMG2THREEJS_SHOWCASE_ROOT'] = $Config.projectRoot
    return $environment
}

function Get-Img2ThreejsValidatedPipelineInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$StrictProceduralContract
    )

    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    $config = ConvertFrom-Img2ThreejsGlbConfig -LiteralPath $ConfigPath -ProjectRoot $project
    if ($StrictProceduralContract) {
        $diffuse = [string]$config.values.CHARACTER_DIFFUSE
        $diffuseMode = if ($diffuse -in @('none','neutral','embedded','glb')) { $diffuse } else { 'external' }
        $glbNodes = @(Get-Img2ThreejsGlbNodeInventory -LiteralPath $config.values.CHARACTER_GLB -ProjectRoot $project `
            -CharacterNodes @($config.values.CHARACTER_NODES) -RequirePipelineGeometry -RequireBin -RequireNormal `
            -RequireTexCoord:($diffuseMode -in @('embedded','glb','external')) -DiffuseMode $diffuseMode)
    } else {
        $glbNodes = @(Get-Img2ThreejsGlbNodeInventory -LiteralPath $config.values.CHARACTER_GLB)
    }
    $null = Assert-Img2ThreejsConfiguredNodesExist -CharacterNodes @($config.values.CHARACTER_NODES) -GlbNodes $glbNodes
    $structural = ConvertFrom-Img2ThreejsStructuralData `
        -CharacterNodes @($config.values.CHARACTER_NODES) `
        -RegionsPath ([string]$config.values.CHARACTER_REGIONS_JSON) `
        -CellSizesPath ([string]$config.values.CHARACTER_CELL_SIZES_JSON) `
        -SectionRegionsPath ([string]$config.values.CHARACTER_SECTION_REGIONS_JSON) `
        -SpokesPath ([string]$config.values.CHARACTER_SPOKES_JSON)
    $codec = [string]$config.values.CHARACTER_CODEC
    if (-not (Test-Path -LiteralPath $codec -PathType Leaf) -or [IO.Path]::GetExtension($codec) -notin @('.ts','.tsx','.js','.mjs')) {
        throw 'CHARACTER_CODEC must resolve to an existing supported project-code entrypoint.'
    }
    $null = Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $codec
    $childEnvironment = ConvertTo-Img2ThreejsChildEnvironment -Config $config
    Write-Output -NoEnumerate ([pscustomobject][ordered]@{
        projectRoot = $project
        config = $config
        structural = $structural
        environment = $childEnvironment
    })
}

function Resolve-Img2ThreejsProjectToolEntrypoint {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('typescript','vite')][string]$Tool,
        [switch]$AllowMissing
    )
    $relative = if ($Tool -eq 'typescript') { 'node_modules/typescript/bin/tsc' } else { 'node_modules/vite/bin/vite.js' }
    $path = Resolve-Img2ThreejsContainedPath -Root $ProjectRoot -RelativePath $relative
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Tool is not already resolved inside the project; the runner will not download it."
    }
    return $path
}

function Get-Img2ThreejsCodecPlan {
    param([Parameter(Mandatory)]$PipelineInput, [switch]$AllowMissingDependencies)
    $upstream = Resolve-Img2ThreejsPinnedUpstreamRoot
    $esbuild = Resolve-Img2ThreejsPinnedUpstreamFile `
        -RelativePath 'integrations/glb_character_pipeline/node/node_modules/esbuild/lib/main.js' `
        -AllowMissing:$AllowMissingDependencies
    $mediator = Join-Path $PSScriptRoot 'img2threejs-codec-mediator.mjs'
    $output = Join-Path $PipelineInput.projectRoot ('.img2threejs/runtime/codec-' + [guid]::NewGuid().ToString('N') + '.mjs')
    $argv = @(
        $mediator,
        '--project-root', $PipelineInput.projectRoot,
        '--codec', [string]$PipelineInput.config.values.CHARACTER_CODEC,
        '--output', $output,
        '--esbuild-module', $esbuild,
        '--upstream-root', $upstream,
        '--execute-contract'
    )
    return New-Img2ThreejsPlanStep -Runtime node -Argv $argv -WorkingDirectory $PipelineInput.projectRoot `
        -EnvironmentNames @('SystemRoot','TEMP','TMP') -Purpose 'compile-contained-codec-and-check-contract'
}

function Get-Img2ThreejsProjectBuildPlan {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('typescript','vite')][string]$Tool,
        [switch]$AllowMissingDependencies
    )
    $entrypoint = Resolve-Img2ThreejsProjectToolEntrypoint -ProjectRoot $ProjectRoot -Tool $Tool -AllowMissing:$AllowMissingDependencies
    $argv = if ($Tool -eq 'typescript') { @($entrypoint, '--noEmit') } else { @($entrypoint, 'build') }
    return New-Img2ThreejsPlanStep -Runtime node -Argv $argv -WorkingDirectory $ProjectRoot `
        -EnvironmentNames @('SystemRoot','TEMP','TMP') -Purpose ($Tool + '-project-build')
}

function Resolve-Img2ThreejsOutputArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $relative = Assert-Img2ThreejsSafeRelativePathSyntax -RelativePath $RelativePath -Name 'artifact relativePath'
    $root = (Resolve-Path -LiteralPath $OutputRoot).Path
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $root -Candidate $candidate)) { throw 'Artifact path escaped the authorized output root.' }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $root -Candidate $candidate
    return $candidate
}

function New-Img2ThreejsArtifactSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('HEDS','TypeScript','NPY','verifier-evidence','generic')][string]$Kind,
        [string]$Level = '',
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$Required = $true,
        [string]$ExpectedDtype,
        [string]$ReferencedBinaryRelativePath
    )
    $null = Assert-Img2ThreejsSafeRelativePathSyntax -RelativePath $RelativePath -Name 'artifact relativePath'
    return [pscustomobject][ordered]@{
        kind = $Kind
        level = $Level
        relativePath = $RelativePath.Replace([char]92, [char]47)
        required = $Required
        expectedDtype = $ExpectedDtype
        referencedBinaryRelativePath = $ReferencedBinaryRelativePath
    }
}

function Get-Img2ThreejsProceduralArtifactPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('sdf','encode','roundtrip','full')][string]$Stage,
        [Parameter(Mandatory)][string[]]$Levels
    )

    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($level in $Levels) {
        if ($level -notin @('x2','x3','default')) { throw "Unsupported procedural artifact level: $level" }
        $suffix = if ($level -eq 'default') { '' } else { '-' + $level }
        if ($Stage -in @('sdf','full')) {
            $plan.Add((New-Img2ThreejsArtifactSpec -Kind HEDS -Level $level -RelativePath ("artifacts/$level/sdf-surfaces$suffix.bin")))
            $plan.Add((New-Img2ThreejsArtifactSpec -Kind NPY -Level $level -RelativePath ("work/$level/V.npy") -Required:$false -ExpectedDtype '<f4'))
            $plan.Add((New-Img2ThreejsArtifactSpec -Kind NPY -Level $level -RelativePath ("work/$level/T.npy") -Required:$false -ExpectedDtype '<i4'))
            $plan.Add((New-Img2ThreejsArtifactSpec -Kind NPY -Level $level -RelativePath ("work/$level/cloud.npy") -Required:$false -ExpectedDtype '<f4'))
        }
        if ($Stage -in @('encode','roundtrip','full')) {
            $plan.Add((New-Img2ThreejsArtifactSpec -Kind TypeScript -Level $level -RelativePath ("artifacts/$level/surfaceData.ts")))
        }
        if ($Stage -in @('roundtrip','full')) {
            $plan.Add((New-Img2ThreejsArtifactSpec -Kind verifier-evidence -Level $level -RelativePath ("work/$level/roundtrip.txt")))
        }
    }
    return $plan.ToArray()
}

function Test-Img2ThreejsKnownArtifact {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    switch ([string]$Spec.kind) {
        'HEDS' { return Test-Img2ThreejsHedsArtifact -LiteralPath $LiteralPath }
        'TypeScript' {
            $reference = $null
            if ($Spec.referencedBinaryRelativePath) { $reference = Resolve-Img2ThreejsOutputArtifactPath -OutputRoot $OutputRoot -RelativePath ([string]$Spec.referencedBinaryRelativePath) }
            return Test-Img2ThreejsTypescriptArtifact -LiteralPath $LiteralPath -ExpectedLevel ([string]$Spec.level) -ReferencedBinaryPath $reference
        }
        'NPY' { return Test-Img2ThreejsNpyArtifact -LiteralPath $LiteralPath -ExpectedDtype ([string]$Spec.expectedDtype) }
        'verifier-evidence' {
            try {
                $text = Get-Img2ThreejsBoundedUtf8Text -LiteralPath $LiteralPath -MaximumBytes $script:Img2ThreejsVerifierMaximumBytes
                return Test-Img2ThreejsVerifierEvidence -Stdout @($text -split '\r?\n') -Stderr @() -ExitCode 0
            } catch { return [pscustomobject][ordered]@{ valid = $false; validator = 'verifier-evidence'; reason = $_.Exception.Message } }
        }
        default { return [pscustomobject][ordered]@{ valid = $true; validator = 'non-empty-file' } }
    }
}

function New-Img2ThreejsArtifactRecord {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $relative = [string]$Spec.relativePath
    try { $path = Resolve-Img2ThreejsOutputArtifactPath -OutputRoot $OutputRoot -RelativePath $relative }
    catch {
        return [pscustomobject][ordered]@{
            kind = [string]$Spec.kind; level = [string]$Spec.level; relativePath = $relative;
            required = [bool]$Spec.required; exists = $false; bytes = 0; sha256 = $null;
            validation = [pscustomobject][ordered]@{ valid = $false; validator = 'path-containment'; reason = $_.Exception.Message }
        }
    }
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    if (-not $exists) {
        return [pscustomobject][ordered]@{
            kind = [string]$Spec.kind; level = [string]$Spec.level; relativePath = $relative;
            required = [bool]$Spec.required; exists = $false; bytes = 0; sha256 = $null;
            validation = [pscustomobject][ordered]@{ valid = (-not [bool]$Spec.required); validator = 'presence'; reason = 'artifact absent' }
        }
    }
    try {
        $item = Get-Item -Force -LiteralPath $path
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'artifact is not a regular file' }
        if ($item.Length -le 0) { throw 'artifact is empty' }
        $validation = Test-Img2ThreejsKnownArtifact -Spec $Spec -LiteralPath $path -OutputRoot $OutputRoot
        $hash = Get-Img2ThreejsFileSha256 -LiteralPath $path
        return [pscustomobject][ordered]@{
            kind = [string]$Spec.kind; level = [string]$Spec.level; relativePath = $relative;
            required = [bool]$Spec.required; exists = $true; bytes = [int64]$item.Length; sha256 = $hash;
            validation = $validation
        }
    } catch {
        return [pscustomobject][ordered]@{
            kind = [string]$Spec.kind; level = [string]$Spec.level; relativePath = $relative;
            required = [bool]$Spec.required; exists = $true; bytes = [int64]$item.Length; sha256 = $null;
            validation = [pscustomobject][ordered]@{ valid = $false; validator = 'artifact'; reason = $_.Exception.Message }
        }
    }
}

function New-Img2ThreejsArtifactManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][object[]]$ArtifactSpecs,
        [string[]]$PartialRelativePaths = @(),
        [string[]]$Limitations = @(),
        [string]$SourceFingerprint
    )

    $artifacts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($spec in @($ArtifactSpecs)) { $artifacts.Add((New-Img2ThreejsArtifactRecord -Spec $spec -OutputRoot $OutputRoot)) }
    $partial = New-Object 'System.Collections.Generic.List[object]'
    foreach ($relative in @($PartialRelativePaths)) {
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $spec = New-Img2ThreejsArtifactSpec -Kind generic -RelativePath $relative -Required:$false
        $record = New-Img2ThreejsArtifactRecord -Spec $spec -OutputRoot $OutputRoot
        if ($record.exists) { $partial.Add($record) }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        operation = 'img2threejs.glb-procedural'
        sourceFingerprint = $SourceFingerprint
        artifacts = @($artifacts.ToArray())
        partialArtifacts = @($partial.ToArray())
        limitations = @($Limitations | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
}

function Assert-Img2ThreejsManifestRecordShape {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$CollectionName)
    foreach ($name in @('kind','level','relativePath','required','exists','bytes','sha256','validation')) {
        if ($null -eq $Record.PSObject.Properties[$name]) { throw "$CollectionName record lacks $name." }
    }
    if ([string]$Record.kind -notin @('HEDS','TypeScript','NPY','verifier-evidence','generic')) { throw "$CollectionName record has an unsupported artifact kind." }
    if ($Record.required -isnot [bool] -or $Record.exists -isnot [bool]) { throw "$CollectionName record required/exists fields must be booleans." }
    $bytes = 0L
    if (-not [long]::TryParse([string]$Record.bytes, [ref]$bytes) -or $bytes -lt 0) { throw "$CollectionName record bytes must be a non-negative integer." }
    if (-not $Record.exists -and ($bytes -ne 0 -or $null -ne $Record.sha256)) { throw "$CollectionName absent record has inconsistent bytes/hash." }
    if ($Record.exists -and ([string]$Record.sha256 -notmatch '^[0-9a-f]{64}$')) { throw "$CollectionName record sha256 is not canonical." }
    if ($Record.validation.valid -isnot [bool]) { throw "$CollectionName record validation.valid must be a boolean." }
}

function Test-Img2ThreejsOutputManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    try {
        if ([int]$Manifest.schemaVersion -ne 1) { throw 'Output manifest schemaVersion must be 1.' }
        if ([string]$Manifest.operation -cne 'img2threejs.glb-procedural') { throw 'Output manifest operation is not FTK-owned.' }
        foreach ($name in @('artifacts','partialArtifacts','limitations')) {
            if ($null -eq $Manifest.PSObject.Properties[$name]) { throw "Output manifest lacks $name." }
        }
        if ($null -ne $Manifest.sourceFingerprint -and [string]$Manifest.sourceFingerprint -and [string]$Manifest.sourceFingerprint -notmatch '^[0-9a-f]{64}$') {
            throw 'Output manifest sourceFingerprint is not canonical.'
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $allRequiredValid = $true
        foreach ($collectionName in @('artifacts','partialArtifacts')) {
            $records = @($Manifest.PSObject.Properties[$collectionName].Value)
            foreach ($record in $records) {
                if ($null -eq $record) { throw "$collectionName contains a null record." }
                Assert-Img2ThreejsManifestRecordShape -Record $record -CollectionName $collectionName
                $relative = [string]$record.relativePath
                $resolved = Resolve-Img2ThreejsOutputArtifactPath -OutputRoot $OutputRoot -RelativePath $relative
                if (-not $seen.Add($relative.Replace([char]92, [char]47))) { throw "Output manifest contains duplicate path $relative." }
                if ($relative -ceq 'manifest.json') { throw 'Output manifest cannot self-reference manifest.json.' }
                $actualAny = Test-Path -LiteralPath $resolved
                $actualExists = Test-Path -LiteralPath $resolved -PathType Leaf
                if (-not [bool]$record.exists -and $actualAny) { throw "Manifest falsely claims an existing artifact is absent: $relative" }
                if ([bool]$record.exists) {
                    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Manifest claims a missing artifact: $relative" }
                    $item = Get-Item -Force -LiteralPath $resolved
                    if ($item.Length -le 0 -or [int64]$record.bytes -ne [int64]$item.Length) { throw "Manifest byte count mismatch: $relative" }
                    $actualHash = Get-Img2ThreejsFileSha256 -LiteralPath $resolved
                    if ([string]$record.sha256 -cne $actualHash) { throw "Manifest hash mismatch: $relative" }
                    $actualSpec = [pscustomobject][ordered]@{
                        kind = [string]$record.kind; level = [string]$record.level; required = [bool]$record.required;
                        relativePath = $relative; expectedDtype = $null; referencedBinaryRelativePath = $null
                    }
                    $actualValidation = Test-Img2ThreejsKnownArtifact -Spec $actualSpec -LiteralPath $resolved -OutputRoot $OutputRoot
                    $record.validation = $actualValidation
                } elseif ([bool]$record.required) {
                    $allRequiredValid = $false
                }
                $validationValid = $false
                $validation = $record.PSObject.Properties['validation']
                if ($null -ne $validation) { $validationValid = [bool]$validation.Value.valid }
                if ([bool]$record.required -and (-not [bool]$record.exists -or -not $validationValid)) { $allRequiredValid = $false }
            }
        }
        return [pscustomobject][ordered]@{ valid = $allRequiredValid; requiredArtifactsValid = $allRequiredValid; partial = (@($Manifest.partialArtifacts).Count -gt 0); manifest = $Manifest; reason = if ($allRequiredValid) { $null } else { 'One or more required output artifacts are missing or invalid.' } }
    } catch {
        return [pscustomobject][ordered]@{ valid = $false; requiredArtifactsValid = $false; partial = $false; manifest = $Manifest; reason = $_.Exception.Message }
    }
}

function Assert-Img2ThreejsOutputManifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$OutputRoot)
    $result = Test-Img2ThreejsOutputManifest -Manifest $Manifest -OutputRoot $OutputRoot
    if (-not $result.valid) { throw [string]$result.reason }
    return $result.manifest
}

function Write-Img2ThreejsOutputManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)]$Manifest
    )
    $null = Assert-Img2ThreejsOutputManifest -Manifest $Manifest -OutputRoot $OutputRoot
    $path = Resolve-Img2ThreejsOutputArtifactPath -OutputRoot $OutputRoot -RelativePath 'manifest.json'
    if (Test-Path -LiteralPath $path) { throw 'Refusing to overwrite a pre-existing output manifest.' }
    $json = ConvertTo-Json -InputObject $Manifest -Depth 20 -Compress
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + "`n")
    Assert-Img2ThreejsNoExistingReparsePoint -Root ((Resolve-Path -LiteralPath $OutputRoot).Path) -Candidate $path
    $stream = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    Assert-Img2ThreejsNoExistingReparsePoint -Root ((Resolve-Path -LiteralPath $OutputRoot).Path) -Candidate $path
    return $path
}

function Assert-Img2ThreejsOutputTargetsAreNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][object[]]$ArtifactSpecs
    )
    foreach ($spec in @($ArtifactSpecs)) {
        $path = Resolve-Img2ThreejsOutputArtifactPath -OutputRoot $OutputRoot -RelativePath ([string]$spec.relativePath)
        if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite pre-existing target artifact: $($spec.relativePath)" }
    }
    return $true
}

function New-Img2ThreejsOwnedTransactionRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    $base = Join-Path $project '.img2threejs/runtime/transactions'
    $created = New-Object 'System.Collections.Generic.List[string]'
    $current = $project
    foreach ($segment in @('.img2threejs','runtime','transactions')) {
        $current = Join-Path $current $segment
        Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $current
        if (-not (Test-Path -LiteralPath $current -PathType Container)) {
            [IO.Directory]::CreateDirectory($current) | Out-Null
            $created.Add($current)
            Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $current
        }
    }
    $root = Join-Path $current ('phase1-' + [guid]::NewGuid().ToString('N'))
    Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $root
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $root
    $created.Add($root)
    return [pscustomobject][ordered]@{ root = (Resolve-Path -LiteralPath $root).Path; owned = $true; projectRoot = $project; createdPaths = $created.ToArray() }
}

function Get-Img2ThreejsOwnedPartialArtifactRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputRoot)
    $root = (Resolve-Path -LiteralPath $OutputRoot).Path
    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A transaction output contains a reparse point.' }
        $relative = $item.FullName.Substring($root.Length).TrimStart([char]92, [char]47).Replace([char]92, [char]47)
        if ($relative -ceq 'manifest.json') { continue }
        $spec = New-Img2ThreejsArtifactSpec -Kind generic -RelativePath $relative -Required:$false
        $record = New-Img2ThreejsArtifactRecord -Spec $spec -OutputRoot $root
        $records.Add($record)
    }
    return $records.ToArray()
}

function Remove-Img2ThreejsOwnedTransactionRoot {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Transaction)
    if (-not $Transaction.owned) { return [pscustomobject][ordered]@{ attempted = $false; removed = $false; limitation = 'transaction root was not runner-owned' } }
    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $Transaction.projectRoot
    $root = (Resolve-Path -LiteralPath $Transaction.root).Path
    $authorized = Join-Path $project '.img2threejs/runtime/transactions'
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $authorized -Candidate $root) -or $root.Equals($authorized, (Get-Img2ThreejsPathComparison))) { throw 'Owned transaction cleanup target escaped its authorized root.' }
    Assert-Img2ThreejsNoExistingReparsePoint -Root $project -Candidate $root
    if ($PSCmdlet.ShouldProcess($root,'remove runner-owned transaction root')) {
        [IO.Directory]::Delete($root, $true)
        return [pscustomobject][ordered]@{ attempted = $true; removed = $true; limitation = $null }
    }
    return [pscustomobject][ordered]@{ attempted = $false; removed = $false; limitation = 'cleanup was not approved by ShouldProcess' }
}

function ConvertFrom-Img2ThreejsChildObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Observation)
    try {
        foreach ($name in @('attempted','childStarted','succeeded','timedOut','failureType','exitCode','stdout','stderr','cleanup')) {
            if ($null -eq $Observation.PSObject.Properties[$name]) { throw "Child observation lacks $name." }
        }
        foreach ($name in @('attempted','childStarted','succeeded','timedOut')) {
            if ($Observation.$name -isnot [bool]) { throw "Child observation $name must be a boolean." }
        }
        $failure = if ($null -eq $Observation.failureType) { $null } else { [string]$Observation.failureType }
        if ($failure -and $failure -notin (Get-FtkDedicatedExecutionFailureTypes)) { throw "Child observation has an unknown failureType: $failure" }
        $exit = $null
        if ($null -ne $Observation.exitCode) {
            $exitValue = 0
            if (-not [int]::TryParse([string]$Observation.exitCode, [ref]$exitValue)) { throw 'Child observation exitCode must be an integer or null.' }
            $exit = [Nullable[int]]$exitValue
        }
        $common = New-FtkDedicatedExecutionResult -Capability 'img2threejs' -Operation 'img2threejs.glb-procedural' `
            -Materialized:([bool]$Observation.attempted) -Attempted:$Observation.attempted -ChildStarted:$Observation.childStarted `
            -Succeeded:$Observation.succeeded -ExitCode $exit -FailureType $failure -TimedOut:$Observation.timedOut `
            -Diagnostics ([ordered]@{}) -Evidence ([ordered]@{})
        return [pscustomobject][ordered]@{ valid = $true; observation = $Observation; reason = $null }
    } catch { return [pscustomobject][ordered]@{ valid = $false; observation = $Observation; reason = $_.Exception.Message } }
}

function New-Img2ThreejsProceduralExecutionEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Materialized,
        [Parameter(Mandatory)][bool]$Attempted,
        [Parameter(Mandatory)][bool]$ChildStarted,
        [Parameter(Mandatory)][bool]$Succeeded,
        [AllowNull()][Nullable[int]]$ExitCode,
        [AllowNull()][string]$FailureType,
        [bool]$TimedOut = $false,
        [AllowNull()][object]$Cleanup,
        [AllowNull()][string]$SourceFingerprint,
        [AllowNull()][object]$Artifacts,
        [AllowNull()][object]$Manifest,
        [string]$Reason = ''
    )

    $diagnostics = [ordered]@{}
    if ($Reason) { $diagnostics.message = $Reason }
    if ($null -ne $Cleanup) { $diagnostics.cleanup = $Cleanup }
    $base = New-FtkDedicatedExecutionResult -Capability 'img2threejs' -Operation 'img2threejs.glb-procedural' `
        -Materialized:$Materialized -Attempted:$Attempted -ChildStarted:$ChildStarted -Succeeded:$Succeeded `
        -ExitCode $ExitCode -FailureType $FailureType -TimedOut:$TimedOut -Diagnostics $diagnostics -Evidence ([ordered]@{})
    Add-Member -InputObject $base -NotePropertyName cleanup -NotePropertyValue $Cleanup
    Add-Member -InputObject $base -NotePropertyName sourceFingerprint -NotePropertyValue $SourceFingerprint
    Add-Member -InputObject $base -NotePropertyName artifacts -NotePropertyValue @($Artifacts)
    Add-Member -InputObject $base -NotePropertyName manifest -NotePropertyValue $Manifest
    return $base
}

function Invoke-Img2ThreejsProceduralPhase1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$OutputRoot,
        [ValidateRange(1,600000)][int]$TimeoutMilliseconds = 120000,
        [string]$ExpectedSourceFingerprint
    )

    $input = $null
    try { $input = Get-Img2ThreejsProceduralInputContract -ProjectRoot $ProjectRoot -ConfigPath $ConfigPath -OutputRoot $OutputRoot }
    catch {
        return New-Img2ThreejsProceduralExecutionEnvelope -Materialized:$false -Attempted:$false -ChildStarted:$false -Succeeded:$false `
            -ExitCode $null -FailureType 'INVALID_INPUT' -Reason $_.Exception.Message -Artifacts @()
    }
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $source = Test-Img2ThreejsSourceProvenance -RepositoryRoot $repoRoot -ExpectedFingerprint $ExpectedSourceFingerprint
    if (-not $source.materialized) {
        return New-Img2ThreejsProceduralExecutionEnvelope -Materialized:$false -Attempted:$false -ChildStarted:$false -Succeeded:$false `
            -ExitCode $null -FailureType 'DEPENDENCY_OR_RUNTIME_FAILURE' -SourceFingerprint $null -Reason $source.reason -Artifacts @()
    }
    if (-not $source.valid) {
        return New-Img2ThreejsProceduralExecutionEnvelope -Materialized:$true -Attempted:$false -ChildStarted:$false -Succeeded:$false `
            -ExitCode $null -FailureType 'DEPENDENCY_OR_RUNTIME_FAILURE' -SourceFingerprint $source.sourceFingerprint -Reason $source.reason -Artifacts @()
    }
    # Phase 1 deliberately stops before the real upstream stages. The robust
    # child runner is independently testable through the explicit synthetic
    # fixture gate; no runtime fallback is allowed here.
    return New-Img2ThreejsProceduralExecutionEnvelope -Materialized:$true -Attempted:$false -ChildStarted:$false -Succeeded:$false `
        -ExitCode $null -FailureType 'DEPENDENCY_OR_RUNTIME_FAILURE' -SourceFingerprint $source.sourceFingerprint `
        -Reason 'Real upstream procedural execution is deferred to Phase 2.' -Artifacts @()
}

function Invoke-Img2ThreejsProceduralSyntheticFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$SyntheticScriptPath,
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][object[]]$ArtifactSpecs,
        [ValidateRange(1,600000)][int]$TimeoutMilliseconds = 120000
    )

    if ($TimeoutMilliseconds -gt (Get-FtkDedicatedExecutionMaximumTimeoutMilliseconds)) {
        throw "Timeout exceeds the FTK maximum of $(Get-FtkDedicatedExecutionMaximumTimeoutMilliseconds) milliseconds."
    }
    $project = Resolve-Img2ThreejsCanonicalProjectRoot -ProjectRoot $ProjectRoot
    $output = (Resolve-Path -LiteralPath $OutputRoot).Path
    if (-not (Test-Img2ThreejsPathWithinRoot -Root $project -Candidate $output) -or $output.Equals($project, (Get-Img2ThreejsPathComparison))) {
        throw 'Synthetic procedural output root must be contained below the project root.'
    }
    Assert-Img2ThreejsOutputTargetsAreNew -OutputRoot $output -ArtifactSpecs $ArtifactSpecs | Out-Null
    $child = Invoke-Img2ThreejsRobustChild -Runtime synthetic -SyntheticFixture -SyntheticScriptPath $SyntheticScriptPath `
        -ArgumentList $ArgumentList -WorkingDirectory $project -TimeoutMilliseconds $TimeoutMilliseconds
    $partialPaths = @()
    if (-not $child.succeeded) {
        $partialPaths = @(Get-Img2ThreejsOwnedPartialArtifactRecords -OutputRoot $output | ForEach-Object { $_.relativePath })
    }
    $manifest = New-Img2ThreejsArtifactManifest -OutputRoot $output -ArtifactSpecs $ArtifactSpecs `
        -PartialRelativePaths $partialPaths -SourceFingerprint ''
    $manifestCheck = Test-Img2ThreejsOutputManifest -Manifest $manifest -OutputRoot $output
    $failureType = $child.failureType
    if ($child.succeeded -and -not $manifestCheck.valid) { $failureType = 'OUTPUT_CONTRACT_FAILURE' }
    $succeeded = $child.succeeded -and $manifestCheck.valid
    $reason = if ($succeeded) { '' } elseif ($null -ne $manifestCheck.reason) { [string]$manifestCheck.reason } else { [string]$child.observation.reason }
    $envelope = New-Img2ThreejsProceduralExecutionEnvelope -Materialized:$true -Attempted:$true `
        -ChildStarted:$child.childStarted -Succeeded:$succeeded -ExitCode $child.exitCode `
        -FailureType $failureType -TimedOut:$child.timedOut -Cleanup $child.cleanup `
        -SourceFingerprint $null -Artifacts @($manifest.artifacts) -Manifest $manifest `
        -Reason $reason
    Add-Member -InputObject $envelope -NotePropertyName stdout -NotePropertyValue @($child.stdout)
    Add-Member -InputObject $envelope -NotePropertyName stderr -NotePropertyValue @($child.stderr)
    Add-Member -InputObject $envelope -NotePropertyName captureComplete -NotePropertyValue $child.captureComplete
    return $envelope
}
