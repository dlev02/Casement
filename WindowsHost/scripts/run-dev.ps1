<#
.SYNOPSIS
  Builds the console host (Debug) and runs it in the interactive desktop session on port 47821
  with the fixed pairing code 246810, logging to %LOCALAPPDATA%\Vantage Host\logs\dev.log.

.DESCRIPTION
  Run it over SSH: processes started by sshd live in a service session that can't see the console
  desktop (no capture, no SendInput), so the host is started through a scheduled task that runs in
  the signed-in user's interactive session. Drew must be signed in at the PC (locked is fine) and
  Remote Desktop must not be connected (it takes the console session; `tscon` gives it back).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\run-dev.ps1
  powershell -ExecutionPolicy Bypass -File scripts\run-dev.ps1 -DumpH264 C:\temp\vantage.h264 -ExitAfter 60
  powershell -ExecutionPolicy Bypass -File scripts\run-dev.ps1 -Stop
#>
param(
    [int]$Port = 47821,
    [string]$PairingCode = "246810",
    [string]$DumpH264,
    [int]$ExitAfter = 0,
    [ValidateSet("auto", "hardware", "software")] [string]$Encoder = "auto",
    [string]$ReceiveFolder,
    [switch]$Synthetic,
    [switch]$Verbose,
    [switch]$NoBuild,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:TESTINGPLATFORM_TELEMETRY_OPTOUT = "1"
$root = Split-Path -Parent $PSScriptRoot
$taskName = "VantageDev"

function Stop-DevHost {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
    Get-Process VantageHostCli -ErrorAction SilentlyContinue | Stop-Process -Force
}

Stop-DevHost
if ($Stop) { Write-Host "Stopped."; return }

if (-not $NoBuild) {
    dotnet build (Join-Path $root "src\Vantage.Host.Windows.Cli\Vantage.Host.Windows.Cli.csproj") -c Debug
    if ($LASTEXITCODE -ne 0) { throw "Build failed." }
}

$exe = Join-Path $root "src\Vantage.Host.Windows.Cli\bin\Debug\net10.0-windows10.0.26100.0\VantageHostCli.exe"
if (-not (Test-Path $exe)) { throw "Not built: $exe" }

$logDir = Join-Path $env:LOCALAPPDATA "Vantage Host\logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir "dev.log"

$arguments = @("--port", $Port, "--pairing-code", $PairingCode, "--log-file", "`"$log`"", "--encoder", $Encoder)
if ($DumpH264) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $DumpH264) | Out-Null
    Remove-Item $DumpH264 -ErrorAction SilentlyContinue # the host appends
    $arguments += @("--dump-h264", "`"$DumpH264`"")
}
if ($ExitAfter -gt 0) { $arguments += @("--exit-after", $ExitAfter) }
if ($ReceiveFolder) { $arguments += @("--receive-folder", "`"$ReceiveFolder`"") }
if ($Synthetic) { $arguments += "--synthetic" }
if ($Verbose) { $arguments += "--verbose" }

$action = New-ScheduledTaskAction -Execute $exe -Argument ($arguments -join " ") -WorkingDirectory (Split-Path $exe)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Start-Sleep -Seconds 2
$process = Get-Process VantageHostCli -ErrorAction SilentlyContinue
if (-not $process) {
    Write-Warning "The host didn't start. Is Drew signed in at the PC (and not over Remote Desktop)?"
} else {
    Write-Host "Vantage Host (console) running in session $($process.SessionId) on port $Port, pairing code $PairingCode."
}
Write-Host "Log: $log"
Write-Host "Follow it with: Get-Content `"$log`" -Wait -Tail 50"
