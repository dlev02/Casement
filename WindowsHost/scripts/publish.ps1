<#
.SYNOPSIS
  Publishes Vantage Host (the tray app) self-contained for win-x64 into
  %LOCALAPPDATA%\Programs\Vantage Host and adds a Start menu shortcut. No installer, no MSIX.

.DESCRIPTION
  Quits a running Vantage Host first (its files are in use). Files copied over SSH carry no Mark of
  the Web, so SmartScreen doesn't prompt; if Smart App Control is on, unsigned apps are blocked.
  Turn on "Start Vantage Host when I sign in" in its General page afterwards.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Configuration Debug -Launch
#>
param(
    [ValidateSet("Release", "Debug")] [string]$Configuration = "Release",
    [string]$Destination = (Join-Path $env:LOCALAPPDATA "Programs\Vantage Host"),
    [switch]$Launch
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:TESTINGPLATFORM_TELEMETRY_OPTOUT = "1"
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "src\Vantage.Host.Windows\Vantage.Host.Windows.csproj"

$running = Get-Process VantageHost -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Quitting the running Vantage Host..."
    $running | Stop-Process -Force
    Start-Sleep -Seconds 1
}

$staging = Join-Path $root "artifacts\publish\VantageHost"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
dotnet publish $project -c $Configuration -r win-x64 --self-contained -p:Platform=x64 -o $staging
if ($LASTEXITCODE -ne 0) { throw "Publish failed." }

New-Item -ItemType Directory -Force $Destination | Out-Null
robocopy $staging $Destination /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Copying to $Destination failed (robocopy $LASTEXITCODE)." }
$exe = Join-Path $Destination "VantageHost.exe"

$shortcutPath = Join-Path ([Environment]::GetFolderPath("Programs")) "Vantage Host.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = $Destination
$shortcut.IconLocation = "$exe,0"
$shortcut.Description = "Vantage Host: control this PC from your iPad"
$shortcut.Save()

$size = (Get-ChildItem $Destination -Recurse | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Published to {0} ({1:N0} MB) with a Start menu shortcut." -f $Destination, $size)
if ($Launch) { Start-Process $exe }
