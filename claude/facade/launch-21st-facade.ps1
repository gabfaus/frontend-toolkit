param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-ClaudePortablePath {
    param([Parameter(Mandatory)][string]$Value)

    return ([Environment]::ExpandEnvironmentVariables($Value)).Replace('/', [IO.Path]::DirectorySeparatorChar)
}

function ConvertTo-ClaudeWindowsNativeArgument {
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

function Get-ClaudeArtifactRoot {
    $root = Join-Path $PSScriptRoot '../..'
    if (-not (Test-Path -Path $root -PathType Container)) { throw 'Claude plugin root is unavailable.' }
    $resolved = (Resolve-Path -Path $root).Path
    if ((Get-Item -Path $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Claude plugin root is a reparse point.'
    }
    return $resolved
}

function Resolve-ClaudeContainedPath {
    param(
        [Parameter(Mandatory)][string]$ArtifactRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [ValidateSet('Leaf', 'Container')][string]$PathType = 'Leaf'
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'Claude path must be relative and traversal-free.'
    }

    $candidate = [IO.Path]::GetFullPath((Join-Path $ArtifactRoot ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $rootWithSeparator = $ArtifactRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Claude path escaped the plugin root.'
    }
    if (-not (Test-Path -Path $candidate -PathType $PathType)) { throw "Claude payload path is unavailable: $RelativePath" }

    $current = $ArtifactRoot
    foreach ($part in ($RelativePath.Replace('/', '\').Split('\') | Where-Object { $_.Length -gt 0 })) {
        $current = Join-Path $current $part
        $item = Get-Item -Path $current -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Claude payload path is a reparse point: $RelativePath" }
    }
    $resolved = (Resolve-Path -Path $candidate).Path
    if (-not $resolved.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Claude payload path resolved outside the plugin root.'
    }
    return $resolved
}

function Resolve-ClaudeNodeToolchain {
    param([Parameter(Mandatory)][string]$ArtifactRoot)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'The Claude 21st facade launcher only supports the registered Windows x64 toolchain.'
    }

    $lockPath = Resolve-ClaudeContainedPath -ArtifactRoot $ArtifactRoot -RelativePath 'integrations/toolchain.lock.json'
    $lock = Get-Content -Raw -Path $lockPath | ConvertFrom-Json
    $nodes = @($lock.runtimes | Where-Object id -CEQ 'node')
    if ($nodes.Count -ne 1) { throw 'The governed toolchain must contain exactly one Node runtime.' }
    $node = $nodes[0]
    if ($node.targetVersion -cne '24.20.0' -or $node.observedVersion -cne $node.targetVersion -or
        $node.portableResolution -notmatch '%LOCALAPPDATA%/Programs/FrontendToolkit/node-v24\.20\.0-win-x64/node\.exe') {
        throw 'The governed Node runtime pin is invalid.'
    }

    $nodePath = [IO.Path]::GetFullPath((Expand-ClaudePortablePath -Value ([string]$node.portableResolution)))
    if (-not (Test-Path -Path $nodePath -PathType Leaf) -or
        ((Get-Item -Path $nodePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The pinned Node runtime is unavailable.'
    }
    $nodeVersion = (& $nodePath --version).Trim().TrimStart('v')
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -cne $node.targetVersion) { throw 'The pinned Node runtime failed version validation.' }

    return [pscustomobject][ordered]@{
        NodePath = $nodePath
        NodeVersion = $nodeVersion
    }
}

function New-ClaudeChildEnvironment {
    param([Parameter(Mandatory)][string]$NodePath)

    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot', 'Process')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
    $temp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    $tmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or [string]::IsNullOrWhiteSpace($localAppData) -or
        [string]::IsNullOrWhiteSpace($temp) -or [string]::IsNullOrWhiteSpace($tmp)) {
        throw 'The minimum Windows child environment is unavailable.'
    }

    $system32 = Join-Path $systemRoot 'System32'
    $nodeDirectory = Split-Path -Parent $NodePath
    $environment = [ordered]@{
        SystemRoot = $systemRoot
        LOCALAPPDATA = $localAppData
        TEMP = $temp
        TMP = $tmp
        PATH = $nodeDirectory + ';' + $system32
        ComSpec = Join-Path $system32 'cmd.exe'
        PATHEXT = '.COM;.EXE;.BAT;.CMD'
        NODE_OPTIONS = '--use-system-ca'
    }
    $apiKey = [Environment]::GetEnvironmentVariable('API_KEY_21ST', 'Process')
    if (-not [string]::IsNullOrEmpty($apiKey)) { $environment.API_KEY_21ST = $apiKey }
    return $environment
}

function Get-ClaudeFacadeInvocation {
    param([Parameter(Mandatory)][string]$ArtifactRoot)

    $toolchain = Resolve-ClaudeNodeToolchain -ArtifactRoot $ArtifactRoot
    $facadePath = Resolve-ClaudeContainedPath -ArtifactRoot $ArtifactRoot -RelativePath 'security/claude/21st-facade.mjs'
    [void](Resolve-ClaudeContainedPath -ArtifactRoot $ArtifactRoot -RelativePath 'security/claude/runtime' -PathType Container)
    [void](Resolve-ClaudeContainedPath -ArtifactRoot $ArtifactRoot -RelativePath 'security/claude/runtime/package.json')
    [void](Resolve-ClaudeContainedPath -ArtifactRoot $ArtifactRoot -RelativePath 'security/claude/runtime/package-lock.json')
    [void](Resolve-ClaudeContainedPath -ArtifactRoot $ArtifactRoot -RelativePath 'security/claude/runtime/node_modules' -PathType Container)
    return [pscustomobject][ordered]@{
        NodePath = $toolchain.NodePath
        NodeVersion = $toolchain.NodeVersion
        FacadePath = $facadePath
        Arguments = @($facadePath)
        Environment = New-ClaudeChildEnvironment -NodePath $toolchain.NodePath
    }
}

function Invoke-ClaudeFacade {
    param(
        [Parameter(Mandatory)][string]$ArtifactRoot,
        [Parameter(Mandatory)][object]$Invocation
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Invocation.NodePath
    $startInfo.WorkingDirectory = $ArtifactRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.Arguments = (@($Invocation.Arguments | ForEach-Object {
        ConvertTo-ClaudeWindowsNativeArgument -Value ([string]$_)
    }) -join ' ')
    $startInfo.EnvironmentVariables.Clear()
    foreach ($name in $Invocation.Environment.Keys) {
        $startInfo.EnvironmentVariables.Add([string]$name, [string]$Invocation.Environment[$name])
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'The 21st facade child process did not start.' }
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

try {
    $artifactRoot = Get-ClaudeArtifactRoot
    $invocation = Get-ClaudeFacadeInvocation -ArtifactRoot $artifactRoot
    if ($ValidateOnly) {
        [Console]::Error.WriteLine(([ordered]@{
            runtime = 'locked-node'
            nodeVersion = $invocation.NodeVersion
            facade = 'security/claude/21st-facade.mjs'
            runtimeRoot = 'security/claude/runtime'
            stdoutPassthrough = $true
            stderrPassthrough = $true
            environmentNames = @($invocation.Environment.Keys)
        } | ConvertTo-Json -Compress))
        exit 0
    }

    exit (Invoke-ClaudeFacade -ArtifactRoot $artifactRoot -Invocation $invocation)
} catch {
    [Console]::Error.WriteLine('Claude 21st facade launcher failed closed.')
    exit 1
}
