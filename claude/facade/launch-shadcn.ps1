param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ShadcnPackage = 'shadcn@4.19.0'

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
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Claude plugin root is unavailable.' }
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Claude plugin root is a reparse point.'
    }
    return $resolved
}

function Resolve-ClaudeNodeToolchain {
    param([Parameter(Mandatory)][string]$ArtifactRoot)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'The Claude Shadcn launcher only supports the registered Windows x64 toolchain.'
    }

    $lockPath = Join-Path $ArtifactRoot 'integrations/toolchain.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw 'The governed toolchain lock is unavailable.' }
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $nodes = @($lock.runtimes | Where-Object id -CEQ 'node')
    if ($nodes.Count -ne 1) { throw 'The governed toolchain must contain exactly one Node runtime.' }
    $node = $nodes[0]
    if ($node.targetVersion -cne '24.20.0' -or $node.observedVersion -cne $node.targetVersion -or
        $node.portableResolution -notmatch '%LOCALAPPDATA%/Programs/FrontendToolkit/node-v24\.20\.0-win-x64/node\.exe') {
        throw 'The governed Node runtime pin is invalid.'
    }

    $nodePath = [IO.Path]::GetFullPath((Expand-ClaudePortablePath -Value ([string]$node.portableResolution)))
    if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf) -or
        ((Get-Item -LiteralPath $nodePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The pinned Node runtime is unavailable.'
    }

    $nodeVersion = (& $nodePath --version).Trim().TrimStart('v')
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -cne $node.targetVersion) {
        throw 'The pinned Node runtime failed version validation.'
    }
    $nodeDirectory = Split-Path -Parent $nodePath
    $npxCliPath = Join-Path $nodeDirectory 'node_modules/npm/bin/npx-cli.js'
    if (-not (Test-Path -LiteralPath $npxCliPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $npxCliPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The governed npx entrypoint is unavailable.'
    }

    return [pscustomobject][ordered]@{
        NodePath = $nodePath
        NodeDirectory = $nodeDirectory
        NodeVersion = $nodeVersion
        NpxCliPath = $npxCliPath
        Arguments = @('--yes', $script:ShadcnPackage, 'mcp')
    }
}

function New-ClaudeChildEnvironment {
    param([Parameter(Mandatory)][string]$NodeDirectory)

    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot', 'Process')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
    $temp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    $tmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or [string]::IsNullOrWhiteSpace($localAppData) -or
        [string]::IsNullOrWhiteSpace($temp) -or [string]::IsNullOrWhiteSpace($tmp)) {
        throw 'The minimum Windows child environment is unavailable.'
    }

    $system32 = Join-Path $systemRoot 'System32'
    return [ordered]@{
        SystemRoot = $systemRoot
        LOCALAPPDATA = $localAppData
        TEMP = $temp
        TMP = $tmp
        PATH = $NodeDirectory + ';' + $system32
        ComSpec = Join-Path $system32 'cmd.exe'
        PATHEXT = '.COM;.EXE;.BAT;.CMD'
        NODE_OPTIONS = '--use-system-ca'
        NPM_CONFIG_USERCONFIG = 'NUL'
        NPM_CONFIG_GLOBALCONFIG = 'NUL'
        NPM_CONFIG_UPDATE_NOTIFIER = 'false'
    }
}

function Get-ClaudeShadcnInvocation {
    param([Parameter(Mandatory)][string]$ArtifactRoot)

    $toolchain = Resolve-ClaudeNodeToolchain -ArtifactRoot $ArtifactRoot
    $childEnvironment = New-ClaudeChildEnvironment -NodeDirectory $toolchain.NodeDirectory
    return [pscustomobject][ordered]@{
        NodePath = $toolchain.NodePath
        NpxCliPath = $toolchain.NpxCliPath
        NodeVersion = $toolchain.NodeVersion
        Arguments = @($toolchain.NpxCliPath) + @($toolchain.Arguments)
        Environment = $childEnvironment
    }
}

function Invoke-ClaudeShadcn {
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
        if (-not $process.Start()) { throw 'The Shadcn child process did not start.' }
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

try {
    $artifactRoot = Get-ClaudeArtifactRoot
    $invocation = Get-ClaudeShadcnInvocation -ArtifactRoot $artifactRoot
    if ($ValidateOnly) {
        $validation = [ordered]@{
            runtime = 'locked-node'
            nodeVersion = $invocation.NodeVersion
            npxEntrypoint = 'node_modules/npm/bin/npx-cli.js'
            arguments = @('--yes', $script:ShadcnPackage, 'mcp')
            environmentNames = @($invocation.Environment.Keys)
            stdoutPassthrough = $true
            stderrPassthrough = $true
        }
        [Console]::Error.WriteLine(($validation | ConvertTo-Json -Compress))
        exit 0
    }

    $exitCode = Invoke-ClaudeShadcn -ArtifactRoot $artifactRoot -Invocation $invocation
    exit $exitCode
} catch {
    [Console]::Error.WriteLine('Claude Shadcn launcher failed closed.')
    exit 1
}
