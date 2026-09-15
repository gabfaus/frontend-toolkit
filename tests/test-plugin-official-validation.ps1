param([switch]$Execute)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/toolchain.lock.json') | ConvertFrom-Json
$distribution = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/distribution.lock.json') | ConvertFrom-Json
$python = [Environment]::ExpandEnvironmentVariables(($toolchain.runtimes | Where-Object id -eq 'python').portableResolution)
$pluginValidator = Join-Path $env:USERPROFILE '.codex/skills/.system/plugin-creator/scripts/validate_plugin.py'
$skillValidator = Join-Path $env:USERPROFILE '.codex/skills/.system/skill-creator/scripts/quick_validate.py'

if (($toolchain.runtimes | Where-Object id -eq 'python').observedVersion -ne '3.14.7') { throw 'Validator Python pin drifted.' }
if ($distribution.validatorRuntime.temporaryDependency -ne 'PyYAML==6.0.3') { throw 'Validator dependency pin drifted.' }
if (-not (Test-Path -LiteralPath $pluginValidator) -or -not (Test-Path -LiteralPath $skillValidator)) { throw 'Official validators are unavailable.' }
if (-not $Execute) {
    Write-Output 'PASS: official validator paths and temporary runtime contract validated.'
    return
}

. (Join-Path $PSScriptRoot 'helpers/external-prerequisite.ps1')
Assert-FtkExternalPrerequisite

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('frontend-toolkit-validator-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$venv = Join-Path $fixture 'venv'
$snapshot = Join-Path $fixture 'snapshot/frontend-toolkit'
$oldPythonUtf8 = $env:PYTHONUTF8
try {
    $env:PYTHONUTF8 = '1'
    & $python -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Temporary validator venv creation failed.' }
    $venvPython = Join-Path $venv 'Scripts/python.exe'
    & $venvPython -m pip install --disable-pip-version-check --no-input PyYAML==6.0.3 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Temporary PyYAML installation failed.' }
    if ((& $venvPython -c 'import yaml; print(yaml.__version__)').Trim() -ne '6.0.3') { throw 'Temporary PyYAML version mismatch.' }

    & (Join-Path $repoRoot 'scripts/build-plugin-snapshot.ps1') -Destination $snapshot -DevelopmentWorkingTree | Out-Null
    & $venvPython $pluginValidator (Join-Path $repoRoot 'plugin/frontend-toolkit')
    if ($LASTEXITCODE -ne 0) { throw 'Official source plugin validation failed.' }
    & $venvPython $pluginValidator $snapshot
    if ($LASTEXITCODE -ne 0) { throw 'Official distribution plugin validation failed.' }
    & $venvPython $skillValidator (Join-Path $snapshot 'skills/frontend-orchestrator')
    if ($LASTEXITCODE -ne 0) { throw 'Official frontend-orchestrator validation failed.' }

    foreach ($adapterSkill in @('impeccable', 'img2threejs')) {
        & $venvPython $skillValidator (Join-Path $snapshot "skills/$adapterSkill")
        if ($LASTEXITCODE -ne 0) { throw "Official adapter validation failed for $adapterSkill." }
    }
    Write-Output 'PASS: canonical plugin validator accepted source and complete distribution.'
    Write-Output 'PASS: skill-creator accepted the orchestrator and external FTK-owned adapters; additional common adapters remain governed by the convergence allowlist.'
} finally {
    $env:PYTHONUTF8 = $oldPythonUtf8
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete('\\?\' + [IO.Path]::GetFullPath($fixture), $true) }
}
if (Test-Path -LiteralPath $fixture) { throw 'Validator fixture teardown failed.' }
Write-Output 'PASS: temporary validator venv teardown completed.'
