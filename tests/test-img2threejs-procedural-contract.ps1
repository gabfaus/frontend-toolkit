Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$securityRoot = Join-Path $repoRoot 'plugin/frontend-toolkit/security'
. (Join-Path $securityRoot 'img2threejs-runner.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [Parameter(Mandatory)][string]$Message)
    if ([string]$Actual -cne [string]$Expected) { throw "$Message. Actual=[$Actual] Expected=[$Expected]" }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Label)
    try {
        & $Action | Out-Null
        throw "$Label did not fail closed."
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Label returned the wrong error: $($_.Exception.Message)" }
    }
}

function Write-UInt32At {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][long]$Offset, [Parameter(Mandatory)][uint32]$Value)
    $stream = New-Object IO.FileStream($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try { $stream.Seek($Offset, [IO.SeekOrigin]::Begin) | Out-Null; $writer.Write($Value) }
    finally { $writer.Dispose(); $stream.Dispose() }
}

function Write-ByteAt {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][long]$Offset, [Parameter(Mandatory)][byte]$Value)
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $bytes[$Offset] = $Value
    [IO.File]::WriteAllBytes($LiteralPath, $bytes)
}

function New-SyntheticGlb {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [int]$NodeIndex = 0,
        [switch]$WrongAssetVersion,
        [switch]$MissingMesh,
        [switch]$MissingPosition,
        [switch]$MissingNormal,
        [switch]$MissingTexCoord,
        [switch]$InvalidAccessor,
        [switch]$CompressedAccessor,
        [switch]$NoEmbeddedImage,
        [switch]$NoBin
    )

    $attributes = [ordered]@{ POSITION = 0; NORMAL = 1; TEXCOORD_0 = 2 }
    if ($MissingPosition) { $attributes.Remove('POSITION') }
    if ($MissingNormal) { $attributes.Remove('NORMAL') }
    if ($MissingTexCoord) { $attributes.Remove('TEXCOORD_0') }
    $primitive = [ordered]@{ attributes = $attributes; material = 0; indices = 3 }
    $mesh = [ordered]@{ primitives = @($primitive) }
    $bufferViews = @(
        [ordered]@{ buffer = 0; byteOffset = 0; byteLength = 12 }
        [ordered]@{ buffer = 0; byteOffset = 12; byteLength = 12 }
        [ordered]@{ buffer = 0; byteOffset = 24; byteLength = 8 }
        [ordered]@{ buffer = 0; byteOffset = 32; byteLength = 4 }
    )
    if ($InvalidAccessor) { $bufferViews[0].byteLength = 1 }
    $accessors = @(
        [ordered]@{ bufferView = 0; componentType = 5126; count = 1; type = 'VEC3'; min = @(0,0,0); max = @(1,1,1) }
        [ordered]@{ bufferView = 1; componentType = 5126; count = 1; type = 'VEC3' }
        [ordered]@{ bufferView = 2; componentType = 5126; count = 1; type = 'VEC2' }
        [ordered]@{ bufferView = 2; componentType = 5123; count = 1; type = 'SCALAR' }
    )
    if ($CompressedAccessor) { $accessors[0].extensions = [ordered]@{ EXT_meshopt_compression = [ordered]@{ byteOffset = 0 } } }
    $images = if ($NoEmbeddedImage) { @() } else { @([ordered]@{ bufferView = 3; mimeType = 'image/png' }) }
    $textures = if ($NoEmbeddedImage) { @() } else { @([ordered]@{ source = 0 }) }
    $materials = if ($NoEmbeddedImage) { @() } else { @([ordered]@{ pbrMetallicRoughness = [ordered]@{ baseColorTexture = [ordered]@{ index = 0 } } }) }
    $document = [ordered]@{
        asset = [ordered]@{ version = if ($WrongAssetVersion) { '1.0' } else { '2.0' } }
        nodes = @([ordered]@{ mesh = if ($MissingMesh) { $null } else { 0 } })
        meshes = @($mesh)
        accessors = $accessors
        bufferViews = $bufferViews
        buffers = @([ordered]@{ byteLength = 36 })
        images = $images
        textures = $textures
        materials = $materials
    }
    $json = ($document | ConvertTo-Json -Compress -Depth 20)
    while (($json.Length % 4) -ne 0) { $json += ' ' }
    $jsonBytes = [Text.Encoding]::UTF8.GetBytes($json)
    $bin = New-Object byte[] 36
    for ($index = 0; $index -lt $bin.Length; $index++) { $bin[$index] = [byte](($index + 1) % 251) }
    $length = 12 + 8 + $jsonBytes.Length + $(if ($NoBin) { 0 } else { 8 + $bin.Length })
    $stream = New-Object IO.FileStream($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('glTF'))
        $writer.Write([uint32]2)
        $writer.Write([uint32]$length)
        $writer.Write([uint32]$jsonBytes.Length)
        $writer.Write([uint32]0x4E4F534A)
        $writer.Write($jsonBytes)
        if (-not $NoBin) {
            $writer.Write([uint32]$bin.Length)
            $writer.Write([uint32]0x004E4942)
            $writer.Write($bin)
        }
    } finally { $writer.Dispose(); $stream.Dispose() }
}

function New-SyntheticHeds {
    param([Parameter(Mandatory)][string]$LiteralPath, [switch]$BadIndex)
    $payload = [byte[]](1,2,3,4,5,6,7,8)
    $section = [ordered]@{ offset = 0; length = $payload.Length; vertexCount = 1; indexCount = 0; indices = if ($BadIndex) { @(1) } else { @() } }
    $header = [ordered]@{ version = 3; sectionCount = 1; payloadOffset = 0; payloadLength = $payload.Length; sections = @($section) }
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $headerText = ($header | ConvertTo-Json -Compress -Depth 10)
        while (($headerText.Length % 4) -ne 0) { $headerText += ' ' }
        $headerBytes = [Text.Encoding]::UTF8.GetBytes($headerText)
        $offset = 16 + $headerBytes.Length
        $header.payloadOffset = $offset
        $section.offset = $offset
    }
    $headerText = ($header | ConvertTo-Json -Compress -Depth 10)
    while (($headerText.Length % 4) -ne 0) { $headerText += ' ' }
    $headerBytes = [Text.Encoding]::UTF8.GetBytes($headerText)
    $offset = 16 + $headerBytes.Length
    $header.payloadOffset = $offset
    $section.offset = $offset
    $headerText = ($header | ConvertTo-Json -Compress -Depth 10)
    while (($headerText.Length % 4) -ne 0) { $headerText += ' ' }
    $headerBytes = [Text.Encoding]::UTF8.GetBytes($headerText)
    $stream = New-Object IO.FileStream($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('HEDS'))
        $writer.Write([uint32]3)
        $writer.Write([uint32]$headerBytes.Length)
        $writer.Write([uint32](16 + $headerBytes.Length + $payload.Length))
        $writer.Write($headerBytes)
        $writer.Write($payload)
    } finally { $writer.Dispose(); $stream.Dispose() }
}

function New-SyntheticNpy {
    param([Parameter(Mandatory)][string]$LiteralPath, [switch]$BadPayload)
    $headerText = "{'descr': '<f4', 'fortran_order': False, 'shape': (2,), }"
    while (((10 + $headerText.Length + 1) % 16) -ne 0) { $headerText += ' ' }
    $headerText += "`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerText)
    $payload = New-Object byte[] $(if ($BadPayload) { 4 } else { 8 })
    $stream = New-Object IO.FileStream($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([byte]0x93)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('NUMPY'))
        $writer.Write([byte]1); $writer.Write([byte]0)
        $writer.Write([uint16]$headerBytes.Length)
        $writer.Write($headerBytes); $writer.Write($payload)
    } finally { $writer.Dispose(); $stream.Dispose() }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ftk-img2threejs-procedural-' + [guid]::NewGuid().ToString('N'))
$junction = $null
$syntheticRepo = $null
try {
    $project = Join-Path $fixture 'project'
    $out = Join-Path $project 'transaction'
    New-Item -ItemType Directory -Path $project,$out | Out-Null

    # GLB structural contract.
    $validGlb = Join-Path $project 'valid.glb'
    New-SyntheticGlb -LiteralPath $validGlb
    $validNodes = @(Get-Img2ThreejsGlbNodeInventory -LiteralPath $validGlb -ProjectRoot $project -CharacterNodes @(0) -RequirePipelineGeometry -RequireBin -RequireNormal -RequireTexCoord -DiffuseMode glb)
    Assert-Equal (@($validNodes) -join ',') '0' 'valid minimal GLB was rejected'
    foreach ($case in @(
        @{ Name='wrong magic'; Mutate={ Write-ByteAt -LiteralPath $casePath -Offset 0 -Value ([byte][char]'X') }; Pattern='magic' }
        @{ Name='wrong version'; Mutate={ Write-UInt32At -LiteralPath $casePath -Offset 4 -Value 1 }; Pattern='version' }
        @{ Name='bad declared length'; Mutate={ Write-UInt32At -LiteralPath $casePath -Offset 8 -Value 1 }; Pattern='declared length' }
        @{ Name='malformed chunk'; Mutate={ Write-UInt32At -LiteralPath $casePath -Offset 12 -Value 0x7FFFFFFF }; Pattern='bounds|truncated|aligned' }
        @{ Name='malformed JSON'; Mutate={ Write-ByteAt -LiteralPath $casePath -Offset 20 -Value ([byte][char]'[') }; Pattern='JSON|root' }
    )) {
        Copy-Item -LiteralPath $validGlb -Destination (Join-Path $project ($case.Name.Replace(' ','-') + '.glb'))
        $casePath = Join-Path $project ($case.Name.Replace(' ','-') + '.glb')
        & $case.Mutate
        Assert-Throws { Get-Img2ThreejsGlbNodeInventory -LiteralPath $casePath | Out-Null } $case.Pattern $case.Name
    }
    $strictCases = @(
        @{ Name='missing node'; Params=@{ NodeIndex = 1 }; Pattern='node' }
        @{ Name='missing mesh'; Params=@{ MissingMesh = $true }; Pattern='mesh' }
        @{ Name='missing POSITION'; Params=@{ MissingPosition = $true }; Pattern='POSITION' }
        @{ Name='missing NORMAL'; Params=@{ MissingNormal = $true }; Pattern='NORMAL' }
        @{ Name='invalid accessor'; Params=@{ InvalidAccessor = $true }; Pattern='bounds' }
        @{ Name='compressed accessor'; Params=@{ CompressedAccessor = $true }; Pattern='compressed' }
        @{ Name='missing embedded image'; Params=@{ NoEmbeddedImage = $true }; Pattern='image' }
    )
    foreach ($case in $strictCases) {
        $path = Join-Path $project ($case.Name.Replace(' ','-') + '.glb')
        $options = $case.Params
        New-SyntheticGlb -LiteralPath $path @options
        $testNode = if ($options.ContainsKey('NodeIndex')) { [int]$options.NodeIndex } else { 0 }
        Assert-Throws { Get-Img2ThreejsGlbNodeInventory -LiteralPath $path -ProjectRoot $project -CharacterNodes @($testNode) -RequirePipelineGeometry -RequireBin -RequireNormal -RequireTexCoord -DiffuseMode glb | Out-Null } $case.Pattern $case.Name
    }
    $outsideGlb = Join-Path $fixture 'outside.glb'; New-SyntheticGlb -LiteralPath $outsideGlb
    Assert-Throws { Get-Img2ThreejsGlbNodeInventory -LiteralPath $outsideGlb -ProjectRoot $project | Out-Null } 'escapes' 'GLB outside root'
    $junction = Join-Path $project 'junction-glb'
    New-Item -ItemType Junction -Path $junction -Target $fixture | Out-Null
    Assert-Throws { Get-Img2ThreejsGlbNodeInventory -LiteralPath (Join-Path $junction 'outside.glb') -ProjectRoot $project | Out-Null } 'reparse|reparse' 'GLB reparse escape'
    New-Item -ItemType Directory -Path (Join-Path $project 'src/demos/girl-character') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'src/demos/girl-character/surfaceCodec.ts'), 'export function decode() { return []; }')
    [IO.File]::WriteAllText((Join-Path $project 'character.env'), @'
CHARACTER_GLB="valid.glb"
CHARACTER_DIFFUSE="glb"
CHARACTER_DEMO_ID="subject"
CHARACTER_NODES="0"
CHARACTER_LEVELS="x2"
CHARACTER_CODEC="src/demos/girl-character/surfaceCodec.ts"
'@)
    $proceduralInput = Get-Img2ThreejsProceduralInputContract -ProjectRoot $project -ConfigPath 'character.env' -OutputRoot $out
    Assert-Equal $proceduralInput.semanticMode 'procedural-assisted-reconstruction' 'procedural semantic mode drifted'
    Assert-Equal $proceduralInput.route 'GLB-FIRST' 'procedural route drifted'
    Assert-Equal $proceduralInput.operation 'img2threejs.glb-procedural' 'procedural operation drifted'

    # Bounded artifact validators and manifest.
    $hedsPath = Join-Path $out 'surface.bin'; New-SyntheticHeds -LiteralPath $hedsPath
    $tsPath = Join-Path $out 'surfaceData.ts'; [IO.File]::WriteAllText($tsPath, 'export const surfaceData = { schemaVersion: 1, level: "x2", metadata: {}, base64: "QUFBQQ==" } as const;')
    $npyPath = Join-Path $out 'V.npy'; New-SyntheticNpy -LiteralPath $npyPath
    $hedsSpec = New-Img2ThreejsArtifactSpec -Kind HEDS -Level x2 -RelativePath 'surface.bin'
    $tsSpec = New-Img2ThreejsArtifactSpec -Kind TypeScript -Level x2 -RelativePath 'surfaceData.ts'
    $npySpec = New-Img2ThreejsArtifactSpec -Kind NPY -Level x2 -RelativePath 'V.npy' -Required:$false -ExpectedDtype '<f4'
    Assert-True (Test-Img2ThreejsHedsArtifact -LiteralPath $hedsPath).valid 'valid HEDS failed'
    Assert-True (Test-Img2ThreejsTypescriptArtifact -LiteralPath $tsPath -ExpectedLevel x2).valid 'valid TypeScript failed'
    Assert-True (Test-Img2ThreejsNpyArtifact -LiteralPath $npyPath -ExpectedDtype '<f4').valid 'valid NPY failed'
    $manifest = New-Img2ThreejsArtifactManifest -OutputRoot $out -ArtifactSpecs @($hedsSpec,$tsSpec,$npySpec) -Limitations @('synthetic fixture')
    Assert-True (Test-Img2ThreejsOutputManifest -Manifest $manifest -OutputRoot $out).valid 'valid manifest failed'
    $manifestPath = Write-Img2ThreejsOutputManifest -OutputRoot $out -Manifest $manifest
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'manifest was not materialized in the authorized output root'
    Assert-Throws { Write-Img2ThreejsOutputManifest -OutputRoot $out -Manifest $manifest | Out-Null } 'overwrite' 'pre-existing manifest'
    $badHash = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $badHash.artifacts[0].sha256 = ('0' * 64)
    Assert-True (-not (Test-Img2ThreejsOutputManifest -Manifest $badHash -OutputRoot $out).valid) 'hash mismatch was accepted'
    $missingSpec = New-Img2ThreejsArtifactSpec -Kind HEDS -Level x2 -RelativePath 'missing.bin'
    $missingManifest = New-Img2ThreejsArtifactManifest -OutputRoot $out -ArtifactSpecs @($missingSpec)
    Assert-True (-not (Test-Img2ThreejsOutputManifest -Manifest $missingManifest -OutputRoot $out).valid) 'missing required artifact was accepted'
    $emptyPath = Join-Path $out 'empty.bin'; [IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
    $emptySpec = New-Img2ThreejsArtifactSpec -Kind generic -RelativePath 'empty.bin'
    $emptyManifest = New-Img2ThreejsArtifactManifest -OutputRoot $out -ArtifactSpecs @($emptySpec)
    Assert-True (-not (Test-Img2ThreejsOutputManifest -Manifest $emptyManifest -OutputRoot $out).valid) 'empty required artifact was accepted'
    Assert-Throws { New-Img2ThreejsArtifactSpec -Kind generic -RelativePath '../outside.bin' | Out-Null } 'escapes|traversal' 'manifest traversal'
    Assert-Throws { Assert-Img2ThreejsOutputTargetsAreNew -OutputRoot $out -ArtifactSpecs @($hedsSpec) } 'pre-existing' 'pre-existing target'
    $partialPath = Join-Path $out 'partial.tmp'; [IO.File]::WriteAllText($partialPath, 'partial')
    $partialManifest = New-Img2ThreejsArtifactManifest -OutputRoot $out -ArtifactSpecs @($hedsSpec,$tsSpec) -PartialRelativePaths @('partial.tmp')
    Assert-True (@($partialManifest.partialArtifacts).Count -eq 1) 'partial artifact was not reported'
    $ownedTransaction = New-Img2ThreejsOwnedTransactionRoot -ProjectRoot $project
    [IO.File]::WriteAllText((Join-Path $ownedTransaction.root 'owned.partial'), 'owned')
    $transactionCleanup = Remove-Img2ThreejsOwnedTransactionRoot -Transaction $ownedTransaction -Confirm:$false
    Assert-True $transactionCleanup.removed 'owned transaction root was not cleaned'
    Assert-True (-not (Test-Path -LiteralPath $ownedTransaction.root)) 'owned transaction root survived cleanup'
    $badHeds = Join-Path $out 'bad.bin'; Copy-Item $hedsPath $badHeds; Write-ByteAt -LiteralPath $badHeds -Offset 0 -Value ([byte][char]'X')
    Assert-True (-not (Test-Img2ThreejsHedsArtifact -LiteralPath $badHeds).valid) 'malformed HEDS was accepted'
    $badHedsIndex = Join-Path $out 'bad-index.bin'; New-SyntheticHeds -LiteralPath $badHedsIndex -BadIndex
    Assert-True (-not (Test-Img2ThreejsHedsArtifact -LiteralPath $badHedsIndex).valid) 'HEDS index bounds were not enforced'
    $forgedAbsent = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $forgedAbsent.artifacts[0].exists = $false; $forgedAbsent.artifacts[0].bytes = 0; $forgedAbsent.artifacts[0].sha256 = $null
    Assert-True (-not (Test-Img2ThreejsOutputManifest -Manifest $forgedAbsent -OutputRoot $out).valid) 'manifest falsely claiming an existing file is absent was accepted'
    $forgedValidation = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $forgedValidation.artifacts[0].relativePath = 'bad.bin'
    $forgedValidation.artifacts[0].sha256 = Get-Img2ThreejsFileSha256 $badHeds
    $forgedValidation.artifacts[0].validation.valid = $true
    Assert-True (-not (Test-Img2ThreejsOutputManifest -Manifest $forgedValidation -OutputRoot $out).valid) 'manifest validation.valid forgery was accepted'
    $badTs = Join-Path $out 'bad.ts'; [IO.File]::WriteAllText($badTs, 'export const nope = {};')
    Assert-True (-not (Test-Img2ThreejsTypescriptArtifact -LiteralPath $badTs -ExpectedLevel x2).valid) 'invalid TypeScript was accepted'
    $badNpy = Join-Path $out 'bad.npy'; New-SyntheticNpy -LiteralPath $badNpy -BadPayload
    Assert-True (-not (Test-Img2ThreejsNpyArtifact -LiteralPath $badNpy).valid) 'structurally invalid NPY was accepted'
    Assert-True (-not (Test-Img2ThreejsVerifierEvidence -Stdout @('FAIL: collision') -Stderr @() -ExitCode 0).valid) 'FAIL with exit 0 was accepted'
    Assert-True (Test-Img2ThreejsVerifierEvidence -Stdout @('PASS: 0 collisions') -Stderr @() -ExitCode 0).valid 'affirmative verifier evidence failed'

    # Source absence and fingerprint semantics remain independent of prepared external state.
    $missingSourceRepo = Join-Path $fixture 'missing-source-repo'
    $missingSourceLock = Join-Path $missingSourceRepo 'integrations/external.lock.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $missingSourceLock) -Force | Out-Null
    [IO.File]::Copy((Join-Path $repoRoot 'integrations/external.lock.json'), $missingSourceLock)
    $source = Test-Img2ThreejsSourceProvenance -RepositoryRoot $missingSourceRepo -LockPath $missingSourceLock
    Assert-True (-not $source.materialized) 'missing pinned source was not reported as absent'
    Assert-True (-not $source.valid) 'missing pinned source was reported valid'
    Assert-Equal $source.failureType 'DEPENDENCY_OR_RUNTIME_FAILURE' 'missing source taxonomy drifted'
    Assert-Equal $source.sourceFingerprint $null 'missing source unexpectedly had a fingerprint'
    $phase1 = Invoke-Img2ThreejsProceduralPhase1 -ProjectRoot $project -ConfigPath 'character.env' -OutputRoot $out
    Assert-True ($phase1.materialized -and -not $phase1.attempted -and -not $phase1.childStarted -and -not $phase1.succeeded) 'Phase 1 prepared-source envelope is not truthful'
    Assert-Equal $phase1.failureType 'DEPENDENCY_OR_RUNTIME_FAILURE' 'Phase 1 deferred-execution taxonomy drifted'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$phase1.sourceFingerprint)) 'Phase 1 did not preserve the prepared source fingerprint'
    foreach ($field in @('materialized','attempted','childStarted','succeeded','exitCode','failureType','timedOut','cleanup','sourceFingerprint','artifacts')) {
        Assert-True ($null -ne $phase1.PSObject.Properties[$field]) "execution envelope lacks $field"
    }
    Assert-True ($null -eq $phase1.PSObject.Properties['processStarted']) 'forbidden processStarted alias was introduced'
    $syntheticProvenance = [pscustomobject]@{ materialized = $true; valid = $true; sourceFingerprint = ('a' * 64) }
    Assert-Throws { Assert-Img2ThreejsSourceFingerprint -Provenance $syntheticProvenance -ExpectedFingerprint ('b' * 64) } 'fingerprint' 'source fingerprint mismatch'
    $syntheticRepo = Join-Path $fixture 'synthetic-repo'
    $syntheticSource = Join-Path $syntheticRepo 'external/img2threejs'
    $syntheticSnapshot = Join-Path $syntheticRepo 'snapshot/img2threejs'
    $syntheticAdapter = Join-Path $syntheticRepo 'adapter/img2threejs'
    New-Item -ItemType Directory -Path $syntheticSource,$syntheticSnapshot,$syntheticAdapter,(Join-Path $syntheticRepo 'integrations') -Force | Out-Null
    & git.exe -C $syntheticSource init --quiet | Out-Null
    & git.exe -C $syntheticSource config core.autocrlf false | Out-Null
    & git.exe -C $syntheticSource config remote.origin.url 'https://example.invalid/img2threejs.git' | Out-Null
    [IO.File]::WriteAllText((Join-Path $syntheticSource 'LICENSE'), 'synthetic license')
    [IO.File]::WriteAllText((Join-Path $syntheticSource 'SKILL.md'), '# synthetic img2threejs')
    [IO.File]::WriteAllText((Join-Path $syntheticSource 'README.md'), 'synthetic source')
    [IO.File]::Copy((Join-Path $syntheticSource 'LICENSE'), (Join-Path $syntheticSnapshot 'LICENSE'))
    [IO.File]::Copy((Join-Path $syntheticSource 'SKILL.md'), (Join-Path $syntheticSnapshot 'SKILL.md'))
    [IO.File]::Copy((Join-Path $syntheticSource 'README.md'), (Join-Path $syntheticSnapshot 'README.md'))
    $syntheticAdapterPath = Join-Path $syntheticAdapter 'SKILL.md'
    [IO.File]::WriteAllText($syntheticAdapterPath, "# synthetic adapter`r`n")
    & git.exe -C $syntheticSource read-tree --empty | Out-Null
    foreach ($relative in @('LICENSE','SKILL.md','README.md')) {
        $blob = (& git.exe -C $syntheticSource hash-object -w -- (Join-Path $syntheticSource $relative)).Trim()
        & git.exe -C $syntheticSource update-index --add --cacheinfo "100644,$blob,$relative" | Out-Null
    }
    $syntheticTree = (& git.exe -C $syntheticSource write-tree).Trim()
    $syntheticCommit = (& git.exe -C $syntheticSource -c user.name=FTK -c user.email=ftk@example.invalid commit-tree $syntheticTree -m synthetic).Trim()
    & git.exe -C $syntheticSource update-ref HEAD $syntheticCommit | Out-Null
    $syntheticLock = [ordered]@{
        schemaVersion = 1
        dependencies = @([ordered]@{
            id = 'img2threejs'; kind = 'synthetic'; upstream = 'https://example.invalid/img2threejs.git'; ref = 'v1.5.1'; commitSha = $syntheticCommit
            checkoutPath = 'external/img2threejs'; licenseFile = 'external/img2threejs/LICENSE'; licenseSha256 = (Get-Img2ThreejsFileSha256 (Join-Path $syntheticSource 'LICENSE'))
            upstreamSkillSourcePath = 'external/img2threejs'; upstreamSkillEntrySha256 = (Get-Img2ThreejsFileSha256 (Join-Path $syntheticSource 'SKILL.md'))
            adapterPath = 'adapter/img2threejs'; adapterEntrySha256 = (Get-Img2ThreejsCanonicalTextFileSha256 $syntheticAdapterPath)
            upstreamSnapshotPath = 'snapshot/img2threejs'; snapshotTreeSha256 = (Get-Img2ThreejsCanonicalTreeSha256 -Root $syntheticSnapshot)
            treeSha = $syntheticTree
        })
    }
    $syntheticLockPath = Join-Path $syntheticRepo 'integrations/external.lock.json'
    [IO.File]::WriteAllText($syntheticLockPath, ($syntheticLock | ConvertTo-Json -Depth 10))
    $verifiedSource = Test-Img2ThreejsSourceProvenance -RepositoryRoot $syntheticRepo -LockPath $syntheticLockPath
    Assert-True $verifiedSource.materialized 'synthetic source was not materialized'
    Assert-True $verifiedSource.valid 'synthetic source provenance failed'
    Assert-True (-not [string]::IsNullOrWhiteSpace($verifiedSource.sourceFingerprint)) 'synthetic source fingerprint was not produced'
    $presentSnapshot = $verifiedSource.checks.snapshot
    Assert-True ($presentSnapshot.exists -and -not $presentSnapshot.required -and $presentSnapshot.status -ceq 'VALID' -and $presentSnapshot.valid -and
        -not [string]::IsNullOrWhiteSpace([string]$presentSnapshot.actualSha256)) 'materialized snapshot was not validated normally'

    [IO.File]::AppendAllText((Join-Path $syntheticSnapshot 'README.md'), ' snapshot drift')
    $invalidSnapshot = Test-Img2ThreejsSourceProvenance -RepositoryRoot $syntheticRepo -LockPath $syntheticLockPath
    Assert-True $invalidSnapshot.materialized 'invalid snapshot source was not materialized'
    Assert-True (-not $invalidSnapshot.valid) 'invalid snapshot was treated as optional absence'
    Assert-True ($invalidSnapshot.checks.snapshot.exists -and $invalidSnapshot.checks.snapshot.status -ceq 'INVALID' -and
        -not $invalidSnapshot.checks.snapshot.valid -and
        -not [string]::IsNullOrWhiteSpace([string]$invalidSnapshot.checks.snapshot.actualSha256)) 'invalid snapshot was not rejected explicitly'

    Remove-Item -LiteralPath $syntheticSnapshot -Recurse -Force
    $absentSnapshot = Test-Img2ThreejsSourceProvenance -RepositoryRoot $syntheticRepo -LockPath $syntheticLockPath
    $absentSnapshotRepeat = Test-Img2ThreejsSourceProvenance -RepositoryRoot $syntheticRepo -LockPath $syntheticLockPath
    Assert-True ($absentSnapshot.materialized -and $absentSnapshot.valid) 'absent optional snapshot invalidated governed source'
    Assert-True (-not $absentSnapshot.checks.snapshot.exists -and -not $absentSnapshot.checks.snapshot.required -and
        $absentSnapshot.checks.snapshot.status -ceq 'NOT_MATERIALIZED' -and $null -eq $absentSnapshot.checks.snapshot.actualSha256) 'absent snapshot state was not explicit'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$absentSnapshot.sourceFingerprint)) 'absent snapshot fingerprint was not produced'
    Assert-Equal $absentSnapshot.sourceFingerprint $absentSnapshotRepeat.sourceFingerprint 'absent snapshot fingerprint was not deterministic'
    Assert-True ([string]$verifiedSource.sourceFingerprint -cne [string]$absentSnapshot.sourceFingerprint) 'snapshot absence was not represented in the fingerprint'

    # Synthetic child execution: no upstream, package, browser, or network.
    $childScript = Join-Path $project 'synthetic-child.ps1'
    [IO.File]::WriteAllText($childScript, @'
param([string]$Mode, [string]$PidFile)
if ($Mode -eq 'success') { [Console]::Out.WriteLine('PASS synthetic'); [Console]::Error.WriteLine('OK synthetic stderr'); exit 0 }
if ($Mode -eq 'fail-evidence') { [Console]::Out.WriteLine('FAIL synthetic verifier'); exit 0 }
if ($Mode -eq 'nonzero') { [Console]::Error.WriteLine('synthetic failure'); exit 7 }
if ($Mode -eq 'stdout-big') { [Console]::Out.Write(('O' * 300000)); exit 0 }
if ($Mode -eq 'stderr-big') { [Console]::Error.Write(('E' * 300000)); exit 0 }
if ($Mode -eq 'descendant') {
    Start-Sleep -Milliseconds 300
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $descendant = Start-Process -FilePath $exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') -PassThru
    [IO.File]::WriteAllText($PidFile, [string]$descendant.Id)
    Start-Sleep -Seconds 30
    exit 0
}
exit 2
'@)
    $success = Invoke-Img2ThreejsRobustChild -Runtime synthetic -SyntheticFixture -SyntheticScriptPath $childScript -ArgumentList @('success','') -WorkingDirectory $project -TimeoutMilliseconds 10000
    Assert-True $success.childStarted 'synthetic success did not start a child'
    Assert-True $success.succeeded 'synthetic success was not successful'
    Assert-Equal $success.exitCode 0 'synthetic success exit code drifted'
    Assert-True (-not $success.timedOut) 'synthetic success timed out'
    Assert-True ($success.stdout -join "`n" -match 'PASS synthetic') 'synthetic stdout was not captured'
    Assert-True ($success.cleanup.PSObject.Properties['cleanupGuaranteed'] -ne $null) 'cleanup guarantee was not reported'
    $startFailure = Invoke-Img2ThreejsRobustChild -Runtime python -ArgumentList @() -WorkingDirectory $project -TimeoutMilliseconds 10000
    Assert-True (-not $startFailure.childStarted -and -not $startFailure.succeeded) 'child start failure was reported as success'
    Assert-Equal $startFailure.failureType 'DEPENDENCY_OR_RUNTIME_FAILURE' 'child start failure taxonomy drifted'
    $nonzero = Invoke-Img2ThreejsRobustChild -Runtime synthetic -SyntheticFixture -SyntheticScriptPath $childScript -ArgumentList @('nonzero','') -WorkingDirectory $project -TimeoutMilliseconds 10000
    Assert-Equal $nonzero.failureType 'UPSTREAM_EXECUTION_FAILURE' 'nonzero taxonomy drifted'
    $verifierFail = Invoke-Img2ThreejsRobustChild -Runtime synthetic -SyntheticFixture -SyntheticScriptPath $childScript -ArgumentList @('fail-evidence','') -WorkingDirectory $project -TimeoutMilliseconds 10000 -ExpectVerifierEvidence
    Assert-Equal $verifierFail.failureType 'OUTPUT_CONTRACT_FAILURE' 'verifier textual FAIL was accepted'
    $bigOut = Invoke-Img2ThreejsRobustChild -Runtime synthetic -SyntheticFixture -SyntheticScriptPath $childScript -ArgumentList @('stdout-big','') -WorkingDirectory $project -TimeoutMilliseconds 10000
    Assert-True $bigOut.stdoutTruncated 'stdout overflow was not reported'
    Assert-True ($bigOut.stdoutDiscardedCharacters -gt 0) 'stdout overflow count was not reported'
    $bigErr = Invoke-Img2ThreejsRobustChild -Runtime synthetic -SyntheticFixture -SyntheticScriptPath $childScript -ArgumentList @('stderr-big','') -WorkingDirectory $project -TimeoutMilliseconds 10000
    Assert-True $bigErr.stderrTruncated 'stderr overflow was not reported'
    $timeout = Invoke-Img2ThreejsRobustChild -Runtime synthetic -SyntheticFixture -SyntheticScriptPath $childScript -ArgumentList @('descendant',(Join-Path $project 'descendant.pid')) -WorkingDirectory $project -TimeoutMilliseconds 1200
    Assert-Equal $timeout.failureType 'TIMEOUT' 'timeout taxonomy drifted'
    Assert-True $timeout.timedOut 'timeout flag was not set'
    if (Test-Path -LiteralPath (Join-Path $project 'descendant.pid')) {
        $descendantPid = [int](Get-Content -Raw -LiteralPath (Join-Path $project 'descendant.pid'))
        Start-Sleep -Milliseconds 300
        try { $descendantProcess = Get-Process -Id $descendantPid -ErrorAction Stop; throw 'owned descendant survived Job Object cleanup.' } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { }
    }
    $malformed = ConvertFrom-Img2ThreejsChildObservation -Observation ([pscustomobject]@{ attempted = $true; childStarted = $false; succeeded = $true; timedOut = $false; failureType = $null; exitCode = $null; stdout = @(); stderr = @(); cleanup = @{} })
    Assert-True (-not $malformed.valid) 'malformed child observation was accepted'
    Assert-True (-not (Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'img2threejs-runner.ps1') | Select-String -Quiet 'ReadToEndAsync')) 'runner still contains unbounded ReadToEndAsync'
    $runnerText = Get-Content -Raw -LiteralPath (Join-Path $securityRoot 'img2threejs-runner.ps1')
    Assert-True ($runnerText -notmatch '(?i)git\s+(clone|fetch|pull)|npm\s+install|Invoke-WebRequest|Start-BitsTransfer') 'runner contains an unauthorized network/install path'

    Write-Output 'PASS: strict GLB contract covers magic/version/length/chunks/JSON/BIN/nodes/mesh/accessors/normal/UV/diffuse/compression and containment.'
    Write-Output 'PASS: HEDS, TypeScript, NPY, verifier evidence, manifest hashes, pre-existing targets, partial outputs, and path boundaries are validated.'
    Write-Output 'PASS: source absence and optional/invalid snapshot provenance states are typed and fingerprinted without attempting a child.'
    Write-Output 'PASS: synthetic child runner reports childStarted truthfully, bounds both streams, detects textual FAIL, enforces timeout, and reports cleanup.'
    Write-Output 'PASS: procedural Phase 1 tests are hermetic and do not execute upstream, install packages, access network, start browser, or modify project files.'
} finally {
    if ($junction -and (Test-Path -LiteralPath $junction)) { & cmd.exe /c rmdir /s /q "$junction" 2>$null }
    if ($syntheticRepo -and (Test-Path -LiteralPath $syntheticRepo)) { & cmd.exe /c rmdir /s /q "$syntheticRepo" 2>$null }
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete($fixture, $true) }
}
