<#
.SYNOPSIS
  Fails if a published folder holds binaries built for the other processor.

.DESCRIPTION
  An arm64 process can't load x64 DLLs, and the exe's own architecture says nothing about them: the
  1.5 and 1.6 ARM packages had an arm64 exe and x64 WinUI. Managed-only assemblies are marked x86
  (0x14C) or arm64/x64 when precompiled, and run anywhere that matches, so only the other 64-bit
  architecture counts as wrong. Hybrid ARM64X files read as arm64 but load in either kind of process,
  so a file with an .a64xrm section passes: the Windows App SDK ships one in its x64 package.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\check-package-arch.ps1 -Arch arm64 -Folder artifacts\publish\arm64
#>
param(
    [Parameter(Mandatory)] [ValidateSet("x64", "arm64")] [string]$Arch,
    [Parameter(Mandatory)] [string]$Folder
)

$ErrorActionPreference = "Stop"
$wrong = if ($Arch -eq "arm64") { 0x8664 } else { 0xAA64 }

function Test-Hybrid([byte[]]$Bytes, [int]$Header) {
    $sections = [BitConverter]::ToUInt16($Bytes, $Header + 6)
    $start = $Header + 24 + [BitConverter]::ToUInt16($Bytes, $Header + 20)
    for ($i = 0; $i -lt $sections; $i++) {
        $at = $start + $i * 40
        if ($at + 8 -gt $Bytes.Length) { return $false }
        if ([Text.Encoding]::ASCII.GetString($Bytes, $at, 8).TrimEnd([char]0) -eq ".a64xrm") { return $true }
    }
    return $false
}

$bad = @()
$count = 0
foreach ($file in Get-ChildItem $Folder -Recurse -File -Include *.dll, *.exe) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { continue }
    $header = [BitConverter]::ToInt32($bytes, 60)
    if ($header -lt 0 -or $header + 6 -gt $bytes.Length) { continue }
    $count++
    if ([BitConverter]::ToUInt16($bytes, $header + 4) -eq $wrong -and -not (Test-Hybrid $bytes $header)) { $bad += $file.FullName }
}
if ($count -eq 0) { throw "No binaries in $Folder." }
if ($bad.Count -gt 0) { throw "$($bad.Count) of $count binaries in the $Arch package are for the other processor:`n$($bad -join "`n")" }
Write-Host "checked $count binaries: none for the other processor ($Arch)"
