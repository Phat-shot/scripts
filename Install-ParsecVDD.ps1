#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the Parsec Virtual Display Driver (VDD) and sets it up as a
    persistent Windows service that keeps a virtual 4K display always connected.

.DESCRIPTION
    After installing the NVIDIA Gaming driver on EC2, the virtual GPU reports
    no EDID and Windows is stuck at 1366x768. This script fixes the problem by:

      1. Downloading and silently installing the Parsec VDD driver
         (signed Microsoft-compatible IddCx driver, free & open source)
      2. Installing the ParsecVDA-Always-Connected service (winsw-based)
         which keeps a virtual display permanently plugged in
      3. Setting the virtual display resolution to 3840x2160 (4K)

    The NVIDIA adapter remains your primary GPU. The Parsec VDD only adds a
    second virtual monitor -- Windows renders via NVIDIA, the virtual display
    just advertises all resolutions up to 4K@240Hz to the OS.

.NOTES
    Sources:
      Driver:  https://builds.parsec.app/vdd/parsec-vdd-0.45.0.0.exe
      Service: https://github.com/timminator/ParsecVDA-Always-Connected
    Both are free and open source (GPL-3.0).
    Requires Windows 10 21H2+ or Windows Server 2019+.
#>

$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────────────
$WorkDir   = "$env:ProgramFiles\airgpu\VDD"
$LogFile   = "$env:ProgramData\airgpu\vdd_install.log"
$VddExe    = Join-Path $WorkDir 'parsec-vdd-setup.exe'
$SvcExe    = Join-Path $WorkDir 'ParsecVDAAC.exe'
$WinswExe  = Join-Path $WorkDir 'winsw.exe'
$SvcXml    = Join-Path $WorkDir 'ParsecVDAAC.xml'
$SvcName   = 'ParsecVDAAC'

# ── URLs ───────────────────────────────────────────────────────────────────
$VddUrl    = 'https://builds.parsec.app/vdd/parsec-vdd-0.45.0.0.exe'
$SvcUrl    = 'https://github.com/timminator/ParsecVDA-Always-Connected/releases/latest/download/ParsecVDA.Always.Connected.exe'
$WinswUrl  = 'https://github.com/winsw/winsw/releases/download/v3.0.0-alpha.11/WinSW-x64.exe'

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

function Get-FileFromWeb {
    param([string]$Url, [string]$Dest)
    Write-Log "Downloading $(Split-Path $Url -Leaf)..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'airgpu-vdd-installer/1.0'
        $wc.DownloadFile($Url, $Dest)
        Write-Log "  -> $Dest ($('{0:N1}' -f ((Get-Item $Dest).Length/1MB)) MB)"
    } catch {
        Write-Log "Download failed: $_" -Level 'ERROR'
        throw
    }
}

# ── Banner ─────────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host ''
Write-Host '  airgpu -- Parsec Virtual Display Driver Setup' -ForegroundColor DarkCyan
Write-Host '  Adds a permanent virtual 4K display to the Gaming driver.' -ForegroundColor DarkGray
Write-Host ''

# ── Workdir ────────────────────────────────────────────────────────────────
if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}
Write-Log "WorkDir: $WorkDir"

# ── Step 1: Stop + remove existing service if present ─────────────────────
Write-Host '  [1/4] Checking existing service...' -ForegroundColor DarkCyan
$existingSvc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Log "Stopping existing service $SvcName..."
    try { Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue } catch {}
    try {
        if (Test-Path $WinswExe) {
            & $WinswExe uninstall $SvcXml 2>&1 | Out-Null
        } else {
            sc.exe delete $SvcName | Out-Null
        }
        Write-Log "Existing service removed."
    } catch { Write-Log "Could not remove service: $_" -Level 'WARN' }
    Start-Sleep -Seconds 2
}

# ── Step 2: Download Parsec VDD driver ────────────────────────────────────
Write-Host '  [2/4] Installing Parsec VDD driver...' -ForegroundColor DarkCyan

# Check if already installed
$vddInstalled = $false
try {
    $dev = Get-PnpDevice -FriendlyName '*Parsec*' -ErrorAction SilentlyContinue
    if ($dev) { $vddInstalled = $true; Write-Log "Parsec VDD already installed: $($dev.FriendlyName)" }
} catch {}

if (-not $vddInstalled) {
    Get-FileFromWeb -Url $VddUrl -Dest $VddExe
    Write-Log "Running VDD installer silently..."
    try {
        $p = Start-Process -FilePath $VddExe -ArgumentList '/silent' -PassThru -Wait
        Write-Log "VDD installer exit code: $($p.ExitCode)"
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            Write-Log "VDD installer returned $($p.ExitCode) -- may still have succeeded." -Level 'WARN'
        }
    } catch {
        Write-Log "VDD installer failed: $_" -Level 'ERROR'
        throw
    }
    # Verify
    Start-Sleep -Seconds 3
    try {
        $dev = Get-PnpDevice -FriendlyName '*Parsec*' -ErrorAction SilentlyContinue
        if ($dev) { Write-Log "VDD confirmed installed: $($dev.FriendlyName)" }
        else       { Write-Log "VDD device not yet visible in PnP (may need reboot)." -Level 'WARN' }
    } catch {}
} else {
    Write-Host "      Already installed -- skipping." -ForegroundColor DarkGray
}

# ── Step 3: Install always-connected service ───────────────────────────────
Write-Host '  [3/4] Setting up always-connected service...' -ForegroundColor DarkCyan

# Download winsw (service wrapper)
Get-FileFromWeb -Url $WinswUrl -Dest $WinswExe

# Download the ParsecVDAAC executable
Get-FileFromWeb -Url $SvcUrl -Dest $SvcExe

# Write service XML config
$xmlContent = @"
<service>
  <id>$SvcName</id>
  <name>ParsecVDA - Always Connected</name>
  <description>Keeps a Parsec virtual display permanently connected for 4K gaming on EC2.</description>
  <executable>$SvcExe</executable>
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
  <log mode="none"/>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="none"/>
</service>
"@
Set-Content -Path $SvcXml -Value $xmlContent -Encoding UTF8
Write-Log "Service XML written: $SvcXml"

# Install via winsw
Write-Log "Installing service via winsw..."
try {
    $out = & $WinswExe install $SvcXml 2>&1
    Write-Log "winsw install: $out"
} catch {
    Write-Log "winsw install failed: $_" -Level 'ERROR'
    throw
}

# Start service
Write-Log "Starting service $SvcName..."
try {
    Start-Service -Name $SvcName -ErrorAction Stop
    Write-Log "Service started OK."
} catch {
    Write-Log "Service start failed: $_" -Level 'WARN'
    Write-Log "Trying sc.exe start as fallback..."
    sc.exe start $SvcName | Out-Null
}

# Verify service running
Start-Sleep -Seconds 3
$svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Log "Service is Running."
} else {
    Write-Log "Service status: $($svc.Status)" -Level 'WARN'
}

# ── Step 4: Set resolution on the virtual display ─────────────────────────
Write-Host '  [4/4] Setting virtual display resolution...' -ForegroundColor DarkCyan

# Give the virtual display a moment to appear
Start-Sleep -Seconds 4

try {
    # Find the Parsec virtual display
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class DisplayHelper {
    [DllImport("user32.dll")] public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll")] public static extern int EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll")] public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    public const int ENUM_CURRENT_SETTINGS = -1;
    public const uint CDS_UPDATEREGISTRY = 0x01;
    public const uint CDS_GLOBAL = 0x08;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public short dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight;
        public uint dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
        public uint dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
}
'@ -Language CSharp -ErrorAction SilentlyContinue

    $dd   = New-Object DisplayHelper+DISPLAY_DEVICE
    $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd)
    $idx  = 0
    $parsecDev = $null

    while ([DisplayHelper]::EnumDisplayDevices($null, $idx, [ref]$dd, 0)) {
        if ($dd.DeviceString -like '*Parsec*') {
            $parsecDev = $dd.DeviceName
            Write-Log "Found Parsec display: $($dd.DeviceName) = $($dd.DeviceString)"
            break
        }
        $idx++
    }

    if ($parsecDev) {
        $dm = New-Object DisplayHelper+DEVMODE
        $dm.dmSize        = [short][System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        $dm.dmPelsWidth   = 3840
        $dm.dmPelsHeight  = 2160
        $dm.dmDisplayFrequency = 60
        $dm.dmFields      = 0x180000  # DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
        $dm.dmFields      = 0x1C0000
        $ret = [DisplayHelper]::ChangeDisplaySettingsEx($parsecDev, [ref]$dm, [IntPtr]::Zero, 0x01 -bor 0x08, [IntPtr]::Zero)
        Write-Log "ChangeDisplaySettingsEx result: $ret (0=OK)"
        if ($ret -eq 0) {
            Write-Host "      Virtual display set to 3840x2160@60Hz." -ForegroundColor DarkCyan
        } else {
            Write-Log "Resolution change returned $ret -- trying Set-DisplayResolution fallback." -Level 'WARN'
            if (Get-Command Set-DisplayResolution -ErrorAction SilentlyContinue) {
                Set-DisplayResolution -Width 3840 -Height 2160 -Force
            }
        }
    } else {
        Write-Log "Parsec display not found yet -- resolution will be set on first connection." -Level 'WARN'
        Write-Host "      Virtual display not yet visible -- reconnect RDP to activate." -ForegroundColor Yellow
    }
} catch {
    Write-Log "Resolution setup failed: $_" -Level 'WARN'
}

# ── Summary ────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Done.' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  Parsec VDD installed and service running.' -ForegroundColor White
Write-Host '  A virtual display (up to 4K@240Hz) is now always connected.' -ForegroundColor White
Write-Host '  Your NVIDIA adapter remains your primary GPU.' -ForegroundColor White
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor DarkGray
Write-Host '    1. Reconnect your RDP session' -ForegroundColor DarkGray
Write-Host '    2. Go to Windows Display Settings' -ForegroundColor DarkGray
Write-Host '    3. Select "Parsec Virtual Display Adapter" as primary display' -ForegroundColor DarkGray
Write-Host '    4. Set resolution to desired value (up to 3840x2160)' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ''
