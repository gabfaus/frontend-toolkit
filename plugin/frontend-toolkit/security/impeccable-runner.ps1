Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$executionContractPath = Join-Path $PSScriptRoot 'execution-contract.ps1'
if (-not (Test-Path -LiteralPath $executionContractPath -PathType Leaf)) { throw 'FTK execution contract is missing.' }
. $executionContractPath

if ($null -eq ('Ftk.Impeccable.BoundedStreamCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Ftk.Impeccable {
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

function Get-ImpeccableOperationPolicy {
    $path = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Impeccable operation policy is missing.' }
    $policy = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ($policy.architecture -cne 'ftk-owned-external-effects-mediation' -or
        $policy.unknownOperationPolicy -cne 'deny' -or $policy.unknownEffectPolicy -cne 'deny') {
        throw 'Impeccable operation policy is not fail closed.'
    }
    return $policy
}

function Get-ImpeccableRegisteredOperation {
    param([Parameter(Mandatory)][string]$Operation)
    $policy = Get-ImpeccableOperationPolicy
    $definitions = @($policy.operations | Where-Object id -CEQ $Operation)
    if ($definitions.Count -ne 1) { throw "UNKNOWN Impeccable operation is denied: $Operation" }
    $knownEffects = @('LOCAL_READ_ONLY','LOCAL_PROJECT_WRITE','LOOPBACK_EPHEMERAL','NETWORK_PASSIVE','TELEMETRY','PAID_GENERATION','EXTERNAL_MUTATION','PROJECT_CODE_EXECUTION')
    foreach ($effect in @($definitions[0].effects)) {
        if ($effect -notin $knownEffects -or $effect -ceq 'UNKNOWN') { throw "UNKNOWN effect is denied for operation: $Operation" }
    }
    return $definitions[0]
}

function Assert-ImpeccableIntegratedPolicyIdentity {
    $authorityPath = Join-Path $PSScriptRoot 'impeccable-authority-policy.json'
    $operationPath = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
    $artifactLockPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'external-skills.lock.json'
    foreach ($path in @($authorityPath, $operationPath, $artifactLockPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Impeccable integrated identity contract is incomplete.' }
    }
    $authority = Get-Content -Raw -LiteralPath $authorityPath | ConvertFrom-Json
    $operation = Get-Content -Raw -LiteralPath $operationPath | ConvertFrom-Json
    $artifact = Get-Content -Raw -LiteralPath $artifactLockPath | ConvertFrom-Json
    $locked = @($artifact.dependencies | Where-Object id -CEQ 'impeccable')
    if ($locked.Count -ne 1 -or
        $authority.upstream.commitSha -cne $operation.upstreamCommit -or
        $authority.upstream.commitSha -cne $locked[0].commitSha -or
        $authority.upstream.snapshotTreeSha256 -cne $locked[0].snapshotTreeSha256) {
        throw 'Impeccable authority, effect, or packaged source identity drifted.'
    }
    if ($authority.upstream.commitSha -cnotmatch '^[0-9a-f]{40}$' -or
        $authority.upstream.snapshotTreeSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $authority.upstream.skillEntrySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        @($authority.upstream.contractFiles).Count -ne 4 -or
        @($authority.upstream.contractFiles | Where-Object { $_.sha256 -cnotmatch '^[0-9a-f]{64}$' }).Count) {
        throw 'Impeccable authority fingerprint is malformed or incomplete.'
    }
    # FTK-owned context/identity mediation is committed and does not execute
    # the optional development checkout. Upstream execution resolves the
    # required checkout separately through Resolve-ImpeccablePinnedScript.
    $upstreamRoot = Resolve-ImpeccablePinnedUpstreamRoot -AllowUnavailable
    if ($null -ne $upstreamRoot -and (Test-Path -LiteralPath (Join-Path $upstreamRoot '.git'))) {
        $safeRoot = $upstreamRoot.Replace('\', '/')
        $head = (& git -c "safe.directory=$safeRoot" -C $upstreamRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $head -cne $authority.upstream.commitSha) {
            throw 'Impeccable upstream HEAD does not match the authority fingerprint.'
        }
        if (& git -c "safe.directory=$safeRoot" -C $upstreamRoot status --porcelain) {
            throw 'Impeccable upstream checkout is dirty and cannot establish source identity.'
        }
    }
}

function Assert-ImpeccableAllowedParameters {
    param([Parameter(Mandatory)][Collections.IDictionary]$BoundParameters, [Parameter(Mandatory)][string[]]$Allowed)
    $common = @([Management.Automation.Cmdlet]::CommonParameters) + @([Management.Automation.Cmdlet]::OptionalCommonParameters)
    $unexpected = @($BoundParameters.Keys | Where-Object { $_ -notin $Allowed -and $_ -notin $common })
    if ($unexpected.Count) { throw ('Operation received unregistered inputs: ' + ($unexpected -join ', ')) }
}

function Get-ImpeccableParameterValidationResult {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$BoundParameters,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Operation
    )

    try { Assert-ImpeccableAllowedParameters $BoundParameters $Allowed; return $null }
    catch { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason $_.Exception.Message }
}

function Resolve-ImpeccableCanonicalProjectRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { throw 'ProjectRoot must be an existing directory.' }
    $resolved = (Resolve-Path -LiteralPath $ProjectRoot).Path
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'ProjectRoot cannot be a reparse point.'
    }
    return [IO.Path]::GetFullPath($resolved)
}

function Test-ImpeccablePathWithinRoot {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Candidate)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidatePath = [IO.Path]::GetFullPath($Candidate)
    return $candidatePath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $candidatePath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ImpeccableNoExistingReparsePoint {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Candidate)
    $rootPath = [IO.Path]::GetFullPath($Root)
    $candidatePath = [IO.Path]::GetFullPath($Candidate)
    if (-not (Test-ImpeccablePathWithinRoot $rootPath $candidatePath)) { throw 'Path escapes its authorized root.' }
    $relative = $candidatePath.Substring($rootPath.Length).TrimStart([char[]]@([char]92, [char]47))
    $cursor = $rootPath
    foreach ($segment in @($relative -split '[\\/]')) {
        if (-not $segment -or $segment -eq '.') { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Path crosses a reparse point.'
            }
        } else { break }
    }
}

function Resolve-ImpeccableGeneratedOutput {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$OutputPath)
    if ([IO.Path]::IsPathRooted($OutputPath) -or $OutputPath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'OutputPath must be a relative contained filename.'
    }
    if ($OutputPath -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:png|svg)$') {
        throw 'OutputPath must be a simple .png or .svg filename.'
    }
    $root = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.impeccable/ftk-generated'))
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $OutputPath))
    if (-not (Test-ImpeccablePathWithinRoot $root $candidate)) { throw 'OutputPath escapes the generated-output boundary.' }
    Assert-ImpeccableNoExistingReparsePoint -Root $ProjectRoot -Candidate $root
    Assert-ImpeccableNoExistingReparsePoint -Root $ProjectRoot -Candidate $candidate
    return [pscustomobject][ordered]@{ Root = $root; Path = $candidate }
}

function Resolve-ImpeccableNodeRuntime {
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $lockPath = Join-Path $PSScriptRoot '../integrations/toolchain.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { $lockPath = Join-Path $repoRoot 'integrations/toolchain.lock.json' }
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $node = @($lock.runtimes | Where-Object id -CEQ 'node')
    if ($node.Count -ne 1 -or $node[0].targetVersion -cne '24.20.0') { throw 'The fixed Impeccable Node runtime lock is unavailable or changed.' }
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $runtime = Join-Path $localAppData 'Programs/FrontendToolkit/node-v24.20.0-win-x64/node.exe'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw 'The locked Node 24.20.0 runtime is unavailable.' }
    return [IO.Path]::GetFullPath($runtime)
}

function Resolve-ImpeccableStaticHtmlModuleRoot {
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $candidates = @(
        (Join-Path $PSScriptRoot '../third_party/static-html-dependencies/node_modules'),
        (Join-Path $repoRoot 'third_party/runtimes/impeccable-static-html/node_modules')
    )
    $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($existing.Count -ne 1) { throw 'Canonical static-HTML module root is missing or ambiguous.' }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $existing[0]).Path)
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Canonical static-HTML module root cannot be a reparse point.'
    }
    return $resolved
}
function Resolve-ImpeccablePinnedUpstreamRoot {
    param([switch]$AllowUnavailable)
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $snapshot = Join-Path (Split-Path $PSScriptRoot -Parent) 'third_party/upstreams/impeccable'
    if (Test-Path -LiteralPath $snapshot -PathType Container) { return (Resolve-Path -LiteralPath $snapshot).Path }

    # DevelopmentWorkingTree fallback: diagnostic/test input only, never release evidence.
    $checkout = Join-Path $repoRoot 'external/impeccable'
    if (-not (Test-Path -LiteralPath $checkout -PathType Container)) {
        if ($AllowUnavailable) { return $null }
        throw 'Pinned Impeccable upstream is unavailable.'
    }
    $lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
    $entry = @($lock.dependencies | Where-Object id -CEQ 'impeccable')
    if ($entry.Count -ne 1 -or $entry[0].commitSha -cne '63b04e2530f5c7b41ea83c133daab24f34912456') {
        throw 'Pinned Impeccable upstream lock does not match the reviewed commit.'
    }
    return (Resolve-Path -LiteralPath $checkout).Path
}

function Resolve-ImpeccablePinnedScript {
    param([Parameter(Mandatory)][string]$RelativePath)
    $root = Resolve-ImpeccablePinnedUpstreamRoot
    $skillRoot = Join-Path $root '.agent/skills/impeccable'
    if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
        $skillRoot = Join-Path $root 'plugin/skills/impeccable'
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $skillRoot $RelativePath))
    if (-not (Test-ImpeccablePathWithinRoot $skillRoot $candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'Registered upstream Impeccable script is unavailable or escaped its root.'
    }
    Assert-ImpeccableNoExistingReparsePoint -Root $skillRoot -Candidate $candidate
    return $candidate
}

function New-ImpeccableChildEnvironment {
    param([Collections.IDictionary]$Additional = ([ordered]@{}))
    $environment = [ordered]@{}
    foreach ($name in @('SystemRoot','TEMP','TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
    }
    $environment['IMPECCABLE_NO_UPDATE_CHECK'] = '1'
    $environment['IMPECCABLE_NO_TELEMETRY'] = '1'
    $environment['DO_NOT_TRACK'] = '1'
    foreach ($name in $Additional.Keys) {
        if ($name -notin @('IMPECCABLE_IMAGE_GEN_FAKE')) { throw "Child environment name is not registered: $name" }
        $environment[$name] = [string]$Additional[$name]
    }
    return $environment
}

function ConvertTo-ImpeccableWindowsNativeArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)
    if ($Value -match '[\x00\r\n]') { throw 'Native argv values may not contain NUL or line breaks.' }
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

function Assert-ImpeccableChildEnvironment {
    param([Parameter(Mandatory)][Collections.IDictionary]$Environment)

    $allowed = @(
        'SystemRoot'
        'TEMP'
        'TMP'
        'IMPECCABLE_NO_UPDATE_CHECK'
        'IMPECCABLE_NO_TELEMETRY'
        'DO_NOT_TRACK'
        'IMPECCABLE_IMAGE_GEN_FAKE'
    )
    foreach ($name in @($Environment.Keys)) {
        if ([string]$name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or [string]$name -notin $allowed) {
            throw "Child environment name is not registered: $name"
        }
    }
}

function Get-ImpeccableSensitiveEnvironmentValues {
    param([Parameter(Mandatory)][Collections.IDictionary]$Environment)

    $sensitiveEnvironmentNamePattern = '(?i)(?:^|[_-])(?:access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|proxy[_-]?authorization|authorization|www[_-]?authenticate|x[_-]?(?:api[_-]?key|auth[_-]?token)|id[_-]?token|private[_-]?key|password|cookie|credential|secret|token|key)(?:[_-][A-Za-z0-9]+)*$'
    foreach ($name in @($Environment.Keys)) {
        if ([string]$name -match $sensitiveEnvironmentNamePattern -and
            -not [string]::IsNullOrEmpty([string]$Environment[$name])) {
            [string]$Environment[$name]
        }
    }
}

function Stop-ImpeccableChildProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [IntPtr]$JobHandle = [IntPtr]::Zero
    )

    $jobTerminated = $false
    if ($JobHandle -ne [IntPtr]::Zero) {
        try { $jobTerminated = [Ftk.Impeccable.ProcessContainment]::Terminate($JobHandle, 1) } catch { }
    }
    if (-not $jobTerminated) {
        try {
            if ($Process.HasExited) { return $true }
        } catch { return $false }
    }
    try {
        if (-not $jobTerminated -and -not $Process.HasExited) { [void]$Process.Kill() }
    } catch {
        if (-not $jobTerminated) { return $false }
    }
    try { return [bool]$Process.WaitForExit(5000) } catch { return $false }
}

function Get-ImpeccableCompletedTaskCapture {
    param(
        [AllowNull()][object]$Task,
        [ValidateRange(0, 10000)][int]$WaitMilliseconds = 5000
    )

    if ($null -eq $Task) { return [pscustomobject]@{ text = ''; complete = $true } }
    $complete = $false
    try {
        $complete = [bool]$Task.IsCompleted
        if (-not $complete) { $complete = [bool]$Task.Wait($WaitMilliseconds) }
        if ($complete -and $Task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
            return [pscustomobject]@{ text = [string]$Task.GetAwaiter().GetResult(); complete = $true }
        }
    } catch {
        return [pscustomobject]@{ text = ''; complete = $false }
    }
    return [pscustomobject]@{ text = ''; complete = $false }
}

function Get-ImpeccableProcessExitCode {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)

    try {
        if ($Process.HasExited) { return [Nullable[int]]$Process.ExitCode }
    } catch { }
    return $null
}

function Set-ImpeccableChildEnvironment {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment
    )

    try {
        $variables = $StartInfo.EnvironmentVariables
        $variables.Clear()
    } catch {
        # Windows PowerShell/.NET Framework can fail while lazily importing a
        # malformed parent environment with case-colliding search variables. Replace
        # only ProcessStartInfo's private dictionary; the parent is untouched.
        $field = $StartInfo.GetType().GetField('environmentVariables', [Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -eq $field) { throw 'Unable to create the isolated child environment.' }
        $variables = New-Object Collections.Specialized.StringDictionary
        $field.SetValue($StartInfo, $variables)
        $variables.Clear()
    }
    foreach ($name in $Environment.Keys) { $variables.Add([string]$name, [string]$Environment[$name]) }
}

function Invoke-ImpeccableChildProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Executable,
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WorkingDirectory,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment,
        [AllowEmptyString()][string]$StandardInputText,
        [ValidateNotNullOrEmpty()][string]$Operation = 'impeccable.dedicated',
        [ValidateRange(0, 600000)][int]$TimeoutMilliseconds = 120000,
        [switch]$ReturnResult
    )

    $maximumOutputCharacters = Get-FtkDedicatedExecutionMaximumOutputCharacters
    $materialized = $false
    $attempted = $false
    $childStarted = $false
    $timedOut = $false
    $failureType = $null
    $failureMessage = $null
    $exitCode = $null
    $stdoutText = ''
    $stderrText = ''
    $captureComplete = $true
    $stdoutOverflowed = $false
    $stderrOverflowed = $false
    $cleanup = 'NOT_REQUIRED'
    $cleanupMechanism = 'none'
    [Nullable[int]]$processId = $null
    [IntPtr]$jobHandle = [IntPtr]::Zero
    $jobAssigned = $false
    $process = [Diagnostics.Process]::new()
    $stdoutCapture = $null
    $stderrCapture = $null
    $inputTask = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    try {
        if ([string]::IsNullOrWhiteSpace($Executable) -or [string]::IsNullOrWhiteSpace($WorkingDirectory) -or
            -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            throw 'Dedicated child process requires a valid executable and working directory.'
        }
        Assert-ImpeccableChildEnvironment -Environment $Environment
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $Executable
        $start.WorkingDirectory = $WorkingDirectory
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.RedirectStandardInput = $PSBoundParameters.ContainsKey('StandardInputText')
        $utf8 = New-Object Text.UTF8Encoding($false)
        $start.StandardOutputEncoding = $utf8
        $start.StandardErrorEncoding = $utf8
        $start.CreateNoWindow = $true
        $start.Arguments = (@($ArgumentList | ForEach-Object {
            ConvertTo-ImpeccableWindowsNativeArgument -Value ([string]$_)
        }) -join ' ')
        Set-ImpeccableChildEnvironment -StartInfo $start -Environment $Environment
        $jobHandle = [Ftk.Impeccable.ProcessContainment]::CreateKillOnCloseJob()
        $cleanupMechanism = 'windows-job-object'
        $process.StartInfo = $start
        $materialized = $true
        $attempted = $true
        try {
            $childStarted = [bool]$process.Start()
            if ($childStarted) { $processId = $process.Id }
        } catch {
            $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
            $failureMessage = $_.Exception.Message
        }
        if (-not $childStarted -and $null -eq $failureType) {
            $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
            $failureMessage = 'Fixed Impeccable child did not start.'
        }
        if ($childStarted) {
            $cleanup = 'INCOMPLETE'
            $captureComplete = $false
            $stdoutCapture = New-Object Ftk.Impeccable.BoundedStreamCapture($process.StandardOutput, $maximumOutputCharacters)
            $stderrCapture = New-Object Ftk.Impeccable.BoundedStreamCapture($process.StandardError, $maximumOutputCharacters)
            try {
                [Ftk.Impeccable.ProcessContainment]::Assign($jobHandle, $process.Handle)
                $jobAssigned = $true
            } catch {
                $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
                $failureMessage = 'The fixed child could not be assigned to the FTK Windows Job Object.'
            }
            if (-not $jobAssigned) { [void](Stop-ImpeccableChildProcess -Process $process -JobHandle $jobHandle) }
            if ($start.RedirectStandardInput) {
                try {
                    $inputBytes = [Text.Encoding]::UTF8.GetBytes($StandardInputText)
                    if ($inputBytes.Length -gt 0) {
                        $inputTask = $process.StandardInput.BaseStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
                        $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
                        if (-not $inputTask.Wait($remaining)) {
                            $timedOut = $true
                            $failureType = 'TIMEOUT'
                            $failureMessage = 'Dedicated child input exceeded the governed timeout.'
                        } else {
                            [void]$inputTask.GetAwaiter().GetResult()
                        }
                    }
                } catch {
                    if (-not $timedOut) {
                        $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
                        $failureMessage = $_.Exception.Message
                    }
                } finally {
                    try { $process.StandardInput.BaseStream.Close() } catch { }
                }
            }
            while (-not $process.HasExited -and -not $timedOut -and $null -eq $failureType) {
                if ($stdoutCapture.Overflowed -or $stderrCapture.Overflowed) {
                    $failureType = 'OUTPUT_CONTRACT_FAILURE'
                    $failureMessage = 'Dedicated child output exceeded the bounded contract limit.'
                    [void](Stop-ImpeccableChildProcess -Process $process -JobHandle $jobHandle)
                    break
                }
                $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
                if ($remaining -le 0) {
                    $timedOut = $true
                    $failureType = 'TIMEOUT'
                    $failureMessage = 'Dedicated child exceeded the governed timeout.'
                    [void](Stop-ImpeccableChildProcess -Process $process -JobHandle $jobHandle)
                } else { [void]$process.WaitForExit([Math]::Min(50, $remaining)) }
            }
            if ($stdoutCapture.Overflowed -or $stderrCapture.Overflowed) {
                if ($null -eq $failureType) {
                    $failureType = 'OUTPUT_CONTRACT_FAILURE'
                    $failureMessage = 'Dedicated child output exceeded the bounded contract limit.'
                }
                [void](Stop-ImpeccableChildProcess -Process $process -JobHandle $jobHandle)
            }
            if ($timedOut -or ($failureType -and -not $process.HasExited)) {
                [void](Stop-ImpeccableChildProcess -Process $process -JobHandle $jobHandle)
            }
            $stdoutCompleted = $false
            $stderrCompleted = $false
            try { $stdoutCompleted = [bool]$stdoutCapture.Completion.Wait(5000) } catch { }
            try { $stderrCompleted = [bool]$stderrCapture.Completion.Wait(5000) } catch { }
            if (-not ($stdoutCompleted -and $stderrCompleted)) {
                if ($null -eq $failureType) {
                    $failureType = 'OUTPUT_CONTRACT_FAILURE'
                    $failureMessage = 'Dedicated child output streams could not be drained completely.'
                }
                [void](Stop-ImpeccableChildProcess -Process $process -JobHandle $jobHandle)
                try { $stdoutCompleted = [bool]$stdoutCapture.Completion.Wait(1000) } catch { }
                try { $stderrCompleted = [bool]$stderrCapture.Completion.Wait(1000) } catch { }
            }
            $exitCode = Get-ImpeccableProcessExitCode -Process $process
            $stdoutOverflowed = [bool]$stdoutCapture.Overflowed
            $stderrOverflowed = [bool]$stderrCapture.Overflowed
            $stdoutText = $stdoutCapture.GetText()
            $stderrText = $stderrCapture.GetText()
            $captureComplete = $stdoutCompleted -and $stderrCompleted
            if (-not $captureComplete -and $null -eq $failureType) {
                $failureType = 'OUTPUT_CONTRACT_FAILURE'
                $failureMessage = 'Dedicated child output streams could not be drained completely.'
            }
            if ($null -eq $failureType -and $null -ne $exitCode -and $exitCode -ne 0) {
                $failureType = 'UPSTREAM_EXECUTION_FAILURE'
                $failureMessage = "Fixed Impeccable child failed with exit code $exitCode."
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
                if (-not $process.HasExited) { [void](Stop-ImpeccableChildProcess -Process $process -JobHandle $jobHandle) }
                if ($jobHandle -ne [IntPtr]::Zero) {
                    $closed = [Ftk.Impeccable.ProcessContainment]::Close($jobHandle)
                    $jobHandle = [IntPtr]::Zero
                    # Process.Start precedes assignment, so the Job Object can
                    # only make a truthful claim about the parent and any
                    # descendants created after assignment.
                    $cleanup = if ($jobAssigned -and $closed) { 'COMPLETED_WITH_LIMITATION' } else { 'INCOMPLETE' }
                } else { $cleanup = 'INCOMPLETE' }
            } catch { $cleanup = 'INCOMPLETE' }
        } elseif ($jobHandle -ne [IntPtr]::Zero) {
            try { [void][Ftk.Impeccable.ProcessContainment]::Close($jobHandle) } catch { }
        }
        try { if ($null -ne $inputTask -and -not $inputTask.IsCompleted) { [void]$inputTask.Wait(1000) } } catch { }
        try { $process.Dispose() } catch { }
        $stopwatch.Stop()
    }

    if ($childStarted -and $cleanup -notin @('COMPLETED','COMPLETED_WITH_LIMITATION') -and $null -eq $failureType) {
        $failureType = 'DEPENDENCY_OR_RUNTIME_FAILURE'
        $failureMessage = 'FTK could not prove complete Windows process-tree cleanup.'
    }

    $observation = New-FtkChildProcessObservation -Capability 'impeccable' -Operation $Operation `
        -Materialized:$materialized -Attempted:$attempted -ChildStarted:$childStarted -ExitCode $exitCode `
        -FailureType $failureType -FailureMessage $failureMessage -TimedOut:$timedOut `
        -StdoutText $stdoutText -ContractStdoutText $stdoutText -IncludeContractOutput:$ReturnResult `
        -StderrText $stderrText -CaptureComplete:$captureComplete `
        -StdoutOverflowed:$stdoutOverflowed -StderrOverflowed:$stderrOverflowed `
        -EnvironmentNames @($Environment.Keys) -RedactValues @(Get-ImpeccableSensitiveEnvironmentValues -Environment $Environment) `
        -Cleanup $cleanup -CleanupMechanism $cleanupMechanism -CleanupGuaranteed:$false `
        -TimeoutMilliseconds $TimeoutMilliseconds -ProcessId $processId
    if ($ReturnResult) { return $observation }
    if ($failureType) {
        $structured = Get-FtkPropertyValue (Get-FtkPropertyValue $observation 'diagnostics') 'structuredStderr'
        if ($failureType -eq 'UPSTREAM_EXECUTION_FAILURE' -and $structured -and $structured.error) {
            throw "Fixed Impeccable child failed: $($structured.error)"
        }
        if ($failureType -eq 'TIMEOUT') { throw 'Fixed Impeccable child timed out.' }
        if ($failureMessage) { throw (ConvertTo-FtkBoundedDiagnostic -Value $failureMessage -MaximumCharacters 2048) }
        throw "Fixed Impeccable child failed with failure type $failureType."
    }
    return $observation
}

function Resolve-ImpeccablePinnedSkillRoot {
    $script = Resolve-ImpeccablePinnedScript -RelativePath 'scripts/detect.mjs'
    return [IO.Path]::GetFullPath((Split-Path (Split-Path $script -Parent) -Parent))
}

function New-ImpeccableDedicatedFailureEnvelope {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][object]$DedicatedExecution
    )

    return New-FtkCapabilityExecutionEnvelope -Capability 'impeccable' -Operation $Operation `
        -PolicyStatus ALLOWED -AuthorizationDecision 'common-dispatcher-allowed' `
        -DedicatedExecution $DedicatedExecution
}

function Remove-ImpeccableContractOutput {
    param([Parameter(Mandatory)][object]$ChildObservation)

    if ($ChildObservation.PSObject.Properties.Name -contains 'contractStdout') {
        $ChildObservation.PSObject.Properties.Remove('contractStdout')
    }
    return $ChildObservation
}

function Assert-ImpeccableContextOutputContract {
    param([Parameter(Mandatory)][object]$ContextOutput)

    if ($ContextOutput -is [array] -or $null -eq $ContextOutput) { throw 'Context output must be a JSON object.' }
    $required = @('schemaVersion','sourceFingerprint','data','advisory','requestedOperations','events')
    $properties = @($ContextOutput.PSObject.Properties.Name)
    $missing = @($required | Where-Object { $_ -notin $properties })
    $unknown = @($properties | Where-Object { $_ -notin $required })
    if ($missing.Count -or $unknown.Count) { throw 'Context output does not match the exact FTK output envelope shape.' }
    if ($ContextOutput.schemaVersion -ne 1) { throw 'Context output schemaVersion is not supported.' }
    foreach ($name in @('data','advisory','requestedOperations','events')) {
        if ($ContextOutput.$name -isnot [array]) { throw "Context output $name must be an array." }
    }
    if (@($ContextOutput.events).Count -ne 0) { throw 'Context output must not contain live events.' }

    $fingerprint = $ContextOutput.sourceFingerprint
    if ($fingerprint -is [array] -or $null -eq $fingerprint) { throw 'Context output sourceFingerprint must be an object.' }
    $fingerprintFields = @('upstreamId','ref','commitSha','snapshotTreeSha256','skillEntrySha256','contractFiles')
    $fingerprintProperties = @($fingerprint.PSObject.Properties.Name)
    if (@($fingerprintFields | Where-Object { $_ -notin $fingerprintProperties }).Count -or
        @($fingerprintProperties | Where-Object { $_ -notin $fingerprintFields }).Count) {
        throw 'Context output sourceFingerprint shape is invalid.'
    }
    foreach ($name in @('upstreamId','ref','commitSha','snapshotTreeSha256','skillEntrySha256')) {
        if ($fingerprint.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($fingerprint.$name)) {
            throw "Context output sourceFingerprint.$name must be a non-empty string."
        }
    }
    if ($fingerprint.contractFiles -isnot [array]) { throw 'Context output sourceFingerprint.contractFiles must be an array.' }
    foreach ($file in @($fingerprint.contractFiles)) {
        if ($file -is [array] -or $null -eq $file) { throw 'Context output contract file fingerprint must be an object.' }
        $fileFields = @($file.PSObject.Properties.Name)
        if (@($fileFields | Where-Object { $_ -notin @('path','sha256') }).Count -or
            @(@('path','sha256') | Where-Object { $_ -notin $fileFields }).Count -or
            $file.path -isnot [string] -or $file.sha256 -isnot [string]) {
            throw 'Context output contract file fingerprint shape is invalid.'
        }
    }
    $authorityPath = Join-Path $PSScriptRoot 'impeccable-authority-policy.json'
    $authority = Get-Content -Raw -LiteralPath $authorityPath | ConvertFrom-Json
    if ($fingerprint.upstreamId -cne $authority.upstream.id -or $fingerprint.ref -cne $authority.upstream.ref -or
        $fingerprint.commitSha -cne $authority.upstream.commitSha -or
        $fingerprint.snapshotTreeSha256 -cne $authority.upstream.snapshotTreeSha256 -or
        $fingerprint.skillEntrySha256 -cne $authority.upstream.skillEntrySha256) {
        throw 'Context output source fingerprint does not match the pinned FTK identity.'
    }
    $expectedFiles = @($authority.upstream.contractFiles)
    $actualFiles = @($fingerprint.contractFiles)
    if ($actualFiles.Count -ne $expectedFiles.Count) { throw 'Context output contract file fingerprint count is invalid.' }
    for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
        if ($actualFiles[$index].path -cne $expectedFiles[$index].path -or $actualFiles[$index].sha256 -cne $expectedFiles[$index].sha256) {
            throw 'Context output contract file fingerprint does not match the pinned FTK identity.'
        }
    }

    $requests = @($ContextOutput.requestedOperations)
    $capabilityRequests = @($requests | Where-Object { $_.type -ceq 'capability' })
    if ($capabilityRequests.Count -ne 1) { throw 'Context output must contain exactly one capability request.' }
    $capabilityRequest = $capabilityRequests[0]
    foreach ($name in @('type','capability','requestedOperationId','selectionMeaning','effectsGranted','execution')) {
        if ($null -eq $capabilityRequest.PSObject.Properties[$name]) { throw 'Context capability request is missing a required field.' }
    }
    if ($capabilityRequest.capability -isnot [string] -or [string]::IsNullOrWhiteSpace($capabilityRequest.capability) -or
        $capabilityRequest.requestedOperationId -cne 'impeccable.context.local' -or
        $capabilityRequest.selectionMeaning -cne 'capability-selected-only' -or
        $capabilityRequest.execution -cne 'not-performed' -or
        $capabilityRequest.effectsGranted -isnot [array] -or @($capabilityRequest.effectsGranted).Count -ne 0) {
        throw 'Context capability request violates the no-effects execution contract.'
    }
    foreach ($request in $requests) {
        if ($null -eq $request -or $request -is [array] -or $request.execution -cne 'not-performed') {
            throw 'Context requested operations must remain not-performed.'
        }
        if ($request.type -notin @('capability','subagent')) { throw 'Context output contains an unknown requested operation type.' }
    }
    return $true
}

function Complete-ImpeccableContextChildResult {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [Parameter(Mandatory)][object]$Child,
        [ValidateSet('context','live-event')][string]$Mode = 'context'
    )

    if ($Child.failureType) {
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation -ChildObservation $Child
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }
    if (@($Child.stderr).Count) {
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
            -ChildObservation $Child -OutputContractValid:$false -OutputContractDiagnostic 'Context mediation emitted stderr alongside its typed output.'
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }
    $json = if ($Child.PSObject.Properties.Name -contains 'contractStdout') { [string]$Child.contractStdout } else { @($Child.stdout) -join "
" }
    try {
        $result = ($json | ConvertFrom-Json -ErrorAction Stop)
        if ($Mode -ceq 'context') { Assert-ImpeccableContextOutputContract -ContextOutput $result | Out-Null }
    }
    catch {
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
            -ChildObservation $Child -OutputContractValid:$false -OutputContractDiagnostic $_.Exception.Message
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }
    $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation -ChildObservation $Child
    Remove-ImpeccableContractOutput -ChildObservation $Child | Out-Null
    return Add-FtkDedicatedExecutionMetadata -OperationResult $result -DedicatedExecution $dedicated
}

function Invoke-ImpeccableDetectorBoundary {
    param(
        [Parameter(Mandatory)][ValidateSet('impeccable.detector.local','impeccable.detector.project','impeccable.detector.payload','impeccable.detector.csp')][string]$Operation,
        [string]$ProjectRoot,
        [string]$InputPath,
        [AllowEmptyString()][string]$Content,
        [string]$ContentType,
        [string]$DetectorOptionsJson
    )
    try {
        if ($ProjectRoot -and $InputPath) { Resolve-ImpeccableContainedInput -ProjectRoot $ProjectRoot -InputPath $InputPath | Out-Null }
        if ($DetectorOptionsJson) {
            if ($DetectorOptionsJson.Length -gt 65536) { throw 'DetectorOptionsJson exceeds the 64 KiB limit.' }
            $DetectorOptionsJson | ConvertFrom-Json -ErrorAction Stop | Out-Null
        }
    } catch {
        $invalid = New-FtkNotAttemptedDedicatedExecution -Capability 'impeccable' -Operation $Operation `
            -Reason $_.Exception.Message -FailureType INVALID_INPUT
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $invalid
    }

    $child = $null
    try {
        Assert-ImpeccableIntegratedPolicyIdentity
        $detector = Join-Path $PSScriptRoot 'impeccable-detector.mjs'
        $staticRuntime = Join-Path $PSScriptRoot 'impeccable-static-runtime.mjs'
        $policy = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
        foreach ($path in @($detector, $staticRuntime, $policy)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'A fixed Impeccable detector boundary file is unavailable or reparsed.'
            }
        }
        $skillRoot = Resolve-ImpeccablePinnedSkillRoot
        $request = [ordered]@{ operation = $Operation }
        if ($ProjectRoot) { $request.projectRoot = $ProjectRoot }
        if ($InputPath) { $request.inputPath = $InputPath }
        if ($PSBoundParameters.ContainsKey('Content')) { $request.content = $Content }
        if ($ContentType) { $request.contentType = $ContentType }
        if ($DetectorOptionsJson) { $request.options = $DetectorOptionsJson | ConvertFrom-Json -ErrorAction Stop }
        $requestJson = $request | ConvertTo-Json -Depth 16 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($requestJson) -gt 2097152) { throw 'Detector request exceeds the 2 MiB limit.' }

        $readRoots = @($PSScriptRoot, (Resolve-ImpeccablePinnedUpstreamRoot), $skillRoot, (Resolve-ImpeccableStaticHtmlModuleRoot))
        $packagedToolchainRoot = Join-Path $PSScriptRoot '../integrations'
        if (Test-Path -LiteralPath $packagedToolchainRoot -PathType Container) { $readRoots += $packagedToolchainRoot }
        if ($ProjectRoot) { $readRoots += $ProjectRoot }
        $arguments = @('--permission')
        foreach ($readRoot in $readRoots) { $arguments += "--allow-fs-read=$readRoot" }
        $staticRuntimeUrl = ([Uri]$staticRuntime).AbsoluteUri
        $arguments += @("--import=$staticRuntimeUrl", $detector, $policy, $skillRoot)
        $child = Invoke-ImpeccableChildProcess -Executable (Resolve-ImpeccableNodeRuntime) `
            -Operation $Operation -ArgumentList $arguments -WorkingDirectory $(if ($ProjectRoot) { $ProjectRoot } else { $PSScriptRoot }) `
            -Environment (New-ImpeccableChildEnvironment) -StandardInputText $requestJson -ReturnResult
    } catch {
        if ($null -ne $child) {
            $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
                -ChildObservation $child -OutputContractValid:$false -OutputContractDiagnostic $_.Exception.Message
        } else {
            $dedicated = New-FtkNotAttemptedDedicatedExecution -Capability 'impeccable' -Operation $Operation `
                -Reason $_.Exception.Message -FailureType DEPENDENCY_OR_RUNTIME_FAILURE
        }
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }

    if ($child.failureType) {
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation -ChildObservation $child
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }
    if (@($child.stderr).Count) {
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
            -ChildObservation $child -OutputContractValid:$false -OutputContractDiagnostic 'Detector emitted stderr alongside its typed output.'
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }
    $json = if ($child.PSObject.Properties.Name -contains 'contractStdout') { [string]$child.contractStdout } else { @($child.stdout) -join "
" }
    try { $result = $json | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
            -ChildObservation $child -OutputContractValid:$false -OutputContractDiagnostic 'Fixed Impeccable detector did not return typed JSON.'
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }
    if ($result.operation -cne $Operation -or $result.schemaVersion -ne 2 -or
        $result.safety.networkAttempted -ne $false -or $result.safety.writesPerformed -ne $false -or
        $result.safety.projectCodeExecuted -ne $false -or $result.safety.parentSecretsInherited -ne $false) {
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
            -ChildObservation $child -OutputContractValid:$false -OutputContractDiagnostic 'Fixed Impeccable detector returned an invalid safety contract.'
        return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
    }
    $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation -ChildObservation $child
    Remove-ImpeccableContractOutput -ChildObservation $child | Out-Null
    return Add-FtkDedicatedExecutionMetadata -OperationResult $result -DedicatedExecution $dedicated
}

function Resolve-ImpeccableContainedInput {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath) -or [IO.Path]::IsPathRooted($InputPath) -or
        $InputPath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'InputPath must be a relative contained path.'
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $InputPath))
    if (-not (Test-ImpeccablePathWithinRoot $ProjectRoot $candidate)) { throw 'InputPath escapes ProjectRoot.' }
    Assert-ImpeccableNoExistingReparsePoint -Root $ProjectRoot -Candidate $candidate
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'InputPath must identify an existing file.' }
    $item = Get-Item -LiteralPath $candidate -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'InputPath cannot be a reparse point.' }
    if ($item.Extension.ToLowerInvariant() -notin @('.html','.css','.scss','.js','.jsx','.ts','.tsx','.vue','.svelte')) {
        throw 'InputPath extension is not registered for the local detector.'
    }
    if ($item.Length -gt 1048576) { throw 'InputPath exceeds the 1 MiB local detector limit.' }
    return $item.FullName
}

function Get-ImpeccableHookStatus {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    Assert-ImpeccableIntegratedPolicyIdentity
    return [pscustomobject][ordered]@{
        schemaVersion = 1; operation = 'impeccable.hooks.status'; effects = @('LOCAL_READ_ONLY')
        projectRoot = $ProjectRoot; source = 'ftk-declarative-hook-status'; ftkHooksEnabled = $false
        upstreamHookInspected = $false; mutationPerformed = $false; childStarted = $false; networkAttempted = $false
    }
}

function Get-ImpeccableBoundaryDoctor {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    Assert-ImpeccableIntegratedPolicyIdentity
    return [pscustomobject][ordered]@{
        schemaVersion = 1; operation = 'impeccable.doctor.report'; effects = @('LOCAL_READ_ONLY')
        projectRoot = $ProjectRoot; sourceIdentity = 'verified'; unknownPolicy = 'deny'
        hostAuthorizationBoundary = 'unavailable'; telemetryDefault = 'off'; updateCheckDefault = 'off'
        selfUpdate = 'denied'; mutationPerformed = $false; childStarted = $false; networkAttempted = $false
    }
}

function Invoke-ImpeccableContextExtractor {
    param(
        [Parameter(Mandatory)][ValidateSet('context','live-event')][string]$Mode,
        [string]$ProjectRoot,
        [string]$Capability,
        [string]$EventJson
    )
    try {
        if ($Mode -ceq 'context') {
            if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($Capability)) {
                throw 'Context extraction requires a project root and capability.'
            }
        } else {
            if ([string]::IsNullOrWhiteSpace($EventJson) -or $EventJson.Length -gt 1048576) {
                throw 'Live event mediation requires bounded EventJson.'
            }
            $EventJson | ConvertFrom-Json -ErrorAction Stop | Out-Null
        }
    } catch {
        $invalidOperation = if ($Mode -ceq 'context') { 'impeccable.context.local' } else { 'impeccable.live.event-mediate' }
        $invalid = New-FtkNotAttemptedDedicatedExecution -Capability 'impeccable' -Operation $invalidOperation `
            -Reason $_.Exception.Message -FailureType INVALID_INPUT
        return New-ImpeccableDedicatedFailureEnvelope -Operation $invalidOperation -DedicatedExecution $invalid
    }

    $operation = if ($Mode -ceq 'context') { 'impeccable.context.local' } else { 'impeccable.live.event-mediate' }
    $child = $null
    try {
        Assert-ImpeccableIntegratedPolicyIdentity
        $extractor = Join-Path $PSScriptRoot 'impeccable-context-extractor.mjs'
        $mediator = Join-Path $PSScriptRoot 'impeccable-context-mediator.mjs'
        $authorityPolicy = Join-Path $PSScriptRoot 'impeccable-authority-policy.json'
        $operationPolicy = Join-Path $PSScriptRoot 'impeccable-operation-policy.json'
        foreach ($path in @($extractor, $mediator, $authorityPolicy, $operationPolicy)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A fixed Impeccable context boundary module is unavailable.' }
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'A fixed Impeccable context boundary module is a reparse point.'
            }
        }
        $arguments = @(
            $extractor, '--mode', $Mode,
            '--authorityPolicy', $authorityPolicy,
            '--operationPolicy', $operationPolicy,
            '--mediator', $mediator
        )
        if ($Mode -ceq 'context') { $arguments += @('--projectRoot', $ProjectRoot, '--capability', $Capability) }
        else { $arguments += @('--eventJson', $EventJson) }
        $child = Invoke-ImpeccableChildProcess -Executable (Resolve-ImpeccableNodeRuntime) `
            -Operation $operation -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -Environment (New-ImpeccableChildEnvironment) -ReturnResult
    } catch {
        if ($null -ne $child) {
            $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $operation `
                -ChildObservation $child -OutputContractValid:$false -OutputContractDiagnostic $_.Exception.Message
        } else {
            $dedicated = New-FtkNotAttemptedDedicatedExecution -Capability 'impeccable' -Operation $operation `
                -Reason $_.Exception.Message -FailureType DEPENDENCY_OR_RUNTIME_FAILURE
        }
        return New-ImpeccableDedicatedFailureEnvelope -Operation $operation -DedicatedExecution $dedicated
    }
    return Complete-ImpeccableContextChildResult -Operation $operation -Child $child -Mode $Mode
}

function New-ImpeccableOperationPlan {
    param([Parameter(Mandatory)]$Definition, [string]$ProjectRoot)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        operation = $Definition.id
        effects = @($Definition.effects)
        defaultState = $Definition.defaultState
        handler = $Definition.scriptHandler
        projectRoot = $ProjectRoot
        endpointRequirements = $Definition.endpointRequirements
        persistentEffect = [bool]$Definition.persistentEffect
        projectCodeExecution = [bool]$Definition.projectCodeExecution
        authorizationRequirement = $Definition.authorizationRequirement
        childEnvironmentNames = @($Definition.childEnvironmentAllowlist)
        childStarted = $false
        networkAttempted = $false
    }
}

function Invoke-ImpeccableOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
        [string]$ProjectRoot,
        [string]$InputPath,
        [string]$Prompt,
        [string]$OutputPath,
        [ValidateSet('1024x1024','1536x1024','1024x1536')][string]$Size = '1536x1024',
        [string]$Scope,
        [string]$Key,
        [string]$Mode,
        [string]$TargetUrl,
        [string]$Capability,
        [string]$EventJson,
        [AllowEmptyString()][string]$Content,
        [ValidateSet('html','css','scss','sass','less','jsx','tsx','js','ts','vue','svelte','astro')][string]$ContentType,
        [string]$DetectorOptionsJson,
        [switch]$PlanOnly
    )
    $bound = @{} + $PSBoundParameters
    $definition = Get-ImpeccableRegisteredOperation -Operation $Operation
    $canonicalProject = $null
    if ($ProjectRoot) {
        try { $canonicalProject = Resolve-ImpeccableCanonicalProjectRoot $ProjectRoot }
        catch { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason $_.Exception.Message }
    }

    if ($Operation -eq 'impeccable.concept.local-fallback') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','Scope','Key','Mode','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if ($Scope -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $Key -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
            return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Local concept fallback requires validated Scope and Key.'
        }
        return [pscustomobject][ordered]@{
            schemaVersion = 1; operation = $Operation; effects = @('LOCAL_READ_ONLY'); source = 'degraded-local'
            scope = $Scope; key = $Key; mode = $Mode; networkAttempted = $false; telemetrySent = $false; childStarted = $false
        }
    }

    if ($Operation -eq 'impeccable.context.local') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','ProjectRoot','Capability','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $canonicalProject) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Local context requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        if ([string]::IsNullOrWhiteSpace($Capability)) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Local context execution requires Capability.' }
        return Invoke-ImpeccableContextExtractor -Mode context -ProjectRoot $canonicalProject -Capability $Capability
    }

    if ($Operation -eq 'impeccable.detector.local') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','ProjectRoot','InputPath','DetectorOptionsJson','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $canonicalProject) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Local detector requires ProjectRoot.' }
        if ([string]::IsNullOrWhiteSpace($InputPath)) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Local detector requires InputPath.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -ProjectRoot $canonicalProject -InputPath $InputPath -DetectorOptionsJson $DetectorOptionsJson
    }

    if ($Operation -eq 'impeccable.detector.project') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','ProjectRoot','InputPath','DetectorOptionsJson','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $canonicalProject) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Project detector requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -ProjectRoot $canonicalProject -InputPath $InputPath -DetectorOptionsJson $DetectorOptionsJson
    }

    if ($Operation -eq 'impeccable.detector.payload') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','Content','ContentType','DetectorOptionsJson','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $bound.ContainsKey('Content') -or [string]::IsNullOrWhiteSpace($ContentType)) {
            return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Payload detector requires typed Content and ContentType.'
        }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $null }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -Content $Content -ContentType $ContentType -DetectorOptionsJson $DetectorOptionsJson
    }

    if ($Operation -eq 'impeccable.detector.csp') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','ProjectRoot','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $canonicalProject) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'CSP detector requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Invoke-ImpeccableDetectorBoundary -Operation $Operation -ProjectRoot $canonicalProject
    }

    if ($Operation -eq 'impeccable.hooks.status') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','ProjectRoot','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $canonicalProject) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Hook status requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Get-ImpeccableHookStatus -ProjectRoot $canonicalProject
    }

    if ($Operation -eq 'impeccable.doctor.report') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','ProjectRoot','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $canonicalProject) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Doctor/report requires ProjectRoot.' }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
        return Get-ImpeccableBoundaryDoctor -ProjectRoot $canonicalProject
    }

    if ($Operation -eq 'impeccable.live.event-mediate') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','EventJson','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if ([string]::IsNullOrWhiteSpace($EventJson) -or $EventJson.Length -gt 1048576) {
            return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Live event mediation requires bounded EventJson.'
        }
        if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $null }
        return Invoke-ImpeccableContextExtractor -Mode live-event -EventJson $EventJson
    }

    if ($Operation -eq 'impeccable.paid-generation.fake') {
        $invalidParameters = Get-ImpeccableParameterValidationResult $bound @('Operation','ProjectRoot','Prompt','OutputPath','Size','PlanOnly') $Operation
        if ($null -ne $invalidParameters) { return $invalidParameters }
        if (-not $canonicalProject) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Fake generation requires ProjectRoot.' }
        if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt.Length -gt 4000 -or $Prompt -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
            return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Prompt is empty, contains controls, or exceeds 4000 characters.'
        }
        if ([string]::IsNullOrWhiteSpace($OutputPath)) { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason 'Fake generation requires OutputPath.' }
        try { $output = Resolve-ImpeccableGeneratedOutput $canonicalProject $OutputPath }
        catch { return New-FtkInvalidInputEnvelope -Capability 'impeccable' -Operation $Operation -Reason $_.Exception.Message }
        if ($PlanOnly) {
            $plan = New-ImpeccableOperationPlan $definition $canonicalProject
            $plan | Add-Member -NotePropertyName outputPath -NotePropertyValue $output.Path
            return $plan
        }
        $child = $null
        try {
            [IO.Directory]::CreateDirectory($output.Root) | Out-Null
            Assert-ImpeccableNoExistingReparsePoint -Root $canonicalProject -Candidate $output.Root
            if (Test-Path -LiteralPath $output.Path) { throw 'Refusing to overwrite an existing generated output.' }
            $script = Resolve-ImpeccablePinnedScript 'scripts/generate-image.mjs'
            $environment = New-ImpeccableChildEnvironment ([ordered]@{ IMPECCABLE_IMAGE_GEN_FAKE = '1' })
            $child = Invoke-ImpeccableChildProcess -Executable (Resolve-ImpeccableNodeRuntime) `
                -Operation $Operation -ArgumentList @($script,'--prompt',$Prompt,'--out',$output.Path,'--size',$Size) `
                -WorkingDirectory $canonicalProject -Environment $environment -ReturnResult
        } catch {
            if ($null -ne $child) {
                $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
                    -ChildObservation $child -OutputContractValid:$false -OutputContractDiagnostic $_.Exception.Message
            } else {
                $dedicated = New-FtkNotAttemptedDedicatedExecution -Capability 'impeccable' -Operation $Operation `
                    -Reason $_.Exception.Message -FailureType DEPENDENCY_OR_RUNTIME_FAILURE
            }
            return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
        }
        if ($child.failureType) {
            $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation -ChildObservation $child
            return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
        }
        try {
            Assert-ImpeccableNoExistingReparsePoint -Root $canonicalProject -Candidate $output.Path
            if (-not (Test-Path -LiteralPath $output.Path -PathType Leaf)) { throw 'Fake generation did not create its contained output.' }
        } catch {
            $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation `
                -ChildObservation $child -OutputContractValid:$false -OutputContractDiagnostic $_.Exception.Message
            return New-ImpeccableDedicatedFailureEnvelope -Operation $Operation -DedicatedExecution $dedicated
        }
        $dedicated = Complete-FtkDedicatedExecution -Capability 'impeccable' -Operation $Operation -ChildObservation $child
        Remove-ImpeccableContractOutput -ChildObservation $child | Out-Null
        return [pscustomobject][ordered]@{
            schemaVersion = 1; operation = $Operation; effects = @('LOCAL_PROJECT_WRITE'); outputPath = $output.Path
            fake = $true; paid = $false; networkAttempted = $false; childStarted = $true; child = $child
            dedicatedExecution = $dedicated
        }
    }

    $allowed = @('Operation','PlanOnly')
    if (@($definition.allowedInputs) -contains 'ProjectRoot') { $allowed += 'ProjectRoot' }
    if (@($definition.allowedInputs) -contains 'TargetUrl') { $allowed += 'TargetUrl' }
    $invalidParameters = Get-ImpeccableParameterValidationResult $bound $allowed $Operation
    if ($null -ne $invalidParameters) { return $invalidParameters }
    if ($PlanOnly) { return New-ImpeccableOperationPlan $definition $canonicalProject }
    throw "Operation $Operation is registered but blocked at the direct runner boundary: $($definition.authorizationRequirement)"
}
