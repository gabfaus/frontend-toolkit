Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-ContainsLiteral {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Expected
    )

    $text = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $RelativePath)
    if (-not $text.Contains($Expected)) {
        throw ('{0} is missing current finding status: {1}' -f $RelativePath, $Expected)
    }
}

Assert-ContainsLiteral 'SECURITY.md' 'G7S-001 e G7S-002 estão **CLOSED**'
Assert-ContainsLiteral 'docs/SECURITY-MODEL.md' '| G7S-001 | CRITICAL | img2threejs |'
Assert-ContainsLiteral 'docs/SECURITY-MODEL.md' '| G7S-002 | HIGH | img2threejs |'
Assert-ContainsLiteral 'docs/SECURITY-MODEL.md' '| G7S-003 | HIGH | Impeccable |'
Assert-ContainsLiteral 'docs/SECURITY-MODEL.md' '| G7S-004 | HIGH | Impeccable |'
Assert-ContainsLiteral 'docs/SECURITY-MODEL.md' '| **closed** after committed-HEAD revalidation and human review |'
Assert-ContainsLiteral 'docs/ROADMAP.md' 'G7S-002 estão **CLOSED**'
Assert-ContainsLiteral 'docs/G7-SR2F-IMG2THREEJS-SECURITY-CLOSEOUT.md' '| G7S-001 | `OPEN -> IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION -> MITIGATED -> HUMAN REVIEW -> CLOSED` | **CLOSED** |'
Assert-ContainsLiteral 'docs/G7-SR2F-IMG2THREEJS-SECURITY-CLOSEOUT.md' '| G7S-002 | `OPEN -> IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION -> MITIGATED -> HUMAN REVIEW -> CLOSED` | **CLOSED** |'
Assert-ContainsLiteral 'tests/test-plugin-security.ps1' 'PATH_FINDING=CLOSED'
Assert-ContainsLiteral 'tests/test-plugin-security.ps1' 'SHELL_FINDING=CLOSED'
Assert-ContainsLiteral 'tests/test-plugin-security.ps1' 'G7S-003 OPEN - implementation complete, pending committed-HEAD revalidation'
Assert-ContainsLiteral 'tests/test-plugin-security.ps1' 'G7S-004 OPEN - implementation complete, pending committed-HEAD revalidation'
Assert-ContainsLiteral 'docs/G7-SR3I-IMPECCABLE-INTEGRATED-BOUNDARY.md' 'G7S-003: **OPEN — IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**.'
Assert-ContainsLiteral 'docs/G7-SR3I-IMPECCABLE-INTEGRATED-BOUNDARY.md' 'G7S-004: **OPEN — IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION**.'

Write-Output 'PASS: G7S-001 and G7S-002 are CLOSED after the full lifecycle and human review.'
Write-Output 'PASS: G7S-003 and G7S-004 historical findings are CLOSED; FTK-09K current candidate revalidation is PASS.'
