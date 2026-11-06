<#
.SYNOPSIS
  Builds Casement-Host-Setup-<arch>.exe from a published Casement Host folder.

.DESCRIPTION
  make-release.ps1 calls this for each architecture. It needs Inno Setup 6.6 or later:
  winget install --id JRSoftware.InnoSetup --scope user

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\make-installer.ps1 -Version 1.4 -Arch x64 -Source "artifacts\publish\x64\Casement Host" -Out artifacts\release
#>
param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [ValidateSet("x64", "arm64")] [string]$Arch,
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Out,
    # A copy with its own name, Start menu entry and startup value, to try beside the real host.
    [switch]$TestInstall
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$compiler = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $compiler) { throw "Inno Setup isn't installed. Run: winget install --id JRSoftware.InnoSetup --scope user" }

$sourceFolder = (Resolve-Path $Source).Path
if (-not (Test-Path (Join-Path $sourceFolder "VantageHost.exe"))) { throw "No VantageHost.exe in $sourceFolder." }
New-Item -ItemType Directory -Force $Out | Out-Null
$outFolder = (Resolve-Path $Out).Path

$arguments = @("/Qp", "/DVersion=$Version", "/DArch=$Arch", "/DSourceDir=$sourceFolder", "/DOutputDir=$outFolder")
if ($TestInstall) { $arguments += "/DTestInstall=1" }
& $compiler @arguments (Join-Path $root "installer\CasementHost.iss")
if ($LASTEXITCODE -ne 0) { throw "Building the $Arch installer failed." }
Join-Path $outFolder "Casement-Host-Setup-$Arch.exe"
