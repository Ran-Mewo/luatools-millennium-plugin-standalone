<#
.SYNOPSIS
  Build and install the LuaTools Millennium plugin.

.DESCRIPTION
  Compiles the plugin to the Millennium 3.4+ .star format and installs the result in the live Millennium
  plugin directory. The existing plugin file is backed up first.
#>

param(
    [string]$Starlight = "starlight"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LiveRoot = "K:\Steam client\millennium\plugins"
$PluginFile = "luatools.star"
$LivePlugin = Join-Path $LiveRoot $PluginFile
$LegacyPlugin = Join-Path $LiveRoot "luatools"
$BackupRoot = "K:\Steam client\millennium\.deploy-backups"

if (-not (Get-Command $Starlight -ErrorAction SilentlyContinue)) {
    Write-Error "Starlight was not found. Install it with 'npm install', or pass its executable with -Starlight."
}

if (Test-Path $LivePlugin) {
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item $LivePlugin (Join-Path $BackupRoot "$PluginFile.$timestamp.bak") -Force
}

if (Test-Path $LegacyPlugin) {
    Write-Error "Legacy plugin folder found at $LegacyPlugin. Remove it before installing luatools.star."
}

Push-Location $RepoRoot
try {
    & $Starlight pack --release --of $LiveRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Starlight failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host "Installed $LivePlugin" -ForegroundColor Green
Write-Host "Restart Steam to load the new plugin." -ForegroundColor Yellow
