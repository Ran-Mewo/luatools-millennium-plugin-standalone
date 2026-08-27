<#
.SYNOPSIS
  Extract the installed LuaTools Millennium plugin for inspection.

.DESCRIPTION
  Millennium 3.4+ plugins are compiled into a single .star file. This script copies that file to the
  repository root so it can be inspected with 'starlight inspect' or 'starlight verify'.
#>

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LivePlugin = "K:\Steam client\millennium\plugins\luatools.star"
$Destination = Join-Path $RepoRoot "luatools.star"

if (-not (Test-Path $LivePlugin)) {
    Write-Error "Installed plugin not found at $LivePlugin"
}

Copy-Item $LivePlugin $Destination -Force
Write-Host "Copied $LivePlugin to $Destination" -ForegroundColor Green
