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
$WorkDir = "C:\Program Files\airgpu\Driver Manager"
$LogFile = "$WorkDir\driver_manager.log"

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
            $tReq.header.adapterId = $path.targetInfo.adapterId
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
            $sReq.header.adapterId = $path.sourceInfo.adapterId
            $sReq.header.id        = $path.sourceInfo.id
            [DisplayAPI]::DisplayConfigGetDeviceInfo([ref]$sReq) | Out-Null
            $gdiName = $sReq.viewGdiDeviceName.Trim()

            # Get adapter name
            $aReq = New-Object DisplayAPI+DISPLAYCONFIG_ADAPTER_NAME
            $aReq.header.type      = [DisplayAPI]::DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME
            $aReq.header.size      = [System.Runtime.InteropServices.Marshal]::SizeOf($aReq)
            $aReq.header.adapterId = $path.sourceInfo.adapterId
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
                $name = $props.DeviceDesc -or $props.DriverDesc
                if (-not $name) {
                    $name = $props.'Device Description'
                }
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

# ─────────────────────────────────────────────────────────────
#  SET PRIMARY — direct ChangeDisplaySettingsEx call
# ─────────────────────────────────────────────────────────────
function Set-PrimaryDisplayViaEnum {
    param([PSCustomObject]$Target, [PSCustomObject[]]$AllDisplays)

    $activePair = $AllDisplays | Where-Object { $_.DeviceName -and $_.Width -gt 0 }
    if (-not $activePair) {
        Write-Log "Set-PrimaryDisplayViaEnum: no active GDI device names found." -Level "WARN"
        return $false
    }

    $offsetX = $Target.PositionX
    $offsetY = $Target.PositionY
    $errors  = 0

    foreach ($d in $activePair) {
        $dm        = New-Object DisplayAPI+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        [DisplayAPI]::EnumDisplaySettings($d.DeviceName, -1, [ref]$dm) | Out-Null

        $dm.dmPositionX = $d.PositionX - $offsetX
        $dm.dmPositionY = $d.PositionY - $offsetY
        $dm.dmFields    = 0x00200000  # DM_POSITION

        $flags = [uint32]([DisplayAPI]::CDS_UPDATEREGISTRY -bor [DisplayAPI]::CDS_NORESET)
        if ($d.DeviceName -eq $Target.DeviceName) {
            $flags = $flags -bor [uint32][DisplayAPI]::CDS_SET_PRIMARY
        }

        $result = [DisplayAPI]::ChangeDisplaySettingsEx(
            $d.DeviceName, [ref]$dm, [IntPtr]::Zero, $flags, [IntPtr]::Zero)
        if ($result -ne [DisplayAPI]::DISP_CHANGE_SUCCESSFUL) { $errors++ }
    }

    # Commit
    [DisplayAPI]::ChangeDisplaySettingsEx(
        $null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero) | Out-Null

    return ($errors -eq 0)
}

# ─────────────────────────────────────────────────────────────
#  SET PRIMARY — via Scheduled Task as SYSTEM in Session 0
#
#  Why: tscon moves the session but the running PowerShell process
#  keeps its original desktop context — EnumDisplayDevices still
#  returns no GDI names.  SYSTEM always runs in Session 0 which
#  has full console/physical display access regardless of RDP.
#
#  Flow:
#    1. Write a small worker script to a temp file
#    2. Register + run it as a Scheduled Task (SYSTEM, interactive, Session 0)
#    3. Worker: enumerate displays, find target by name, call
#       ChangeDisplaySettingsEx, write result JSON to a result file
#    4. Wait for result file (up to 30 s), read outcome
#    5. Clean up task + temp files
# ─────────────────────────────────────────────────────────────
function Set-PrimaryDisplayViaSystemTask {
    param([PSCustomObject]$Target)

    $label        = if ($Target.FriendlyName) { $Target.FriendlyName } else { $Target.AdapterName }
    $taskName     = "airgpu_SetPrimaryDisplay"
    $workerPath   = "C:\Windows\Temp\airgpu_setprimary_worker.ps1"
    $launcherPath = "C:\Windows\Temp\airgpu_setprimary_launcher.ps1"
    $paramPath    = "C:\Windows\Temp\airgpu_setprimary_params.txt"
    $resultPath   = "C:\Windows\Temp\airgpu_setprimary_result.json"
    $logPath      = "C:\Windows\Temp\airgpu_setprimary_worker.log"

    Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item $logPath    -Force -ErrorAction SilentlyContinue

    Write-Host "  Direct API failed (RDP session has no console display context)." -ForegroundColor Yellow
    Write-Host "  Spawning worker in Console user context via WTSQueryUserToken..." -ForegroundColor Cyan
    Write-Host ""

    # Params file -- avoids all escaping
    Set-Content -Path $paramPath -Value $label -Encoding UTF8

    # ── Worker: runs as console user, has interactive desktop token ──
    @'
$paramFile  = "C:\Windows\Temp\airgpu_setprimary_params.txt"
$resultFile = "C:\Windows\Temp\airgpu_setprimary_result.json"
$logFile    = "C:\Windows\Temp\airgpu_setprimary_worker.log"
function L($m){ Add-Content $logFile "[$(Get-Date -f 'HH:mm:ss')] $m" -Encoding UTF8 }
L "Worker start user=$env:USERNAME"
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
        $ox=$d1.X;$oy=$d1.Y
        foreach($d in ($devs|Where-Object{$_.Act})){
            $dm=New-Object DW2+DM;$dm.sz=[Runtime.InteropServices.Marshal]::SizeOf($dm)
            [DW2]::EnumDisplaySettings($d.N,-1,[ref]$dm)|Out-Null
            $dm.x=$d.X-$ox;$dm.y=$d.Y-$oy;$dm.fields=0x200000
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

    # ── Launcher: SYSTEM uses WTSQueryUserToken to get the console
    #    user's interactive token, then CreateProcessAsUser to run
    #    the worker in that user context (has the real desktop handle)
    @'
Add-Type @"
using System; using System.Runtime.InteropServices;
public class TL {
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("Wtsapi32.dll",SetLastError=true)] public static extern bool WTSQueryUserToken(uint s,out IntPtr t);
    [DllImport("userenv.dll",SetLastError=true)] public static extern bool CreateEnvironmentBlock(out IntPtr e,IntPtr t,bool i);
    [DllImport("userenv.dll",SetLastError=true)] public static extern bool DestroyEnvironmentBlock(IntPtr e);
    [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Auto)]
    public static extern bool CreateProcessAsUser(IntPtr t,string app,string cmd,IntPtr pa,IntPtr ta,bool inh,uint fl,IntPtr env,string dir,ref SI si,out PI pi);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Auto)]
    public struct SI { public int cb; public string r1,desktop,title; public uint x,y,xs,ys,xc,yc,fill; public ushort nd; public uint flags; public ushort show,r2; public IntPtr r3,si0,so,se; }
    [StructLayout(LayoutKind.Sequential)]
    public struct PI { public IntPtr proc,thread; public uint pid,tid; }
    public const uint ENV=0x400; public const uint INF=0xFFFFFFFF;
}
"@ -ErrorAction Stop
$sid=[TL]::WTSGetActiveConsoleSessionId()
$tok=[IntPtr]::Zero
[TL]::WTSQueryUserToken($sid,[ref]$tok)|Out-Null
$si=New-Object TL+SI; $si.cb=[Runtime.InteropServices.Marshal]::SizeOf($si); $si.desktop="winsta0\default"
$pi=New-Object TL+PI
$env=[IntPtr]::Zero
[TL]::CreateEnvironmentBlock([ref]$env,$tok,$false)|Out-Null
$cmd='powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Windows\Temp\airgpu_setprimary_worker.ps1"'
[TL]::CreateProcessAsUser($tok,$null,$cmd,[IntPtr]::Zero,[IntPtr]::Zero,$false,[TL]::ENV,$env,$null,[ref]$si,[ref]$pi)|Out-Null
[TL]::WaitForSingleObject($pi.proc,[TL]::INF)|Out-Null
if($env -ne [IntPtr]::Zero){[TL]::DestroyEnvironmentBlock($env)|Out-Null}
if($pi.proc -ne [IntPtr]::Zero){[TL]::CloseHandle($pi.proc)|Out-Null}
if($tok  -ne [IntPtr]::Zero){[TL]::CloseHandle($tok)|Out-Null}
'@ | Set-Content -Path $launcherPath -Encoding UTF8

    # ── Register + run task as SYSTEM ────────────────────────
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$launcherPath`""

        $principal = New-ScheduledTaskPrincipal `
            -UserId    "SYSTEM" `
            -LogonType  ServiceAccount `
            -RunLevel   Highest

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -MultipleInstances  IgnoreNew

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Principal $principal -Settings $settings -Force | Out-Null

        Write-Host "  Step 1/3  Task registered. SYSTEM will impersonate Console user..." -ForegroundColor Cyan
        Start-ScheduledTask -TaskName $taskName
        Write-Host "  Step 2/3  Waiting for result (max 35s)..." -ForegroundColor Cyan
        Write-Log "Task '$taskName' started for target '$label'."
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
        Write-Host "  (no worker log produced -- launcher likely failed to spawn worker)" -ForegroundColor Yellow
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
                    Write-Host "  Devices seen by console user:" -ForegroundColor DarkGray
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
    Remove-Item $workerPath   -Force -ErrorAction SilentlyContinue
    Remove-Item $launcherPath -Force -ErrorAction SilentlyContinue
    Remove-Item $paramPath    -Force -ErrorAction SilentlyContinue
    Remove-Item $resultPath   -Force -ErrorAction SilentlyContinue

    return $ok
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

    # First attempt: direct API (works on Console session or when GDI names are available)
    $ok = Set-PrimaryDisplayViaEnum -Target $Target -AllDisplays $AllDisplays

    if ($ok) {
        Write-Host "  Primary display updated successfully." -ForegroundColor Green
        Write-Log "Primary display set to: $label ($($Target.DeviceName))" -Level "OK"
        return
    }

    # Second attempt: SYSTEM Scheduled Task running in Session 0 (console display context)
    Write-Log "Direct API failed for '$label', attempting SYSTEM/Session-0 task." -Level "WARN"
    $ok = Set-PrimaryDisplayViaSystemTask -Target $Target

    if ($ok) {
        Write-Host ""
        Write-Host "  Primary display updated successfully via SYSTEM task." -ForegroundColor Green
        Write-Log "Primary display set to: $label via SYSTEM/Session-0 task." -Level "OK"
    } else {
        Write-Host ""
        Write-Host "  Could not set primary display automatically." -ForegroundColor Red
        Write-Host "  Please set it manually: Settings -> System -> Display -> Make this my main display" -ForegroundColor DarkGray
        Write-Log "Set-Primary failed for '$label' via both direct API and SYSTEM task." -Level "ERROR"
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
