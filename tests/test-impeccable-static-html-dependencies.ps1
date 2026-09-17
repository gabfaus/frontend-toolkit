Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'helpers/external-prerequisite.ps1')
. (Join-Path $repoRoot 'scripts/release-safety.ps1')
Assert-FtkExternalPrerequisite
$lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/impeccable-static-html-dependencies.lock.json') | ConvertFrom-Json
$externalLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/external.lock.json') | ConvertFrom-Json
$snapshotRoot = Join-Path $repoRoot $lock.snapshot.path
$moduleRoot = Join-Path $repoRoot $lock.snapshot.moduleRoot

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$textExtensions = @('.cjs', '.js', '.json', '.map', '.md', '.snap', '.ts')
function Get-CanonicalStaticBytes([string]$Path, [string]$Root) {
    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $relative = (Resolve-Path -LiteralPath $Path).Path.Substring($rootPath.Length + 1).Replace([char]92, [char]47)
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $known = $extension -eq '.cjs' -or $extension -eq '.js' -or $extension -eq '.json' -or $extension -eq '.map' -or $extension -eq '.md' -or $extension -eq '.snap' -or $extension -eq '.ts'
    $known = $known -or [IO.Path]::GetFileName($Path) -ceq 'LICENSE'
    if (-not $known) { throw 'Unknown static-HTML content type.' }
    $source = [IO.File]::ReadAllBytes($Path)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    for ($index = 0; $index -lt $source.Length; $index++) {
        if ($source[$index] -eq 13 -and $index + 1 -lt $source.Length -and $source[$index + 1] -eq 10) { [void]$bytes.Add(10); $index++ } else { [void]$bytes.Add($source[$index]) }
    }
    return $bytes.ToArray()
}
function Get-CanonicalStaticHash([string]$Path, [string]$Root) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash((Get-CanonicalStaticBytes -Path $Path -Root $Root)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-CanonicalStaticByteCount([string]$Root) {
    $total = [long]0
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $total += [long](Get-CanonicalStaticBytes -Path $file.FullName -Root $Root).Length
    }
    return $total
}
function Get-TreeHash([string]$Root) {
    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $records = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        [pscustomobject][ordered]@{
            path = $relative
            sha256 = if ($rootPath -match 'impeccable-static-html' -or $rootPath -match 'node_modules') { Get-CanonicalStaticHash -Path $_.FullName -Root $rootPath } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
        }
    })
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $records) { [void]$entries.Add($record) }
    $entries.Sort([System.Comparison[object]]{
        param($left, $right)
        return [StringComparer]::Ordinal.Compare([string]$left.path, [string]$right.path)
    })
    $canonical = @($entries | ForEach-Object { "$($_.path)|$($_.sha256)" })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($canonical -join "`n"))))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Convert-HexToBytes([string]$Hex) {
    Assert-True ($Hex -match '^[0-9a-f]+$' -and $Hex.Length % 2 -eq 0) "Invalid hexadecimal digest: $Hex"
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) { $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16) }
    return $bytes
}

$expected = [ordered]@{
    htmlparser2='12.0.0'; 'css-select'='7.0.0'; 'css-tree'='3.2.1'; domutils='4.0.2'; boolbase='2.0.0'
    'css-what'='8.0.0'; 'dom-serializer'='3.1.1'; domelementtype='3.0.0'; domhandler='6.0.1'
    entities='8.0.0'; 'mdn-data'='2.27.1'; 'nth-check'='3.0.1'; 'source-map-js'='1.2.1'
}

Assert-True ($lock.schemaVersion -eq 1 -and $lock.gate -ceq 'G7-SR3I-D3F') 'Dedicated lock identity drifted.'
Assert-True ($lock.upstream.commitSha -ceq '63b04e2530f5c7b41ea83c133daab24f34912456') 'Impeccable pin drifted.'
Assert-True ($lock.registryHost -ceq 'registry.npmjs.org' -and $lock.network.scheme -ceq 'https') 'Registry boundary drifted.'
Assert-True ($lock.network.totalHttpRequests -eq 26 -and $lock.network.redirects -eq 0) 'Network closeout evidence drifted.'
Assert-True (-not $lock.network.credentialsSent -and -not $lock.network.otherHostsContacted) 'Network authority boundary drifted.'
Assert-True (-not $lock.acquisition.packageManagerUsed -and -not $lock.acquisition.packageCodeExecuted -and -not $lock.acquisition.lifecycleScriptsExecuted) 'Acquisition execution boundary drifted.'
Assert-True ($lock.snapshot.path -ceq 'third_party/runtimes/impeccable-static-html') 'Snapshot path drifted.'
Assert-True ($lock.snapshot.moduleRoot -ceq 'third_party/runtimes/impeccable-static-html/node_modules') 'Closed module root drifted.'
Assert-True (@($lock.packages).Count -eq 13 -and $lock.snapshot.packageCount -eq 13) 'Package count is not exactly 13.'

$actualDirectories = @(Get-ChildItem -LiteralPath $moduleRoot -Directory -Force | ForEach-Object Name | Sort-Object)
$expectedDirectories = @($expected.Keys | Sort-Object)
Assert-True (($actualDirectories -join "`n") -ceq ($expectedDirectories -join "`n")) 'Snapshot contains a missing or additional package.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $snapshotRoot 'package.json'))) 'Snapshot root must not masquerade as a package or Skill.'
Assert-True (-not $snapshotRoot.StartsWith((Join-Path $repoRoot '.agents/skills'), [StringComparison]::OrdinalIgnoreCase)) 'Snapshot entered local Skill discovery.'
Assert-True (-not $snapshotRoot.StartsWith((Join-Path $repoRoot 'plugin/frontend-toolkit/skills'), [StringComparison]::OrdinalIgnoreCase)) 'Snapshot entered distribution Skill discovery.'
& git -C $repoRoot check-ignore -q -- 'third_party/runtimes/impeccable-static-html/node_modules/htmlparser2/package.json'
Assert-True ($LASTEXITCODE -eq 1) 'Canonical snapshot is not versionable due to an ignore rule.'

$allFiles = @(Get-ChildItem -LiteralPath $snapshotRoot -Recurse -File -Force)
Assert-True ($allFiles.Count -eq $lock.snapshot.fileCount) 'Snapshot file count drifted.'
Assert-True ((Get-CanonicalStaticByteCount $snapshotRoot) -eq [long]$lock.snapshot.bytes) 'Snapshot canonical byte count drifted.'
Assert-True ((Get-TreeHash $snapshotRoot) -ceq $lock.snapshot.treeSha256) 'Snapshot tree hash drifted.'
Assert-True (@(Get-ChildItem -LiteralPath $snapshotRoot -Recurse -Force -Attributes ReparsePoint).Count -eq 0) 'Snapshot contains a reparse point.'
Assert-True (@(Get-ChildItem -LiteralPath $moduleRoot -Recurse -Directory -Force | Where-Object Name -eq 'node_modules').Count -eq 0) 'Snapshot contains an unexpected nested node_modules.'

foreach ($package in @($lock.packages)) {
    Assert-True ($expected.Contains($package.name)) "Unexpected lock package: $($package.name)"
    Assert-True ($package.version -ceq $expected[$package.name]) "Version drift: $($package.name)"
    Assert-True ($package.registryHost -ceq 'registry.npmjs.org') "Registry host drift: $($package.name)"
    $tarball = [Uri]$package.canonicalTarballUrl
    Assert-True ($tarball.Scheme -ceq 'https' -and $tarball.Host -ceq 'registry.npmjs.org') "Unapproved tarball origin: $($package.name)"
    Assert-True ($package.registryIntegrity -ceq $package.bunLockIntegrity) "Registry/bun.lock SRI mismatch: $($package.name)"
    $computedSri = 'sha512-' + [Convert]::ToBase64String((Convert-HexToBytes $package.tarballSha512))
    Assert-True ($computedSri -ceq $package.registryIntegrity) "Locked tarball SHA-512 does not encode to SRI: $($package.name)"
    Assert-True ($package.tarballSha256 -match '^[0-9a-f]{64}$') "Missing tarball SHA-256: $($package.name)"

    $packageRoot = Join-Path $moduleRoot $package.name
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'package.json') | ConvertFrom-Json
    Assert-True ($manifest.name -ceq $package.name -and $manifest.version -ceq $package.version) "Manifest identity drift: $($package.name)"
    Assert-True ((Get-TreeHash $packageRoot) -ceq $package.extractedCanonicalTreeSha256) "Package tree drift: $($package.name)"
    Assert-True (@(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Force).Count -eq $package.fileCount) "Package file count drift: $($package.name)"
    $licensePath = Join-Path $repoRoot $package.licenseFilePath
    Assert-True (Test-Path -LiteralPath $licensePath -PathType Leaf) "License file missing: $($package.name)"
    Assert-True ((Get-CanonicalStaticHash $licensePath $snapshotRoot) -ceq $package.licenseFileSha256) "License hash drift: $($package.name)"
    Assert-True ($manifest.license -ceq $package.licenseIdentifier) "License identifier drift: $($package.name)"

    $manifestEdges = @(); $dependencies = $manifest.psobject.Properties['dependencies']; if ($dependencies -and $dependencies.Value) { $manifestEdges = @($dependencies.Value.psobject.Properties | ForEach-Object { "$($_.Name)|$($_.Value)" } | Sort-Object) }
    $lockedEdges = @($package.dependencyEdges | ForEach-Object { "$($_.name)|$($_.range)" } | Sort-Object)
    Assert-True (($manifestEdges -join "`n") -ceq ($lockedEdges -join "`n")) "Dependency edge drift: $($package.name)"
    foreach ($edge in @($package.dependencyEdges)) {
        Assert-True ($expected.Contains($edge.name)) "Dependency escapes snapshot: $($package.name) -> $($edge.name)"
        Assert-True ($edge.resolvedVersion -ceq $expected[$edge.name]) "Resolved edge drift: $($package.name) -> $($edge.name)"
        Assert-True (Test-Path -LiteralPath (Join-Path $moduleRoot $edge.name) -PathType Container) "Dependency does not close in snapshot: $($edge.name)"
    }
    $bin = $manifest.psobject.Properties['bin']; $gypfile = $manifest.psobject.Properties['gypfile']
    Assert-True ((-not $bin -or -not $bin.Value) -and (-not $gypfile -or -not $gypfile.Value)) "Native/binary declaration appeared: $($package.name)"
    $optional = $manifest.psobject.Properties['optionalDependencies']; $bundled = $manifest.psobject.Properties['bundledDependencies']
    Assert-True ((-not $optional -or -not $optional.Value) -and (-not $bundled -or -not $bundled.Value)) "Optional/bundled dependency appeared: $($package.name)"
    $scripts = $manifest.psobject.Properties['scripts']
    if ($scripts -and $scripts.Value) { foreach ($lifecycle in 'preinstall','install','postinstall') { Assert-True (-not $scripts.Value.psobject.Properties[$lifecycle]) "Install lifecycle appeared: $($package.name)/$lifecycle" } }
}

$codeFiles = Get-ChildItem -LiteralPath $moduleRoot -Recurse -File | Where-Object { $_.Extension -in @('.js','.mjs','.cjs') }
$effectHits = @($codeFiles | Select-String -Pattern 'child_process|node:child_process|process\.env|node:fs|node:https|node:http|XMLHttpRequest|WebSocket|node-gyp|bindings\s*\(')
Assert-True ($effectHits.Count -eq 0) 'A forbidden effect marker appeared in canonical package code.'
$dynamicHits = @($codeFiles | Select-String -Pattern 'new\s+Function|\beval\s*\(')
Assert-True ($dynamicHits.Count -eq 1 -and $dynamicHits[0].Path.EndsWith('source-map-js\lib\quick-sort.js')) 'Dynamic-execution audit inventory drifted.'
$sourceMapImport = Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'css-tree/lib/generator/sourceMap.js')
Assert-True ($sourceMapImport.Contains("from 'source-map-js/lib/source-map-generator.js'")) 'css-tree source-map import closure drifted.'
$generatorCode = Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'source-map-js/lib/source-map-generator.js')
Assert-True (-not ($generatorCode -match 'quick-sort|new\s+Function|\beval\s*\(')) 'Reachable source-map generator gained dynamic execution.'


$impeccable = $externalLock.dependencies | Where-Object id -eq 'impeccable'
$upstreamRoot = Join-Path $repoRoot $impeccable.checkoutPath
Assert-True ($impeccable.commitSha -ceq $lock.upstream.commitSha) 'External and dependency lock pins disagree.'
Assert-True ((& git -C $upstreamRoot rev-parse HEAD | Out-String).Trim() -ceq $impeccable.commitSha) 'Impeccable checkout HEAD drifted.'
Assert-True ([string]::IsNullOrWhiteSpace((& git -C $upstreamRoot status --porcelain | Out-String))) 'Impeccable checkout is dirty.'
$auditRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ftk-d3f-upstream-' + [guid]::NewGuid().ToString('N').Substring(0,8))))
Assert-True ($auditRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) 'Audit temp root escaped system temp.'
$archivePath = Join-Path $auditRoot 'impeccable.tar'; $extractPath = Join-Path $auditRoot 'snapshot'
try {
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    Assert-SafeGitArchiveTree -Repository $upstreamRoot -Commit $impeccable.commitSha -Context 'pinned Impeccable audit tree' -Paths @('LICENSE', 'NOTICE.md', 'plugin/skills/impeccable')
    Export-CanonicalGitFiles -Repository $upstreamRoot -Commit $impeccable.commitSha -DestinationArchive $archivePath -CoreAutocrlf 'true' -Paths @('LICENSE', 'NOTICE.md', 'plugin/skills/impeccable')
    & tar -xf $archivePath -C $extractPath
    if ($LASTEXITCODE -ne 0) { throw 'Unable to extract pinned Impeccable audit tree.' }
    Assert-True ((Get-TreeHash $extractPath) -ceq $impeccable.snapshotTreeSha256) 'Upstream Impeccable snapshot bytes drifted.'
} finally { if (Test-Path -LiteralPath $auditRoot) { Remove-Item -LiteralPath $auditRoot -Recurse -Force } }

Write-Output "PASS: canonical static-HTML substrate contains exactly 13 closed, licensed, integrity-locked packages at tree $($lock.snapshot.treeSha256)."
Write-Output "PASS: pinned Impeccable snapshot remains byte-identical at $($impeccable.snapshotTreeSha256)."
