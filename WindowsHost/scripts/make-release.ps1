<#
.SYNOPSIS
  Builds the Windows release files into artifacts\release: the x64 and arm64 zips, their SHA-256
  checksums, and the signed update manifest installed copies check for.

.DESCRIPTION
  Upload everything it prints to the GitHub release tagged host-<version>. A copy only updates to a
  release that has both windows-update.json and windows-update.json.sig, and only once that release
  is published and marked latest (a draft is invisible to it).

  The signing key stays out of the repo. Lose it and installed copies can never update again without a
  manual download, so keep a backup (a password manager is a good place).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\make-release.ps1 -Version 1.4
#>
param(
    [Parameter(Mandatory)] [string]$Version,
    [string]$Key = (Join-Path $env:USERPROFILE ".casement\update-signing-key")
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:TESTINGPLATFORM_TELEMETRY_OPTOUT = "1"
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "src\Vantage.Host.Windows\Vantage.Host.Windows.csproj"
$signer = Join-Path $root "tools\UpdateSigner\UpdateSigner.csproj"
$out = Join-Path $root "artifacts\release"

if (-not (Test-Path $Key)) { throw "No signing key at $Key." }
$declared = ([xml](Get-Content $project -Raw)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if ($declared -ne $Version) { throw "The csproj says version $declared, not $Version. Bump it first (a commit of its own)." }

New-Item -ItemType Directory -Force $out | Out-Null
$readme = "Casement Host for Windows $Version. Run VantageHost.exe in this folder once. From then on it starts when you sign in, is in the Start menu, and keeps itself up to date. Keep this folder where it is."
$zips = @{}
foreach ($arch in "x64", "arm64") {
    $staging = Join-Path $root "artifacts\publish\$arch\Casement Host"
    if (Test-Path (Split-Path $staging)) { Remove-Item -Recurse -Force (Split-Path $staging) }
    $publish = @("publish", $project, "-c", "Release", "-r", "win-$arch", "--self-contained", "-p:Platform=x64", "-o", $staging)
    if ($arch -eq "arm64") { $publish += @("-p:PlatformTarget=arm64", "-p:RuntimeIdentifier=win-arm64") }
    dotnet @publish
    if ($LASTEXITCODE -ne 0) { throw "Publishing $arch failed." }
    Set-Content -Path (Join-Path $staging "README.txt") -Value $readme
    $zip = Join-Path $out "Casement-Host-$Version-windows-$arch.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal
    $zips[$arch] = $zip
}

dotnet run --project $signer -c Release -- sign --key $Key --version $Version --tag "host-$Version" --out $out --x64 $zips.x64 --arm64 $zips.arm64
if ($LASTEXITCODE -ne 0) { throw "Signing failed." }

$sums = Join-Path $out "Casement-Host-$Version-windows-SHA256.txt"
$zips.Values | Sort-Object | ForEach-Object { "$((Get-FileHash $_ -Algorithm SHA256).Hash.ToLowerInvariant())  $(Split-Path $_ -Leaf)" } | Set-Content $sums

Write-Host "`nUpload these to the host-$Version release:"
Get-ChildItem $out | Where-Object { $_.Name -like "*$Version*" -or $_.Name -like "windows-update*" } | ForEach-Object { Write-Host "  $($_.FullName)" }
