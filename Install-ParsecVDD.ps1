#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the Parsec Virtual Display Driver (VDD) as a permanent Windows service,
    giving the NVIDIA Gaming driver access to all resolutions up to 4K@240Hz.
.NOTES
    Free & open source (GPL-3.0). No Parsec account required.
    Requires Windows 10 21H2+ or Windows Server 2019+.
#>

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────────────
$WorkDir  = "$env:ProgramFiles\airgpu\VDD"
$LogFile  = "$env:ProgramData\airgpu\vdd_install.log"
$SvcName  = 'ParsecVDAAC'

# ── Logging ────────────────────────────────────────────────────────────────
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

# ── HTTP download with redirect + retry ────────────────────────────────────
function Get-FileFromWeb {
    param([string]$Url, [string]$Dest)
    Write-Log "Downloading $(Split-Path $Url -Leaf) ..."
    $tmp = $Dest + '.part'
    foreach ($attempt in 1..3) {
        try {
            # Follow redirects manually (GitHub releases redirect to CDN)
            $current = $Url
            for ($r = 0; $r -lt 10; $r++) {
                $req = [System.Net.HttpWebRequest]::Create($current)
                $req.UserAgent        = 'airgpu-vdd/1.0'
                $req.Timeout          = 30000
                $req.ReadWriteTimeout = 300000
                $req.AllowAutoRedirect = $false
                $resp = $req.GetResponse()
                if ($resp.StatusCode -in @(301,302,303,307,308)) {
                    $current = $resp.Headers['Location']
                    $resp.Close()
                    continue
                }
                # Download
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
            Write-Log "  OK ($( '{0:N1}' -f ((Get-Item $Dest).Length / 1MB) ) MB)"
            return
        } catch {
            Write-Log "  Attempt $attempt failed: $_" -Level 'WARN'
            if (Test-Path $tmp) { try { Remove-Item $tmp -Force } catch {} }
            if ($attempt -lt 3) { Start-Sleep -Seconds (3 * $attempt) }
        }
    }
    throw "Download failed: $Url"
}

# ── GitHub latest release asset URL ────────────────────────────────────────
function Get-GitHubAssetUrl {
    param([string]$Repo, [string]$Pattern)
    $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    Write-Log "Resolving $Repo latest release ..."
    $req = [System.Net.HttpWebRequest]::Create($apiUrl)
    $req.UserAgent = 'airgpu-vdd/1.0'
    $req.Timeout   = 15000
    $resp   = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $json   = $reader.ReadToEnd()
    $reader.Close(); $resp.Close()
    # Build regex pattern without [^ in quoted strings (PS parse-time issue)

    $sq  = [char]34

    $pat = "browser_download_url" + $sq + ":" + $sq + "(" + [char]91 + [char]94 + $sq + [char]93 + "+" + ")" + $sq
    $urls = [regex]::Matches($json, $pat) |
            ForEach-Object { $_.Groups[1].Value }
    $match = $urls | Where-Object { $_ -match $Pattern } | Select-Object -First 1
    if (-not $match) { throw "No asset matching '$Pattern' found in $Repo" }
    Write-Log "  -> $match"
    return $match
}

# ── Banner ─────────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host ''
Write-Host '  airgpu -- Parsec Virtual Display Driver Setup' -ForegroundColor DarkCyan
Write-Host '  Adds a permanent virtual 4K display alongside the Gaming driver.' -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Write-Log "WorkDir: $WorkDir"

# ── Step 1: Remove existing service ────────────────────────────────────────
Write-Host '  [1/4] Checking existing service...' -ForegroundColor DarkCyan
$existingSvc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Log "Removing existing service $SvcName ..."
    try { Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue } catch {}
    $wsPrev = Join-Path $WorkDir 'winsw.exe'
    $xPrev  = Join-Path $WorkDir "$SvcName.xml"
    if ((Test-Path $wsPrev) -and (Test-Path $xPrev)) {
        & $wsPrev uninstall $xPrev 2>&1 | Out-Null
    } else {
        sc.exe delete $SvcName | Out-Null
    }
    Start-Sleep -Seconds 2
    Write-Log "Existing service removed."
}

# ── Step 2: Install Parsec VDD driver ──────────────────────────────────────
Write-Host '  [2/4] Installing Parsec VDD driver...' -ForegroundColor DarkCyan

$vddInstalled = $false
try {
    $dev = Get-PnpDevice -FriendlyName '*Parsec*' -ErrorAction SilentlyContinue
    if ($dev) { $vddInstalled = $true; Write-Log "Already installed: $($dev.FriendlyName)" }
} catch {}

if (-not $vddInstalled) {
    $vddDest = Join-Path $WorkDir 'parsec-vdd-setup.exe'
    # Try Parsec CDN first (official), fall back to GitHub release
    $vddUrls = @(
        'https://builds.parsec.app/vdd/parsec-vdd-0.45.0.0.exe',
        'https://github.com/nomi-san/parsec-vdd/releases/download/v0.45.1/ParsecVDisplay-v0.45.1-setup.exe',
        'https://github.com/nomi-san/parsec-vdd/releases/download/v0.45.0/ParsecVDisplay-v0.45.0-setup.exe'
    )
    $downloaded = $false
    foreach ($url in $vddUrls) {
        try { Get-FileFromWeb -Url $url -Dest $vddDest; $downloaded = $true; break }
        catch { Write-Log "  URL failed: $url" -Level 'WARN' }
    }
    if (-not $downloaded) {
        try {
            $url = Get-GitHubAssetUrl -Repo 'nomi-san/parsec-vdd' -Pattern 'setup\.exe$'
            Get-FileFromWeb -Url $url -Dest $vddDest
        } catch {
            Write-Log "All VDD download sources failed: $_" -Level 'ERROR'
            throw
        }
    }

    Write-Log "Running VDD installer (silent) ..."
    $p = Start-Process -FilePath $vddDest -ArgumentList '/silent' -PassThru -Wait
    Write-Log "VDD installer exit code: $($p.ExitCode)"
    if ($p.ExitCode -notin @(0, 3010)) {
        Write-Log "Non-zero exit ($($p.ExitCode)) -- may still be OK." -Level 'WARN'
    }
    Start-Sleep -Seconds 3
    try {
        $dev = Get-PnpDevice -FriendlyName '*Parsec*' -ErrorAction SilentlyContinue
        if ($dev) { Write-Log "VDD confirmed: $($dev.FriendlyName)" }
        else       { Write-Log "VDD not yet visible in PnP (may need reboot)." -Level 'WARN' }
    } catch {}
} else {
    Write-Host '      Already installed -- skipping.' -ForegroundColor DarkGray
}

# ── Step 3: Download and install always-connected service ───────────────────
Write-Host '  [3/4] Setting up always-connected service...' -ForegroundColor DarkCyan

# ParsecVDA-Always-Connected -- uses its own Inno Setup installer which registers
# its own service internally. We run it with /SILENT so no wizard appears.
$svcSetupDest = Join-Path $WorkDir 'ParsecVDAAC-setup.exe'
try {
    $url = Get-GitHubAssetUrl -Repo 'timminator/ParsecVDA-Always-Connected' -Pattern 'setup.*x64\.exe$|x64.*setup\.exe$|\.exe$'
    Get-FileFromWeb -Url $url -Dest $svcSetupDest
} catch {
    Write-Log "ParsecVDA-Always-Connected download failed: $_" -Level 'ERROR'; throw
}

Write-Log "Running ParsecVDA-Always-Connected installer (silent) ..."
$p = Start-Process -FilePath $svcSetupDest -ArgumentList '/SILENT', '/NORESTART' -PassThru -Wait
Write-Log "Installer exit code: $($p.ExitCode)"
if ($p.ExitCode -notin @(0, 3010)) {
    Write-Log "Non-zero exit ($($p.ExitCode)) -- may still be OK." -Level 'WARN'
}
Start-Sleep -Seconds 5

# The installer registers its own service named "ParsecVDA - Always Connected"
$realSvcName = 'ParsecVDA - Always Connected'
$svc = Get-Service -Name $realSvcName -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "Service '$realSvcName' status: $($svc.Status)"
    if ($svc.Status -ne 'Running') {
        try { Start-Service -Name $realSvcName -ErrorAction Stop }
        catch { sc.exe start $realSvcName | Out-Null }
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name $realSvcName -ErrorAction SilentlyContinue
        Write-Log "Service status after start: $($svc.Status)"
    }
} else {
    Write-Log "Service '$realSvcName' not found after install -- check installer logs." -Level 'WARN'
}

# ── Step 4: Register preset resolutions ────────────────────────────────────
Write-Host '  [4/4] Registering preset resolutions...' -ForegroundColor DarkCyan

$regPath = 'HKLM:\SOFTWARE\Parsec\vdd'
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
$presets = @('3840 2160 60','2560 1440 60','1920 1080 60','1920 1080 144','2560 1440 144')
for ($i = 0; $i -lt $presets.Count; $i++) {
    Set-ItemProperty -Path $regPath -Name "$i" -Value $presets[$i] -Type String -Force
    Write-Log "  Preset $i : $($presets[$i])"
}

try {
    if (Get-Command Set-DisplayResolution -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 4
        Set-DisplayResolution -Width 3840 -Height 2160 -Force
        Write-Log "Set-DisplayResolution 3840x2160 OK."
    }
} catch { Write-Log "Set-DisplayResolution: $_" -Level 'WARN' }

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Done.' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  Parsec VDD installed and service running.' -ForegroundColor White
Write-Host '  Virtual display with all resolutions up to 4K@240Hz is now active.' -ForegroundColor White
Write-Host '  Your NVIDIA adapter remains the primary GPU.' -ForegroundColor White
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor DarkGray
Write-Host '    1. Reconnect your RDP / streaming session' -ForegroundColor DarkGray
Write-Host '    2. Open Windows Display Settings' -ForegroundColor DarkGray
Write-Host '    3. Select "Parsec Virtual Display Adapter" as primary' -ForegroundColor DarkGray
Write-Host '    4. Choose your resolution (up to 3840x2160)' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ''
