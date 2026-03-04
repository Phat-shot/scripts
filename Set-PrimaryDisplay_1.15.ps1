#Requires -RunAsAdministrator
<#
.SYNOPSIS
    airgpu Display Manager -- List all displays (RDP-aware) and set the primary display.

.DESCRIPTION
    Works over RDP where EnumDisplayDevices only sees the RDP mirror adapter.
    Uses multiple detection strategies to find all displays including inactive/virtual ones:

    1. EnumDisplayDevices (active displays -- may be empty over RDP)
    2. QueryDisplayConfig with QDC_ALL_PATHS (finds all configured displays, incl. inactive)
    3. WMI Win32_VideoController + Win32_PnPEntity (finds NVIDIA Virtual Display and monitors)
    4. Registry HKLM\SYSTEM\CurrentControlSet\Control\Video (all driver-registered adapters)
    5. nvidia-smi (GPU output enumeration)

.NOTES
    Working dir : C:\Program Files\airgpu\Driver Manager\
    Log file    : C:\Program Files\airgpu\Driver Manager\driver_manager.log
#>

# ─────────────────────────────────────────────────────────────
#  CONFIG & LOGGING
# ─────────────────────────────────────────────────────────────
$WorkDir = "C:\Program Files\airgpu"
$LogFile = "$WorkDir\display_selector.log"

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$ts] [$Level] $Message" -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────
#  WIN32 API
# ─────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class DisplayAPI {

    // ── LUID ─────────────────────────────────────────────────
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    // ── QueryDisplayConfig structs ────────────────────────────
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        public int outputTechnology; public int rotation; public int scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate; public int scanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;
        public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_2DREGION { public uint cx; public uint cy; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO {
        public ulong pixelRate;
        public DISPLAYCONFIG_RATIONAL hSyncFreq; public DISPLAYCONFIG_RATIONAL vSyncFreq;
        public DISPLAYCONFIG_2DREGION activeSize; public DISPLAYCONFIG_2DREGION totalSize;
        public uint videoStandard; public int scanLineOrdering;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_TARGET_MODE {
        public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_MODE {
        public uint width; public uint height; public int pixelFormat; public POINTL position;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct DISPLAYCONFIG_MODE_INFO_UNION {
        [FieldOffset(0)] public DISPLAYCONFIG_TARGET_MODE targetMode;
        [FieldOffset(0)] public DISPLAYCONFIG_SOURCE_MODE sourceMode;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO {
        public int infoType; public uint id; public LUID adapterId;
        public DISPLAYCONFIG_MODE_INFO_UNION info;
    }

    // ── Target device name ────────────────────────────────────
    public const int DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER {
        public int type; public uint size; public LUID adapterId; public uint id;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME_FLAGS { public uint value; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public DISPLAYCONFIG_TARGET_DEVICE_NAME_FLAGS flags;
        public int outputTechnology; public ushort edidManufactureId; public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    // ── Adapter name ─────────────────────────────────────────
    public const int DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME = 4;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_ADAPTER_NAME {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string adapterDevicePath;
    }

    // ── Source device name ────────────────────────────────────
    public const int DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
    }

    // ── P/Invoke ─────────────────────────────────────────────
    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPaths,
        [Out] DISPLAYCONFIG_PATH_INFO[] paths, ref uint numModes,
        [Out] DISPLAYCONFIG_MODE_INFO[] modes, IntPtr currentTopologyId);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME r);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_ADAPTER_NAME r);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME r);
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPaths,
        [In] DISPLAYCONFIG_PATH_INFO[] paths, uint numModes,
        [In] DISPLAYCONFIG_MODE_INFO[] modes, uint flags);

    // SetDisplayConfig flags
    public const uint SDC_APPLY                        = 0x00000080;
    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG  = 0x00000020;
    public const uint SDC_SAVE_TO_DATABASE             = 0x00000200;
    public const uint SDC_ALLOW_CHANGES                = 0x00000400;
    public const uint SDC_TOPOLOGY_SUPPLIED            = 0x00000010;
    public const uint SDC_NO_OPTIMIZATION              = 0x00000100;

    // ── EnumDisplayDevices ───────────────────────────────────
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    public const uint EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001;
    public const uint DISPLAY_DEVICE_ACTIVE         = 0x00000001;
    public const uint DISPLAY_DEVICE_PRIMARY_DEVICE = 0x00000004;
    public const uint DISPLAY_DEVICE_ATTACHED       = 0x00000002;
    public const uint DISPLAY_DEVICE_MIRRORING_DRIVER = 0x00000008;

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum,
        ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    // ── ChangeDisplaySettingsEx ──────────────────────────────
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion; public ushort dmDriverVersion;
        public ushort dmSize; public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX; public int dmPositionY;
        public uint dmDisplayOrientation; public uint dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels; public uint dmBitsPerPel;
        public uint dmPelsWidth; public uint dmPelsHeight;
        public uint dmDisplayFlags; public uint dmDisplayFrequency;
        public uint dmICMMethod; public uint dmICMIntent; public uint dmMediaType;
        public uint dmDitherType; public uint dmReserved1; public uint dmReserved2;
        public uint dmPanningWidth; public uint dmPanningHeight;
    }
    public const int CDS_SET_PRIMARY    = 0x00000010;
    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int CDS_NORESET        = 0x10000000;
    public const int DISP_CHANGE_SUCCESSFUL = 0;

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode,
        IntPtr hwnd, uint dwflags, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, IntPtr lpDevMode,
        IntPtr hwnd, uint dwflags, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);
}
"@ -ErrorAction Stop

# ─────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "        /\        " -NoNewline -ForegroundColor Cyan
    Write-Host "        _                   " -ForegroundColor White
    Write-Host "       /  \       " -NoNewline -ForegroundColor Cyan
    Write-Host "   __ (_) _ __  __ _  _ __  _   _  " -ForegroundColor White
    Write-Host "      ||        " -NoNewline -ForegroundColor Cyan
    Write-Host "  / _`` || || '__|/ _`` || '_ \| | | | " -ForegroundColor White
    Write-Host "   |    |       " -NoNewline -ForegroundColor Cyan
    Write-Host " | (_| || || |  | (_| || |_) | |_| | " -ForegroundColor White
    Write-Host "   | () |       " -NoNewline -ForegroundColor Cyan
    Write-Host "  \__,_||_||_|   \__, || .__/ \__,_| " -ForegroundColor White
    Write-Host "   |    |        " -NoNewline -ForegroundColor Cyan
    Write-Host "                 |___/ |_|            " -ForegroundColor White
    Write-Host "  /|    |\      " -ForegroundColor Cyan
    Write-Host " / |    | \     " -NoNewline -ForegroundColor Cyan
    Write-Host "   D I S P L A Y   M A N A G E R     " -ForegroundColor DarkCyan
    Write-Host "   \  /\  /     " -NoNewline -ForegroundColor Cyan
    Write-Host "   NVIDIA  *  Amazon EC2  *  Windows 11" -ForegroundColor DarkGray
    Write-Host "    \/  \/      " -ForegroundColor Cyan
    Write-Host "    |    |      " -ForegroundColor DarkCyan
    Write-Host "   /      \     " -ForegroundColor DarkCyan
    Write-Host "  / ' '' ' \    " -ForegroundColor DarkCyan
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────
#  DETECT SESSION TYPE
# ─────────────────────────────────────────────────────────────
function Get-SessionInfo {
    $session = @{ IsRDP = $false; SessionName = ""; Note = "" }
    try {
        $sessionName = (query session $env:USERNAME 2>$null) -join " "
        if ($sessionName -match "rdp|console") {
            $session.IsRDP      = $sessionName -match "rdp"
            $session.SessionName = if ($session.IsRDP) { "RDP" } else { "Console" }
        }
    } catch { }

    # Also check via WTS
    if ($env:SESSIONNAME -match "rdp") {
        $session.IsRDP      = $true
        $session.SessionName = $env:SESSIONNAME
    }

    $session.Note = if ($session.IsRDP) {
        "RDP session detected -- using extended display detection"
    } else {
        "Console session"
    }
    return $session
}

# ─────────────────────────────────────────────────────────────
#  STRATEGY 1 — EnumDisplayDevices (works on Console, partial on RDP)
# ─────────────────────────────────────────────────────────────
function Get-DisplaysViaEnum {
    $results = @()
    $idx = 0
    while ($true) {
        $dev    = New-Object DisplayAPI+DISPLAY_DEVICE
        $dev.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dev)
        if (-not [DisplayAPI]::EnumDisplayDevices($null, $idx, [ref]$dev, [DisplayAPI]::EDD_GET_DEVICE_INTERFACE_NAME)) { break }

        # Skip RDP mirror driver
        $isMirror = [bool]($dev.StateFlags -band [DisplayAPI]::DISPLAY_DEVICE_MIRRORING_DRIVER)
        $isRdpDev = $dev.DeviceString -match "RDP|Remote Desktop|IDD"

        if (-not $isMirror -and -not $isRdpDev) {
            $isActive  = [bool]($dev.StateFlags -band [DisplayAPI]::DISPLAY_DEVICE_ACTIVE)
            $isPrimary = [bool]($dev.StateFlags -band [DisplayAPI]::DISPLAY_DEVICE_PRIMARY_DEVICE)

            $dm      = New-Object DisplayAPI+DEVMODE
            $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
            [DisplayAPI]::EnumDisplaySettings($dev.DeviceName, -1, [ref]$dm) | Out-Null

            $results += [PSCustomObject]@{
                Source       = "EnumDisplayDevices"
                DeviceName   = $dev.DeviceName.Trim()
                AdapterName  = $dev.DeviceString.Trim()
                FriendlyName = ""
                DeviceID     = $dev.DeviceID.Trim()
                Width        = $dm.dmPelsWidth
                Height       = $dm.dmPelsHeight
                RefreshRate  = $dm.dmDisplayFrequency
                PositionX    = $dm.dmPositionX
                PositionY    = $dm.dmPositionY
                IsActive     = $isActive
                IsPrimary    = $isPrimary
                AdapterId    = $null
                TargetId     = $null
            }
        }
        $idx++
    }
    return $results
}

# ─────────────────────────────────────────────────────────────
#  STRATEGY 2 — QueryDisplayConfig QDC_ALL_PATHS
#  Finds ALL configured displays, including inactive/virtual ones over RDP
# ─────────────────────────────────────────────────────────────
function Get-DisplaysViaQueryConfig {
    $results = @()
    try {
        $numPaths = 0; $numModes = 0

        # QDC_ALL_PATHS = 0x4 -- includes inactive paths, crucial for RDP
        $ret = [DisplayAPI]::GetDisplayConfigBufferSizes(0x4, [ref]$numPaths, [ref]$numModes)
        if ($ret -ne 0 -or $numPaths -eq 0) { return $results }

        $paths = New-Object DisplayAPI+DISPLAYCONFIG_PATH_INFO[] $numPaths
        $modes = New-Object DisplayAPI+DISPLAYCONFIG_MODE_INFO[] $numModes
        $ret   = [DisplayAPI]::QueryDisplayConfig(0x4, [ref]$numPaths, $paths, [ref]$numModes, $modes, [IntPtr]::Zero)
        if ($ret -ne 0) { return $results }

        $seen = @{}

        foreach ($path in $paths) {
            # Get target (monitor) name
            $tReq = New-Object DisplayAPI+DISPLAYCONFIG_TARGET_DEVICE_NAME
            $tReq.header.type      = [DisplayAPI]::DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
            $tReq.header.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($tReq)
            $tReq.header.adapterId.LowPart  = $path.targetInfo.adapterId.LowPart
            $tReq.header.adapterId.HighPart = $path.targetInfo.adapterId.HighPart
            $tReq.header.id        = $path.targetInfo.id
            [DisplayAPI]::DisplayConfigGetDeviceInfo([ref]$tReq) | Out-Null

            $friendlyName  = $tReq.monitorFriendlyDeviceName.Trim()
            $monitorPath   = $tReq.monitorDevicePath.Trim()

            # Skip RDP/IDD virtual displays from Remote Desktop itself
            if ($monitorPath -match "RDPUDD|RdpIdd|IddSample" -or
                $friendlyName -match "^Remote Desktop") { continue }

            # Get source (adapter + GDI device name)
            $sReq = New-Object DisplayAPI+DISPLAYCONFIG_SOURCE_DEVICE_NAME
            $sReq.header.type      = [DisplayAPI]::DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
            $sReq.header.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($sReq)
            $sReq.header.adapterId.LowPart  = $path.sourceInfo.adapterId.LowPart
            $sReq.header.adapterId.HighPart = $path.sourceInfo.adapterId.HighPart
            $sReq.header.id        = $path.sourceInfo.id
            [DisplayAPI]::DisplayConfigGetDeviceInfo([ref]$sReq) | Out-Null
            $gdiName = $sReq.viewGdiDeviceName.Trim()

            # Get adapter name
            $aReq = New-Object DisplayAPI+DISPLAYCONFIG_ADAPTER_NAME
            $aReq.header.type      = [DisplayAPI]::DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME
            $aReq.header.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($aReq)
            $aReq.header.adapterId.LowPart  = $path.sourceInfo.adapterId.LowPart
            $aReq.header.adapterId.HighPart = $path.sourceInfo.adapterId.HighPart
            $aReq.header.id        = $path.sourceInfo.id
            [DisplayAPI]::DisplayConfigGetDeviceInfo([ref]$aReq) | Out-Null
            $adapterPath = $aReq.adapterDevicePath.Trim()

            # Deduplicate by monitor device path
            $key = if ($monitorPath) { $monitorPath } else { "$($path.targetInfo.adapterId.LowPart)-$($path.targetInfo.id)" }
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $isActive  = $path.targetInfo.targetAvailable
            $isPrimary = $false  # Determined separately

            # Resolve resolution from mode info
            $width = 0; $height = 0; $hz = 0; $posX = 0; $posY = 0
            $srcModeIdx = $path.sourceInfo.modeInfoIdx
            if ($srcModeIdx -ne 0xFFFFFFFF -and $srcModeIdx -lt $modes.Count) {
                $m = $modes[$srcModeIdx]
                if ($m.infoType -eq 2) {  # DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE = 2
                    $width  = $m.info.sourceMode.width
                    $height = $m.info.sourceMode.height
                    $posX   = $m.info.sourceMode.position.x
                    $posY   = $m.info.sourceMode.position.y
                }
            }
            $tgtModeIdx = $path.targetInfo.modeInfoIdx
            if ($tgtModeIdx -ne 0xFFFFFFFF -and $tgtModeIdx -lt $modes.Count) {
                $m = $modes[$tgtModeIdx]
                if ($m.infoType -eq 1) {  # DISPLAYCONFIG_MODE_INFO_TYPE_TARGET = 1
                    $num = $m.info.targetMode.targetVideoSignalInfo.vSyncFreq.Numerator
                    $den = $m.info.targetMode.targetVideoSignalInfo.vSyncFreq.Denominator
                    if ($den -gt 0) { $hz = [uint32]($num / $den) }
                    if ($width -eq 0) {
                        $width  = $m.info.targetMode.targetVideoSignalInfo.activeSize.cx
                        $height = $m.info.targetMode.targetVideoSignalInfo.activeSize.cy
                    }
                }
            }

            $results += [PSCustomObject]@{
                Source       = "QueryDisplayConfig"
                DeviceName   = $gdiName
                AdapterName  = $adapterPath
                FriendlyName = $friendlyName
                DeviceID     = $monitorPath
                Width        = $width
                Height       = $height
                RefreshRate  = $hz
                PositionX    = $posX
                PositionY    = $posY
                IsActive     = $isActive
                IsPrimary    = $false   # set below
                AdapterId    = $path.sourceInfo.adapterId
                TargetId     = $path.targetInfo.id
                PathInfo     = $path
            }
        }
    } catch {
        Write-Log "QueryDisplayConfig failed: $_" -Level "WARN"
    }
    return $results
}

# ─────────────────────────────────────────────────────────────
#  STRATEGY 3 — WMI (finds NVIDIA Virtual Display even over RDP)
# ─────────────────────────────────────────────────────────────
function Get-DisplaysViaWMI {
    $results = @()
    $seen    = @{}

    # 3a: Win32_VideoController — catches all GPU/display adapters incl. NVIDIA
    try {
        $controllers = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "RDP|Remote Desktop|IDD|^Microsoft Remote" }
        foreach ($c in $controllers) {
            $key = $c.Name.Trim()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $results += [PSCustomObject]@{
                Source       = "WMI-VC"
                DeviceName   = ""
                AdapterName  = $c.Name.Trim()
                FriendlyName = $c.Name.Trim()
                DeviceID     = $c.PNPDeviceID
                Width        = if ($c.CurrentHorizontalResolution) { [uint32]$c.CurrentHorizontalResolution } else { 0 }
                Height       = if ($c.CurrentVerticalResolution)   { [uint32]$c.CurrentVerticalResolution   } else { 0 }
                RefreshRate  = if ($c.CurrentRefreshRate)           { [uint32]$c.CurrentRefreshRate           } else { 0 }
                PositionX    = 0
                PositionY    = 0
                IsActive     = ($c.Availability -eq 3)   # 3 = Running/Full Power
                IsPrimary    = $false
                AdapterId    = $null
                TargetId     = $null
            }
        }
    } catch {
        Write-Log "WMI Win32_VideoController failed: $_" -Level "WARN"
    }

    # 3b: Win32_PnPEntity with Display class — catches virtual monitors not in VideoController
    try {
        $entities = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object {
                (
                    $_.PNPClass -eq "Monitor" -or
                    $_.PNPClass -eq "Display" -or
                    $_.Name -match "NVIDIA|Virtual Display|Display Adapter|Monitor"
                ) -and
                $_.Name -notmatch "RDP|Remote Desktop|IDD|^Microsoft Remote"
            }
        foreach ($e in $entities) {
            $key = $e.Name.Trim()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $results += [PSCustomObject]@{
                Source       = "WMI-PnP"
                DeviceName   = ""
                AdapterName  = $e.Name.Trim()
                FriendlyName = $e.Name.Trim()
                DeviceID     = $e.DeviceID
                Width        = 0
                Height       = 0
                RefreshRate  = 0
                PositionX    = 0
                PositionY    = 0
                IsActive     = ($e.Status -eq "OK")
                IsPrimary    = $false
                AdapterId    = $null
                TargetId     = $null
            }
        }
    } catch {
        Write-Log "WMI Win32_PnPEntity failed: $_" -Level "WARN"
    }

    return $results
}

# ─────────────────────────────────────────────────────────────
#  STRATEGY 5 — Registry HKLM\SYSTEM\CurrentControlSet\Control\Video
#  Contains every display adapter registered by a driver, incl. NVIDIA Virtual Display
# ─────────────────────────────────────────────────────────────
function Get-DisplaysViaRegistry {
    $results = @()
    $seen    = @{}
    try {
        $videoBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Video"
        Get-ChildItem $videoBase -ErrorAction SilentlyContinue | ForEach-Object {
            $guidKey = $_
            Get-ChildItem $guidKey.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                $subKey = $_
                $props  = Get-ItemProperty $subKey.PSPath -ErrorAction SilentlyContinue

                # DeviceDesc or DriverDesc holds the human-readable name
                $name = if ($props.DriverDesc) { "$($props.DriverDesc)" }
                        elseif ($props.DeviceDesc) { "$($props.DeviceDesc)" }
                        elseif ($props.'Device Description') { "$($props.'Device Description')" }
                        else { $null }
                if (-not $name) { return }

                # Strip driver store prefix like "@oem12.inf,%nvidia_dev..."
                if ($name -match ',(.+)$') { $name = $Matches[1].Trim() }
                $name = $name.Trim()

                # Skip RDP/IDD adapters
                if ($name -match "RDP|Remote Desktop|IDD|^Microsoft Remote") { return }

                $key = $name.ToLower()
                if ($seen.ContainsKey($key)) { return }
                $seen[$key] = $true

                # Try to get resolution from registry
                $w  = if ($props.DefaultSettings_XResolution) { [uint32]$props.DefaultSettings_XResolution } else { 0 }
                $h  = if ($props.DefaultSettings_YResolution) { [uint32]$props.DefaultSettings_YResolution } else { 0 }
                $hz = if ($props.DefaultSettings_VRefresh)    { [uint32]$props.DefaultSettings_VRefresh    } else { 0 }

                $results += [PSCustomObject]@{
                    Source       = "Registry"
                    DeviceName   = ""
                    AdapterName  = $name
                    FriendlyName = $name
                    DeviceID     = $subKey.PSPath
                    Width        = $w
                    Height       = $h
                    RefreshRate  = $hz
                    PositionX    = 0
                    PositionY    = 0
                    IsActive     = $false
                    IsPrimary    = $false
                    AdapterId    = $null
                    TargetId     = $null
                }
            }
        }
    } catch {
        Write-Log "Registry display detection failed: $_" -Level "WARN"
    }
    return $results
}

# ─────────────────────────────────────────────────────────────
#  STRATEGY 4 — nvidia-smi (GPU outputs)
# ─────────────────────────────────────────────────────────────
function Get-DisplaysViaNvidiaSmi {
    $results = @()
    try {
        $smiPath = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        if (-not (Test-Path $smiPath)) { $smiPath = "nvidia-smi" }

        $out = & $smiPath --query-gpu=name,display_mode,display_active --format=csv,noheader 2>&1
        if ($LASTEXITCODE -ne 0) { return $results }

        foreach ($line in $out) {
            $parts = $line -split ","
            if ($parts.Count -ge 3) {
                $results += [PSCustomObject]@{
                    Source       = "nvidia-smi"
                    DeviceName   = ""
                    AdapterName  = $parts[0].Trim()
                    FriendlyName = "$($parts[0].Trim()) (display_mode=$($parts[1].Trim()))"
                    DeviceID     = ""
                    Width        = 0
                    Height       = 0
                    RefreshRate  = 0
                    PositionX    = 0
                    PositionY    = 0
                    IsActive     = ($parts[2].Trim() -eq "Enabled")
                    IsPrimary    = $false
                    AdapterId    = $null
                    TargetId     = $null
                }
            }
        }
    } catch {
        Write-Log "nvidia-smi display detection failed: $_" -Level "WARN"
    }
    return $results
}

# ─────────────────────────────────────────────────────────────
#  MERGE ALL SOURCES — deduplicate, enrich, mark primary
# ─────────────────────────────────────────────────────────────
function Get-AllDisplays {
    $enum     = Get-DisplaysViaEnum
    $qdc      = Get-DisplaysViaQueryConfig
    $wmi      = Get-DisplaysViaWMI
    $smi      = Get-DisplaysViaNvidiaSmi
    $reg      = Get-DisplaysViaRegistry

    $merged   = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Helper: check if a candidate name is already represented in $merged
    function Test-AlreadyMerged {
        param([string]$Name)
        if (-not $Name) { return $false }
        $n = $Name.Trim().ToLower()
        foreach ($m in $merged) {
            $mf = if ($m.FriendlyName) { $m.FriendlyName.Trim().ToLower() } else { "" }
            $ma = if ($m.AdapterName)  { $m.AdapterName.Trim().ToLower()  } else { "" }
            # Exact match
            if ($mf -eq $n -or $ma -eq $n) { return $true }
            # Significant substring match (at least 6 chars to avoid false positives)
            if ($n.Length -ge 6 -and ($mf -like "*$n*" -or $ma -like "*$n*")) { return $true }
            if ($n.Length -ge 6 -and ($n -like "*$mf*" -or $n -like "*$ma*") -and $mf.Length -ge 6) { return $true }
        }
        return $false
    }

    # 1. Start with QDC (most authoritative for configured paths)
    foreach ($d in $qdc) { $merged.Add($d) }

    # 2. EnumDisplayDevices — update GDI name + primary flag on existing, or add new
    foreach ($e in $enum) {
        $match = $merged | Where-Object { $_.DeviceName -eq $e.DeviceName } | Select-Object -First 1
        if (-not $match) {
            $match = $merged | Where-Object {
                $_.FriendlyName -and $e.AdapterName -and
                $_.FriendlyName.ToLower() -like "*$($e.AdapterName.ToLower().Split(' ')[0])*"
            } | Select-Object -First 1
        }
        if ($match) {
            if (-not $match.DeviceName -and $e.DeviceName) { $match.DeviceName = $e.DeviceName }
            if ($e.IsPrimary) { $match.IsPrimary = $true }
            if ($e.Width -gt 0 -and $match.Width -eq 0) {
                $match.Width = $e.Width; $match.Height = $e.Height
                $match.RefreshRate = $e.RefreshRate
                $match.PositionX   = $e.PositionX; $match.PositionY = $e.PositionY
            }
        } else {
            $merged.Add($e)
        }
    }

    # 3. WMI VideoController + PnPEntity — add anything not yet present
    foreach ($w in $wmi) {
        if (-not (Test-AlreadyMerged $w.FriendlyName)) {
            $merged.Add($w)
        }
    }

    # 4. Registry — add driver-registered adapters not yet found by other methods
    foreach ($r in $reg) {
        if (-not (Test-AlreadyMerged $r.FriendlyName)) {
            $merged.Add($r)
        }
    }

    # 5. nvidia-smi — enrich existing NVIDIA entries or add GPU info
    foreach ($s in $smi) {
        $match = $merged | Where-Object {
            $_.FriendlyName -like "*NVIDIA*" -or $_.AdapterName -like "*NVIDIA*"
        } | Select-Object -First 1
        if ($match) {
            # Enrich: mark active if smi says so
            if ($s.IsActive) { $match.IsActive = $true }
        } else {
            $merged.Add($s)
        }
    }

    # Determine primary: position (0,0) wins if not set explicitly
    $hasPrimary = $merged | Where-Object { $_.IsPrimary }
    if (-not $hasPrimary) {
        $atOrigin = $merged | Where-Object { $_.PositionX -eq 0 -and $_.PositionY -eq 0 -and $_.IsActive } |
            Select-Object -First 1
        if ($atOrigin) { $atOrigin.IsPrimary = $true }
    }

    # Assign sequential index
    $i = 0
    foreach ($d in $merged) {
        $d | Add-Member -NotePropertyName "Index" -NotePropertyValue $i -Force
        $i++
    }

    return $merged
}

# ─────────────────────────────────────────────────────────────
#  DISPLAY TABLE
# ─────────────────────────────────────────────────────────────
function Show-Displays {
    param($Displays, $SessionInfo)

    if ($SessionInfo.IsRDP) {
        Write-Host "  Session   : " -NoNewline -ForegroundColor DarkGray
        Write-Host "RDP  " -NoNewline -ForegroundColor Yellow
        Write-Host "(extended detection active)" -ForegroundColor DarkGray
    } else {
        Write-Host "  Session   : Console" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host "  Detected displays:" -ForegroundColor White
    Write-Host ""

    $fmt = "  {0,-4} {1,-18} {2,-30} {3,-16} {4,-12} {5,-8} {6}"
    Write-Host ($fmt -f "No.", "Device", "Name / Adapter", "Resolution", "Position", "Active", "Status") `
        -ForegroundColor DarkGray
    Write-Host ("  " + "-" * 95) -ForegroundColor DarkGray

    foreach ($d in $Displays) {
        $name   = if ($d.FriendlyName) { $d.FriendlyName }
                  elseif ($d.AdapterName) { $d.AdapterName }
                  else { "Unknown" }
        $name   = if ($name.Length -gt 29) { $name.Substring(0,27) + ".." } else { $name }

        $dev    = if ($d.DeviceName) { $d.DeviceName } else { "($($d.Source))" }
        $res    = if ($d.Width -gt 0) { "$($d.Width)x$($d.Height)@$($d.RefreshRate)Hz" } else { "n/a" }
        $pos    = if ($d.Width -gt 0) { "($($d.PositionX),$($d.PositionY))" } else { "n/a" }
        $active = if ($d.IsActive) { "Yes" } else { "No" }
        $status = if ($d.IsPrimary) { "[PRIMARY]" } else { "" }

        $color  = if ($d.IsPrimary)  { "Green" }
                  elseif ($d.IsActive) { "White" }
                  else                 { "DarkGray" }

        Write-Host ($fmt -f "[$($d.Index+1)]", $dev, $name, $res, $pos, $active, $status) `
            -ForegroundColor $color
    }

    Write-Host ""

    # Legend
    Write-Host "  " -NoNewline
    Write-Host "[green]" -NoNewline -ForegroundColor Green
    Write-Host " = primary   " -NoNewline -ForegroundColor DarkGray
    Write-Host "[white]" -NoNewline -ForegroundColor White
    Write-Host " = active   " -NoNewline -ForegroundColor DarkGray
    Write-Host "[gray]" -NoNewline -ForegroundColor DarkGray
    Write-Host " = inactive / virtual" -ForegroundColor DarkGray
    Write-Host ""
}

function Set-PrimaryDisplayViaRegistry {
    # Registry-based primary display change.
    #
    # Windows stores display configuration in two places:
    #   HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration\<hash>\00\
    #     -> "PrimSurf" DWORD = 1 means primary
    #   HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity\<hash>\
    #     -> links configuration to a specific adapter/display
    #
    # After writing, a reboot or "CCD database reload" is needed to apply.
    # However: the DISPLAY_DEVICE registry key under
    #   HKLM\SYSTEM\CurrentControlSet\Control\Video\{GUID}\0000\
    # contains "DefaultSettings.XResolution" etc. but NOT a primary flag.
    #
    # The REAL persistent primary flag is stored in the CCD (Connected Displays Database):
    #   HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration\
    # Each subkey is a base64-encoded topology blob. The "PrimSurf" value in the
    # active configuration's display subkey marks which output is primary.
    #
    # Simpler alternative that works WITHOUT reboot:
    # Write to the Video adapter's "AttachedTo" key and trigger a display
    # settings broadcast via BroadcastSystemMessage -- but this still requires
    # a desktop context.
    #
    # REAL solution: use the Scheduled Task as the CURRENT USER but with
    # SetDisplayConfig called from within that fresh process context.
    # The key insight we missed: GetDisplayConfigBufferSizes with QDC_ALL_PATHS
    # should work even from a service if we use the right flags. Let's try
    # QDC_DATABASE_CURRENT (0x4) vs QDC_ALL_PATHS -- actually QDC_DATABASE_CURRENT
    # = 0x4 queries the STORED database, not the active session displays.
    # This is different from QDC_ALL_PATHS for active paths!
    #
    # QDC_DATABASE_CURRENT = 0x00000004 returns the topology stored in CCD database
    # regardless of session. This is what we need.

    param([PSCustomObject]$Target)
    $label = if ($Target.FriendlyName) { $Target.FriendlyName } else { $Target.AdapterName }
    Write-Log "Registry/CCD attempt for '$label'"

    # QDC_DATABASE_CURRENT = 0x4 -- reads from CCD database (session-independent)
    # QDC_ALL_PATHS         = 0x4 -- same flag value! They are the same.
    # The real session-independent flag is:
    #   QDC_VIRTUAL_MODE_AWARE = 0x10 combined with QDC_DATABASE_CURRENT
    # But actually the issue is that over RDP, even QDC_ALL_PATHS=0x4 returns 0 paths
    # because the Desktop Window Manager is not running for this session's display.
    #
    # The ONLY session-independent way: write the CCD blob in registry directly.
    # We identify the NVIDIA adapter's registry key and set its display mode.

    $configBase = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration"

    try {
        $configs = Get-ChildItem $configBase -ErrorAction Stop
    } catch {
        Write-Log "Registry: Cannot open $configBase : $_" -Level "WARN"
        return $false
    }

    # Key name format: MSBDD_NOEDID_<VendorID>_<DevID>_...
    # NVIDIA vendor IDs in CCD key names: 1D0F (NVIDIA) or NVD in the path
    # Microsoft Basic Display: 1234
    # We pick the config key whose name contains 1D0F or NVD (NVIDIA identifiers)
    # and whose subkey count >= 1 (has at least one display entry)

    Write-Host "  [REG] Scanning $($configs.Count) display configurations..." -ForegroundColor DarkGray
    Write-Log "Registry: $($configs.Count) config entries"

    $targetConfigKey  = $null
    $targetDisplayKey = $null
    $targetKeyScore   = -1

    foreach ($cfg in $configs) {
        $cfgName  = $cfg.PSChildName
        $dispKeys = Get-ChildItem $cfg.PSPath -ErrorAction SilentlyContinue

        # Score this config key by how well it matches the requested label
        # NVIDIA L4: vendor 1D0F, NVD in path
        $isNvidia  = $cfgName -match "1D0F|NVD"
        $isMsBasic = $cfgName -match "1234"
        $score = if ($isNvidia) { 2 } elseif ($isMsBasic) { 0 } else { 1 }

        foreach ($dk in $dispKeys) {
            Write-Host "  [REG]   $cfgName\$($dk.PSChildName) nvidia=$isNvidia" -ForegroundColor DarkGray
            Write-Log "Registry: $cfgName\$($dk.PSChildName) nvidia=$isNvidia score=$score"
        }

        # Pick the config with the best score, preferring NVIDIA
        if ($score -gt $targetKeyScore -and $dispKeys.Count -gt 0) {
            $targetKeyScore  = $score
            $targetConfigKey = $cfg.PSPath
            # The display subkey to mark as primary is "00" (first output)
            $targetDisplayKey = ($dispKeys | Sort-Object PSChildName | Select-Object -First 1).PSPath
        }
    }

    if (-not $targetDisplayKey) {
        Write-Host "  [REG] No suitable display config found." -ForegroundColor Red
        Write-Log "Registry: no suitable config key found" -Level "WARN"
        return $false
    }

    Write-Host "  [REG] Selected config: $($targetConfigKey.Split('\')[-1])" -ForegroundColor Cyan
    Write-Log "Registry: selected $targetConfigKey"

    Write-Host "  [REG] Primary display key: $($targetDisplayKey.Split('\\HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers\\Configuration\\')[-1])" -ForegroundColor Cyan
    Write-Log "Registry: target display key = $targetDisplayKey"

    # Set PrimSurf=1 on target display, 0 on all others in same config
    $dispKeys2 = Get-ChildItem $targetConfigKey -ErrorAction SilentlyContinue
    $errors = 0
    foreach ($dk in $dispKeys2) {
        $isPrimary = ($dk.PSPath -eq $targetDisplayKey)
        try {
            Set-ItemProperty -Path $dk.PSPath -Name "PrimSurf" -Value ([int]$isPrimary) -Type DWord -ErrorAction Stop
            Write-Log "Registry: Set PrimSurf=$([int]$isPrimary) on $($dk.PSChildName)"
        } catch {
            Write-Log "Registry: Failed to set PrimSurf on $($dk.PSChildName): $_" -Level "WARN"
            $errors++
        }
    }

    if ($errors -gt 0) {
        Write-Host "  [REG] Some registry writes failed (permissions?)." -ForegroundColor Red
        return $false
    }

    Write-Host "  [REG] Registry updated. Triggering display change broadcast..." -ForegroundColor Cyan
    Write-Log "Registry: PrimSurf updated, broadcasting"

    # Broadcast WM_SETTINGCHANGE to tell Windows to reload display config
    # This is what Windows itself does after display settings change
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinMsg {
    [DllImport("user32.dll",SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
        string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);
    public const uint WM_SETTINGCHANGE = 0x001A;
    public const uint SMTO_ABORTIFHUNG = 0x0002;
}
"@ -ErrorAction SilentlyContinue

    try {
        $result = [UIntPtr]::Zero
        [WinMsg]::SendMessageTimeout(
            [WinMsg]::HWND_BROADCAST,
            [WinMsg]::WM_SETTINGCHANGE,
            [UIntPtr]::Zero,
            "Policy",
            [WinMsg]::SMTO_ABORTIFHUNG,
            2000,
            [ref]$result) | Out-Null
        Write-Log "Registry: WM_SETTINGCHANGE sent"
    } catch {
        Write-Log "Registry: WM_SETTINGCHANGE failed: $_" -Level "WARN"
    }

    Write-Host "  [REG] Done. A sign-out/reboot may be required to fully apply." -ForegroundColor Yellow
    return $true
}

function Set-PrimaryDisplayViaSystemTask {
    param([PSCustomObject]$Target)

    $label        = if ($Target.FriendlyName) { $Target.FriendlyName } else { $Target.AdapterName }
    $taskName     = "airgpu_SetPrimaryDisplay"
    $workerPath   = "C:\Windows\Temp\airgpu_setprimary_worker.ps1"
    $paramPath    = "C:\Windows\Temp\airgpu_setprimary_params.txt"
    $resultPath   = "C:\Windows\Temp\airgpu_setprimary_result.json"
    $logPath      = "C:\Windows\Temp\airgpu_setprimary_worker.log"
    $launchLog    = "C:\Windows\Temp\airgpu_setprimary_launcher.log"

    Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item $logPath    -Force -ErrorAction SilentlyContinue
    Remove-Item $launchLog  -Force -ErrorAction SilentlyContinue

    Write-Host "  Direct API failed (RDP session has no console display context)." -ForegroundColor Yellow
    Write-Host "  Running display change as current user via Scheduled Task..." -ForegroundColor Cyan
    Write-Host ""

    # Params file
    Set-Content -Path $paramPath -Value $label -Encoding UTF8

    # ── Worker script ─────────────────────────────────────────
    # Runs as the current logged-in user -- same account, but launched
    # by Task Scheduler with a *fresh interactive process* that has
    # the winsta0\default desktop handle. This is what gives it access
    # to ChangeDisplaySettingsEx even from an RDP session.
    @'
$paramFile  = "C:\Windows\Temp\airgpu_setprimary_params.txt"
$resultFile = "C:\Windows\Temp\airgpu_setprimary_result.json"
$logFile    = "C:\Windows\Temp\airgpu_setprimary_worker.log"
function L($m){ Add-Content $logFile "[$(Get-Date -f 'HH:mm:ss')] $m" -Encoding UTF8 }
L "Worker start. User=$env:USERNAME SessionName=$env:SESSIONNAME"
try {
    $tgt = (Get-Content $paramFile -Encoding UTF8).Trim()
    L "Target: $tgt"
    Add-Type @"
using System; using System.Runtime.InteropServices;
public class DW2 {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)]
    public struct DD { public int cb;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]  public string N;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string A;
        public uint F;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string ID;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string K; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)]
    public struct DM { [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string n;
        public ushort v1,v2,sz,ex; public uint fields; public int x,y;
        public uint ori,fix; public short c,d,yr,tt,co;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string fm;
        public ushort dpi; public uint bpp,w,h,df,hz,im,ii,mt,dt,r1,r2,pw,ph; }
    public const uint ACT=1,PRI=4,MIR=8;
    public const int SET_PRI=0x10,UPD=1,NOR=unchecked((int)0x10000000),OK=0;
    [DllImport("user32.dll",CharSet=CharSet.Ansi)] public static extern bool EnumDisplayDevices(string d,uint i,ref DD dd,uint f);
    [DllImport("user32.dll",CharSet=CharSet.Ansi)] public static extern bool EnumDisplaySettings(string d,int m,ref DM dm);
    [DllImport("user32.dll",CharSet=CharSet.Ansi)] public static extern int ChangeDisplaySettingsEx(string d,ref DM dm,IntPtr h,uint f,IntPtr l);
    [DllImport("user32.dll",CharSet=CharSet.Ansi)] public static extern int ChangeDisplaySettingsEx(string d,IntPtr dm,IntPtr h,uint f,IntPtr l);
}
"@ -ErrorAction Stop
    L "Types loaded"
    $devs=@(); $i=[uint32]0
    while($true){
        $dd=New-Object DW2+DD; $dd.cb=[Runtime.InteropServices.Marshal]::SizeOf($dd)
        if(-not [DW2]::EnumDisplayDevices($null,$i,[ref]$dd,0)){break}
        if(-not($dd.F -band [DW2]::MIR) -and $dd.A -notmatch 'RDP|IDD|Remote Desktop'){
            $dm=New-Object DW2+DM; $dm.sz=[Runtime.InteropServices.Marshal]::SizeOf($dm)
            [DW2]::EnumDisplaySettings($dd.N,-1,[ref]$dm)|Out-Null
            $devs+=[PSCustomObject]@{N=$dd.N;A=$dd.A;Act=[bool]($dd.F -band [DW2]::ACT);W=$dm.w;H=$dm.h;X=$dm.x;Y=$dm.y}
        }
        $i++
    }
    L "Devices ($($devs.Count)): $(($devs|%{$_.N+'|'+$_.A}) -join '; ')"
    $d1=$devs|Where-Object{$_.A -like "*$tgt*"}|Select-Object -First 1
    if(-not $d1){$d1=$devs|Where-Object{$_.A -like '*NVIDIA*'}|Select-Object -First 1}
    if(-not $d1){$d1=$devs|Where-Object{$_.Act}|Select-Object -First 1}
    L "Using: $($d1.N)|$($d1.A)"
    $errs=0
    if($d1){
        $ox=$d1.X; $oy=$d1.Y
        foreach($d in ($devs|Where-Object{$_.Act})){
            $dm=New-Object DW2+DM; $dm.sz=[Runtime.InteropServices.Marshal]::SizeOf($dm)
            [DW2]::EnumDisplaySettings($d.N,-1,[ref]$dm)|Out-Null
            $dm.x=$d.X-$ox; $dm.y=$d.Y-$oy; $dm.fields=0x200000
            $fl=[uint32]([DW2]::UPD -bor [DW2]::NOR)
            if($d.N -eq $d1.N){$fl=$fl -bor [uint32][DW2]::SET_PRI}
            $r=[DW2]::ChangeDisplaySettingsEx($d.N,[ref]$dm,[IntPtr]::Zero,$fl,[IntPtr]::Zero)
            L "CDS $($d.N) flags=$fl -> $r"; if($r -ne [DW2]::OK){$errs++}
        }
        [DW2]::ChangeDisplaySettingsEx($null,[IntPtr]::Zero,[IntPtr]::Zero,0,[IntPtr]::Zero)|Out-Null
    }
    $ok=($null -ne $d1 -and $errs -eq 0)
    L "Done ok=$ok errs=$errs"
    @{Success=$ok;Target="$($d1.N)|$($d1.A)";Errors=$errs;Devs=@($devs|%{"$($_.N)|$($_.A)"})}|ConvertTo-Json|Set-Content $resultFile -Encoding UTF8
} catch {
    L "EXCEPTION: $_"
    @{Success=$false;Target='';Errors=-1;Exception="$_"}|ConvertTo-Json|Set-Content $resultFile -Encoding UTF8
}
'@ | Set-Content -Path $workerPath -Encoding UTF8

    # ── Scheduled Task as the CURRENT USER (not SYSTEM) ───────
    # Running as the same user who launched this script means the task
    # inherits a valid session token with display access.
    # We use -RunLevel Highest so it has elevation.
    # The key: Task Scheduler gives it a *fresh* interactive process
    # context, unlike our current process which has the RDP desktop handle.
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$workerPath`""

        # Run as current user (interactive) -- gets proper display access
        $currentUser = "$env:USERDOMAIN\$env:USERNAME"
        $principal   = New-ScheduledTaskPrincipal `
            -UserId   $currentUser `
            -LogonType Interactive `
            -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -MultipleInstances  IgnoreNew

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Principal $principal -Settings $settings -Force | Out-Null

        Write-Host "  Step 1/3  Task registered as $currentUser (interactive)..." -ForegroundColor Cyan
        Start-ScheduledTask -TaskName $taskName
        Write-Host "  Step 2/3  Waiting for result (max 35s)..." -ForegroundColor Cyan
        Write-Log "Task '$taskName' started as '$currentUser' for target '$label'."
    } catch {
        Write-Host "  Failed to start task: $_" -ForegroundColor Red
        Write-Log "Task start failed: $_" -Level "ERROR"
        return $false
    }

    # ── Poll for result ───────────────────────────────────────
    $deadline = (Get-Date).AddSeconds(35)
    while (-not (Test-Path $resultPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600
    }

    Write-Host "  Step 3/3  Reading result..." -ForegroundColor Cyan

    if (Test-Path $logPath) {
        Write-Host "  Worker log:" -ForegroundColor DarkGray
        Get-Content $logPath | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Log "Worker log: $(Get-Content $logPath -Raw -ErrorAction SilentlyContinue)"
    } else {
        Write-Host "  No worker log -- task may not have started." -ForegroundColor Yellow
        # Check task last run result
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($taskInfo) {
            Write-Host "  Task LastRunTime  : $($taskInfo.LastRunTime)"  -ForegroundColor DarkGray
            Write-Host "  Task LastResult   : $($taskInfo.LastTaskResult)" -ForegroundColor DarkGray
            Write-Log "Task LastResult: $($taskInfo.LastTaskResult)"
        }
    }

    $ok = $false
    if (Test-Path $resultPath) {
        try {
            $res = Get-Content $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $ok  = [bool]$res.Success
            Write-Log "Result: Success=$($res.Success) Target=$($res.Target) Errors=$($res.Errors)"
            if (-not $ok) {
                Write-Host "  Target : $($res.Target)" -ForegroundColor DarkGray
                Write-Host "  Errors : $($res.Errors)" -ForegroundColor DarkGray
                if ($res.Exception) { Write-Host "  Error  : $($res.Exception)" -ForegroundColor Red }
                if ($res.Devs) {
                    Write-Host "  Devices seen:" -ForegroundColor DarkGray
                    $res.Devs | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                }
            }
        } catch {
            Write-Host "  Could not parse result: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  Timed out -- no result produced." -ForegroundColor Red
        Write-Log "Timeout: no result file." -Level "ERROR"
    }

    # ── Cleanup ───────────────────────────────────────────────
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $workerPath -Force -ErrorAction SilentlyContinue
    Remove-Item $paramPath  -Force -ErrorAction SilentlyContinue
    Remove-Item $resultPath -Force -ErrorAction SilentlyContinue

    return $ok
}

# ─────────────────────────────────────────────────────────────
#  SET PRIMARY — AtLogin Scheduled Task
#
#  GetDisplayConfigBufferSizes returns 0 paths over RDP because
#  the display stack is session-scoped. The only reliable window
#  where SetDisplayConfig works is during the interactive login
#  sequence, before RDP claims the session.
#
#  This function registers a one-shot Scheduled Task that runs
#  AT LOGON as the current user. The task calls SetDisplayConfig
#  via a small embedded script. On next sign-in (or reboot+login)
#  the display change is applied in the correct desktop context.
#  The task deletes itself after running once.
# ─────────────────────────────────────────────────────────────
function Set-PrimaryDisplayAtLogin {
    param([string]$Label)

    $taskName   = "airgpu_SetPrimaryAtLogin"
    $workerPath = "C:\Program Files\airgpu\set_primary_worker.ps1"
    $logPath    = "C:\Program Files\airgpu\display_selector.log"

    # ── Worker script embedded here ───────────────────────────
    # Runs at logon in the user's interactive session -- full display API access.
    # Self-deletes the scheduled task after running.
    $worker = @'
$logFile = "C:\Program Files\airgpu\display_selector.log"
function L($m){ Add-Content $logFile "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [AtLogin] $m" -Encoding UTF8 }
L "Worker started. User=$env:USERNAME Session=$env:SESSIONNAME"

Add-Type @"
using System; using System.Runtime.InteropServices;
public class SDC {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RATIONAL { public uint N; public uint D; }
    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE {
        public LUID adapter; public uint id; public uint modeIdx; public uint flags;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET {
        public LUID adapter; public uint id; public uint modeIdx;
        public int tech; public int rot; public int scale;
        public RATIONAL refresh; public int scanline;
        [MarshalAs(UnmanagedType.Bool)] public bool available;
        public uint flags;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PATH { public PATH_SOURCE src; public PATH_TARGET tgt; public uint flags; }
    [StructLayout(LayoutKind.Sequential)]
    public struct REGION2D { public uint cx; public uint cy; }
    [StructLayout(LayoutKind.Sequential)]
    public struct SIGNAL {
        public ulong pixelRate; public RATIONAL hSync; public RATIONAL vSync;
        public REGION2D active; public REGION2D total; public uint std; public int scan;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct TGTMODE { public SIGNAL sig; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct SRCMODE { public uint w; public uint h; public int fmt; public POINT pos; }
    [StructLayout(LayoutKind.Explicit)]
    public struct MODE_UNION {
        [FieldOffset(0)] public TGTMODE tgt;
        [FieldOffset(0)] public SRCMODE src;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct MODE { public int type; public uint id; public LUID adapter; public MODE_UNION u; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct HDR { public int type; public uint size; public LUID adapter; public uint id; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct TGTNAME {
        public HDR hdr; public uint nameFlags; public int tech;
        public ushort mfr; public ushort prod; public uint inst;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)]  public string name;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string path;
    }
    public const int GET_TARGET_NAME=2;
    [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint f,out uint np,out uint nm);
    [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint f,ref uint np,[Out]PATH[] p,ref uint nm,[Out]MODE[] m,IntPtr t);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TGTNAME r);
    [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint np,[In]PATH[] p,uint nm,[In]MODE[] m,uint f);
    public const uint APPLY=0x80,SUPPLIED=0x20,SAVE=0x200,CHANGES=0x400;
}
"@ -ErrorAction Stop
L "Types loaded"

try {
    $np=[uint32]0; $nm=[uint32]0
    $r=[SDC]::GetDisplayConfigBufferSizes(0x4,[ref]$np,[ref]$nm)
    L "BufferSizes ret=$r np=$np nm=$nm"
    if($r -ne 0 -or $np -eq 0){ L "No paths -- exiting"; exit 1 }
    $paths=New-Object SDC+PATH[] $np; $modes=New-Object SDC+MODE[] $nm
    $r=[SDC]::QueryDisplayConfig(0x4,[ref]$np,$paths,[ref]$nm,$modes,[IntPtr]::Zero)
    L "QueryDisplayConfig ret=$r"
    if($r -ne 0){ exit 1 }

    # Find target path by name containing target label
    $targetLabel = "ATLOGIN_TARGET_LABEL"
    $srcIdx = $null
    for($p=0;$p -lt $np;$p++){
        $req=New-Object SDC+TGTNAME
        $req.hdr.type=[SDC]::GET_TARGET_NAME
        $req.hdr.size=[Runtime.InteropServices.Marshal]::SizeOf($req)
        $req.hdr.adapter.Low=$paths[$p].tgt.adapter.Low
        $req.hdr.adapter.High=$paths[$p].tgt.adapter.High
        $req.hdr.id=$paths[$p].tgt.id
        [SDC]::DisplayConfigGetDeviceInfo([ref]$req)|Out-Null
        $fname=$req.name.Trim()
        L "path[$p] name='$fname' avail=$($paths[$p].tgt.available)"
        $match=($fname -and ($targetLabel -like "*$($fname.Split(' ')[0])*" -or $fname -like "*$($targetLabel.Split(' ')[0])*"))
        $nvMatch=($targetLabel -like '*NVIDIA*' -and ($fname -like '*NVIDIA*' -or $paths[$p].src.adapter.Low -ne 0))
        if($match -or $nvMatch){
            $si=$paths[$p].src.modeIdx
            if($si -ne 0xFFFFFFFF -and [int]$si -lt $modes.Count){ $srcIdx=[int]$si; L "Matched path[$p] srcIdx=$srcIdx"; break }
        }
    }
    if($null -eq $srcIdx){
        # Fallback: largest source
        $best=0
        for($m=0;$m -lt $modes.Count;$m++){
            if($modes[$m].type -eq 2){
                $a=[long]$modes[$m].u.src.w*[long]$modes[$m].u.src.h
                if($a -gt $best -and $modes[$m].u.src.w -le 10000){ $best=$a; $srcIdx=$m }
            }
        }
        L "Fallback srcIdx=$srcIdx"
    }
    if($null -eq $srcIdx){ L "No source found -- abort"; exit 1 }

    $ox=$modes[$srcIdx].u.src.pos.x; $oy=$modes[$srcIdx].u.src.pos.y
    L "Shifting by (-$ox,-$oy) to make srcIdx=$srcIdx primary"
    for($m=0;$m -lt $modes.Count;$m++){
        if($modes[$m].type -eq 2){ $modes[$m].u.src.pos.x-=$ox; $modes[$m].u.src.pos.y-=$oy }
    }
    $f=[SDC]::APPLY -bor [SDC]::SUPPLIED -bor [SDC]::SAVE -bor [SDC]::CHANGES
    $r=[SDC]::SetDisplayConfig($np,$paths,$nm,$modes,$f)
    L "SetDisplayConfig ret=$r"
    if($r -eq 0){ L "SUCCESS" } else { L "FAILED ret=$r" }
} catch { L "EXCEPTION: $_" }

# Self-delete task
Unregister-ScheduledTask -TaskName "airgpu_SetPrimaryAtLogin" -Confirm:$false -ErrorAction SilentlyContinue
'@

    # Inject the target label into the worker
    $worker = $worker -replace "ATLOGIN_TARGET_LABEL", ($Label -replace "'", "''")
    Set-Content -Path $workerPath -Value $worker -Encoding UTF8

    # Register as AtLogon task for current user
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$workerPath`""

        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $principal = New-ScheduledTaskPrincipal `
            -UserId   "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive `
            -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

        Write-Host "  AtLogin task registered for: $Label" -ForegroundColor Cyan
        Write-Log "AtLogin task registered for '$Label'"
        return $true
    } catch {
        Write-Host "  Failed to register AtLogin task: $_" -ForegroundColor Red
        Write-Log "AtLogin task registration failed: $_" -Level "ERROR"
        return $false
    }
}

function Set-PrimaryDisplay {
    param([PSCustomObject]$Target, [PSCustomObject[]]$AllDisplays)

    if ($Target.IsPrimary) {
        Write-Host ""
        Write-Host "  '$($Target.FriendlyName)' is already the primary display." -ForegroundColor Yellow
        Write-Log "Set-Primary: already primary: $($Target.FriendlyName)"
        return
    }

    Write-Host ""
    $label = if ($Target.FriendlyName) { $Target.FriendlyName } else { $Target.AdapterName }
    Write-Host "  Setting primary display to: $label" -ForegroundColor Yellow
    if ($Target.Width -gt 0) {
        Write-Host "  Resolution : $($Target.Width)x$($Target.Height)@$($Target.RefreshRate)Hz" -ForegroundColor DarkGray
    }
    Write-Host ""

    # Schedule a task to run SetDisplayConfig at next login (before RDP session takes over)
    $ok = Set-PrimaryDisplayAtLogin -Label $label

    if ($ok) {
        Write-Host "  Scheduled: NVIDIA L4 will be set as primary at next login." -ForegroundColor Green
        Write-Host "  Sign out and back in (or reboot) to apply." -ForegroundColor DarkGray
        Write-Log "Scheduled AtLogin task for: $label" -Level "OK"
    } else {
        Write-Host "  Could not schedule display change." -ForegroundColor Red
        Write-Host "  Please set it manually: Settings -> System -> Display -> Make this my main display" -ForegroundColor DarkGray
        Write-Log "Set-Primary scheduling failed for '$label'." -Level "ERROR"
    }
}

# ─────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────
Show-Banner

$session = Get-SessionInfo

while ($true) {
    $displays = Get-AllDisplays

    if ($displays.Count -eq 0) {
        Write-Host "  No displays found by any detection method." -ForegroundColor Red
        Write-Host ""
        break
    }

    Show-Displays -Displays $displays -SessionInfo $session

    # Only offer to set primary for displays that have a usable GDI device name
    # (needed for ChangeDisplaySettingsEx) OR show all with a note
    $selectable = $displays | Where-Object { $_.DeviceName -or $_.IsActive }

    if ($selectable.Count -le 1 -and ($selectable | Where-Object { $_.IsPrimary })) {
        Write-Host "  Only one actionable display found -- nothing to change." -ForegroundColor DarkGray
        Write-Host ""
        break
    }

    Write-Host "  Select the display to set as primary:" -ForegroundColor Yellow
    foreach ($d in $displays) {
        $name   = if ($d.FriendlyName) { $d.FriendlyName } elseif ($d.AdapterName) { $d.AdapterName } else { "Unknown" }
        $marker = if ($d.IsPrimary)    { "  [current primary]" } else { "" }
        $note   = if (-not $d.DeviceName -and -not $d.IsActive) { "  (inactive/virtual)" } else { "" }
        Write-Host "    [$($d.Index+1)] $name$marker$note"
    }
    Write-Host "    [0] Exit"
    Write-Host ""

    do {
        Write-Host "  Selection: " -ForegroundColor Yellow -NoNewline
        $sel = Read-Host
        $num = -1
        [int]::TryParse($sel, [ref]$num) | Out-Null
    } while ($num -lt 0 -or $num -gt $displays.Count)

    if ($num -eq 0) {
        Write-Host "  Exiting." -ForegroundColor DarkGray
        Write-Host ""
        break
    }

    $chosen = $displays | Where-Object { $_.Index -eq ($num - 1) } | Select-Object -First 1
    Set-PrimaryDisplay -Target $chosen -AllDisplays $displays

    Write-Host ""
    Write-Host "  Press Enter to refresh or Ctrl+C to exit..." -ForegroundColor DarkGray
    Read-Host | Out-Null
    Clear-Host
    Show-Banner
}
