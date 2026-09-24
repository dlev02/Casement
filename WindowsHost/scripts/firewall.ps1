<#
.SYNOPSIS
  Lets iPads on the tailnet reach Vantage Host (TCP 47820–47829 from Tailscale addresses only).
  Run once, as administrator, before the host first listens, so Windows never creates a block rule.

.EXAMPLE
  Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -File scripts\firewall.ps1'
#>
$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell (Run as administrator)."
}

$name = "Vantage Host (tailnet)"
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort 47820-47829 -RemoteAddress 100.64.0.0/10, fd7a:115c:a1e0::/48 -Profile Any | Out-Null
Write-Host "Added '$name': TCP 47820-47829 from 100.64.0.0/10 and fd7a:115c:a1e0::/48."

# If Windows already asked about VantageHost.exe / VantageHostCli.exe and the answer was Cancel, it
# created per-program block rules, which win over any allow rule. Remove them.
$blocks = Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.Program -match "VantageHost(Cli)?\.exe$" } |
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.Action -eq "Block" }
foreach ($rule in $blocks) {
    Write-Host "Removing block rule '$($rule.DisplayName)' for $((Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule).Program)"
    $rule | Remove-NetFirewallRule
}
