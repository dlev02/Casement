<#
.SYNOPSIS
  Publishes Casement Host Service (CasementHostService.exe) as one self-contained, trimmed file into
  a published Casement Host folder.

.DESCRIPTION
  "Control administrator prompts and apps" copies it from the host's folder into Program Files and
  runs it as a SYSTEM service, so it can't lean on the runtime in the host's folder (any program
  running as the user could change that). One file keeps it to ~13 MB; partial trimming only trims
  assemblies marked trimmable, and its warnings come from WinRT projections the service never calls.
  Called by publish.ps1 and make-release.ps1.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\publish-service.ps1 -Arch x64 -Destination artifacts\publish\VantageHost
#>
param(
    [Parameter(Mandatory)] [ValidateSet("x64", "arm64")] [string]$Arch,
    [Parameter(Mandatory)] [string]$Destination,
    [ValidateSet("Release", "Debug")] [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "src\Vantage.Host.Windows.Service\Vantage.Host.Windows.Service.csproj"
$out = Join-Path $root "artifacts\publish\service-$Arch"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
dotnet publish $project -c $Configuration -r "win-$Arch" --self-contained `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:PublishTrimmed=true -p:TrimMode=partial -p:SuppressTrimAnalysisWarnings=true -p:TreatWarningsAsErrors=false `
    -p:GenerateDocumentationFile=false -p:DebugType=none -o $out
if ($LASTEXITCODE -ne 0) { throw "Publishing Casement Host Service ($Arch) failed." }
Copy-Item (Join-Path $out "CasementHostService.exe") $Destination -Force
