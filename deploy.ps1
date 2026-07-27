<#
.SYNOPSIS
    Deploy the rs2 skill to both Codex and Claude global skill directories.

.DESCRIPTION
    Copies SKILL.md and the references/ folder from this directory into:
      - %USERPROFILE%\.claude\skills\rs2
      - %USERPROFILE%\.codex\skills\rs2
    Existing target contents are replaced so deploys are clean.
#>
[CmdletBinding()]
param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$SkillName = 'rs2'
$Source    = $PSScriptRoot

# Files/folders that make up the skill.
$Items = @('SKILL.md', 'references')

# Validate source.
foreach ($item in $Items) {
    $p = Join-Path $Source $item
    if (-not (Test-Path $p)) {
        throw "Missing source item: $p"
    }
}

$Targets = @(
    (Join-Path $env:USERPROFILE ".claude\skills\$SkillName"),
    (Join-Path $env:USERPROFILE ".codex\skills\$SkillName")
)

foreach ($target in $Targets) {
    Write-Host "Deploying '$SkillName' -> $target"

    if ($WhatIf) {
        Write-Host "  [WhatIf] would refresh target" -ForegroundColor Yellow
        continue
    }

    # Clean target so removed files don't linger.
    if (Test-Path $target) {
        Remove-Item -Path $target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    foreach ($item in $Items) {
        $src = Join-Path $Source $item
        Copy-Item -Path $src -Destination $target -Recurse -Force
    }

    Write-Host "  done" -ForegroundColor Green
}

Write-Host "Skill '$SkillName' deployed to all targets."
