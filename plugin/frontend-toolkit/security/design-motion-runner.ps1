Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'execution-contract.ps1')
. (Join-Path $PSScriptRoot 'design-motion-contract.ps1')
. (Join-Path $PSScriptRoot 'design-motion-source-verifier.ps1')

if ($null -eq ('Ftk.DesignMotion.BoundedStreamCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Ftk.DesignMotion {
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

        public static bool Terminate(IntPtr job, uint exitCode) { return TerminateJobObject(job, exitCode); }
        public static bool Close(IntPtr job) { return CloseHandle(job); }
    }
}
'@
}

function ConvertTo-DesignMotionWindowsNativeArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s\"]') { return $Argument }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
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

function Resolve-DesignMotionNodeRuntime {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$AllowPreparedRuntimeFallback
    )

    $portable = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs/FrontendToolkit/node-v24.20.0-win-x64/node.exe'
    try {
        if (Test-Path -LiteralPath $portable -PathType Leaf) { return [IO.Path]::GetFullPath($portable) }
    } catch { }
    if ($AllowPreparedRuntimeFallback) {
        try {
            $pathCommand = Get-Command node -ErrorAction Stop
            if ($pathCommand.CommandType -eq 'Application' -and -not [string]::IsNullOrWhiteSpace($pathCommand.Source)) {
                $candidate = [IO.Path]::GetFullPath($pathCommand.Source)
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $version = (& $candidate '--version' 2>$null | Select-Object -First 1).Trim()
                    if ($version -ceq 'v24.20.0') { return $candidate }
                }
            }
        } catch { }
    }
    throw 'The locked Node 24.20.0 runtime is unavailable.'
}

function New-DesignMotionChildEnvironment {
    $environment = [ordered]@{}
    foreach ($name in @('SystemRoot', 'TEMP', 'TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
    }
    $environment['FTK_DESIGN_MOTION_CHILD'] = '1'
    $environment['DO_NOT_TRACK'] = '1'
    return $environment
}

function Set-DesignMotionChildEnvironment {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment
    )

    try {
        $variables = $StartInfo.EnvironmentVariables
        if ($null -eq $variables) { throw 'ProcessStartInfo environment dictionary is unavailable.' }
        $variables.Clear()
    } catch {
        $field = $StartInfo.GetType().GetField('environmentVariables', [Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -eq $field) { throw 'Unable to create the isolated design-motion child environment.' }
        $variables = New-Object Collections.Specialized.StringDictionary
        $field.SetValue($StartInfo, $variables)
        $variables.Clear()
    }
    foreach ($name in $Environment.Keys) { $variables.Add([string]$name, [string]$Environment[$name]) }
}

function Stop-DesignMotionChildProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][IntPtr]$JobHandle,
        [bool]$JobAssigned = $false
    )

    $jobTerminated = $false
    $directKill = $false
    try {
        if ($JobAssigned -and $JobHandle -ne [IntPtr]::Zero) {
            $jobTerminated = [bool][Ftk.DesignMotion.ProcessContainment]::Terminate($JobHandle, 124)
        }
    } catch { $jobTerminated = $false }
    try {
        if (-not $Process.HasExited -and (-not $jobTerminated)) { $Process.Kill(); $directKill = $true }
    } catch { }
    $processExited = $false
    try { [void]$Process.WaitForExit(5000); $processExited = [bool]$Process.HasExited } catch { $processExited = $false }
    return [pscustomobject][ordered]@{
        jobTerminated = $jobTerminated
        directKill = $directKill
        processExited = $processExited
        cleanupGuaranteed = ($JobAssigned -and $jobTerminated -and $processExited)
    }
}

function New-DesignMotionChildObservation {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][bool]$Materialized,
        [Parameter(Mandatory)][bool]$Attempted,
        [Parameter(Mandatory)][bool]$ChildStarted,
        [AllowNull()][Nullable[int]]$ExitCode = $null,
        [AllowNull()][string]$FailureType = $null,
        [AllowNull()][string]$FailureMessage = $null,
        [bool]$TimedOut = $false,
        [AllowNull()][string]$StdoutText = '',
        [AllowNull()][string]$StderrText = '',
        [bool]$CaptureComplete = $true,
        [bool]$StdoutOverflowed = $false,
        [bool]$StderrOverflowed = $false,
        [string[]]$EnvironmentNames = @(),
        [ValidateSet('NOT_REQUIRED', 'COMPLETED', 'COMPLETED_WITH_LIMITATION', 'INCOMPLETE')][string]$Cleanup = 'NOT_REQUIRED',
        [ValidateNotNullOrEmpty()][string]$CleanupMechanism = 'none',
        [bool]$CleanupGuaranteed = $false,
        [int]$TimeoutMilliseconds = 0,
        [AllowNull()][Nullable[int]]$ProcessId = $null
    )

    $boundedStdout = ConvertTo-FtkBoundedDiagnostic -Value $StdoutText -MaximumCharacters (Get-FtkDedicatedExecutionMaximumOutputCharacters)
    $boundedStderr = ConvertTo-FtkBoundedDiagnostic -Value $StderrText -MaximumCharacters (Get-FtkDedicatedExecutionMaximumOutputCharacters)
    $diagnostics = [ordered]@{
        stdout = @(ConvertTo-FtkDiagnosticLines -Value $StdoutText)
        stderr = @(ConvertTo-FtkDiagnosticLines -Value $StderrText)
        structuredStderr = Get-FtkStructuredStderrDiagnostic -StderrText $boundedStderr
        stdoutCharacters = $boundedStdout.Length
        stderrCharacters = $boundedStderr.Length
        stdoutBounded = $true
        stderrBounded = $true
        stdoutOverflowed = $StdoutOverflowed
        stderrOverflowed = $StderrOverflowed
        stdoutTruncated = ($StdoutOverflowed -or ([string]$StdoutText).Length -gt (Get-FtkDedicatedExecutionMaximumOutputCharacters))
        stderrTruncated = ($StderrOverflowed -or ([string]$StderrText).Length -gt (Get-FtkDedicatedExecutionMaximumOutputCharacters))
        captureComplete = $CaptureComplete
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureMessage)) { $diagnostics.failureMessage = ConvertTo-FtkBoundedDiagnostic -Value $FailureMessage -MaximumCharacters 2048 }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'dedicated-child-observation'
        capability = 'design-motion'
        operation = $Operation
        materialized = $Materialized
        attempted = $Attempted
        childStarted = $ChildStarted
        exitCode = $ExitCode
        failureType = $FailureType
        timedOut = $TimedOut
        processSucceeded = ($ChildStarted -and -not $TimedOut -and $ExitCode -eq 0 -and $null -eq $FailureType)
        stdout = @($diagnostics.stdout)
        stderr = @($diagnostics.stderr)
        diagnostics = $diagnostics
        evidence = [ordered]@{
            source = 'ftk-design-motion-child-process'
            processId = $ProcessId
            environmentNames = @($EnvironmentNames | Sort-Object -Unique)
            cleanup = $Cleanup
            cleanupMechanism = $CleanupMechanism
            cleanupGuaranteed = $CleanupGuaranteed
            captureComplete = $CaptureComplete
            timeoutMilliseconds = $TimeoutMilliseconds
            timeoutGoverned = ($TimeoutMilliseconds -gt 0)
        }
        cleanup = $Cleanup
        cleanupMechanism = $CleanupMechanism
        cleanupGuaranteed = $CleanupGuaranteed
        processId = $ProcessId
        executableClass = 'locked-node-ftk-adapter'
        commandStringConstructed = $false
        environmentNames = @($EnvironmentNames | Sort-Object -Unique)
        rawStdout = [string]$StdoutText
        rawStderr = [string]$StderrText
    }
}

function Invoke-DesignMotionChildProcess {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AdapterPath,
        [Parameter(Mandatory)][string]$RequestJson,
        [Parameter(Mandatory)][ValidateRange(1, 600000)][int]$TimeoutMilliseconds,
        [switch]$AllowPreparedRuntimeFallback
    )

    $maximumOutputCharacters = Get-FtkDedicatedExecutionMaximumOutputCharacters
    $environment = New-DesignMotionChildEnvironment
    $environmentNames = @($environment.Keys)
    $process = $null
    $jobHandle = [IntPtr]::Zero
    $stdoutCapture = $null
    $stderrCapture = $null
    $childStarted = $false
    $jobAssigned = $false
    $processId = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $captureComplete = $true
    $cleanup = 'NOT_REQUIRED'
    $cleanupMechanism = 'none'
    $cleanupGuaranteed = $false
    try {
        $node = Resolve-DesignMotionNodeRuntime -RepoRoot $RepoRoot -AllowPreparedRuntimeFallback:$AllowPreparedRuntimeFallback
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $node
        $startInfo.Arguments = ((@($AdapterPath, '--stdin') | ForEach-Object { ConvertTo-DesignMotionWindowsNativeArgument ([string]$_) }) -join ' ')
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
        Set-DesignMotionChildEnvironment -StartInfo $startInfo -Environment $environment

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        $jobHandle = [Ftk.DesignMotion.ProcessContainment]::CreateKillOnCloseJob()
        $cleanupMechanism = 'windows-job-object-kill-on-close'
        if (-not $process.Start()) { throw 'FTK design-motion child process did not start.' }
        $childStarted = $true
        $processId = [int]$process.Id
        $cleanup = 'INCOMPLETE'
        $stdoutCapture = New-Object Ftk.DesignMotion.BoundedStreamCapture($process.StandardOutput, $maximumOutputCharacters)
        $stderrCapture = New-Object Ftk.DesignMotion.BoundedStreamCapture($process.StandardError, $maximumOutputCharacters)
        try {
            [Ftk.DesignMotion.ProcessContainment]::Assign($jobHandle, $process.Handle)
            $jobAssigned = $true
        } catch {
            $assignmentFailure = $_.Exception.Message
        }

        $failure = $null
        $assignmentFailure = $null
        $inputFailure = $null
        if (-not $jobAssigned) {
            $failure = 'DEPENDENCY_OR_RUNTIME_FAILURE'
            $stopResult = Stop-DesignMotionChildProcess -Process $process -JobHandle $jobHandle -JobAssigned:$false
            $cleanupGuaranteed = $false
            $cleanup = 'COMPLETED_WITH_LIMITATION'
        } else {
            try {
                $inputBytes = [Text.Encoding]::UTF8.GetBytes($RequestJson)
                $inputTask = $process.StandardInput.BaseStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
                $remaining = [Math]::Max(1, $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
                if (-not $inputTask.Wait($remaining)) {
                    $timedOut = $true
                    $stopResult = Stop-DesignMotionChildProcess -Process $process -JobHandle $jobHandle -JobAssigned:$jobAssigned
                }
            } catch {
                $failure = 'DEPENDENCY_OR_RUNTIME_FAILURE'
                $inputFailure = $_.Exception.Message
            } finally { try { $process.StandardInput.Close() } catch { } }
            if (-not $timedOut -and $null -eq $failure) {
                while (-not $process.HasExited -and $timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) { Start-Sleep -Milliseconds 10 }
                if (-not $process.HasExited) {
                    $timedOut = $true
                    $stopResult = Stop-DesignMotionChildProcess -Process $process -JobHandle $jobHandle -JobAssigned:$jobAssigned
                } else {
                    $waitedForExit = $process.WaitForExit(5000)
                    if (-not $waitedForExit -or -not $process.HasExited) {
                        $timedOut = $true
                        $stopResult = Stop-DesignMotionChildProcess -Process $process -JobHandle $jobHandle -JobAssigned:$jobAssigned
                    }
                }
            }
        }

        $stdoutWaited = $true
        $stderrWaited = $true
        if ($null -ne $stdoutCapture) { try { $stdoutWaited = [bool]$stdoutCapture.Completion.Wait(2000) } catch { $stdoutWaited = $false } }
        if ($null -ne $stderrCapture) { try { $stderrWaited = [bool]$stderrCapture.Completion.Wait(2000) } catch { $stderrWaited = $false } }
        $captureComplete = $stdoutWaited -and $stderrWaited
        $stdout = if ($null -eq $stdoutCapture) { '' } else { $stdoutCapture.GetText() }
        $stderr = if ($null -eq $stderrCapture) { '' } else { $stderrCapture.GetText() }
        $exitCode = if ($process.HasExited) { [int]$process.ExitCode } else { $null }
        $closeSucceeded = $true
        if ($jobHandle -ne [IntPtr]::Zero) {
            try { $closeSucceeded = [bool][Ftk.DesignMotion.ProcessContainment]::Close($jobHandle) } catch { $closeSucceeded = $false }
            $jobHandle = [IntPtr]::Zero
        }
        if ($timedOut) { $cleanupGuaranteed = ($jobAssigned -and $null -ne $stopResult -and $stopResult.cleanupGuaranteed -and $closeSucceeded) }
        elseif ($null -ne $process -and $process.HasExited) { $cleanupGuaranteed = ($jobAssigned -and $closeSucceeded) }
        else { $cleanupGuaranteed = $false }
        if (-not $cleanupGuaranteed) { $cleanup = 'COMPLETED_WITH_LIMITATION' } else { $cleanup = 'COMPLETED' }
        if ($timedOut) { $failure = 'TIMEOUT' }
        elseif ($null -eq $failure -and -not $cleanupGuaranteed) { $failure = 'DEPENDENCY_OR_RUNTIME_FAILURE' }
        elseif ($null -eq $failure -and $null -ne $exitCode -and $exitCode -ne 0) { $failure = 'UPSTREAM_EXECUTION_FAILURE' }
        elseif ($null -eq $failure -and (-not $captureComplete -or ($null -ne $stdoutCapture -and $stdoutCapture.Overflowed) -or ($null -ne $stderrCapture -and $stderrCapture.Overflowed))) { $failure = 'OUTPUT_CONTRACT_FAILURE' }
        $message = if ($null -ne $assignmentFailure) { $assignmentFailure } elseif ($null -ne $inputFailure) { $inputFailure } else { $null }
        $stdoutOverflowed = if ($null -eq $stdoutCapture) { $false } else { [bool]$stdoutCapture.Overflowed }
        $stderrOverflowed = if ($null -eq $stderrCapture) { $false } else { [bool]$stderrCapture.Overflowed }
        return New-DesignMotionChildObservation -Operation $Operation -Materialized:$true -Attempted:$true -ChildStarted:$true `
            -ExitCode $exitCode -FailureType $failure -FailureMessage $message -TimedOut:$timedOut `
            -StdoutText $stdout -StderrText $stderr -CaptureComplete:$captureComplete `
            -StdoutOverflowed:$stdoutOverflowed -StderrOverflowed:$stderrOverflowed `
            -EnvironmentNames $environmentNames -Cleanup $cleanup -CleanupMechanism $cleanupMechanism `
            -CleanupGuaranteed:$cleanupGuaranteed -TimeoutMilliseconds $TimeoutMilliseconds -ProcessId $processId
    } catch {
        $catchCaptureComplete = -not $childStarted
        if ($childStarted -and $null -ne $process) {
            $stopResult = Stop-DesignMotionChildProcess -Process $process -JobHandle $jobHandle -JobAssigned:$jobAssigned
            $catchStdoutWaited = $false
            $catchStderrWaited = $false
            if ($null -ne $stdoutCapture) { try { $catchStdoutWaited = [bool]$stdoutCapture.Completion.Wait(2000) } catch { $catchStdoutWaited = $false } }
            if ($null -ne $stderrCapture) { try { $catchStderrWaited = [bool]$stderrCapture.Completion.Wait(2000) } catch { $catchStderrWaited = $false } }
            $catchCaptureComplete = $catchStdoutWaited -and $catchStderrWaited
        }
        $stdout = if ($null -eq $stdoutCapture) { '' } else { $stdoutCapture.GetText() }
        $stderr = if ($null -eq $stderrCapture) { '' } else { $stderrCapture.GetText() }
        $closeSucceeded = $true
        if ($jobHandle -ne [IntPtr]::Zero) {
            try { $closeSucceeded = [bool][Ftk.DesignMotion.ProcessContainment]::Close($jobHandle) } catch { $closeSucceeded = $false }
            $jobHandle = [IntPtr]::Zero
        }
        $cleanupGuaranteed = [bool]($childStarted -and $jobAssigned -and $null -ne $stopResult -and $stopResult.cleanupGuaranteed -and $closeSucceeded)
        $cleanup = if ($cleanupGuaranteed) { 'COMPLETED' } elseif ($childStarted) { 'COMPLETED_WITH_LIMITATION' } else { 'NOT_REQUIRED' }
        $cleanupMechanism = if ($childStarted) { 'windows-job-object-kill-on-close' } else { 'none' }
        $message = $_.Exception.Message
        return New-DesignMotionChildObservation -Operation $Operation -Materialized:$true -Attempted:$true -ChildStarted:$childStarted `
            -FailureType 'DEPENDENCY_OR_RUNTIME_FAILURE' -FailureMessage $message -StdoutText $stdout -StderrText $stderr `
            -CaptureComplete:$catchCaptureComplete `
            -EnvironmentNames $environmentNames -Cleanup $cleanup -CleanupMechanism $cleanupMechanism `
            -CleanupGuaranteed:$cleanupGuaranteed -TimeoutMilliseconds $TimeoutMilliseconds -ProcessId $processId
    } finally {
        if ($jobHandle -ne [IntPtr]::Zero) { try { [void][Ftk.DesignMotion.ProcessContainment]::Close($jobHandle) } catch { } }
        if ($null -ne $process) { $process.Dispose() }
    }
}

function New-DesignMotionNoChildDedicatedExecution {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][bool]$Materialized,
        [AllowNull()][string]$FailureType = $null,
        [Parameter(Mandatory)][string]$Reason
    )

    return New-FtkDedicatedExecutionResult -Capability 'design-motion' -Operation $Operation `
        -Materialized:$Materialized -Attempted:$false -ChildStarted:$false -Succeeded:$false `
        -ExitCode $null -FailureType $FailureType -Diagnostics ([ordered]@{ message = ConvertTo-FtkBoundedDiagnostic $Reason 2048 }) `
        -Evidence ([ordered]@{ source = 'ftk-design-motion-runner'; reason = ConvertTo-FtkBoundedDiagnostic $Reason 512 })
}

function New-DesignMotionEnvelope {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$AuthorizationDecision,
        [Parameter(Mandatory)][object]$DedicatedExecution,
        [AllowNull()][object]$FinalWorkflowResult = $null,
        [AllowNull()][string]$SourceFingerprint = $null,
        [AllowNull()][object]$SourceVerification = $null
    )

    $envelope = [ordered]@{
        schemaVersion = 1
        capability = 'design-motion'
        operation = $Operation
        policy = [ordered]@{
            status = 'POLICY_REJECTION'
            authorizationDecision = $AuthorizationDecision
            source = 'ftk-design-motion-lane-local-preintegration'
        }
        integration = [ordered]@{
            operationSurface = 'REQUEST_ONLY'
            commonDispatcher = 'not-wired-in-this-lane'
            sharedChangeRequestRequired = $true
        }
        dedicatedExecution = $DedicatedExecution
        materialized = [bool](Get-DesignMotionProperty $DedicatedExecution 'materialized')
        attempted = [bool](Get-DesignMotionProperty $DedicatedExecution 'attempted')
        childStarted = [bool](Get-DesignMotionProperty $DedicatedExecution 'childStarted')
        succeeded = [bool](Get-DesignMotionProperty $DedicatedExecution 'succeeded')
        exitCode = Get-DesignMotionProperty $DedicatedExecution 'exitCode'
        failureType = Get-DesignMotionProperty $DedicatedExecution 'failureType'
        timedOut = [bool](Get-DesignMotionProperty $DedicatedExecution 'timedOut')
        diagnostics = Get-DesignMotionProperty $DedicatedExecution 'diagnostics'
        evidence = Get-DesignMotionProperty $DedicatedExecution 'evidence'
        fallback = $null
        finalWorkflowResult = $FinalWorkflowResult
    }
    if ($null -ne $SourceFingerprint) { $envelope.sourceFingerprint = $SourceFingerprint }
    if ($null -ne $SourceVerification) {
        $summary = [ordered]@{
            verified = [bool](Get-DesignMotionProperty $SourceVerification 'verified')
            materialized = [bool](Get-DesignMotionProperty $SourceVerification 'materialized')
            dependencyId = [string](Get-DesignMotionProperty $SourceVerification 'dependencyId')
            representation = Get-DesignMotionProperty $SourceVerification 'representation'
            sourceFingerprint = Get-DesignMotionProperty $SourceVerification 'sourceFingerprint'
        }
        $envelope.sourceVerification = $summary
    }
    return [pscustomobject]$envelope
}

function New-DesignMotionInvalidInputEnvelope {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Reason
    )

    $dedicated = New-DesignMotionNoChildDedicatedExecution -Operation $Operation -Materialized:$false `
        -FailureType 'INVALID_INPUT' -Reason $Reason
    return New-DesignMotionEnvelope -Operation $Operation -AuthorizationDecision 'invalid-input-rejected-before-child' `
        -DedicatedExecution $dedicated -FinalWorkflowResult ([ordered]@{ operation = $Operation; status = 'FAILED'; failureType = 'INVALID_INPUT' })
}

function Invoke-DesignMotionOperation {
    param(
        [Parameter(Mandatory)][object]$Request,
        [string]$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')),
        [string]$LockPath = '',
        [AllowNull()][string]$SourceRoot,
        [ValidateRange(1, 600000)][int]$TimeoutMilliseconds = (Get-FtkDedicatedExecutionDefaultTimeoutMilliseconds),
        [switch]$TestHarness,
        [switch]$HermeticTestMode,
        [ValidateSet('malformed', 'stdout-overflow', 'stderr-overflow', 'timeout', 'fail')][string]$TestBehavior = 'malformed'
    )

    $parsed = $Request
    if ($Request -is [string]) {
        try { $parsed = $Request | ConvertFrom-Json -ErrorAction Stop }
        catch { return New-DesignMotionInvalidInputEnvelope -Operation 'design-motion.request' -Reason 'Request JSON is malformed.' }
    }
    $operation = [string](Get-DesignMotionProperty $parsed 'operation')
    if ([string]::IsNullOrWhiteSpace($operation)) { $operation = 'design-motion.request' }
    try { [void](Assert-DesignMotionRequest $parsed) }
    catch {
        return New-DesignMotionInvalidInputEnvelope -Operation $operation -Reason $_.Exception.Message
    }
    if ($operation -eq 'animate') {
        $dedicated = New-DesignMotionNoChildDedicatedExecution -Operation $operation -Materialized:$false `
            -Reason 'animate is REGISTERED_NO_HANDLER and PHASE_2_BLOCKED in the Phase 1 read-only lane.'
        $final = [ordered]@{
            operation = 'animate'
            status = 'REGISTERED_NO_HANDLER'
            authorization = 'PHASE_2_BLOCKED'
            limitations = @('No animate handler exists in Phase 1; no authorization is inferred.')
        }
        return New-DesignMotionEnvelope -Operation $operation -AuthorizationDecision 'phase-2-blocked-registered-no-handler' `
            -DedicatedExecution $dedicated -FinalWorkflowResult $final
    }

    $verification = Invoke-DesignMotionSourceVerification -Operation $operation -RepoRoot $RepoRoot -LockPath $LockPath -SourceRoot $SourceRoot -AllowSyntheticLock:$HermeticTestMode
    if (-not [bool](Get-DesignMotionProperty $verification 'verified')) {
        $materialized = [bool](Get-DesignMotionProperty $verification 'materialized')
        $reason = [string](Get-DesignMotionProperty $verification 'reason')
        $dedicated = New-DesignMotionNoChildDedicatedExecution -Operation $operation -Materialized:$materialized `
            -FailureType 'DEPENDENCY_OR_RUNTIME_FAILURE' -Reason $reason
        $final = [ordered]@{
            operation = $operation
            status = 'BLOCKED'
            sourceStatus = if ($materialized) { 'MATERIALIZED_BUT_UNVERIFIED' } else { 'NOT_MATERIALIZED' }
            sourceFingerprint = $null
            limitations = @('Dedicated Phase 1 execution requires the exact governed source to be materialized and verified.')
        }
        return New-DesignMotionEnvelope -Operation $operation -AuthorizationDecision 'source-verification-failed-closed' `
            -DedicatedExecution $dedicated -FinalWorkflowResult $final -SourceVerification $verification
    }

    $childRequest = [ordered]@{
        schemaVersion = 1
        operation = $operation
        context = $parsed.context
        input = $parsed.input
        sourceVerification = [ordered]@{
            verified = $true
            dependencyId = [string](Get-DesignMotionProperty $verification 'dependencyId')
            sourceFingerprint = [string](Get-DesignMotionProperty $verification 'sourceFingerprint')
            representation = 'canonical-lf-and-crlf-normalized'
        }
    }
    if ($TestHarness) { $childRequest.testHarness = [ordered]@{ behavior = $TestBehavior } }
    try {
        $requestJson = $childRequest | ConvertTo-Json -Compress -Depth 50
        if ($requestJson.Length -gt 131072) { throw 'The typed child request exceeds the bounded input contract.' }
    } catch {
        $dedicated = New-DesignMotionNoChildDedicatedExecution -Operation $operation -Materialized:$true `
            -FailureType 'INVALID_INPUT' -Reason $_.Exception.Message
        return New-DesignMotionEnvelope -Operation $operation -AuthorizationDecision 'invalid-input-rejected-before-child' `
            -DedicatedExecution $dedicated -FinalWorkflowResult ([ordered]@{ operation = $operation; status = 'FAILED'; failureType = 'INVALID_INPUT' }) -SourceVerification $verification
    }

    $adapterPath = Join-Path $PSScriptRoot 'design-motion-adapter.mjs'
    $child = Invoke-DesignMotionChildProcess -Operation $operation -RepoRoot ([IO.Path]::GetFullPath($RepoRoot)) -AdapterPath $adapterPath `
        -RequestJson $requestJson -TimeoutMilliseconds $TimeoutMilliseconds -AllowPreparedRuntimeFallback:$HermeticTestMode
    $output = $null
    $outputValid = $false
    $outputDiagnostic = ''
    $childDiagnostics = Get-DesignMotionProperty $child 'diagnostics'
    $childFailureType = Get-DesignMotionProperty $child 'failureType'
    if ([bool](Get-DesignMotionProperty $child 'childStarted') -and
        [int](Get-DesignMotionProperty $child 'exitCode') -eq 0 -and
        -not [bool](Get-DesignMotionProperty $child 'timedOut') -and
        [string]::IsNullOrWhiteSpace([string]$childFailureType) -and
        [bool](Get-DesignMotionProperty $childDiagnostics 'captureComplete') -and
        -not [bool](Get-DesignMotionProperty $childDiagnostics 'stdoutOverflowed') -and
        -not [bool](Get-DesignMotionProperty $childDiagnostics 'stderrOverflowed')) {
        try {
            $rawStdout = [string](Get-DesignMotionProperty $child 'rawStdout')
            if ([string]::IsNullOrWhiteSpace($rawStdout)) { throw 'The FTK adapter returned empty stdout.' }
            $output = $rawStdout.Trim() | ConvertFrom-Json -ErrorAction Stop
            [void](Assert-DesignMotionOutputContract -Output $output -Operation $operation `
                -SourceFingerprint ([string](Get-DesignMotionProperty $verification 'sourceFingerprint')) `
                -ExpectedRoutingMode ([string](Get-DesignMotionProperty $parsed.context 'routingMode')) `
                -ExpectedReferenceAuthority ([string](Get-DesignMotionProperty $parsed.context 'referenceAuthority')) `
                -ExpectedApprovedReference (Get-DesignMotionProperty $parsed.context 'approvedReference') `
                -ExpectedAllowedDelta (Get-DesignMotionProperty $parsed.context 'allowedDelta'))
            $outputValid = $true
        } catch {
            $outputDiagnostic = $_.Exception.Message
        }
    } else {
        $outputDiagnostic = 'The FTK design-motion child did not complete with exit code 0.'
    }
    $dedicated = Complete-FtkDedicatedExecution -Capability 'design-motion' -Operation $operation `
        -ChildObservation $child -OutputContractValid:$outputValid -OutputContractDiagnostic $outputDiagnostic
    $fingerprint = [string](Get-DesignMotionProperty $verification 'sourceFingerprint')
    if ($null -eq $dedicated.evidence) { $dedicated.evidence = [ordered]@{} }
    $dedicated.evidence.sourceFingerprint = $fingerprint
    $dedicated.evidence.sourceVerification = [ordered]@{ dependencyId = [string](Get-DesignMotionProperty $verification 'dependencyId'); representation = 'canonical-lf-and-crlf-normalized' }
    $final = if ($outputValid -and [bool](Get-DesignMotionProperty $dedicated 'succeeded')) { $output } else {
        [ordered]@{
            operation = $operation
            status = 'FAILED'
            failureType = [string](Get-DesignMotionProperty $dedicated 'failureType')
            sourceFingerprint = $fingerprint
            limitations = @('No successful workflow result is exposed when the child or output contract fails.')
        }
    }
    return New-DesignMotionEnvelope -Operation $operation -AuthorizationDecision 'phase-1-read-only-adapter' `
        -DedicatedExecution $dedicated -FinalWorkflowResult $final -SourceFingerprint $fingerprint -SourceVerification $verification
}
