# ============================================================
#  airgpu Driver Manager — Build Script
#  Produces two EXEs:
#    airgpu-driver-manager.exe        (launcher, deployed locally)
#    airgpu-driver-manager-app.exe    (app, hosted on GitHub Releases)
#
#  Usage:
#    .\Build-All.ps1
#    .\Build-All.ps1 -OutDir "C:\build"
# ============================================================
param(
    [string]$OutDir   = "$PSScriptRoot\build",
    [string]$IconPath = "C:\Program Files\airgpu\airgpu.ico"
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# ── Find csc.exe ─────────────────────────────────────────────
$csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64" -Filter "csc.exe" -Recurse -ErrorAction SilentlyContinue |
       Sort-Object { $_.DirectoryName } -Descending | Select-Object -First 1
if (-not $csc) { Write-Error "csc.exe not found. .NET Framework required."; exit 1 }
Write-Host "CSC: $($csc.FullName)" -ForegroundColor DarkGray

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$iconArg = if (Test-Path $IconPath) { "/win32icon:`"$IconPath`"" } else { "" }

# ── UAC manifest (shared) ─────────────────────────────────────
$manifest = Join-Path $env:TEMP "airgpu.manifest"
@'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges>
      <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
    </requestedPrivileges></security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
</assembly>
'@ | Set-Content $manifest -Encoding UTF8


# ════════════════════════════════════════════════════════════
#  BUILD 1: LAUNCHER  (console app, minimal, no WPF)
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Building launcher..." -ForegroundColor Cyan

$launcherCs  = Join-Path $PSScriptRoot "Launcher.cs"
$launcherOut = Join-Path $OutDir "airgpu-driver-manager.exe"

$launcherRefs = @("System.dll","System.Core.dll","System.Net.dll")
$launcherArgs = @(
    "/target:exe",          # console exe — shows while downloading
    "/platform:x64",
    "/optimize+",
    "/out:`"$launcherOut`"",
    "/win32manifest:`"$manifest`""
) + ($launcherRefs | ForEach-Object { "/reference:`"$_`"" })
if ($iconArg) { $launcherArgs += $iconArg }
$launcherArgs += "`"$launcherCs`""

$result = & $csc.FullName $launcherArgs 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  OK -> $launcherOut" -ForegroundColor Green
} else {
    Write-Host "  FAILED:" -ForegroundColor Red
    $result | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 1
}


# ════════════════════════════════════════════════════════════
#  BUILD 2: APP  (WPF winexe, full driver manager GUI)
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Building app..." -ForegroundColor Cyan

$appCs  = Join-Path $PSScriptRoot "DriverManagerApp.cs"
$appOut = Join-Path $OutDir "airgpu-driver-manager-app.exe"

$appRefs = @(
    "System.dll",
    "System.Core.dll",
    "System.Net.dll",
    "System.Xml.dll",
    "WindowsBase.dll",
    "PresentationCore.dll",
    "PresentationFramework.dll",
    "System.Xaml.dll",
    "Microsoft.Win32.Registry.dll",
    "System.Security.dll"
)
$appArgs = @(
    "/target:winexe",
    "/platform:x64",
    "/optimize+",
    "/out:`"$appOut`"",
    "/win32manifest:`"$manifest`""
) + ($appRefs | ForEach-Object { "/reference:`"$_`"" })
if ($iconArg) { $appArgs += $iconArg }
$appArgs += "`"$appCs`""

$result = & $csc.FullName $appArgs 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  OK -> $appOut" -ForegroundColor Green
} else {
    Write-Host "  FAILED:" -ForegroundColor Red
    $result | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 1
}


# ── Cleanup ──────────────────────────────────────────────────
Remove-Item $manifest -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "  Deploy:  $launcherOut  -->  C:\Program Files\airgpu\airgpu-driver-manager.exe"
Write-Host "  Release: $appOut  -->  GitHub Releases -> airgpu-driver-manager-app.exe"
Write-Host ""
