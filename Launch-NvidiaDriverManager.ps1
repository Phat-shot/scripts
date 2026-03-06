#Requires -RunAsAdministrator
<#
.SYNOPSIS
    airgpu Driver Manager Launcher
    Downloads and runs the latest Manage-NvidiaDriver.ps1 from GitHub.
#>

$RawUrl    = "https://raw.githubusercontent.com/Phat-shot/scripts/main/Manage-NvidiaDriver.ps1"
$WorkDir   = "C:\Program Files\airgpu\Driver Manager"
$ScriptDst = "$WorkDir\Manage-NvidiaDriver.ps1"

# ── Ensure working directory exists ──────────────────────────
if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

# ── Banner ────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "        /\        " -NoNewline -ForegroundColor Cyan
Write-Host "        _                   " -ForegroundColor White
Write-Host "       /  \       " -NoNewline -ForegroundColor Cyan
Write-Host "   __ (_) _ __  __ _  _ __  _   _  " -ForegroundColor White
Write-Host "      ||        " -NoNewline -ForegroundColor Cyan
Write-Host "  / _` || || '__|/ _` || '_ \| | | | " -ForegroundColor White
Write-Host "   |    |       " -NoNewline -ForegroundColor Cyan
Write-Host " | (_| || || |  | (_| || |_) | |_| | " -ForegroundColor White
Write-Host "   | () |       " -NoNewline -ForegroundColor Cyan
Write-Host "  \__,_||_||_|   \__, || .__/ \__,_| " -ForegroundColor White
Write-Host "   |    |        " -NoNewline -ForegroundColor Cyan
Write-Host "                 |___/ |_|            " -ForegroundColor White
Write-Host "  /|    |\      " -ForegroundColor Cyan
Write-Host " / |    | \     " -NoNewline -ForegroundColor Cyan
Write-Host "   D R I V E R   M A N A G E R       " -ForegroundColor DarkCyan
Write-Host "   \  /\  /     " -NoNewline -ForegroundColor Cyan
Write-Host "   NVIDIA  *  Amazon EC2  *  Windows 11" -ForegroundColor DarkGray
Write-Host "    \/  \/      " -ForegroundColor Cyan
Write-Host "    |    |      " -ForegroundColor DarkCyan
Write-Host "   /      \     " -ForegroundColor DarkCyan
Write-Host "  / ' '' ' \    " -ForegroundColor DarkCyan
Write-Host ""

# ── Download latest script ────────────────────────────────────
Write-Host "  Fetching latest script from GitHub..." -ForegroundColor Yellow
Write-Host "  $RawUrl" -ForegroundColor DarkGray
Write-Host ""

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($RawUrl, $ScriptDst)

    Write-Host "  Downloaded: $ScriptDst" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Could not download script." -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Please check your internet connection and try again." -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
}

# ── Execute ───────────────────────────────────────────────────
Write-Host ""
Write-Host "  Launching Driver Manager..." -ForegroundColor Cyan
Write-Host ""

# When running as a compiled EXE (ps2exe), & script.ps1 is blocked by ExecutionPolicy.
# Spawn a real powershell.exe and immediately hide this window.
$isExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName -notlike "*powershell*"
if ($isExe) {
    $argStr = ($args | ForEach-Object { $_ }) -join " "
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDst`" $argStr" -Wait -NoNewWindow
} else {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    & $ScriptDst @args
}
