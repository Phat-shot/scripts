#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Amazon DCV Server on EC2 to activate the Indirect Display Driver (IDD).
    The IDD registers a virtual monitor that supports all resolutions up to 4K,
    fixing the resolution limit on instances running the NVIDIA Gaming driver.

.DESCRIPTION
    - Downloads and installs Amazon DCV Server silently (no sessions, no client needed)
    - The IDD activates automatically after a manual reboot
    - No displays are disabled, no reboots are forced
    - Free on EC2 (license verified via AWS S3 endpoint)
    - Requires Windows Server 2019+ and DCV Server 2023.1+

.NOTES
    After running this script, reboot the instance manually.
    After reboot: "AWS Indirect Display Device" appears in Display Settings
    with all resolutions up to 4K available.
#>

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$WorkDir    = "$env:ProgramFiles\airgpu\DCV"
$LogFile    = "$env:ProgramData\airgpu\dcv_install.log"
$DcvBaseUrl = 'https://d1uj6qtbmh3dt5.cloudfront.net'
$DcvMsiUrl  = "$DcvBaseUrl/nice-dcv-server-x64-Release.msi"
$DcvMsiDest = Join-Path $WorkDir 'dcv-server.msi'

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    try {
        $d = Split-Path $LogFile
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
    switch ($Level) {
        'WARN'  { Write-Host "  [!] $Msg" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [!] $Msg" -ForegroundColor Red }
        default { Write-Host "      $Msg" -ForegroundColor DarkGray }
    }
}

function Get-FileFromWeb {
    param([string]$Url, [string]$Dest)
    Write-Log "Downloading $(Split-Path $Url -Leaf) ..."
    $tmp = $Dest + '.part'
    foreach ($attempt in 1..3) {
        try {
            $current = $Url
            for ($r = 0; $r -lt 10; $r++) {
                $req = [System.Net.HttpWebRequest]::Create($current)
                $req.UserAgent        = 'airgpu-dcv/1.0'
                $req.Timeout          = 60000
                $req.ReadWriteTimeout = 600000
                $req.AllowAutoRedirect = $false
                $resp = $req.GetResponse()
                if ([int]$resp.StatusCode -in @(301,302,303,307,308)) {
                    $current = $resp.Headers['Location']
                    $resp.Close(); continue
                }
                $stream = $resp.GetResponseStream()
                $fs     = [System.IO.File]::Create($tmp)
                $buf    = New-Object byte[] 65536
                $read   = 0
                while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $read) }
                $fs.Close(); $stream.Close(); $resp.Close()
                break
            }
            if (Test-Path $Dest) { Remove-Item $Dest -Force }
            Rename-Item $tmp $Dest
            Write-Log ("  OK (" + ('{0:N1}' -f ((Get-Item $Dest).Length / 1MB)) + " MB)")
            return
        } catch {
            Write-Log "  Attempt $attempt failed: $_" -Level 'WARN'
            if (Test-Path $tmp) { try { Remove-Item $tmp -Force } catch {} }
            if ($attempt -lt 3) { Start-Sleep -Seconds (3 * $attempt) }
        }
    }
    throw "Download failed: $Url"
}

# ── Banner ───────────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host ''
Write-Host '  airgpu -- Install Amazon DCV (Display Fix)' -ForegroundColor DarkCyan
Write-Host '  Installs DCV IDD for 4K resolution support on Gaming driver.' -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Write-Log "=== Install-AirgpuDCV start ==="

# ── Check OS ─────────────────────────────────────────────────────────────────
$build = [System.Environment]::OSVersion.Version.Build
Write-Log "OS build: $build"
if ($build -lt 17763) {
    Write-Host '  [!] Windows Server 2019 or later required (build 17763+).' -ForegroundColor Red
    Write-Log "Unsupported OS build: $build" -Level 'ERROR'
    exit 1
}

# ── Check if already installed ───────────────────────────────────────────────
Write-Host '  [1/2] Checking existing installation...' -ForegroundColor DarkCyan
$dcvSvc = Get-Service -Name 'dcvserver' -ErrorAction SilentlyContinue
if ($dcvSvc) {
    Write-Log "DCV already installed (status: $($dcvSvc.Status))."
    Write-Host "      Already installed (status: $($dcvSvc.Status))." -ForegroundColor DarkGray
    Write-Host "      Re-installing to ensure latest IDD version..." -ForegroundColor DarkGray
}

# ── Download ──────────────────────────────────────────────────────────────────
Write-Host '  [2/2] Downloading and installing DCV Server...' -ForegroundColor DarkCyan
try {
    Get-FileFromWeb -Url $DcvMsiUrl -Dest $DcvMsiDest
} catch {
    Write-Log "Latest URL failed, trying pinned version..." -Level 'WARN'
    Get-FileFromWeb -Url "$DcvBaseUrl/2025.0/Servers/nice-dcv-server-x64-Release-2025.0-20103.msi" -Dest $DcvMsiDest
}

# ── Install ───────────────────────────────────────────────────────────────────
$msiLog  = Join-Path $WorkDir 'dcv_msi.log'
$msiArgs = "/i `"$DcvMsiDest`" DISABLE_AUTOMATIC_SESSION_CREATION=1 /quiet /norestart /l*v `"$msiLog`""
Write-Log "Running msiexec..."
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -PassThru -Wait
Write-Log "msiexec exit: $($p.ExitCode)"

switch ($p.ExitCode) {
    0    { Write-Host '      Installed successfully.' -ForegroundColor DarkCyan }
    3010 { Write-Host '  [!] Installed -- please reboot to activate the IDD.' -ForegroundColor Yellow }
    default {
        Write-Host "  [!] Installer returned $($p.ExitCode) -- see $msiLog" -ForegroundColor Yellow
        Write-Log "Non-zero exit: $($p.ExitCode)" -Level 'WARN'
    }
}

# ── Disable DCV server service (IDD stays loaded as a kernel driver) ──────────
try {
    Stop-Service  'dcvserver' -Force -ErrorAction SilentlyContinue
    Set-Service   'dcvserver' -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Log "DCV server service disabled (IDD driver remains active)."
} catch { Write-Log "Could not disable DCV service: $_" -Level 'WARN' }

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Done.' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  Reboot the instance to activate the Indirect Display Driver.' -ForegroundColor Yellow
Write-Host '  After reboot: "AWS Indirect Display Device" will appear in' -ForegroundColor DarkGray
Write-Host '  Display Settings with all resolutions up to 4K available.' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ''
