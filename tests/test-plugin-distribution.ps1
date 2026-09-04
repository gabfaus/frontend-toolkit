param(
    [switch]$ValidateOnly,
    [switch]$DevelopmentWorkingTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TreeHash {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = (Resolve-Path $Root).Path
    $entries = Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        "$relative|$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())"
    } | Sort-Object
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Invoke-Codex {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & $script:CodexPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Codex failed: $($Arguments -join ' ')" }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$distributionLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/distribution.lock.json') | ConvertFrom-Json
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$mcpLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/mcp.lock.json') | ConvertFrom-Json
$builder = Join-Path $repoRoot $distributionLock.generator

if ($distributionLock.strategy -ne 'mediated-adapter-generated-snapshots' -or $distributionLock.architecture -ne 'ftk-owned-mediated-adapter') { throw 'Distribution strategy drifted.' }
if ($distributionLock.snapshotPersistence -ne 'ephemeral-only') { throw 'Snapshots must remain ephemeral in FTK-05B.' }
if ($distributionLock.sourceComposition.strategy -ne 'git-head-explicit-file-allowlist' -or
    $distributionLock.sourceComposition.unexpectedFilesystemEntries -ne 'fail' -or
    $distributionLock.sourceComposition.sensitivePathDefense -ne 'fail' -or
    $distributionLock.sourceComposition.enumeration -ne 'all-files-force') {
    throw 'Distribution source-composition safety contract drifted.'
}
if (@($distributionLock.twentyFirstAutomaticTools) -ne 'search') { throw '21st automatic policy drifted.' }
if (-not (Test-Path -LiteralPath $builder)) { throw 'Snapshot builder is missing.' }
foreach ($dependency in $externalLock.dependencies) {
    if ($dependency.commitSha -notmatch '^[0-9a-f]{40}$' -or $dependency.license -ne 'Apache-2.0') { throw "Invalid external lock: $($dependency.id)" }
}
$impeccableLock = $externalLock.dependencies | Where-Object id -eq 'impeccable'
if ($impeccableLock.noticeSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Impeccable NOTICE is not locked.' }
if ($ValidateOnly) {
    Write-Output 'PASS: FTK-05B distribution lock, pins, licenses and generator contract validated.'
    return
}

$toolchain = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json
$script:CodexPath = [Environment]::ExpandEnvironmentVariables(($toolchain.runtimes | Where-Object id -eq 'codex-cli').portableResolution)
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk05b-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$snapshotOne = Join-Path $fixture 'one/frontend-toolkit'
$snapshotTwo = Join-Path $fixture 'two/frontend-toolkit'
$marketplaceRoot = Join-Path $fixture 'marketplace'
$marketplaceDirectory = Join-Path $marketplaceRoot '.agents/plugins'
$marketplacePlugin = Join-Path $marketplaceRoot 'plugins/frontend-toolkit'
$mainConfig = Join-Path $env:USERPROFILE '.codex/config.toml'
$configBefore = if (Test-Path -LiteralPath $mainConfig) { (Get-FileHash -Algorithm SHA256 -LiteralPath $mainConfig).Hash } else { '<absent>' }
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$oldCodexHome = $env:CODEX_HOME

try {
    $snapshotOneArguments = @{ Destination = $snapshotOne }
    $snapshotTwoArguments = @{ Destination = $snapshotTwo }
    if ($DevelopmentWorkingTree) {
        $snapshotOneArguments.DevelopmentWorkingTree = $true
        $snapshotTwoArguments.DevelopmentWorkingTree = $true
    }
    & $builder @snapshotOneArguments | Out-Null
    & $builder @snapshotTwoArguments | Out-Null
    $treeHashOne = Get-TreeHash $snapshotOne
    $treeHashTwo = Get-TreeHash $snapshotTwo
    if ($treeHashOne -ne $treeHashTwo) { throw 'Two snapshot generations produced different trees.' }
    if (-not $DevelopmentWorkingTree -and $treeHashOne -ne $distributionLock.observedSnapshotTreeSha256) {
        throw "Snapshot observation drifted: $treeHashOne"
    }
    foreach ($required in @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'SNAPSHOT_PROVENANCE.json', 'skills/frontend-orchestrator/SKILL.md', 'skills/impeccable/SKILL.md', 'skills/img2threejs/SKILL.md', 'security/effect-policy.json', 'security/img2threejs-codec-mediator.mjs', 'security/img2threejs-foundation.ps1', 'security/img2threejs-runner.ps1', 'security/img2threejs-runtime-policy.json', 'security/img2threejs-state-guard.ps1', 'security/img2threejs-structural-validation.ps1', 'security/impeccable-authority-policy.json', 'security/impeccable-context-extractor.mjs', 'security/impeccable-context-mediator.mjs', 'security/impeccable-detector.mjs', 'security/impeccable-static-runtime.mjs', 'security/impeccable-network-client.mjs', 'security/impeccable-operation-policy.json', 'security/impeccable-runner.ps1', 'security/invoke-capability.ps1', 'third_party/upstreams/impeccable/LICENSE', 'third_party/upstreams/impeccable/NOTICE.md', 'third_party/upstreams/impeccable/plugin/skills/impeccable/SKILL.md', 'third_party/upstreams/img2threejs/LICENSE', 'third_party/upstreams/img2threejs/SKILL.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $snapshotOne $required))) { throw "Distribution attribution missing: $required" }
    }
    $provenance = Get-Content -Raw -LiteralPath (Join-Path $snapshotOne 'SNAPSHOT_PROVENANCE.json') | ConvertFrom-Json
    if ($provenance.architecture -ne 'ftk-owned-mediated-adapter' -or @($provenance.adapters).Count -ne 2 -or @($provenance.upstreamSnapshots).Count -ne 2) { throw 'Adapter/upstream provenance is not separated.' }
    $impeccableProvenance = $provenance.upstreamSnapshots | Where-Object id -eq 'impeccable'
    if ($impeccableProvenance.noticeSha256 -ne $impeccableLock.noticeSha256) { throw 'Impeccable NOTICE provenance drifted.' }
    $skills = @(Get-ChildItem -LiteralPath (Join-Path $snapshotOne 'skills') -Directory | Sort-Object Name | Select-Object -ExpandProperty Name)
    if (($skills -join ',') -ne 'frontend-orchestrator,img2threejs,impeccable') { throw "Snapshot Skills mismatch: $($skills -join ',')" }
    foreach ($dependency in $externalLock.dependencies) {
        $adapterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $snapshotOne ($dependency.distributionAdapterPath + '/SKILL.md'))).Hash.ToLowerInvariant()
        if ($adapterHash -ne $dependency.adapterEntrySha256) { throw "Snapshot adapter hash mismatch: $($dependency.id)" }
        $snapshotHash = Get-TreeHash (Join-Path $snapshotOne $dependency.upstreamSnapshotPath)
        if ($snapshotHash -ne $dependency.snapshotTreeSha256) { throw "Snapshot upstream tree hash mismatch: $($dependency.id)" }
    }

    New-Item -ItemType Directory -Path $marketplaceDirectory, (Split-Path $marketplacePlugin) -Force | Out-Null
    Copy-Item -LiteralPath $snapshotOne -Destination $marketplacePlugin -Recurse
    $marketplace = @{
        name = 'ftk05b_fixture'
        interface = @{ displayName = 'FTK-05B Fixture' }
        plugins = @(@{
            name = 'frontend-toolkit'
            source = @{ source = 'local'; path = './plugins/frontend-toolkit' }
            policy = @{ installation = 'AVAILABLE'; authentication = 'ON_USE' }
            category = 'Developer Tools'
        })
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $marketplaceDirectory 'marketplace.json'), $marketplace, (New-Object Text.UTF8Encoding($false)))

    $env:CODEX_HOME = Join-Path $fixture 'codex-home'
    New-Item -ItemType Directory -Path $env:CODEX_HOME | Out-Null
    Invoke-Codex @('plugin', 'marketplace', 'add', $marketplaceRoot)
    $install = (& $script:CodexPath plugin add frontend-toolkit@ftk05b_fixture --json | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'Plugin installation failed.' }
    $installedPath = $install.installedPath
    $skills = @(Get-ChildItem -LiteralPath (Join-Path $installedPath 'skills') -Directory | Select-Object -ExpandProperty Name | Sort-Object)
    if (($skills -join ',') -ne 'frontend-orchestrator,img2threejs,impeccable') { throw "Installed Skills mismatch: $($skills -join ',')" }
    $mcp = Get-Content -Raw -LiteralPath (Join-Path $installedPath '.mcp.json') | ConvertFrom-Json
    if ((@($mcp.mcpServers.PSObject.Properties.Name | Sort-Object) -join ',') -ne '21st,shadcn') { throw 'Installed MCP discovery mismatch.' }
    if ($mcp.mcpServers.'21st'.bearer_token_env_var -ne 'API_KEY_21ST') { throw '21st authentication is not env-var-only.' }
    $policy = Get-Content -Raw -LiteralPath (Join-Path $installedPath 'skills/frontend-orchestrator/references/routing-policy.json') | ConvertFrom-Json
    if (@($policy.capabilities.'21st'.defaultAllowedTools) -ne 'search') { throw 'Installed routing policy is not search-only for 21st.' }

    $cachebusterHelper = Join-Path $env:USERPROFILE '.codex/skills/.system/plugin-creator/scripts/update_plugin_cachebuster.py'
    $pythonPath = [Environment]::ExpandEnvironmentVariables(($toolchain.runtimes | Where-Object id -eq 'python').portableResolution)
    if (-not (Test-Path -LiteralPath $cachebusterHelper)) { throw 'Official cachebuster helper is missing.' }
    & $pythonPath $cachebusterHelper $marketplacePlugin | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cachebuster update failed.' }
    $updatedVersion = (Get-Content -Raw -LiteralPath (Join-Path $marketplacePlugin '.codex-plugin/plugin.json') | ConvertFrom-Json).version
    $baseVersion = [regex]::Escape((Get-Content -Raw -LiteralPath (Join-Path $snapshotOne '.codex-plugin/plugin.json') | ConvertFrom-Json).version)
    if ($updatedVersion -notmatch "^$baseVersion\+codex\.[0-9]{14}$") { throw "Unexpected updated version: $updatedVersion" }
    $update = (& $script:CodexPath plugin add frontend-toolkit@ftk05b_fixture --json | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $update.version -ne $updatedVersion -or -not (Test-Path -LiteralPath $update.installedPath)) { throw 'Plugin update failed.' }
    $updatedPath = $update.installedPath

    Invoke-Codex @('plugin', 'remove', 'frontend-toolkit@ftk05b_fixture', '--json')
    if ((Test-Path -LiteralPath $installedPath) -or (Test-Path -LiteralPath $updatedPath)) { throw 'Plugin cache remained after removal.' }
    $reinstall = (& $script:CodexPath plugin add frontend-toolkit@ftk05b_fixture --json | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $reinstall.version -ne $updatedVersion -or -not (Test-Path -LiteralPath $reinstall.installedPath)) { throw 'Plugin reinstall failed.' }
    Invoke-Codex @('plugin', 'remove', 'frontend-toolkit@ftk05b_fixture', '--json')
    Invoke-Codex @('plugin', 'marketplace', 'remove', 'ftk05b_fixture')

    if ($DevelopmentWorkingTree) {
        Write-Output "DIAGNOSTIC: DevelopmentWorkingTree snapshot tree $treeHashOne is not persistent release evidence."
    } else {
        Write-Output "PASS: deterministic committed-HEAD snapshot tree $treeHashOne."
    }
    Write-Output 'PASS: clean install discovered three FTK adapters and two MCPs; upstream snapshots remained non-discoverable.'
    Write-Output 'PASS: routing policy stayed 21st/search-only; no MCP tool was called.'
    Write-Output "PASS: cachebuster update installed $updatedVersion."
    Write-Output 'PASS: remove and reinstall completed without cache residue.'
} finally {
    $env:CODEX_HOME = $oldCodexHome
    $extendedFixture = '\\?\' + [IO.Path]::GetFullPath($fixture)
    if ([IO.Directory]::Exists($extendedFixture)) { [IO.Directory]::Delete($extendedFixture, $true) }
}

$configAfter = if (Test-Path -LiteralPath $mainConfig) { (Get-FileHash -Algorithm SHA256 -LiteralPath $mainConfig).Hash } else { '<absent>' }
if ($configBefore -ne $configAfter) { throw 'Main Codex config changed.' }
if ($userPathBefore -ne [Environment]::GetEnvironmentVariable('Path', 'User')) { throw 'User PATH changed.' }
if ($machinePathBefore -ne [Environment]::GetEnvironmentVariable('Path', 'Machine')) { throw 'Machine PATH changed.' }
foreach ($dependency in $externalLock.dependencies) {
    $checkout = (Resolve-Path (Join-Path $repoRoot $dependency.checkoutPath)).Path
    if (& git -c "safe.directory=$($checkout.Replace('\','/'))" -C $checkout status --porcelain) { throw "External checkout changed: $($dependency.id)" }
}
if (Test-Path -LiteralPath $fixture) { throw 'Fixture teardown was incomplete.' }
Write-Output 'PASS: fixture teardown, config, PATH and external checkouts remained intact.'
