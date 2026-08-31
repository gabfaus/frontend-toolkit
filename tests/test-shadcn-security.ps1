Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'integrations/mcp.lock.json') | ConvertFrom-Json
$shadcn = $lock.servers | Where-Object id -eq 'shadcn'
if ($shadcn.package -ne 'shadcn' -or $shadcn.version -ne '4.19.0') { throw 'Unexpected Shadcn package pin.' }
if ($shadcn.registry -ne 'https://registry.npmjs.org/' -or [string]::IsNullOrWhiteSpace($shadcn.integrity)) {
    throw 'Shadcn registry or integrity provenance is incomplete.'
}
if (@($shadcn.secretsRequiredForDefaultRegistry).Count -ne 0) { throw 'Default Shadcn registry unexpectedly requires a credential.' }

$helper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests/helpers/shadcn-mcp-smoke.mjs')
if ($helper -notmatch 'registries:\s*\[\s*''@shadcn''\s*\]') { throw 'Read-only Shadcn helper does not select the trusted registry explicitly.' }
if ($helper -match '(?i)authorization|process\.env\..*(token|key|secret)|headers\s*:') {
    throw 'Read-only Shadcn helper contains credential or header forwarding behavior.'
}

$pluginMcp = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'plugin/frontend-toolkit/.mcp.json') | ConvertFrom-Json
$shadcnConfig = $pluginMcp.mcpServers.shadcn
if (@($shadcnConfig.args) -join ' ' -ne '--yes shadcn@4.19.0 mcp') { throw 'Plugin Shadcn command is not exactly pinned.' }
$configuredEnvironmentNames = @($shadcnConfig.env.PSObject.Properties.Name)
if (@($configuredEnvironmentNames).Count -ne 1 -or $configuredEnvironmentNames[0] -ne 'NODE_OPTIONS') {
    throw 'Plugin Shadcn configuration maps an unexpected environment value.'
}

$fixtureJson = @'
{
  'registries': {
    '@untrusted': {
      'url': 'https://invalid.example/{name}.json',
      'headers': {
        'X-Synthetic-Header-Name': '${SYNTHETIC_ENV_NAME_ONLY}'
      }
    }
  }
}
'@
$fixture = $fixtureJson.Replace([char]39, [char]34) | ConvertFrom-Json
$registryConfig = $fixture.registries.'@untrusted'
if ($registryConfig.url -ne 'https://invalid.example/{name}.json') { throw 'Synthetic registry fixture parsing failed.' }
$headerProperties = @($registryConfig.headers.PSObject.Properties)
if ($headerProperties.Count -ne 1 -or $headerProperties[0].Name -ne 'X-Synthetic-Header-Name') {
    throw 'Synthetic header-name inventory failed.'
}
if ($headerProperties[0].Value -notmatch '^\$\{[A-Z0-9_]+\}$') { throw 'Synthetic environment-reference syntax was not recognized as data.' }

$policies = @(
    (Join-Path $repoRoot '.agents/skills/frontend-orchestrator/references/routing-policy.json')
    (Join-Path $repoRoot 'plugin/frontend-toolkit/skills/frontend-orchestrator/references/routing-policy.json')
)
foreach ($policyPath in $policies) {
    $policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
    if ($policy.untrustedContentPolicy.sources -notcontains 'project-files') { throw 'Project configuration is not classified as untrusted.' }
    foreach ($requiredDenial in @('elevate-permission', 'authorize-secret-access', 'authorize-exfiltration')) {
        if ($policy.untrustedContentPolicy.cannot -notcontains $requiredDenial) { throw ('Missing Shadcn security denial: ' + $requiredDenial) }
    }
}

if (Test-Path Env:SYNTHETIC_ENV_NAME_ONLY) { throw 'The static test must not define or read a synthetic environment value.' }
Write-Output 'PASS: Shadcn package, version, registry and integrity are pinned; the default registry requires no secret.'
Write-Output 'PASS: the existing read-only smoke explicitly selects @shadcn and has no header or credential forwarding path.'
Write-Output 'PASS: plugin configuration maps only NODE_OPTIONS; untrusted registry/header syntax remained inert data.'
Write-Output 'DYNAMIC TEST NOT EXECUTED  STATIC/DEFENSIVE REVIEW COMPLETED'
